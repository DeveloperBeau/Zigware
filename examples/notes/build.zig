const std = @import("std");
const zigware = @import("zigware");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const dep = b.dependency("zigware", .{ .target = target });

    _ = zigware.addApp(b, dep, .{
        .name = "notes",
        .manifest = b.path("zigware.zon"),
        .command_root = b.path("src/commands.zig"),
        .main_root = b.path("src/main.zig"),
        .integration_root = b.path("src/integration_test.zig"),
        .frontend = .{
            .index_html = b.path("frontend/index.html"),
            .app_js = b.path("frontend/app.js"),
        },
        .target = target,
        .optimize = optimize,
    });
}
