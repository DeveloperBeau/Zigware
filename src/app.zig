const std = @import("std");
const backend_mod = @import("platform/backend.zig");
const assets = @import("assets.zig");
const Bridge = @import("bridge.zig").Bridge;
const builtin = @import("commands/builtin.zig");
const security_cap = @import("security/capability.zig");
const security_grant = @import("security/grant_table.zig");
const security_defaults = @import("security/defaults.zig");
const security_gates = @import("security/gates.zig");
const security_navigation = @import("security/navigation.zig");
const manifest_types = @import("manifest/types.zig");
const parse = @import("manifest/parse.zig");
const window_manager = @import("window/manager.zig");
const window_lifecycle = @import("window/lifecycle.zig");
const window_commands = @import("window/commands.zig");
const D = manifest_types;
const WindowManager = window_manager.WindowManager;
const Lifecycle = window_lifecycle.Lifecycle;

// The bootstrap window now carries the manager-injected user-scripts (zigware.js
// + window.js + the per-window label constant); WindowManager.create owns those
// @embedFile injections, so app.zig no longer embeds the frontend JS itself.
// app.js (the PoC demo script) is intentionally NOT injected: the demo is rebuilt
// against real capabilities in a later sub-project, so E stops shipping it rather
// than letting the PoC demo constrain the window layer.

/// The shipping command surface registered with the bridge: every builtin demo
/// command plus the `window.*` namespace, composed via dotted decl names so the
/// registry registers each command under its decl name (e.g. `window.create`).
/// A builtin command dropped from this list is silently unregistered, so every
/// builtin.Commands decl (sha256, echoBytes, echo) is re-exported explicitly.
fn AppCommands(comptime B: type) type {
    const W = window_commands.WindowCommands(B);
    return struct {
        pub const sha256 = builtin.Commands.sha256;
        pub const echoBytes = builtin.Commands.echoBytes;
        pub const echo = builtin.Commands.echo;
        pub const @"window.create" = W.@"window.create";
        pub const @"window.close" = W.@"window.close";
        pub const @"window.focus" = W.@"window.focus";
        pub const @"window.setTitle" = W.@"window.setTitle";
        pub const @"window.setSize" = W.@"window.setSize";
        pub const @"window.setFullscreen" = W.@"window.setFullscreen";
    };
}

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
        /// The multi-window manager and quit-policy lifecycle, held BY VALUE so
        /// their addresses are stable for the App's life: the bridge holds a
        /// `*WindowManager(B)` into `manager`, and `lifecycle` holds a
        /// `*WindowManager(B)` into the same field.
        manager: WindowManager(B),
        lifecycle: Lifecycle(B),
        shutdown_done: std.atomic.Value(bool) = .init(false),
        /// The single app State injected into every command handler. A field, not
        /// an init-scope local, so its address is stable for the bridge's life.
        state: builtin.State = .{},

        /// C's capability state. The App compiles one immutable GrantTable at init
        /// and holds it for the app lifetime. `owns_grants` => deinit frees it
        /// (production owns it; a test that injects its own table may keep
        /// ownership). base_dir/bases are valid handles for the path scope engine;
        /// v0.1.0 commands are .none so they are unused live.
        grants: *security_grant.GrantTable,
        base_dir: std.Io.Dir,
        bases: security_gates.Bases,
        is_debug: bool,
        owns_grants: bool,

        /// Production entry: grants only core:default. The GUI sha256 demo is
        /// therefore denied at G2 (the demo is rebuilt with real capabilities in a
        /// later sub-project). D later replaces this with a manifest-parsed
        /// GrantTable + the real app-support base_dir; v0.1.0 commands are all
        /// .none so base_dir/bases are unused but must be valid handles.
        pub fn init(alloc: std.mem.Allocator, io: std.Io, backend: *B) !*Self {
            const manifest = parse.embedded();
            const windows = manifest.app.windows;

            // Collect the full label set so the GrantTable knows every window
            // label, and compile ONE capability covering all of them with
            // core:default (deny-by-default for cross-window manage; mirrors the
            // PoC's per-"main" grant generalized to N labels). One cap per label
            // set keeps scopeFor/originsFor at n<=1 matched cap per label.
            var labels_list: std.ArrayList([]const u8) = .empty;
            defer labels_list.deinit(alloc);
            for (windows) |w| try labels_list.append(alloc, w.label);
            const labels = labels_list.items;

            const app_caps = [_]security_cap.Capability{.{ .identifier = "app", .windows = labels, .permissions = &.{"core:default"} }};
            var diags: manifest_types.Diagnostics = .{};
            defer diags.deinit(alloc);
            const grants = try alloc.create(security_grant.GrantTable);
            errdefer alloc.destroy(grants);
            grants.* = try security_grant.GrantTable.compile(alloc, &app_caps, &security_defaults.builtin_catalog, .{}, labels, &diags);
            errdefer grants.deinit();
            const bases = security_gates.Bases{ .appdata = ".", .home = ".", .appconfig = "." };
            return initWithConfig(
                alloc,
                io,
                backend,
                grants,
                bases,
                std.Io.Dir.cwd(),
                (@import("builtin").mode == .Debug),
                true,
                windows,
                manifest.app.quitOnLastWindowClosed,
                manifest.app.windowShowFallbackMs,
            );
        }

        /// Shared init body. Constructs the window manager BY VALUE (stable
        /// address at `&self.manager`), creates every configured window through
        /// it (so each window carries the gate-chain user-scripts + window.js +
        /// its per-window label constant), wires the bridge to the manager, and
        /// builds the quit-policy lifecycle. `owns_grants` => deinit frees
        /// `grants`. On error this does NOT free `grants` — ownership transfers
        /// to the App only on success, so the caller's errdefer frees it once.
        ///
        /// `windows` is the manifest window list (at least one, label "main");
        /// `policy` and `fallback_ms` come from D's App config.
        pub fn initWithConfig(
            alloc: std.mem.Allocator,
            io: std.Io,
            backend: *B,
            grants: *security_grant.GrantTable,
            bases: security_gates.Bases,
            base_dir: std.Io.Dir,
            is_debug: bool,
            owns_grants: bool,
            windows: []const D.Window,
            policy: D.QuitPolicy,
            fallback_ms: u32,
        ) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);

            // Initialise the by-value fields whose addresses must be stable for
            // the App's life. The manager is constructed in place at
            // &self.manager so the watchdog ctx that create() spawns captures the
            // final manager address, not a temporary that would be memcpy'd away.
            // bridge/lifecycle are written below; nothing reads them before then.
            self.* = .{
                .alloc = alloc,
                .io = io,
                .backend = backend,
                .bridge = undefined,
                .manager = WindowManager(B).init(alloc, backend, io),
                .lifecycle = undefined,
                .state = .{},
                .grants = grants,
                .base_dir = base_dir,
                .bases = bases,
                .is_debug = is_debug,
                .owns_grants = owns_grants,
            };
            self.manager.fallback_ms = fallback_ms;
            // Free every created window (joining its watchdog) if a later step in
            // this init fails. closeAll is idempotent and safe before deinit.
            errdefer self.manager.deinit();

            // Create the configured windows through the manager. The first
            // window's handle seeds the bridge's pre-E fallback field; routing
            // always goes through the manager once setManager runs, so that
            // handle is never the actual reply target.
            var boot: ?B.WindowHandle = null;
            for (windows) |w| {
                const e = try self.manager.create(.{
                    .label = w.label,
                    .url = w.url,
                    .title = w.title,
                    .width = w.width,
                    .height = w.height,
                    .decorations = w.decorations,
                    .title_bar_style = w.titleBarStyle,
                    .show = w.show,
                });
                if (boot == null) boot = e.handle;
            }
            // D's validator guarantees at least one window (no_main_window), so
            // boot is always set on the production path; guard anyway so a test
            // passing an empty list fails loudly rather than dereferencing null.
            const boot_handle = boot orelse return error.NoWindows;

            // &self.state is a valid, stable address right after alloc.create; the
            // value was written by the self.* literal above before any message can
            // arrive, so the bridge never reads it early.
            const bridge = try Bridge(B).init(
                alloc,
                io,
                backend,
                boot_handle,
                builtin.State,
                AppCommands(B),
                &self.state,
                .{},
                grants,
                bases,
                base_dir,
                is_debug,
            );
            errdefer bridge.deinit();
            self.bridge = bridge;

            // Route every per-window emit/reply and the attested labelFor through
            // the manager. Done before setCallbacks so no inbound message is
            // dispatched before the manager is wired (labelFor fails closed for
            // unmapped ids under a wired manager).
            bridge.setManager(&self.manager);

            self.lifecycle = Lifecycle(B).init(backend, &self.manager, policy);

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
        ///   1. close every window + terminate the backend — but only if the
        ///      lifecycle did NOT already run the ordered shutdown (single owner:
        ///      a will_terminate / quit-policy window_all_closed already did
        ///      closeAll+terminate via Lifecycle.orderedShutdown; a bare deinit
        ///      under keep-running has not, so we do it here),
        ///   2. install the fail-closed sentinel callbacks, so any inbound IMP
        ///      that fires during the join/drain window (delayed scheme task,
        ///      queued message, late lifecycle) hits the sentinel rather than the
        ///      bridge that is mid-teardown or the App that is about to be freed
        ///      (B3, M14),
        ///   3. drain the main-thread queue AFTER closeAll: closeAll joins every
        ///      watchdog thread, but a watchdog that already hopped leaves a
        ///      queued fireMain on a real backend; pump it now, while the manager
        ///      is still alive, so it cannot dereference a freed manager,
        ///   4. join the worker pool by deiniting the bridge,
        ///   5. deinit the manager AFTER the pool join (no worker can touch the
        ///      maps once joined) and the post-closeAll pump.
        /// Idempotent via an atomic swap so concurrent will_terminate + deinit
        /// run the body exactly once (M5).
        fn shutdown(self: *Self) void {
            if (self.shutdown_done.swap(true, .acq_rel)) return;
            // Single ordered-shutdown owner: if the lifecycle already closed every
            // window and terminated, do not repeat it (closeAll/terminate are
            // idempotent, but keeping one owner makes the ordering obvious).
            if (!self.lifecycle.didTerminate()) {
                self.manager.closeAll(); // joins every watchdog thread
                self.backend.terminate();
            }
            self.backend.setCallbacks(deadCallbacks()); // sentinel live during the drain (M14)
            // Drain any fireMain a watchdog queued before it was joined, BEFORE
            // the manager is deinit'd, so the queued work sees a live manager.
            self.backend.pumpMain();
            self.bridge.deinit(); // joins the worker pool
            self.manager.deinit(); // free entries/maps after the pool join
            if (self.owns_grants) {
                self.grants.deinit();
                self.alloc.destroy(self.grants);
            }
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

        /// Route lifecycle through the quit-policy Lifecycle, then drive the App
        /// teardown off its terminate flag (single ordered-shutdown owner):
        ///   will_terminate     -> orderedShutdown (always) + App.shutdown,
        ///   window_all_closed   -> policy decides; shutdown only if it terminated
        ///                          (keep_running stays alive — E's macOS default),
        ///   reopen              -> policy handler (recreate the default window),
        ///   did_launch          -> nothing.
        fn onLifecycle(ctx: *anyopaque, event: backend_mod.LifecycleEvent) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            switch (event) {
                .will_terminate => {
                    self.lifecycle.handle(event);
                    self.shutdown();
                },
                .window_all_closed => {
                    self.lifecycle.handle(event); // policy decides terminate-or-stay
                    if (self.lifecycle.didTerminate()) self.shutdown();
                },
                .reopen => self.lifecycle.handle(event),
                .did_launch => {},
            }
        }

        /// Deny-by-default (M6): C's navigation guard allows only app://localhost
        /// (plus, in debug, this window's dev URL); everything else cancels. The
        /// dead-sentinel `deadNavigation` still returns `.cancel` during teardown
        /// (ctx is the sentinel, NOT an App, so it is never cast to *Self).
        fn onNavigation(ctx: *anyopaque, url: []const u8) backend_mod.NavigationDecision {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return security_navigation.decideNavigation(self.grants.originsFor("main"), url, self.is_debug);
        }
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const NullBackend = @import("platform/null.zig").NullBackend;
const fixtures = @import("security_test_fixtures.zig");

const dummy_bases = security_gates.Bases{ .appdata = "/tmp", .home = "/tmp", .appconfig = "/tmp" };

// The single bootstrap window the PoC hardcoded now lives in D config; the
// single-window tests reconstruct it as one `main` window with the
// quit_on_last_close policy so window_all_closed still shuts the app down
// (E's production default is keep_running_on_last_close, exercised by the
// multi-window tests below).
const single_window = [_]manifest_types.Window{.{ .label = "main", .url = "app://localhost/index.html", .title = "Zigware", .show = true }};

/// The App tests drive sha256/echoBytes through the bridge gate, so makeApp grants
/// the fixture commands (core:default alone denies them at G2). owns_grants=true:
/// the App frees the grants in deinit, so teardown must NOT free them again.
fn makeApp() !struct { backend: *NullBackend, app: *App(NullBackend) } {
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    const grants = try fixtures.buildTestGrants(std.testing.allocator);
    const app = App(NullBackend).initWithConfig(std.testing.allocator, std.testing.io, backend, grants, dummy_bases, std.Io.Dir.cwd(), false, true, &single_window, .quit_on_last_close, 5000) catch |err| {
        grants.deinit();
        std.testing.allocator.destroy(grants);
        return err;
    };
    return .{ .backend = backend, .app = app };
}

/// The attested id of the App's "main" window (replaces the removed single
/// `app.window` handle field; routing now goes through the manager).
fn mainId(app: *App(NullBackend)) u64 {
    return app.manager.lookup("main").?.window_id;
}

fn teardown(backend: *NullBackend, app: *App(NullBackend)) void {
    app.deinit(); // shutdown: closeAll -> pump -> bridge.deinit (joins) -> manager.deinit -> pump
    backend.markJoined();
    backend.deinit();
}

/// E multi-window App harness: builds an App via initWithConfig with two windows
/// ("main" + "viewer") and the given quit policy. Grants cover both labels via a
/// single capability. owns_grants=true: the App frees the grants in deinit.
fn makeAppMulti(policy: manifest_types.QuitPolicy) !struct { backend: *NullBackend, app: *App(NullBackend) } {
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    const grants = try buildAppGrantsMulti(std.testing.allocator);
    const windows = [_]manifest_types.Window{
        .{ .label = "main", .url = "app://localhost/index.html", .title = "Zigware", .show = true },
        .{ .label = "viewer", .url = "app://localhost/v", .title = "Viewer", .show = true },
    };
    const app = App(NullBackend).initWithConfig(std.testing.allocator, std.testing.io, backend, grants, dummy_bases, std.Io.Dir.cwd(), false, true, &windows, policy, 5000) catch |err| {
        grants.deinit();
        std.testing.allocator.destroy(grants);
        return err;
    };
    return .{ .backend = backend, .app = app };
}

fn teardownMulti(h: anytype) void {
    teardown(h.backend, h.app);
}

/// A GrantTable covering labels "main" and "viewer" with one capability (so
/// scopeFor/originsFor keep n<=1 matched cap per label), granting the fixture
/// commands with an app_scheme origin.
fn buildAppGrantsMulti(alloc: std.mem.Allocator) !*fixtures.GrantTable {
    const cap = @import("security/capability.zig");
    const gt = try alloc.create(fixtures.GrantTable);
    errdefer alloc.destroy(gt);
    var diags: manifest_types.Diagnostics = .{};
    defer diags.deinit(alloc);
    const caps = [_]cap.Capability{.{ .identifier = "test", .windows = &.{ "main", "viewer" }, .origins = &.{.app_scheme}, .permissions = &.{"test:default"} }};
    gt.* = try fixtures.GrantTable.compile(alloc, &caps, &fixtures.test_catalog, .{}, &.{ "main", "viewer" }, &diags);
    return gt;
}

test "end to end: simulated invoke resolves through the real pool into eval_log" {
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    const main_id = mainId(h.app);
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
    const main_id = mainId(h.app);
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
    // The PoC default (window_all_closed always quits) moved into D config; E's
    // production default is keep_running_on_last_close. makeApp pins
    // quit_on_last_close so window_all_closed still drives the full shutdown here.
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    const main_id = mainId(h.app);
    h.backend.simulateLifecycle(.window_all_closed); // quit_on_last_close: joins + terminates
    // Observe the downstream effect rather than reading terminated directly (L10):
    // a message after shutdown delivers nothing.
    h.backend.simulateMessage(main_id, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    h.backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 0), h.backend.eval_log.items.len);
}

test "M5: will_terminate joins the pool without a will_terminate->deinit double-shutdown leak" {
    // The teardown helper's markJoined + backend.deinit assert the pool joined.
    // will_terminate ALWAYS runs the full shutdown regardless of quit policy
    // (E's default is keep_running_on_last_close, under which window_all_closed
    // would NOT shut down), so it is the policy-independent join trigger. If the
    // shutdown did not run, the bridge would not be deinit'd and the testing
    // allocator would flag a leak at test exit.
    const h = try makeApp();
    h.backend.simulateLifecycle(.will_terminate);
    // deinit's shutdown is a no-op (already done via the lifecycle path).
    teardown(h.backend, h.app);
}

test "windowId of the main window matches the inbound id" {
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    try std.testing.expectEqual(@as(u64, 0), mainId(h.app));
}

test "ordered shutdown under load drops in-flight emissions cleanly" {
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    const main_id = mainId(h.app);
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
    const main_id = mainId(h.app);
    h.backend.simulateLifecycle(.window_all_closed); // full shutdown
    h.backend.simulateMessage(main_id, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    h.backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 0), h.backend.eval_log.items.len);
}

test "E: app creates the configured windows and applies keep-running policy" {
    const h = try makeAppMulti(.keep_running_on_last_close);
    defer teardownMulti(h);
    try std.testing.expectEqual(@as(usize, 2), h.backend.countEvents(.created));
    h.backend.simulateLifecycle(.window_all_closed);
    // keep_running_on_last_close: the last window closing does NOT terminate.
    try std.testing.expectEqual(@as(usize, 0), h.backend.countEvents(.terminated));
}

test "E: quit_on_last_close terminates on window_all_closed" {
    const h = try makeAppMulti(.quit_on_last_close);
    defer teardownMulti(h);
    h.backend.simulateLifecycle(.window_all_closed);
    try std.testing.expectEqual(@as(usize, 1), h.backend.countEvents(.terminated));
}

test "E: each configured label routes its own invoke reply" {
    const h = try makeAppMulti(.keep_running_on_last_close);
    defer teardownMulti(h);
    const viewer_id = h.app.manager.lookup("viewer").?.window_id;
    h.backend.simulateMessage(viewer_id, "app://localhost", "{\"id\":3,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    h.app.bridge.drainForTest();
    h.backend.pumpMain();
    // The resolve must land on the viewer window, not main.
    try std.testing.expectEqual(@as(usize, 1), h.backend.countResolveExactly(3));
    for (h.backend.eval_log.items) |e| {
        if (std.mem.indexOf(u8, e.js, "_resolve(3, ") != null)
            try std.testing.expectEqual(viewer_id, e.window_id);
    }
}
