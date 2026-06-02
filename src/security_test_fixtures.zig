//! Shared test-only capability fixtures for the bridge/app/sec_regression test
//! harnesses. The live App grants only `core:default`, so the builtin demo
//! commands (sha256/echoBytes/echo) are denied at G2. Tests that drive those
//! commands build a GrantTable from this fixture catalog instead, so the
//! bridge/registry tests stay meaningful. Imported (not addLogicTest'd) by the
//! test blocks; it carries no tests of its own.

const std = @import("std");
const cap = @import("security/capability.zig");
const grant = @import("security/grant_table.zig");
const defaults = @import("security/defaults.zig");
const manifest = @import("manifest/types.zig");

pub const GrantTable = grant.GrantTable;

/// A test catalog that grants the builtin fixture commands under one permission,
/// plus core:default, so the existing harness tests still drive sha256/echoBytes/echo.
// NOTE: `array ++ array` yields an ARRAY; assigning it to a `[]const T` slice
// field needs `&(...)` to coerce.
pub const test_catalog = cap.Catalog{
    .permissions = &(defaults.builtin_permissions ++ [_]cap.Permission{
        .{ .identifier = "test:fixtures", .commands_allow = &.{ "sha256", "echoBytes", "echo" } },
    }),
    .sets = &(defaults.builtin_sets ++ [_]cap.PermissionSet{
        .{ .identifier = "test:default", .members = &.{ "core:default", "test:fixtures" } },
    }),
};

/// Build a single-cap GrantTable for "main" granting the fixture commands with an
/// app_scheme origin. Caller owns the returned table: `gt.deinit()` then
/// `alloc.destroy(gt)`. Allocator-parameterized so OOM-injection harnesses can
/// build it on their failing/limited allocator; a compile-OOM frees the create.
pub fn buildTestGrants(alloc: std.mem.Allocator) !*GrantTable {
    const gt = try alloc.create(GrantTable);
    errdefer alloc.destroy(gt);
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(alloc);
    const caps = [_]cap.Capability{.{ .identifier = "test", .windows = &.{"main"}, .origins = &.{.app_scheme}, .permissions = &.{"test:default"} }};
    gt.* = try GrantTable.compile(alloc, &caps, &test_catalog, .{}, &.{"main"}, &diags);
    return gt;
}
