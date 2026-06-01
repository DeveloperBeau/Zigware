const std = @import("std");

// ─── Limits and reserved routes ──────────────────────────────────────────────

/// Hard cap on an inbound bridge message (finding H1). Enforced at three layers:
/// the macOS onMessage IMP rejects an NSString longer than this before spanning
/// it, Bridge.handleMessage rejects text.len > MAX with one reject, and decode
/// takes max_len explicitly. 64 KiB is generous for a JSON command envelope.
pub const MAX_MESSAGE_LEN: usize = 64 * 1024;

/// Maximum JSON nesting depth before decode rejects (finding H2). Closes the
/// deeply-nested-object/array bomb that fits inside MAX_MESSAGE_LEN.
pub const MAX_JSON_DEPTH: usize = 32;

/// Per-value length cap and duplicate-field policy passed to std.json on every
/// parse in the codebase (finding H2). Bounds a single giant string field and
/// makes duplicate-key handling deterministic (first wins).
pub const JSON_PARSE_OPTIONS: std.json.ParseOptions = .{
    .max_value_len = 4096,
    .duplicate_field_behavior = .use_first,
};

/// Reserved internal route prefixes that must never be served as static assets
/// and never reach the command gate. Owned here in protocol.zig; sub-project B
/// extends this list (for example the binary streaming scheme) and B's command
/// gate consults the same list. A's serveAsset consults it to exclude reserved
/// routes from the asset allowlist.
pub const reserved_route_prefixes = [_][]const u8{
    "/__zigware_stream",
};

/// True when `path` exactly equals a reserved route prefix OR begins with a
/// reserved prefix followed by `/`. Bare `startsWith` is insufficient: an
/// attacker can request `/__zigware_streamattack` and bypass the reserved-route
/// check, then potentially reach a sibling handler that uses the same loose
/// prefix. Boundary matching closes that hole.
pub fn isReservedRoute(path: []const u8) bool {
    for (reserved_route_prefixes) |prefix| {
        if (!std.mem.startsWith(u8, path, prefix)) continue;
        if (path.len == prefix.len) return true;
        if (path[prefix.len] == '/') return true;
    }
    return false;
}

/// Reject text whose `{`/`[` nesting exceeds MAX_JSON_DEPTH. A cheap pre-scan
/// run before std.json so a depth bomb is refused without recursing the parser.
fn exceedsJsonDepth(text: []const u8) bool {
    var depth: usize = 0;
    var max: usize = 0;
    var in_string = false;
    var escaped = false;
    for (text) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > max) max = depth;
            },
            '}', ']' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    return max > MAX_JSON_DEPTH;
}

// ─── Public types ────────────────────────────────────────────────────────────

pub const Message = struct {
    id: u64,
    cmd: []const u8,
    args_json: []const u8,

    pub fn deinit(self: Message, alloc: std.mem.Allocator) void {
        alloc.free(self.cmd);
        alloc.free(self.args_json);
    }
};

pub const DecodeError = error{BadMessage} || std.mem.Allocator.Error;

// ─── decode ──────────────────────────────────────────────────────────────────

pub fn decode(alloc: std.mem.Allocator, text: []const u8, max_len: usize) DecodeError!Message {
    if (text.len > max_len) return error.BadMessage;
    if (exceedsJsonDepth(text)) return error.BadMessage;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, JSON_PARSE_OPTIONS) catch return error.BadMessage;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.BadMessage;
    const obj = root.object;

    const id_v = obj.get("id") orelse return error.BadMessage;
    if (id_v != .integer or id_v.integer < 0) return error.BadMessage;
    const cmd_v = obj.get("cmd") orelse return error.BadMessage;
    if (cmd_v != .string) return error.BadMessage;

    // Serialize the "args" field (or default to "{}") using Allocating writer.
    var args_aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer args_aw.deinit();
    if (obj.get("args")) |a| {
        std.json.Stringify.value(a, .{}, &args_aw.writer) catch return error.BadMessage;
    } else {
        args_aw.writer.writeAll("{}") catch return error.BadMessage;
    }
    const args_json = args_aw.toOwnedSlice() catch return error.OutOfMemory;
    errdefer alloc.free(args_json);

    const cmd_copy = try alloc.dupe(u8, cmd_v.string);
    errdefer alloc.free(cmd_copy);

    return .{
        .id = @intCast(id_v.integer),
        .cmd = cmd_copy,
        .args_json = args_json,
    };
}

// ─── jsString ────────────────────────────────────────────────────────────────

/// Write a JSON string literal that is ALSO safe inside a <script> context and
/// inside JS source. This is THE injection boundary; it must be the only path
/// from arbitrary bytes into a JS string position.
pub fn jsString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const b = s[i];
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '/' => try w.writeAll("\\/"), // neutralises </script>
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => {
                if (b < 0x20) {
                    try w.print("\\u{x:0>4}", .{b});
                } else if (b == 0xE2 and i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0xA8 or s[i + 2] == 0xA9)) {
                    // U+2028 LINE SEPARATOR or U+2029 PARAGRAPH SEPARATOR
                    // These are valid JSON but terminate a JS string literal.
                    try w.writeAll(if (s[i + 2] == 0xA8) "\\u2028" else "\\u2029");
                    i += 2; // loop bump will consume the third byte
                } else {
                    try w.writeByte(b);
                }
            },
        }
    }
    try w.writeByte('"');
}

// ─── writeJsonAsJsLiteral ────────────────────────────────────────────────────

/// Pass pre-validated JSON through, escaping only LS/PS characters
/// which are valid JSON but terminate a JS string literal.
///
/// CONTRACT: `text` MUST be already-`std.json`-serialized output (no raw user
/// bytes in string positions). Callers passing raw user data here bypass the
/// `jsString` escape and break the injection boundary — raw user strings must
/// go through `jsString`, never here.
pub fn writeJsonAsJsLiteral(w: *std.Io.Writer, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (i + 3 <= text.len and text[i] == 0xE2 and text[i + 1] == 0x80 and (text[i + 2] == 0xA8 or text[i + 2] == 0xA9)) {
            try w.writeAll(if (text[i + 2] == 0xA8) "\\u2028" else "\\u2029");
            i += 3;
        } else {
            try w.writeByte(text[i]);
            i += 1;
        }
    }
}

// ─── encode helpers ──────────────────────────────────────────────────────────

pub fn encodeResolve(w: *std.Io.Writer, id: u64, json: []const u8) !void {
    try w.print("window.zig._resolve({d}, ", .{id});
    try writeJsonAsJsLiteral(w, json);
    try w.writeAll(");");
}

pub fn encodeReject(w: *std.Io.Writer, id: u64, message: []const u8) !void {
    try w.print("window.zig._reject({d}, ", .{id});
    try jsString(w, message);
    try w.writeAll(");");
}

pub fn encodeEmit(w: *std.Io.Writer, channel: []const u8, json: []const u8) !void {
    try w.writeAll("window.zig._emit(");
    try jsString(w, channel);
    try w.writeAll(", ");
    try writeJsonAsJsLiteral(w, json);
    try w.writeAll(");");
}

// ─── Fixture generator (used by Task 10/11) ──────────────────────────────────

/// Emit a JSON-Lines fixture of (input, escaped_output) pairs the Bun suite
/// uses for the JS-eval round-trip fuzz (Task 10). Wired into a build step
/// in Task 11.
pub fn emitEscapeFixtures(w: *std.Io.Writer) !void {
    const cases = [_][]const u8{
        "",
        "hello",
        "\"quoted\"",
        "</script><script>alert(1)</script>",
        "\u{2028}\u{2029}",
        "a\\b\nc\td",
        "ßünîçødé",
    };
    for (cases) |cs| {
        var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer aw.deinit();
        try jsString(&aw.writer, cs);
        try w.writeAll("{\"in\":");
        try jsString(w, cs);
        try w.writeAll(",\"out\":");
        try jsString(w, aw.writer.buffered());
        try w.writeAll("}\n");
    }
}

// ─── Test helpers ────────────────────────────────────────────────────────────

/// Assert that `out` is a structurally safe JS string literal that cannot
/// break out of the string position.  This is the canonical oracle used by
/// both the fuzz target and the adversarial unit-test table.
///
/// Invariants checked:
///   • out is wrapped in ASCII double-quotes.
///   • No raw control byte < 0x20 in the interior.
///   • No raw 3-byte U+2028 / U+2029 sequence in the interior.
///   • No unescaped double-quote in the interior.
///   • Every backslash begins a recognised escape sequence
///     (\", \\, \/, \n, \r, \t, \b, \f, \uXXXX).
fn assertSafeJsLiteral(out: []const u8) !void {
    if (out.len < 2) return error.TooShort;
    if (out[0] != '"') return error.MissingOpenQuote;
    if (out[out.len - 1] != '"') return error.MissingCloseQuote;

    const interior = out[1 .. out.len - 1];
    var i: usize = 0;
    while (i < interior.len) {
        const b = interior[i];
        // No raw control characters.
        if (b < 0x20) return error.RawControlChar;
        // No raw U+2028 LINE SEPARATOR or U+2029 PARAGRAPH SEPARATOR.
        if (b == 0xE2 and i + 2 < interior.len and interior[i + 1] == 0x80 and
            (interior[i + 2] == 0xA8 or interior[i + 2] == 0xA9))
        {
            return error.RawLineSeparator;
        }
        if (b == '\\') {
            if (i + 1 >= interior.len) return error.TrailingBackslash;
            const esc = interior[i + 1];
            switch (esc) {
                '"', '\\', '/', 'n', 'r', 't', 'b', 'f' => {
                    i += 2;
                },
                'u' => {
                    // \uXXXX — need exactly 4 hex digits after \u.
                    if (i + 6 > interior.len) return error.ShortUnicodeEscape;
                    for (interior[i + 2 .. i + 6]) |hc| {
                        if (!std.ascii.isHex(hc)) return error.InvalidHexInUnicodeEscape;
                    }
                    i += 6;
                },
                else => return error.InvalidEscapeChar,
            }
        } else if (b == '"') {
            return error.UnescapedQuote;
        } else {
            i += 1;
        }
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "isReservedRoute matches reserved prefixes at a boundary and nothing else" {
    try std.testing.expect(isReservedRoute("/__zigware_stream/1/0"));
    try std.testing.expect(isReservedRoute("/__zigware_stream"));
    try std.testing.expect(!isReservedRoute("/index.html"));
    try std.testing.expect(!isReservedRoute("/"));
    try std.testing.expect(!isReservedRoute("/app.js"));
    // Adversarial: a prefix that a bare startsWith would accept must NOT match.
    try std.testing.expect(!isReservedRoute("/__zigware_streamattack"));
    try std.testing.expect(!isReservedRoute("/__zigware_stream_x"));
    try std.testing.expect(!isReservedRoute("/__zigware_streamabc/foo"));
}

test "decode rejects text larger than max_len before parsing" {
    var buf: [MAX_MESSAGE_LEN + 16]u8 = undefined;
    @memset(buf[0..], 'a');
    try std.testing.expectError(error.BadMessage, decode(std.testing.allocator, buf[0 .. MAX_MESSAGE_LEN + 1], MAX_MESSAGE_LEN));
}

test "decode rejects deeply nested JSON (depth bomb)" {
    // 64 nested arrays exceeds MAX_JSON_DEPTH = 32.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var d: usize = 0;
    while (d < 64) : (d += 1) try aw.writer.writeByte('[');
    try aw.writer.writeAll("\"id\"");
    d = 0;
    while (d < 64) : (d += 1) try aw.writer.writeByte(']');
    try std.testing.expectError(error.BadMessage, decode(std.testing.allocator, aw.writer.buffered(), MAX_MESSAGE_LEN));
}

test "decode parses a well-formed message within limits" {
    const msg = try decode(std.testing.allocator, "{\"id\":7,\"cmd\":\"sha256\",\"args\":{\"megabytes\":4}}", MAX_MESSAGE_LEN);
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 7), msg.id);
    try std.testing.expectEqualStrings("sha256", msg.cmd);
}

test "decode rejects malformed input with error, no panic" {
    try std.testing.expectError(error.BadMessage, decode(std.testing.allocator, "not json", MAX_MESSAGE_LEN));
    try std.testing.expectError(error.BadMessage, decode(std.testing.allocator, "{\"id\":\"x\"}", MAX_MESSAGE_LEN));
}

test "encodeResolve produces a valid JS call with JSON arg" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try encodeResolve(&aw.writer, 3, "{\"hash\":\"ab\"}");
    try std.testing.expectEqualStrings("window.zig._resolve(3, {\"hash\":\"ab\"});", aw.writer.buffered());
}

test "jsString escapes injection vectors including LS/PS" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try jsString(&aw.writer, "\"</script>\\\n\u{2028}");
    try std.testing.expectEqualStrings("\"\\\"<\\/script>\\\\\\n\\u2028\"", aw.writer.buffered());
}

test "jsString is breakout-safe across adversarial inputs" {
    // Each entry: { input, ?expected_output }.
    // expected_output is non-null for ASCII-clean cases where the exact
    // output string is stable; null means "any output passing the structural
    // oracle is acceptable" (used for raw high-byte pass-throughs).
    const Case = struct { input: []const u8, expected: ?[]const u8 };
    const cases = [_]Case{
        // ── invalid UTF-8 — jsString passes bytes raw; still safe ─────────
        .{ .input = &.{0xE2}, .expected = null },
        .{ .input = &.{ 0xE2, 0x80 }, .expected = null },
        .{ .input = &.{ 0xFF, 0xFE }, .expected = null },
        .{ .input = &.{0x80}, .expected = null },
        // ── DEL 0x7F — raw passthrough (≥ 0x20, no special handling) ──────
        .{ .input = &.{0x7F}, .expected = null },
        // ── U+2029 must be escaped to   ──────────────────────────────
        .{ .input = "\u{2029}", .expected = "\"\\u2029\"" },
        // ── </SCRIPT>: slash must be escaped to \/ ─────────────────────────
        .{ .input = "</SCRIPT>", .expected = "\"<\\/SCRIPT>\"" },
        // ── NEL U+0085 (C2 85) — valid UTF-8, raw passthrough ─────────────
        .{ .input = "\u{0085}", .expected = null },
        // ── BOM U+FEFF (EF BB BF) — valid UTF-8, raw passthrough ──────────
        .{ .input = "\u{FEFF}", .expected = null },
        // ── backtick template safe in double-quoted JS literal ────────────
        .{ .input = "`${x}`", .expected = null },
        // ── known exact case ──────────────────────────────────────────────
        .{ .input = "a\"b", .expected = "\"a\\\"b\"" },
    };

    for (cases) |c| {
        var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        try jsString(&aw.writer, c.input);
        const out = aw.writer.buffered();

        // Structural safety oracle — must pass for ALL inputs.
        try assertSafeJsLiteral(out);

        // Exact output check for deterministic ASCII-clean cases.
        if (c.expected) |expected| {
            try std.testing.expectEqualStrings(expected, out);
        }

        // Round-trip check for all valid UTF-8 inputs (proves no data loss).
        if (std.unicode.utf8ValidateSlice(c.input)) {
            var parsed = try std.json.parseFromSlice([]const u8, std.testing.allocator, out, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings(c.input, parsed.value);
        }

        // For the invalid-UTF-8 cases, verify the raw byte is present (safe
        // passthrough rather than silent drop or corruption).
        if (!std.unicode.utf8ValidateSlice(c.input)) {
            try std.testing.expect(out.len >= 3); // at minimum: " + byte + "
        }

        // DEL 0x7F: explicitly confirm the raw byte survives intact.
        if (c.input.len == 1 and c.input[0] == 0x7F) {
            try std.testing.expectEqual(@as(u8, 0x7F), out[1]);
        }
    }
}

// ─── Fuzz targets ────────────────────────────────────────────────────────────

test "fuzz: decode never panics on arbitrary bytes" {
    try std.testing.fuzz({}, fuzzDecode, .{});
}

fn fuzzDecode(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    const input = buf[0..n];
    const r = decode(std.testing.allocator, input, MAX_MESSAGE_LEN) catch return;
    r.deinit(std.testing.allocator);
}

// ── Manual fuzz driver (finding H14): the native --fuzz body runs once under
//    `zig build test` due to a 0.16 toolchain bug, so a deterministic loop runs
//    >= 10000 iterations seeded by std.testing.random_seed.

test "fuzz: isReservedRoute boundary-matches only (native body)" {
    try std.testing.fuzz({}, fuzzReserved, .{});
}

test "fuzz: isReservedRoute boundary-matches only (manual >= 10000 iterations)" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        var buf: [256]u8 = undefined;
        const n = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..n]) |*c| c.* = rand.int(u8);
        try checkReservedInvariant(buf[0..n]);
    }
}

fn fuzzReserved(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const n = smith.slice(&buf);
    try checkReservedInvariant(buf[0..n]);
}

/// Shared invariant body so the native and manual fuzz drivers test the same
/// property: if isReservedRoute accepted, the path ends at the prefix or has a
/// '/' immediately after it.
fn checkReservedInvariant(path: []const u8) !void {
    if (!isReservedRoute(path)) return;
    var matched_clean = false;
    for (reserved_route_prefixes) |p| {
        if (!std.mem.startsWith(u8, path, p)) continue;
        if (path.len == p.len) {
            matched_clean = true;
            break;
        }
        if (path[p.len] == '/') {
            matched_clean = true;
            break;
        }
    }
    try std.testing.expect(matched_clean);
}

test "fuzz: decode never panics on arbitrary bytes (manual >= 10000 iterations)" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        var buf: [4096]u8 = undefined;
        const n = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..n]) |*c| c.* = rand.int(u8);
        const r = decode(std.testing.allocator, buf[0..n], MAX_MESSAGE_LEN) catch continue;
        r.deinit(std.testing.allocator);
    }
}

test "fuzz: jsString output is always a valid JSON string round-trip" {
    try std.testing.fuzz({}, fuzzEscape, .{});
}

fn fuzzEscape(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    const input = buf[0..n];

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try jsString(&aw.writer, input);
    const out = aw.writer.buffered();

    // Always: structurally safe — no breakout possible.
    try assertSafeJsLiteral(out);

    // Round-trip: only when input is valid UTF-8 (jsString intentionally passes
    // invalid UTF-8 raw; std.json.parseFromSlice would wrongly reject it).
    if (std.unicode.utf8ValidateSlice(input)) {
        var parsed = try std.json.parseFromSlice([]const u8, std.testing.allocator, out, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(input, parsed.value);
    }
}
