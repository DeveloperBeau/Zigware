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

test "fuzz: pathMatches never allows an escape (manual >= 10000)" {
    const io = std.testing.io;
    // One temp dir reused across all iterations (fast: no per-iter tmpDir creation).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bp: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const bn = try tmp.dir.realPath(io, &bp);
    const base = bp[0..bn];
    // Create the allowed zone: $APPDATA/ok/f.
    // ALSO create an on-disk sibling $APPDATA/okf/f — a path whose canonical form
    // starts with base/ok but violates the segment boundary (base/okf, not base/ok/).
    // Without the boundary fix, a bare startsWith would match okf/f against
    // $APPDATA/ok/**, producing a false allow (escape). The fuzz MUST catch that.
    try tmp.dir.createDirPath(io, "ok");
    var f = try tmp.dir.createFile(io, "ok/f", .{});
    f.close(io);
    try tmp.dir.createDirPath(io, "okf");
    var g = try tmp.dir.createFile(io, "okf/f", .{});
    g.close(io);
    const bases = Bases{ .appdata = base, .home = base, .appconfig = base };
    const allow_set = ScopeSet{ .allow = &.{.{ .path = "$APPDATA/ok/**" }}, .deny = &.{} };

    // Build the canonical ok_base once so we can check the segment boundary.
    var okb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const ok_base = try std.fmt.bufPrint(&okb, "{s}/ok", .{base});

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();
    // Segment vocabulary: mixing "ok", "okf", "f", and ".." ensures:
    //   - ok/f         -> canonical base/ok/f   -> ALLOW (hits invariant branch)
    //   - okf/f        -> canonical base/okf/f  -> DENY  (boundary escape probe)
    //   - ok/../okf/f  -> canonical base/okf/f  -> DENY  (traversal variant)
    //   - ok/../../x   -> base parent           -> DENY  (out-of-tree escape)
    // Using segment vocabulary (not a char alphabet) ensures valid on-disk paths
    // appear on a predictable fraction of iterations so allowed_hits is never ~0.
    const segs = [_][]const u8{ "ok", "okf", "f", ".." };
    var allowed_hits: usize = 0;
    var it: usize = 0;
    while (it < 10_000) : (it += 1) {
        // Build a candidate from 1-6 random segments.
        var cb: [512]u8 = undefined;
        var pos: usize = 0;
        const nseg = 1 + rand.uintLessThan(usize, 6);
        for (0..nseg) |si| {
            const seg = segs[rand.uintLessThan(usize, segs.len)];
            if (si > 0) {
                if (pos >= cb.len) break;
                cb[pos] = '/';
                pos += 1;
            }
            if (pos + seg.len > cb.len) break;
            @memcpy(cb[pos .. pos + seg.len], seg);
            pos += seg.len;
        }
        var full: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cand = std.fmt.bufPrint(&full, "{s}/{s}", .{ base, cb[0..pos] }) catch continue;
        if (pathMatches(io, tmp.dir, allow_set, cand, bases)) {
            allowed_hits += 1;
            // SECURITY INVARIANT: if allowed, the canonical path MUST be under
            // base/ok AT A SEGMENT BOUNDARY. A bare startsWith would pass base/okf —
            // tighten to require canon == ok_base or canon[ok_base.len] == '/'.
            // If this assertion fires it is a REAL security bug; do NOT weaken.
            var rb: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const rn = tmp.dir.realPathFile(io, cand, &rb) catch continue;
            const canon = rb[0..rn];
            try std.testing.expect(std.mem.startsWith(u8, canon, ok_base));
            try std.testing.expect(canon.len == ok_base.len or canon[ok_base.len] == '/');
        }
    }
    // TEETH CHECK: the allow branch must fire on a non-trivial fraction of
    // iterations. If this fails, the fuzz alphabet/vocab cannot reach the allowed
    // zone and the invariant assertion above is never exercised (toothless fuzz).
    try std.testing.expect(allowed_hits > 0);
}

// macOS case-insensitivity caveat (C security review C2):
//
// On a case-insensitive filesystem (macOS APFS default), realPathFile normalises
// the on-disk CASE of the candidate. The glob TAIL however is matched byte-exact
// (no case folding). This means an author who writes a deny pattern with the
// wrong case — e.g. `*.KEY` when the file on disk is `k.key` — will find the
// deny silently inactive, because the canonical candidate (`…/k.key`) does not
// byte-match `*.KEY`.
//
// THIS IS NOT ATTACKER-DRIVABLE: the attacker provides the candidate path, not
// the deny pattern. realPathFile resolves the candidate to its exact on-disk
// name, so an attacker cannot choose which case the canonical string uses.
//
// This is an AUTHOR FOOTGUN: the app author (trusted) who typos a deny pattern
// case produces a deny that never fires. The workaround is simple: always match
// the deny glob case to the on-disk file case, or use a case-insensitive glob.
// Fixing this properly (case-fold both pattern tail and canonical path) is
// deferred until a real `fs:` command lands (sub-project D).
//
// DOCUMENTED BEHAVIOR (asserted below): the deny does NOT fire => pathMatches
// returns TRUE (the allow fires instead). This is the known author-footgun state.
test "case-insensitivity caveat: mismatched deny pattern case does not fire (author footgun)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bp: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const bn = try tmp.dir.realPath(io, &bp);
    const base = bp[0..bn];
    // Create `k.key` on disk (lowercase).
    var fk = try tmp.dir.createFile(io, "k.key", .{});
    fk.close(io);
    const bases = Bases{ .appdata = base, .home = base, .appconfig = base };
    // Allow everything; deny only `*.KEY` (uppercase extension — mismatched case).
    const set = ScopeSet{
        .allow = &.{.{ .path = "$APPDATA/**" }},
        .deny = &.{.{ .path = "$APPDATA/**/*.KEY" }},
    };
    var c: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cand = try std.fmt.bufPrint(&c, "{s}/k.key", .{base});
    // DOCUMENTED BEHAVIOR: on a case-insensitive FS the deny glob `*.KEY` does
    // NOT match the canonical `k.key` (byte-exact tail match). pathMatches => true.
    // On a case-sensitive FS (Linux) the canonical name IS `k.key` and `*.KEY`
    // also fails the byte-exact match — so the result is true on BOTH platforms.
    // ASSERT: allow fires, deny does not (regardless of platform case sensitivity).
    // This is NOT a security escape (attacker cannot control pattern case).
    try std.testing.expect(pathMatches(io, tmp.dir, set, cand, bases));
}
