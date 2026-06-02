//! Comptime-embed agreement test. Proves the build-time loader path
//! (`parseAtBuild`) and the runtime accessor (`embedded()`) agree on the
//! same source bytes.
//!
//! This module is wired in build.zig with its OWN anonymous import for
//! `zigware_manifest_zon`, pointing at `tests/manifest/embed_fixture/zigware.zon`.
//! The production wire (the merged effective manifest) is NOT used here; the
//! embed-agreement contract is between the fixture file and parseAtBuild over
//! the same fixture directory, so the comparison stays well-defined.

const std = @import("std");
const parse = @import("parse.zig");
const types = @import("types.zig");

test "embedded() equals parseAtBuild over the same source fixture" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fixture_dir = try std.Io.Dir.cwd().openDir(io, "tests/manifest/embed_fixture", .{});
    defer fixture_dir.close(io);

    var diag: types.Diagnostics = .{};
    defer diag.deinit(gpa);

    const parsed = try parse.parseAtBuild(gpa, io, fixture_dir, .macos, .Debug, &diag);
    defer parse.freeManifest(gpa, parsed);

    // embedded() is comptime-static; never freed.
    const e = parse.embedded();

    // Required fields.
    try std.testing.expectEqualStrings(e.identifier, parsed.identifier);
    try std.testing.expectEqualStrings(e.productName, parsed.productName);
    try std.testing.expectEqualStrings(e.version, parsed.version);

    // App.windows shape.
    try std.testing.expectEqual(e.app.windows.len, parsed.app.windows.len);
    if (e.app.windows.len > 0) {
        try std.testing.expectEqualStrings(e.app.windows[0].label, parsed.app.windows[0].label);
        try std.testing.expectEqualStrings(e.app.windows[0].title, parsed.app.windows[0].title);
    }

    // Defaulted leaves that the validator depends on.
    try std.testing.expectEqual(e.security.fuses.allowShell, parsed.security.fuses.allowShell);
    try std.testing.expectEqualStrings(e.build.frontendDist, parsed.build.frontendDist);
}
