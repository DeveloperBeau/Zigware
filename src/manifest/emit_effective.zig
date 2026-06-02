//! Build-time codegen: parses zigware.zon + per-OS override, validates, and
//! re-serializes the MERGED+VALIDATED manifest as a .zon literal at the path
//! given as argv[1]. argv[2] is the base manifest path; argv[3..] are per-OS
//! override paths. The codegen NEVER opens std.Io.Dir.cwd() for source input;
//! build.zig passes every input path explicitly so the Run step's cache key is
//! stable. Production embedded() reads this artifact, NOT the raw zigware.zon.
const std = @import("std");
const parse = @import("parse.zig");
const types = @import("types.zig");

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

    var diag: types.Diagnostics = .{};
    defer diag.deinit(gpa);
    const tag = @import("builtin").target.os.tag;
    const empty_caps: []const []const u8 = &.{}; // capability ids are passed by build.zig via addFileArg in a future iteration
    const m = parse.parseAtBuildFromPaths(gpa, io, base_path, override_paths, empty_caps, tag, .Debug, &diag) catch |e| {
        for (diag.items.items) |d| std.debug.print("manifest: {s}{s}{s}\n", .{
            d.message,
            if (d.path != null) " at " else "",
            if (d.path) |p| p else "",
        });
        return e;
    };
    defer parse.freeManifest(gpa, m);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.zon.stringify.serialize(m, .{}, &aw.writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = aw.writer.buffered() });
}
