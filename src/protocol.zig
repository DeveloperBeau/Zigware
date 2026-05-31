const std = @import("std");

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

pub fn decode(alloc: std.mem.Allocator, text: []const u8) DecodeError!Message {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return error.BadMessage;
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
fn writeJsonAsJsLiteral(w: *std.Io.Writer, text: []const u8) !void {
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

// ─── Tests ───────────────────────────────────────────────────────────────────

test "decode parses well-formed message" {
    const msg = try decode(std.testing.allocator, "{\"id\":7,\"cmd\":\"sha256\",\"args\":{\"megabytes\":4}}");
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 7), msg.id);
    try std.testing.expectEqualStrings("sha256", msg.cmd);
}

test "decode rejects malformed input with error, no panic" {
    try std.testing.expectError(error.BadMessage, decode(std.testing.allocator, "not json"));
    try std.testing.expectError(error.BadMessage, decode(std.testing.allocator, "{\"id\":\"x\"}"));
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

// ─── Fuzz targets ────────────────────────────────────────────────────────────

test "fuzz: decode never panics on arbitrary bytes" {
    try std.testing.fuzz({}, fuzzDecode, .{});
}

fn fuzzDecode(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    const input = buf[0..n];
    const r = decode(std.testing.allocator, input) catch return;
    r.deinit(std.testing.allocator);
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
    var parsed = std.json.parseFromSlice([]const u8, std.testing.allocator, aw.writer.buffered(), .{}) catch return error.NotValidJsonString;
    defer parsed.deinit();
    try std.testing.expectEqualStrings(input, parsed.value);
}
