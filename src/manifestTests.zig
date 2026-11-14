const std = @import("std");

test {
    _ = @import("manifest/types.zig");
    _ = @import("manifest/parse.zig");
    _ = @import("manifest/capabilities.zig");
    _ = @import("manifest/validate.zig");
    _ = @import("manifest/merge.zig");
    _ = @import("manifest/schemaGeneration.zig");
    _ = @import("manifest/fuses.zig");
}

test "manifest test root mounted" {
    try std.testing.expect(@typeInfo(@import("manifest/types.zig").Manifest).@"struct".fields.len >= 4);
}

// Parser/validator robustness fuzz with deterministic three-counter teeth.
//
// The manifest happy-path is narrow: a single random byte twist of a valid
// .zon overwhelmingly produces an invalid one (either parse OR validate
// fails). A purely random fuzz would be flaky on the `valid_parses` arm.
//
// Every 16th iteration feeds the PRISTINE valid seed unmutated, so
// `valid_parses` increments deterministically regardless of the harness's
// random_seed. The remaining iterations drive `parse_failures` and
// `validation_failures`.
//
// All three counters are asserted positive AFTER the loop ("teeth check"):
// a fuzz vocabulary that degenerates to single-arm coverage fails loudly.
//
// The pristine seed uses a single-line string literal to avoid the Zig
// multi-line raw-string-array continuation ambiguity (where \\-lines glue
// based on indentation and a stray separator could split one logical seed
// into two invalid ones, killing the `valid_parses` arm).
//
// Parsed manifests are freed via `parse.freeManifest` (which honors the
// static-default-slice skip rule). `std.zon.parse.free` is NOT safe on
// Manifest: it would walk the static-literal default pointers and call
// gpa.free on them.
//
// This is a robustness fuzz over the author-trust boundary (zigware.zon is
// author-controlled), not adversarial. The teeth check exists to detect
// coverage rot, not security.
test "fuzz parser+validator: deterministic teeth on parse/validate/valid arms" {
    const types = @import("manifest/types.zig");
    const validate = @import("manifest/validate.zig");
    const parse_mod = @import("manifest/parse.zig");

    const gpa = std.testing.allocator;

    // Single-line .zon literal: required + a "main" window with non-empty
    // title. Slices use plain tuple `.{ ... }` (not `&.{ ... }`).
    const pristine: [:0]const u8 =
        ".{ .identifier = \"com.example.a\", .productName = \"A\", .version = \"0.1.0\", .app = .{ .windows = .{ .{ .label = \"main\", .title = \"M\" } } } }";

    // Multiple of 16 so the threshold math `iters / 16` is exact.
    const iters: usize = 10240;

    errdefer std.debug.print("manifest robustness fuzz seed: {d}\n", .{std.testing.random_seed});
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();

    var parse_failures: usize = 0;
    var validation_failures: usize = 0;
    var valid_parses: usize = 0;

    var mutbuf: [4096:0]u8 = undefined;

    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const candidate: [:0]const u8 = if (i % 16 == 0) blk: {
            break :blk pristine;
        } else blk: {
            const len = @min(pristine.len, mutbuf.len);
            @memcpy(mutbuf[0..len], pristine[0..len]);
            mutbuf[len] = 0;
            // 1-3 random single-byte writes.
            var k: usize = 0;
            const muts = rand.uintLessThan(usize, 3) + 1;
            while (k < muts) : (k += 1) {
                const pos = rand.uintLessThan(usize, len);
                mutbuf[pos] = rand.int(u8);
            }
            break :blk @as([:0]const u8, mutbuf[0..len :0]);
        };

        var zon_diag: std.zon.parse.Diagnostics = .{};
        defer zon_diag.deinit(gpa);

        const parsed = std.zon.parse.fromSliceAlloc(types.Manifest, gpa, candidate, &zon_diag, .{}) catch |err| switch (err) {
            error.ParseZon => {
                parse_failures += 1;
                continue;
            },
            error.OutOfMemory => return err,
        };
        // Manifest free is reflection-driven and skips static-default slices
        // via pointer-identity; safe on every accepted parse.
        defer parse_mod.freeManifest(gpa, parsed);

        var diag: types.Diagnostics = .{};
        defer diag.deinit(gpa);

        const caps_empty: []const []const u8 = &.{};
        const ok = try validate.validate(gpa, parsed, .Debug, caps_empty, &diag);
        if (!ok or diag.hasErrors()) {
            validation_failures += 1;
        } else {
            valid_parses += 1;
        }
    }

    // Teeth: every arm must fire. Pristine arm makes `valid_parses` deterministic.
    try std.testing.expect(parse_failures > 0);
    try std.testing.expect(validation_failures > 0);
    try std.testing.expect(valid_parses >= iters / 16);
}

// Two-direction manifest fuzz. The robustness fuzz above only checks that
// nothing crashes. These two tests check the accept decision itself.
//
// False-negative oracle: every manifest built by the generator is valid by
// construction, so the parser and validator must accept all of them.
// False-positive oracle: every mutant below is invalid by construction (an old
// snake_case key, an unknown key, or a misspelled required key), so the parser
// must reject all of them. A failing test prints its seed. A passing test must stay
// silent: the build runner fails a step whose test writes to stderr. To replay a
// failure, pass the printed seed to the test binary as `--seed`.

const Verdict = enum { parse_rejected, validate_rejected, accepted };

/// Runs `text` through the production entry point, `parseAtBuildFromPaths`, so a
/// change to the real parse options is seen by the oracles below.
fn judge(gpa: std.mem.Allocator, dir: *std.testing.TmpDir, text: []const u8) !Verdict {
    const parse_mod = @import("manifest/parse.zig");
    const types = @import("manifest/types.zig");
    const io = std.testing.io;

    try dir.dir.writeFile(io, .{ .sub_path = "zigware.zon", .data = text });
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/zigware.zon", .{dir.sub_path});

    var diag: types.Diagnostics = .{};
    defer diag.deinit(gpa);
    const parsed = parse_mod.parseAtBuildFromPaths(gpa, io, path, &.{}, &.{}, .macos, .Debug, &diag) catch |err| switch (err) {
        error.ParseFailed => return .parse_rejected,
        error.ValidationFailed => return .validate_rejected,
        else => return err,
    };
    parse_mod.freeManifest(gpa, parsed);
    return .accepted;
}

/// A lowercase word of 1 to 8 characters that starts with a letter. The result
/// is a valid reverse-DNS label, window label, command name and path segment.
fn genWord(rand: std.Random, buf: *[8]u8) []const u8 {
    const letters = "abcdefghijklmnopqrstuvwxyz";
    const alnum = letters ++ "0123456789";
    const len = rand.uintLessThan(usize, 8) + 1;
    buf[0] = letters[rand.uintLessThan(usize, letters.len)];
    for (buf[1..len]) |*c| c.* = alnum[rand.uintLessThan(usize, alnum.len)];
    return buf[0..len];
}

/// Builds a valid manifest. With `full` set it always declares one permission
/// that uses all four permission keys, so a mutator can find each key.
fn genValidManifest(gpa: std.mem.Allocator, rand: std.Random, full: bool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    var b1: [8]u8 = undefined;
    var b2: [8]u8 = undefined;
    var b3: [8]u8 = undefined;
    var b4: [8]u8 = undefined;
    try w.print(".{{ .identifier = \"com.{s}.{s}\", .productName = \"{s}\", .version = \"{d}.{d}.{d}\", ", .{
        genWord(rand, &b1),
        genWord(rand, &b2),
        genWord(rand, &b3),
        rand.uintLessThan(u8, 50),
        rand.uintLessThan(u8, 50),
        rand.uintLessThan(u8, 50),
    });
    try w.print(".app = .{{ .windows = .{{ .{{ .label = \"main\", .title = \"{s}\" }}", .{genWord(rand, &b4)});
    if (rand.boolean()) try w.print(", .{{ .label = \"x{s}\", .title = \"T\" }}", .{genWord(rand, &b1)});
    try w.writeAll(" } }");
    if (full or rand.boolean()) {
        try w.print(", .security = .{{ .permissions = .{{ .{{ .identifier = \"app:{s}\", .commandsAllow = .{{ \"{s}\" }}", .{ genWord(rand, &b1), genWord(rand, &b2) });
        if (full or rand.boolean()) try w.print(", .commandsDeny = .{{ \"{s}\" }}", .{genWord(rand, &b3)});
        if (full or rand.boolean()) try w.print(", .scopeAllow = .{{ .{{ .path = \"$APPDATA/{s}/**\" }} }}", .{genWord(rand, &b4)});
        if (full or rand.boolean()) try w.print(", .scopeDeny = .{{ .{{ .path = \"$APPDATA/{s}/**\" }} }}", .{genWord(rand, &b1)});
        try w.writeAll(" } } }");
    }
    try w.writeAll(" }");
    return aw.toOwnedSlice();
}

const old_key_renames = [_]struct { new: []const u8, old: []const u8 }{
    .{ .new = ".commandsAllow = ", .old = ".commands_allow = " },
    .{ .new = ".commandsDeny = ", .old = ".commands_deny = " },
    .{ .new = ".scopeAllow = ", .old = ".scope_allow = " },
    .{ .new = ".scopeDeny = ", .old = ".scope_deny = " },
};

test "fuzz manifest false-negative oracle: valid generated manifests are always accepted" {
    const gpa = std.testing.allocator;
    errdefer std.debug.print("manifest false-negative fuzz seed: {d}\n", .{std.testing.random_seed});
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const text = try genValidManifest(gpa, rand, i % 2 == 0);
        defer gpa.free(text);
        const verdict = try judge(gpa, &dir, text);
        if (verdict != .accepted) {
            std.debug.print("valid manifest was {s}: {s}\n", .{ @tagName(verdict), text });
            return error.TestUnexpectedResult;
        }
    }
}

test "fuzz manifest false-positive oracle: old keys, unknown keys and missing keys are never accepted" {
    const gpa = std.testing.allocator;
    errdefer std.debug.print("manifest false-positive fuzz seed: {d}\n", .{std.testing.random_seed});
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const base = try genValidManifest(gpa, rand, true);
        defer gpa.free(base);

        // Pick the mutation and the exact text to replace.
        const kind = rand.uintLessThan(usize, 4);
        const rename = old_key_renames[rand.uintLessThan(usize, old_key_renames.len)];
        const needle: []const u8 = switch (kind) {
            0 => rename.new,
            1 => ".{ .identifier",
            2 => ".identifier = \"app:",
            else => ".version = ",
        };
        const replacement: []const u8 = switch (kind) {
            0 => rename.old,
            1 => ".{ .fuzzUnknown = 1, .identifier",
            2 => ".fuzzUnknown = 1, .identifier = \"app:",
            else => ".versoin = ",
        };
        const at = std.mem.indexOf(u8, base, needle) orelse {
            std.debug.print("mutation target not found: {s} in {s}\n", .{ needle, base });
            return error.TestUnexpectedResult;
        };
        const mutant = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ base[0..at], replacement, base[at + needle.len ..] });
        defer gpa.free(mutant);

        const verdict = try judge(gpa, &dir, mutant);
        if (verdict == .accepted) {
            std.debug.print("invalid manifest was accepted: {s}\n", .{mutant});
            return error.TestUnexpectedResult;
        }
    }
}
