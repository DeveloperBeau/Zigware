const std = @import("std");
const template_index = @import("template_index");

pub const Template = enum { vanilla, react, vue, svelte };

pub const InitOptions = struct {
    dir: []const u8,
    name: []const u8,
    template: Template = .vanilla,
    force: bool = false,
    /// Absolute path to the Zigware framework checkout the scaffold depends on
    /// (pre-release path dependency). Resolved by the CLI from `--framework-path`
    /// or the `ZIGWARE_FRAMEWORK_PATH` env var.
    framework_path: []const u8,
};

const name_token = "{{name}}";
const ident_token = "{{name_ident}}";
const fingerprint_token = "{{fingerprint}}";
const framework_dep_token = "{{framework_dep}}";

/// The substitutions applied to every template file's bytes. Computed once in
/// `run` from the project name + framework path.
const Subst = struct {
    name: []const u8,
    name_ident: []const u8,
    fingerprint: []const u8, // "0x...." hex literal
    framework_dep: []const u8, // relative path from the scaffold to the framework
};

/// Scaffold a new project into `opts.dir` from the embedded template set.
///
/// The template blob set is fixed at compile time (`@embedFile` names must be
/// comptime literals), so `opts.template` performs a RUNTIME pick among the
/// COMPTIME-known per-template arrays exposed by the generated `template_index`
/// module. It never enumerates the embed set at runtime.
pub fn run(io: std.Io, gpa: std.mem.Allocator, opts: InitOptions) anyerror!void {
    var dir = try openTarget(io, opts.dir, opts.force);
    defer dir.close(io);

    const subst = try computeSubst(io, gpa, dir, opts);
    defer freeSubst(gpa, subst);

    // The `_shared/*` payload is written for every template, then the selected
    // template's own files. Both lists are comptime-known.
    try writeFiles(io, gpa, dir, &template_index.shared, subst);
    try writeFiles(io, gpa, dir, template_index.filesFor(@tagName(opts.template)), subst);

    try printNextSteps(io, opts);
}

/// Compute the per-scaffold substitutions: the project name, a valid Zig
/// enum-literal identifier, a Zig 0.16 package fingerprint (checksum over the
/// identifier in the high 32 bits, a deterministic id in the low 32), and the
/// RELATIVE path from the scaffold to the framework checkout (Zig rejects
/// absolute path dependencies).
fn computeSubst(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, opts: InitOptions) anyerror!Subst {
    const name_ident = try deriveIdent(gpa, opts.name);
    errdefer gpa.free(name_ident);
    const fingerprint = try computeFingerprint(gpa, name_ident);
    errdefer gpa.free(fingerprint);

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const scaffold_n = try dir.realPath(io, &buf);
    // Both inputs are absolute, so `cwd` is unused; pass "/". (Zig 0.16's generic
    // `relative` needs an environ map; relativePosix is the macOS-only path.)
    const framework_dep = try std.fs.path.relativePosix(gpa, "/", buf[0..scaffold_n], opts.framework_path);

    return .{ .name = opts.name, .name_ident = name_ident, .fingerprint = fingerprint, .framework_dep = framework_dep };
}

fn freeSubst(gpa: std.mem.Allocator, s: Subst) void {
    gpa.free(s.name_ident);
    gpa.free(s.fingerprint);
    gpa.free(s.framework_dep);
}

/// A valid Zig enum-literal identifier from the app name: lowercase, every
/// non-`[a-z0-9_]` byte becomes `_`, and a leading digit is prefixed with `_`.
fn deriveIdent(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    if (name.len > 0 and std.ascii.isDigit(name[0])) try list.append(gpa, '_');
    for (name) |c| {
        const lc = std.ascii.toLower(c);
        const ok = (lc >= 'a' and lc <= 'z') or (lc >= '0' and lc <= '9') or lc == '_';
        try list.append(gpa, if (ok) lc else '_');
    }
    if (list.items.len == 0) try list.append(gpa, '_');
    return list.toOwnedSlice(gpa);
}

/// Zig 0.16 validates `.fingerprint`: high 32 bits MUST equal `crc32(name)`;
/// low 32 bits are a free package id. Deterministic (no time/RNG): same name ->
/// same fingerprint.
fn computeFingerprint(gpa: std.mem.Allocator, name_ident: []const u8) ![]u8 {
    const checksum: u32 = std.hash.Crc32.hash(name_ident);
    var id: u32 = @truncate(std.hash.Wyhash.hash(0, name_ident));
    if (id == 0 or id == 0xffffffff) id = 1;
    const fp: u64 = (@as(u64, checksum) << 32) | id;
    return std.fmt.allocPrint(gpa, "0x{x:0>16}", .{fp});
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
    subst: Subst,
) anyerror!void {
    for (files) |f| {
        const dest = destPath(f.rel);

        // Create any parent directories first; writeFile does not create them.
        if (std.fs.path.dirnamePosix(dest)) |parent| {
            try dir.createDirPath(io, parent);
        }

        const bytes = try substituteAll(gpa, f.bytes, subst);
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

/// Replace every template token in `src`, returning a fresh allocation owned by
/// the caller. Tokens absent from a given file are no-ops.
fn substituteAll(gpa: std.mem.Allocator, src: []const u8, subst: Subst) ![]u8 {
    var cur = try gpa.dupe(u8, src);
    const pairs = [_]struct { tok: []const u8, val: []const u8 }{
        .{ .tok = name_token, .val = subst.name },
        .{ .tok = ident_token, .val = subst.name_ident },
        .{ .tok = fingerprint_token, .val = subst.fingerprint },
        .{ .tok = framework_dep_token, .val = subst.framework_dep },
    };
    for (pairs) |p| {
        const next = try replaceAlloc(gpa, cur, p.tok, p.val);
        gpa.free(cur);
        cur = next;
    }
    return cur;
}

fn replaceAlloc(gpa: std.mem.Allocator, src: []const u8, needle: []const u8, repl: []const u8) ![]u8 {
    const size = std.mem.replacementSize(u8, src, needle, repl);
    const out = try gpa.alloc(u8, size);
    _ = std.mem.replace(u8, src, needle, repl, out);
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

/// A throwaway framework path for tests: the framework checkout is the process
/// cwd, so its realpath is a valid absolute `framework_path`.
fn testFrameworkPath(io: std.Io, buf: []u8) ![]const u8 {
    var d = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer d.close(io);
    const n = try d.realPath(io, buf);
    return buf[0..n];
}

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
    try testing.expectEqualStrings("src/main.zig", destPath("_shared/src/main.zig"));
}

test "substituteAll replaces every template token" {
    const gpa = testing.allocator;
    const subst: Subst = .{ .name = "Acme", .name_ident = "acme", .fingerprint = "0xdeadbeefcafef00d", .framework_dep = "../zigware" };
    const out = try substituteAll(gpa, "n={{name}} i={{name_ident}} f={{fingerprint}} d={{framework_dep}}\n", subst);
    defer gpa.free(out);
    try testing.expectEqualStrings("n=Acme i=acme f=0xdeadbeefcafef00d d=../zigware\n", out);
    try testing.expect(std.mem.indexOf(u8, out, "{{") == null);
}

test "deriveIdent sanitizes and fingerprint is deterministic + valid" {
    const gpa = testing.allocator;
    const id1 = try deriveIdent(gpa, "My App 2");
    defer gpa.free(id1);
    try testing.expectEqualStrings("my_app_2", id1);
    const id2 = try deriveIdent(gpa, "9lives");
    defer gpa.free(id2);
    try testing.expectEqualStrings("_9lives", id2);

    const fp1 = try computeFingerprint(gpa, "demo");
    defer gpa.free(fp1);
    const fp2 = try computeFingerprint(gpa, "demo");
    defer gpa.free(fp2);
    try testing.expectEqualStrings(fp1, fp2); // deterministic
    try testing.expectEqual(@as(usize, 18), fp1.len); // "0x" + 16 hex
    try testing.expect(std.mem.startsWith(u8, fp1, "0x"));
}

test "init scaffolds a normal Zig project (no vendored framework files), manifest parses" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fw_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fw_abs = try testFrameworkPath(io, &fw_buf);

    inline for (.{ .vanilla, .react, .vue, .svelte }) |tmpl| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const abs_n = try tmp.dir.realPath(io, &path_buf);
        const abs = path_buf[0..abs_n];

        try run(io, gpa, .{ .dir = abs, .name = "MyApp", .template = tmpl, .framework_path = fw_abs });

        // Shared payload and the template's own files must all exist.
        try expectedExists(io, tmp.dir, &template_index.shared);
        try expectedExists(io, tmp.dir, template_index.filesFor(@tagName(tmpl)));

        // The user-owned normal-project tree. src/commands.zig is the stable
        // barrel addApp reads as command_root; src/grants/main.zon must exist
        // for every template (vanilla/react/vue/svelte), which a comptime blob
        // iteration would not otherwise diagnose.
        for ([_][]const u8{ "build.zig", "build.zig.zon", ".gitignore", "README.md", "zigware.zon", "src/main.zig", "src/commands.zig", "src/commands/greet.zig", "src/grants/main.zon" }) |p| {
            try tmp.dir.access(io, p, .{});
        }

        // Framework files must NOT be vendored into the scaffold (they come from the package).
        for ([_][]const u8{ "command_ctx.zig", "protocol.zig", "bindgen.zig", "emit_dts.zig" }) |p| {
            try testing.expectError(error.FileNotFound, tmp.dir.access(io, p, .{}));
        }

        // build.zig.zon: every token substituted, fingerprint + dependency present.
        const bz = try tmp.dir.readFileAlloc(io, "build.zig.zon", gpa, .limited(64 * 1024));
        defer gpa.free(bz);
        try testing.expect(std.mem.indexOf(u8, bz, "{{") == null);
        try testing.expect(std.mem.indexOf(u8, bz, ".fingerprint = 0x") != null);
        try testing.expect(std.mem.indexOf(u8, bz, ".path =") != null);

        // The generated manifest must parse, with the substituted product name.
        const zon = try tmp.dir.readFileAlloc(io, "zigware.zon", gpa, .limited(64 * 1024));
        defer gpa.free(zon);
        try testing.expect(std.mem.indexOf(u8, zon, name_token) == null);
        try testing.expect(std.mem.indexOf(u8, zon, "MyApp") != null);

        var diag: manifest.Diagnostics = .{};
        defer diag.deinit(gpa);
        const m = try manifest.parseAtBuild(gpa, io, tmp.dir, .macos, .Debug, &diag);
        defer manifest.freeManifest(gpa, m);
        try testing.expectEqualStrings("MyApp", m.productName);
    }
}

test "init refuses a non-empty target unless force is set" {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var fw_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fw_abs = try testFrameworkPath(io, &fw_buf);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_n = try tmp.dir.realPath(io, &path_buf);
    const abs = path_buf[0..path_n];

    try tmp.dir.writeFile(io, .{ .sub_path = "keep.txt", .data = "x" });

    try testing.expectError(
        error.init_dir_not_empty,
        run(io, gpa, .{ .dir = abs, .name = "MyApp", .template = .vanilla, .framework_path = fw_abs }),
    );

    // force overwrites into the populated directory.
    try run(io, gpa, .{ .dir = abs, .name = "MyApp", .template = .vanilla, .force = true, .framework_path = fw_abs });
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

    var fw_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fw_abs = try testFrameworkPath(io, &fw_buf);

    var nested_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const nested = try std.fmt.bufPrint(&nested_buf, "{s}/brand-new", .{base});

    try run(io, gpa, .{ .dir = nested, .name = "Fresh", .template = .vanilla, .framework_path = fw_abs });
    try tmp.dir.access(io, "brand-new/zigware.zon", .{});
}
