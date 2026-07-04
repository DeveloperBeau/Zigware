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
const caps_loader = @import("capabilities.zig");

const log = diag.scoped("manifest");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) return error.MissingArgs;
    const out_path = args[1];
    const grants_out_path = args[2];
    const base_path = args[3];
    // args[4..] (per-OS overrides + capability files) are still passed by build.zig
    // so an edit invalidates the Run cache; the loaders below re-discover them by
    // walking the manifest's directory, so they need not be threaded individually.

    var diagnostics: types.Diagnostics = .{};
    defer diagnostics.deinit(gpa);
    // NOTE: target_os here is the codegen exe's compile target, which build.zig
    // sets equal to the build's user-selected target via standardTargetOptions.
    const tag = @import("builtin").target.os.tag;

    // Open the manifest's directory as the load root so per-OS overrides AND
    // capabilities (src/grants/*.zon) are enumerated and the
    // `security.grants` cross-check has the real present-set. Inputs are
    // pinned via addFileArg in build.zig, so the Run cache key stays stable.
    const root_path = std.fs.path.dirname(base_path) orelse ".";
    var root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |e| {
        log.err("cannot open manifest root", &.{diag.str("path", root_path)});
        return e;
    };
    defer root_dir.close(io);

    const m = parse.parseAtBuild(gpa, io, root_dir, tag, .Debug, &diagnostics) catch |e| {
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

    // Second artifact: the app's DECLARED capability bodies, filtered to the ids
    // the manifest references (security.grants), serialized so the runtime can
    // @import them the same way it imports the effective manifest. loadCapabilities
    // walks the same root dir; a missing src/grants yields an empty list, which
    // serializes to `.{}` and drives the runtime fallback.
    var caps_arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer caps_arena_state.deinit();
    const caps_arena = caps_arena_state.allocator();
    const loaded = caps_loader.loadCapabilities(caps_arena, io, root_dir) catch |e| {
        log.err("cannot load capability bodies", &.{diag.str("path", root_path)});
        return e;
    };
    var referenced: std.ArrayList(caps_loader.Capability) = .empty;
    for (loaded) |c| {
        for (m.security.grants) |id| {
            if (std.mem.eql(u8, c.identifier, id)) {
                try referenced.append(caps_arena, c);
                break;
            }
        }
    }
    var gaw: std.Io.Writer.Allocating = .init(gpa);
    defer gaw.deinit();
    try std.zon.stringify.serialize(referenced.items, .{}, &gaw.writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = grants_out_path, .data = gaw.writer.buffered() });
}
