const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    if (target.result.os.tag != .macos) {
        std.debug.print("zigware PoC targets macOS only\n", .{});
    }

    // The objc helper exposed as a named module so files rooted as standalone
    // logic-test modules (e.g. src/platform/macos/origin.zig) can import it
    // without a relative path that would escape their module root.
    const objc_mod = b.createModule(.{
        .root_source_file = b.path("src/objc.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("objc", objc_mod);
    exe_mod.linkFramework("Cocoa", .{});
    exe_mod.linkFramework("WebKit", .{});
    // Embedded frontend assets live outside src/ (the package root), so expose
    // them as anonymous imports that @embedFile can reference by name.
    exe_mod.addAnonymousImport("frontend/index.html", .{ .root_source_file = b.path("frontend/index.html") });
    exe_mod.addAnonymousImport("frontend/app.js", .{ .root_source_file = b.path("frontend/app.js") });
    exe_mod.addAnonymousImport("frontend/zigware.js", .{ .root_source_file = b.path("frontend/zigware.js") });
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
    addLogicTest(b, test_step, target, optimize, "src/command_ctx.zig");
    addLogicTest(b, test_step, target, optimize, "src/commands/sha256.zig");
    addLogicTest(b, test_step, target, optimize, "src/commands/demo.zig");
    addLogicTest(b, test_step, target, optimize, "src/jobs.zig");
    addLogicTest(b, test_step, target, optimize, "src/registry.zig");
    addLogicTest(b, test_step, target, optimize, "src/bridge.zig");
    addLogicTest(b, test_step, target, optimize, "src/platform/backend.zig");
    addLogicTest(b, test_step, target, optimize, "src/platform/null.zig");
    addLogicTest(b, test_step, target, optimize, "src/platform/macos/scheme_logic.zig");
    addLogicTest(b, test_step, target, optimize, "src/manifest/types.zig");
    addLogicTest(b, test_step, target, optimize, "src/security_tests.zig");

    // origin.zig imports the `objc` module; wire it on the standalone test.
    {
        const m = b.createModule(.{
            .root_source_file = b.path("src/platform/macos/origin.zig"),
            .target = target,
            .optimize = optimize,
        });
        m.addImport("objc", objc_mod);
        const tt = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(tt).step);
    }

    // Logic test that needs the embedded frontend assets (assets.zig, app.zig).
    const addEmbedTest = struct {
        fn add(bb: *std.Build, ts: *std.Build.Step, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, src: []const u8) void {
            const m = bb.createModule(.{
                .root_source_file = bb.path(src),
                .target = t,
                .optimize = o,
            });
            m.addAnonymousImport("frontend/index.html", .{ .root_source_file = bb.path("frontend/index.html") });
            m.addAnonymousImport("frontend/app.js", .{ .root_source_file = bb.path("frontend/app.js") });
            m.addAnonymousImport("frontend/zigware.js", .{ .root_source_file = bb.path("frontend/zigware.js") });
            const tt = bb.addTest(.{ .root_module = m });
            ts.dependOn(&bb.addRunArtifact(tt).step);
        }
    }.add;
    addEmbedTest(b, test_step, target, optimize, "src/assets.zig");
    addEmbedTest(b, test_step, target, optimize, "src/app.zig");
    addEmbedTest(b, test_step, target, optimize, "src/sec_regression.zig");

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

    const dts_mod = b.createModule(.{
        .root_source_file = b.path("src/emit_dts.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dts_exe = b.addExecutable(.{ .name = "emit_dts", .root_module = dts_mod });
    const dts_run = b.addRunArtifact(dts_exe);
    const dts_step = b.step("dts", "Generate frontend/bindings.d.ts");
    dts_step.dependOn(&dts_run.step);

    const scaffold_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    scaffold_mod.addImport("objc", objc_mod);
    scaffold_mod.linkFramework("Cocoa", .{});
    scaffold_mod.linkFramework("WebKit", .{});
    scaffold_mod.addAnonymousImport("frontend/index.html", .{ .root_source_file = b.path("frontend/index.html") });
    scaffold_mod.addAnonymousImport("frontend/app.js", .{ .root_source_file = b.path("frontend/app.js") });
    scaffold_mod.addAnonymousImport("frontend/zigware.js", .{ .root_source_file = b.path("frontend/zigware.js") });
    const scaffold_tests = b.addTest(.{ .root_module = scaffold_mod });
    test_step.dependOn(&b.addRunArtifact(scaffold_tests).step);

    // coverage-exe: the full headless logic surface. Rooted at app.zig, which
    // transitively imports bridge, null backend, assets, backend contract,
    // protocol, allowlist, jobs, and commands. The pure macOS helpers
    // (origin.zig, scheme_logic.zig) are pulled in by reference so their tests
    // run in this binary too and kcov reports their coverage; they are reached
    // only through the objc backend, which app.zig does not import, so without
    // the explicit reference below they would never appear in the report.
    // No Cocoa/WebKit needed.
    const cov_mod = b.createModule(.{
        .root_source_file = b.path("src/coverage_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    cov_mod.addAnonymousImport("frontend/index.html", .{ .root_source_file = b.path("frontend/index.html") });
    cov_mod.addAnonymousImport("frontend/app.js", .{ .root_source_file = b.path("frontend/app.js") });
    cov_mod.addAnonymousImport("frontend/zigware.js", .{ .root_source_file = b.path("frontend/zigware.js") });
    cov_mod.addImport("objc", objc_mod);
    const cov_tests = b.addTest(.{ .root_module = cov_mod, .name = "logic-tests" });
    const cov_install = b.addInstallArtifact(cov_tests, .{});
    const cov_step = b.step("coverage-exe", "Build the logic-tests binary for kcov");
    cov_step.dependOn(&cov_install.step);
}
