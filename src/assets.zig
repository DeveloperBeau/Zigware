const std = @import("std");
const seam = @import("platform/backend.zig");
const protocol = @import("protocol.zig");

const index_html_embed = @embedFile("frontend/index.html");
const app_js_embed = @embedFile("frontend/app.js");
const zigware_js_embed = @embedFile("frontend/zigware.js");

// Comptime table of every path that may legitimately return 200, with the exact
// body and mime each must serve. The fuzz oracle asserts against the BODY CONTENT
// and the MIME so a corrupted asset table that returns the wrong body, or serves
// /app.js as text/html, is caught (the previous pointer-identity check compared a
// slice against itself and proved nothing).
const KnownAsset = struct { path: []const u8, body: []const u8, mime: []const u8 };
const known_paths = [_]KnownAsset{
    .{ .path = "/", .body = index_html_embed, .mime = "text/html" },
    .{ .path = "/index.html", .body = index_html_embed, .mime = "text/html" },
    .{ .path = "/app.js", .body = app_js_embed, .mime = "text/javascript" },
    .{ .path = "/zigware.js", .body = zigware_js_embed, .mime = "text/javascript" },
};

// Reserved internal routes are declared in protocol.zig because sub-project B
// will add wire-level routes (the binary streaming scheme) to the same list;
// protocol.zig is the single source of truth so the asset allowlist and the
// command gate never drift. This asset table replaces src/scheme.zig's PoC
// table (cross-checked before Task 10 deletes that file).

fn notFound() seam.Response {
    return .{ .status = 404, .mime = "text/plain", .body = "", .kind = .embedded_static };
}

/// Resolve an `app://` path to an embedded asset. Reserved internal routes and
/// unknown paths return 404. Pure logic, no platform dependency. Every body is
/// an @embedFile slice, so `kind` is always `.embedded_static`.
pub fn serveAsset(path: []const u8) seam.Response {
    if (protocol.isReservedRoute(path)) return notFound();
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        return .{ .status = 200, .mime = "text/html", .body = index_html_embed, .kind = .embedded_static };
    }
    if (std.mem.eql(u8, path, "/app.js")) {
        return .{ .status = 200, .mime = "text/javascript", .body = app_js_embed, .kind = .embedded_static };
    }
    if (std.mem.eql(u8, path, "/zigware.js")) {
        return .{ .status = 200, .mime = "text/javascript", .body = zigware_js_embed, .kind = .embedded_static };
    }
    return notFound();
}

test "serves known paths with 200 and the right mime" {
    const idx = serveAsset("/index.html");
    try std.testing.expectEqual(@as(u16, 200), idx.status);
    try std.testing.expectEqualStrings("text/html", idx.mime);
    try std.testing.expect(idx.body.len > 0);
    try std.testing.expectEqual(@as(@TypeOf(idx.kind), .embedded_static), idx.kind);

    const root = serveAsset("/");
    try std.testing.expectEqual(@as(u16, 200), root.status);

    const js = serveAsset("/app.js");
    try std.testing.expectEqual(@as(u16, 200), js.status);
    try std.testing.expectEqualStrings("text/javascript", js.mime);
}

test "unknown path is 404" {
    const r = serveAsset("/secret.txt");
    try std.testing.expectEqual(@as(u16, 404), r.status);
}

test "reserved internal route: isReservedRoute true AND serveAsset 404" {
    const reserved = [_][]const u8{
        "/__zigware_stream",
        "/__zigware_stream/1/0",
        "/__zigware_stream/anything/here",
    };
    for (reserved) |p| {
        try std.testing.expect(protocol.isReservedRoute(p));
        try std.testing.expectEqual(@as(u16, 404), serveAsset(p).status);
    }
}

test "reserved-route boundary attackers: isReservedRoute false AND serveAsset 404" {
    // These would slip past a bare startsWith; they are NOT reserved and are
    // also NOT known assets, so they must 404 (not 200, not crash).
    const attackers = [_][]const u8{
        "/__zigware_streamattack",
        "/__zigware_stream_x",
        "/__zigware_streamabc/foo",
    };
    for (attackers) |p| {
        try std.testing.expect(!protocol.isReservedRoute(p));
        try std.testing.expectEqual(@as(u16, 404), serveAsset(p).status);
    }
}

test "adversarial known-prefix vectors never 200" {
    const cases = [_][]const u8{
        "/index.html/", // trailing slash is not the known path
        "/__zigware_stream/../index.html", // traversal through a reserved prefix
        "/index.html?../etc/passwd", // query-style traversal
        "", // empty path
    };
    for (cases) |p| {
        try std.testing.expect(serveAsset(p).status != 200);
    }
}

// ── Native fuzz bodies (run once under `zig build test` per the 0.16 bug) ──

test "fuzz: serveAsset oracle (native)" {
    try std.testing.fuzz({}, fuzzServeAsset, .{});
}

test "fuzz: serveAsset pathological (native)" {
    try std.testing.fuzz({}, fuzzServeAssetPathological, .{});
}

// ── Manual fuzz drivers (finding H14): >= 10000 iterations, deterministic ──

test "fuzz: serveAsset oracle (manual >= 10000 iterations)" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        // Uniformly random bytes essentially never spell "/index.html", so this
        // driver exercises the no-panic and no-false-200 properties on long,
        // arbitrary input rather than known-path collision coverage. The exact
        // known-path contract is pinned by the unit tests above.
        var buf: [16 * 1024]u8 = undefined;
        const n = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..n]) |*c| c.* = rand.int(u8);
        try checkServeAssetOracle(buf[0..n]);
    }
}

fn fuzzServeAsset(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [16 * 1024]u8 = undefined;
    const n = smith.slice(&buf);
    try checkServeAssetOracle(buf[0..n]);
}

/// Shared oracle, bidirectional so it alone pins the contract both ways (mirrors
/// protocol.zig's checkReservedInvariant). Reserved routes never 200. If `path`
/// exactly equals a known_paths entry it MUST 200 with that entry's exact body
/// and mime (catches a regression to 404, or a corrupted table). If it does not
/// equal any known entry it MUST 404 (catches a spurious 200). Body/mime are
/// content comparisons, not pointer identity.
fn checkServeAssetOracle(path: []const u8) !void {
    const r = serveAsset(path);

    if (protocol.isReservedRoute(path)) {
        try std.testing.expectEqual(@as(u16, 404), r.status);
        return;
    }

    var known: ?KnownAsset = null;
    for (known_paths) |k| {
        if (std.mem.eql(u8, k.path, path)) {
            known = k;
            break;
        }
    }

    if (known) |k| {
        // Forward direction: a known path must serve its exact contract.
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expectEqualStrings(k.body, r.body);
        try std.testing.expectEqualStrings(k.mime, r.mime);
    } else {
        // Reverse direction: anything not in the table must 404, never 200.
        try std.testing.expectEqual(@as(u16, 404), r.status);
    }
}

fn fuzzServeAssetPathological(_: void, smith: *std.testing.Smith) anyerror!void {
    const cases = [_][]const u8{
        "",
        "/",
        "/\x00/index.html", // NUL injection
        "/\x01\x02\x03", // control chars
        "/index.html?../etc/passwd", // path traversal attempt
        "/index.html\r\nLocation: evil", // header-injection style
    };
    for (cases) |path| {
        const r = serveAsset(path);
        try std.testing.expect(r.status == 200 or r.status == 404);
    }
    var buf: [16 * 1024]u8 = undefined;
    const n = smith.slice(&buf);
    const r = serveAsset(buf[0..n]);
    try std.testing.expect(r.status == 200 or r.status == 404);
}
