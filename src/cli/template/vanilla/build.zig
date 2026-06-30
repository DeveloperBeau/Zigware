const std = @import("std");
const zigware = @import("zigware");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // The framework. Pass only `.target`; the framework registers a bool
    // `-Drelease` (Zig 0.16 standardOptimizeOption), so forwarding `.optimize`
    // would send a rejected `-Doptimize`. The barrel compiles at this build's
    // optimize mode regardless.
    const dep = b.dependency("zigware", .{ .target = target });

    _ = zigware.addApp(b, dep, .{
        .name = "{{name}}",
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
