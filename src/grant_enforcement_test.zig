//! Build-time grant-loading enforcement test. Walks the renamed surface end to
//! end: parseAtBuild (reads zigware.zon, cross-checks security.grants against the
//! present src/grants/*.zon ids) -> loadCapabilities (parses each src/grants/*.zon
//! body) -> filter to the manifest's referenced grant ids -> GrantTable.compile
//! against the runtime catalog -> commandGranted. The live runtime enforces via
//! synthAppGrants (src/app.zig), which ignores manifest.security.grants and
//! loadCapabilities, so this is the only coverage of the build-time grant edge.

const std = @import("std");
const parse = @import("manifest/parse.zig");
const caps_loader = @import("manifest/capabilities.zig");
const grant = @import("security/grant_table.zig");
const app_catalog = @import("app_catalog.zig");
const types = @import("manifest/types.zig");

const Capability = caps_loader.Capability;

test "build-time grant loading authorizes a granted command and denies others" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fixture = try std.Io.Dir.cwd().openDir(io, "tests/manifest/grants_enforcement", .{});
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
        &app_catalog.runtime_catalog,
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
