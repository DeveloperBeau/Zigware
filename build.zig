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

    // The structured diagnostics logger exposed as a named module so files
    // rooted in other module roots (cli/*, manifest/*) can import it without a
    // relative path that would escape their own root.
    const diag_mod = b.createModule(.{
        .root_source_file = b.path("src/diag.zig"),
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
    // zigware.zon; the CLI never calls embedded(), so the placeholder suffices.
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
    // dev.zig/build.zig route their compiler-error stderr passthroughs through diag.
    cli_mod.addImport("diag", diag_mod);

    // The packaging module owns the canonical Artifacts/Arch handoff types and the
    // package() pipeline the build verb hands off to. It is its own module so the
    // CLI imports it as `package` (a cross-module import; a bare path import would
    // escape the cli module root). Its config leaf reaches the manifest through the
    // same `zigware_manifest` name.
    const package_mod = b.createModule(.{
        .root_source_file = b.path("src/package/packager.zig"),
        .target = target,
        .optimize = optimize,
    });
    package_mod.addImport("zigware_manifest", manifest_mod);
    cli_mod.addImport("package", package_mod);

    // ─── Scaffold template embeds ────────────────────────────────────────────
    //
    // `init.zig` writes a scaffold from bytes baked into the CLI exe. The bytes
    // come from @embedFile("template/<rel>") names that must be registered as
    // anonymous imports. Walk src/cli/template/ recursively at configure time and
    // register every file under its repo-relative name, so adding a new template
    // subtree (Wave B) needs NO edit here. The same walk emits a generated
    // template_index.zig listing each template's files grouped by first path
    // segment, which init.zig switches on (since @embedFile names must be comptime
    // literals, init picks among comptime-known blobs rather than enumerating at
    // runtime). wireTemplateEmbeds applies the same registration to any module
    // that resolves those embeds: cli_mod, the generated index module (its own
    // @embedFile literals resolve against its OWN import table), and the
    // init.zig test module.
    const template_files = walkTemplateTree(b);
    const template_index = emitTemplateIndex(b, template_files);
    const template_index_mod = b.createModule(.{
        .root_source_file = template_index,
        .target = target,
        .optimize = optimize,
    });
    registerTemplateEmbeds(b, template_index_mod, template_files);
    wireTemplateEmbeds(b, cli_mod, template_files, template_index_mod);

    const cli_exe = b.addExecutable(.{ .name = "zigware", .root_module = cli_mod });
    b.installArtifact(cli_exe);
    // Short alias: same CLI module, installed as `zw` for ergonomic invocation.
    const zw_exe = b.addExecutable(.{ .name = "zw", .root_module = cli_mod });
    b.installArtifact(zw_exe);
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

    // Manifest-aware logic-test registrar: mirrors addLogicTest plus the one addImport
    // that resolves @import("zigware_manifest").Manifest in the test module. Used by the
    // CLI leaves that consume D's parsed manifest type (csp.zig now; dev/build in A3).
    const addLogicTestWithManifest = struct {
        fn add(bb: *std.Build, ts: *std.Build.Step, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, mm: *std.Build.Module, dm: *std.Build.Module, src: []const u8) void {
            const m = bb.createModule(.{
                .root_source_file = bb.path(src),
                .target = t,
                .optimize = o,
            });
            m.addImport("zigware_manifest", mm);
            // dev.zig routes compiler-error stderr through diag; csp.zig leaves it unused (harmless).
            m.addImport("diag", dm);
            const tt = bb.addTest(.{ .root_module = m });
            ts.dependOn(&bb.addRunArtifact(tt).step);
        }
    }.add;

    // Manifest+package-aware registrar: cli/build.zig re-exports package.Artifacts and
    // cli/main.zig invokes package() through the build verb, so their TEST roots resolve
    // @import("package") in addition to @import("zigware_manifest"). The product cli_mod
    // gets package via addImport at line 78; these standalone test modules need it wired
    // here too or the test binary fails to compile.
    const addLogicTestWithManifestAndPackage = struct {
        fn add(bb: *std.Build, ts: *std.Build.Step, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, mm: *std.Build.Module, pm: *std.Build.Module, dm: *std.Build.Module, src: []const u8) *std.Build.Step.Run {
            const m = bb.createModule(.{
                .root_source_file = bb.path(src),
                .target = t,
                .optimize = o,
            });
            m.addImport("zigware_manifest", mm);
            m.addImport("package", pm);
            // build.zig routes compiler-error stderr through diag.
            m.addImport("diag", dm);
            const tt = bb.addTest(.{ .root_module = m });
            const run = bb.addRunArtifact(tt);
            ts.dependOn(&run.step);
            return run;
        }
    }.add;

    // Template-aware logic-test registrar: mirrors addLogicTest plus the template/**
    // anonymous imports the CLI module receives AND the generated template_index
    // module, so init.zig's per-leaf TEST root can resolve the @embedFile("template/...")
    // literals and @import("template_index") that C4's init.run tests exercise. The
    // plain addLogicTest builds a zero-import module that cannot resolve those.
    const addLogicTestWithTemplates = struct {
        fn add(bb: *std.Build, ts: *std.Build.Step, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, files: []const []const u8, idx: *std.Build.Module, mm: *std.Build.Module, pm: *std.Build.Module, dm: *std.Build.Module, src: []const u8) *std.Build.Step.Run {
            const m = bb.createModule(.{
                .root_source_file = bb.path(src),
                .target = t,
                .optimize = o,
            });
            wireTemplateEmbeds(bb, m, files, idx);
            m.addImport("zigware_manifest", mm); // init.zig's tests parse the scaffolded zigware.zon via D's reader
            m.addImport("package", pm); // main.zig's build verb invokes package(); init ignores the unused import
            m.addImport("diag", dm); // main.zig pulls in dev/build, which route stderr through diag
            const tt = bb.addTest(.{ .root_module = m });
            const run = bb.addRunArtifact(tt);
            ts.dependOn(&run.step);
            return run;
        }
    }.add;

    addLogicTest(b, test_step, target, optimize, "src/protocol.zig");
    addLogicTest(b, test_step, target, optimize, "src/allowlist.zig");
    addLogicTest(b, test_step, target, optimize, "src/command_ctx.zig");
    // sha256.zig/demo.zig import ../compute.zig; rooting their tests at the
    // src/-level aggregator keeps that import inside the module root (a standalone
    // src/commands/*.zig root dir would make ../compute.zig escape).
    addLogicTest(b, test_step, target, optimize, "src/sha256_tests.zig");
    addLogicTest(b, test_step, target, optimize, "src/jobs.zig");
    addLogicTest(b, test_step, target, optimize, "src/registry.zig");
    addLogicTest(b, test_step, target, optimize, "src/platform/backend.zig");
    addLogicTest(b, test_step, target, optimize, "src/platform/null.zig");
    addLogicTest(b, test_step, target, optimize, "src/platform/macos/scheme_logic.zig");
    addLogicTest(b, test_step, target, optimize, "src/manifest/types.zig");
    addLogicTest(b, test_step, target, optimize, "src/security_tests.zig");
    // diag.zig is std-only; its tests run in BOTH modes (the build-gating path
    // diverges only under -Drelease=true).
    addLogicTest(b, test_step, target, optimize, "src/diag_tests.zig");

    // CLI leaf stubs (std-only leaves via the plain registrar; csp via the manifest-aware one).
    addLogicTest(b, test_step, target, optimize, "src/cli/proc.zig");
    addLogicTest(b, test_step, target, optimize, "src/cli/watch.zig");
    addLogicTest(b, test_step, target, optimize, "src/cli/devserver.zig");
    addLogicTest(b, test_step, target, optimize, "src/cli/assets_embed.zig");
    addLogicTestWithManifest(b, test_step, target, optimize, manifest_mod, diag_mod, "src/cli/csp.zig");
    addLogicTestWithManifest(b, test_step, target, optimize, manifest_mod, diag_mod, "src/cli/dev.zig");
    const build_test_run = addLogicTestWithManifestAndPackage(b, test_step, target, optimize, manifest_mod, package_mod, diag_mod, "src/cli/build.zig");
    const test_build_step = b.step("test-build", "Run only the CLI build-orchestrator tests");
    test_build_step.dependOn(&build_test_run.step);
    addLogicTestWithManifest(b, test_step, target, optimize, manifest_mod, diag_mod, "src/package_tests.zig");
    // init.zig reads the template embeds + the generated template_index module; the
    // template-aware registrar wires both onto its test root so C4's init.run tests
    // can resolve the anonymous template imports.
    const init_test_run = addLogicTestWithTemplates(b, test_step, target, optimize, template_files, template_index_mod, manifest_mod, package_mod, diag_mod, "src/cli/init.zig");
    // Isolated step so init.zig's fake-driven scaffolding tests can run without the
    // App-based suites that hang on some hosts.
    const test_init_step = b.step("test-init", "Run only the CLI init scaffolding tests");
    test_init_step.dependOn(&init_test_run.step);

    // main.zig wires the verbs together: it imports init.zig (template embeds +
    // template_index) and the manifest module, so its test root needs the same
    // template-aware wiring as init. Its fake-free tests (exitCodeFor / SIGINT) run
    // without any App-based suite, so they get an isolated step too.
    const main_test_run = addLogicTestWithTemplates(b, test_step, target, optimize, template_files, template_index_mod, manifest_mod, package_mod, diag_mod, "src/cli/main.zig");
    const test_main_step = b.step("test-main", "Run only the CLI main-wiring tests");
    test_main_step.dependOn(&main_test_run.step);

    // Isolated manifest-only test step: runs the manifest module tests
    // (parse/validate/merge/capabilities/schema_gen/fuses via src/manifest_tests.zig,
    // the embed-agreement test, the fuses comptime-lock test) without the
    // App-based GUI suites that hang on this host. Task 3 appends the grant
    // enforcement test to this step.
    const test_manifest_step = b.step("test-manifest", "Run only the manifest module tests");

    // Isolated CLI-verb test step: runs the cli/dev.zig and cli/build.zig manifest
    // readers' tests in their own binaries so the dev/build assertions execute
    // without the App suites. Mirrors the addLogicTestWithManifest wiring.
    const test_cli_step = b.step("test-cli", "Run only the CLI dev/build verb tests");
    {
        const dm = b.createModule(.{ .root_source_file = b.path("src/cli/dev.zig"), .target = target, .optimize = optimize });
        dm.addImport("zigware_manifest", manifest_mod);
        dm.addImport("diag", diag_mod);
        test_cli_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = dm })).step);

        const bm = b.createModule(.{ .root_source_file = b.path("src/cli/build.zig"), .target = target, .optimize = optimize });
        bm.addImport("zigware_manifest", manifest_mod);
        bm.addImport("package", package_mod);
        bm.addImport("diag", diag_mod);
        test_cli_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bm })).step);
    }

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
    // src/bridge.zig and src/window_tests.zig build a WindowManager (E), and
    // manager.zig now imports manifest/fuses.zig (the allow_eval gate), which
    // resolves @import("zigware_manifest_zon"). They therefore need wireManifest
    // in addition to the frontend embeds, so they are registered via
    // addEmbedManifestTest after effective_zon is defined (see below).
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
    // emit_effective.zig routes its manifest-diagnostic prints through diag.
    emit_eff_mod.addImport("diag", diag_mod);

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
    // Targeted runners for the App/security suites (the full `test` step can hang
    // on unrelated long-running suites; these isolate the wiring under change).
    const test_app_step = b.step("test-app", "Run only the src/app.zig tests");
    addEmbedManifestTest(b, test_app_step, target, optimize, effective_zon, "src/app.zig");
    const test_sec_step = b.step("test-sec", "Run only the src/sec_regression.zig tests");
    addEmbedManifestTest(b, test_sec_step, target, optimize, effective_zon, "src/sec_regression.zig");

    // ─── In-repo example: examples/notes/ ────────────────────────────────────
    //
    // The example links the REAL framework through the src/zigware.zig barrel
    // (exposed as the named module `zigware`). The barrel is rooted in src/ so
    // every framework file resolves its src/-relative imports; the example's own
    // sources sit in examples/notes/src/ and reach the framework only by that
    // name. The framework barrel module pulls in app.zig (-> manager -> fuses ->
    // manifest) and assets.zig, so it needs the production frontend embeds + the
    // effective manifest wired exactly as the app test root does. MacOSBackend
    // pulls in objc + Cocoa/WebKit.
    //
    // makeZigwareModule builds one fresh barrel instance per consumer (a Build
    // Module cannot be shared across two root modules with different link
    // settings), wiring the objc import, frameworks, frontend embeds, and
    // manifest each time.
    const makeZigwareModule = struct {
        fn make(bb: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, om: *std.Build.Module, zon: std.Build.LazyPath) *std.Build.Module {
            const m = bb.createModule(.{
                .root_source_file = bb.path("src/zigware.zig"),
                .target = t,
                .optimize = o,
                .link_libc = true,
            });
            m.addImport("objc", om);
            m.linkFramework("Cocoa", .{});
            m.linkFramework("WebKit", .{});
            m.addAnonymousImport("frontend/index.html", .{ .root_source_file = bb.path("frontend/index.html") });
            m.addAnonymousImport("frontend/app.js", .{ .root_source_file = bb.path("frontend/app.js") });
            m.addAnonymousImport("frontend/zigware.js", .{ .root_source_file = bb.path("frontend/zigware.js") });
            m.addAnonymousImport("frontend/window.js", .{ .root_source_file = bb.path("frontend/window.js") });
            wireManifest(m, zon);
            return m;
        }
    }.make;

    // Public package surface for EXTERNAL consumers (a scaffolded app declares
    // `zigware` as a dependency and consumes this module). Same wiring as
    // makeZigwareModule, but the per-app manifest is left to the consumer: after
    // running the emit_effective_manifest exe over their own zigware.zon they add
    // the `zigware_manifest_zon` anonymous import onto this module (that is what
    // parse.embedded() resolves). The framework's own self-build never consumes
    // this instance (it uses makeZigwareModule), so its missing manifest is inert.
    const public_zigware = b.addModule("zigware", .{
        .root_source_file = b.path("src/zigware.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    public_zigware.addImport("objc", objc_mod);
    public_zigware.linkFramework("Cocoa", .{});
    public_zigware.linkFramework("WebKit", .{});
    public_zigware.addAnonymousImport("frontend/index.html", .{ .root_source_file = b.path("frontend/index.html") });
    public_zigware.addAnonymousImport("frontend/app.js", .{ .root_source_file = b.path("frontend/app.js") });
    public_zigware.addAnonymousImport("frontend/zigware.js", .{ .root_source_file = b.path("frontend/zigware.js") });
    public_zigware.addAnonymousImport("frontend/window.js", .{ .root_source_file = b.path("frontend/window.js") });

    // Expose the manifest codegen exe so consumers run it via
    // dep.artifact("emit_effective_manifest") to merge+validate their zigware.zon.
    b.installArtifact(emit_eff_exe);

    // The example executable. Rooted at examples/notes/src/main.zig, it builds an
    // App(MacOSBackend) from the manifest and runs the platform loop. The notes
    // frontend is embedded as anonymous imports (served from the regenerated asset
    // table on the packaged path; the in-repo exe links the framework's default
    // asset table, Locked decision 5).
    const notes_mod = b.createModule(.{
        .root_source_file = b.path("examples/notes/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    notes_mod.addImport("zigware", makeZigwareModule(b, target, optimize, objc_mod, effective_zon));
    notes_mod.linkFramework("Cocoa", .{});
    notes_mod.linkFramework("WebKit", .{});
    notes_mod.addAnonymousImport("examples/notes/frontend/index.html", .{ .root_source_file = b.path("examples/notes/frontend/index.html") });
    notes_mod.addAnonymousImport("examples/notes/frontend/app.js", .{ .root_source_file = b.path("examples/notes/frontend/app.js") });
    notes_mod.addAnonymousImport("examples/notes/frontend/style.css", .{ .root_source_file = b.path("examples/notes/frontend/style.css") });
    const notes_exe = b.addExecutable(.{ .name = "notes", .root_module = notes_mod });
    b.getInstallStep().dependOn(&b.addInstallArtifact(notes_exe, .{ .dest_sub_path = "notes-example" }).step);

    // The example's headless integration test: drives the real hashFile handler
    // over a Bridge(NullBackend) through the secure-default scope path. It imports
    // the framework barrel by name and the example handler by relative path (both
    // inside examples/notes/src/). It needs the example manifest on disk (read at
    // test time by D's loader), not embedded, so no per-example effective manifest.
    const notes_test_mod = b.createModule(.{
        .root_source_file = b.path("examples/notes/src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    notes_test_mod.addImport("zigware", makeZigwareModule(b, target, optimize, objc_mod, effective_zon));
    notes_test_mod.linkFramework("Cocoa", .{});
    notes_test_mod.linkFramework("WebKit", .{});
    const notes_tests = b.addTest(.{ .root_module = notes_test_mod });
    test_step.dependOn(&b.addRunArtifact(notes_tests).step);
    const test_notes_step = b.step("test-notes", "Run only the notes example integration tests");
    test_notes_step.dependOn(&b.addRunArtifact(notes_tests).step);

    // ─── In-repo example: examples/crypto-*/ ─────────────────────────────────
    //
    // The crypto round-trip demo ships as four scaffolds (vanilla/react/vue/
    // svelte) that share ONE command: src/commands/crypto.zig derives a key as
    // SHA-256(password) and runs a ChaCha20-Poly1305 encrypt/decrypt over the
    // per-call arena. The command is a pure function, so its proof is a headless
    // unit test rooted at the command file; no window or backend needed. The
    // four variants carry byte-identical command files (only their frontends
    // differ), so testing the vanilla copy covers all four. Rooted against the
    // real framework barrel (same `zigware` module the shipping app links) so the
    // test exercises the production Ctx/Result types, not the vendored stubs.
    const crypto_test_mod = b.createModule(.{
        .root_source_file = b.path("examples/crypto-vanilla/src/commands/crypto.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    crypto_test_mod.addImport("zigware", makeZigwareModule(b, target, optimize, objc_mod, effective_zon));
    crypto_test_mod.linkFramework("Cocoa", .{});
    crypto_test_mod.linkFramework("WebKit", .{});
    const crypto_tests = b.addTest(.{ .root_module = crypto_test_mod });
    test_step.dependOn(&b.addRunArtifact(crypto_tests).step);
    const test_crypto_step = b.step("test-crypto", "Run only the crypto example round-trip tests");
    test_crypto_step.dependOn(&b.addRunArtifact(crypto_tests).step);

    // The crypto example's headless bridge integration test: drives the real
    // cryptoDemo handler over a Bridge(NullBackend) through the gate + dispatch +
    // JSON-encode path, the same surface a window would use. Rooted at the
    // example's integration_test.zig, which imports the framework barrel by name
    // and the command by relative path (both inside examples/crypto-vanilla/src/).
    const crypto_it_mod = b.createModule(.{
        .root_source_file = b.path("examples/crypto-vanilla/src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    crypto_it_mod.addImport("zigware", makeZigwareModule(b, target, optimize, objc_mod, effective_zon));
    crypto_it_mod.linkFramework("Cocoa", .{});
    crypto_it_mod.linkFramework("WebKit", .{});
    const crypto_it_tests = b.addTest(.{ .root_module = crypto_it_mod });
    test_step.dependOn(&b.addRunArtifact(crypto_it_tests).step);
    test_crypto_step.dependOn(&b.addRunArtifact(crypto_it_tests).step);

    // The runnable crypto-vanilla window. Rooted at the example's src/main.zig, it
    // builds an App(MacOSBackend) that registers + grants the app's cryptoDemo
    // command and opens the window. The asset table serves the app:// frontend
    // from the embeds named `frontend/*`, so this barrel instance OVERRIDES the
    // index.html + app.js embeds with the example's own (the runtime shim
    // zigware.js/window.js stay the framework's). That makes the window load the
    // crypto UI, whose button invokes cryptoDemo over the bridge.
    const crypto_zig_mod = b.createModule(.{
        .root_source_file = b.path("src/zigware.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    crypto_zig_mod.addImport("objc", objc_mod);
    crypto_zig_mod.linkFramework("Cocoa", .{});
    crypto_zig_mod.linkFramework("WebKit", .{});
    crypto_zig_mod.addAnonymousImport("frontend/index.html", .{ .root_source_file = b.path("examples/crypto-vanilla/frontend/index.html") });
    crypto_zig_mod.addAnonymousImport("frontend/app.js", .{ .root_source_file = b.path("examples/crypto-vanilla/frontend/app.js") });
    crypto_zig_mod.addAnonymousImport("frontend/zigware.js", .{ .root_source_file = b.path("frontend/zigware.js") });
    crypto_zig_mod.addAnonymousImport("frontend/window.js", .{ .root_source_file = b.path("frontend/window.js") });
    // The exe embeds the example's own manifest (title + show=true) rather than
    // the framework default, so the window appears at launch with the right title.
    const crypto_eff_run = b.addRunArtifact(emit_eff_exe);
    const crypto_effective_zon: std.Build.LazyPath = crypto_eff_run.addOutputFileArg("crypto.effective.zon");
    crypto_eff_run.addFileArg(b.path("examples/crypto-vanilla/zigware.embed.zon"));
    wireManifest(crypto_zig_mod, crypto_effective_zon);

    const crypto_app_mod = b.createModule(.{
        .root_source_file = b.path("examples/crypto-vanilla/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    crypto_app_mod.addImport("zigware", crypto_zig_mod);
    crypto_app_mod.linkFramework("Cocoa", .{});
    crypto_app_mod.linkFramework("WebKit", .{});
    const crypto_app_exe = b.addExecutable(.{ .name = "crypto-vanilla", .root_module = crypto_app_mod });
    b.getInstallStep().dependOn(&b.addInstallArtifact(crypto_app_exe, .{ .dest_sub_path = "crypto-vanilla-example" }).step);
    const run_crypto_step = b.step("run-crypto", "Build and run the crypto-vanilla example window");
    run_crypto_step.dependOn(&b.addRunArtifact(crypto_app_exe).step);

    // The Vite-frontend crypto variants (react/vue/svelte) build the SAME way as
    // crypto-vanilla, except a Node/npm step first bundles the frontend into a
    // single external app.js + index.html (the asset table's two own-origin
    // slots). The script stays external ('self', strict CSP); styles are inline.
    // These exes are NOT in the default install (so `zig build` stays Node-free);
    // each is built+run only by its `run-crypto-<fw>` step.
    const addViteExample = struct {
        fn add(
            bb: *std.Build,
            t: std.Build.ResolvedTarget,
            o: std.builtin.OptimizeMode,
            om: *std.Build.Module,
            ee_exe: *std.Build.Step.Compile,
            fw: []const u8,
        ) void {
            const dir = bb.fmt("examples/crypto-{s}", .{fw});
            // Bundle the frontend. has_side_effects so the step always runs (it
            // writes dist/); ordered before the exe compile that embeds dist/*.
            const npm = bb.addSystemCommand(&.{ "sh", "-c", "npm install --no-audit --no-fund --silent && npm run build" });
            npm.setCwd(bb.path(dir));
            npm.has_side_effects = true;

            const zmod = bb.createModule(.{
                .root_source_file = bb.path("src/zigware.zig"),
                .target = t,
                .optimize = o,
                .link_libc = true,
            });
            zmod.addImport("objc", om);
            zmod.linkFramework("Cocoa", .{});
            zmod.linkFramework("WebKit", .{});
            zmod.addAnonymousImport("frontend/index.html", .{ .root_source_file = bb.path(bb.fmt("{s}/dist/index.html", .{dir})) });
            zmod.addAnonymousImport("frontend/app.js", .{ .root_source_file = bb.path(bb.fmt("{s}/dist/app.js", .{dir})) });
            zmod.addAnonymousImport("frontend/zigware.js", .{ .root_source_file = bb.path("frontend/zigware.js") });
            zmod.addAnonymousImport("frontend/window.js", .{ .root_source_file = bb.path("frontend/window.js") });
            const eff = bb.addRunArtifact(ee_exe);
            const eff_out = eff.addOutputFileArg(bb.fmt("{s}.effective.zon", .{fw}));
            eff.addFileArg(bb.path(bb.fmt("{s}/zigware.embed.zon", .{dir})));
            wireManifest(zmod, eff_out);

            const amod = bb.createModule(.{
                .root_source_file = bb.path(bb.fmt("{s}/src/main.zig", .{dir})),
                .target = t,
                .optimize = o,
                .link_libc = true,
            });
            amod.addImport("zigware", zmod);
            amod.linkFramework("Cocoa", .{});
            amod.linkFramework("WebKit", .{});
            const app_exe = bb.addExecutable(.{ .name = bb.fmt("crypto-{s}", .{fw}), .root_module = amod });
            // The exe embeds dist/* (a plain path the build graph cannot see as
            // produced), so force the bundle to run before the compile.
            app_exe.step.dependOn(&npm.step);
            const run_art = bb.addRunArtifact(app_exe);
            const step = bb.step(bb.fmt("run-crypto-{s}", .{fw}), bb.fmt("Bundle (Vite) and run the crypto-{s} example window", .{fw}));
            step.dependOn(&run_art.step);
        }
    }.add;
    addViteExample(b, target, optimize, objc_mod, emit_eff_exe, "react");
    addViteExample(b, target, optimize, objc_mod, emit_eff_exe, "vue");
    addViteExample(b, target, optimize, objc_mod, emit_eff_exe, "svelte");
    // bridge.zig and window_tests.zig compile manager.zig, which imports
    // manifest/fuses.zig and so needs the effective manifest wired too.
    addEmbedManifestTest(b, test_step, target, optimize, effective_zon, "src/bridge.zig");
    addEmbedManifestTest(b, test_step, target, optimize, effective_zon, "src/window_tests.zig");
    // compute_tests.zig drives the real Bridge async offload path, so it pulls in
    // manager.zig (manifest fuses) and the frontend embeds like bridge.zig does.
    addEmbedManifestTest(b, test_step, target, optimize, effective_zon, "src/compute_tests.zig");

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
    const mt_run = b.addRunArtifact(mt_tests);
    test_step.dependOn(&mt_run.step);
    test_manifest_step.dependOn(&mt_run.step);

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
    const embed_run = b.addRunArtifact(embed_tests);
    test_step.dependOn(&embed_run.step);
    test_manifest_step.dependOn(&embed_run.step);

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
    const fuses_run = b.addRunArtifact(fuses_tests);
    test_step.dependOn(&fuses_run.step);
    test_manifest_step.dependOn(&fuses_run.step);

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

const template_root = "src/cli/template";

/// Recursively walk src/cli/template/ at configure time and return every file's
/// path relative to that root (forward-slash separated, sorted for determinism).
/// Uses Dir.walk (recursive, NOT a one-level iterate), so nested template
/// subtrees (frontend/, src/commands/, _shared/) are all registered without a
/// per-template build.zig edit. Returns an empty slice if the dir is absent.
fn walkTemplateTree(b: *std.Build) []const []const u8 {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, template_root, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var list: std.ArrayList([]const u8) = .empty;
    var walker = dir.walk(b.allocator) catch @panic("OOM walking template tree");
    defer walker.deinit();
    while (walker.next(io) catch @panic("error walking template tree")) |entry| {
        if (entry.kind != .file) continue;
        // entry.path aliases the walker's name_buffer (invalidated on next()), so
        // dupe immediately. Normalise to forward slashes for the embed name.
        const rel = b.dupe(entry.path);
        std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
        list.append(b.allocator, rel) catch @panic("OOM");
    }
    const files = list.toOwnedSlice(b.allocator) catch @panic("OOM");
    std.mem.sort([]const u8, files, {}, struct {
        fn lt(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lt);
    return files;
}

/// addAnonymousImport each template file under its repo-relative "template/<rel>"
/// name, so @embedFile("template/<rel>") resolves against this module.
fn registerTemplateEmbeds(b: *std.Build, mod: *std.Build.Module, files: []const []const u8) void {
    for (files) |rel| {
        const name = b.fmt("template/{s}", .{rel});
        const src = b.fmt("{s}/{s}", .{ template_root, rel });
        mod.addAnonymousImport(name, .{ .root_source_file = b.path(src) });
    }
}

/// Wire BOTH the template embeds and the generated template_index module onto a
/// module. Shared by cli_mod and the init.zig test root so the wiring stays
/// single-sourced.
fn wireTemplateEmbeds(b: *std.Build, mod: *std.Build.Module, files: []const []const u8, index_mod: *std.Build.Module) void {
    registerTemplateEmbeds(b, mod, files);
    mod.addImport("template_index", index_mod);
}

/// Emit a generated template_index.zig: each template's files grouped by first
/// path segment, listed as @embedFile("template/<rel>") literals (names must be
/// comptime, so init picks among comptime-known blobs). `shared` holds the
/// _shared/* payload init writes for every template; `filesFor` returns the
/// framework-specific files for a template name.
fn emitTemplateIndex(b: *std.Build, files: []const []const u8) std.Build.LazyPath {
    var src: std.ArrayList(u8) = .empty;
    const gpa = b.allocator;

    src.appendSlice(gpa,
        \\// Generated by build.zig. Do not edit by hand.
        \\pub const File = struct { rel: []const u8, bytes: []const u8 };
        \\
        \\
    ) catch @panic("OOM");

    // Collect the distinct first path segments (sorted, deterministic).
    var segments: std.ArrayList([]const u8) = .empty;
    for (files) |rel| {
        const seg = rel[0 .. std.mem.indexOfScalar(u8, rel, '/') orelse rel.len];
        var seen = false;
        for (segments.items) |s| {
            if (std.mem.eql(u8, s, seg)) {
                seen = true;
                break;
            }
        }
        if (!seen) segments.append(gpa, seg) catch @panic("OOM");
    }

    // One `pub const <seg> = [_]File{...}` array per segment.
    for (segments.items) |seg| {
        const decl = if (std.mem.eql(u8, seg, "_shared")) "shared" else seg;
        src.print(gpa, "pub const {s} = [_]File{{\n", .{decl}) catch @panic("OOM");
        for (files) |rel| {
            const fseg = rel[0 .. std.mem.indexOfScalar(u8, rel, '/') orelse rel.len];
            if (!std.mem.eql(u8, fseg, seg)) continue;
            src.print(gpa, "    .{{ .rel = \"{s}\", .bytes = @embedFile(\"template/{s}\") }},\n", .{ rel, rel }) catch @panic("OOM");
        }
        src.appendSlice(gpa, "};\n\n") catch @panic("OOM");
    }

    // filesFor: framework-specific files for a template name (empty until the
    // per-template subtrees land in Wave B).
    src.appendSlice(gpa, "pub fn filesFor(name: []const u8) []const File {\n") catch @panic("OOM");
    for (segments.items) |seg| {
        if (std.mem.eql(u8, seg, "_shared")) continue;
        src.print(gpa, "    if (std.mem.eql(u8, name, \"{s}\")) return &{s};\n", .{ seg, seg }) catch @panic("OOM");
    }
    src.appendSlice(gpa, "    return &.{};\n}\n\nconst std = @import(\"std\");\n") catch @panic("OOM");

    const bytes = src.toOwnedSlice(gpa) catch @panic("OOM");
    return b.addWriteFiles().add("template_index.zig", bytes);
}
