const std = @import("std");
// objc is imported as a named module rather than a relative path. All
// src/platform/macos/* files import it this way so src/objc.zig belongs to a
// single module ("objc") across every graph; a relative "../../objc.zig" here
// would also escape this file's module root when it is rooted as a standalone
// logic-test module. build.zig wires the `objc` module on every graph that
// compiles these files (the exe, the scaffold tests, and the origin logic test).
const objc = @import("objc");

pub const MAX_HOST_LEN: usize = 4096;

/// Sentinel returned when an origin cannot be read. NOT "" so deny-by-default
/// is unambiguous: a gate that sees this string denies (H6).
pub const UNREADABLE = "app:zigware:unreadable";

/// Format an origin as `protocol://host[:port]` into the caller's buffer.
/// `port == 0` omits the port (the WKSecurityOrigin convention for the scheme's
/// default port). Returns the written slice. Uses std.Io.Writer.fixed (capital
/// I), per the plan conventions (B5). On overflow returns the writer's error.
pub fn formatOrigin(buf: []u8, protocol: []const u8, host: []const u8, port: u16) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print("{s}://{s}", .{ protocol, host });
    if (port != 0) try w.print(":{d}", .{port});
    return w.buffered();
}

/// Read protocol/host/port out of a WKSecurityOrigin and format the origin into
/// the caller's buffer. Returns UNREADABLE on any null/unreadable component so
/// the result never aliases "" (H6). isKindOf-gates each objc.id before utf8;
/// bounds the host/proto walk at MAX_HOST_LEN.
pub fn readSecurityOrigin(buf: []u8, sec_origin: objc.id) []const u8 {
    if (@intFromPtr(sec_origin) == 0) return UNREADABLE; // L8: null check via intFromPtr
    const NSString = objc.class("NSString");

    const protoObj = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(sec_origin, objc.sel("protocol"));
    if (!objc.isKindOf(protoObj, NSString)) return UNREADABLE;
    const hostObj = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(sec_origin, objc.sel("host"));
    if (!objc.isKindOf(hostObj, NSString)) return UNREADABLE;
    // WKSecurityOrigin.port is an NSInteger (i64); 0 means the scheme default.
    // A negative or >65535 value would panic @intCast in ReleaseSafe, so cast
    // safely and fail closed on anything out of u16 range (H4).
    const raw_port = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) i64)(sec_origin, objc.sel("port"));
    const port: u16 = std.math.cast(u16, raw_port) orelse return UNREADABLE;

    const protoC = objc.utf8(protoObj) orelse return UNREADABLE;
    const hostC = objc.utf8(hostObj) orelse return UNREADABLE;
    const proto = boundedSpan(protoC, MAX_HOST_LEN) orelse return UNREADABLE;
    const host = boundedSpan(hostC, MAX_HOST_LEN) orelse return UNREADABLE;
    return formatOrigin(buf, proto, host, port) catch UNREADABLE;
}

/// std.mem.span with an explicit cap so an unterminated C string cannot drive
/// an unbounded read. Returns null if no NUL within `max`.
fn boundedSpan(c: [*:0]const u8, max: usize) ?[]const u8 {
    var i: usize = 0;
    while (i < max and c[i] != 0) : (i += 1) {}
    if (i == max) return null;
    return c[0..i];
}

test "formatOrigin omits the port when it is zero" {
    var buf: [128]u8 = undefined;
    const got = try formatOrigin(&buf, "app", "localhost", 0);
    try std.testing.expectEqualStrings("app://localhost", got);
}

test "formatOrigin includes a non-zero port" {
    var buf: [128]u8 = undefined;
    const got = try formatOrigin(&buf, "http", "localhost", 5173);
    try std.testing.expectEqualStrings("http://localhost:5173", got);
}

test "formatOrigin handles empty host" {
    var buf: [128]u8 = undefined;
    const got = try formatOrigin(&buf, "app", "", 0);
    try std.testing.expectEqualStrings("app://", got);
}

test "formatOrigin overflow returns the writer error" {
    var buf: [4]u8 = undefined;
    const r = formatOrigin(&buf, "https", "example.com", 8443);
    // std.Io.Writer.fixed reports overflow as error.WriteFailed in 0.16.0.
    try std.testing.expectError(error.WriteFailed, r);
}

test "manual fuzz: formatOrigin tolerates adversarial host/proto bytes" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();
    var it: usize = 0;
    while (it < 10_000) : (it += 1) {
        var hb: [64]u8 = undefined;
        var pb: [16]u8 = undefined;
        const hn = rand.uintLessThan(usize, hb.len);
        const pn = rand.uintLessThan(usize, pb.len);
        rand.bytes(hb[0..hn]);
        rand.bytes(pb[0..pn]);
        var out: [256]u8 = undefined;
        _ = formatOrigin(&out, pb[0..pn], hb[0..hn], rand.int(u16)) catch {};
    }
}
