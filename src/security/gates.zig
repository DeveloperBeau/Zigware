const std = @import("std");
const builtin = @import("builtin");
const cap = @import("capability.zig");
const grant = @import("grantTable.zig");
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
/// Empty origins means app_scheme only. devUrl honored only when is_debug.
/// httpsExact already fuse-filtered at compile.
fn originTrusted(origins: []const OriginPattern, origin: []const u8, is_debug: bool) bool {
    if (origins.len == 0) return isAppScheme(origin);
    for (origins) |o| switch (o) {
        .app_scheme => if (isAppScheme(origin)) return true,
        .devUrl => |u| if (is_debug and std.mem.eql(u8, u, origin)) return true,
        .httpsExact => |u| if (std.mem.eql(u8, u, origin)) return true,
    };
    return false;
}

/// The trusted prod origin is EXACTLY app://localhost (the one app host), not any
/// app:// host. Matching a bare `app://` prefix would trust `app://evil/` and
/// `app://localhost.attacker.com/`. The current app.zig nav guard fixed that bug
/// (see its deny-by-default comment). Match `app://localhost/` (with a path)
/// or the bare `app://localhost` origin, nothing else. An empty, opaque,
/// javascript:, or foreign origin does not match.
pub fn isAppScheme(origin: []const u8) bool {
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
    return g4(grants, ctx.window_label, ctx.command, ctx.scope_input, bases, io, base_dir);
}

fn g4(
    grants: *const GrantTable,
    window_label: []const u8,
    command: []const u8,
    scope_input: ScopeInput,
    bases: Bases,
    io: std.Io,
    base_dir: std.Io.Dir,
) Decision {
    switch (scope_input) {
        .none => return .allow,
        .path => |p| {
            const set = grants.scopeFor(window_label, command);
            if (path.pathMatches(io, base_dir, set, p, bases)) return .allow;
            return .{ .deny = .{ .gate = .g4_scope, .code = "scope.path.no_match", .message = "path out of scope" } };
        },
        .host => |h| {
            const set = grants.scopeFor(window_label, command);
            if (host.hostMatches(set, h)) return .allow;
            return .{ .deny = .{ .gate = .g4_scope, .code = "scope.host.no_match", .message = "host out of scope" } };
        },
        .argv => |av| {
            const set = grants.scopeFor(window_label, command);
            if (argv.argvMatches(set, av)) return .allow;
            return .{ .deny = .{ .gate = .g4_scope, .code = "scope.argv.no_match", .message = "argv out of scope" } };
        },
        .label => |l| {
            const set = grants.scopeFor(window_label, command);
            if (label.labelMatches(set, l)) return .allow;
            return .{ .deny = .{ .gate = .g4_scope, .code = "scope.label.no_match", .message = "target window out of scope" } };
        },
    }
}

pub fn originAllowed(grants: *const GrantTable, window_label: []const u8, origin: []const u8, is_debug: bool) bool {
    return originTrusted(grants.originsFor(window_label), origin, is_debug);
}

pub fn checkScope(grants: *const GrantTable, window_label: []const u8, command: []const u8, scope_input: ScopeInput, bases: Bases, io: std.Io, base_dir: std.Io.Dir) Decision {
    return g4(grants, window_label, command, scope_input, bases, io, base_dir);
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

test "originAllowed mirrors evaluate's G1 for a window label" {
    const caps = [_]cap.Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"core:default"} }};
    var table = try gt(&caps);
    defer table.deinit();
    try std.testing.expect(originAllowed(&table, "main", "app://localhost", false));
    try std.testing.expect(!originAllowed(&table, "main", "https://evil.example", false));
}

test "checkScope runs only G4 and denies an out-of-scope label" {
    const caps = [_]cap.Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"core:default"} }};
    var table = try gt(&caps);
    defer table.deinit();
    const bases = Bases{ .appdata = "/a", .home = "/h", .appconfig = "/c" };
    const d = checkScope(&table, "main", "window.create", .{ .label = "secret" }, bases, std.testing.io, std.Io.Dir.cwd());
    try std.testing.expectEqual(Gate.g4_scope, d.deny.gate);
    try std.testing.expectEqualStrings("scope.label.no_match", d.deny.code);
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

test "G1: devUrl honored only in debug" {
    const caps = [_]cap.Capability{.{ .identifier = "c", .windows = &.{"main"}, .origins = &.{ .app_scheme, .{ .devUrl = "http://localhost:1420" } }, .permissions = &.{"core:default"} }};
    var table = try gt(&caps);
    defer table.deinit();
    const bases = Bases{ .appdata = "/a", .home = "/h", .appconfig = "/c" };
    // In Debug: devUrl is in the compiled trust set, so the runtime is_debug gate
    // is the deciding factor. In ReleaseSafe: devUrl is dropped from the compiled
    // trust set at compile time (belt beyond the runtime gate), so even is_debug=true
    // at runtime denies.
    if (comptime builtin.mode == .Debug) {
        try std.testing.expect(evaluate(&table, ctxFor("http://localhost:1420", "window.setTitle", true), bases, std.testing.io, std.Io.Dir.cwd()) == .allow);
    }
    const d = evaluate(&table, ctxFor("http://localhost:1420", "window.setTitle", false), bases, std.testing.io, std.Io.Dir.cwd());
    try std.testing.expectEqualStrings("origin.untrusted", d.deny.code); // always denied when is_debug=false
}

test "G4: a .none command allows immediately" {
    const caps = [_]cap.Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"core:default"} }};
    var table = try gt(&caps);
    defer table.deinit();
    const bases = Bases{ .appdata = "/a", .home = "/h", .appconfig = "/c" };
    try std.testing.expect(evaluate(&table, ctxFor("app://localhost", "compute.cancel", false), bases, std.testing.io, std.Io.Dir.cwd()) == .allow);
}

test "fuzz: only the three origin shapes ever accept (manual >= 10000)" {
    // Three origin patterns matching the live gate's trust set:
    //   app_scheme           -> app://localhost and app://localhost/<path>
    //   devUrl              -> exact http://localhost:1420
    //   httpsExact          -> exact https://x.example
    const origins = [_]cap.OriginPattern{
        .app_scheme,
        .{ .devUrl = "http://localhost:1420" },
        .{ .httpsExact = "https://x.example" },
    };
    // Known-good seeds: mutations of these land near the boundary and reliably hit
    // the accept branches, giving the tight oracle real work to do.
    const seeds = [_][]const u8{
        "app://localhost",
        "app://localhost/x",
        "http://localhost:1420",
        "https://x.example",
    };
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed ^ 0xC0FFEE);
    const rand = prng.random();
    var accepted_hits: usize = 0;
    var it: usize = 0;
    while (it < 10_000) : (it += 1) {
        var buf: [64]u8 = undefined;
        var candidate: []u8 = undefined;
        var n: usize = undefined;
        // Half the time: raw random bytes (reject-path stress, keep this).
        // Half the time: mutate a known-good seed to land near the boundary.
        if (rand.uintLessThan(u8, 2) == 0) {
            n = rand.uintLessThan(usize, buf.len);
            rand.bytes(buf[0..n]);
            candidate = buf[0..n];
        } else {
            const seed = seeds[rand.uintLessThan(usize, seeds.len)];
            @memcpy(buf[0..seed.len], seed);
            n = seed.len;
            // Apply a small random mutation: truncate, append, or flip a byte.
            switch (rand.uintLessThan(u8, 3)) {
                0 => { // truncate by 1..3 bytes
                    const k = rand.uintLessThan(usize, 3) + 1;
                    n = if (n > k) n - k else 0;
                },
                1 => { // append a random byte (if room)
                    if (n < buf.len) {
                        buf[n] = rand.int(u8);
                        n += 1;
                    }
                },
                else => { // flip one byte at a random position
                    if (n > 0) {
                        const pos = rand.uintLessThan(usize, n);
                        buf[pos] = rand.int(u8);
                    }
                },
            }
            candidate = buf[0..n];
        }
        const accepted = originTrusted(&origins, candidate, true);
        if (accepted) {
            accepted_hits += 1;
            const o = candidate;
            // SECURITY INVARIANT: only the exact known-trusted origin shapes may be
            // accepted. Any other byte sequence must be rejected. If this fires, it
            // is a REAL bypass in originTrusted; do NOT weaken the oracle.
            //
            // app_scheme covers:
            //   "app://localhost"        (bare, no path)
            //   "app://localhost/<path>" (with slash-prefixed path)
            // devUrl: exact string match "http://localhost:1420"
            // httpsExact: exact string match "https://x.example"
            const ok = std.mem.startsWith(u8, o, "app://localhost/") or
                std.mem.eql(u8, o, "app://localhost") or
                std.mem.eql(u8, o, "http://localhost:1420") or
                std.mem.eql(u8, o, "https://x.example");
            try std.testing.expect(ok);
        }
    }
    // Teeth check: the mutation strategy must have reached the accept branch a
    // non-trivial number of times. If this fails, the fuzz vocabulary stopped
    // covering the trust set (e.g. all seeds rejected), which is itself a bug.
    try std.testing.expect(accepted_hits > 0);
}
