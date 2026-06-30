const std = @import("std");
const zigware = @import("zigware");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const dep = b.dependency("zigware", .{ .target = target });

    // The frontend embeds are the app:// fallback (see crypto-react). index.html
    // is the vite root entry; src/main.js is the JS entry.
    _ = zigware.addApp(b, dep, .{
        .name = "crypto-svelte",
        .manifest = b.path("zigware.zon"),
        .command_root = b.path("../_shared/commands.zig"),
        .main_root = b.path("../_shared/main.zig"),
        .integration_root = b.path("../_shared/integration_test.zig"),
        .frontend = .{
            .index_html = b.path("index.html"),
            .app_js = b.path("frontend/src/main.js"),
        },
        .target = target,
        .optimize = optimize,
    });
}
