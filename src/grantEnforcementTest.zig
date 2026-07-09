//! Build-time grant-loading enforcement test. Walks the surface end to end:
//! parseAtBuild (reads zigware.zon, cross-checks security.grants against the
//! present src/grants/*.zon ids) -> loadCapabilities (parses each src/grants/*.zon
//! body) -> filter to the manifest's referenced grant ids -> GrantTable.compile
//! against the runtime catalog -> commandGranted. This mirrors the LIVE path: the
//! manifest codegen emits the same referenced capabilities as zigware_grants_zon,
//! and app.zig builds the runtime table from them via buildGrantsFromCaps. This
//! test pins the build-time half (loader + filter + compile) that the live embed
//! rides on.

const std = @import("std");
const parse = @import("manifest/parse.zig");
const caps_loader = @import("manifest/capabilities.zig");
const grant = @import("security/grantTable.zig");
const cap = @import("security/capability.zig");
const defaults = @import("security/defaults.zig");
const types = @import("manifest/types.zig");

// Test catalog: built-in permissions plus a scoped hashFile entry used by the
// grant-enforcement fixture. The notes app now declares the equivalent via its
// manifest; this local copy keeps the framework test self-contained.
const hashfile_test_catalog = cap.Catalog{
    .permissions = &(defaults.builtin_permissions ++ [_]cap.Permission{.{
        .identifier = "app:hashFile",
        .commandsAllow = &.{"hashFile"},
        .scopeAllow = &.{.{ .path = "$APPDATA/notes/**" }},
    }}),
    .sets = &defaults.builtin_sets,
};

const Capability = caps_loader.Capability;

test "build-time grant loading authorizes a granted command and denies others" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fixture = try std.Io.Dir.cwd().openDir(io, "tests/manifest/grantsEnforcement", .{});
    defer fixture.close(io);

    // 1. parseAtBuild reads zigware.zon and validates security.grants against the
    //    present src/grants/*.zon basenames ("main"), returning the merged manifest.
    var diag: types.Diagnostics = .{};
    defer diag.deinit(gpa);
    const m = try parse.parseAtBuild(gpa, io, fixture, .macos, .Debug, &diag);
    defer parse.freeManifest(gpa, m);
    try std.testing.expect(!diag.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), m.security.grants.len);
    try std.testing.expectEqualStrings("main", m.security.grants[0]);

    // 2. loadCapabilities parses each src/grants/*.zon body into a Capability.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const loaded = try caps_loader.loadCapabilities(arena, io, fixture);

    // 3. Filter the loaded grants down to the manifest's referenced ids.
    var referenced: std.ArrayList(Capability) = .empty;
    defer referenced.deinit(arena);
    for (loaded) |c| {
        for (m.security.grants) |id| {
            if (std.mem.eql(u8, c.identifier, id)) {
                try referenced.append(arena, c);
                break;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), referenced.items.len);

    // 4. Compile the grant table against the runtime catalog (built-in permissions
    //    plus the app-declared app:hashFile the "main" grant references).
    var compile_diag: types.Diagnostics = .{};
    defer compile_diag.deinit(gpa);
    const labels = [_][]const u8{"main"};
    var table = try grant.GrantTable.compile(
        gpa,
        referenced.items,
        &hashfile_test_catalog,
        m.security.fuses,
        &labels,
        &compile_diag,
    );
    defer table.deinit();
    // compile() emits capability_window_unknown / fuse_requires_capability as
    // diagnostics rather than errors; a clean compile must surface none, else the
    // table below would be silently partial.
    try std.testing.expect(!compile_diag.hasErrors());

    // 5. G2: the granted command is authorized; an ungranted one is denied
    //    (deny-by-default), and an unmatched window denies the granted command too.
    try std.testing.expect(table.commandGranted("main", "hashFile"));
    try std.testing.expect(!table.commandGranted("main", "deleteEverything"));
    try std.testing.expect(!table.commandGranted("other", "hashFile"));
}

test "security data types live in the manifest layer and re-export from capability" {
    try std.testing.expect(types.Permission == cap.Permission);
    try std.testing.expect(types.Scope == cap.Scope);
    try std.testing.expect(types.HostRule == cap.HostRule);
}
