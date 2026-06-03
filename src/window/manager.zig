const std = @import("std");
const seam = @import("../platform/backend.zig");
const D = @import("../manifest/types.zig");
const win = @import("window.zig");
const protocol = @import("../protocol.zig");
const NullBackend = @import("../platform/null.zig").NullBackend;

const zigware_js = @embedFile("frontend/zigware.js");
const window_js = @embedFile("frontend/window.js");

pub const default_show_fallback_ms: u32 = 5000;

/// Writes the per-window injected label constant, escaping the label through
/// protocol.jsString (THE injection boundary; the label is display-only, never a
/// trust input). Factored out so create can map the writer's WriteFailed (a
/// growth OOM) onto its narrow Error set.
fn buildLabelScript(w: *std.Io.Writer, label: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("window.__ZIGWARE_LABEL__ = ");
    try protocol.jsString(w, label);
    try w.writeAll(";");
}

pub fn WindowManager(comptime B: type) type {
    seam.assertBackend(B);
    return struct {
        const Self = @This();
        pub const Entry = win.WindowEntry(B);
        pub const Options = win.CreateOptions(B);
        pub const Error = error{ LabelInUse, UnknownLabel, BackendFailure, OutOfMemory };

        gpa: std.mem.Allocator,
        backend: *B,
        io: std.Io,
        /// Guards by_label AND by_id. The only off-main reader is Bridge.emit/
        /// emitAll (worker thread) via handleFor/forEachHandle; main-thread
        /// create/close take it for the brief insert/remove. NEVER held across a
        /// seam call.
        map_mutex: std.Io.Mutex = .init,
        by_label: std.StringHashMapUnmanaged(*Entry) = .empty,
        by_id: std.AutoHashMapUnmanaged(B.WindowId, *Entry) = .empty,
        fallback_ms: u32 = default_show_fallback_ms,
        /// Set true in closeAll/deinit so any pending watchdog thread that wakes
        /// during teardown exits without touching freed state.
        shutting_down: std.atomic.Value(bool) = .{ .raw = false },

        pub fn init(gpa: std.mem.Allocator, backend: *B, io: std.Io) Self {
            return .{ .gpa = gpa, .backend = backend, .io = io };
        }

        /// Frees every live entry (cancelling its watchdog first), the label
        /// copies, and both maps. Production calls closeAll before this; deinit
        /// must still not leak if a test skips closeAll.
        pub fn deinit(self: *Self) void {
            self.shutting_down.store(true, .release);
            var it = self.by_label.valueIterator();
            while (it.next()) |ep| {
                const e = ep.*;
                self.cancelWatchdog(e); // joins the thread, frees its label copy
                self.gpa.free(e.label);
                self.gpa.destroy(e);
            }
            self.by_label.deinit(self.gpa);
            self.by_id.deinit(self.gpa);
        }

        pub fn create(self: *Self, opts: Options) Error!*Entry {
            if (self.by_label.contains(opts.label)) return error.LabelInUse;

            const label_copy = try self.gpa.dupe(u8, opts.label);
            errdefer self.gpa.free(label_copy);

            const url_src = opts.url orelse "app://localhost/index.html";
            const url_z = try self.gpa.dupeZ(u8, url_src);
            defer self.gpa.free(url_z);
            const title_z = try self.gpa.dupeZ(u8, opts.title);
            defer self.gpa.free(title_z);

            // Per-window injected scripts: the embedded bridge + window helper,
            // then a baked label constant escaped through jsString (THE injection
            // boundary; the label is display-only, never a trust input).
            // The Allocating writer's only failure is WriteFailed on a growth
            // OOM; fold it into OutOfMemory so create's Error set stays narrow.
            var label_script_aw: std.Io.Writer.Allocating = .init(self.gpa);
            defer label_script_aw.deinit();
            buildLabelScript(&label_script_aw.writer, opts.label) catch return error.OutOfMemory;
            const user_scripts = [_][]const u8{ zigware_js, window_js, label_script_aw.writer.buffered() };

            const handle = self.backend.createWindow(.{
                .url = url_z,
                .user_scripts = &user_scripts,
                .title = title_z,
                .width = @floatFromInt(opts.width),
                .height = @floatFromInt(opts.height),
                .decorations = opts.decorations,
                .titlebar = win.titleBarStyleToSeam(opts.title_bar_style),
                .show = false, // ALWAYS hidden; markReadyAndShow honors opts.show
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ScriptContainsNul => return error.BackendFailure,
            };
            errdefer self.backend.destroyWindow(handle);

            const id = self.backend.windowId(handle);
            const entry = try self.gpa.create(Entry);
            errdefer self.gpa.destroy(entry);
            entry.* = .{
                .label = label_copy,
                .handle = handle,
                .window_id = id,
                .want_show = opts.show,
                .shown = false,
                .ready = false,
                .closing = false,
            };

            {
                self.map_mutex.lockUncancelable(self.io);
                defer self.map_mutex.unlock(self.io);
                try self.by_label.put(self.gpa, label_copy, entry);
                errdefer _ = self.by_label.remove(label_copy);
                try self.by_id.put(self.gpa, id, entry);
            }
            errdefer {
                self.map_mutex.lockUncancelable(self.io);
                _ = self.by_label.remove(label_copy);
                _ = self.by_id.remove(id);
                self.map_mutex.unlock(self.io);
            }

            try self.spawnWatchdog(entry); // Task 5
            return entry;
        }

        pub fn close(self: *Self, label: []const u8) Error!void {
            self.map_mutex.lockUncancelable(self.io);
            const entry = self.by_label.get(label) orelse {
                self.map_mutex.unlock(self.io);
                return error.UnknownLabel;
            };
            if (entry.closing) {
                self.map_mutex.unlock(self.io);
                return; // idempotent
            }
            entry.closing = true;
            _ = self.by_label.remove(entry.label);
            _ = self.by_id.remove(entry.window_id);
            self.map_mutex.unlock(self.io);

            self.cancelWatchdog(entry); // join + free watchdog copy
            self.backend.destroyWindow(entry.handle);
            self.gpa.free(entry.label);
            self.gpa.destroy(entry);
        }

        // Op wrappers: get-under-lock-free is safe ONLY on the main thread; these
        // run on the command/main thread. They re-check liveness so a stale label
        // never reaches a seam call.
        pub fn focus(self: *Self, label: []const u8) Error!void {
            const e = self.lookup(label) orelse return error.UnknownLabel;
            self.backend.focusWindow(e.handle);
        }
        pub fn setTitle(self: *Self, label: []const u8, title: []const u8) Error!void {
            const e = self.lookup(label) orelse return error.UnknownLabel;
            const z = try self.gpa.dupeZ(u8, title);
            defer self.gpa.free(z);
            self.backend.setTitle(e.handle, z) catch return error.BackendFailure;
        }
        pub fn setSize(self: *Self, label: []const u8, w: u32, h: u32) Error!void {
            const e = self.lookup(label) orelse return error.UnknownLabel;
            self.backend.setSize(e.handle, @floatFromInt(w), @floatFromInt(h));
        }
        pub fn setFullscreen(self: *Self, label: []const u8, on: bool) Error!void {
            const e = self.lookup(label) orelse return error.UnknownLabel;
            self.backend.setFullscreen(e.handle, on);
        }

        // Main-thread lookups (no lock; the maps are only mutated on the main
        // thread, and the off-main readers use the locked handleFor/forEachHandle).
        pub fn lookup(self: *Self, label: []const u8) ?*Entry {
            return self.by_label.get(label);
        }
        pub fn lookupById(self: *Self, id: B.WindowId) ?*Entry {
            return self.by_id.get(id);
        }
        pub fn labelFor(self: *Self, id: B.WindowId) ?[]const u8 {
            const e = self.by_id.get(id) orelse return null;
            return e.label;
        }
        pub fn liveCount(self: *Self) usize {
            return self.by_label.count();
        }

        /// Off-main-thread label->handle, under the map mutex (Bridge.emit).
        pub fn handleFor(self: *Self, label: []const u8) ?B.WindowHandle {
            self.map_mutex.lockUncancelable(self.io);
            defer self.map_mutex.unlock(self.io);
            const e = self.by_label.get(label) orelse return null;
            return e.handle;
        }

        /// Off-main-thread snapshot of every live handle into `buf`; returns the
        /// count written (capped at buf.len; a larger live set logs and is
        /// truncated, never silently). The caller evalJS's OUTSIDE the lock.
        pub fn snapshotHandles(self: *Self, buf: []B.WindowHandle) usize {
            self.map_mutex.lockUncancelable(self.io);
            defer self.map_mutex.unlock(self.io);
            var n: usize = 0;
            var it = self.by_label.valueIterator();
            while (it.next()) |ep| {
                if (n >= buf.len) {
                    std.log.warn("emitAll: more live windows than snapshot buffer; truncating", .{});
                    break;
                }
                buf[n] = ep.*.handle;
                n += 1;
            }
            return n;
        }

        // Watchdog scheduling (Task 5) replaces these compiling stubs. A missing
        // symbol here would break create/close/deinit, which reference them.
        fn spawnWatchdog(self: *Self, entry: *Entry) Error!void {
            _ = self;
            entry.watchdog = null;
            entry.watchdog_thread = null;
        }
        pub fn cancelWatchdog(self: *Self, entry: *Entry) void {
            _ = self;
            _ = entry;
        }
    };
}

fn tm(be: *NullBackend) WindowManager(NullBackend) {
    return WindowManager(NullBackend).init(std.testing.allocator, be, std.testing.io);
}

test "create assigns the label, forces show:false, binds the attested id" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    defer mgr.deinit();
    const e = try mgr.create(.{ .label = "main", .url = "app://localhost/index.html", .show = true });
    try std.testing.expectEqualStrings("main", e.label);
    try std.testing.expectEqual(@as(usize, 1), mgr.liveCount());
    try std.testing.expect(!be.windows.items[e.handle].shown); // created hidden
    try std.testing.expectEqual(be.windowId(e.handle), e.window_id);
    try std.testing.expectEqual(e, mgr.lookup("main").?);
    try std.testing.expectEqual(e, mgr.lookupById(e.window_id).?);
    try std.testing.expectEqualStrings("main", mgr.labelFor(e.window_id).?);
}

test "duplicate label is rejected and creates no second seam window" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    defer mgr.deinit();
    _ = try mgr.create(.{ .label = "main", .url = "app://localhost/index.html" });
    try std.testing.expectError(error.LabelInUse, mgr.create(.{ .label = "main", .url = "app://localhost/index.html" }));
    try std.testing.expectEqual(@as(usize, 1), be.windows.items.len);
}

test "close destroys the seam window, frees the entry, decrements liveCount" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    defer mgr.deinit();
    const e = try mgr.create(.{ .label = "viewer", .url = "app://localhost/v" });
    const id = e.window_id;
    try mgr.close("viewer");
    try std.testing.expectEqual(@as(usize, 0), mgr.liveCount());
    try std.testing.expectEqual(@as(usize, 1), be.countEvents(.destroyed));
    try std.testing.expect(mgr.lookup("viewer") == null);
    try std.testing.expect(mgr.lookupById(id) == null);
}

test "ops on an unknown label return UnknownLabel and never touch the seam" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    defer mgr.deinit();
    try std.testing.expectError(error.UnknownLabel, mgr.focus("ghost"));
    try std.testing.expectError(error.UnknownLabel, mgr.setTitle("ghost", "x"));
    try std.testing.expectError(error.UnknownLabel, mgr.setSize("ghost", 10, 10));
    try std.testing.expectError(error.UnknownLabel, mgr.setFullscreen("ghost", true));
    try std.testing.expectError(error.UnknownLabel, mgr.close("ghost"));
}

test "op wrappers translate to the seam for a live window" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    defer mgr.deinit();
    const e = try mgr.create(.{ .label = "main", .url = "app://localhost/index.html" });
    try mgr.setTitle("main", "Report");
    try std.testing.expectEqualStrings("Report", be.windows.items[e.handle].title);
    try mgr.setSize("main", 1024, 768);
    try std.testing.expectEqual(@as(f64, 1024), be.windows.items[e.handle].width);
    try mgr.setFullscreen("main", true);
    try std.testing.expect(be.windows.items[e.handle].fullscreen);
}

// Fault-injection sweep over create. The backend AND the manager share the SAME
// allocator the harness injects, so a single failing index covers every
// allocation in create's path: the label dupe, the url/title dupeZ, the
// label-script Allocating writer, the seam createWindow's url/title/script
// dupes and list growth, the entry create, and both map puts. On every failing
// index create must return error.OutOfMemory and leave nothing allocated; on
// the success run the entry is created. Teardown (mgr.deinit, then
// be.markJoined + be.deinit) only frees, so it never trips the stuck allocator,
// and create's no-op destroyWindow means the backend's own dupes are reclaimed
// by be.deinit (not a leak). `be`'s `try` sits above its defer, so a fail on
// the very first alloc (the backend struct) returns with nothing registered.
fn createOomAttempt(alloc: std.mem.Allocator) !void {
    const be = try NullBackend.init(alloc, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = WindowManager(NullBackend).init(alloc, be, std.testing.io);
    defer mgr.deinit();
    const e = try mgr.create(.{ .label = "main", .url = "app://localhost/index.html", .title = "Main" });
    // Reached only on the leak-free success run the harness ends with.
    try std.testing.expectEqualStrings("main", e.label);
    try std.testing.expectEqual(@as(usize, 1), mgr.liveCount());
}

test "create under checkAllAllocationFailures: every alloc-failure path leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createOomAttempt, .{});
}
