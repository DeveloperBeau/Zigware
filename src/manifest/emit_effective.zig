//! Build-time codegen: parses zigware.zon + per-OS override, validates, and
//! re-serializes the MERGED+VALIDATED manifest as a .zon literal at the path
//! given as argv[1]. argv[2] is the base manifest path; argv[3..] are per-OS
//! override paths. The codegen NEVER opens std.Io.Dir.cwd() for source input;
//! build.zig passes every input path explicitly so the Run step's cache key is
//! stable. Production embedded() reads this artifact, NOT the raw zigware.zon.
const std = @import("std");
const parse = @import("parse.zig");
const types = @import("types.zig");
const diag = @import("diag");

const log = diag.scoped("manifest");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return error.MissingArgs;
    const out_path = args[1];
    const base_path = args[2];
    // toSlice yields []const [:0]const u8; the loader takes plain []const u8
    // slices, so re-pack into a non-sentinel view for the call boundary.
    var override_paths_buf = try arena.alloc([]const u8, args.len - 3);
    for (args[3..], 0..) |a, i| override_paths_buf[i] = a;
    const override_paths: []const []const u8 = override_paths_buf;

    var diagnostics: types.Diagnostics = .{};
    defer diagnostics.deinit(gpa);
    // NOTE: target_os here is the codegen exe's compile target, which build.zig
    // sets equal to the build's user-selected target via standardTargetOptions.
    // Cross-compiling the codegen for a non-host target would also require an
    // emulator to run it; the supported path is a native build on the build host.
    const tag = @import("builtin").target.os.tag;
    // Capability cross-check is currently NOT performed at codegen time: the
    // codegen passes an empty capability id set to the validator. Adding
    // security.capabilities entries to zigware.zon would cause spurious
    // unknown_capability_ref errors here. build.zig pins src/capabilities/*.zon
    // via addFileArg (for cache invalidation), but does not yet thread the
    // basenames through argv. Resolve before sub-project E ships capabilities.
    const empty_caps: []const []const u8 = &.{};
    const m = parse.parseAtBuildFromPaths(gpa, io, base_path, override_paths, empty_caps, tag, .Debug, &diagnostics) catch |e| {
        for (diagnostics.items.items) |d| {
            if (d.path) |p| {
                log.err(d.message, &.{diag.str("path", p)});
            } else {
                log.err(d.message, &.{});
            }
        }
        return e;
    };
    defer parse.freeManifest(gpa, m);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.zon.stringify.serialize(m, .{}, &aw.writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = aw.writer.buffered() });
}
