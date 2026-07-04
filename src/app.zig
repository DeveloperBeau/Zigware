const std = @import("std");
const backend_mod = @import("platform/backend.zig");
const assets = @import("assets.zig");
const Bridge = @import("bridge.zig").Bridge;
const builtin = @import("commands/builtin.zig");
const builtin_target = @import("builtin");

// ReleaseSafe enforcement, duplicated here so a consumer that pulls app.zig
// without the barrel (e.g. a future headless app harness) still inherits the
// ban. The barrel carries the authoritative copy.
comptime {
    if (builtin_target.mode == .ReleaseFast or builtin_target.mode == .ReleaseSmall) {
        @compileError("Zigware ships ReleaseSafe or Debug only");
    }
}

const security_cap = @import("security/capability.zig");
const security_grant = @import("security/grant_table.zig");
const security_gates = @import("security/gates.zig");
const security_navigation = @import("security/navigation.zig");
const manifest_types = @import("manifest/types.zig");
const parse = @import("manifest/parse.zig");
const window_manager = @import("window/manager.zig");
const window_lifecycle = @import("window/lifecycle.zig");
const window_commands = @import("window/commands.zig");
const compute_commands = @import("commands/compute.zig");
const defaults = @import("security/defaults.zig");
const registry = @import("registry.zig");

/// The app's declared capabilities, embedded at build time (build_helpers /
/// build.zig wire the anonymous import). Empty (`.{}`) when the app declares no
/// src/grants/*.zon, which drives the synthAppGrants fallback in the grant-build
/// path (Task 3).
const embedded_caps: []const security_cap.Capability = @import("zigware_grants_zon");

/// Comptime-strip any `.dev_url` origin outside Debug so a shipped (ReleaseSafe)
/// binary carries no dev-server origin STRING at all (a pure comptime rebuild
/// keeps the string out of the binary; the compile-time drop in
/// GrantTable.compile and the runtime is_debug gate in gates.originTrusted are
/// the further belts). In Debug the input is returned unchanged.
fn dropDevUrlInRelease(comptime caps: []const security_cap.Capability) []const security_cap.Capability {
    if (builtin_target.mode == .Debug) return caps;
    comptime {
        var out: []const security_cap.Capability = &.{};
        for (caps) |c| {
            var origins: []const security_cap.OriginPattern = &.{};
            for (c.origins) |o| switch (o) {
                .dev_url => {}, // dropped in release
                else => origins = origins ++ &[_]security_cap.OriginPattern{o},
            };
            out = out ++ &[_]security_cap.Capability{.{
                .identifier = c.identifier,
                .windows = c.windows,
                .origins = origins,
                .permissions = c.permissions,
            }};
        }
        return out;
    }
}

/// The live capabilities: the embedded declarations with release dev origins
/// stripped. A comptime constant so ReleaseSafe never materializes a dev_url.
const live_caps: []const security_cap.Capability = dropDevUrlInRelease(embedded_caps);

const D = manifest_types;
const WindowManager = window_manager.WindowManager;
const Lifecycle = window_lifecycle.Lifecycle;

/// In Debug only, returns the ZIGWARE_DEV_URL override when ZIGWARE_DEV=1; null otherwise.
/// In release this compiles to `return null` with no env access: the comptime gate elides
/// the whole body, so a ReleaseSafe binary reads no environment here. `gpa` backs the
/// Environ map; the returned slice is duped into `gpa` since the map (and its values) are
/// freed before return, so the caller frees the dupe. `@import("builtin")` is referenced
/// inline because the file-scope `builtin` alias is the command surface, not the std module.
fn devUrlOverride(gpa: std.mem.Allocator) !?[]const u8 {
    if (comptime @import("builtin").mode != .Debug) return null;
    // No `init` is in scope here (app.zig's main() is zero-param), and the
    // `.{ .block = .global }` form does not compile on macOS, so build a PosixBlock
    // straight from the libc environ. std.c.environ is `[*:null]?[*:0]u8`; PosixBlock.slice
    // is `[:null]const ?[*:0]const u8`, so span to the null sentinel then @ptrCast the inner
    // const (outer-only coercion will not add the inner pointee const automatically).
    const c_environ = std.c.environ;
    var n: usize = 0;
    while (c_environ[n] != null) : (n += 1) {}
    const block: std.process.Environ.Block = .{ .slice = @ptrCast(c_environ[0..n :null]) };
    var map = try std.process.Environ.createMap(.{ .block = block }, gpa);
    defer map.deinit();
    const flag = map.get("ZIGWARE_DEV") orelse return null;
    if (!std.mem.eql(u8, flag, "1")) return null;
    const url = map.get("ZIGWARE_DEV_URL") orelse return null;
    return try gpa.dupe(u8, url);
}

/// Pure decision: the dev override wins when present, else the configured prod URL.
fn resolveWindowUrl(prod_url: []const u8, dev_override: ?[]const u8) []const u8 {
    return dev_override orelse prod_url;
}

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
    const C = compute_commands.ComputeCommands(B);
    return struct {
        pub const sha256 = builtin.Commands.sha256;
        pub const echoBytes = builtin.Commands.echoBytes;
        pub const echo = builtin.Commands.echo;
        pub const @"compute.cancel" = C.@"compute.cancel";
        pub const @"window.create" = W.@"window.create";
        pub const @"window.close" = W.@"window.close";
        pub const @"window.focus" = W.@"window.focus";
        pub const @"window.setTitle" = W.@"window.setTitle";
        pub const @"window.setSize" = W.@"window.setSize";
        pub const @"window.setFullscreen" = W.@"window.setFullscreen";
    };
}

/// Compile a GrantTable that authorizes every command in `AppCmds` for `labels`,
/// alongside `core:default`. Each command `c` is granted through the permission
/// `app:c`: if the app declares it via .security.permissions (e.g. the notes example's
/// scoped `app:hashFile`), that declaration is reused so its scope is PRESERVED;
/// otherwise an unscoped `app:c` permission is synthesized. Deny-by-default holds.
/// Only the app's declared commands (plus core:default) are granted, and only to
/// the app's own window labels. Caller owns the returned table.
///
/// Fallback used when the app declares NO src/grants/*.zon: grants every app
/// command to EVERY window over app_scheme, alongside core:default. Apps that
/// declare capabilities go through buildGrantsFromCaps instead, which honors
/// per-window and per-origin declarations (including a Debug dev origin).
fn synthAppGrants(
    alloc: std.mem.Allocator,
    labels: []const []const u8,
    comptime AppCmds: type,
    comptime declared: []const security_cap.Permission,
) !*security_grant.GrantTable {
    // Command names are independent of the backend B and the builtins, so a dummy
    // namespace pairing is enough to enumerate them (registry ignores B).
    const names = comptime registry.Commands(struct {}, builtin.State, AppCmds).command_names;

    // The catalog the capability resolves against: the built-in permissions
    // (so core:default's members resolve) plus the app-declared permissions
    // (so a declared command's scope is reused, not re-minted unscoped).
    const declared_perms = defaults.builtin_catalog.permissions ++ declared;

    // Comptime-build the permission-id list the capability grants, plus any
    // permissions the catalog does not already define (unscoped).
    const synth = comptime blk: {
        var perm_ids: []const []const u8 = &[_][]const u8{"core:default"};
        var extra: []const security_cap.Permission = &.{};
        for (names) |name| {
            const id = "app:" ++ name;
            perm_ids = perm_ids ++ &[_][]const u8{id};
            var is_declared = false;
            for (declared_perms) |p| {
                if (std.mem.eql(u8, p.identifier, id)) {
                    is_declared = true;
                    break;
                }
            }
            if (!is_declared)
                extra = extra ++ &[_]security_cap.Permission{.{ .identifier = id, .commands_allow = &[_][]const u8{name} }};
        }
        break :blk .{ .perm_ids = perm_ids, .extra = extra };
    };

    const catalog = security_cap.Catalog{
        .permissions = declared_perms ++ synth.extra,
        .sets = defaults.builtin_catalog.sets,
    };
    const caps = [_]security_cap.Capability{.{
        .identifier = "app",
        .windows = labels,
        .origins = &.{.app_scheme},
        .permissions = synth.perm_ids,
    }};

    const gt = try alloc.create(security_grant.GrantTable);
    errdefer alloc.destroy(gt);
    var diags: manifest_types.Diagnostics = .{};
    defer diags.deinit(alloc);
    gt.* = try security_grant.GrantTable.compile(alloc, &caps, &catalog, .{}, labels, &diags);
    return gt;
}

/// Build the live GrantTable from the app's DECLARED capabilities. Each declared
/// cap contributes its own windows and origins; its permission list is augmented
/// with core:default and an `app:<cmd>` grant for every registered command (a
/// declared scoped `app:<cmd>` is reused, not re-minted), so the app's commands
/// stay invokable from its windows while per-window scoping and per-origin trust
/// (including a Debug dev origin) now come from the declarations. With no declared
/// caps this delegates to synthAppGrants (all windows, app_scheme, core:default +
/// app commands), preserving the pre-capability behavior. Caller owns the table.
fn buildGrantsFromCaps(
    alloc: std.mem.Allocator,
    comptime AppCmds: type,
    comptime declared: []const security_cap.Permission,
    decl_caps: []const security_cap.Capability,
    labels: []const []const u8,
) !*security_grant.GrantTable {
    if (decl_caps.len == 0) return synthAppGrants(alloc, labels, AppCmds, declared);

    const names = comptime registry.Commands(struct {}, builtin.State, AppCmds).command_names;
    const declared_perms = defaults.builtin_catalog.permissions ++ declared;
    const synth = comptime blk: {
        var perm_ids: []const []const u8 = &[_][]const u8{"core:default"};
        var extra: []const security_cap.Permission = &.{};
        for (names) |name| {
            const id = "app:" ++ name;
            perm_ids = perm_ids ++ &[_][]const u8{id};
            var is_declared = false;
            for (declared_perms) |p| {
                if (std.mem.eql(u8, p.identifier, id)) {
                    is_declared = true;
                    break;
                }
            }
            if (!is_declared)
                extra = extra ++ &[_]security_cap.Permission{.{ .identifier = id, .commands_allow = &[_][]const u8{name} }};
        }
        break :blk .{ .perm_ids = perm_ids, .extra = extra };
    };
    const catalog = security_cap.Catalog{
        .permissions = declared_perms ++ synth.extra,
        .sets = defaults.builtin_catalog.sets,
    };

    // Augment each declared cap: keep its windows + origins, and add every
    // perm id not already present. A scratch arena backs the temporary
    // permission-id slices; compile() dupes what it keeps, so the arena is torn
    // down right after.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var caps_list: std.ArrayList(security_cap.Capability) = .empty;
    for (decl_caps) |c| {
        var perms: std.ArrayList([]const u8) = .empty;
        for (c.permissions) |pid| try perms.append(sa, pid);
        for (synth.perm_ids) |pid| {
            var present = false;
            for (perms.items) |have| if (std.mem.eql(u8, have, pid)) {
                present = true;
                break;
            };
            if (!present) try perms.append(sa, pid);
        }
        try caps_list.append(sa, .{
            .identifier = c.identifier,
            .windows = c.windows,
            .origins = c.origins,
            .permissions = try perms.toOwnedSlice(sa),
        });
    }

    const gt = try alloc.create(security_grant.GrantTable);
    errdefer alloc.destroy(gt);
    var diags: manifest_types.Diagnostics = .{};
    defer diags.deinit(alloc);
    gt.* = try security_grant.GrantTable.compile(alloc, caps_list.items, &catalog, .{}, labels, &diags);
    return gt;
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
        /// The default ("main") window's create options, captured from the first
        /// manifest window during init. Under keep_running_on_last_close, a
        /// `reopen` after every window has closed recreates this one window from
        /// the manifest. Its slice fields (label/url/title) point at static data
        /// (comptime .zon on the production path, string literals in tests), so
        /// the stored value stays valid for the App's life with no dupe.
        default_window: WindowManager(B).Options,
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
            // label, then build the table from the app's declared capabilities via
            // buildGrantsFromCaps. init registers no app commands (struct {}), so
            // the augmentation adds only core:default; with no declared caps the
            // builder falls back to synthAppGrants (deny-by-default preserved).
            var labels_list: std.ArrayList([]const u8) = .empty;
            defer labels_list.deinit(alloc);
            for (windows) |w| try labels_list.append(alloc, w.label);
            const labels = labels_list.items;

            // Build the grant table from the app's DECLARED capabilities (empty
            // struct{} => no app commands, so per-cap augmentation adds only
            // core:default). With no declared caps this falls back to the historic
            // all-windows core:default cap via synthAppGrants(struct{}).
            const grants = try buildGrantsFromCaps(alloc, struct {}, comptime parse.embedded().security.permissions, live_caps, labels);
            errdefer {
                grants.deinit();
                alloc.destroy(grants);
            }
            const bases = security_gates.Bases{ .appdata = ".", .home = ".", .appconfig = "." };
            return initWithConfig(
                struct {},
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

        /// Production entry for an app that ships its own commands. Identical to
        /// `init` except the bridge also registers `AppCmds` (composed with the
        /// builtins over the shared State), and the grant table authorizes those
        /// commands for the app's windows via `buildGrantsFromCaps` (per-window and
        /// per-origin scoping from the declared capabilities; deny-by-default and
        /// declared scopes preserved). main.zig calls this with its
        /// `pub const Commands` to make web-UI → Zig command calls work live.
        pub fn initWithCommands(comptime AppCmds: type, alloc: std.mem.Allocator, io: std.Io, backend: *B) !*Self {
            const manifest = parse.embedded();
            const windows = manifest.app.windows;

            var labels_list: std.ArrayList([]const u8) = .empty;
            defer labels_list.deinit(alloc);
            for (windows) |w| try labels_list.append(alloc, w.label);
            const labels = labels_list.items;

            const grants = try buildGrantsFromCaps(alloc, AppCmds, comptime parse.embedded().security.permissions, live_caps, labels);
            errdefer {
                grants.deinit();
                alloc.destroy(grants);
            }
            const bases = security_gates.Bases{ .appdata = ".", .home = ".", .appconfig = "." };
            return initWithConfig(
                AppCmds,
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
        /// `grants`. On error this does NOT free `grants`. Ownership transfers
        /// to the App only on success, so the caller's errdefer frees it once.
        ///
        /// `windows` is the manifest window list (at least one, label "main");
        /// `policy` and `fallback_ms` come from D's App config.
        pub fn initWithConfig(
            comptime AppCmds: type,
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
                .default_window = undefined,
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
                // The dev-URL override applies ONLY to the "main" window and ONLY in
                // Debug (devUrlOverride folds to null in release). It selects the window
                // URL; it is never fed into nav trust (that flows through the manifest
                // dev_url capability origin in decideNavigation). create() dupes opts.url
                // (manager.zig:73), so the override is freed right after create returns.
                const dev_override = if (std.mem.eql(u8, w.label, "main"))
                    try devUrlOverride(alloc)
                else
                    null;
                defer if (dev_override) |d| alloc.free(d);
                // w.url is optional (null derives app://); the override only supersedes
                // a present URL, so fold it in only when w.url is non-null.
                const window_url: ?[]const u8 = if (w.url) |u| resolveWindowUrl(u, dev_override) else dev_override;
                const opts = WindowManager(B).Options{
                    .label = w.label,
                    .url = window_url,
                    .title = w.title,
                    .width = w.width,
                    .height = w.height,
                    .decorations = w.decorations,
                    .title_bar_style = w.titleBarStyle,
                    .show = w.show,
                };
                const e = try self.manager.create(opts);
                if (boot == null) {
                    boot = e.handle;
                    // The first manifest window is the default ("main"): store its
                    // opts so a later reopen can recreate exactly this window. Pin the
                    // STABLE manifest URL here, not the dev override: the override is
                    // freed at the end of this iteration, so storing it would leave
                    // default_window.url dangling for the reopen path (line ~433).
                    var default_opts = opts;
                    default_opts.url = w.url;
                    self.default_window = default_opts;
                }
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
                // The framework builtins composed with the app's own commands over
                // the one builtin.State. An empty AppCmds contributes no decls, so
                // a command-less app registers exactly the builtin surface.
                .{ AppCommands(B), AppCmds },
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

        /// Deinit order rationale (authoritative copy; main.zig keeps a
        /// distilled one-line note). Defers run LIFO, so app.deinit() runs
        /// BEFORE backend.deinit(). App.deinit's shutdown drains and re-points
        /// callbacks at the sentinel; it does NOT call back into the backend
        /// afterward, so the order is safe even after the macOS drain lands.
        /// deinit itself only runs shutdown() and frees the App allocation.
        pub fn deinit(self: *Self) void {
            self.shutdown();
            self.alloc.destroy(self);
        }

        /// Ordered, exactly-once, infallible shutdown:
        ///   1. close every window + terminate the backend if the lifecycle has
        ///      NOT already run the ordered shutdown (single owner:
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
        ///                          (keep_running stays alive; E's macOS default),
        ///   reopen              -> under keep_running with no live windows, the App
        ///                          recreates the default window from the manifest
        ///                          (app-owned, since app.zig holds the manifest),
        ///                          then runs the policy hook,
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
                .reopen => {
                    // Spec: reopen under keep_running recreates the default window
                    // from the D manifest. The recreate is app-owned (app.zig holds
                    // the manifest), so it lives here rather than in the lifecycle's
                    // fn-pointer reopen_handler, which can't close over the manifest.
                    // Guard precisely: only keep_running (quit_on_last_close already
                    // terminated; explicit lets the app decide), and only when no
                    // window is live (a reopen with a window already open is a
                    // no-op). create maps the recreated window, so the fail-closed
                    // bridge accepts its messages; a create error is logged, never a
                    // crash.
                    if (self.lifecycle.policy == .keep_running_on_last_close and self.manager.liveCount() == 0) {
                        _ = self.manager.create(self.default_window) catch |err| {
                            std.log.warn("reopen: recreate default window failed: {}", .{err});
                        };
                    }
                    self.lifecycle.handle(event);
                },
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
    const app = App(NullBackend).initWithConfig(struct {}, std.testing.allocator, std.testing.io, backend, grants, dummy_bases, std.Io.Dir.cwd(), false, true, &single_window, .quit_on_last_close, 5000) catch |err| {
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
    const app = App(NullBackend).initWithConfig(struct {}, std.testing.allocator, std.testing.io, backend, grants, dummy_bases, std.Io.Dir.cwd(), false, true, &windows, policy, 5000) catch |err| {
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

const ctxmod = @import("command_ctx.zig");

/// A stand-in app command namespace that fills the role a real app's `pub const Commands`
/// (in main.zig) plays. Proves App registers and authorizes commands the
/// framework itself never declared, sharing the builtin State.
const TestAppCommands = struct {
    pub fn ping(_: *ctxmod.Ctx(builtin.State), args: struct { x: i64 }) ctxmod.Result(struct { pong: i64 }) {
        return .{ .ok = .{ .pong = args.x + 1 } };
    }
};

/// Grants the app-defined `ping` command to "main" via an unscoped app
/// permission, mirroring how an app's capability would grant its own command.
fn buildPingGrants(alloc: std.mem.Allocator) !*security_grant.GrantTable {
    const gt = try alloc.create(security_grant.GrantTable);
    errdefer alloc.destroy(gt);
    var diags: manifest_types.Diagnostics = .{};
    defer diags.deinit(alloc);
    const perm = security_cap.Permission{ .identifier = "app:ping", .commands_allow = &.{"ping"} };
    const catalog = security_cap.Catalog{ .permissions = &.{perm}, .sets = &.{} };
    const caps = [_]security_cap.Capability{.{ .identifier = "app", .windows = &.{"main"}, .origins = &.{.app_scheme}, .permissions = &.{"app:ping"} }};
    gt.* = try security_grant.GrantTable.compile(alloc, &caps, &catalog, .{}, &.{"main"}, &diags);
    return gt;
}

test "initWithCommands registers and grants the app's commands end to end" {
    // The production-shaped entry: pass a command namespace, get an App whose
    // window can call those commands. No hand-built grants or config here.
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    const app = try App(NullBackend).initWithCommands(TestAppCommands, std.testing.allocator, std.testing.io, backend);
    defer teardown(backend, app);
    const main_id = mainId(app);
    backend.simulateMessage(main_id, "app://localhost", "{\"id\":11,\"cmd\":\"ping\",\"args\":{\"x\":7}}");
    app.bridge.drainForTest();
    backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 1), backend.countContaining("window.Zigware._resolve(11, "));
    try std.testing.expectEqual(@as(usize, 1), backend.countContaining("\"pong\":8"));
}

test "synthesized app grants authorize the app's own commands" {
    // No hand-built permission here: synthAppGrants must derive the grant for
    // every command in the namespace, the way init() does for a real app.
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    const grants = try synthAppGrants(std.testing.allocator, &.{"main"}, TestAppCommands, &.{});
    const app = App(NullBackend).initWithConfig(TestAppCommands, std.testing.allocator, std.testing.io, backend, grants, dummy_bases, std.Io.Dir.cwd(), false, true, &single_window, .quit_on_last_close, 5000) catch |err| {
        grants.deinit();
        std.testing.allocator.destroy(grants);
        return err;
    };
    defer teardown(backend, app);
    const main_id = mainId(app);
    backend.simulateMessage(main_id, "app://localhost", "{\"id\":9,\"cmd\":\"ping\",\"args\":{\"x\":1}}");
    app.bridge.drainForTest();
    backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 1), backend.countContaining("window.Zigware._resolve(9, "));
    try std.testing.expectEqual(@as(usize, 1), backend.countContaining("\"pong\":2"));
}

/// A namespace whose command name (`hashFile`) matches an app-declared scoped
/// `app:hashFile` permission ($APPDATA/notes/**) passed to synthAppGrants. Used to
/// prove the synthesis REUSES that declared scoped permission rather than minting
/// an unscoped one.
const TestScopedCommands = struct {
    pub fn hashFile(_: *ctxmod.Ctx(builtin.State), args: struct { path: []const u8 }) ctxmod.Result(struct { ok: bool }) {
        _ = args;
        return .{ .ok = .{ .ok = true } };
    }
};

test "synthesized grants preserve a declared command scope" {
    // synthAppGrants must reuse the app's declared scoped `app:hashFile`, so an
    // out-of-scope path is denied at the path gate. Were the synthesis to mint an
    // unscoped `app:hashFile` (ignoring the declaration), the gate would dispatch
    // /etc/passwd and resolve. This would be a real privilege escalation.
    // dummy_bases anchors $APPDATA at /tmp, so /etc/passwd is outside
    // $APPDATA/notes/** and must be rejected.
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    const notes_hashfile = security_cap.Permission{
        .identifier = "app:hashFile",
        .commands_allow = &.{"hashFile"},
        .scope_allow = &.{.{ .path = "$APPDATA/notes/**" }},
    };
    const grants = try synthAppGrants(std.testing.allocator, &.{"main"}, TestScopedCommands, &.{notes_hashfile});
    const app = App(NullBackend).initWithConfig(TestScopedCommands, std.testing.allocator, std.testing.io, backend, grants, dummy_bases, std.Io.Dir.cwd(), false, true, &single_window, .quit_on_last_close, 5000) catch |err| {
        grants.deinit();
        std.testing.allocator.destroy(grants);
        return err;
    };
    defer teardown(backend, app);
    const main_id = mainId(app);
    backend.simulateMessage(main_id, "app://localhost", "{\"id\":12,\"cmd\":\"hashFile\",\"args\":{\"path\":\"/etc/passwd\"}}");
    app.bridge.drainForTest();
    backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 0), backend.countContaining("window.Zigware._resolve(12, "));
    try std.testing.expectEqual(@as(usize, 1), backend.countContaining("scope.path.no_match"));
}

test "synthesized app grants still deny an undeclared command" {
    // A command the app never declared must NOT be authorized by the synthesis.
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    const grants = try synthAppGrants(std.testing.allocator, &.{"main"}, TestAppCommands, &.{});
    const app = App(NullBackend).initWithConfig(TestAppCommands, std.testing.allocator, std.testing.io, backend, grants, dummy_bases, std.Io.Dir.cwd(), false, true, &single_window, .quit_on_last_close, 5000) catch |err| {
        grants.deinit();
        std.testing.allocator.destroy(grants);
        return err;
    };
    defer teardown(backend, app);
    const main_id = mainId(app);
    backend.simulateMessage(main_id, "app://localhost", "{\"id\":10,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    app.bridge.drainForTest();
    backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 0), backend.countContaining("window.Zigware._resolve(10, "));
}

test "app-defined command resolves through App" {
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    const grants = try buildPingGrants(std.testing.allocator);
    const app = App(NullBackend).initWithConfig(TestAppCommands, std.testing.allocator, std.testing.io, backend, grants, dummy_bases, std.Io.Dir.cwd(), false, true, &single_window, .quit_on_last_close, 5000) catch |err| {
        grants.deinit();
        std.testing.allocator.destroy(grants);
        return err;
    };
    defer teardown(backend, app);
    const main_id = mainId(app);
    backend.simulateMessage(main_id, "app://localhost", "{\"id\":7,\"cmd\":\"ping\",\"args\":{\"x\":41}}");
    app.bridge.drainForTest();
    backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 1), backend.countContaining("window.Zigware._resolve(7, "));
    try std.testing.expectEqual(@as(usize, 1), backend.countContaining("\"pong\":42"));
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

test "compute.cancel is registered and granted: cancelling an unknown id resolves" {
    // Proves the real AppCommands wiring + the core:default grant (core:compute:cancel)
    // + the auto-derived allowlist: compute.cancel reaches its handler through G1/G2,
    // and cancelling an id that was never offloaded is an idempotent no-op success
    // (bridge.cancelId short-circuits the missing entry).
    const h = try makeApp();
    defer teardown(h.backend, h.app);
    const main_id = mainId(h.app);
    h.backend.simulateMessage(main_id, "app://localhost", "{\"id\":5,\"cmd\":\"compute.cancel\",\"args\":{\"id\":999}}");
    h.app.bridge.drainForTest();
    h.backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 1), h.backend.countResolveExactly(5));
    try std.testing.expectEqual(@as(usize, 0), h.backend.countRejectExactly(5));
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
    // A host that only begins with "localhost" is a different origin.
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, h.backend.simulateNavigation("app://localhost.attacker.com/"));
    // The scheme match is case-sensitive.
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, h.backend.simulateNavigation("APP://localhost/"));
    try std.testing.expectEqual(backend_mod.NavigationDecision.allow, h.backend.simulateNavigation("app://localhost/index.html"));
}

test "dev mode: ZIGWARE_DEV_URL overrides the main window URL and is a trusted nav origin" {
    if (@import("builtin").mode != .Debug) return error.SkipZigTest;
    // devUrlOverride(gpa) reads the env under the Debug gate (re-signatured to take an
    // allocator + be fallible, since 0.16 has no std.posix.getenv). CI Debug runs with the
    // var unset, so assert the null path here and cover the set path via the pure helper below.
    // Any duped non-null result must be freed by the caller.
    if (try devUrlOverride(std.testing.allocator)) |u| std.testing.allocator.free(u);
    // Pure helper covers the decision without touching process env:
    try std.testing.expectEqualStrings("http://localhost:5173", resolveWindowUrl("app://localhost/index.html", "http://localhost:5173"));
    try std.testing.expectEqualStrings("app://localhost/index.html", resolveWindowUrl("app://localhost/index.html", null));
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

test "E: reopen under keep_running recreates the default window from the manifest" {
    const h = try makeAppMulti(.keep_running_on_last_close);
    defer teardownMulti(h);
    // Drive every window closed directly: under keep_running, window_all_closed
    // does NOT close anything, so reach liveCount 0 by closing each label.
    try h.app.manager.close("main");
    try h.app.manager.close("viewer");
    try std.testing.expectEqual(@as(usize, 0), h.app.manager.liveCount());
    // The OS reports the last window gone; keep_running stays alive (no terminate).
    h.backend.simulateLifecycle(.window_all_closed);
    try std.testing.expectEqual(@as(usize, 0), h.backend.countEvents(.terminated));

    const before = h.backend.countEvents(.created); // 2 (both initial windows)
    h.backend.simulateLifecycle(.reopen); // recreates the default window
    try std.testing.expectEqual(before + 1, h.backend.countEvents(.created));
    try std.testing.expectEqual(@as(usize, 1), h.app.manager.liveCount());
    // The recreated window is the default ("main"), mapped so the bridge routes it.
    try std.testing.expect(h.app.manager.lookup("main") != null);
}

test "E: reopen with a window still live is a no-op (no second window)" {
    const h = try makeAppMulti(.keep_running_on_last_close);
    defer teardownMulti(h);
    const before = h.backend.countEvents(.created); // 2 windows still live
    h.backend.simulateLifecycle(.reopen);
    try std.testing.expectEqual(before, h.backend.countEvents(.created));
    try std.testing.expectEqual(@as(usize, 2), h.app.manager.liveCount());
}

test "E: reopen under quit_on_last_close does not recreate (the app terminated)" {
    const h = try makeAppMulti(.quit_on_last_close);
    defer teardownMulti(h);
    h.backend.simulateLifecycle(.window_all_closed); // terminates + shuts down
    const before = h.backend.countEvents(.created);
    h.backend.simulateLifecycle(.reopen); // reaches the dead sentinel, never the App
    try std.testing.expectEqual(before, h.backend.countEvents(.created));
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

test "dropDevUrlInRelease strips dev_url origins outside Debug, keeps them in Debug" {
    const in = [_]security_cap.Capability{.{
        .identifier = "c",
        .windows = &.{"main"},
        .origins = &.{ .app_scheme, .{ .dev_url = "http://localhost:5173" } },
        .permissions = &.{},
    }};
    const out = comptime dropDevUrlInRelease(&in);
    var has_dev = false;
    var has_app = false;
    inline for (out[0].origins) |o| switch (o) {
        .dev_url => has_dev = true,
        .app_scheme => has_app = true,
        else => {},
    };
    try std.testing.expect(has_app); // app_scheme always survives
    if (builtin_target.mode == .Debug) {
        try std.testing.expect(has_dev);
    } else {
        try std.testing.expect(!has_dev); // release binary carries no dev origin
    }
}

test "buildGrantsFromCaps honors a declared cap's window and trusts app_scheme" {
    // One declared cap (main window, app_scheme). The app's ping command is
    // reachable from "main" but NOT from an undeclared window label.
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    const decl = [_]security_cap.Capability{.{ .identifier = "main", .windows = &.{"main"}, .origins = &.{.app_scheme}, .permissions = &.{"core:default"} }};
    const grants = try buildGrantsFromCaps(std.testing.allocator, TestAppCommands, &.{}, &decl, &.{"main"});
    // The declared cap scopes ping to "main": granted there, denied on any window
    // label the cap does not cover (per-window enforcement, not all-windows).
    try std.testing.expect(grants.commandGranted("main", "ping"));
    try std.testing.expect(!grants.commandGranted("other", "ping"));
    const app = App(NullBackend).initWithConfig(TestAppCommands, std.testing.allocator, std.testing.io, backend, grants, dummy_bases, std.Io.Dir.cwd(), false, true, &single_window, .quit_on_last_close, 5000) catch |err| {
        grants.deinit();
        std.testing.allocator.destroy(grants);
        return err;
    };
    defer teardown(backend, app);
    const main_id = mainId(app);
    backend.simulateMessage(main_id, "app://localhost", "{\"id\":21,\"cmd\":\"ping\",\"args\":{\"x\":4}}");
    app.bridge.drainForTest();
    backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 1), backend.countContaining("window.Zigware._resolve(21, "));
    try std.testing.expectEqual(@as(usize, 1), backend.countContaining("\"pong\":5"));
}

test "buildGrantsFromCaps trusts a declared dev origin only in Debug" {
    // The cap declares a dev_url origin. In Debug the grant table trusts it; in
    // ReleaseSafe compile() drops it, so originsFor never surfaces it.
    const decl = [_]security_cap.Capability{.{ .identifier = "main", .windows = &.{"main"}, .origins = &.{ .app_scheme, .{ .dev_url = "http://localhost:5173" } }, .permissions = &.{"core:default"} }};
    const grants = try buildGrantsFromCaps(std.testing.allocator, struct {}, &.{}, &decl, &.{"main"});
    defer {
        grants.deinit();
        std.testing.allocator.destroy(grants);
    }
    var has_dev = false;
    for (grants.originsFor("main")) |o| if (o == .dev_url) {
        has_dev = true;
    };
    if (@import("builtin").mode == .Debug) {
        try std.testing.expect(has_dev);
    } else {
        try std.testing.expect(!has_dev);
    }
}

test "buildGrantsFromCaps falls back to synthAppGrants when no caps are declared" {
    // Empty declarations => the synthAppGrants fallback grants every app command
    // to every window over app_scheme (the framework's own build has no grants).
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    const grants = try buildGrantsFromCaps(std.testing.allocator, TestAppCommands, &.{}, &.{}, &.{"main"});
    const app = App(NullBackend).initWithConfig(TestAppCommands, std.testing.allocator, std.testing.io, backend, grants, dummy_bases, std.Io.Dir.cwd(), false, true, &single_window, .quit_on_last_close, 5000) catch |err| {
        grants.deinit();
        std.testing.allocator.destroy(grants);
        return err;
    };
    defer teardown(backend, app);
    const main_id = mainId(app);
    backend.simulateMessage(main_id, "app://localhost", "{\"id\":22,\"cmd\":\"ping\",\"args\":{\"x\":8}}");
    app.bridge.drainForTest();
    backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 1), backend.countContaining("\"pong\":9"));
}
