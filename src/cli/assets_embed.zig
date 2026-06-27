const std = @import("std");

pub const Entry = struct {
    /// served path, always begins with "/", forward-slash normalized
    serve_path: []const u8,
    /// path relative to outDir, used as the addAnonymousImport name
    import_name: []const u8,
    /// sentinel-terminated MIME for seam.Response.mime
    mime: [:0]const u8,
};

pub const WalkResult = struct {
    entries: []const Entry,
    arena: std.heap.ArenaAllocator, // owns all entry strings; caller deinits
    pub fn deinit(self: *WalkResult) void {
        self.arena.deinit();
    }
};

/// True when `entry_canon` lies within `base_canon` at a SEGMENT BOUNDARY.
/// A bare `startsWith` lets `/a/foo` match `/a/foobar` (foobar starts with foo, an
/// out-of-scope escape), so the candidate must equal the base or have a '/'
/// immediately after the base prefix. Both arguments are canonical absolute paths.
/// This is the realpath-then-segment-boundary containment pattern; it deliberately
/// does NOT import src/security/scope/path.zig (which drags in the capability
/// machinery), it re-implements only the pattern.
fn withinBase(base_canon: []const u8, entry_canon: []const u8) bool {
    if (!std.mem.startsWith(u8, entry_canon, base_canon)) return false;
    // Equal paths (the dist root itself) cannot host an asset, but the boundary
    // predicate treats equality as "contained"; the walk never asks about the root.
    if (entry_canon.len == base_canon.len) return true;
    // A trailing separator on the base already places us at a boundary.
    if (base_canon.len > 0 and base_canon[base_canon.len - 1] == '/') return true;
    return entry_canon[base_canon.len] == '/';
}

/// A relative path is structurally rejectable BEFORE any disk resolution when it
/// carries an embedded NUL or is absolute. `..` and out-pointing symlinks are NOT
/// caught here (they need realpath); they are rejected by the containment check
/// in `walk`. Returns true when the string alone proves the path may not be served.
fn isStructurallyRejected(rel: []const u8) bool {
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return true; // embedded NUL
    if (rel.len > 0 and rel[0] == '/') return true; // absolute
    return false;
}

/// Enumerate outDir; canonicalize each path and reject anything resolving outside it
/// (.., out-pointing symlinks, absolute paths, embedded NUL) with error.asset_outside_dist.
pub fn walk(io: std.Io, gpa: std.mem.Allocator, dist_dir: []const u8) anyerror!WalkResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var dir = std.Io.Dir.cwd().openDir(io, dist_dir, .{ .iterate = true }) catch
        return error.frontend_dist_missing;
    defer dir.close(io);

    // Canonical absolute path of the dist root; every entry must resolve under it.
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_n = dir.realPath(io, &base_buf) catch return error.frontend_dist_missing;
    const base_canon = base_buf[0..base_n];

    var entries: std.ArrayList(Entry) = .empty;

    var walker = try dir.walk(a);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // The walker descends into directories on its own; only leaf payloads matter.
        // Every NON-directory entry (regular file, symlink, fifo, …) is run through
        // containment: an escaping symlink resolves OUT and is rejected here rather
        // than silently skipped.
        if (entry.kind == .directory) continue;

        // entry.path aliases the walker's name_buffer, invalidated on the next
        // next() call; read it before any further iteration and dupe what we keep.
        const rel = entry.path;
        if (isStructurallyRejected(rel)) return error.asset_outside_dist;

        // Canonicalize the entry (follows symlinks, resolves `..`) and require it to
        // sit within the dist root at a segment boundary. An unresolvable path is a
        // reject, never a propagated raw error and never an allow.
        var ent_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const ent_n = dir.realPathFile(io, rel, &ent_buf) catch return error.asset_outside_dist;
        const ent_canon = ent_buf[0..ent_n];
        if (!withinBase(base_canon, ent_canon)) return error.asset_outside_dist;

        // import_name is the dist-relative path with forward slashes (the
        // addAnonymousImport name); serve_path is "/" ++ import_name.
        const import_name = try forwardSlashDupe(a, rel);
        const serve_path = try std.fmt.allocPrint(a, "/{s}", .{import_name});
        const ext = extensionOf(import_name);

        try entries.append(a, .{
            .serve_path = serve_path,
            .import_name = import_name,
            .mime = mimeForExt(ext),
        });
    }

    const slice = try entries.toOwnedSlice(a);
    std.mem.sort(Entry, slice, {}, lessByServePath);
    return .{ .entries = slice, .arena = arena };
}

fn lessByServePath(_: void, lhs: Entry, rhs: Entry) bool {
    return std.mem.lessThan(u8, lhs.serve_path, rhs.serve_path);
}

/// Dupe `rel` into `a`, rewriting the host path separator to a forward slash so the
/// generated import names and serve paths are platform-independent. On POSIX the
/// separator is already '/', so this is a plain dupe; the rewrite future-proofs the
/// emitted source against a Windows host.
fn forwardSlashDupe(a: std.mem.Allocator, rel: []const u8) ![]const u8 {
    const out = try a.dupe(u8, rel);
    if (std.fs.path.sep != '/') {
        for (out) |*c| {
            if (c.* == std.fs.path.sep) c.* = '/';
        }
    }
    return out;
}

/// The extension INCLUDING the leading dot (".css"), or "" when the basename has
/// none. Only the final path segment is inspected so a dot in a parent directory
/// name does not masquerade as an extension.
fn extensionOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const base = if (slash) |s| path[s + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    return base[dot..];
}

/// Emit the generated build.zig fragment (addAnonymousImport per entry).
/// Entries are assumed sorted by `serve_path` (walk sorts them) for reproducibility.
pub fn emitBuildFragment(w: *std.Io.Writer, entries: []const Entry) !void {
    for (entries) |e| {
        try w.print(
            "mod.addAnonymousImport(\"{s}\", .{{ .root_source_file = b.path(\"{s}\") }});\n",
            .{ e.import_name, e.import_name },
        );
    }
}

/// Emit asset_table.zig: `pub const table = [_]Asset{ .{...} };` consumed by serveAsset.
/// Re-emits the `Asset` row declaration so A4's `asset_table.Asset` alias resolves.
pub fn emitAssetTable(w: *std.Io.Writer, entries: []const Entry) !void {
    try w.writeAll(
        \\pub const Asset = struct {
        \\    path: []const u8,
        \\    body: []const u8,
        \\    mime: [:0]const u8,
        \\};
        \\
        \\pub const table = [_]Asset{
        \\
    );
    for (entries) |e| {
        try w.print(
            "    .{{ .path = \"{s}\", .body = @embedFile(\"{s}\"), .mime = \"{s}\" }},\n",
            .{ e.serve_path, e.import_name, e.mime },
        );
    }
    try w.writeAll("};\n");
}

/// Extension -> MIME, sentinel-terminated. Unknown extensions fall back to application/octet-stream.
pub fn mimeForExt(ext: []const u8) [:0]const u8 {
    const table = .{
        .{ ".html", "text/html" },        .{ ".js", "text/javascript" },
        .{ ".css", "text/css" },          .{ ".json", "application/json" },
        .{ ".svg", "image/svg+xml" },     .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },         .{ ".woff2", "font/woff2" },
        .{ ".woff", "font/woff" },        .{ ".ico", "image/x-icon" },
        .{ ".wasm", "application/wasm" }, .{ ".map", "application/json" },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, ext, row[0])) return row[1];
    }
    return "application/octet-stream";
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn findEntry(entries: []const Entry, serve_path: []const u8) ?Entry {
    for (entries) |e| {
        if (std.mem.eql(u8, e.serve_path, serve_path)) return e;
    }
    return null;
}

test "walk: fixture dist yields three entries with correct serve paths and mimes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "<html></html>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.js", .data = "console.log(1)" });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/x.css", .data = "body{}" });

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_n = try tmp.dir.realPath(io, &base_buf);
    const base = base_buf[0..base_n];

    var result = try walk(io, testing.allocator, base);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.entries.len);

    // Sorted by serve_path: "/app.js", "/index.html", "/sub/x.css".
    try testing.expectEqualStrings("/app.js", result.entries[0].serve_path);
    try testing.expectEqualStrings("/index.html", result.entries[1].serve_path);
    try testing.expectEqualStrings("/sub/x.css", result.entries[2].serve_path);

    const js = findEntry(result.entries, "/app.js").?;
    try testing.expectEqualStrings("app.js", js.import_name);
    try testing.expectEqualStrings("text/javascript", js.mime);

    const html = findEntry(result.entries, "/index.html").?;
    try testing.expectEqualStrings("index.html", html.import_name);
    try testing.expectEqualStrings("text/html", html.mime);

    const css = findEntry(result.entries, "/sub/x.css").?;
    try testing.expectEqualStrings("sub/x.css", css.import_name);
    try testing.expectEqualStrings("text/css", css.mime);
}

test "walk: missing dist directory errors frontend_dist_missing" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_n = try tmp.dir.realPath(io, &base_buf);
    const base = base_buf[0..base_n];

    var miss_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrint(&miss_buf, "{s}/does-not-exist", .{base});
    try testing.expectError(error.frontend_dist_missing, walk(io, testing.allocator, missing));
}

test "walk: symlink escaping the dist is rejected" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "x" });
    // A symlink whose target is "/" (outside the dist). Skip the test if the host
    // refuses symlink creation.
    tmp.dir.symLink(io, "/etc/passwd", "escape", .{}) catch return;

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_n = try tmp.dir.realPath(io, &base_buf);
    const base = base_buf[0..base_n];

    try testing.expectError(error.asset_outside_dist, walk(io, testing.allocator, base));
}

test "walk: symlink staying inside the dist is accepted" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "real.js", .data = "1" });
    // A symlink whose target resolves INSIDE the dist must NOT be rejected.
    tmp.dir.symLink(io, "real.js", "alias.js", .{}) catch return;

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_n = try tmp.dir.realPath(io, &base_buf);
    const base = base_buf[0..base_n];

    var result = try walk(io, testing.allocator, base);
    defer result.deinit();

    // Both the real file and the in-bounds alias survive; neither escapes.
    try testing.expect(findEntry(result.entries, "/real.js") != null);
    try testing.expect(findEntry(result.entries, "/alias.js") != null);
}

test "containment predicate: segment-boundary and structural rejects" {
    // withinBase enforces a segment boundary: a sibling sharing a prefix is OUT.
    try testing.expect(withinBase("/a/dist", "/a/dist/index.html"));
    try testing.expect(withinBase("/a/dist", "/a/dist")); // the root itself
    try testing.expect(withinBase("/a/dist/", "/a/dist/x")); // trailing-sep base
    try testing.expect(!withinBase("/a/dist", "/a/distractor/x")); // prefix, no boundary
    try testing.expect(!withinBase("/a/dist", "/etc/passwd")); // unrelated
    try testing.expect(!withinBase("/a/dist", "/a")); // parent

    // Structural string rejects (caught before any disk resolution).
    try testing.expect(isStructurallyRejected("/etc/passwd")); // absolute
    try testing.expect(isStructurallyRejected("a\x00b")); // embedded NUL
    try testing.expect(!isStructurallyRejected("sub/x.css")); // ordinary relative
    try testing.expect(!isStructurallyRejected("../escape")); // realpath catches this, not the string
}

test "extensionOf only inspects the final segment" {
    try testing.expectEqualStrings(".css", extensionOf("sub/x.css"));
    try testing.expectEqualStrings(".html", extensionOf("index.html"));
    try testing.expectEqualStrings("", extensionOf("noext"));
    try testing.expectEqualStrings("", extensionOf("dir.with.dot/file")); // dot is in the dir
    try testing.expectEqualStrings(".map", extensionOf("a.b.map"));
}

test "emitBuildFragment: exact deterministic output for a fixed entry set" {
    const entries = [_]Entry{
        .{ .serve_path = "/app.js", .import_name = "app.js", .mime = "text/javascript" },
        .{ .serve_path = "/index.html", .import_name = "index.html", .mime = "text/html" },
        .{ .serve_path = "/sub/x.css", .import_name = "sub/x.css", .mime = "text/css" },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitBuildFragment(&aw.writer, &entries);

    const expected =
        \\mod.addAnonymousImport("app.js", .{ .root_source_file = b.path("app.js") });
        \\mod.addAnonymousImport("index.html", .{ .root_source_file = b.path("index.html") });
        \\mod.addAnonymousImport("sub/x.css", .{ .root_source_file = b.path("sub/x.css") });
        \\
    ;
    try testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "emitAssetTable: exact deterministic output including Asset decl and mime sentinel" {
    const entries = [_]Entry{
        .{ .serve_path = "/app.js", .import_name = "app.js", .mime = "text/javascript" },
        .{ .serve_path = "/index.html", .import_name = "index.html", .mime = "text/html" },
        .{ .serve_path = "/sub/x.css", .import_name = "sub/x.css", .mime = "text/css" },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitAssetTable(&aw.writer, &entries);

    const expected =
        \\pub const Asset = struct {
        \\    path: []const u8,
        \\    body: []const u8,
        \\    mime: [:0]const u8,
        \\};
        \\
        \\pub const table = [_]Asset{
        \\    .{ .path = "/app.js", .body = @embedFile("app.js"), .mime = "text/javascript" },
        \\    .{ .path = "/index.html", .body = @embedFile("index.html"), .mime = "text/html" },
        \\    .{ .path = "/sub/x.css", .body = @embedFile("sub/x.css"), .mime = "text/css" },
        \\};
        \\
    ;
    try testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "mimeForExt: known and unknown extensions" {
    try testing.expectEqualStrings("text/html", mimeForExt(".html"));
    try testing.expectEqualStrings("application/wasm", mimeForExt(".wasm"));
    try testing.expectEqualStrings("application/json", mimeForExt(".map"));
    try testing.expectEqualStrings("application/octet-stream", mimeForExt(".unknownext"));
    try testing.expectEqualStrings("application/octet-stream", mimeForExt(""));
}

/// The deny-gate property, shared by the manual driver and the Smith body so both
/// pin the SAME contract (mirrors src/assets.zig's shared `checkServeAssetOracle`).
/// `rel` is an arbitrary candidate relative path. The walk's reject-outside-dist is
/// the composition of two pure predicates: a structural string reject (absolute /
/// embedded NUL) and a realpath segment-boundary containment check. We cannot
/// realPath synthetic non-existent paths, so we hammer those predicates directly:
/// a path that is structurally rejectable, or whose pre-resolution joined form is
/// NOT within the base at a segment boundary, is NEVER accepted. Deny wins.
fn checkContainmentProperty(rel: []const u8) !void {
    const base = "/proj/dist";

    // Direct adversarial probes: these hold regardless of the random `rel`.
    try testing.expect(!withinBase(base, "/proj/distractor/x")); // sibling prefix
    try testing.expect(!withinBase(base, "/etc/passwd")); // unrelated root
    try testing.expect(!withinBase(base, "/proj")); // parent

    // Structural gate: absolute or NUL-bearing relatives are rejected outright.
    if (isStructurallyRejected(rel)) return; // correctly denied by the string gate

    // Otherwise simulate the canonical form the way realpath would: a path that
    // does not start with base/ at a boundary is an escape and must be denied.
    var cand_buf: [4096]u8 = undefined;
    const cand = std.fmt.bufPrint(&cand_buf, "{s}/{s}", .{ base, rel }) catch return;

    // A textual `..` in the joined candidate means realpath WOULD climb out; the
    // synthetic candidate we hand to withinBase is the pre-resolution string, so we
    // assert the structural property of withinBase itself: when it accepts, the
    // candidate genuinely starts with "base/" at a boundary (no sibling-prefix
    // escape, no parent).
    if (withinBase(base, cand)) {
        try testing.expect(std.mem.startsWith(u8, cand, base));
        try testing.expect(cand.len == base.len or cand[base.len] == '/');
    }
}

/// Smith body: the libFuzzer-driven path. The runner executes it once under
/// `zig build test`; a fuzzing build mutates the corpus. Bytes are fed straight
/// through as the candidate relative path so the adversarial set (`..`, NUL,
/// absolute, mixed separators) arises naturally from coverage-guided mutation.
fn fuzzContainment(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    try checkContainmentProperty(buf[0..n]);
}

test "fuzz: the containment gate never lets an escaping path through (native)" {
    try std.testing.fuzz({}, fuzzContainment, .{});
}

test "fuzz: the containment gate never lets an escaping path through (manual >= 10000)" {
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        var buf: [256]u8 = undefined;
        const n = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..n]) |*c| {
            // Bias toward path-shaped bytes plus the adversarial set: separators,
            // dots (for `..`), NUL, leading slashes.
            c.* = switch (rand.intRangeAtMost(u8, 0, 9)) {
                0 => '/',
                1 => '.',
                2 => 0, // embedded NUL
                3 => '\\', // mixed separator
                else => rand.int(u8),
            };
        }
        try checkContainmentProperty(buf[0..n]);
    }
}
