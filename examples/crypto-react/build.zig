const std = @import("std");
const zigware = @import("zigware");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const dep = b.dependency("zigware", .{ .target = target });

    // The frontend embeds are the app:// fallback. In dev the app loads from
    // serveUrl (vite); production `zigware build` stages the vite dist via
    // -Dasset_table. index.html (the vite root entry) and main.jsx (the JS
    // entry) only need to be embeddable here.
    _ = zigware.addApp(b, dep, .{
        .name = "crypto-react",
        .manifest = b.path("zigware.zon"),
        .command_root = b.path("../_shared/commands.zig"),
        .main_root = b.path("../_shared/main.zig"),
        .integration_root = b.path("../_shared/integration_test.zig"),
        .frontend = .{
            .index_html = b.path("index.html"),
            .app_js = b.path("frontend/main.jsx"),
        },
        .target = target,
        .optimize = optimize,
    });
}
