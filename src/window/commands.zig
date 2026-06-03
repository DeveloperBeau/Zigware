const std = @import("std");
const ctxmod = @import("../command_ctx.zig");
const gates = @import("../security/gates.zig");
const cap = @import("../security/capability.zig");
const Bridge = @import("../bridge.zig").Bridge;
const builtin = @import("../commands/builtin.zig");

const State = builtin.State; // window commands share the app State; they use ctx.services

pub const CreateArgs = struct {
    label: []const u8,
    url: ?[]const u8 = null,
    title: []const u8 = "",
    width: u32 = 800,
    height: u32 = 600,
    decorations: bool = true,
    show: bool = false,
};
pub const LabelArg = struct { label: []const u8 };
pub const TitleArgs = struct { label: []const u8, title: []const u8 };
pub const SizeArgs = struct { label: []const u8, width: u32, height: u32 };
pub const FullscreenArgs = struct { label: []const u8, on: bool };

/// The `window.*` command namespace. Each handler runs as a B built-in: G1+G2
/// already ran in Bridge.handleMessage (origin trust + command grant), so the
/// handler is reached ONLY for a granted command from a trusted window. It then
/// runs G4 itself via gates.checkScope (the label value-set, plus the create-url
/// host) before touching the manager. The body's `label`/`url` are the gated
/// inputs; the calling window's identity is ctx.window_label (the attested label
/// stamped by the bridge), never anything the body claims.
pub fn WindowCommands(comptime B: type) type {
    const Br = Bridge(B);
    return struct {
        fn br(ctx: *ctxmod.Ctx(State)) *Br {
            return @ptrCast(@alignCast(ctx.services.?));
        }

        /// Surface the structured window deny code; the C deny code (the precise
        /// scope.* reason) travels in `message` so a test/caller can branch on it
        /// without leaking the granted set into a payload.
        fn scopeErr(code: []const u8) ctxmod.CommandError {
            return .{ .code = "window.scope_denied", .message = code, .payload_json = null };
        }
        fn mapErr(e: anytype) ctxmod.CommandError {
            return switch (e) {
                error.LabelInUse => .{ .code = "window.label_in_use", .message = "label already in use" },
                error.UnknownLabel => .{ .code = "window.unknown_label", .message = "no such window" },
                error.BackendFailure, error.OutOfMemory => .{ .code = "window.backend_failure", .message = "window backend failed" },
            };
        }

        /// G4 label scope with the OWN-WINDOW fast path. A window operating on ITS
        /// OWN label needs no cross-window label scope (the core:window:own
        /// semantics for setTitle/setSize, which ship in core:default). G2 still
        /// gated the command itself in handleMessage, so close/focus/setFullscreen
        /// on self still require their granted permission. A DIFFERENT target
        /// requires an explicit label scope. `window.create` always names a fresh
        /// target distinct from the caller, so it never takes the fast path.
        fn labelG4(b: *Br, ctx: *ctxmod.Ctx(State), command: []const u8, target: []const u8) ?ctxmod.CommandError {
            if (std.mem.eql(u8, target, ctx.window_label)) return null;
            const d = gates.checkScope(b.grants, ctx.window_label, command, .{ .label = target }, b.bases, b.io, b.base_dir);
            return if (d == .deny) scopeErr(d.deny.code) else null;
        }

        pub fn @"window.create"(ctx: *ctxmod.Ctx(State), args: CreateArgs) ctxmod.Result(struct { label: []const u8 }) {
            const b = br(ctx);
            if (labelG4(b, ctx, "window.create", args.label)) |err| return .{ .err = err };
            if (args.url) |u| {
                const hr = parseHostRule(u) catch return .{ .err = scopeErr("scope.host.no_match") };
                const dh = gates.checkScope(b.grants, ctx.window_label, "window.create", .{ .host = hr }, b.bases, b.io, b.base_dir);
                if (dh == .deny) return .{ .err = scopeErr(dh.deny.code) };
            }
            _ = b.manager.?.create(.{
                .label = args.label,
                .url = args.url,
                .title = args.title,
                .width = args.width,
                .height = args.height,
                .decorations = args.decorations,
                .show = args.show,
            }) catch |e| return .{ .err = mapErr(e) };
            return .{ .ok = .{ .label = args.label } };
        }

        pub fn @"window.close"(ctx: *ctxmod.Ctx(State), args: LabelArg) ctxmod.Result(struct {}) {
            const b = br(ctx);
            if (labelG4(b, ctx, "window.close", args.label)) |err| return .{ .err = err };
            // close is idempotent: a second close hits an already-removed entry and
            // returns UnknownLabel from the manager. Swallow that ONE error so the
            // promise still resolves (the window is gone, which is the desired
            // end-state). Every other failure surfaces as a structured reject.
            b.manager.?.close(args.label) catch |e| switch (e) {
                error.UnknownLabel => {},
                else => return .{ .err = mapErr(e) },
            };
            return .{ .ok = .{} };
        }

        pub fn @"window.focus"(ctx: *ctxmod.Ctx(State), args: LabelArg) ctxmod.Result(struct {}) {
            const b = br(ctx);
            if (labelG4(b, ctx, "window.focus", args.label)) |err| return .{ .err = err };
            b.manager.?.focus(args.label) catch |e| return .{ .err = mapErr(e) };
            return .{ .ok = .{} };
        }

        pub fn @"window.setTitle"(ctx: *ctxmod.Ctx(State), args: TitleArgs) ctxmod.Result(struct {}) {
            const b = br(ctx);
            if (labelG4(b, ctx, "window.setTitle", args.label)) |err| return .{ .err = err };
            b.manager.?.setTitle(args.label, args.title) catch |e| return .{ .err = mapErr(e) };
            return .{ .ok = .{} };
        }

        pub fn @"window.setSize"(ctx: *ctxmod.Ctx(State), args: SizeArgs) ctxmod.Result(struct {}) {
            const b = br(ctx);
            if (labelG4(b, ctx, "window.setSize", args.label)) |err| return .{ .err = err };
            b.manager.?.setSize(args.label, args.width, args.height) catch |e| return .{ .err = mapErr(e) };
            return .{ .ok = .{} };
        }

        pub fn @"window.setFullscreen"(ctx: *ctxmod.Ctx(State), args: FullscreenArgs) ctxmod.Result(struct {}) {
            const b = br(ctx);
            if (labelG4(b, ctx, "window.setFullscreen", args.label)) |err| return .{ .err = err };
            b.manager.?.setFullscreen(args.label, args.on) catch |e| return .{ .err = mapErr(e) };
            return .{ .ok = .{} };
        }
    };
}

/// Parse a window URL into a HostRule {host, port?} for the G4 host check.
///
/// v0.1.0 host-scope rule:
///   - `app://localhost[/...]` -> {host: "localhost"} (app://localhost is THE one
///     trusted app origin; a child window must be app://localhost/<path>).
///   - `app://<other-host>[/...]` -> error (deny-closed; never trust app://evil/).
///   - `http(s)://host[:port][/...]` -> {host, port}.
///   - anything malformed (no "://", empty authority/host, bad/overflowing port)
///     -> error, so the caller denies closed.
fn parseHostRule(url: []const u8) !cap.HostRule {
    const sep = std.mem.indexOf(u8, url, "://") orelse return error.MalformedUrl;
    const scheme = url[0..sep];
    const rest = url[sep + 3 ..];
    // Authority is everything up to the first '/', or the whole remainder.
    const auth_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..auth_end];
    if (authority.len == 0) return error.MalformedUrl;

    if (std.mem.eql(u8, scheme, "app")) {
        // The only trusted app host is localhost; any other host is denied closed.
        if (!std.mem.eql(u8, authority, "localhost")) return error.MalformedUrl;
        return .{ .host = "localhost" };
    }
    if (std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "https")) {
        // Split a trailing :port. A host with no colon means any port (null).
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |ci| {
            const host = authority[0..ci];
            const port_str = authority[ci + 1 ..];
            if (host.len == 0 or port_str.len == 0) return error.MalformedUrl;
            const port = std.fmt.parseInt(u16, port_str, 10) catch return error.MalformedUrl;
            return .{ .host = host, .port = port };
        }
        return .{ .host = authority };
    }
    return error.MalformedUrl;
}

// ─── parseHostRule unit tests ─────────────────────────────────────────────────

test "parseHostRule: app://localhost with a path yields host localhost" {
    const hr = try parseHostRule("app://localhost/index.html");
    try std.testing.expectEqualStrings("localhost", hr.host);
    try std.testing.expect(hr.port == null);
}

test "parseHostRule: bare app://localhost yields host localhost" {
    const hr = try parseHostRule("app://localhost");
    try std.testing.expectEqualStrings("localhost", hr.host);
    try std.testing.expect(hr.port == null);
}

test "parseHostRule: app:// with a non-localhost host is denied closed" {
    try std.testing.expectError(error.MalformedUrl, parseHostRule("app://evil/"));
    try std.testing.expectError(error.MalformedUrl, parseHostRule("app://localhost.attacker.com/x"));
}

test "parseHostRule: https host:port splits into host and port" {
    const hr = try parseHostRule("https://x.example:8443/p");
    try std.testing.expectEqualStrings("x.example", hr.host);
    try std.testing.expectEqual(@as(?u16, 8443), hr.port);
}

test "parseHostRule: http host without a port yields a null port" {
    const hr = try parseHostRule("http://x.example/p");
    try std.testing.expectEqualStrings("x.example", hr.host);
    try std.testing.expect(hr.port == null);
}

test "parseHostRule: malformed urls error (deny-closed)" {
    try std.testing.expectError(error.MalformedUrl, parseHostRule("no-scheme"));
    try std.testing.expectError(error.MalformedUrl, parseHostRule("app://"));
    try std.testing.expectError(error.MalformedUrl, parseHostRule("https://"));
    try std.testing.expectError(error.MalformedUrl, parseHostRule("https://:8443/p")); // empty host
    try std.testing.expectError(error.MalformedUrl, parseHostRule("https://x.example:/p")); // empty port
    try std.testing.expectError(error.MalformedUrl, parseHostRule("https://x.example:99999/p")); // port overflow
}

// ─── window.* end-to-end command tests (full gate chain through the bridge) ────
//
// These drive Bridge.handleMessage with window.* JSON and assert the structured
// results/rejects, proving the G2 (command grant, in handleMessage) / G4 (label +
// host scope, in the handler) split end-to-end with zero seam side effects on a
// denial. The production composition AppCommands(B) is wired in app.zig (Task 10);
// here a TEST-ONLY composed struct mirrors that dotted-decl-name pattern so the
// registry sees both the builtin demo commands and the six window.* handlers.

const NullBackend = @import("../platform/null.zig").NullBackend;
const Bridge_ = @import("../bridge.zig").Bridge;
const WindowManager = @import("manager.zig").WindowManager;
const grant = @import("../security/grant_table.zig");
const defaults = @import("../security/defaults.zig");
const manifest = @import("../manifest/types.zig");
const protocol = @import("../protocol.zig");

/// TEST-ONLY composition mirroring the dotted-decl-name shape AppCommands(B) will
/// use in Task 10: the shipping builtin demo commands plus the six window.*
/// handlers, all registered by their decl name (so @"window.create" registers the
/// command "window.create"). Re-exported as plain decls; registry.declFns picks up
/// every fn-typed decl by name.
fn TestAppCommands(comptime B: type) type {
    const WC = WindowCommands(B);
    return struct {
        pub const sha256 = builtin.Commands.sha256;
        pub const echoBytes = builtin.Commands.echoBytes;
        pub const echo = builtin.Commands.echo;
        pub const @"window.create" = WC.@"window.create";
        pub const @"window.close" = WC.@"window.close";
        pub const @"window.focus" = WC.@"window.focus";
        pub const @"window.setTitle" = WC.@"window.setTitle";
        pub const @"window.setSize" = WC.@"window.setSize";
        pub const @"window.setFullscreen" = WC.@"window.setFullscreen";
    };
}

const Manager = WindowManager(NullBackend);
const dummy_bases = gates.Bases{ .appdata = "/tmp", .home = "/tmp", .appconfig = "/tmp" };

/// A test catalog granting the calling window "main" the manage verbs with a
/// label scope set {viewer} and a host scope {localhost}, plus core:default and
/// the builtin fixture commands. A second window "plain" gets core:default ONLY
/// (no manage), so it doubles as the G2-deny caller and the own-window-allow
/// caller (setTitle on self via core:window:own). Two non-overlapping caps keep
/// the per-(label,command) n<=1 grant assertion inert.
const manage_catalog = cap.Catalog{
    .permissions = &(defaults.builtin_permissions ++ [_]cap.Permission{
        .{ .identifier = "test:fixtures", .commands_allow = &.{ "sha256", "echoBytes", "echo" } },
        .{ .identifier = "test:windowscope", .scope_allow = &.{
            .{ .label = "viewer" },
            .{ .host = .{ .host = "localhost" } },
        } },
    }),
    .sets = &(defaults.builtin_sets ++ [_]cap.PermissionSet{
        .{ .identifier = "test:manage", .members = &.{ "core:default", "test:fixtures", "core:window:manage", "test:windowscope" } },
        .{ .identifier = "test:plain", .members = &.{ "core:default", "test:fixtures" } },
    }),
};

fn buildTestGrantsManage(alloc: std.mem.Allocator) !*grant.GrantTable {
    const gt = try alloc.create(grant.GrantTable);
    errdefer alloc.destroy(gt);
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(alloc);
    const caps = [_]cap.Capability{
        .{ .identifier = "cap-main", .windows = &.{"main"}, .origins = &.{.app_scheme}, .permissions = &.{"test:manage"} },
        .{ .identifier = "cap-plain", .windows = &.{"plain"}, .origins = &.{.app_scheme}, .permissions = &.{"test:plain"} },
    };
    gt.* = try grant.GrantTable.compile(alloc, &caps, &manage_catalog, .{}, &.{ "main", "plain" }, &diags);
    return gt;
}

/// Bridge wired to a manager owning two windows: "main" (manage-granted caller)
/// and "plain" (core:default only). Registers TestAppCommands so window.* dispatch
/// runs the real gate chain. Mirrors bridge.zig's initMulti scaffolding.
const WinHarness = struct {
    backend: *NullBackend,
    bridge: *Bridge_(NullBackend),
    manager: *Manager,
    grants: *grant.GrantTable,
    state: *builtin.State,
    id_main: u64,
    id_plain: u64,
    handle_main: NullBackend.WindowHandle,
    handle_plain: NullBackend.WindowHandle,

    fn init() !WinHarness {
        const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
        const boot = try backend.createWindow(.{ .url = "app://localhost/index.html" });
        const state = try std.testing.allocator.create(builtin.State);
        state.* = .{};
        const grants = try buildTestGrantsManage(std.testing.allocator);
        const bridge = try Bridge_(NullBackend).init(
            std.testing.allocator,
            std.testing.io,
            backend,
            boot,
            builtin.State,
            TestAppCommands(NullBackend),
            state,
            .{ .worker_count = 4 },
            grants,
            dummy_bases,
            std.Io.Dir.cwd(),
            false,
        );
        backend.setCallbacks(.{
            .ctx = bridge,
            .onSchemeRequest = schemeReq,
            .onMessage = noopMessage,
            .onLifecycle = noopLifecycle,
            .onNavigation = noopNavigation,
        });
        const mgr = try std.testing.allocator.create(Manager);
        mgr.* = Manager.init(std.testing.allocator, backend, std.testing.io);
        bridge.setManager(mgr);
        const em = try mgr.create(.{ .label = "main", .url = "app://localhost/m", .show = true });
        const ep = try mgr.create(.{ .label = "plain", .url = "app://localhost/p", .show = true });
        return .{
            .backend = backend,
            .bridge = bridge,
            .manager = mgr,
            .grants = grants,
            .state = state,
            .id_main = em.window_id,
            .id_plain = ep.window_id,
            .handle_main = em.handle,
            .handle_plain = ep.handle,
        };
    }

    fn schemeReq(ctx: *anyopaque, req: @import("../platform/backend.zig").Request) @import("../platform/backend.zig").Response {
        const bridge: *Bridge_(NullBackend) = @ptrCast(@alignCast(ctx));
        switch (req.source) {
            .stream_scheme => return bridge.serveStream(req.path),
            .asset_scheme => return .{ .status = 404, .mime = "text/plain", .body = "" },
        }
    }
    fn noopMessage(_: *anyopaque, _: u64, _: []const u8, _: []const u8) void {}
    fn noopLifecycle(_: *anyopaque, _: @import("../platform/backend.zig").LifecycleEvent) void {}
    fn noopNavigation(_: *anyopaque, _: []const u8) @import("../platform/backend.zig").NavigationDecision {
        return .cancel;
    }

    /// Drive a message from a given attested window id, then settle.
    fn call(self: *WinHarness, id: u64, text: []const u8) void {
        self.bridge.handleMessage(id, "app://localhost", text);
        self.bridge.drainForTest();
        self.backend.pumpMain();
    }

    fn deinit(self: *WinHarness) void {
        self.bridge.deinit();
        self.manager.deinit();
        std.testing.allocator.destroy(self.manager);
        self.grants.deinit();
        std.testing.allocator.destroy(self.grants);
        std.testing.allocator.destroy(self.state);
        self.backend.markJoined();
        self.backend.deinit();
    }
};

/// Was a terminal _reject for `id` emitted whose body carries `needle`? The reject
/// code/message ride in the encoded JS literal (escaped through jsString), so a
/// substring search over the reject frames is a reliable structured-code assertion.
fn rejectCarries(be: *NullBackend, id: u64, needle: []const u8) bool {
    var buf: [32]u8 = undefined;
    const tag = std.fmt.bufPrint(&buf, "_reject({d}, ", .{id}) catch return false;
    for (be.eval_log.items) |e| {
        if (std.mem.indexOf(u8, e.js, tag) != null and std.mem.indexOf(u8, e.js, needle) != null) return true;
    }
    return false;
}

test "window.create rejects a duplicate label with window.label_in_use" {
    var t = try WinHarness.init();
    defer t.deinit();
    const before = t.backend.countEvents(.created);
    // "main" is granted manage; "viewer" is in scope and free; create it first.
    t.call(t.id_main, "{\"id\":1,\"cmd\":\"window.create\",\"args\":{\"label\":\"viewer\",\"url\":\"app://localhost/v\"}}");
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(1));
    try std.testing.expectEqual(before + 1, t.backend.countEvents(.created));
    // Second create of the same in-scope label -> reaches the manager -> in-use.
    t.call(t.id_main, "{\"id\":2,\"cmd\":\"window.create\",\"args\":{\"label\":\"viewer\",\"url\":\"app://localhost/v\"}}");
    try std.testing.expect(rejectCarries(t.backend, 2, "window.label_in_use"));
    // No SECOND seam window was created on the duplicate.
    try std.testing.expectEqual(before + 1, t.backend.countEvents(.created));
}

test "window.create denied at G2 when the window lacks core:window:manage" {
    var t = try WinHarness.init();
    defer t.deinit();
    const before = t.backend.countEvents(.created);
    // "plain" holds core:default only; window.create needs core:window:manage,
    // so G2 in handleMessage rejects before any arg (label/url) is examined.
    t.call(t.id_plain, "{\"id\":3,\"cmd\":\"window.create\",\"args\":{\"label\":\"viewer\",\"url\":\"app://localhost/v\"}}");
    try std.testing.expect(rejectCarries(t.backend, 3, "command.not_granted"));
    // Zero seam side effects: no createWindow ran.
    try std.testing.expectEqual(before, t.backend.countEvents(.created));
}

test "window.create denied at G4 when the target label is out of scope" {
    var t = try WinHarness.init();
    defer t.deinit();
    const before = t.backend.countEvents(.created);
    // "secret" is NOT in main's label scope {viewer}: G4 label check denies.
    t.call(t.id_main, "{\"id\":4,\"cmd\":\"window.create\",\"args\":{\"label\":\"secret\",\"url\":\"app://localhost/s\"}}");
    try std.testing.expect(rejectCarries(t.backend, 4, "window.scope_denied"));
    try std.testing.expect(rejectCarries(t.backend, 4, "scope.label.no_match"));
    try std.testing.expectEqual(before, t.backend.countEvents(.created));
}

test "window.create denied at G4 when the url host is out of scope" {
    var t = try WinHarness.init();
    defer t.deinit();
    const before = t.backend.countEvents(.created);
    // Label "viewer" passes the label check; the https host x.example is NOT in the
    // host scope {localhost}, so the second G4 (host) check denies.
    t.call(t.id_main, "{\"id\":5,\"cmd\":\"window.create\",\"args\":{\"label\":\"viewer\",\"url\":\"https://x.example/p\"}}");
    try std.testing.expect(rejectCarries(t.backend, 5, "window.scope_denied"));
    try std.testing.expect(rejectCarries(t.backend, 5, "scope.host.no_match"));
    try std.testing.expectEqual(before, t.backend.countEvents(.created));
}

test "window.setTitle on an unknown label returns window.unknown_label" {
    var t = try WinHarness.init();
    defer t.deinit();
    // "viewer" is IN main's label scope but not created, so G4 passes and the
    // manager reports the unknown label (distinct from a scope denial).
    t.call(t.id_main, "{\"id\":6,\"cmd\":\"window.setTitle\",\"args\":{\"label\":\"viewer\",\"title\":\"x\"}}");
    try std.testing.expect(rejectCarries(t.backend, 6, "window.unknown_label"));
}

test "window.close is idempotent: a second close resolves, not errors" {
    var t = try WinHarness.init();
    defer t.deinit();
    // Create an in-scope window, then close it twice from main.
    t.call(t.id_main, "{\"id\":7,\"cmd\":\"window.create\",\"args\":{\"label\":\"viewer\",\"url\":\"app://localhost/v\"}}");
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(7));
    t.call(t.id_main, "{\"id\":8,\"cmd\":\"window.close\",\"args\":{\"label\":\"viewer\"}}");
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(8));
    // Second close: the entry is already gone, but window.close swallows
    // UnknownLabel and RESOLVES (idempotent), it does not reject.
    t.call(t.id_main, "{\"id\":9,\"cmd\":\"window.close\",\"args\":{\"label\":\"viewer\"}}");
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(9));
    try std.testing.expectEqual(@as(usize, 0), t.backend.countRejectExactly(9));
}

test "own-window fast path: a core:default window sets its OWN title; close on self needs manage (G2)" {
    var t = try WinHarness.init();
    defer t.deinit();
    // "plain" holds core:default only. setTitle is in core:window:own (core:default),
    // so G2 passes; the own-window G4 fast path skips the label scope it lacks; the
    // manager applies the title.
    t.call(t.id_plain, "{\"id\":10,\"cmd\":\"window.setTitle\",\"args\":{\"label\":\"plain\",\"title\":\"Mine\"}}");
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(10));
    try std.testing.expectEqualStrings("Mine", t.backend.windows.items[t.handle_plain].title);
    // But close on SELF still needs core:window:manage, which "plain" lacks: G2
    // rejects in handleMessage with command.not_granted, no destroy on the seam.
    const destroyed_before = t.backend.countEvents(.destroyed);
    t.call(t.id_plain, "{\"id\":11,\"cmd\":\"window.close\",\"args\":{\"label\":\"plain\"}}");
    try std.testing.expect(rejectCarries(t.backend, 11, "command.not_granted"));
    try std.testing.expectEqual(destroyed_before, t.backend.countEvents(.destroyed));
}
