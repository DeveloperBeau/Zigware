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

    // Required identity fields.
    try std.testing.expectEqualStrings(e.identifier, parsed.identifier);
    try std.testing.expectEqualStrings(e.productName, parsed.productName);
    try std.testing.expectEqualStrings(e.version, parsed.version);

    // --- app ---
    try std.testing.expectEqual(e.app.windows.len, parsed.app.windows.len);
    if (e.app.windows.len > 0) {
        try std.testing.expectEqualStrings(e.app.windows[0].label, parsed.app.windows[0].label);
        try std.testing.expectEqualStrings(e.app.windows[0].title, parsed.app.windows[0].title);
    }
    try std.testing.expectEqual(e.app.quitOnLastWindowClosed, parsed.app.quitOnLastWindowClosed);
    try std.testing.expectEqual(e.app.windowDefaults.width, parsed.app.windowDefaults.width);
    try std.testing.expectEqual(e.app.windowShowFallbackMs, parsed.app.windowShowFallbackMs);

    // --- security ---
    try std.testing.expectEqual(e.security.fuses.allowShell, parsed.security.fuses.allowShell);
    try std.testing.expectEqual(e.security.fuses.allowRemoteContent, parsed.security.fuses.allowRemoteContent);
    try std.testing.expectEqual(e.security.csp.scriptSrc.len, parsed.security.csp.scriptSrc.len);
    if (e.security.csp.scriptSrc.len > 0) {
        try std.testing.expectEqualStrings(e.security.csp.scriptSrc[0], parsed.security.csp.scriptSrc[0]);
    }

    // --- frontend ---
    try std.testing.expectEqualStrings(e.frontend.outDir, parsed.frontend.outDir);
    // Optional left at its default-null: both sides must agree it is absent.
    try std.testing.expectEqual(@as(?[]const u8, null), e.frontend.serveUrl);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.frontend.serveUrl);

    // --- bundle ---
    try std.testing.expectEqual(e.bundle.targets.len, parsed.bundle.targets.len);
    try std.testing.expectEqual(e.bundle.macos.hardenedRuntime, parsed.bundle.macos.hardenedRuntime);
    try std.testing.expectEqualStrings(e.bundle.macos.minimumSystemVersion, parsed.bundle.macos.minimumSystemVersion);
    try std.testing.expectEqual(@as(?[]const u8, null), e.bundle.macos.signingIdentity);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.bundle.macos.signingIdentity);
}
