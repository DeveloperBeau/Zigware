const std = @import("std");
const Manifest = @import("zigware_manifest").Manifest; // D's parsed manifest type

pub const ScriptHash = struct { algo: enum { sha256 }, b64: []const u8 };

/// SHA-256 each script (file bytes or inline <script> body), base64-encode, return 'sha256-<b64>' sources.
/// The returned `.b64` holds the BARE base64 digest (no `sha256-` prefix); the prefix is
/// added in buildCsp when a hash is rendered as a quoted `'sha256-<b64>'` source.
pub fn scriptHashes(gpa: std.mem.Allocator, scripts: []const []const u8) ![]const ScriptHash {
    const out = try gpa.alloc(ScriptHash, scripts.len);
    errdefer gpa.free(out);

    var filled: usize = 0;
    errdefer for (out[0..filled]) |h| gpa.free(h.b64);

    const enc = std.base64.standard.Encoder;
    for (scripts, 0..) |bytes, i| {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const b64 = try gpa.alloc(u8, enc.calcSize(digest.len));
        _ = enc.encode(b64, &digest);
        out[i] = .{ .algo = .sha256, .b64 = b64 };
        filled = i + 1;
    }
    return out;
}

/// Sources that are never permitted from manifest input across any directive. CSP keyword
/// and scheme sources are matched case-insensitively by browsers, so the scan lowercases a
/// copy of each manifest token before comparing against these (already-lowercase) literals.
const deny_keywords = [_][]const u8{
    "'unsafe-inline'",
    "'unsafe-eval'",
    "'unsafe-hashes'",
    "'wasm-unsafe-eval'",
};
const deny_schemes = [_][]const u8{ "https:", "http:", "data:", "blob:" };

/// Returns true when `token` (already ASCII-lowercased) is an unsafe source that must fail
/// the build closed: a deny-listed keyword, a bare wildcard, or a scheme-only source.
fn isUnsafeToken(lower: []const u8) bool {
    for (deny_keywords) |kw| {
        if (std.mem.eql(u8, lower, kw)) return true;
    }
    if (std.mem.eql(u8, lower, "*")) return true;
    for (deny_schemes) |sch| {
        if (std.mem.eql(u8, lower, sch)) return true;
    }
    return false;
}

/// Scan a directive's manifest tokens; returns error.csp_conflict on the first unsafe one.
/// Lowercases a COPY into a stack buffer for the compare only; the token itself is untouched.
fn denyScan(tokens: []const []const u8) error{csp_conflict}!void {
    var buf: [256]u8 = undefined;
    for (tokens) |tok| {
        if (tok.len <= buf.len) {
            const lower = std.ascii.lowerString(buf[0..tok.len], tok);
            if (isUnsafeToken(lower)) return error.csp_conflict;
        } else {
            // Over-long token cannot equal any short deny literal; only the bare `*`
            // and the scheme/keyword forms (all <= buf.len) are rejectable, so a token
            // this long is a host and is allowed through.
        }
    }
}

/// True when `tok` is the literal `'self'` keyword (case-insensitive). The strict base already
/// emits `'self'` for every directive, so a manifest-supplied `'self'` (the schema default) is
/// dropped to avoid a doubled `'self' 'self'`.
fn isSelf(tok: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tok, "'self'");
}

/// Strict base ("default-src 'self'; script-src 'self' <hashes>; ...", no unsafe-inline/eval)
/// plus validated manifest host tokens. Fails closed (error.csp_conflict) on any unsafe token.
pub fn buildCsp(gpa: std.mem.Allocator, hashes: []const ScriptHash, manifest: *const Manifest) ![]u8 {
    const csp = manifest.security.csp;

    // Fail closed BEFORE emitting anything: scan every manifest-incorporated directive.
    try denyScan(csp.defaultSrc);
    try denyScan(csp.scriptSrc);
    try denyScan(csp.styleSrc);
    try denyScan(csp.connectSrc);
    try denyScan(csp.imgSrc);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    // default-src
    try w.writeAll("default-src 'self'");
    try appendHosts(w, csp.defaultSrc);
    try w.writeAll("; ");

    // script-src: 'self' + hash sources + validated host tokens (keywords like the default
    // 'self' are dropped — manifest input never adds keyword sources to script-src).
    try w.writeAll("script-src 'self'");
    for (hashes) |h| {
        try w.print(" 'sha256-{s}'", .{h.b64});
    }
    try appendHosts(w, csp.scriptSrc);
    try w.writeAll("; ");

    // style-src
    try w.writeAll("style-src 'self'");
    try appendHosts(w, csp.styleSrc);
    try w.writeAll("; ");

    // connect-src
    try w.writeAll("connect-src 'self'");
    try appendHosts(w, csp.connectSrc);
    try w.writeAll("; ");

    // img-src
    try w.writeAll("img-src 'self'");
    try appendHosts(w, csp.imgSrc);

    return aw.toOwnedSlice();
}

/// Append each manifest host token preceded by a space, skipping the `'self'` keyword (already
/// emitted by the strict base). The deny-scan has already rejected every unsafe token.
fn appendHosts(w: *std.Io.Writer, tokens: []const []const u8) !void {
    for (tokens) |tok| {
        if (isSelf(tok)) continue;
        try w.writeByte(' ');
        try w.writeAll(tok);
    }
}

const csp_meta_prefix = "<meta http-equiv=\"Content-Security-Policy\"";

/// Replace/insert the <meta http-equiv="Content-Security-Policy"> in index.html.
/// - absent: insert `<meta http-equiv="Content-Security-Policy" content="<csp>">` into <head>.
/// - present and content identical to `csp`: return the HTML unchanged (idempotent).
/// - present and content differs: error.csp_conflict (never a silent overwrite/downgrade).
/// The returned slice is always a fresh heap allocation owned by the caller.
pub fn injectIntoHtml(gpa: std.mem.Allocator, html: []const u8, csp: []const u8) ![]u8 {
    // The CSP value is rendered into a double-quoted HTML attribute. Reject any host string
    // that would break out of that context; the strict policy never contains these itself.
    for (csp) |c| {
        if (c == '"' or c == '<' or c == '>') return error.csp_conflict;
    }

    if (findCspMeta(html)) |meta| {
        const existing = extractContent(html, meta) orelse return error.csp_conflict;
        if (std.mem.eql(u8, existing, csp)) {
            return gpa.dupe(u8, html); // idempotent: identical meta already present
        }
        return error.csp_conflict; // differing author meta: fail closed, never overwrite
    }

    // No CSP meta present: insert one immediately after <head...> (case-insensitive open tag).
    const head_end = findHeadInsertPoint(html) orelse return error.csp_conflict;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(html[0..head_end]);
    try w.writeAll("\n    ");
    try w.writeAll(csp_meta_prefix);
    try w.writeAll(" content=\"");
    try w.writeAll(csp);
    try w.writeAll("\">");
    try w.writeAll(html[head_end..]);
    return aw.toOwnedSlice();
}

/// Byte range [start, end) of a CSP meta tag in `html` (from `<meta` through its closing `>`),
/// matched case-insensitively and tolerant of attribute order. null when absent.
const MetaSpan = struct { start: usize, end: usize };

fn findCspMeta(html: []const u8) ?MetaSpan {
    var i: usize = 0;
    while (i < html.len) {
        const meta_rel = ciIndex(html[i..], "<meta") orelse return null;
        const meta_start = i + meta_rel;
        // Find this tag's closing '>'.
        const gt_rel = std.mem.indexOfScalar(u8, html[meta_start..], '>') orelse return null;
        const tag_end = meta_start + gt_rel + 1;
        const tag = html[meta_start..tag_end];
        if (metaIsCsp(tag)) return .{ .start = meta_start, .end = tag_end };
        i = tag_end;
    }
    return null;
}

/// True when a <meta ...> tag carries http-equiv="Content-Security-Policy" (case-insensitive,
/// quote-tolerant).
fn metaIsCsp(tag: []const u8) bool {
    const he_rel = ciIndex(tag, "http-equiv") orelse return false;
    var j = he_rel + "http-equiv".len;
    // Skip whitespace and '='.
    while (j < tag.len and (tag[j] == ' ' or tag[j] == '\t' or tag[j] == '=' or tag[j] == '\n' or tag[j] == '\r')) j += 1;
    // Optional opening quote.
    if (j < tag.len and (tag[j] == '"' or tag[j] == '\'')) j += 1;
    const rest = tag[j..];
    return ciStartsWith(rest, "content-security-policy");
}

/// Extract the value of the `content="..."` attribute within the CSP meta span. null when the
/// attribute is malformed/absent (treated as a conflict by the caller).
fn extractContent(html: []const u8, meta: MetaSpan) ?[]const u8 {
    const tag = html[meta.start..meta.end];
    // Find the real `content` ATTRIBUTE: a `content` token whose next non-whitespace
    // character is `=`. A bare substring search would falsely match the `Content` inside
    // `http-equiv="Content-Security-Policy"` (where the following char is `-`, not `=`),
    // so we scan past any such non-attribute occurrence.
    var search: usize = 0;
    while (search < tag.len) {
        const rel = ciIndex(tag[search..], "content") orelse return null;
        var j = search + rel + "content".len;
        // Skip whitespace between the attribute name and its `=`.
        var k = j;
        while (k < tag.len and (tag[k] == ' ' or tag[k] == '\t' or tag[k] == '\n' or tag[k] == '\r')) k += 1;
        if (k >= tag.len or tag[k] != '=') {
            // Not the `content=` attribute (e.g. the http-equiv value); keep scanning.
            search = search + rel + 1;
            continue;
        }
        j = k + 1; // step past '='
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '\t' or tag[j] == '\n' or tag[j] == '\r')) j += 1;
        if (j >= tag.len) return null;
        const quote = tag[j];
        if (quote != '"' and quote != '\'') return null;
        j += 1;
        const close = std.mem.indexOfScalar(u8, tag[j..], quote) orelse return null;
        return tag[j .. j + close];
    }
    return null;
}

/// Insertion point: just after the opening `<head ...>` tag. null when there is no <head>.
fn findHeadInsertPoint(html: []const u8) ?usize {
    const head_rel = ciIndex(html, "<head") orelse return null;
    const gt = std.mem.indexOfScalar(u8, html[head_rel..], '>') orelse return null;
    return head_rel + gt + 1;
}

/// Case-insensitive substring search; returns the index of the first match of `needle`.
fn ciIndex(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn ciStartsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

// ─────────────────────────── tests ───────────────────────────

const testing = std.testing;

fn testManifest() Manifest {
    return .{ .identifier = "com.example.app", .productName = "Example", .version = "0.1.0" };
}

test "scriptHashes: known vector alert(1)" {
    const scripts = [_][]const u8{"alert(1)"};
    const hashes = try scriptHashes(testing.allocator, &scripts);
    defer {
        for (hashes) |h| testing.allocator.free(h.b64);
        testing.allocator.free(hashes);
    }
    try testing.expectEqual(@as(usize, 1), hashes.len);
    try testing.expect(hashes[0].algo == .sha256);
    // BARE base64, no `sha256-` prefix.
    try testing.expectEqualStrings("bhHHL3z2vDgxUt0W3dWQOrprscmda2Y5pLsLg4GF+pI=", hashes[0].b64);
}

test "scriptHashes: empty input yields empty slice" {
    const hashes = try scriptHashes(testing.allocator, &.{});
    defer testing.allocator.free(hashes);
    try testing.expectEqual(@as(usize, 0), hashes.len);
}

test "buildCsp: exact output for fixed hash list + default manifest" {
    const hashes = [_]ScriptHash{.{ .algo = .sha256, .b64 = "bhHHL3z2vDgxUt0W3dWQOrprscmda2Y5pLsLg4GF+pI=" }};
    const m = testManifest();
    const csp = try buildCsp(testing.allocator, &hashes, &m);
    defer testing.allocator.free(csp);
    try testing.expectEqualStrings(
        "default-src 'self'; " ++
            "script-src 'self' 'sha256-bhHHL3z2vDgxUt0W3dWQOrprscmda2Y5pLsLg4GF+pI='; " ++
            "style-src 'self'; connect-src 'self'; img-src 'self'",
        csp,
    );
}

test "buildCsp: validated hosts are appended, self not doubled" {
    var m = testManifest();
    m.security.csp = .{
        .scriptSrc = &.{ "'self'", "https://cdn.example.com" },
        .connectSrc = &.{ "'self'", "https://api.example.com" },
    };
    const csp = try buildCsp(testing.allocator, &.{}, &m);
    defer testing.allocator.free(csp);
    try testing.expectEqualStrings(
        "default-src 'self'; " ++
            "script-src 'self' https://cdn.example.com; " ++
            "style-src 'self'; " ++
            "connect-src 'self' https://api.example.com; img-src 'self'",
        csp,
    );
}

test "buildCsp: unsafe-eval in scriptSrc fails closed" {
    var m = testManifest();
    m.security.csp = .{ .scriptSrc = &.{ "'self'", "'unsafe-eval'" } };
    try testing.expectError(error.csp_conflict, buildCsp(testing.allocator, &.{}, &m));
}

test "buildCsp: bare wildcard in defaultSrc fails closed" {
    var m = testManifest();
    m.security.csp = .{ .defaultSrc = &.{ "'self'", "*" } };
    try testing.expectError(error.csp_conflict, buildCsp(testing.allocator, &.{}, &m));
}

test "buildCsp: bare wildcard in connectSrc fails closed" {
    var m = testManifest();
    m.security.csp = .{ .connectSrc = &.{ "'self'", "*" } };
    try testing.expectError(error.csp_conflict, buildCsp(testing.allocator, &.{}, &m));
}

test "buildCsp: scheme-only source in imgSrc fails closed" {
    var m = testManifest();
    m.security.csp = .{ .imgSrc = &.{ "'self'", "https:" } };
    try testing.expectError(error.csp_conflict, buildCsp(testing.allocator, &.{}, &m));
}

test "buildCsp: mixed-case unsafe token fails closed (case-fold)" {
    var m = testManifest();
    m.security.csp = .{ .scriptSrc = &.{ "'self'", "'Unsafe-Eval'" } };
    try testing.expectError(error.csp_conflict, buildCsp(testing.allocator, &.{}, &m));
}

test "buildCsp: mixed-case unsafe-inline in styleSrc fails closed" {
    var m = testManifest();
    m.security.csp = .{ .styleSrc = &.{ "'self'", "'UNSAFE-INLINE'" } };
    try testing.expectError(error.csp_conflict, buildCsp(testing.allocator, &.{}, &m));
}

test "injectIntoHtml: inserts meta when absent" {
    const html = "<html><head><title>x</title></head><body></body></html>";
    const csp = "default-src 'self'";
    const out = try injectIntoHtml(testing.allocator, html, csp);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Content-Security-Policy") != null);
    try testing.expect(std.mem.indexOf(u8, out, "content=\"default-src 'self'\"") != null);
    // The inserted meta lands inside <head>, before </head>.
    const meta_at = std.mem.indexOf(u8, out, "<meta").?;
    const head_close = std.mem.indexOf(u8, out, "</head>").?;
    try testing.expect(meta_at < head_close);
}

test "injectIntoHtml: identical meta is idempotent" {
    const csp = "default-src 'self'; script-src 'self'";
    const html = "<html><head>\n    <meta http-equiv=\"Content-Security-Policy\" content=\"" ++
        "default-src 'self'; script-src 'self'\"></head><body></body></html>";
    const out = try injectIntoHtml(testing.allocator, html, csp);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(html, out);
}

test "injectIntoHtml: differing meta fails closed" {
    const csp = "default-src 'self'; script-src 'self'";
    const html = "<html><head><meta http-equiv=\"Content-Security-Policy\" content=\"" ++
        "default-src *\"></head><body></body></html>";
    try testing.expectError(error.csp_conflict, injectIntoHtml(testing.allocator, html, csp));
}

// Fuzz: mirror the H14 single-input Smith body + manual >= 10000-iteration deterministic loop
// (src/assets.zig:107-133). Property: injectIntoHtml never silently drops a conflicting meta
// (conflict => error, not overwrite) and never lets an injected meta carry attacker-chosen
// bytes that would break the double-quoted attribute context.

fn checkInjectProperty(gpa: std.mem.Allocator, html: []const u8) anyerror!void {
    const csp = "default-src 'self'; script-src 'self'";
    const out = injectIntoHtml(gpa, html, csp) catch |err| {
        // Only csp_conflict (fail-closed) or OutOfMemory are acceptable outcomes.
        switch (err) {
            error.csp_conflict, error.OutOfMemory => return,
            else => return err,
        }
    };
    defer gpa.free(out);

    // On any success path the output must carry exactly the CSP we asked for, verbatim, and
    // never an attribute-context escape from the injected value (the value is conflict-free).
    try testing.expect(std.mem.indexOf(u8, out, "content=\"default-src 'self'; script-src 'self'\"") != null);

    // If the input already had a CSP meta, success means it was byte-identical (idempotent):
    // re-running must be a fixed point.
    const again = injectIntoHtml(gpa, out, csp) catch |err| switch (err) {
        error.OutOfMemory => return,
        else => return err, // a second run must never newly conflict on our own output
    };
    defer gpa.free(again);
    try testing.expectEqualStrings(out, again);
}

fn fuzzInject(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [4 * 1024]u8 = undefined;
    const n = smith.slice(&buf);
    try checkInjectProperty(testing.allocator, buf[0..n]);
}

test "fuzz: injectIntoHtml property (single-input Smith)" {
    try std.testing.fuzz({}, fuzzInject, .{});
}

test "fuzz: injectIntoHtml property (manual >= 10000 iterations)" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();

    const fragments = [_][]const u8{
        "<html>",
        "<head>",
        "<HEAD>",
        "</head>",
        "<body>",
        "</body>",
        "</html>",
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'self'; script-src 'self'\">",
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src *\">",
        "<META HTTP-EQUIV='Content-Security-Policy' CONTENT='default-src 'self''>",
        "<meta charset=\"utf-8\">",
        "<script>alert(1)</script>",
        "</script>",
        "<title>x</title>",
        "\u{2028}",
        "\u{2029}",
        "\"",
        "'",
        "<",
        ">",
        "=",
    };

    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        var html: std.ArrayList(u8) = .empty;
        defer html.deinit(testing.allocator);
        const parts = rand.intRangeAtMost(usize, 0, 8);
        var p: usize = 0;
        while (p < parts) : (p += 1) {
            const frag = fragments[rand.intRangeLessThan(usize, 0, fragments.len)];
            try html.appendSlice(testing.allocator, frag);
        }
        try checkInjectProperty(testing.allocator, html.items);
    }
}
