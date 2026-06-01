const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag != .macos) {
        std.debug.print("zigware PoC targets macOS only\n", .{});
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.linkFramework("Cocoa", .{});
    exe_mod.linkFramework("WebKit", .{});
    // Embedded frontend assets live outside src/ (the package root), so expose
    // them as anonymous imports that @embedFile can reference by name.
    exe_mod.addAnonymousImport("frontend/index.html", .{ .root_source_file = b.path("frontend/index.html") });
    exe_mod.addAnonymousImport("frontend/app.js", .{ .root_source_file = b.path("frontend/app.js") });
    const exe = b.addExecutable(.{ .name = "zigware", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run zigware");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");

    // Helper closure to register a pure-logic test module (used by later tasks).
    const addLogicTest = struct {
        fn add(bb: *std.Build, ts: *std.Build.Step, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, src: []const u8) void {
            const m = bb.createModule(.{
                .root_source_file = bb.path(src),
                .target = t,
                .optimize = o,
            });
            const tt = bb.addTest(.{ .root_module = m });
            ts.dependOn(&bb.addRunArtifact(tt).step);
        }
    }.add;
    addLogicTest(b, test_step, target, optimize, "src/protocol.zig");
    addLogicTest(b, test_step, target, optimize, "src/allowlist.zig");
    addLogicTest(b, test_step, target, optimize, "src/commands/sha256.zig");
    addLogicTest(b, test_step, target, optimize, "src/commands/demo.zig");
    addLogicTest(b, test_step, target, optimize, "src/jobs.zig");
    addLogicTest(b, test_step, target, optimize, "src/bridge.zig");

    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fixture_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/emit_escapes.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixture_mod.addImport("protocol", protocol_mod);
    const fixture_exe = b.addExecutable(.{ .name = "emit_escapes", .root_module = fixture_mod });
    const fixture_run = b.addRunArtifact(fixture_exe);
    const escapes_step = b.step("escapes", "Emit test/fixtures/js_escapes.jsonl");
    escapes_step.dependOn(&fixture_run.step);

    const scaffold_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    scaffold_mod.linkFramework("Cocoa", .{});
    scaffold_mod.linkFramework("WebKit", .{});
    const scaffold_tests = b.addTest(.{ .root_module = scaffold_mod });
    test_step.dependOn(&b.addRunArtifact(scaffold_tests).step);

    // ── coverage-exe: standalone test binary for kcov wrapping ────────────────
    // Roots at bridge.zig which transitively imports protocol, allowlist, jobs,
    // commands — the full pure-Zig logic surface (no Cocoa/WebKit needed).
    const cov_mod = b.createModule(.{
        .root_source_file = b.path("src/bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cov_tests = b.addTest(.{ .root_module = cov_mod, .name = "logic-tests" });
    const cov_install = b.addInstallArtifact(cov_tests, .{});
    const cov_step = b.step("coverage-exe", "Build the logic-tests binary for kcov");
    cov_step.dependOn(&cov_install.step);
}
