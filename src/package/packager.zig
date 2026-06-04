const std = @import("std");

pub const Arch = enum { host }; // universal (lipo arm64 + x86_64) reserved for v0.2

/// The F -> G handoff struct. F populates the binary; G fills the rest and returns it.
/// THIS is the single definition; src/cli imports it (do not redefine in cli/build.zig).
///
/// OWNERSHIP: ALL string fields (`binary_path`, `app_name`, `bundle_id`, `version`,
/// and the optional `icon_path`/`entitlements_path`/`signing_identity` when present)
/// are `opts.gpa`-owned dupes. `package()` dupes `binaries[0]` into `binary_path` and
/// dupes the resolved `signing_identity`/other config-sourced fields rather than
/// borrowing the parsed manifest or `opts.binaries`. The caller (the T11 pipeline test
/// and T12's `main`) MUST free the returned value via `deinit` after consuming it; the
/// leak-clean test over `std.testing.allocator` depends on this contract.
pub const Artifacts = struct {
    binary_path: []const u8,
    app_name: []const u8,
    bundle_id: []const u8,
    version: []const u8,
    icon_path: ?[]const u8,
    entitlements_path: ?[]const u8,
    signing_identity: ?[]const u8,
    frontend_embedded: bool,
    arch: Arch,

    /// Frees every gpa-owned string field. Mirrors the dupe set in `package()`.
    pub fn deinit(self: Artifacts, gpa: std.mem.Allocator) void {
        gpa.free(self.binary_path);
        gpa.free(self.app_name);
        gpa.free(self.bundle_id);
        gpa.free(self.version);
        if (self.icon_path) |p| gpa.free(p);
        if (self.entitlements_path) |p| gpa.free(p);
        if (self.signing_identity) |p| gpa.free(p);
    }
};

const required_packager_methods = [_][]const u8{ "assembleBundle", "sign", "notarize", "makeDmg" };

/// Comptime conformance: a future Windows/Linux packager missing a stage is a clear
/// compile error, not a cryptic instantiation failure (mirrors assertBackend).
pub fn assertPackager(comptime P: type) void {
    comptime {
        for (required_packager_methods) |name| {
            if (!@hasDecl(P, name)) @compileError(@typeName(P) ++ " is missing packager method: " ++ name);
            if (@typeInfo(@TypeOf(@field(P, name))) != .@"fn")
                @compileError(@typeName(P) ++ "." ++ name ++ " is not a fn");
        }
    }
}

// NOTE: there is NO `Packager(P)` wrapper type. The conformance seam is `assertPackager`
// alone, called once at the `builtin.os` packager-selection site in `package()` (Task 11) —
// exactly as `src/app.zig:93` calls `assertBackend(B)` at its selection site. A holds no
// `Backend(P)` wrapper either; its only comptime gate is `assertBackend`. `MacPackager`'s
// four stages are then called individually by `package()`, never through an instantiated
// generic. Do NOT add an empty `Packager(P)` wrapper — it would hold no state, forward
// nothing, and have no callers.

test "assertPackager accepts a conformant stub and the four stage names are stable" {
    const Stub = struct {
        pub fn assembleBundle() void {}
        pub fn sign() void {}
        pub fn notarize() void {}
        pub fn makeDmg() void {}
    };
    assertPackager(Stub);
    try std.testing.expectEqual(@as(usize, 4), required_packager_methods.len);
}
