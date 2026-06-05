//! Structured, leveled diagnostics logger.
//!
//! This is the framework's DIAGNOSTIC channel (build/manifest/dev errors and
//! traces), NOT the CLI's user-facing program output (help/version/packaging
//! result text stay on a plain stdout writer). Every record carries a level, a
//! scope, a free-form message, and zero or more typed fields.
//!
//! Build-gating: `trace` and `debug` lower to no-ops whenever
//! `comptime builtin.mode != .Debug` (the single normative predicate). The
//! no-op performs NO format/transport work — under ReleaseSafe/ReleaseFast/
//! ReleaseSmall those two levels produce no output at all. `info`/`warn`/`err`
//! are always live so ship builds keep their error diagnostics. Because `fields`
//! is a runtime slice, the CALLER still materialises the slice literal before a
//! gated-out call is entered; the only guarantee is that the no-op emits nothing.
//!
//! Redaction: `secret(key)` records ONLY the key — the raw value never enters
//! the logger — and renders as `***` in every transport.
//!
//! Transport default flips by mode: human-readable lines in Debug, JSON-lines
//! in release. `setTransport` swaps the sink (used by tests to capture output).

const std = @import("std");
const builtin = @import("builtin");

/// The single normative build-gating predicate. `trace`/`debug` are stripped to
/// no-ops whenever this is true. Exported so a test can assert against the SAME
/// expression the gate uses (they must agree).
pub const verbose_stripped = builtin.mode != .Debug;

pub const Level = enum {
    trace,
    debug,
    info,
    warn,
    err,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// A typed field value. `.redacted` carries no payload — only the key survives,
/// rendered as `***`.
pub const Value = union(enum) {
    str: []const u8,
    int: i64,
    uint: u64,
    boolean: bool,
    redacted,
};

pub const Field = struct {
    key: []const u8,
    value: Value,
};

/// Convenience field constructors so call sites read as `diag.str("path", p)`.
pub fn str(key: []const u8, v: []const u8) Field {
    return .{ .key = key, .value = .{ .str = v } };
}
pub fn int(key: []const u8, v: i64) Field {
    return .{ .key = key, .value = .{ .int = v } };
}
pub fn uint(key: []const u8, v: u64) Field {
    return .{ .key = key, .value = .{ .uint = v } };
}
pub fn boolean(key: []const u8, v: bool) Field {
    return .{ .key = key, .value = .{ .boolean = v } };
}

/// Records ONLY the key — the raw value never enters the logger and renders as
/// `***`. Takes the key alone by design (Locked decision 7).
pub fn secret(key: []const u8) Field {
    return .{ .key = key, .value = .redacted };
}

/// A transport sink: a function plus an opaque context the function casts back.
/// `record` receives a fully assembled record and is responsible for emitting
/// it (a line, a JSON object, a captured buffer, etc.).
pub const Transport = struct {
    ctx: ?*anyopaque,
    record: *const fn (ctx: ?*anyopaque, rec: Record) void,
};

pub const Record = struct {
    level: Level,
    scope: []const u8,
    message: []const u8,
    fields: []const Field,
};

/// The active transport. Defaults by build mode: human-readable in Debug,
/// JSON-lines in release. Swapped via `setTransport` (tests capture here).
var active_transport: Transport = .{
    .ctx = null,
    .record = if (builtin.mode == .Debug) humanRecord else jsonRecord,
};

pub fn setTransport(t: Transport) void {
    active_transport = t;
}

/// Restore the build-default transport (human in Debug, JSON-lines in release).
pub fn resetTransport() void {
    active_transport = .{
        .ctx = null,
        .record = if (builtin.mode == .Debug) humanRecord else jsonRecord,
    };
}

// ─── Scoped emitter ──────────────────────────────────────────────────────────

pub fn scoped(comptime scope: []const u8) Scoped {
    return .{ .scope = scope };
}

pub const Scoped = struct {
    scope: []const u8,

    /// Stripped to a no-op when `verbose_stripped` (release builds). The no-op
    /// does NO transport work.
    pub fn trace(self: Scoped, message: []const u8, fields: []const Field) void {
        if (comptime verbose_stripped) return;
        emit(.trace, self.scope, message, fields);
    }

    /// Stripped to a no-op when `verbose_stripped` (release builds). The no-op
    /// does NO transport work.
    pub fn debug(self: Scoped, message: []const u8, fields: []const Field) void {
        if (comptime verbose_stripped) return;
        emit(.debug, self.scope, message, fields);
    }

    pub fn info(self: Scoped, message: []const u8, fields: []const Field) void {
        emit(.info, self.scope, message, fields);
    }

    pub fn warn(self: Scoped, message: []const u8, fields: []const Field) void {
        emit(.warn, self.scope, message, fields);
    }

    pub fn err(self: Scoped, message: []const u8, fields: []const Field) void {
        emit(.err, self.scope, message, fields);
    }
};

fn emit(level: Level, scope: []const u8, message: []const u8, fields: []const Field) void {
    active_transport.record(active_transport.ctx, .{
        .level = level,
        .scope = scope,
        .message = message,
        .fields = fields,
    });
}

// ─── Built-in transports ─────────────────────────────────────────────────────

const REDACTED = "***";

/// Human-readable single line: `LEVEL [scope] message key=value key=***`.
/// Writes to stderr (the diagnostic channel) via the same low-level primitive
/// `std.debug.print` uses; errors are swallowed (a logger must never fault).
fn humanRecord(_: ?*anyopaque, rec: Record) void {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeHuman(&w, rec) catch {
        // Overflowed the fixed buffer; emit a truncated best-effort line.
        std.debug.print("{s} [{s}] {s} ...\n", .{ rec.level.label(), rec.scope, rec.message });
        return;
    };
    std.debug.print("{s}", .{w.buffered()});
}

fn writeHuman(w: *std.Io.Writer, rec: Record) !void {
    try w.print("{s} [{s}] {s}", .{ rec.level.label(), rec.scope, rec.message });
    for (rec.fields) |f| {
        try w.writeAll(" ");
        try w.writeAll(f.key);
        try w.writeAll("=");
        switch (f.value) {
            .str => |s| try w.writeAll(s),
            .int => |v| try w.print("{d}", .{v}),
            .uint => |v| try w.print("{d}", .{v}),
            .boolean => |v| try w.writeAll(if (v) "true" else "false"),
            .redacted => try w.writeAll(REDACTED),
        }
    }
    try w.writeAll("\n");
}

/// One JSON object per line. Strings are escaped with std.json (JSON context,
/// NOT the JS/HTML eval-channel rules of protocol.jsString).
fn jsonRecord(_: ?*anyopaque, rec: Record) void {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeJson(&w, rec) catch {
        std.debug.print(
            "{{\"level\":\"{s}\",\"scope\":\"truncated\",\"message\":\"truncated\"}}\n",
            .{@tagName(rec.level)},
        );
        return;
    };
    std.debug.print("{s}", .{w.buffered()});
}

fn writeJson(w: *std.Io.Writer, rec: Record) !void {
    const opts: std.json.Stringify.Options = .{};
    try w.writeAll("{\"level\":");
    try std.json.Stringify.encodeJsonString(@tagName(rec.level), opts, w);
    try w.writeAll(",\"scope\":");
    try std.json.Stringify.encodeJsonString(rec.scope, opts, w);
    try w.writeAll(",\"message\":");
    try std.json.Stringify.encodeJsonString(rec.message, opts, w);
    for (rec.fields) |f| {
        try w.writeAll(",");
        try std.json.Stringify.encodeJsonString(f.key, opts, w);
        try w.writeAll(":");
        switch (f.value) {
            .str => |s| try std.json.Stringify.encodeJsonString(s, opts, w),
            .int => |v| try w.print("{d}", .{v}),
            .uint => |v| try w.print("{d}", .{v}),
            .boolean => |v| try w.writeAll(if (v) "true" else "false"),
            .redacted => try std.json.Stringify.encodeJsonString(REDACTED, opts, w),
        }
    }
    try w.writeAll("}\n");
}

// ─── Test-only render helpers ────────────────────────────────────────────────
// Exposed so src/diag_tests.zig (a separate module root) can render a Record to
// a fixed writer and inspect the bytes without going through a captured Io sink.

pub fn writeJsonForTest(w: *std.Io.Writer, rec: Record) !void {
    return writeJson(w, rec);
}

pub fn writeHumanForTest(w: *std.Io.Writer, rec: Record) !void {
    return writeHuman(w, rec);
}
