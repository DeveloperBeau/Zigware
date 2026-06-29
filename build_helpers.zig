const std = @import("std");

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

    // Production asset table override. `zigware build` stages a CSP-injected
    // asset_table.zig (colocated with the built assets) and passes its path via
    // -Dasset_table; this anonymous import shadows the framework default
    // src/asset_table.zig (resolved relatively by src/assets.zig), so the
    // release binary serves the transformed production assets. Unset in dev (the
    // app loads from serveUrl), so the relative default is used.
    if (b.option([]const u8, "asset_table", "Path to a staged asset_table.zig (set by `zigware build`)")) |asset_table| {
        barrel.addAnonymousImport("asset_table.zig", .{ .root_source_file = .{ .cwd_relative = asset_table } });
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

    return exe;
}
