const std = @import("std");
const backend_mod = @import("platform/backend.zig");
const assets = @import("assets.zig");
const Bridge = @import("bridge.zig").Bridge;
const builtin = @import("commands/builtin.zig");

const zigware_js = @embedFile("frontend/zigware.js");
const app_js = @embedFile("frontend/app.js");

/// A process-lifetime static the fail-closed sentinel callbacks read as their
/// ctx. It is never dereferenced as an App; it exists only so the sentinel ctx
/// pointer is a valid, owned address rather than a dangling App.
// const, not var: its address is a unique opaque ctx pointer that the dead
// callbacks never dereference, and it can never be mutated (L2).
const dead_sentinel: u8 = 0;

/// The application orchestrator, generic over a platform backend `B`.
/// Constructs the one window with the bridge shim injected before the page
/// loads, wires the bridge, registers inbound callbacks, and runs the platform
/// loop. Tests instantiate App(NullBackend) and drive it with the backend's
/// simulate* methods.
///
/// Lifecycle contract: `shutdown` (and `deinit`) are INFALLIBLE. Any future
/// fallible cleanup goes through a separate `flush()` before deinit (M18).
pub fn App(comptime B: type) type {
    backend_mod.assertBackend(B);
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        io: std.Io,
        backend: *B,
        bridge: *Bridge(B),
        window: B.WindowHandle,
        shutdown_done: std.atomic.Value(bool) = .init(false),
        /// The single app State injected into every command handler. A field, not
        /// an init-scope local, so its address is stable for the bridge's life.
        state: builtin.State = .{},

        pub fn init(alloc: std.mem.Allocator, io: std.Io, backend: *B) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);

            // v0.1.0 hardcodes the prod URL; F (dev server) and D (manifest)
            // will move URL selection into init options so it flips by build mode.
            const window = try backend.createWindow(.{
                .url = "app://localhost/index.html",
                .user_scripts = &.{ zigware_js, app_js },
            });
            // If a later init step fails, tear the window back down (M12).
            // destroyWindow must be safe on a window whose webview/handler were
            // wired but whose App never finished init.
            errdefer backend.destroyWindow(window);

            // &self.state is a valid, stable address right after alloc.create; the
            // value is written by the self.* literal below before any message can
            // arrive, so the bridge never reads it early.
            const bridge = try Bridge(B).init(
                alloc,
                io,
                backend,
                window,
                builtin.State,
                builtin.Commands,
                &self.state,
                .{},
            );
            errdefer bridge.deinit();

            self.* = .{
                .alloc = alloc,
                .io = io,
                .backend = backend,
                .bridge = bridge,
                .window = window,
                .state = .{},
            };

            backend.setCallbacks(.{
                .ctx = self,
                .onSchemeRequest = onSchemeRequest,
                .onMessage = onMessage,
                .onLifecycle = onLifecycle,
                .onNavigation = onNavigation,
            });

            return self;
        }

        /// Deinit order is documented in main.zig: app.deinit() runs before
        /// backend.deinit() (LIFO). deinit does NOT touch the backend after
        /// shutdown; it only frees the App allocation, so the order is safe.
        pub fn deinit(self: *Self) void {
            self.shutdown();
            self.alloc.destroy(self);
        }

        /// Ordered, exactly-once, infallible shutdown:
        ///   1. terminate the backend (queued evals drop on pump),
        ///   2. install the fail-closed sentinel callbacks FIRST, so any inbound
        ///      IMP that fires during the join/drain window (delayed scheme task,
        ///      queued message, late lifecycle) hits the sentinel rather than the
        ///      bridge that is mid-teardown or the App that is about to be freed
        ///      (B3, M14),
        ///   3. join the worker pool by deiniting the bridge,
        ///   4. drain the main-thread queue.
        /// Idempotent via an atomic swap so concurrent will_terminate + deinit
        /// run the body exactly once (M5).
        fn shutdown(self: *Self) void {
            if (self.shutdown_done.swap(true, .acq_rel)) return;
            // Step order is load-bearing: the sentinel must be installed before
            // bridge.deinit/join so inbound IMPs during the drain hit the
            // sentinel, not torn-down state. Guarded indirectly by the M5/B3
            // tests and the leak detector.
            self.backend.terminate();
            self.backend.setCallbacks(deadCallbacks()); // sentinel live during the drain (M14)
            self.bridge.deinit(); // joins the worker pool
            self.backend.markJoined(); // App owns the join handshake: every
            // App(B) teardown satisfies backend.deinit's joined assert without
            // per-test markJoined. Bridge-only tests (TestBridge) call it manually.
            self.backend.pumpMain();
        }

        pub fn run(self: *Self) void {
            self.backend.run();
        }

        /// Fail-closed callback set installed after shutdown. ctx is the static
        /// dead_sentinel, never an App. Scheme -> 404, message/lifecycle no-op,
        /// navigation -> cancel.
        fn deadCallbacks() backend_mod.Callbacks {
            return .{
                .ctx = @constCast(&dead_sentinel), // ctx is *anyopaque; sentinel is never dereferenced
                .onSchemeRequest = deadScheme,
                .onMessage = deadMessage,
                .onLifecycle = deadLifecycle,
                .onNavigation = deadNavigation,
            };
        }

        fn deadScheme(_: *anyopaque, _: backend_mod.Request) backend_mod.Response {
            return .{ .status = 404, .mime = "text/plain", .body = "" };
        }
        fn deadMessage(_: *anyopaque, _: u64, _: []const u8, _: []const u8) void {}
        fn deadLifecycle(_: *anyopaque, _: backend_mod.LifecycleEvent) void {}
        fn deadNavigation(_: *anyopaque, _: []const u8) backend_mod.NavigationDecision {
            return .cancel;
        }

        // ── Inbound callbacks (C-free; plain fn ptrs over *anyopaque ctx) ──────

        /// A owns the asset scheme; B's stream scheme routes to the bridge's
        /// serveStream (out-of-band binary). The switch over Request.source is
        /// exhaustive at compile time over the 2-variant enum: a new source
        /// variant is a compile error here, not a silent runtime miss. The
        /// sentinel deadScheme still 404s every source during teardown (fail-closed).
        fn onSchemeRequest(ctx: *anyopaque, req: backend_mod.Request) backend_mod.Response {
            const self: *Self = @ptrCast(@alignCast(ctx));
            switch (req.source) {
                .asset_scheme => return assets.serveAsset(req.path),
                .stream_scheme => return self.bridge.serveStream(req.path),
            }
        }

        fn onMessage(ctx: *anyopaque, window_id: u64, origin: []const u8, text: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.bridge.handleMessage(window_id, origin, text);
        }

        /// Both window_all_closed and will_terminate run the FULL shutdown so a
        /// force-quit that never delivers will_terminate still joins workers (M5).
        fn onLifecycle(ctx: *anyopaque, event: backend_mod.LifecycleEvent) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            switch (event) {
                .window_all_closed, .will_terminate => self.shutdown(),
                .did_launch, .reopen => {},
            }
        }

        /// Deny-by-default (M6): allow only the app://localhost origin; cancel
        /// everything else. C tightens this to capability-aware per-origin
        /// policy. startsWith("app://") would let any host under the scheme
        /// through (app://evil/, app://localhost.attacker.com/), so we match the
        /// origin exactly: the localhost host followed by a path separator, or
        /// the bare origin with no path.
        fn onNavigation(_: *anyopaque, url: []const u8) backend_mod.NavigationDecision {
            if (std.mem.startsWith(u8, url, "app://localhost/") or
                std.mem.eql(u8, url, "app://localhost"))
            {
                return .allow;
            }
            return .cancel;
        }
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const NullBackend = @import("platform/null.zig").NullBackend;

fn makeApp() !struct { backend: *NullBackend, app: *App(NullBackend) } {
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    const app = try App(NullBackend).init(std.testing.allocator, std.testing.io, backend);
    return .{ .backend = backend, .app = app };
}

fn teardown(backend: *NullBackend, app: *App(NullBackend)) void {
    app.deinit(); // shutdown: terminate -> bridge.deinit (joins) -> pump -> sentinel
    backend.markJoined();
    backend.deinit();
}

test "end to end: simulated invoke resolves through the real pool into eval_log" {
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    const main_id = h.backend.windowId(h.app.window);
    h.backend.simulateMessage(main_id, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    h.app.bridge.drainForTest();
    h.backend.pumpMain();
    var buf: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "window.Zigware._resolve(1, ", .{});
    try std.testing.expectEqual(@as(usize, 1), h.backend.countContaining(needle));
}

test "scheme request routes through serveAsset" {
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    const ok = h.backend.simulateSchemeRequest("/index.html");
    try std.testing.expectEqual(@as(u16, 200), ok.status);
    const miss = h.backend.simulateSchemeRequest("/nope");
    try std.testing.expectEqual(@as(u16, 404), miss.status);
    const reserved = h.backend.simulateSchemeRequest("/__zigware_stream/1/0");
    try std.testing.expectEqual(@as(u16, 404), reserved.status);
}

test "a stream-scheme request for a non-stream path 404s via serveStream/parseStreamPath" {
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    // simulateSchemeRequestSource lets a test set Request.source explicitly.
    // .stream_scheme is no longer denied at the seam: it routes to serveStream,
    // which 404s here only because "/index.html" fails parseStreamPath.
    const r = h.backend.simulateSchemeRequestSource(.stream_scheme, "/index.html");
    try std.testing.expectEqual(@as(u16, 404), r.status);
}

test "stream scheme routes to the bridge serveStream (app path)" {
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    const main_id = h.backend.windowId(h.app.window);
    h.backend.simulateMessage(main_id, "app://localhost", "{\"id\":1,\"cmd\":\"echoBytes\",\"args\":{\"n\":4}}");
    h.app.bridge.drainForTest();
    h.backend.pumpMain();
    const r = h.backend.simulateSchemeRequestSource(.stream_scheme, "/__zigware_stream/1/0");
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqual(@as(usize, 4), r.body.len);
}

test "M6: navigation denies by default, allows only the app://localhost origin" {
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, h.backend.simulateNavigation("https://evil.example/"));
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, h.backend.simulateNavigation("javascript:alert(1)"));
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, h.backend.simulateNavigation("https://x/"));
    // A bare "app://" host other than localhost must not slip through.
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, h.backend.simulateNavigation("app://evil/"));
    // A host that merely begins with "localhost" is a different origin.
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, h.backend.simulateNavigation("app://localhost.attacker.com/"));
    // The scheme match is case-sensitive.
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, h.backend.simulateNavigation("APP://localhost/"));
    try std.testing.expectEqual(backend_mod.NavigationDecision.allow, h.backend.simulateNavigation("app://localhost/index.html"));
}

test "L10: window_all_closed runs full shutdown (observed via post-event message drop)" {
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    const main_id = h.backend.windowId(h.app.window);
    h.backend.simulateLifecycle(.window_all_closed); // full shutdown: joins + terminates
    // Observe the downstream effect rather than reading terminated directly (L10):
    // a message after shutdown delivers nothing.
    h.backend.simulateMessage(main_id, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    h.backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 0), h.backend.eval_log.items.len);
}

test "M5: window_all_closed WITHOUT will_terminate still joins the pool (no leak)" {
    // The teardown helper's markJoined + backend.deinit assert the pool joined.
    // If window_all_closed did not run the full shutdown, the bridge would not
    // be deinit'd and std.testing.allocator would flag a leak at test exit.
    const h = try makeApp();
    h.backend.simulateLifecycle(.window_all_closed);
    // No will_terminate. deinit's shutdown is a no-op (already done).
    teardown(h.backend, h.app);
}

test "windowId of the main window matches the inbound id" {
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    try std.testing.expectEqual(@as(u64, 0), h.backend.windowId(h.app.window));
}

test "ordered shutdown under load drops in-flight emissions cleanly" {
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    const main_id = h.backend.windowId(h.app.window);
    var i: u64 = 0;
    while (i < 50) : (i += 1) {
        var buf: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":1}}}}", .{i});
        h.backend.simulateMessage(main_id, "app://localhost", text);
    }
    h.backend.simulateLifecycle(.will_terminate); // App.shutdown joins workers and pumps
}

test "App.shutdown is exactly-once across deinit and lifecycle paths" {
    const h = try makeApp();
    h.backend.simulateLifecycle(.will_terminate); // first shutdown
    h.app.deinit(); // second shutdown; swap returns true, body no-ops
    h.backend.markJoined();
    h.backend.deinit();
}

test "B3: simulate* after shutdown reaches the fail-closed sentinel, never the App" {
    const h = try makeApp();
    h.backend.simulateLifecycle(.will_terminate); // shutdown installs the sentinel
    // These would crash if they reached the freed App; the sentinel + the
    // backend's terminated no-op make them safe.
    h.backend.simulateMessage(99, "app://localhost", "{\"id\":99,\"cmd\":\"sha256\",\"args\":{}}");
    const r = h.backend.simulateSchemeRequest("/index.html");
    try std.testing.expectEqual(@as(u16, 404), r.status); // sentinel returns 404
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, h.backend.simulateNavigation("app://localhost/x"));
    h.backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 0), h.backend.eval_log.items.len);
    h.app.deinit();
    h.backend.markJoined();
    h.backend.deinit();
}

test "inbound message after terminate is a no-op" {
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    const main_id = h.backend.windowId(h.app.window);
    h.backend.simulateLifecycle(.window_all_closed); // full shutdown
    h.backend.simulateMessage(main_id, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    h.backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 0), h.backend.eval_log.items.len);
}
