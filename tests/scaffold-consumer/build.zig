const std = @import("std");
const zigware = @import("zigware");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const dep = b.dependency("zigware", .{ .target = target, .optimize = optimize });
    _ = zigware.addApp(b, dep, .{
        .name = "scaffold-consumer",
        .manifest = b.path("zigware.zon"),
        .command_root = b.path("src/commands.zig"),
        .main_root = b.path("src/main.zig"),
        .frontend = .{
            .index_html = b.path("frontend/index.html"),
            .app_js = b.path("frontend/app.js"),
        },
        .target = target,
        .optimize = optimize,
    });
}
