const std = @import("std");
const proc = @import("proc.zig");
const dev = @import("dev.zig");
const Manifest = @import("zigware_manifest").Manifest;

pub const Arch = enum { host }; // universal (lipo arm64 + x86_64) reserved for v0.2

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
};

pub const BuildOptions = struct {
    manifest: *const Manifest,
    optimize: std.builtin.OptimizeMode = .ReleaseSafe, // NOT ReleaseFast; src/main.zig comptime-bans it
    out_dir: []const u8,
    builder: dev.BuildRunner,
    proc: proc.Spawner,
};

/// build orchestrator: beforeBuildCommand -> asset embed -> CSP inject -> release compile -> Artifacts.
pub fn run(io: std.Io, gpa: std.mem.Allocator, opts: BuildOptions) anyerror!Artifacts {
    _ = io;
    _ = gpa;
    _ = opts;
    return error.NotImplemented;
}
