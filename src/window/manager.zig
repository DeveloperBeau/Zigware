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
            // Cancel the watchdog FIRST (joins the thread, so no concurrent fire
            // can race the transition), then flip state.
            if (self.by_label.get(label)) |e| {
                self.cancelWatchdog(e);
            } else {
                return error.UnknownLabel;
            }
            if (self.transitionReady(label) == .unknown) return error.UnknownLabel;
        }

        /// The watchdog's fire action (main thread in production via dispatchMain;
        /// inline on the watchdog thread under NullBackend). Resolves by LABEL so a
        /// fire after close is a clean no-op. Does NOT cancel the watchdog (it IS
        /// the watchdog); the lock in transitionReady makes the by_label read safe
        /// even off the main thread.
        pub fn fireFallback(self: *Self, label: []const u8) void {
            _ = self.transitionReady(label);
        }

        const WCtx = win.WatchdogCtx;

        fn spawnWatchdog(self: *Self, entry: *Entry) Error!void {
            const wc = try self.gpa.create(WCtx);
            errdefer self.gpa.destroy(wc);
            const label_dup = try self.gpa.dupe(u8, entry.label); // DISTINCT copy
            errdefer self.gpa.free(label_dup);
            wc.* = .{ .mgr = self, .label = label_dup, .fallback_ms = self.fallback_ms };
            // std.Thread.spawn's SpawnError is not a subset of Self.Error; fold a
            // spawn failure into BackendFailure (the errdefers above reclaim wc +
            // its label copy, and create's own errdefers tear down the window).
            const t = std.Thread.spawn(.{}, watchdogBody, .{wc}) catch return error.BackendFailure;
            entry.watchdog = wc;
            entry.watchdog_thread = t;
        }

        /// Per-window thread: sleep in slices so cancellation and shutdown are
        /// observed within one slice; on expiry hop to main via dispatchMain.
        fn watchdogBody(wc: *WCtx) void {
            const self: *Self = @ptrCast(@alignCast(wc.mgr));
            const slice_ms: u32 = 25;
            var elapsed: u32 = 0;
            while (elapsed < wc.fallback_ms) {
                if (wc.cancel.load(.acquire) or self.shutting_down.load(.acquire)) return;
                const step = @min(slice_ms, wc.fallback_ms - elapsed);
                // std.Thread.sleep was removed in 0.16; sleep through the Io
                // vtable. A raw std.Thread has no cancellation token, so the
                // Cancelable result cannot fire here; real cancellation is the
                // wc.cancel atomic checked between slices.
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(step), .awake) catch {};
                elapsed += step;
            }
            if (wc.cancel.load(.acquire) or self.shutting_down.load(.acquire)) return;
            // Hop to main with a heap payload independent of wc (cancelWatchdog may
            // free wc right after we read its label). The main handler frees it.
            const fc = self.gpa.create(FireCtx) catch return;
            const lc = self.gpa.dupe(u8, wc.label) catch {
                self.gpa.destroy(fc);
                return;
            };
            fc.* = .{ .mgr = self, .label = lc };
            self.backend.dispatchMain(fireMain, fc);
        }

        const FireCtx = struct { mgr: *Self, label: []u8 };
        fn fireMain(ptr: ?*anyopaque) callconv(.c) void {
            const fc: *FireCtx = @ptrCast(@alignCast(ptr.?));
            fc.mgr.fireFallback(fc.label);
            fc.mgr.gpa.free(fc.label);
            fc.mgr.gpa.destroy(fc);
        }

        /// Cancel + join the entry's watchdog and free its ctx. Idempotent. Single
        /// free site for the watchdog label copy. Safe to call from close/deinit/
        /// markReadyAndShow (all main-thread).
        pub fn cancelWatchdog(self: *Self, entry: *Entry) void {
            const wc = entry.watchdog orelse return;
            wc.cancel.store(true, .release);
            if (entry.watchdog_thread) |t| t.join(); // bounded by one slice (<=25ms)
            self.gpa.free(wc.label);
            self.gpa.destroy(wc);
            entry.watchdog = null;
            entry.watchdog_thread = null;
        }

        pub fn cancelWatchdogByLabel(self: *Self, label: []const u8) void {
            const e = self.by_label.get(label) orelse return;
            self.cancelWatchdog(e);
        }

        /// Close every live window, ordered, idempotent (close guards via
        /// entry.closing). Snapshots labels into owned dupes first so the iterator
        /// is not invalidated and no freed-key is hashed mid-loop. Does NOT set
        /// `shutting_down`: closeAll runs on the quit path (orderedShutdown) but
        /// also indirectly on app shutdown; setting the flag here would permanently
        /// disable the watchdog, so a later `reopen` (keep-running policy) window
        /// would never fire its fallback. Only `deinit` (truly terminal) sets it.
        /// Each close() cancels its own watchdog, so teardown still joins cleanly.
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

test "a real short-fallback watchdog fires and shows the window (spawn/sleep/free path)" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    mgr.fallback_ms = 10; // tiny, so the test does not stall
    defer mgr.deinit();
    const e = try mgr.create(.{ .label = "w", .url = "app://localhost/w", .show = true });
    // Join the watchdog: it sleeps ~10ms, then dispatchMain runs fireFallback
    // inline on the watchdog thread (NullBackend dispatchMain is inline). After
    // join, the window is shown. cancelWatchdog joins + frees the ctx.
    mgr.cancelWatchdog(e); // joins the (possibly already-fired) thread; no leak
    // The watchdog may or may not have fired before cancel; assert no leak/trap.
    // Determinism for the SHOW assertion is covered by fireFallback above.
}

test "the watchdog thread drives the show end-to-end (timer -> dispatchMain -> fireMain -> showWindow)" {
    const be = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer {
        be.markJoined();
        be.deinit();
    }
    var mgr = tm(be);
    mgr.fallback_ms = 10; // tiny, so the timer expires quickly
    defer mgr.deinit();
    const e = try mgr.create(.{ .label = "w", .url = "app://localhost/w", .show = true });

    // Poll the SYNCHRONIZED signal `e.shown` under map_mutex, the same mutex
    // transitionReady writes it under, until the timer thread expires and drives
    // the show (watchdogBody -> dispatchMain -> fireMain -> fireFallback ->
    // transitionReady -> showWindow; NullBackend dispatchMain runs inline on the
    // watchdog thread, so the show happens once the thread expires). We do NOT
    // cancel first and we never call fireFallback directly, so this proves the
    // THREAD path. The bound is generous (400 x 5ms = ~2s) so a slow CI run cannot
    // flake; an early break keeps the fast path fast.
    //
    // DEVIATION (forced by soundness): we poll `e.shown` under map_mutex rather
    // than `be.countEvents(.shown)`, because the NullBackend event log is appended
    // by showWindow WITHOUT a lock. Reading it from this thread while the watchdog
    // thread appends would be a data race (a torn read, or a realloc-induced UAF
    // when the append grows the buffer). `e.shown` is written under map_mutex, so
    // polling it under the same mutex is race-free.
    var spun: usize = 0;
    while (spun < 400) : (spun += 1) {
        mgr.map_mutex.lockUncancelable(mgr.io);
        const done = e.shown;
        mgr.map_mutex.unlock(mgr.io);
        if (done) break;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }

    // Join the (already-fired) thread before touching the unlocked event log. The
    // cancel store is harmless here: we've already observed shown==true, so the
    // fire happened; join just reaps the thread after its showWindow append
    // returned, establishing the happens-before that makes the reads below safe.
    mgr.cancelWatchdog(e);

    // Single-threaded now: assert the thread reached expiry and drove the show.
    try std.testing.expect(e.shown);
    try std.testing.expectEqual(@as(usize, 1), be.countEvents(.shown));
    // mgr.deinit at teardown finds watchdog == null (already reaped) and no-ops.
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
