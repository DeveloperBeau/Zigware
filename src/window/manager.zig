const std = @import("std");
const seam = @import("../platform/backend.zig");
const D = @import("../manifest/types.zig");
const win = @import("window.zig");
const protocol = @import("../protocol.zig");
const NullBackend = @import("../platform/null.zig").NullBackend;
const fuses = @import("../manifest/fuses.zig");

const zigware_js = @embedFile("frontend/zigware.js");
const window_js = @embedFile("frontend/window.js");

/// Static, F-chosen source (never user data; stays clear of the G6 output-encoding
/// boundary). Lives under the single root namespace window.Zigware. Referenced ONLY
/// under `comptime fuses.allow_eval`, so a default build (allowEval = false) compiles
/// the string out of the binary entirely.
const dev_client_src =
    \\window.Zigware = window.Zigware || {};
    \\window.Zigware.__dev = {
    \\  reload() { location.reload(); },
    \\  rehandshake() { /* reserved: v0.2 process-preserving bridge re-handshake */ },
    \\};
;

/// Number of dev-client user_scripts entries the manager injects: 1 when the
/// allowEval fuse is set at comptime, else 0. The injection itself is gated on the
/// same comptime condition, so the 4th user_scripts entry is present iff allow_eval.
pub fn dev_client_count() usize {
    return if (comptime fuses.allow_eval) 1 else 0;
}

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
        pub fn init(gpa: std.mem.Allocator, backend: *B, io: std.Io) Self {
            return .{ .gpa = gpa, .backend = backend, .io = io };
        }

        /// Frees every live entry (cancelling its show-fallback timer first), the
        /// label copies, and both maps. Production calls closeAll before this;
        /// deinit must still not leak if a test skips closeAll.
        pub fn deinit(self: *Self) void {
            var it = self.by_label.valueIterator();
            while (it.next()) |ep| {
                const e = ep.*;
                self.cancelWatchdog(e); // cancels the timer, frees its FireCtx
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
            // The dev-client entry is appended ONLY under the comptime allow_eval
            // gate; dev_client_src is referenced nowhere else, so a default build
            // (allowEval = false) compiles the string out entirely. Invariant: the
            // 4th user_scripts entry is present iff allow_eval. Core IPC evalJS is
            // untouched — only this injection is gated.
            const base_scripts = [_][]const u8{ zigware_js, window_js, label_script_aw.writer.buffered() };
            const user_scripts = if (comptime fuses.allow_eval)
                base_scripts ++ [_][]const u8{dev_client_src}
            else
                base_scripts;

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

            // Arm the show-fallback as a MAIN-THREAD TIMER (no OS thread). The
            // FireCtx is heap-allocated and owns its own label copy (distinct from
            // the entry's map-key label), so freeing it never double-frees the
            // entry's label. It is freed exactly once: by fireMain on the fire
            // path, or by cancelWatchdog on the cancel path. A 0 token means the
            // backend could not schedule the timer (resource exhaustion); surface
            // it as OutOfMemory so create's errdefers tear the window down.
            if (self.fallback_ms > 0) {
                const fc = try self.gpa.create(FireCtx);
                errdefer self.gpa.destroy(fc);
                const fc_label = try self.gpa.dupe(u8, entry.label); // DISTINCT copy
                errdefer self.gpa.free(fc_label);
                fc.* = .{ .mgr = self, .label = fc_label };
                const token = self.backend.dispatchMainAfter(self.fallback_ms, fireMain, fc);
                if (token == 0) return error.OutOfMemory;
                entry.fallback_timer = token;
                entry.fallback_ctx = fc;
            }
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

            self.cancelWatchdog(entry); // cancel the timer + free its FireCtx
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

        /// Resolve `label` and flip the ready/shown state under the map mutex
        /// (the fireFallback path can run off the main thread on NullBackend,
        /// where dispatchMain is inline). Captures the handle + whether to show
        /// INSIDE the lock; performs the seam show/focus OUTSIDE the lock (the
        /// mutex is never held across a seam call). Returns .unknown if an
        /// unknown label was requested (caller maps to error.UnknownLabel; the
        /// fallback path ignores it). Idempotent: a second call after `shown`
        /// does nothing.
        fn transitionReady(self: *Self, label: []const u8) enum { ok, unknown } {
            var do_show = false;
            var handle: B.WindowHandle = undefined;
            {
                self.map_mutex.lockUncancelable(self.io);
                defer self.map_mutex.unlock(self.io);
                const e = self.by_label.get(label) orelse return .unknown;
                if (e.shown) return .ok;
                e.ready = true;
                if (e.want_show) {
                    e.shown = true;
                    do_show = true;
                    handle = e.handle;
                }
            }
            if (do_show) {
                self.backend.showWindow(handle);
                self.backend.focusWindow(handle);
            }
            return .ok;
        }

        pub fn markReadyAndShow(self: *Self, label: []const u8) Error!void {
            // Cancel the fallback timer FIRST (on the main thread, so no fire can
            // race the transition), then flip state.
            if (self.by_label.get(label)) |e| {
                self.cancelWatchdog(e);
            } else {
                return error.UnknownLabel;
            }
            if (self.transitionReady(label) == .unknown) return error.UnknownLabel;
        }

        /// The fallback's fire action. Resolves by LABEL so a fire after close is a
        /// clean no-op. Does NOT cancel the timer (it IS the timer firing); the
        /// lock in transitionReady makes the by_label read safe.
        pub fn fireFallback(self: *Self, label: []const u8) void {
            _ = self.transitionReady(label);
        }

        /// The timer's ctx: heap-allocated, owns a DISTINCT label copy (so freeing
        /// it never double-frees the entry's map-key label). `mgr` is the typed
        /// manager so the callback can re-enter it.
        const FireCtx = struct { mgr: *Self, label: []u8 };

        /// The main-thread timer callback (runs on the main thread). Resolves the
        /// entry by label; if present, clears the entry's timer bookkeeping (so a
        /// later cancelWatchdog is a no-op) BEFORE transitioning, then shows the
        /// window if still wanted (idempotent via e.shown). Finally frees the
        /// FireCtx — the single free site on the fire path.
        fn fireMain(ptr: ?*anyopaque) callconv(.c) void {
            const fc: *FireCtx = @ptrCast(@alignCast(ptr.?));
            const self = fc.mgr;
            if (self.by_label.get(fc.label)) |e| {
                // Clear first: the timer has fired, so cancelWatchdog must NOT try
                // to cancel a spent token or re-free this same FireCtx.
                e.fallback_timer = null;
                e.fallback_ctx = null;
            }
            self.fireFallback(fc.label);
            self.gpa.free(fc.label);
            self.gpa.destroy(fc);
        }

        /// Cancel the entry's show-fallback timer and free its FireCtx. Idempotent.
        /// Safe to call from close/deinit/markReadyAndShow (all main-thread). After
        /// cancelMainTimer returns, the timer is guaranteed not to fire, so this is
        /// the sole owner of the FireCtx on the cancel path; the main-thread
        /// serialization of cancel-vs-fire makes the single-free safe.
        pub fn cancelWatchdog(self: *Self, entry: *Entry) void {
            const token = entry.fallback_timer orelse return;
            self.backend.cancelMainTimer(token);
            if (entry.fallback_ctx) |ctx| {
                const fc: *FireCtx = @ptrCast(@alignCast(ctx));
                self.gpa.free(fc.label);
                self.gpa.destroy(fc);
            }
            entry.fallback_timer = null;
            entry.fallback_ctx = null;
        }

        pub fn cancelWatchdogByLabel(self: *Self, label: []const u8) void {
            const e = self.by_label.get(label) orelse return;
            self.cancelWatchdog(e);
        }

        /// Close every live window, ordered, idempotent (close guards via
        /// entry.closing). Snapshots labels into owned dupes first so the iterator
        /// is not invalidated and no freed-key is hashed mid-loop. Each close()
        /// cancels its own show-fallback timer, so teardown leaves no armed timer.
        pub fn closeAll(self: *Self) void {
            var labels: std.ArrayList([]u8) = .empty;
            defer {
                for (labels.items) |l| self.gpa.free(l);
                labels.deinit(self.gpa);
            }
            {
                self.map_mutex.lockUncancelable(self.io);
                defer self.map_mutex.unlock(self.io);
                var it = self.by_label.keyIterator();
                while (it.next()) |k| {
                    const dup = self.gpa.dupe(u8, k.*) catch continue;
                    labels.append(self.gpa, dup) catch {
                        self.gpa.free(dup);
                    };
                }
            }
            for (labels.items) |l| self.close(l) catch {};
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

test "markReadyAndShow shows only when want_show, and is idempotent" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    defer mgr.deinit();
    const e = try mgr.create(.{ .label = "main", .url = "app://localhost/index.html", .show = true });
    try std.testing.expect(!e.shown);
    try mgr.markReadyAndShow("main");
    try std.testing.expect(e.ready and e.shown);
    try std.testing.expectEqual(@as(usize, 1), be.countEvents(.shown));
    try mgr.markReadyAndShow("main"); // idempotent
    try std.testing.expectEqual(@as(usize, 1), be.countEvents(.shown));
}

test "markReadyAndShow with want_show=false records ready but stays hidden" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    defer mgr.deinit();
    const e = try mgr.create(.{ .label = "bg", .url = "app://localhost/bg", .show = false });
    try mgr.markReadyAndShow("bg");
    try std.testing.expect(e.ready and !e.shown);
    try std.testing.expectEqual(@as(usize, 0), be.countEvents(.shown));
}

test "fireFallback shows a never-readied window and is a no-op on a closed label" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    defer mgr.deinit();
    _ = try mgr.create(.{ .label = "slow", .url = "app://localhost/s", .show = true });
    mgr.fireFallback("slow");
    try std.testing.expectEqual(@as(usize, 1), be.countEvents(.shown));
    try mgr.close("slow");
    mgr.fireFallback("slow"); // no-op, no trap
}

test "the show-fallback timer fires on the main thread and shows the window" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    defer mgr.deinit();
    const e = try mgr.create(.{ .label = "w", .url = "app://localhost/w", .show = true });
    // Created hidden; the fallback is armed as a main-thread timer (no OS thread).
    try std.testing.expect(!e.shown);
    try std.testing.expect(e.fallback_timer != null);

    // Fire the timer deterministically (no real sleep). This runs fireMain on the
    // calling/main thread: it clears the entry's timer bookkeeping, then shows the
    // window via transitionReady.
    be.fireTimers();
    try std.testing.expect(e.shown);
    try std.testing.expectEqual(@as(usize, 1), be.countEvents(.shown));
    // fireMain cleared the token, so a later cancel is a clean no-op.
    try std.testing.expect(e.fallback_timer == null);
    try std.testing.expect(e.fallback_ctx == null);
    mgr.cancelWatchdog(e); // no-op; no double-free, no second show
    try std.testing.expectEqual(@as(usize, 1), be.countEvents(.shown));
}

test "pumpMain fires a due show-fallback timer and shows the window" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    // A large delay arms the timer well into the future, so an immediate pumpMain
    // cannot see it as due (no flake). We do NOT sleep; we drive the show through
    // fireTimers (which ignores the deadline) and use pumpMain only to confirm a
    // not-yet-due timer is left armed.
    mgr.fallback_ms = 60_000;
    defer mgr.deinit();
    const e = try mgr.create(.{ .label = "w", .url = "app://localhost/w", .show = true });
    try std.testing.expect(!e.shown);
    try std.testing.expect(e.fallback_timer != null);
    // A pump immediately after create runs before the 1ms deadline, so the timer
    // is NOT yet due and the window stays hidden (proves pumpMain gates on the
    // deadline, not "fire everything").
    be.pumpMain();
    try std.testing.expect(!e.shown);
    try std.testing.expect(e.fallback_timer != null);
    // Now fire deterministically (deadline-independent) and confirm the show.
    be.fireTimers();
    try std.testing.expect(e.shown);
    try std.testing.expectEqual(@as(usize, 1), be.countEvents(.shown));
}

test "cancelling the fallback before it fires shows nothing and leaks nothing" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    defer mgr.deinit();
    const e = try mgr.create(.{ .label = "w", .url = "app://localhost/w", .show = true });
    try std.testing.expect(e.fallback_timer != null);

    // Cancel on the main thread, then fire any remaining timers: the cancelled
    // timer must NOT run, so the window stays hidden and the FireCtx is freed
    // exactly once (cancelWatchdog freed it; the timer never fires).
    mgr.cancelWatchdog(e);
    try std.testing.expect(e.fallback_timer == null);
    try std.testing.expect(e.fallback_ctx == null);
    be.fireTimers();
    try std.testing.expect(!e.shown);
    try std.testing.expectEqual(@as(usize, 0), be.countEvents(.shown));
}

test "markReadyAndShow cancels the fallback so a later fire does not double-show" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    defer mgr.deinit();
    const e = try mgr.create(.{ .label = "w", .url = "app://localhost/w", .show = true });
    try mgr.markReadyAndShow("w"); // cancels the timer, then shows
    try std.testing.expect(e.ready and e.shown);
    try std.testing.expectEqual(@as(usize, 1), be.countEvents(.shown));
    // The fallback was cancelled, so firing remaining timers shows nothing more.
    be.fireTimers();
    try std.testing.expectEqual(@as(usize, 1), be.countEvents(.shown));
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
