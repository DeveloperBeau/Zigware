const std = @import("std");
const cap = @import("capability.zig");
const grant = @import("grant_table.zig");
const path = @import("scope/path.zig");
const host = @import("scope/host.zig");
const argv = @import("scope/argv.zig");
const label = @import("scope/label.zig");

const GrantTable = grant.GrantTable;
const OriginPattern = cap.OriginPattern;
const HostRule = cap.HostRule;
pub const Bases = path.Bases;

pub const Gate = enum { g1_origin, g2_command, g4_scope };

pub const ScopeInput = union(enum) {
    none, // command declares no scope; G4 is a no-op allow
    path: []const u8,
    host: HostRule,
    argv: []const []const u8,
    label: []const u8,
};

pub const InvokeContext = struct {
    window_label: []const u8,
    origin: []const u8,
    command: []const u8,
    scope_input: ScopeInput,
    is_debug: bool,
};

pub const DenyReason = struct {
    gate: Gate,
    code: []const u8, // stable string the frontend can branch on
    message: []const u8, // never includes the granted set, candidate path, or origin
};

pub const Decision = union(enum) {
    allow,
    deny: DenyReason,
};

/// G1: does `origin` match any trusted OriginPattern for this window?
/// Empty origins means app_scheme only. dev_url honored only when is_debug.
/// https_exact already fuse-filtered at compile.
fn originTrusted(origins: []const OriginPattern, origin: []const u8, is_debug: bool) bool {
    if (origins.len == 0) return isAppScheme(origin);
    for (origins) |o| switch (o) {
        .app_scheme => if (isAppScheme(origin)) return true,
        .dev_url => |u| if (is_debug and std.mem.eql(u8, u, origin)) return true,
        .https_exact => |u| if (std.mem.eql(u8, u, origin)) return true,
    };
    return false;
}

/// The trusted prod origin is EXACTLY app://localhost (the one app host), not any
/// app:// host. Matching a bare `app://` prefix would trust `app://evil/` and
/// `app://localhost.attacker.com/` — the exact bug the current app.zig nav guard
/// fixed (see its deny-by-default comment). Match `app://localhost/` (with a path)
/// or the bare `app://localhost` origin, nothing else. An empty, opaque,
/// javascript:, or foreign origin does not match.
fn isAppScheme(origin: []const u8) bool {
    return std.mem.startsWith(u8, origin, "app://localhost/") or
        std.mem.eql(u8, origin, "app://localhost");
}

pub fn evaluate(
    grants: *const GrantTable,
    ctx: InvokeContext,
    bases: Bases,
    io: std.Io,
    base_dir: std.Io.Dir,
) Decision {
    // G1 origin.
    const origins = grants.originsFor(ctx.window_label);
    if (!originTrusted(origins, ctx.origin, ctx.is_debug)) {
        return .{ .deny = .{ .gate = .g1_origin, .code = "origin.untrusted", .message = "origin not trusted for this window" } };
    }
    // G2 command granted.
    if (!grants.commandGranted(ctx.window_label, ctx.command)) {
        return .{ .deny = .{ .gate = .g2_command, .code = "command.not_granted", .message = "command not granted to this window" } };
    }
    // G4 scope.
    switch (ctx.scope_input) {
        .none => return .allow,
        .path => |p| {
            const set = grants.scopeFor(ctx.window_label, ctx.command);
            if (path.pathMatches(io, base_dir, set, p, bases)) return .allow;
            return .{ .deny = .{ .gate = .g4_scope, .code = "scope.path.no_match", .message = "path out of scope" } };
        },
        .host => |h| {
            const set = grants.scopeFor(ctx.window_label, ctx.command);
            if (host.hostMatches(set, h)) return .allow;
            return .{ .deny = .{ .gate = .g4_scope, .code = "scope.host.no_match", .message = "host out of scope" } };
        },
        .argv => |av| {
            const set = grants.scopeFor(ctx.window_label, ctx.command);
            if (argv.argvMatches(set, av)) return .allow;
            return .{ .deny = .{ .gate = .g4_scope, .code = "scope.argv.no_match", .message = "argv out of scope" } };
        },
        .label => |l| {
            const set = grants.scopeFor(ctx.window_label, ctx.command);
            if (label.labelMatches(set, l)) return .allow;
            return .{ .deny = .{ .gate = .g4_scope, .code = "scope.label.no_match", .message = "target window out of scope" } };
        },
    }
}

const defaults = @import("defaults.zig");

fn gt(caps: []const cap.Capability) !GrantTable {
    var diags = @import("../manifest/types.zig").Diagnostics{};
    defer diags.deinit(std.testing.allocator);
    return GrantTable.compile(std.testing.allocator, caps, &defaults.builtin_catalog, .{}, &.{"main"}, &diags);
}

fn ctxFor(origin: []const u8, command: []const u8, is_debug: bool) InvokeContext {
    return .{ .window_label = "main", .origin = origin, .command = command, .scope_input = .none, .is_debug = is_debug };
}

test "G1: app:// origin allowed, foreign denied" {
    const caps = [_]cap.Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"core:default"} }};
    var table = try gt(&caps);
    defer table.deinit();
    const bases = Bases{ .appdata = "/a", .home = "/h", .appconfig = "/c" };
    try std.testing.expect(evaluate(&table, ctxFor("app://localhost", "window.setTitle", false), bases, std.testing.io, std.Io.Dir.cwd()) == .allow);
    const d = evaluate(&table, ctxFor("https://evil.example", "window.setTitle", false), bases, std.testing.io, std.Io.Dir.cwd());
    try std.testing.expectEqualStrings("origin.untrusted", d.deny.code);
    // app:// with a non-localhost host must be denied (not any app:// host is trusted).
    const e = evaluate(&table, ctxFor("app://evil/", "window.setTitle", false), bases, std.testing.io, std.Io.Dir.cwd());
    try std.testing.expectEqualStrings("origin.untrusted", e.deny.code);
    const f = evaluate(&table, ctxFor("app://localhost.attacker.com/", "window.setTitle", false), bases, std.testing.io, std.Io.Dir.cwd());
    try std.testing.expectEqualStrings("origin.untrusted", f.deny.code);
}

test "G1 ordering: a G1 failure never reaches G2 (ungranted command behind a bad origin still reports origin)" {
    const caps = [_]cap.Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"core:default"} }};
    var table = try gt(&caps);
    defer table.deinit();
    const bases = Bases{ .appdata = "/a", .home = "/h", .appconfig = "/c" };
    const d = evaluate(&table, ctxFor("https://evil", "fs.readFile", false), bases, std.testing.io, std.Io.Dir.cwd());
    try std.testing.expectEqual(Gate.g1_origin, d.deny.gate); // G1, not G2
}

test "G2: granted command allows, ungranted denies with command.not_granted" {
    const caps = [_]cap.Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"core:default"} }};
    var table = try gt(&caps);
    defer table.deinit();
    const bases = Bases{ .appdata = "/a", .home = "/h", .appconfig = "/c" };
    const d = evaluate(&table, ctxFor("app://localhost", "fs.readFile", false), bases, std.testing.io, std.Io.Dir.cwd());
    try std.testing.expectEqualStrings("command.not_granted", d.deny.code);
}

test "G1: dev_url honored only in debug" {
    const caps = [_]cap.Capability{.{ .identifier = "c", .windows = &.{"main"}, .origins = &.{ .app_scheme, .{ .dev_url = "http://localhost:1420" } }, .permissions = &.{"core:default"} }};
    var table = try gt(&caps);
    defer table.deinit();
    const bases = Bases{ .appdata = "/a", .home = "/h", .appconfig = "/c" };
    try std.testing.expect(evaluate(&table, ctxFor("http://localhost:1420", "window.setTitle", true), bases, std.testing.io, std.Io.Dir.cwd()) == .allow);
    const d = evaluate(&table, ctxFor("http://localhost:1420", "window.setTitle", false), bases, std.testing.io, std.Io.Dir.cwd());
    try std.testing.expectEqualStrings("origin.untrusted", d.deny.code); // release build rejects dev url
}

test "G4: a .none command allows immediately" {
    const caps = [_]cap.Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"core:default"} }};
    var table = try gt(&caps);
    defer table.deinit();
    const bases = Bases{ .appdata = "/a", .home = "/h", .appconfig = "/c" };
    try std.testing.expect(evaluate(&table, ctxFor("app://localhost", "compute.cancel", false), bases, std.testing.io, std.Io.Dir.cwd()) == .allow);
}
