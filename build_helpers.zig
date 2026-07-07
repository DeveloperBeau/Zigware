const std = @import("std");
const assets_embed = @import("src/cli/assets_embed.zig");

/// The consumer's own-origin frontend assets. The framework runtime shims
/// (zigware.js, window.js) are pulled from the dependency, not from here.
pub const FrontendEmbeds = struct {
    index_html: std.Build.LazyPath,
    app_js: std.Build.LazyPath,
};

pub const AppOptions = struct {
    /// Binary name (zig-out/bin/<name>).
    name: []const u8,
    /// The consumer's zigware.zon manifest. CONTRACT: emit_effective_manifest
    /// reads only `dirname(manifest)` plus the hardcoded basename `zigware.zon`,
    /// and dir-walks the per-OS overrides and `src/grants/*.zon` from that
    /// directory; the explicit override/grant `addFileArg`s are cache-pins, not
    /// data. So `manifest` must be a file named `zigware.zon` sitting at the
    /// consumer build root next to `src/grants/`.
    manifest: std.Build.LazyPath,
    /// The consumer's stable command barrel (src/commands.zig). Both the run
    /// exe and the dts-main reach the app commands through this one path.
    command_root: std.Build.LazyPath,
    /// The consumer's entry point (src/main.zig).
    main_root: std.Build.LazyPath,
    /// Optional headless bridge integration test. When set, addApp wires an
    /// `integration-test` step that roots a test at this path against the FULL
    /// barrel (so z.Bridge / z.NullBackend / z.App resolve; the headless barrel
    /// has none of them). NullBackend opens no window, so it runs on CI without a
    /// GUI. Defaults to null, so the scaffold templates and the scaffold-consumer
    /// fixture are unaffected.
    integration_root: ?std.Build.LazyPath = null,
    frontend: FrontendEmbeds,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

/// Per-consumer app constructor. Roots a fresh full barrel against the resolved
/// `zigware` dependency, merges the consumer's manifest through the dependency's
/// installed codegen exe, and wires the run, dts, and test steps. Returns the
/// run exe so the caller can customize it. addApp OWNS the exe and sets all link
/// settings on the barrel; linkFramework propagates across the import edge
/// (spiked 2026-06-28), so the consumer never calls linkFramework.
///
/// Registers the `run`, `dts`, and `test` steps, so call addApp ONCE per consumer
/// build invocation (v0.1.0 single-app scope). A second call would collide on
/// those step names.
pub fn addApp(b: *std.Build, dep: *std.Build.Dependency, opts: AppOptions) *std.Build.Step.Compile {
    const target = opts.target;
    const optimize = opts.optimize;

    // objc named module, rooted in the dependency tree (the macos backend
    // files import it as @import("objc")).
    const objc_mod = b.createModule(.{
        .root_source_file = dep.builder.path("src/objc.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Fresh full barrel for THIS consumer. Cocoa/WebKit link settings live
    // here and propagate to the exe across the import edge.
    const barrel = b.createModule(.{
        .root_source_file = dep.builder.path("src/zigware.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    barrel.addImport("objc", objc_mod);
    // PER-OS LINK SEAM. One of the sites a future Linux/Windows port touches
    // (alongside `Backend()` in src/zigware.zig, Task 5, and the `objc` import
    // just above). Runtime guard, NOT a comptime switch: `target.result.os.tag`
    // is a runtime std.Build value, so a `switch ... else => @compileError` would
    // fire unconditionally and fail to compile build_helpers.zig. Comptime
    // macOS-only enforcement is already delivered by Backend()'s @compileError at
    // app-compile time. Adding a platform here is one additive branch (e.g.
    // GTK/WebKitGTK on Linux, WebView2 on Windows).
    if (target.result.os.tag == .macos) {
        barrel.linkFramework("Cocoa", .{});
        barrel.linkFramework("WebKit", .{});
        // When the target is explicitly specified (e.g. `-Dtarget=aarch64-macos`
        // or `x86_64-macos`, as `zigware build --arch`/`--arch universal` pass),
        // Zig does not auto-discover the macOS SDK, so both the framework search
        // path and the sysroot (needed to resolve transitive system library
        // dependencies in .tbd stubs) are empty. Fix both via xcrun. A native
        // build (no `-Dtarget`) already resolves the SDK, so only pay the xcrun
        // spawn and the global b.sysroot mutation for a non-native target. Keying
        // on arch-inequality alone was wrong: a same-arch explicit target (arm64
        // host -> aarch64-macos, the first slice of a universal build) is still
        // non-native and needs the SDK, but would slip past an arch compare.
        if (!target.query.isNative()) {
            if (sdkPath(b.allocator, b.graph.io)) |sdk| {
                b.sysroot = sdk;
                barrel.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
            } else |_| {}
        }
    } else {
        std.debug.panic("zigware v0.1.0 targets macOS only", .{});
    }
    // Consumer-supplied own-origin assets override the framework defaults.
    barrel.addAnonymousImport("frontend/index.html", .{ .root_source_file = opts.frontend.index_html });
    barrel.addAnonymousImport("frontend/app.js", .{ .root_source_file = opts.frontend.app_js });
    // Framework runtime shims come from the dependency.
    barrel.addAnonymousImport("frontend/zigware.js", .{ .root_source_file = dep.builder.path("frontend/zigware.js") });
    barrel.addAnonymousImport("frontend/window.js", .{ .root_source_file = dep.builder.path("frontend/window.js") });

    // Merge+validate the consumer's manifest via the dependency's INSTALLED
    // codegen exe. dep.artifact resolves only because the consumer surface
    // installs emit_effective_manifest.
    const eff_run = b.addRunArtifact(dep.artifact("emit_effective_manifest"));
    const eff_zon: std.Build.LazyPath = eff_run.addOutputFileArg("zigware.effective.zon");
    const grants_zon: std.Build.LazyPath = eff_run.addOutputFileArg("zigware.effective.grants.zon");
    eff_run.addFileArg(opts.manifest);

    // Per-OS overrides + grants, pinned from the CONSUMER build root so a change
    // re-runs the codegen. These reads run in the consumer build (b is the
    // consumer builder), so b.build_root is the consumer root.
    const root = b.build_root.handle;
    const bio = b.graph.io;
    for ([_][]const u8{ "zigware.macos.zon", "zigware.linux.zon", "zigware.windows.zon" }) |name| {
        if (root.access(bio, name, .{})) {
            eff_run.addFileArg(b.path(name));
        } else |_| {}
    }
    {
        var gd = root.openDir(bio, "src/grants", .{ .iterate = true }) catch null;
        if (gd) |*dir| {
            defer dir.close(bio);
            var it = dir.iterate();
            while (it.next(bio) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
                eff_run.addFileArg(b.path(b.fmt("src/grants/{s}", .{entry.name})));
            }
        }
    }
    // parse.embedded() in the barrel resolves the merged manifest.
    barrel.addAnonymousImport("zigware_manifest_zon", .{ .root_source_file = eff_zon });

    // The app's declared capability bodies, embedded the same way the manifest is.
    // app.zig @imports this to build the live grant table from real per-window /
    // per-origin declarations. app.zig is compiled AS PART of the barrel module,
    // so wiring the import on the barrel resolves it for the run exe and the
    // full-barrel integration test alike.
    barrel.addAnonymousImport("zigware_grants_zon", .{ .root_source_file = grants_zon });

    // Asset table wiring. Two shadow sources for the framework default
    // src/asset_table.zig (a 3-entry table), in priority order:
    //   1. `zigware build` release staging passes -Dasset_table=<staged path>: a
    //      CSP-injected table colocated with the built dist. Highest priority.
    //   2. Dev (`zig build run`): stage the consumer's own frontend/ source dir
    //      (every file, not just index.html/app.js) plus the framework zigware.js
    //      shim into one WriteFiles dir, emit asset_table.zig beside them, and
    //      shadow the default. This gives dev the same full-asset coverage release
    //      already has, so a consumer stylesheet/image is served over app://.
    // When neither applies (no frontend/ dir), the framework default table stands.
    if (b.option([]const u8, "asset_table", "Path to a staged asset_table.zig (set by `zigware build`)")) |asset_table| {
        barrel.addAnonymousImport("asset_table.zig", .{ .root_source_file = .{ .cwd_relative = asset_table } });
    } else if (stageDevAssets(b, dep)) |dev_table| {
        barrel.addAnonymousImport("asset_table.zig", .{ .root_source_file = dev_table });
    }

    // -- run exe (owns the barrel link settings) --
    const exe_mod = b.createModule(.{
        .root_source_file = opts.main_root,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zigware", barrel);
    const exe = b.addExecutable(.{ .name = opts.name, .root_module = exe_mod });
    b.installArtifact(exe);
    const run_step = b.step("run", "Build and run the app window");
    run_step.dependOn(&b.addRunArtifact(exe).step);

    // -- dts (headless; the consumer command file compiles against the
    // Cocoa-free barrel so the dts exe links no Cocoa) --
    const headless = dep.module("zigware-headless");
    const app_cmds = b.createModule(.{
        .root_source_file = opts.command_root,
        .target = target,
        .optimize = optimize,
    });
    // The consumer's command files name handler types via @import("zigware");
    // for the headless dts build that resolves to the Cocoa-free barrel.
    app_cmds.addImport("zigware", headless);

    // dts-main: synthesized source that calls zc.emit and writes the output.
    // Writes to frontend/bindings.d.ts relative to the Run step cwd, which Zig
    // Build sets to b.build_root (the consumer project root). This is deliberate,
    // NOT an addOutputFileArg build artifact: bindings.d.ts is a frontend dev
    // artifact the TS toolchain imports, so it must land in the consumer's
    // frontend/ source tree (gitignored). frontend/ is guaranteed to exist because
    // addApp requires opts.frontend.{index_html,app_js}, so the parent dir is never
    // missing. Mirrors the framework's own emit_dts.zig / dts step.
    const dts_main_src =
        \\const std = @import("std");
        \\const zc = @import("zigware-headless");
        \\const app = @import("app_commands");
        \\pub fn main() !void {
        \\    var gpa = std.heap.DebugAllocator(.{}){};
        \\    defer _ = gpa.deinit();
        \\    const alloc = gpa.allocator();
        \\    var aw: std.Io.Writer.Allocating = .init(alloc);
        \\    defer aw.deinit();
        \\    try zc.emit(&aw.writer, app.State, app.Commands);
        \\    var threaded = std.Io.Threaded.init(alloc, .{});
        \\    defer threaded.deinit();
        \\    const io = threaded.io();
        \\    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "frontend/bindings.d.ts", .data = aw.writer.buffered() });
        \\}
        \\
    ;
    const dts_main = b.addWriteFiles().add("dts_main.zig", dts_main_src);
    const dts_mod = b.createModule(.{
        .root_source_file = dts_main,
        .target = target,
        .optimize = optimize,
    });
    dts_mod.addImport("zigware-headless", headless);
    dts_mod.addImport("app_commands", app_cmds);
    const dts_exe = b.addExecutable(.{ .name = b.fmt("{s}-dts", .{opts.name}), .root_module = dts_mod });
    // Install the dts binary to zig-out/bin/ so the headless otool gate has a
    // deterministic path. The dts_step also depends on this install so that
    // `zig build dts` both installs the binary AND runs it.
    const install_dts_exe = b.addInstallArtifact(dts_exe, .{});
    b.getInstallStep().dependOn(&install_dts_exe.step);
    const dts_step = b.step("dts", "Generate frontend/bindings.d.ts");
    dts_step.dependOn(&install_dts_exe.step);
    dts_step.dependOn(&b.addRunArtifact(dts_exe).step);

    // -- test (headless command tests, Cocoa-free, so they run on CI without a
    // GUI) --
    const test_mod = b.createModule(.{
        .root_source_file = opts.command_root,
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zigware", headless);
    const test_step = b.step("test", "Run the app's command tests (headless)");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_mod })).step);

    // -- integration test (optional; full-barrel headless bridge round-trip) --
    // Rooted against the SAME per-consumer `barrel` the run exe uses (so the
    // embedded manifest, frontend embeds, and Cocoa/WebKit link settings are the
    // example's own). NullBackend opens no window; the Cocoa link the barrel
    // pulls across the import edge is harmless on the macOS runner.
    if (opts.integration_root) |it_root| {
        const it_mod = b.createModule(.{
            .root_source_file = it_root,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        it_mod.addImport("zigware", barrel);
        const it_step = b.step("integration-test", "Run the app's headless bridge integration test");
        it_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = it_mod })).step);
    }

    return exe;
}

/// Dev asset staging: walk the consumer's frontend/ source dir, stage every
/// asset plus the framework zigware.js shim into one WriteFiles output dir, and
/// emit an asset_table.zig beside them (so its @embedFile resolves by
/// colocation, exactly as the release-staged table does). Returns the generated
/// table's LazyPath, or null when there is no frontend/ dir (missing dir is the
/// graceful "use the framework default table" path, never a hard error). Reuses
/// src/cli/assets_embed.zig, which enforces the reject-outside-dist containment.
fn stageDevAssets(b: *std.Build, dep: *std.Build.Dependency) ?std.Build.LazyPath {
    const io = b.graph.io;
    const gpa = b.allocator;

    // Resolve frontend/ to an ABSOLUTE path via the build-root handle, so the
    // walk is independent of the process cwd (b.pathFromRoot can yield a
    // cwd-relative "./frontend" when build_root.path is null or "."). This
    // mirrors addApp's other configure-time reads, which use b.build_root.handle
    // (see the per-OS override + grants probing earlier in addApp). A missing
    // frontend/ dir is the graceful "use the framework default table" path.
    b.build_root.handle.access(io, "frontend", .{}) catch return null;
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_n = b.build_root.handle.realPath(io, &root_buf) catch return null;
    const root_abs = root_buf[0..root_n];
    const frontend_abs = b.fmt("{s}/frontend", .{root_abs});

    var result = assets_embed.walk(io, gpa, frontend_abs) catch |err| switch (err) {
        // No frontend/ dir: fall back to the framework default table.
        error.frontend_dist_missing => return null,
        // A real staging error (an asset resolving outside the dir, OOM) must
        // fail the build loudly, not silently serve a partial set.
        else => std.debug.panic("zigware: staging frontend assets failed: {s}", .{@errorName(err)}),
    };
    defer result.deinit();

    const wf = b.addWriteFiles();
    // Copy each walked consumer asset into the staged dir under its
    // import_name, so the emitted @embedFile("<import_name>") resolves.
    for (result.entries) |e| {
        _ = wf.addCopyFile(b.path(b.fmt("frontend/{s}", .{e.import_name})), e.import_name);
    }
    // The framework zigware.js shim is not in the consumer's frontend/ dir; it
    // comes from the dependency. Stage it and add its table entry so /zigware.js
    // stays served (parity with the framework default table).
    _ = wf.addCopyFile(dep.builder.path("frontend/zigware.js"), "zigware.js");

    // Build the full entry list (walked consumer assets + zigware.js) and emit
    // the table. emitAssetTable does not require sorted input for correctness;
    // append the shim entry after the walked (already sorted) ones.
    var entries: std.ArrayList(assets_embed.Entry) = .empty;
    defer entries.deinit(gpa);
    entries.appendSlice(gpa, result.entries) catch @panic("OOM");
    entries.append(gpa, .{ .serve_path = "/zigware.js", .import_name = "zigware.js", .mime = assets_embed.mimeForExt(".js") }) catch @panic("OOM");

    // Ownership: wf.add holds the byte slice until the WriteFiles step runs, so
    // the bytes must outlive this function. Dupe the emitted table onto
    // b.allocator (the build arena, alive for the whole build) and let the
    // Allocating writer's own buffer be freed by defer. This is the safe analog
    // of emitTemplateIndex's toOwnedSlice pattern (build.zig ~754).
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    assets_embed.emitAssetTable(&aw.writer, entries.items) catch @panic("OOM");
    const bytes = gpa.dupe(u8, aw.writer.buffered()) catch @panic("OOM");

    return wf.add("asset_table.zig", bytes);
}

/// Return the path to the active macOS SDK (e.g.
/// `.../MacOSX.sdk`). Used to supply an explicit sysroot and framework search
/// path when cross-compiling between macOS architectures: Zig does not
/// auto-discover the SDK on non-native builds, so `-framework Cocoa` would
/// otherwise fail to link with "searched paths: none" and transitive system
/// library stubs (.tbd) can't resolve their own dependencies.
///
/// Runs `xcrun --sdk macosx --show-sdk-path` synchronously during the build
/// configuration phase. Errors are returned rather than panicked so the call
/// site can decide whether to treat a missing xcrun as fatal.
fn sdkPath(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
    });
    defer gpa.free(res.stderr);
    defer gpa.free(res.stdout);
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) return error.xcrun_failed;
    const sdk = std.mem.trim(u8, res.stdout, " \n\r\t");
    return gpa.dupe(u8, sdk);
}
