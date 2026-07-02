const std = @import("std");

const helpers = @import("build_helpers.zig");
pub const AppOptions = helpers.AppOptions;
pub const FrontendEmbeds = helpers.FrontendEmbeds;
pub const addApp = helpers.addApp;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Consumers that call b.dependency("zigware", .{ .optimize = optimize }) pass
    // -Doptimize=<mode>. Accept it here alongside -Drelease so addApp-based
    // consumers can forward their own optimize mode to the dependency.
    const optimize_override = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (forwarded from consumer via .optimize =)");
    const optimize = optimize_override orelse b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

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

    // ─── Consumer package surface (runs for the root build AND for any
    // dependent that resolves b.dependency("zigware", ...)) ─────────────────────
    //
    // A dependent build executes this and then returns at the pkg_hash gate below,
    // so it never triggers the CLI, the in-repo examples, the npm bundles, the
    // grants walker, or the test-step registrations. The published tarball's
    // .paths excludes examples/ and tests/, so any stray self reference fails when
    // fetched. Gate on pkg_hash (root => "", dependency => non-empty) rather than a
    // -Dself option: an option defaults off, which would silently skip the
    // framework's own examples/tests unless every CI call passed -Dself=true.

    // Cocoa-free codegen module a consumer's dts/test builds root against.
    _ = b.addModule("zigware-headless", .{
        .root_source_file = b.path("src/zigware_codegen.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The merge+validate codegen exe. addApp runs it per consumer over the
    // consumer's zigware.zon. Rooted at emit_effective.zig; parse.zig/validate.zig/
    // merge.zig/types.zig join by file-path import. parse.zig declares embedded()
    // with @import("zigware_manifest_zon"), so the anonymous import must be wired
    // even though the codegen never CALLS embedded().
    const emit_eff_mod = b.createModule(.{
        .root_source_file = b.path("src/manifest/emit_effective.zig"),
        .target = target,
        .optimize = optimize,
    });
    emit_eff_mod.addAnonymousImport("zigware_manifest_zon", .{ .root_source_file = b.path("zigware.zon") });
    emit_eff_mod.addImport("diag", diag_mod);
    const emit_eff_exe = b.addExecutable(.{ .name = "emit_effective_manifest", .root_module = emit_eff_mod });
    // REQUIRED: dep.artifact(name) resolves only INSTALLED artifacts.
    b.installArtifact(emit_eff_exe);

    // Everything past here is the framework's own self build.
    if (b.pkg_hash.len != 0) return;

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
    // Isolated registry-only step: the aggregate `test` step hangs on the App
    // suites, so the registry's dispatch/threading tests get their own binary.
    const test_registry_step = b.step("test-registry", "Run only the registry tests");
    {
        const m = b.createModule(.{ .root_source_file = b.path("src/registry.zig"), .target = target, .optimize = optimize });
        test_registry_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
    addLogicTest(b, test_step, target, optimize, "src/platform/backend.zig");
    addLogicTest(b, test_step, target, optimize, "src/platform/null.zig");
    addLogicTest(b, test_step, target, optimize, "src/platform/macos/scheme_logic.zig");
    addLogicTest(b, test_step, target, optimize, "src/manifest/types.zig");
    addLogicTest(b, test_step, target, optimize, "src/security_tests.zig");
    // diag.zig is std-only; its tests run in BOTH modes (the build-gating path
    // diverges only under -Drelease=true).
    addLogicTest(b, test_step, target, optimize, "src/diag_tests.zig");
    addLogicTest(b, test_step, target, optimize, "src/zigware_codegen.zig");

    // Isolated headless-barrel step: confirms the Cocoa-free codegen surface
    // (Sink export, emitter) compiles and tests without the App suites.
    const test_codegen_step = b.step("test-codegen", "Run only the headless codegen barrel tests");
    {
        const m = b.createModule(.{ .root_source_file = b.path("src/zigware_codegen.zig"), .target = target, .optimize = optimize });
        test_codegen_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }

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

    // The emitter was previously untested; register its tests and give them an
    // isolated step (the aggregate test step hangs on the App suites).
    addLogicTest(b, test_step, target, optimize, "src/emit_dts.zig");
    const test_emit_dts_step = b.step("test-emit-dts", "Run only the .d.ts emitter tests");
    {
        const m = b.createModule(.{ .root_source_file = b.path("src/emit_dts.zig"), .target = target, .optimize = optimize });
        test_emit_dts_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }

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
    // Capability files (src/grants/*.zon) are read by parseAtBuild via
    // presence enumeration. Pin each one currently present so a change re-runs
    // the codegen. A missing dir means no files are added; the loader's
    // missing-dir branch yields an empty present-set.
    {
        var cap_dir = root.openDir(bio, "src/grants", .{ .iterate = true }) catch null;
        if (cap_dir) |*dir| {
            defer dir.close(bio);
            var it = dir.iterate();
            while (it.next(bio) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
                const sub = b.fmt("src/grants/{s}", .{entry.name});
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

    // Isolated security-suite step: src/security_tests.zig builds a standalone
    // logic-test module (no embedded manifest, no Cocoa), so it runs without
    // the App suites that hang on this host.
    const test_security_step = b.step("test-security", "Run only the src/security_tests.zig tests");
    addLogicTest(b, test_security_step, target, optimize, "src/security_tests.zig");

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

    // Build-time grant-loading enforcement test (src/grant_enforcement_test.zig).
    // Rooted at src/ so manifest/* and security/* are reachable by path in one
    // module; needs the zigware_manifest_zon wire because parse.zig's embedded()
    // compiles even though this test never calls it. No frontend embeds, no Cocoa.
    const grant_enf_mod = b.createModule(.{
        .root_source_file = b.path("src/grant_enforcement_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    wireManifest(grant_enf_mod, effective_zon);
    const grant_enf_tests = b.addTest(.{ .root_module = grant_enf_mod });
    const grant_enf_run = b.addRunArtifact(grant_enf_tests);
    test_step.dependOn(&grant_enf_run.step);
    test_manifest_step.dependOn(&grant_enf_run.step);

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

    // Drift guard: regenerate the schema to a temp file and diff it against the
    // committed copy. `diff` exits non-zero on any difference, failing the step,
    // so CI catches a stale checked-in zigware-manifest.schema.json.
    const schema_check_run = b.addRunArtifact(schema_exe);
    const fresh_schema = schema_check_run.addOutputFileArg("zigware-manifest.schema.json");
    const schema_diff = b.addSystemCommand(&.{ "diff", "-u" });
    schema_diff.addFileArg(b.path("zigware-manifest.schema.json"));
    schema_diff.addFileArg(fresh_schema);
    const schema_check_step = b.step("manifest-schema-check", "Fail if the committed manifest schema drifts from a fresh regenerate");
    schema_check_step.dependOn(&schema_diff.step);

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
