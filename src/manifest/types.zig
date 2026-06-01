//! Minimal manifest types owned by sub-project D (manifest/config). Created here
//! by C because C consumes them and is built before D. D later takes ownership
//! and extends these (the manifest parser, JSON schema, fuse storage). This file
//! imports nothing from src/security/ so there is no dependency cycle.

const std = @import("std");

/// Build-time, runtime-immutable kill switches (Electron-fuses analog). All
/// default false (deny-by-default posture). C reads `allowRemoteContent` and
/// `allowShell` at GrantTable.compile to force-drop grants; F enforces
/// `allowEval` and `debugInspector`.
pub const Fuses = struct {
    allowRemoteContent: bool = false,
    allowEval: bool = false,
    allowShell: bool = false,
    debugInspector: bool = false,
};

/// Stable diagnostic codes for the build-time capability cross-check stream.
/// D extends this enum as it adds manifest validation; C only emits the two it
/// owns at compile time.
pub const Code = enum {
    fuse_requires_capability, // a fuse-off force-dropped a requested grant
    capability_window_unknown, // a windows label glob matched no known label
};

/// One build-time diagnostic. Reported, not fatal (unknown permission identifiers
/// are the only fatal case and surface as error.UnknownPermission, not a Diagnostic).
pub const Diagnostic = struct {
    code: Code,
    /// Human-readable; never includes secrets. Borrowed for the Diagnostic's
    /// lifetime (the caller owns the backing memory).
    message: []const u8,
};

/// A growable sink the compile path reports diagnostics through. D owns the
/// richer version; this minimal one collects into a caller-provided ArrayList.
pub const Diagnostics = struct {
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn report(self: *Diagnostics, alloc: std.mem.Allocator, d: Diagnostic) void {
        // Reporting failure (OOM) must never break the build path silently: on
        // OOM we drop the diagnostic but keep going (it is advisory, not fatal).
        self.list.append(alloc, d) catch {};
    }

    pub fn deinit(self: *Diagnostics, alloc: std.mem.Allocator) void {
        self.list.deinit(alloc);
    }
};

test "Diagnostics collects reported diagnostics" {
    var diags: Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    diags.report(std.testing.allocator, .{ .code = .fuse_requires_capability, .message = "x" });
    try std.testing.expectEqual(@as(usize, 1), diags.list.items.len);
    try std.testing.expectEqual(Code.fuse_requires_capability, diags.list.items[0].code);
}

test "Fuses default to the deny-by-default posture (all false)" {
    const f: Fuses = .{};
    try std.testing.expect(!f.allowRemoteContent and !f.allowEval and !f.allowShell and !f.debugInspector);
}
