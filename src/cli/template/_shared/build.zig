const std = @import("std");

// A normal Zig project that consumes the Zigware framework as a package
// dependency (declared in build.zig.zon). `zig build` links the app; the
// framework is fetched/linked from the dependency, not vendored here.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // The framework. Pass only `.target` - the framework uses `-Drelease`
    // (Zig 0.16 standardOptimizeOption), so forwarding `.optimize` would send a
    // rejected `-Doptimize`. The consumed module compiles at this exe's optimize.
    const dep = b.dependency("zigware", .{ .target = target });

    // Merge + validate this app's manifest through the framework's codegen, then
    // wire the result onto the framework module (parse.embedded() resolves it).
    const eff = b.addRunArtifact(dep.artifact("emit_effective_manifest"));
    const effective = eff.addOutputFileArg("zigware.effective.zon");
    eff.addFileArg(b.path("zigware.zon"));

    const zigware_mod = dep.module("zigware");
    zigware_mod.addAnonymousImport("zigware_manifest_zon", .{ .root_source_file = effective });

    // Production frontend assets: `zigware build` stages a CSP-injected
    // asset_table.zig (colocated with the assets) and passes its path here; that
    // shadows the framework's default table. In dev the app loads from serveUrl, so
    // this option stays unset and the framework default is used.
    if (b.option([]const u8, "asset_table", "Path to a staged asset_table.zig (set by `zigware build`)")) |asset_table| {
        zigware_mod.addAnonymousImport("asset_table.zig", .{ .root_source_file = .{ .cwd_relative = asset_table } });
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zigware", zigware_mod);
    exe_mod.linkFramework("Cocoa", .{});
    exe_mod.linkFramework("WebKit", .{});

    const exe = b.addExecutable(.{ .name = "{{name}}", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
