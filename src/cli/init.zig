const std = @import("std");
const template_index = @import("template_index");

pub const Template = enum { vanilla, react, vue, svelte };

pub const InitOptions = struct {
    dir: []const u8,
    name: []const u8,
    template: Template = .vanilla,
    force: bool = false,
};

const name_token = "{{name}}";

/// Scaffold a new project into `opts.dir` from the embedded template set.
///
/// The template blob set is fixed at compile time (`@embedFile` names must be
/// comptime literals), so `opts.template` performs a RUNTIME pick among the
/// COMPTIME-known per-template arrays exposed by the generated `template_index`
/// module. It never enumerates the embed set at runtime.
pub fn run(io: std.Io, gpa: std.mem.Allocator, opts: InitOptions) anyerror!void {
    var dir = try openTarget(io, opts.dir, opts.force);
    defer dir.close(io);

    // The vendored `_shared/*` payload is written for every template, then the
    // selected template's own files. Both lists are comptime-known.
    try writeFiles(io, gpa, dir, &template_index.shared, opts.name);
    try writeFiles(io, gpa, dir, template_index.filesFor(@tagName(opts.template)), opts.name);

    try printNextSteps(io, opts);
}

/// Open (creating if needed) the destination directory, enforcing the
/// not-empty guard unless `force` is set.
fn openTarget(io: std.Io, path: []const u8, force: bool) anyerror!std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, path) catch |err| switch (err) {
        // A pre-existing directory is fine; emptiness is checked below.
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try cwd.openDir(io, path, .{ .iterate = true });
    errdefer dir.close(io);

    if (!force and try hasEntries(io, dir)) return error.init_dir_not_empty;
    return dir;
}

/// True when `dir` contains at least one entry.
fn hasEntries(io: std.Io, dir: std.Io.Dir) anyerror!bool {
    var it = dir.iterate();
    return (try it.next(io)) != null;
}

/// Write each template file into `dir`, stripping the leading subtree segment
/// (`_shared/` or `<template>/`), renaming `gitignore` -> `.gitignore`, and
/// substituting the project name for `{{name}}` everywhere in the bytes.
fn writeFiles(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    files: []const template_index.File,
    name: []const u8,
) anyerror!void {
    for (files) |f| {
        const dest = destPath(f.rel);

        // Create any parent directories first; writeFile does not create them.
        if (std.fs.path.dirnamePosix(dest)) |parent| {
            try dir.createDirPath(io, parent);
        }

        const bytes = try substituteName(gpa, f.bytes, name);
        defer gpa.free(bytes);
        try dir.writeFile(io, .{ .sub_path = dest, .data = bytes });
    }
}

/// Map an embedded template-relative path to its on-disk destination: drop the
/// first path segment (the subtree name) and rename the bare `gitignore` to the
/// dotfile the scaffold needs.
fn destPath(rel: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, rel, '/') orelse return rel;
    const stripped = rel[slash + 1 ..];
    if (std.mem.eql(u8, stripped, "gitignore")) return ".gitignore";
    return stripped;
}

/// Replace every `{{name}}` occurrence in `src` with `name`, returning a fresh
/// allocation owned by the caller.
fn substituteName(gpa: std.mem.Allocator, src: []const u8, name: []const u8) ![]u8 {
    const size = std.mem.replacementSize(u8, src, name_token, name);
    const out = try gpa.alloc(u8, size);
    _ = std.mem.replace(u8, src, name_token, name, out);
    return out;
}

/// Print the post-scaffold guidance via the io writer. Status goes to stderr so
/// it never collides with a stdout pipe (e.g. the test runner's `--listen=-`
/// IPC channel) and follows the convention that human progress is not stdout data.
fn printNextSteps(io: std.Io, opts: InitOptions) anyerror!void {
    var buf: [512]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    const w = &fw.interface;
    try w.print("Scaffolded {s} ({s}) in {s}\n\n", .{ opts.name, @tagName(opts.template), opts.dir });
    try w.print("Next steps:\n  cd {s}\n", .{opts.dir});
    if (opts.template != .vanilla) {
        try w.writeAll("  npm install\n");
    }
    try w.writeAll("  zigware dev\n");
    try w.flush();
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;
const manifest = @import("zigware_manifest");

// Set to true in CI to also compile the scaffolded `dts` codegen step, proving
// the vendored bindgen + sample command compile. Default off: it shells out to
// `zig build` per template and is slow on a developer machine.
const run_scaffold_build = false;

/// Collect the expected destination paths for a template (shared payload plus
/// the template's own files), mirroring `run`'s strip/rename rules.
fn expectedExists(io: std.Io, dir: std.Io.Dir, files: []const template_index.File) !void {
    for (files) |f| {
        const dest = destPath(f.rel);
        dir.access(io, dest, .{}) catch |err| {
            std.debug.print("missing scaffolded file: {s}\n", .{dest});
            return err;
        };
    }
}

test "destPath strips the subtree segment and renames gitignore" {
    try testing.expectEqualStrings("zigware.zon", destPath("vanilla/zigware.zon"));
    try testing.expectEqualStrings("src/commands/greet.zig", destPath("react/src/commands/greet.zig"));
    try testing.expectEqualStrings(".gitignore", destPath("_shared/gitignore"));
    try testing.expectEqualStrings("build.zig", destPath("_shared/build.zig"));
}

test "substituteName replaces every {{name}} occurrence" {
    const out = try substituteName(testing.allocator, "# {{name}}\ncd {{name}}\n", "Acme");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# Acme\ncd Acme\n", out);
    try testing.expect(std.mem.indexOf(u8, out, name_token) == null);
}

test "init scaffolds the expected tree for every template and the manifest parses" {
    const io = testing.io;
    const gpa = testing.allocator;

    inline for (.{ .vanilla, .react, .vue, .svelte }) |tmpl| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_n = try tmp.dir.realPath(io, &path_buf);
        const abs = path_buf[0..path_n];

        try run(io, gpa, .{ .dir = abs, .name = "MyApp", .template = tmpl });

        // Vendored shared payload and the template's own files must all exist.
        try expectedExists(io, tmp.dir, &template_index.shared);
        try expectedExists(io, tmp.dir, template_index.filesFor(@tagName(tmpl)));

        // Spot-check the load-bearing files the plan names explicitly.
        try tmp.dir.access(io, "zigware.zon", .{});
        try tmp.dir.access(io, "build.zig", .{});
        try tmp.dir.access(io, ".gitignore", .{});
        try tmp.dir.access(io, "README.md", .{});
        try tmp.dir.access(io, "src/commands/greet.zig", .{});

        // `{{name}}` must be fully substituted in the manifest.
        const zon = try tmp.dir.readFileAlloc(io, "zigware.zon", gpa, .limited(64 * 1024));
        defer gpa.free(zon);
        try testing.expect(std.mem.indexOf(u8, zon, name_token) == null);
        try testing.expect(std.mem.indexOf(u8, zon, "MyApp") != null);

        // The generated manifest must parse under D's reader.
        var diag: manifest.Diagnostics = .{};
        defer diag.deinit(gpa);
        const m = try manifest.parseAtBuild(gpa, io, tmp.dir, .macos, .Debug, &diag);
        defer manifest.freeManifest(gpa, m);
        try testing.expectEqualStrings("MyApp", m.productName);

        if (run_scaffold_build) try assertScaffoldDtsCompiles(io, gpa, abs);
    }
}

test "init refuses a non-empty target unless force is set" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_n = try tmp.dir.realPath(io, &path_buf);
    const abs = path_buf[0..path_n];

    try tmp.dir.writeFile(io, .{ .sub_path = "keep.txt", .data = "x" });

    try testing.expectError(
        error.init_dir_not_empty,
        run(io, gpa, .{ .dir = abs, .name = "MyApp", .template = .vanilla }),
    );

    // force overwrites into the populated directory.
    try run(io, gpa, .{ .dir = abs, .name = "MyApp", .template = .vanilla, .force = true });
    try tmp.dir.access(io, "zigware.zon", .{});
}

test "init creates a missing target directory" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_n = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..path_n];

    var nested_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const nested = try std.fmt.bufPrint(&nested_buf, "{s}/brand-new", .{base});

    try run(io, gpa, .{ .dir = nested, .name = "Fresh", .template = .vanilla });
    try tmp.dir.access(io, "brand-new/zigware.zon", .{});
}

/// CI-only strong check: run the scaffold's `dts` step (roots at the vendored
/// bindgen -> emit_dts + the sample greet command) and assert exit 0. Full
/// `zig build` cannot run here: `_shared/build.zig` roots the app at a
/// `src/main.zig` no template ships and links Cocoa/WebKit, and the framework
/// templates' `frontendDist` does not exist until npm runs.
fn assertScaffoldDtsCompiles(io: std.Io, gpa: std.mem.Allocator, dir: []const u8) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "zig", "build", "dts" },
        .cwd = .{ .path = dir },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}
