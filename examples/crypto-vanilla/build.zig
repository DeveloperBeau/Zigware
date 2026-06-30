const std = @import("std");
const zigware = @import("zigware");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // The framework. Pass only `.target`; the framework registers a bool
    // `-Drelease`, so forwarding `.optimize` would send a rejected `-Doptimize`.
    const dep = b.dependency("zigware", .{ .target = target });

    // The crypto Zig surface (command, barrel, entry, and the bridge integration
    // test) is shared by all four crypto examples from ../_shared. A module may
    // be rooted outside this build root as long as it imports only its siblings.
    _ = zigware.addApp(b, dep, .{
        .name = "crypto-vanilla",
        .manifest = b.path("zigware.zon"),
        .command_root = b.path("../_shared/commands.zig"),
        .main_root = b.path("../_shared/main.zig"),
        .integration_root = b.path("../_shared/integration_test.zig"),
        .frontend = .{
            .index_html = b.path("frontend/index.html"),
            .app_js = b.path("frontend/app.js"),
        },
        .target = target,
        .optimize = optimize,
    });
}
