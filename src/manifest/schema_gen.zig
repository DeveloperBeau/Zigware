//! JSON Schema emitter for the manifest type. Walks `types.Manifest` via
//! `@typeInfo` so a new field on Manifest (or any nested struct) automatically
//! appears in the generated schema. A hand-coded emitter is rejected; the
//! drift-guard test below enforces this by asserting every top-level field
//! name appears in the rendered output.
//!
//! Optional convention: `?T` is rendered as `{"type": "<T>"}` AND the field is
//! omitted from the parent's `required` array. The alternative (`["string",
//! "null"]`) is rejected for two reasons: (1) `.zon` itself has no JSON `null`
//! literal, so a tool that emits `null` against this schema would still fail to
//! parse into Manifest; (2) the omit-from-required form matches Apple/Microsoft
//! editor tooling defaults and produces less noisy autocomplete in VSCode.

const std = @import("std");
const types = @import("types.zig");

/// Render a Draft 2020-12 JSON Schema for `types.Manifest` to the given writer.
/// REFLECTION-DRIVEN via @typeInfo: a new field on Manifest (or any nested
/// struct) automatically appears in the rendered schema.
pub fn writeSchema(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\{
        \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
        \\  "title": "Zigware Manifest",
        \\
    );
    try writeStructBody(writer, types.Manifest, 1);
    try writer.writeAll("\n}\n");
}

/// Emit the body of an object schema (`"type": "object", "properties": ...,
/// "required": [...], "additionalProperties": false`) WITHOUT the surrounding
/// `{` / `}`. The caller writes those, plus any sibling keys such as
/// `$schema` / `title`. `indent` is the indentation level of the enclosing
/// object's keys (in two-space units).
fn writeStructBody(writer: *std.Io.Writer, comptime T: type, comptime indent: usize) std.Io.Writer.Error!void {
    const fields = @typeInfo(T).@"struct".fields;
    try writeIndent(writer, indent);
    try writer.writeAll("\"type\": \"object\",\n");
    try writeIndent(writer, indent);
    try writer.writeAll("\"properties\": {\n");
    inline for (fields, 0..) |f, i| {
        try writeIndent(writer, indent + 1);
        try writer.print("\"{s}\": ", .{f.name});
        try writeType(writer, unwrapOptional(f.type), indent + 1);
        if (i + 1 < fields.len) try writer.writeAll(",");
        try writer.writeAll("\n");
    }
    try writeIndent(writer, indent);
    try writer.writeAll("},\n");
    try writeIndent(writer, indent);
    try writer.writeAll("\"required\": [");
    comptime var first_required = true;
    inline for (fields) |f| {
        // A field is required iff it has no default value AND is not optional.
        // The omit-from-required convention for `?T` means optional fields are
        // implicitly absent-allowed regardless of whether they carry a default.
        if (f.default_value_ptr == null and @typeInfo(f.type) != .optional) {
            if (!first_required) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{f.name});
            first_required = false;
        }
    }
    try writer.writeAll("],\n");
    try writeIndent(writer, indent);
    try writer.writeAll("\"additionalProperties\": false");
}

/// Strip a single layer of optional wrapping. Used so `?[]const u8` renders
/// as `{"type": "string"}` while the field is implicitly omitted from the
/// parent's `required` list.
fn unwrapOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// Recursively render a JSON Schema fragment describing `T`. The fragment is
/// always a single JSON value (object or primitive), not a key/value pair.
fn writeType(writer: *std.Io.Writer, comptime T: type, comptime indent: usize) std.Io.Writer.Error!void {
    if (T == []const u8) {
        try writer.writeAll("{\"type\": \"string\"}");
        return;
    }
    switch (@typeInfo(T)) {
        .bool => try writer.writeAll("{\"type\": \"boolean\"}"),
        .int, .comptime_int => try writer.writeAll("{\"type\": \"integer\"}"),
        .float, .comptime_float => try writer.writeAll("{\"type\": \"number\"}"),
        .optional => |o| try writeType(writer, o.child, indent),
        .@"enum" => |e| {
            try writer.writeAll("{\"enum\": [");
            inline for (e.fields, 0..) |ef, i| {
                if (i != 0) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{ef.name});
            }
            try writer.writeAll("]}");
        },
        .pointer => |p| {
            // Slices only. The manifest contains no single-item pointers; an
            // unexpected one is a comptime error so a new field cannot land
            // with a quietly-wrong schema.
            if (p.size != .slice) @compileError("schema_gen: unsupported pointer type " ++ @typeName(T));
            try writer.writeAll("{\"type\": \"array\", \"items\": ");
            try writeType(writer, p.child, indent);
            try writer.writeAll("}");
        },
        .@"struct" => {
            try writer.writeAll("{\n");
            try writeStructBody(writer, T, indent + 1);
            try writer.writeAll("\n");
            try writeIndent(writer, indent);
            try writer.writeAll("}");
        },
        else => @compileError("schema_gen: unsupported type " ++ @typeName(T)),
    }
}

fn writeIndent(writer: *std.Io.Writer, comptime n: usize) std.Io.Writer.Error!void {
    comptime var i: usize = 0;
    inline while (i < n) : (i += 1) try writer.writeAll("  ");
}

/// Build-runnable main: emits `zigware-manifest.schema.json` at the repo root.
/// Mirrors `src/emit_dts.zig` exactly: DebugAllocator, Allocating writer,
/// std.Io.Threaded for the io seam, std.Io.Dir.cwd().writeFile for the write.
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    try writeSchema(&aw.writer);

    // 0.16 filesystem API: std.Io.Dir.cwd() + io-taking writeFile
    // (std.fs.cwd() does not exist on this toolchain).
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "zigware-manifest.schema.json",
        .data = aw.writer.buffered(),
    });
}

test "schema reflects every Manifest top-level field (drift guard)" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeSchema(&aw.writer);
    const out = aw.writer.buffered();
    inline for (@typeInfo(types.Manifest).@"struct".fields) |f| {
        const needle = "\"" ++ f.name ++ "\"";
        try std.testing.expect(std.mem.indexOf(u8, out, needle) != null);
    }
    // required-set check (robust to whitespace + field ordering): the schema
    // emits a `"required"` key at every object level (top-level + every nested
    // struct), so scan EVERY `"required"` occurrence; at least one window of
    // 256 bytes must contain all three top-level required-field names.
    const required_names = [_][]const u8{ "\"identifier\"", "\"productName\"", "\"version\"" };
    var search_from: usize = 0;
    var found_top_required = false;
    while (std.mem.indexOfPos(u8, out, search_from, "\"required\"")) |req_off| {
        const slice = out[req_off..@min(req_off + 256, out.len)];
        var all_present = true;
        for (required_names) |name| {
            if (std.mem.indexOf(u8, slice, name) == null) {
                all_present = false;
                break;
            }
        }
        if (all_present) {
            found_top_required = true;
            break;
        }
        search_from = req_off + 1;
    }
    try std.testing.expect(found_top_required);
}

test "schema rejects unknown top-level keys via additionalProperties:false" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeSchema(&aw.writer);
    const out = aw.writer.buffered();
    // Closes the door on typos in user manifests. The schema renders
    // additionalProperties at every nested object too, but this test only
    // requires that AT LEAST one occurrence is present (the top-level one).
    try std.testing.expect(std.mem.indexOf(u8, out, "\"additionalProperties\": false") != null);
}

test "schema declares Draft 2020-12 and renders an enum for QuitPolicy" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeSchema(&aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "https://json-schema.org/draft/2020-12/schema") != null);
    // QuitPolicy is the only enum reachable from Manifest with multiple
    // variants under app.quitOnLastWindowClosed; asserting one variant proves
    // the enum walker fired.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"keep_running_on_last_close\"") != null);
}
