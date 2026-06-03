//! Build-time manifest loader. Reads `zigware.zon` and any per-OS override,
//! merges them, validates, and returns the effective `Manifest`. The runtime
//! accessor `embedded()` returns a comptime `@import` of the build-embedded
//! `.zon` artifact — there is no runtime file read on the production path.
//!
//! Ownership:
//! - `parseAtBuild` / `parseAtBuildFromPaths` return a `Manifest` owned by the
//!   caller's allocator. Free with `freeManifest`.
//! - `std.zon.parse.free` is UNUSABLE on `Manifest`: it walks pointer fields
//!   type-driven and calls `gpa.free` on the static-literal default pointers
//!   (e.g. `Csp.scriptSrc = &.{"'self'"}`), which crashes. The in-house
//!   `freeManifest` below consults `@typeInfo(...).default_value_ptr` and
//!   skips slices whose runtime `.ptr` still equals the comptime default's
//!   `.ptr` — that is the static-default skip rule.
//! - `std.zon.parse.free` IS safe on `OverrideManifest` (every default is
//!   `null`, no static-literal slice defaults exist); the override is freed
//!   in-function before this routine returns.
//!
//! `merge.merge` returns a fully `gpa`-owned deep-dup of base merged with the
//! per-OS override (when present); both call sites free `base` immediately on
//! the success path because the merged value no longer aliases into it.

const std = @import("std");
const types = @import("types.zig");
const validate = @import("validate.zig");
const merge = @import("merge.zig");

pub const Manifest = types.Manifest;
const OverrideManifest = types.OverrideManifest;
const Diagnostics = types.Diagnostics;

pub const LoadError = error{
    FileNotFound,
    ParseFailed,
    ValidationFailed,
} || std.mem.Allocator.Error;

const READ_LIMIT_BYTES: usize = 1 << 20; // 1 MiB upper bound on a manifest file.

/// Reads `zigware.zon` (and any matching per-OS override) from `root_dir` and
/// returns the validated effective `Manifest`. Callers free the result with
/// `freeManifest`. Diagnostics are appended to `diag`; the caller owns it.
pub fn parseAtBuild(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    target_os: std.Target.Os.Tag,
    optimize: std.builtin.OptimizeMode,
    diag: *Diagnostics,
) LoadError!Manifest {
    // 1. Read base.
    const base_src = root_dir.readFileAllocOptions(
        io,
        "zigware.zon",
        gpa,
        .limited(READ_LIMIT_BYTES),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FileNotFound,
    };
    defer gpa.free(base_src);

    // 2. Discover available per-OS override files. Iterate the dir and record
    // every basename that matches `zigware.<known_os>.zon`. The presence list
    // is consulted both for selection (pick the file matching target_os) and
    // for the unknown-target warning emission.
    var present: [3]?KnownOsFile = .{ null, null, null };
    var n_present: usize = 0;

    var it_dir = root_dir.openDir(io, ".", .{ .iterate = true }) catch null;
    if (it_dir) |*d| {
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (matchKnownOsOverride(entry.name)) |kof| {
                if (n_present < present.len) {
                    present[n_present] = kof;
                    n_present += 1;
                }
            }
        }
    }

    // 3. Select an override matching target_os if any.
    const selected: ?KnownOsFile = blk: {
        const target_kof = targetKnownOs(target_os) orelse break :blk null;
        for (present[0..n_present]) |entry| {
            const kof = entry orelse continue;
            if (kof == target_kof) break :blk kof;
        }
        break :blk null;
    };

    // 4. If the target has no mapping and any per-OS override file IS present,
    // emit one warning per present override.
    if (targetKnownOs(target_os) == null) {
        for (present[0..n_present]) |entry| {
            if (entry == null) continue;
            try diag.add(gpa, .{
                .code = .override_for_target_dropped,
                .is_error = false,
                .message = OVERRIDE_DROPPED_MESSAGE,
                .path = null,
            });
        }
    }

    return parsePipeline(gpa, io, root_dir, base_src, selected, optimize, diag);
}

/// Path-driven sibling of `parseAtBuild`. The base manifest path and any
/// per-OS override paths are supplied explicitly so the build graph can pin
/// every input via `addFileArg` (Task 9's codegen uses this entry point).
/// The override selection scans basenames in `override_paths`. `capability_ids`
/// is the present-set the validator cross-checks `security.capabilities`
/// against; the caller pins capability files via `addFileArg` and extracts
/// their basenames before calling.
pub fn parseAtBuildFromPaths(
    gpa: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    override_paths: []const []const u8,
    capability_ids: []const []const u8,
    target_os: std.Target.Os.Tag,
    optimize: std.builtin.OptimizeMode,
    diag: *Diagnostics,
) LoadError!Manifest {
    const cwd = std.Io.Dir.cwd();

    const base_src = cwd.readFileAllocOptions(
        io,
        base_path,
        gpa,
        .limited(READ_LIMIT_BYTES),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FileNotFound,
    };
    defer gpa.free(base_src);

    // Walk override_paths once. Select the path whose basename matches the
    // target OS, and (if the target has no mapping) emit one warning per
    // recognised override path.
    var selected_path: ?[]const u8 = null;
    const target_kof = targetKnownOs(target_os);
    for (override_paths) |op| {
        const base = std.fs.path.basename(op);
        const kof = matchKnownOsOverride(base) orelse continue;
        if (target_kof) |tk| {
            if (kof == tk) {
                // build.zig is expected to pin each per-OS basename at most
                // once. A duplicate would silently take last-write-wins;
                // assert at debug time so the bug surfaces in tests rather
                // than as confusing runtime behaviour.
                std.debug.assert(selected_path == null);
                selected_path = op;
            }
        } else {
            try diag.add(gpa, .{
                .code = .override_for_target_dropped,
                .is_error = false,
                .message = OVERRIDE_DROPPED_MESSAGE,
                .path = null,
            });
        }
    }

    // Parse the base.
    var zon_diag: std.zon.parse.Diagnostics = .{};
    defer zon_diag.deinit(gpa);
    const base = std.zon.parse.fromSliceAlloc(Manifest, gpa, base_src, &zon_diag, .{}) catch |err| switch (err) {
        error.ParseZon => {
            try mirrorZonDiagnostic(gpa, diag, &zon_diag, base_path, "base manifest failed to parse");
            return error.ParseFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    var base_owned: ?Manifest = base;
    errdefer if (base_owned) |b| freeManifest(gpa, b);

    // Parse and apply override if one was selected.
    var override_value: ?OverrideManifest = null;
    if (selected_path) |op| {
        const ov_src = cwd.readFileAllocOptions(
            io,
            op,
            gpa,
            .limited(READ_LIMIT_BYTES),
            .of(u8),
            0,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A selected override that turns up missing is a configuration
            // error worth surfacing: the caller pinned the path and expected
            // it to read. Mirror to a parse-failed result; the message is
            // generic because there is no zon-level location.
            else => {
                try diag.add(gpa, .{
                    .code = .override_for_target_dropped,
                    .is_error = true,
                    .message = "selected per-OS override path could not be read",
                    .path = null,
                });
                return error.ParseFailed;
            },
        };
        defer gpa.free(ov_src);

        var ov_zon_diag: std.zon.parse.Diagnostics = .{};
        defer ov_zon_diag.deinit(gpa);
        override_value = std.zon.parse.fromSliceAlloc(OverrideManifest, gpa, ov_src, &ov_zon_diag, .{}) catch |err| switch (err) {
            error.ParseZon => {
                try mirrorZonDiagnostic(gpa, diag, &ov_zon_diag, op, "per-OS override failed to parse");
                return error.ParseFailed;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    defer if (override_value) |ov| std.zon.parse.free(gpa, ov);

    // Apply the merge. It returns a fully gpa-owned deep-dup of base merged
    // with override, so the base allocation is disposable on the success path.
    const merged = try merge.merge(gpa, base_owned.?, override_value);
    freeManifest(gpa, base_owned.?);
    base_owned = null;

    if (!(try validate.validate(gpa, merged, optimize, capability_ids, diag)) or diag.hasErrors()) {
        freeManifest(gpa, merged);
        return error.ValidationFailed;
    }

    return merged;
}

/// Returns the build-embedded manifest. `@import("zigware_manifest_zon")` is
/// resolved at compile time of THIS file (parse.zig); every module that
/// compiles parse.zig MUST wire the anonymous import via build.zig.
pub fn embedded() Manifest {
    return @import("zigware_manifest_zon");
}

/// Lists capability identifiers by presence under `src/capabilities/*.zon` in
/// `root_dir`. A missing directory yields an EMPTY slice (fail-closed: every
/// `security.capabilities` reference then fails as `unknown_capability_ref`),
/// never an error.
///
/// Ownership: every element is `gpa.dupe`-d. Caller frees with:
///   for (ids) |s| gpa.free(s);
///   gpa.free(ids);
fn listCapabilityIds(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
) std.mem.Allocator.Error![]const []const u8 {
    var dir = root_dir.openDir(io, "src/capabilities", .{ .iterate = true }) catch {
        // Missing dir is the expected fail-closed path; any other open error
        // also degrades to "no capabilities present" rather than aborting.
        const empty: []const []const u8 = &.{};
        return empty;
    };
    defer dir.close(io);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
        const id = entry.name[0 .. entry.name.len - ".zon".len];
        const owned = try gpa.dupe(u8, id);
        errdefer gpa.free(owned);
        try list.append(gpa, owned);
    }

    return try list.toOwnedSlice(gpa);
}

/// Reflection-driven freer for `Manifest`. For each slice-typed field, if a
/// comptime default exists and the runtime `.ptr` equals the deref'd default's
/// `.ptr`, the slice is left untouched (still the static default). Zero-length
/// slices are also skipped. Otherwise the slice is freed with `gpa.free`,
/// recursing first into element types that themselves own memory.
pub fn freeManifest(gpa: std.mem.Allocator, m: Manifest) void {
    freeStruct(Manifest, gpa, m);
}

fn freeStruct(comptime T: type, gpa: std.mem.Allocator, value: T) void {
    const info = @typeInfo(T);
    inline for (info.@"struct".fields) |f| {
        freeField(f, gpa, @field(value, f.name));
    }
}

fn freeField(comptime f: std.builtin.Type.StructField, gpa: std.mem.Allocator, v: f.type) void {
    const FT = f.type;
    const finfo = @typeInfo(FT);
    switch (finfo) {
        .pointer => |ptr| {
            if (ptr.size != .slice) return;
            // Static-default skip: if a comptime default exists and the
            // runtime `.ptr` matches the default's `.ptr`, leave it.
            if (f.default_value_ptr) |dvp| {
                const default_val: *const FT = @ptrCast(@alignCast(dvp));
                if (v.ptr == default_val.*.ptr) return;
            }
            if (v.len == 0) return;
            const Child = ptr.child;
            const cinfo = @typeInfo(Child);
            if (cinfo == .pointer or cinfo == .@"struct") {
                for (v) |elem| freeValue(Child, gpa, elem);
            }
            gpa.free(v);
        },
        .optional => |opt| {
            if (v) |unwrapped| {
                freeValue(opt.child, gpa, unwrapped);
            }
        },
        .@"struct" => freeStruct(FT, gpa, v),
        else => {}, // scalars, enums — no allocation to free.
    }
}

fn freeValue(comptime T: type, gpa: std.mem.Allocator, value: T) void {
    const info = @typeInfo(T);
    switch (info) {
        .pointer => |ptr| {
            if (ptr.size == .slice and value.len > 0) {
                const Child = ptr.child;
                const cinfo = @typeInfo(Child);
                if (cinfo == .pointer or cinfo == .@"struct") {
                    for (value) |elem| freeValue(Child, gpa, elem);
                }
                gpa.free(value);
            }
        },
        .@"struct" => freeStruct(T, gpa, value),
        else => {},
    }
}

// ─── internals ───────────────────────────────────────────────────────────────

const KnownOsFile = enum { macos, linux, windows };

const OVERRIDE_DROPPED_MESSAGE =
    "per-OS override file present but the build target has no override mapping; the file is being ignored";

fn targetKnownOs(t: std.Target.Os.Tag) ?KnownOsFile {
    return switch (t) {
        .macos => .macos,
        .linux => .linux,
        .windows => .windows,
        else => null,
    };
}

fn matchKnownOsOverride(basename: []const u8) ?KnownOsFile {
    if (std.mem.eql(u8, basename, "zigware.macos.zon")) return .macos;
    if (std.mem.eql(u8, basename, "zigware.linux.zon")) return .linux;
    if (std.mem.eql(u8, basename, "zigware.windows.zon")) return .windows;
    return null;
}

fn mirrorZonDiagnostic(
    gpa: std.mem.Allocator,
    out: *Diagnostics,
    src: *const std.zon.parse.Diagnostics,
    file_path: []const u8,
    message: []const u8,
) std.mem.Allocator.Error!void {
    // Render the std.zon diagnostic stream into a path string of the form
    // "<file_path>: <zon-diag>". The Diagnostic contract says `path` is
    // heap-built and Diagnostics.deinit frees it; `message` is a static
    // template owned by the call site.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    // Allocating writer surfaces OOM through writer.err; the only writer
    // error returned is WriteFailed, which we mirror as OutOfMemory.
    aw.writer.writeAll(file_path) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    aw.writer.writeAll(": ") catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    src.format(&aw.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    const path_owned = try gpa.dupe(u8, aw.writer.buffered());
    errdefer gpa.free(path_owned);
    try out.add(gpa, .{
        .code = .zon_parse_error,
        .message = message,
        .path = path_owned,
    });
}

/// Shared pipeline for both entry points once the base source is in memory and
/// the override choice has been made.
fn parsePipeline(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    base_src: [:0]const u8,
    selected: ?KnownOsFile,
    optimize: std.builtin.OptimizeMode,
    diag: *Diagnostics,
) LoadError!Manifest {
    // Parse base.
    var zon_diag: std.zon.parse.Diagnostics = .{};
    defer zon_diag.deinit(gpa);
    const base = std.zon.parse.fromSliceAlloc(Manifest, gpa, base_src, &zon_diag, .{}) catch |err| switch (err) {
        error.ParseZon => {
            try mirrorZonDiagnostic(gpa, diag, &zon_diag, "zigware.zon", "base manifest failed to parse");
            return error.ParseFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    var base_owned: ?Manifest = base;
    errdefer if (base_owned) |b| freeManifest(gpa, b);

    // Parse override if selected.
    var override_value: ?OverrideManifest = null;
    if (selected) |kof| {
        const ov_name = switch (kof) {
            .macos => "zigware.macos.zon",
            .linux => "zigware.linux.zon",
            .windows => "zigware.windows.zon",
        };
        const ov_src = root_dir.readFileAllocOptions(
            io,
            ov_name,
            gpa,
            .limited(READ_LIMIT_BYTES),
            .of(u8),
            0,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // Recognised in the dir scan, vanished before we read it.
                try diag.add(gpa, .{
                    .code = .override_for_target_dropped,
                    .is_error = true,
                    .message = "selected per-OS override file could not be read",
                    .path = null,
                });
                return error.ParseFailed;
            },
        };
        defer gpa.free(ov_src);

        var ov_zon_diag: std.zon.parse.Diagnostics = .{};
        defer ov_zon_diag.deinit(gpa);
        override_value = std.zon.parse.fromSliceAlloc(OverrideManifest, gpa, ov_src, &ov_zon_diag, .{}) catch |err| switch (err) {
            error.ParseZon => {
                try mirrorZonDiagnostic(gpa, diag, &ov_zon_diag, ov_name, "per-OS override failed to parse");
                return error.ParseFailed;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    defer if (override_value) |ov| std.zon.parse.free(gpa, ov);

    const ids = try listCapabilityIds(gpa, io, root_dir);
    defer {
        for (ids) |s| gpa.free(s);
        gpa.free(ids);
    }

    const merged = try merge.merge(gpa, base_owned.?, override_value);
    // merge returns a fully gpa-owned deep-dup; the base allocation is
    // disposable on the success path. (On error the errdefer above still fires.)
    freeManifest(gpa, base_owned.?);
    base_owned = null;

    if (!(try validate.validate(gpa, merged, optimize, ids, diag)) or diag.hasErrors()) {
        freeManifest(gpa, merged);
        return error.ValidationFailed;
    }

    return merged;
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "listCapabilityIds returns empty when the directory is absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try std.Io.Dir.cwd().openDir(io, "tests/manifest/missing", .{});
    defer fixture.close(io);
    const ids = try listCapabilityIds(gpa, io, fixture);
    defer {
        for (ids) |s| gpa.free(s);
        gpa.free(ids);
    }
    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "parseAtBuild returns FileNotFound when zigware.zon is absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try std.Io.Dir.cwd().openDir(io, "tests/manifest/missing", .{});
    defer fixture.close(io);

    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);

    try std.testing.expectError(
        error.FileNotFound,
        parseAtBuild(gpa, io, fixture, .macos, .Debug, &diag),
    );
}

test "parseAtBuildFromPaths selects the override matching target_os" {
    // Setup: base is valid; the linux override is malformed; the macos override
    // is valid. With target_os=.linux, the malformed linux override must be the
    // one selected, surfacing as error.ParseFailed. If selection wrongly fell
    // back to macos (or no override) the call would succeed. This discriminates
    // selection without depending on the (stubbed) merge to apply the override.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const overrides = [_][]const u8{
        "tests/manifest/override-select/zigware.linux.zon",
        "tests/manifest/override-select/zigware.macos.zon",
    };

    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);

    try std.testing.expectError(
        error.ParseFailed,
        parseAtBuildFromPaths(
            gpa,
            io,
            "tests/manifest/override-select/zigware.zon",
            &overrides,
            &.{},
            .linux,
            .Debug,
            &diag,
        ),
    );
}

test "parseAtBuildFromPaths applies the selected override via merge" {
    // The well-formed corpus has a valid base AND valid per-OS overrides,
    // so the selection result reaches merge. With target_os=.linux, the
    // merged productName must come from the linux override.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const overrides = [_][]const u8{
        "tests/manifest/parseatbuild_override/zigware.linux.zon",
        "tests/manifest/parseatbuild_override/zigware.macos.zon",
    };

    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);

    const m = try parseAtBuildFromPaths(
        gpa,
        io,
        "tests/manifest/parseatbuild_override/zigware.zon",
        &overrides,
        &.{},
        .linux,
        .Debug,
        &diag,
    );
    defer freeManifest(gpa, m);

    try std.testing.expectEqualStrings("LinuxProduct", m.productName);
}

test "parseAtBuild selects the override matching target_os" {
    // The io.Dir variant discovers overrides by scanning the directory.
    // With target_os=.macos, the merged productName must come from the
    // macos override.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fixture = try std.Io.Dir.cwd().openDir(
        io,
        "tests/manifest/parseatbuild_override",
        .{},
    );
    defer fixture.close(io);

    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);

    const m = try parseAtBuild(gpa, io, fixture, .macos, .Debug, &diag);
    defer freeManifest(gpa, m);

    try std.testing.expectEqualStrings("MacOsProduct", m.productName);
}

test "parseAtBuild emits override_for_target_dropped per recognized override when target has no mapping" {
    // target_os=.freebsd has no override mapping. Both zigware.linux.zon
    // and zigware.macos.zon are recognised, so the dir scan must emit one
    // warning per recognised override file. The result is still a valid
    // Manifest (the base parses and validates).
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fixture = try std.Io.Dir.cwd().openDir(
        io,
        "tests/manifest/parseatbuild_override",
        .{},
    );
    defer fixture.close(io);

    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);

    const m = try parseAtBuild(gpa, io, fixture, .freebsd, .Debug, &diag);
    defer freeManifest(gpa, m);

    var dropped: usize = 0;
    for (diag.items.items) |d| {
        if (d.code == .override_for_target_dropped) dropped += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), dropped);
    try std.testing.expect(!diag.hasErrors());
}

test "parseAtBuild silently ignores unrelated files in the dir" {
    // The fixture contains a stray README.md. The dir scan must skip any
    // file whose basename does not match `zigware.<known_os>.zon`. With a
    // matched target_os, no override_for_target_dropped warnings should
    // fire at all (the stray file is invisible to the scan).
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fixture = try std.Io.Dir.cwd().openDir(
        io,
        "tests/manifest/parseatbuild_override",
        .{},
    );
    defer fixture.close(io);

    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);

    const m = try parseAtBuild(gpa, io, fixture, .macos, .Debug, &diag);
    defer freeManifest(gpa, m);

    var dropped: usize = 0;
    for (diag.items.items) |d| {
        if (d.code == .override_for_target_dropped) dropped += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), dropped);
}

test "parseAtBuildFromPaths emits override_for_target_dropped per supplied override when target_os has no mapping" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const overrides = [_][]const u8{
        "tests/manifest/override/zigware.linux.zon",
        "tests/manifest/override/zigware.macos.zon",
    };

    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);

    const m = try parseAtBuildFromPaths(
        gpa,
        io,
        "tests/manifest/override/zigware.zon",
        &overrides,
        &.{},
        .freebsd,
        .Debug,
        &diag,
    );
    defer freeManifest(gpa, m);

    var dropped: usize = 0;
    for (diag.items.items) |d| {
        if (d.code == .override_for_target_dropped) dropped += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), dropped);
    try std.testing.expect(!diag.hasErrors());
}

test "parseAtBuildFromPaths returns ParseFailed with one mirrored zon Diagnostic when the base file is malformed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);

    try std.testing.expectError(
        error.ParseFailed,
        parseAtBuildFromPaths(
            gpa,
            io,
            "tests/manifest/malformed/zigware.zon",
            &.{},
            &.{},
            .macos,
            .Debug,
            &diag,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), diag.items.items.len);
}

test "std.zon.parse.free is safe on a parsed OverrideManifest" {
    // The override path frees OverrideManifest via std.zon.parse.free; the
    // Manifest crash condition (defaulted static-literal slices) does NOT
    // apply because every OverrideManifest leaf defaults to null and arrays
    // default to null too. Prove the safety empirically rather than relying
    // on reasoning, since this code is run on the production override path
    // before any Task 5 test selects a valid override.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const src = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        "tests/manifest/override/zigware.linux.zon",
        gpa,
        .limited(READ_LIMIT_BYTES),
        .of(u8),
        0,
    );
    defer gpa.free(src);
    var zon_diag: std.zon.parse.Diagnostics = .{};
    defer zon_diag.deinit(gpa);
    const ov = try std.zon.parse.fromSliceAlloc(OverrideManifest, gpa, src, &zon_diag, .{});
    std.zon.parse.free(gpa, ov);
}

test "freeManifest skips static-default slices via pointer identity" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try std.Io.Dir.cwd().openDir(io, "tests/manifest/good", .{});
    defer fixture.close(io);

    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);

    const m = try parseAtBuild(gpa, io, fixture, .macos, .Debug, &diag);

    // The fixture supplies only the required fields. The default static-literal
    // slices on Manifest (e.g. MacOsBundle.minimumSystemVersion = "11.0") must
    // remain identity-equal to the comptime default's data pointer.
    try std.testing.expect(
        m.bundle.macos.minimumSystemVersion.ptr == (types.MacOsBundle{}).minimumSystemVersion.ptr,
    );

    // Call freeManifest under the testing allocator. The static-default skip
    // rule must prevent any invalid-free; the testing allocator panics on
    // double-free or invalid-pointer free, so reaching the next line is the
    // assertion.
    freeManifest(gpa, m);
}
