const std = @import("std");
const manifest = @import("../manifest/types.zig");

pub const Fuses = manifest.Fuses;

/// A trusted origin shape (Tauri capability remote-origin analog).
pub const OriginPattern = union(enum) {
    app_scheme, // app:// (the prod origin), always trusted
    dev_url: []const u8, // exact dev origin, honored only in debug builds
    https_exact: []const u8, // explicit https origin, requires allowRemoteContent fuse
};

pub const HostRule = struct { host: []const u8, port: ?u16 = null };

/// Per-resource scope. The union tag IS the scope kind (no separate enum).
pub const Scope = union(enum) {
    path: []const u8, // glob with $APPDATA/$HOME/$APPCONFIG/** tokens
    host: HostRule, // host glob plus optional exact port
    argv: []const u8, // exact argv token (no globbing)
    label: []const u8, // window-label glob (E's window.* value-set scope)
};

/// A single permission grants commands and carries scope. Deny beats allow.
pub const Permission = struct {
    identifier: []const u8, // "<plugin>:<action>", lower-ascii
    commands_allow: []const []const u8 = &.{},
    commands_deny: []const []const u8 = &.{},
    scope_allow: []const Scope = &.{},
    scope_deny: []const Scope = &.{},
};

/// A named bundle of permissions/nested sets so the common case is one line.
pub const PermissionSet = struct {
    identifier: []const u8, // e.g. "core:default"
    members: []const []const u8, // permission or nested-set identifiers
};

/// The authored unit (mirrors a Tauri capability file).
pub const Capability = struct {
    identifier: []const u8, // unique, for diagnostics
    windows: []const []const u8, // window LABEL globs ("main", "win-*", "*")
    origins: []const OriginPattern = &.{}, // empty means {app_scheme} only
    permissions: []const []const u8 = &.{}, // permission or set identifiers
};

/// The catalog of every built-in permission and set, supplied at comptime by
/// defaults.zig (and extensible by D for app-declared permissions).
pub const Catalog = struct {
    permissions: []const Permission,
    sets: []const PermissionSet,

    pub fn permission(self: *const Catalog, id: []const u8) ?*const Permission {
        for (self.permissions) |*p| {
            if (std.mem.eql(u8, p.identifier, id)) return p;
        }
        return null;
    }

    pub fn set(self: *const Catalog, id: []const u8) ?*const PermissionSet {
        for (self.sets) |*s| {
            if (std.mem.eql(u8, s.identifier, id)) return s;
        }
        return null;
    }
};

/// Comptime check (mirrors backend.zig's assertBackend): every member of every
/// set resolves to a permission or another set in the catalog, and there are no
/// set-membership cycles. A typo in defaults.zig fails the BUILD, not at runtime.
pub fn assertCatalog(comptime catalog: Catalog) void {
    comptime {
        for (catalog.sets) |s| {
            for (s.members) |m| {
                const is_perm = blk: {
                    for (catalog.permissions) |p| {
                        if (std.mem.eql(u8, p.identifier, m)) break :blk true;
                    }
                    break :blk false;
                };
                const is_set = blk: {
                    for (catalog.sets) |s2| {
                        if (std.mem.eql(u8, s2.identifier, m)) break :blk true;
                    }
                    break :blk false;
                };
                if (!is_perm and !is_set)
                    @compileError("catalog set '" ++ s.identifier ++ "' references unknown member '" ++ m ++ "'");
            }
            // Cycle detection: walk this set's transitive members with a bounded
            // depth; a set reachable from itself is a cycle.
            assertNoCycle(catalog, s.identifier, s.identifier, 0);
        }
    }
}

fn assertNoCycle(comptime catalog: Catalog, comptime root: []const u8, comptime current: []const u8, comptime depth: usize) void {
    comptime {
        if (depth > catalog.sets.len + 1)
            @compileError("catalog set membership cycle through '" ++ root ++ "'");
        const s = for (catalog.sets) |s2| {
            if (std.mem.eql(u8, s2.identifier, current)) break s2;
        } else return; // current is a permission, not a set: leaf, no cycle
        for (s.members) |m| {
            if (std.mem.eql(u8, m, root) and depth > 0)
                @compileError("catalog set membership cycle through '" ++ root ++ "'");
            assertNoCycle(catalog, root, m, depth + 1);
        }
    }
}

test "Catalog.permission / set resolve by identifier" {
    const cat = Catalog{
        .permissions = &.{.{ .identifier = "fs:read", .commands_allow = &.{"fs.readFile"} }},
        .sets = &.{.{ .identifier = "fs:default", .members = &.{"fs:read"} }},
    };
    try std.testing.expect(cat.permission("fs:read") != null);
    try std.testing.expect(cat.permission("nope") == null);
    try std.testing.expect(cat.set("fs:default") != null);
    try std.testing.expect(cat.set("fs:read") == null);
}

test "assertCatalog accepts a well-formed catalog" {
    const cat = Catalog{
        .permissions = &.{
            .{ .identifier = "a:x" },
            .{ .identifier = "a:y" },
        },
        .sets = &.{
            .{ .identifier = "a:inner", .members = &.{"a:x"} },
            .{ .identifier = "a:default", .members = &.{ "a:inner", "a:y" } },
        },
    };
    assertCatalog(cat); // comptime; if it returns, the contract holds
    try std.testing.expect(true);
}

test "assertCatalog rejection is verified out-of-band (see comment)" {
    // A live @compileError cannot sit in a passing test body (same pattern as
    // backend.zig:173). To confirm assertCatalog rejects, uncomment ONE locally
    // and run `zig build test`; each must fail to compile:
    //   const BadMember = Catalog{ .permissions = &.{}, .sets = &.{.{ .identifier = "s", .members = &.{"missing"} }} };
    //   assertCatalog(BadMember); // expected: "references unknown member 'missing'"
    //   const Cycle = Catalog{ .permissions = &.{}, .sets = &.{
    //       .{ .identifier = "s1", .members = &.{"s2"} },
    //       .{ .identifier = "s2", .members = &.{"s1"} },
    //   }};
    //   assertCatalog(Cycle); // expected: "membership cycle"
    try std.testing.expect(true);
}
