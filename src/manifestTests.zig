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
