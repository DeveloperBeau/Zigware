const std = @import("std");

/// True if `text` matches `pattern`. Segments are split on '/'. `**` matches zero
/// or more whole segments; within a segment `*` matches zero or more bytes and
/// `?` matches exactly one byte; all other bytes are exact. Recursive with a
/// bound: pattern and text are short (paths/labels), so the recursion depth is
/// bounded by segment count.
pub fn match(pattern: []const u8, text: []const u8) bool {
    const p = splitSegs(pattern);
    const t = splitSegs(text);
    // FAIL-CLOSED on overflow (SECURITY): an input with more than 64 segments
    // cannot be represented. Silently truncating would drop trailing segments and
    // could false-allow -- e.g. `a/**/b` vs `a/<62 junk>/b/EXTRA` truncates to
    // `[a, ..., b]` and wrongly matches. Treat any >64-segment input as NO MATCH:
    // a long candidate then gets no allow (-> denied in pathMatches), and a long
    // pattern is malformed (-> no match). This is the safe direction.
    if (p.overflow or t.overflow) return false;
    return mseg(p.items[0..p.len], t.items[0..t.len]);
}

const Segs = struct { items: [64][]const u8 = undefined, len: usize = 0, overflow: bool = false };

fn splitSegs(s: []const u8) Segs {
    var segs: Segs = .{};
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| {
        if (segs.len >= segs.items.len) {
            segs.overflow = true; // too many segments; caller fails closed
            return segs;
        }
        segs.items[segs.len] = seg;
        segs.len += 1;
    }
    return segs;
}

fn mseg(p: []const []const u8, t: []const []const u8) bool {
    if (p.len == 0) return t.len == 0;
    if (std.mem.eql(u8, p[0], "**")) {
        // ** matches zero or more segments: try consuming 0..t.len segments.
        var i: usize = 0;
        while (i <= t.len) : (i += 1) {
            if (mseg(p[1..], t[i..])) return true;
        }
        return false;
    }
    if (t.len == 0) return false;
    if (!matchOne(p[0], t[0])) return false;
    return mseg(p[1..], t[1..]);
}

/// Single-segment match: `*` is zero-or-more bytes, `?` is one byte, else exact.
fn matchOne(pat: []const u8, seg: []const u8) bool {
    // Classic two-pointer wildcard match with backtracking on '*'.
    var pi: usize = 0;
    var si: usize = 0;
    var star: ?usize = null;
    var star_si: usize = 0;
    while (si < seg.len) {
        if (pi < pat.len and (pat[pi] == seg[si] or pat[pi] == '?')) {
            pi += 1;
            si += 1;
        } else if (pi < pat.len and pat[pi] == '*') {
            star = pi;
            star_si = si;
            pi += 1;
        } else if (star) |sp| {
            pi = sp + 1;
            star_si += 1;
            si = star_si;
        } else return false;
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

test "glob: exact, single-segment star, question, and ** across segments" {
    try std.testing.expect(match("a/b/c", "a/b/c"));
    try std.testing.expect(!match("a/b/c", "a/b/d"));
    try std.testing.expect(match("a/*/c", "a/zzz/c"));
    try std.testing.expect(!match("a/*/c", "a/z/z/c")); // * stays within a segment
    try std.testing.expect(match("a/**/c", "a/x/y/c"));
    try std.testing.expect(match("a/**/c", "a/c")); // ** matches zero segments
    try std.testing.expect(match("a/**", "a/x/y/z"));
    try std.testing.expect(match("**", "anything/at/all"));
    try std.testing.expect(match("a?c", "abc"));
    try std.testing.expect(!match("a?c", "ac"));
    try std.testing.expect(match("*.txt", "report.txt"));
    try std.testing.expect(!match("*.txt", "report.md"));
}

test "glob: label-style single-segment matches" {
    try std.testing.expect(match("main", "main"));
    try std.testing.expect(match("win-*", "win-3"));
    try std.testing.expect(match("*", "anything"));
    try std.testing.expect(!match("win-*", "main"));
}

test "glob: >64-segment input fails closed (no false allow via truncation)" {
    // Build a 65-segment text that, truncated to 64, WOULD match a/**/b: a / 62 junk / b / EXTRA.
    var buf: [256]u8 = undefined;
    var w: usize = 0;
    @memcpy(buf[w .. w + 2], "a/");
    w += 2;
    var i: usize = 0;
    while (i < 62) : (i += 1) {
        @memcpy(buf[w .. w + 2], "x/");
        w += 2;
    }
    @memcpy(buf[w .. w + 2], "b/");
    w += 2;
    @memcpy(buf[w .. w + 5], "EXTRA");
    w += 5;
    try std.testing.expect(!match("a/**/b", buf[0..w])); // overflow -> fail closed, NOT a truncated match
    // A normal-depth path still matches.
    try std.testing.expect(match("a/**/b", "a/x/y/b"));
}
