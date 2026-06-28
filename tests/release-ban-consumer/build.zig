const std = @import("std");
const zigware = @import("zigware");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const dep = b.dependency("zigware", .{ .target = target, .optimize = .ReleaseFast });
    _ = zigware.addApp(b, dep, .{
        .name = "release-ban-consumer",
        .manifest = b.path("zigware.zon"),
        .command_root = b.path("src/commands.zig"),
        .main_root = b.path("src/main.zig"),
        .frontend = .{
            .index_html = b.path("frontend/index.html"),
            .app_js = b.path("frontend/app.js"),
        },
        .target = target,
        // Force ReleaseFast directly: a scaffold-shaped build.zig registers
        // -Drelease (bool), so -Doptimize=ReleaseFast is an unknown option and
        // never reaches the comptime ban. The mode must be set on the module.
        .optimize = .ReleaseFast,
    });
}
