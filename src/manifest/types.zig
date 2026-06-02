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

/// Stable diagnostic codes for the build-time config + capability cross-check
/// stream. D emits the config codes; C emits `fuse_requires_capability` and
/// `capability_window_unknown` (it has the capability-file contents D does not
/// parse). Both streams read uniformly because they share this vocabulary.
pub const Code = enum {
    // --- D-emitted (manifest validation) ---
    missing_identifier,
    invalid_identifier,
    invalid_version,
    no_main_window,
    duplicate_window_label,
    empty_window_label,
    unknown_capability_ref,
    inspector_in_release,
    dev_url_without_command, // WARNING (is_error=false)
    override_for_target_dropped, // WARNING: a per-OS override file exists but target_os has no mapping
    // --- C-emitted (capability-file cross-checks); kept here for one vocabulary ---
    fuse_requires_capability,
    capability_window_unknown,
};

/// One build-time diagnostic. `message` is a static template keyed off `code`
/// (no allocation, never freed). `path` is the dotted manifest location of the
/// offending field; allocator-owned when present, freed by Diagnostics.deinit.
///
/// DEVIATION (ratified): `path` is OPTIONAL, not the spec's literal []const u8.
/// C's advisory enforcement diagnostics carry no path; an optional lets C's
/// `.{ .code, .message }` literals compile unchanged and lets deinit free only
/// the non-null, heap-built paths D produces.
pub const Diagnostic = struct {
    code: Code,
    is_error: bool = true,
    message: []const u8,
    /// Invariant: when non-null, `path` MUST be allocator-owned (built with
    /// std.fmt.allocPrint from static segments). Diagnostics.deinit frees it.
    /// A static-string `path` will cause an invalid-free under the testing
    /// allocator; if a static path ever makes sense, dup it before adding.
    path: ?[]const u8 = null,
};

/// Build-time diagnostic sink. Two writers by design:
///   - `report`: OOM-SWALLOWING. C's GrantTable.compile fail-closed path uses
///     this; a dropped advisory diagnostic must never make the build fail-open.
///   - `add`: OOM-SURFACING. D's manifest validation uses this; an allocation
///     failure while recording a config error should abort the build, not
///     silently lose the error.
pub const Diagnostics = struct {
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn report(self: *Diagnostics, alloc: std.mem.Allocator, d: Diagnostic) void {
        self.items.append(alloc, d) catch {};
    }

    pub fn add(self: *Diagnostics, alloc: std.mem.Allocator, d: Diagnostic) std.mem.Allocator.Error!void {
        try self.items.append(alloc, d);
    }

    /// True if any item is error-level (warnings such as dev_url_without_command excluded).
    pub fn hasErrors(self: Diagnostics) bool {
        for (self.items.items) |d| if (d.is_error) return true;
        return false;
    }

    pub fn deinit(self: *Diagnostics, alloc: std.mem.Allocator) void {
        for (self.items.items) |d| if (d.path) |p| alloc.free(p);
        self.items.deinit(alloc);
    }
};

test "Diagnostics collects reported diagnostics" {
    var diags: Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    diags.report(std.testing.allocator, .{ .code = .fuse_requires_capability, .message = "x" });
    try std.testing.expectEqual(@as(usize, 1), diags.items.items.len);
    try std.testing.expectEqual(Code.fuse_requires_capability, diags.items.items[0].code);
}

test "Fuses default to the deny-by-default posture (all false)" {
    const f: Fuses = .{};
    try std.testing.expect(!f.allowRemoteContent and !f.allowEval and !f.allowShell and !f.debugInspector);
}

test "Diagnostics.add surfaces OOM and hasErrors reflects error-level items" {
    var diags: Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    try diags.add(std.testing.allocator, .{ .code = .invalid_version, .message = "bad", .path = null });
    try std.testing.expect(diags.hasErrors());
    try diags.add(std.testing.allocator, .{ .code = .dev_url_without_command, .is_error = false, .message = "warn", .path = null });
    try std.testing.expectEqual(@as(usize, 2), diags.items.items.len);
    // a warnings-only set has no errors:
    var warn_only: Diagnostics = .{};
    defer warn_only.deinit(std.testing.allocator);
    try warn_only.add(std.testing.allocator, .{ .code = .dev_url_without_command, .is_error = false, .message = "w", .path = null });
    try std.testing.expect(!warn_only.hasErrors());
}
