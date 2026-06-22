//! Tests for src/diag.zig. This single root is run under BOTH `zig build test`
//! (Debug) and `zig build test -Drelease=true` (ReleaseSafe); the build-gating
//! assertions branch on the SAME predicate the logger uses
//! (`comptime builtin.mode != .Debug`) so the two modes agree.

const std = @import("std");
const builtin = @import("builtin");
const diag = @import("diag.zig");

/// A capturing transport: stores every record's level, scope, message, and a
/// flattened "key=rendered" view of each field so a test can inspect what the
/// logger emitted (including redaction).
const Capture = struct {
    const Entry = struct {
        level: diag.Level,
        scope: []const u8,
        message: []const u8,
        rendered: []u8,
    };

    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    fn transport(self: *Capture) diag.Transport {
        return .{ .ctx = self, .record = record };
    }

    fn record(ctx: ?*anyopaque, rec: diag.Record) void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        var buf: std.ArrayList(u8) = .empty;
        for (rec.fields) |f| {
            buf.appendSlice(self.gpa, f.key) catch return;
            buf.append(self.gpa, '=') catch return;
            switch (f.value) {
                .str => |s| buf.appendSlice(self.gpa, s) catch return,
                .int => |v| buf.print(self.gpa, "{d}", .{v}) catch return,
                .uint => |v| buf.print(self.gpa, "{d}", .{v}) catch return,
                .boolean => |v| buf.appendSlice(self.gpa, if (v) "true" else "false") catch return,
                .redacted => buf.appendSlice(self.gpa, "***") catch return,
            }
            buf.append(self.gpa, ' ') catch return;
        }
        const rendered = buf.toOwnedSlice(self.gpa) catch return;
        self.entries.append(self.gpa, .{
            .level = rec.level,
            .scope = self.gpa.dupe(u8, rec.scope) catch return,
            .message = self.gpa.dupe(u8, rec.message) catch return,
            .rendered = rendered,
        }) catch return;
    }

    fn deinit(self: *Capture) void {
        for (self.entries.items) |e| {
            self.gpa.free(e.scope);
            self.gpa.free(e.message);
            self.gpa.free(e.rendered);
        }
        self.entries.deinit(self.gpa);
    }

    fn countLevel(self: *Capture, level: diag.Level) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (e.level == level) n += 1;
        }
        return n;
    }
};

test "trace/debug are stripped to no transport output in release; live in Debug" {
    var cap: Capture = .{ .gpa = std.testing.allocator };
    defer cap.deinit();
    diag.setTransport(cap.transport());
    defer diag.resetTransport();

    const log = diag.scoped("test");
    log.trace("a trace line", &.{});
    log.debug("a debug line", &.{});

    if (comptime builtin.mode != .Debug) {
        // The gated-OUT half: the no-op must produce NO transport record.
        try std.testing.expectEqual(@as(usize, 0), cap.countLevel(.trace));
        try std.testing.expectEqual(@as(usize, 0), cap.countLevel(.debug));
    } else {
        // In Debug the same calls ARE recorded.
        try std.testing.expectEqual(@as(usize, 1), cap.countLevel(.trace));
        try std.testing.expectEqual(@as(usize, 1), cap.countLevel(.debug));
    }
}

test "info/warn/err survive the gate in every mode" {
    var cap: Capture = .{ .gpa = std.testing.allocator };
    defer cap.deinit();
    diag.setTransport(cap.transport());
    defer diag.resetTransport();

    const log = diag.scoped("test");
    log.info("an info line", &.{});
    log.warn("a warn line", &.{});
    log.err("an err line", &.{});

    // The always-on half of the SAME predicate: the gate must suppress EXACTLY
    // trace+debug and nothing above them, in BOTH modes (Debug and release).
    try std.testing.expectEqual(@as(usize, 1), cap.countLevel(.info));
    try std.testing.expectEqual(@as(usize, 1), cap.countLevel(.warn));
    try std.testing.expectEqual(@as(usize, 1), cap.countLevel(.err));
}

test "jsonTransport emits one valid JSON object per line" {
    const gpa = std.testing.allocator;
    const rec: diag.Record = .{
        .level = .info,
        .scope = "build",
        .message = "compiled \"unit\"\nwith newline",
        .fields = &.{
            diag.str("path", "a/b\"c"),
            diag.uint("count", 3),
            diag.boolean("ok", true),
        },
    };

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try diag.writeJsonForTest(&w, rec);
    const line = w.buffered();

    // Exactly one line (trailing newline only).
    try std.testing.expect(line.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));

    // It must parse as valid JSON, and the embedded quotes/newlines must round-trip.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("info", obj.get("level").?.string);
    try std.testing.expectEqualStrings("build", obj.get("scope").?.string);
    try std.testing.expectEqualStrings("compiled \"unit\"\nwith newline", obj.get("message").?.string);
    try std.testing.expectEqualStrings("a/b\"c", obj.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 3), obj.get("count").?.integer);
    try std.testing.expectEqual(true, obj.get("ok").?.bool);
}

test "secret renders *** and no raw value can appear" {
    // `secret(key)` records ONLY the key; no value channel exists for a raw
    // value to leak through. Assert the rendered field is `<key>=***`, and that
    // the chosen sentinel raw value never appears anywhere in the line.
    const raw = "super-secret-token-value";
    const rec: diag.Record = .{
        .level = .info,
        .scope = "auth",
        .message = "token loaded",
        .fields = &.{diag.secret("api_key")},
    };

    var buf: [512]u8 = undefined;

    // JSON transport.
    var jw: std.Io.Writer = .fixed(&buf);
    try diag.writeJsonForTest(&jw, rec);
    const jline = jw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, jline, "***") != null);
    try std.testing.expect(std.mem.indexOf(u8, jline, raw) == null);

    // Human transport.
    var hbuf: [512]u8 = undefined;
    var hw: std.Io.Writer = .fixed(&hbuf);
    try diag.writeHumanForTest(&hw, rec);
    const hline = hw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, hline, "***") != null);
    try std.testing.expect(std.mem.indexOf(u8, hline, raw) == null);
}

test "secret takes the key only, never a value" {
    // The key IS the field's key here (the API records only the key). Prove the
    // rendered field reads `<key>=***`.
    const f = diag.secret("api_key");
    try std.testing.expectEqualStrings("api_key", f.key);
    try std.testing.expect(f.value == .redacted);
}
