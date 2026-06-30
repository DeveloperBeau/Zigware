const std = @import("std");
const zigware = @import("zigware");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // The framework. Pass only `.target`; forwarding `.optimize` would send a
    // rejected `-Doptimize` (the framework registers a bool `-Drelease`).
    const dep = b.dependency("zigware", .{ .target = target });

    // The frontend embeds are the app:// fallback. In dev the app loads from
    // serveUrl (vite); in production `zigware build` stages the vite dist and
    // passes it via -Dasset_table, which shadows these. So index.html (the vite
    // root entry) and main.jsx (the JS entry) only need to be embeddable here.
    _ = zigware.addApp(b, dep, .{
        .name = "{{name}}",
        .manifest = b.path("zigware.zon"),
        .command_root = b.path("src/commands.zig"),
        .main_root = b.path("src/main.zig"),
        .frontend = .{
            .index_html = b.path("index.html"),
            .app_js = b.path("frontend/main.jsx"),
        },
        .target = target,
        .optimize = optimize,
    });
}
