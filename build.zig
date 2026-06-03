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
    exe_mod.addAnonymousImport("frontend/window.js", .{ .root_source_file = b.path("frontend/window.js") });
    const exe = b.addExecutable(.{ .name = "zigware", .root_module = exe_mod });
    // The CLI exe (added below) keeps the `zigware` name; the app installs under
    // a distinct sub-path so exactly one artifact lands at zig-out/bin/zigware.
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{ .dest_sub_path = "zigware-app" }).step);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run zigware");
    run_step.dependOn(&run_cmd.step);

    // --- zigware CLI (no Cocoa/WebKit; shells out to `zig build`) ---
    // The CLI needs D's *parser* (it reads the END-USER's zigware.zon at runtime),
    // not just the Manifest type. parse.zig/types.zig/validate.zig/merge.zig
    // cross-import BY PATH and must all live in ONE compilation, so root a
    // dedicated module at parse.zig (it transitively pulls in its siblings by
    // path) and satisfy its `zigware_manifest_zon` anonymous import with the raw
    // zigware.zon — the CLI never calls embedded(), so the placeholder suffices.
    const manifest_mod = b.createModule(.{
        .root_source_file = b.path("src/manifest/parse.zig"),
        .target = target,
        .optimize = optimize,
    });
    manifest_mod.addAnonymousImport("zigware_manifest_zon", .{
        .root_source_file = b.path("zigware.zon"),
    });
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Expose D's parser+type to the CLI leaves under the name `zigware_manifest`.
    cli_mod.addImport("zigware_manifest", manifest_mod);
    const cli_exe = b.addExecutable(.{ .name = "zigware", .root_module = cli_mod });
    b.installArtifact(cli_exe);
    const cli_run = b.addRunArtifact(cli_exe);
    if (b.args) |args| cli_run.addArgs(args);
    const cli_step = b.step("cli", "Run the zigware CLI");
    cli_step.dependOn(&cli_run.step);

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
            m.addAnonymousImport("frontend/window.js", .{ .root_source_file = bb.path("frontend/window.js") });
            const tt = bb.addTest(.{ .root_module = m });
            ts.dependOn(&bb.addRunArtifact(tt).step);
        }
    }.add;
    addEmbedTest(b, test_step, target, optimize, "src/assets.zig");
    // bridge.zig's TestBridge harness builds a WindowManager (E), which
    // @embedFiles the frontend JS; the test compilation needs those embeds.
    addEmbedTest(b, test_step, target, optimize, "src/bridge.zig");
    addEmbedTest(b, test_step, target, optimize, "src/window_tests.zig");
    // src/app.zig and src/sec_regression.zig both transitively compile
    // manifest/parse.zig (app.zig now calls parse.embedded()), so they need
    // wireManifest in addition to the frontend embeds; addEmbedTest exposes no
    // module handle, so they are registered explicitly after effective_zon is
    // defined (see the addEmbedManifestTest calls below the manifest wiring).

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

    // ─── Manifest module wiring ──────────────────────────────────────────────
    //
    // The build-time codegen reads zigware.zon (and any per-OS overrides), runs
    // the merge+validate pipeline, and emits a single .zon literal that every
    // CONSUMING module imports via @import("zigware_manifest_zon"). Production
    // embedded() therefore returns the merged+validated manifest, not the raw
    // source. The codegen exe itself is the one exception: it consumes the RAW
    // source because parse.zig declares embedded() and that @import resolves at
    // parse.zig COMPILATION time, which would otherwise be a chicken-and-egg.
    //
    // The codegen module is rooted directly at emit_effective.zig; parse.zig,
    // validate.zig, merge.zig, and types.zig are reached via file-path imports
    // and so become members of the same module. The plan's separate manifest_mod
    // / types_mod structure is incompatible with how those files cross-import
    // each other (e.g. parse.zig does `@import("types.zig")` by path), because
    // a file can only belong to one module per compilation.
    const emit_eff_mod = b.createModule(.{
        .root_source_file = b.path("src/manifest/emit_effective.zig"),
        .target = target,
        .optimize = optimize,
    });
    // parse.zig (a file member of emit_eff_mod via the codegen's relative
    // import) declares embedded() with @import("zigware_manifest_zon"), so the
    // anonymous import must be wired here. The codegen never CALLS embedded();
    // the wire only satisfies the compile-time @import resolution.
    emit_eff_mod.addAnonymousImport("zigware_manifest_zon", .{ .root_source_file = b.path("zigware.zon") });

    const emit_eff_exe = b.addExecutable(.{ .name = "emit_effective_manifest", .root_module = emit_eff_mod });
    const emit_eff_run = b.addRunArtifact(emit_eff_exe);
    // argv[1] = output path (materialised as a LazyPath downstream consumers can wire).
    const effective_zon: std.Build.LazyPath = emit_eff_run.addOutputFileArg("zigware.effective.zon");
    // argv[2] = base manifest path; pinned via addFileArg so an edit invalidates the cache.
    emit_eff_run.addFileArg(b.path("zigware.zon"));
    // argv[3..] = per-OS override paths; pin every existing one. build.zig's
    // configure-phase filesystem reads use b.build_root.handle + b.graph.io;
    // std.fs.cwd() is not in 0.16.
    const root = b.build_root.handle;
    const bio = b.graph.io;
    for ([_][]const u8{ "zigware.macos.zon", "zigware.linux.zon", "zigware.windows.zon" }) |name| {
        if (root.access(bio, name, .{})) {
            emit_eff_run.addFileArg(b.path(name));
        } else |_| {}
    }
    // Capability files (src/capabilities/*.zon) are read by parseAtBuild via
    // presence enumeration. Pin each one currently present so a change re-runs
    // the codegen. A missing dir means no files are added; the loader's
    // missing-dir branch yields an empty present-set.
    {
        var cap_dir = root.openDir(bio, "src/capabilities", .{ .iterate = true }) catch null;
        if (cap_dir) |*dir| {
            defer dir.close(bio);
            var it = dir.iterate();
            while (it.next(bio) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
                const sub = b.fmt("src/capabilities/{s}", .{entry.name});
                emit_eff_run.addFileArg(b.path(sub));
            }
        }
    }

    const emit_eff_step = b.step("emit-effective-manifest", "Emit the merged effective manifest .zon");
    emit_eff_step.dependOn(&emit_eff_run.step);

    // app.zig now imports manifest/parse.zig and calls parse.embedded(), so both
    // the production executable module and the app test module must resolve
    // @import("zigware_manifest_zon") to the MERGED+validated effective manifest
    // (NOT the raw zigware.zon the codegen exe consumes). exe_mod was created
    // near the top of build(); addExecutable captured it by reference, so wiring
    // the anonymous import here (after effective_zon exists) is in time.
    wireManifest(exe_mod, effective_zon);

    // src/app.zig and src/sec_regression.zig both need the frontend embeds AND
    // wireManifest (app.zig calls parse.embedded(); sec_regression imports App).
    // addEmbedTest exposes no module handle for wireManifest, so they are
    // registered explicitly here, after effective_zon is defined.
    const addEmbedManifestTest = struct {
        fn add(bb: *std.Build, ts: *std.Build.Step, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, zon: std.Build.LazyPath, src: []const u8) void {
            const m = bb.createModule(.{
                .root_source_file = bb.path(src),
                .target = t,
                .optimize = o,
            });
            m.addAnonymousImport("frontend/index.html", .{ .root_source_file = bb.path("frontend/index.html") });
            m.addAnonymousImport("frontend/app.js", .{ .root_source_file = bb.path("frontend/app.js") });
            m.addAnonymousImport("frontend/zigware.js", .{ .root_source_file = bb.path("frontend/zigware.js") });
            m.addAnonymousImport("frontend/window.js", .{ .root_source_file = bb.path("frontend/window.js") });
            wireManifest(m, zon);
            const tt = bb.addTest(.{ .root_module = m });
            ts.dependOn(&bb.addRunArtifact(tt).step);
        }
    }.add;
    addEmbedManifestTest(b, test_step, target, optimize, effective_zon, "src/app.zig");
    addEmbedManifestTest(b, test_step, target, optimize, effective_zon, "src/sec_regression.zig");

    // Manifest test root: src/manifest/*.zig files import each other and cannot
    // be rooted as standalone logic-test modules. The manifest test root mounts
    // them under one binary. addLogicTest is not usable here because parse.zig's
    // embedded() forces @import("zigware_manifest_zon") to resolve at compile
    // time of parse.zig; the module needs the anonymous import wired.
    const mt_mod = b.createModule(.{
        .root_source_file = b.path("src/manifest_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    wireManifest(mt_mod, effective_zon);
    const mt_tests = b.addTest(.{ .root_module = mt_mod });
    test_step.dependOn(&b.addRunArtifact(mt_tests).step);

    // Embed-agreement test: proves embedded() and parseAtBuild over the SAME
    // source bytes produce identical Manifest values. The fixture lives at
    // tests/manifest/embed_fixture/zigware.zon and is wired here as this
    // module's zigware_manifest_zon import so embedded() resolves to the
    // fixture, not the production effective manifest. parseAtBuild in turn
    // reads the fixture dir at test time. Identical bytes on both sides keeps
    // the comparison well-defined.
    const embed_test_mod = b.createModule(.{
        .root_source_file = b.path("src/manifest/embed_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    embed_test_mod.addAnonymousImport("zigware_manifest_zon", .{
        .root_source_file = b.path("tests/manifest/embed_fixture/zigware.zon"),
    });
    const embed_tests = b.addTest(.{ .root_module = embed_test_mod });
    test_step.dependOn(&b.addRunArtifact(embed_tests).step);

    // Fuse-constants module: thin re-export of the embedded fuses so the
    // bridge/command layer can prune disabled branches at comptime. Tested
    // both through the manifest test root (via src/manifest_tests.zig) and
    // through its own standalone test binary so the comptime-lock fires
    // even if the test root's import is removed in a refactor.
    const fuses_mod = b.createModule(.{
        .root_source_file = b.path("src/manifest/fuses.zig"),
        .target = target,
        .optimize = optimize,
    });
    wireManifest(fuses_mod, effective_zon);
    const fuses_tests = b.addTest(.{ .root_module = fuses_mod });
    test_step.dependOn(&b.addRunArtifact(fuses_tests).step);

    // JSON Schema emitter: produces zigware-manifest.schema.json at the repo
    // root for editor autocomplete. Reflection-driven; a new Manifest field
    // shows up in the schema on the next `zig build manifest-schema`.
    // schema_gen.zig reaches types via `@import("types.zig")` (file path), so
    // no module-level types import is needed here.
    const schema_mod = b.createModule(.{
        .root_source_file = b.path("src/manifest/schema_gen.zig"),
        .target = target,
        .optimize = optimize,
    });
    const schema_exe = b.addExecutable(.{ .name = "manifest_schema", .root_module = schema_mod });
    const schema_run = b.addRunArtifact(schema_exe);
    const schema_step = b.step("manifest-schema", "Generate zigware-manifest.schema.json");
    schema_step.dependOn(&schema_run.step);

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
    cov_mod.addAnonymousImport("frontend/window.js", .{ .root_source_file = b.path("frontend/window.js") });
    cov_mod.addImport("objc", objc_mod);
    wireManifest(cov_mod, effective_zon);
    const cov_tests = b.addTest(.{ .root_module = cov_mod, .name = "logic-tests" });
    const cov_install = b.addInstallArtifact(cov_tests, .{});
    const cov_step = b.step("coverage-exe", "Build the logic-tests binary for kcov");
    cov_step.dependOn(&cov_install.step);
}

/// Wires the build-time codegen output onto a module so `@import("zigware_manifest_zon")`
/// resolves to the merged+validated effective manifest at compile time. Every
/// module that transitively compiles src/manifest/parse.zig (except the codegen
/// exe itself) MUST have this called on it.
fn wireManifest(mod: *std.Build.Module, zon: std.Build.LazyPath) void {
    mod.addAnonymousImport("zigware_manifest_zon", .{ .root_source_file = zon });
}
