const std = @import("std");
const cap = @import("../capability.zig");
const glob = @import("glob.zig");
const grant = @import("../grant_table.zig");

const Scope = cap.Scope;
const ScopeSet = grant.ScopeSet;

pub const Bases = struct {
    appdata: []const u8, // $APPDATA, absolute
    home: []const u8, // $HOME, absolute
    appconfig: []const u8, // $APPCONFIG, absolute
};

/// Expand a leading $TOKEN to its base. Returns null (-> deny) on an unknown
/// $TOKEN so there is no silent literal pass-through. Writes into `out` (caller
/// buffer); returns the used slice.
fn expandTokens(out: []u8, s: []const u8, bases: Bases) ?[]const u8 {
    const map = [_]struct { tok: []const u8, val: []const u8 }{
        .{ .tok = "$APPDATA", .val = bases.appdata },
        .{ .tok = "$HOME", .val = bases.home },
        .{ .tok = "$APPCONFIG", .val = bases.appconfig },
    };
    if (s.len > 0 and s[0] == '$') {
        for (map) |m| {
            // Require a token BOUNDARY after the match (end-of-string or '/') so
            // $APPDATA does not alias a future $APPDATABASE token.
            if (std.mem.startsWith(u8, s, m.tok) and (s.len == m.tok.len or s[m.tok.len] == '/')) {
                const rest = s[m.tok.len..];
                const total = m.val.len + rest.len;
                if (total > out.len) return null;
                @memcpy(out[0..m.val.len], m.val);
                @memcpy(out[m.val.len..total], rest);
                return out[0..total];
            }
        }
        return null; // unknown $TOKEN -> deny
    }
    if (s.len > out.len) return null;
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
}

/// G4 path matcher. Order is fixed (security-critical):
/// 1. Expand $TOKENs in candidate and patterns (unknown token -> deny).
/// 2. Canonicalize the candidate via realpath (resolves ., .., ~, symlinks).
///    For create/write a non-existent leaf, canonicalize the PARENT then rejoin
///    the literal leaf (see the create/write path below).
/// 3. Canonicalize each pattern's literal (non-glob) prefix the same way.
/// 4. Glob-match the canonical candidate against canonical patterns; deny first,
///    then require an allow. Unresolvable candidate -> deny (fail-closed), so the
///    no-match and resolve-failure paths are indistinguishable to the caller.
///
/// CALLER CONTRACT + KNOWN LIMITATIONS (all LOW, from the C security review):
///  - base_dir anchoring: relative candidates and a pattern's literal prefix
///    resolve against the passed `base_dir` HANDLE, not the process CWD. The
///    matcher's safety is conditional on the caller passing the correct app-data
///    dir handle.
///  - TOCTOU: this resolves at G4, but the handler opens the path LATER; a symlink
///    swapped between check and open defeats the canonical result. The future fs
///    handler MUST open with O_NOFOLLOW or re-verify the resulting fd against the
///    canonical scope. v0.1.0 has no scoped command (all .none), so nothing opens
///    a scoped path yet.
///  - Case-insensitive filesystems (macOS APFS): the glob TAIL is byte-exact, so an
///    AUTHOR who miscases a deny pattern (`*.KEY` vs on-disk `k.key`) can have the
///    deny bypassed. NOT attacker-drivable (realpath normalizes the attacker
///    candidate to on-disk case) and the app author is trusted, so this is an
///    author footgun, not an escape.
pub fn pathMatches(io: std.Io, base_dir: std.Io.Dir, set: ScopeSet, candidate: []const u8, bases: Bases) bool {
    var cand_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const expanded = expandTokens(&cand_buf, candidate, bases) orelse return false;
    // realPathFile returns the LENGTH written into real_buf (0.16); slice it.
    // Fail-closed: an unresolvable candidate (broken symlink, missing path) denies.
    const cn = base_dir.realPathFile(io, expanded, &real_buf) catch return false;
    const canon = real_buf[0..cn];

    // TODO(fs:write): canonicalize parent then rejoin leaf for create commands

    // Deny first.
    for (set.deny) |s| switch (s) {
        .path => |pat| if (matchPattern(io, base_dir, pat, canon, bases)) return false,
        else => {},
    };
    // Require an allow.
    for (set.allow) |s| switch (s) {
        .path => |pat| if (matchPattern(io, base_dir, pat, canon, bases)) return true,
        else => {},
    };
    return false; // no allow matched -> deny
}

/// Canonicalize a pattern's literal prefix, then glob-match the canonical
/// candidate against (canonical-prefix ++ glob-tail). The glob tail (from the
/// first wildcard segment on) is matched literally, never re-realpath'd.
fn matchPattern(io: std.Io, base_dir: std.Io.Dir, pattern: []const u8, canon_candidate: []const u8, bases: Bases) bool {
    var pat_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const expanded = expandTokens(&pat_buf, pattern, bases) orelse return false;
    // Split at the first wildcard segment.
    const wc = firstWildcard(expanded);
    if (wc == null) {
        // No glob: canonicalize the whole pattern and require an exact match.
        // SECURITY NOTE (latent, INERT in v0.1.0): realPathFile requires the
        // pattern path to EXIST; a no-glob DENY rule naming a not-yet-created file
        // resolves to `return false` and is silently dropped (deny-side fail-open
        // vs "deny always wins"). v0.1.0 has no live scoped command, and deny-exact
        // unit tests create the file, so this never bites. D's fs:write work MUST
        // revisit this together with the deferred parent-canonicalization branch
        // (canonicalize the pattern's parent dir, not the leaf, for deny rules too).
        var pr_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const pn = base_dir.realPathFile(io, expanded, &pr_buf) catch return false;
        return std.mem.eql(u8, pr_buf[0..pn], canon_candidate);
    }
    const split = wc.?;
    const literal_prefix = expanded[0..split]; // ends at a '/'
    const glob_tail = expanded[split..];
    var pr_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const ppn = base_dir.realPathFile(io, if (literal_prefix.len == 0) "." else literal_prefix, &pr_buf) catch return false;
    const canon_prefix = pr_buf[0..ppn];
    // The canonical candidate must start with canon_prefix AT A SEGMENT BOUNDARY.
    // SECURITY: a bare startsWith lets `/a/foo/**` match `/a/foobar/x` (foobar
    // starts with foo) — an out-of-scope escape. Require the candidate to equal the
    // prefix or have a '/' immediately after it.
    if (!std.mem.startsWith(u8, canon_candidate, canon_prefix)) return false;
    if (canon_candidate.len != canon_prefix.len and canon_candidate[canon_prefix.len] != '/') return false;
    var tail = canon_candidate[canon_prefix.len..];
    if (tail.len > 0 and tail[0] == '/') tail = tail[1..];
    const gtail = if (glob_tail.len > 0 and glob_tail[0] == '/') glob_tail[1..] else glob_tail;
    return glob.match(gtail, tail);
}

/// Byte offset of the start of the first segment containing a wildcard, or null.
fn firstWildcard(s: []const u8) ?usize {
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '/') {
            seg_start = i + 1;
        } else if (s[i] == '*' or s[i] == '?') {
            return seg_start;
        }
    }
    return null;
}

test "in-base path allows; traversal escape denies" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Build an absolute base path and an $APPDATA pointing at it.
    var base_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const bn = try tmp.dir.realPath(io, &base_path_buf);
    const base_path = base_path_buf[0..bn];
    // Create $APPDATA/notes/a.txt
    try tmp.dir.createDirPath(io, "notes");
    var f = try tmp.dir.createFile(io, "notes/a.txt", .{});
    f.close(io);

    const bases = Bases{ .appdata = base_path, .home = base_path, .appconfig = base_path };
    const allow_set = ScopeSet{ .allow = &.{.{ .path = "$APPDATA/notes/**" }}, .deny = &.{} };

    // In-base file: allow.
    {
        var c: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cand = try std.fmt.bufPrint(&c, "{s}/notes/a.txt", .{base_path});
        try std.testing.expect(pathMatches(io, tmp.dir, allow_set, cand, bases));
    }
    // Traversal escape: deny (realpath resolves the .. and it leaves $APPDATA/notes).
    {
        var c: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cand = try std.fmt.bufPrint(&c, "{s}/notes/../../etc/passwd", .{base_path});
        try std.testing.expect(!pathMatches(io, tmp.dir, allow_set, cand, bases));
    }
}

test "unknown $TOKEN denies" {
    const bases = Bases{ .appdata = "/a", .home = "/h", .appconfig = "/c" };
    const set = ScopeSet{ .allow = &.{.{ .path = "$NOPE/x" }}, .deny = &.{} };
    try std.testing.expect(!pathMatches(std.testing.io, std.Io.Dir.cwd(), set, "/a/x", bases));
}

test "deny pattern beats allow pattern" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bp: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const bn = try tmp.dir.realPath(io, &bp);
    const base = bp[0..bn];
    try tmp.dir.createDirPath(io, "secret");
    var f = try tmp.dir.createFile(io, "secret/k.txt", .{});
    f.close(io);
    const bases = Bases{ .appdata = base, .home = base, .appconfig = base };
    const set = ScopeSet{ .allow = &.{.{ .path = "$APPDATA/**" }}, .deny = &.{.{ .path = "$APPDATA/secret/**" }} };
    var c: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cand = try std.fmt.bufPrint(&c, "{s}/secret/k.txt", .{base});
    try std.testing.expect(!pathMatches(io, tmp.dir, set, cand, bases)); // deny wins
}

test "symlink escaping the base denies" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bp: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const bn = try tmp.dir.realPath(io, &bp);
    const base = bp[0..bn];
    try tmp.dir.createDirPath(io, "inside");
    // Create a symlink inside -> "/" (outside the base). Skip if unsupported on the host.
    tmp.dir.symLink(io, "/", "inside/escape", .{}) catch return;
    const bases = Bases{ .appdata = base, .home = base, .appconfig = base };
    const set = ScopeSet{ .allow = &.{.{ .path = "$APPDATA/inside/**" }}, .deny = &.{} };
    var c: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cand = try std.fmt.bufPrint(&c, "{s}/inside/escape/etc", .{base});
    try std.testing.expect(!pathMatches(io, tmp.dir, set, cand, bases)); // realpath follows the symlink out
}

test "scoped command with an empty scope set denies any path" {
    try std.testing.expect(!pathMatches(std.testing.io, std.Io.Dir.cwd(), ScopeSet.empty, "/anything", .{ .appdata = "/a", .home = "/h", .appconfig = "/c" }));
}

test "segment-boundary: $APPDATA/foo/** must NOT match a /foobar sibling" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bp: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const bn = try tmp.dir.realPath(io, &bp);
    const base = bp[0..bn];
    try tmp.dir.createDirPath(io, "foo");
    try tmp.dir.createDirPath(io, "foobar");
    var f = try tmp.dir.createFile(io, "foobar/x", .{});
    f.close(io);
    const bases = Bases{ .appdata = base, .home = base, .appconfig = base };
    const set = ScopeSet{ .allow = &.{.{ .path = "$APPDATA/foo/**" }}, .deny = &.{} };
    var c: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cand = try std.fmt.bufPrint(&c, "{s}/foobar/x", .{base});
    try std.testing.expect(!pathMatches(io, tmp.dir, set, cand, bases)); // foobar is NOT under foo/
}
