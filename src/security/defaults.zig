const std = @import("std");
const cap = @import("capability.zig");
const Permission = cap.Permission;
const PermissionSet = cap.PermissionSet;
const Catalog = cap.Catalog;

// Built-in permissions. Identifiers follow <plugin>:<action>, lower-ascii.
// Command names are the framework-reserved command identifiers later sub-projects
// register (window.*, dialog.*, compute.*). fs/http/shell carry scope; the core
// window/dialog/compute perms either carry no scope (.none commands) or a scope
// kind they own. v0.1.0 ships the IDENTIFIERS and command grants; the commands
// themselves are registered by E (window.*), H (compute.*), and later fs/http/shell.
pub const builtin_permissions = [_]Permission{
    // Filesystem (scoped by path globs). Commands wired by a later fs plugin.
    .{ .identifier = "fs:read", .commands_allow = &.{ "fs.readFile", "fs.readDir" } },
    .{ .identifier = "fs:write", .commands_allow = &.{ "fs.writeFile", "fs.createDir" } },
    // Dialog: user-mediated, no path scope (the user picks the path).
    .{ .identifier = "dialog:open", .commands_allow = &.{ "dialog.open", "dialog.save" } },
    // Shell (strict argv allowlist). Dropped at compile when allowShell is off.
    .{ .identifier = "shell:execute", .commands_allow = &.{"shell.execute"} },
    // Network (host/port scope). Dropped origins handled at G1, not here.
    .{ .identifier = "http:request", .commands_allow = &.{"http.fetch"} },
    // Core window controls for the window's OWN label (no cross-window scope).
    .{ .identifier = "core:window:own", .commands_allow = &.{ "window.setTitle", "window.setSize" } },
    // Core compute: the public compute surface plus cancellation. No external
    // resource, so .none scope.
    .{ .identifier = "core:compute:cancel", .commands_allow = &.{"compute.cancel"} },
};

// The shipped default bundle: only safe, ambient-free commands. NO fs/http/shell.
pub const builtin_sets = [_]PermissionSet{
    .{ .identifier = "core:default", .members = &.{ "core:window:own", "dialog:open", "core:compute:cancel" } },
};

pub const builtin_catalog = Catalog{
    .permissions = &builtin_permissions,
    .sets = &builtin_sets,
};

// Prove at comptime that every core:default member (and every set member)
// resolves. A typo here fails the build.
comptime {
    cap.assertCatalog(builtin_catalog);
}

test "builtin_catalog: core:default resolves and grants no fs/http/shell" {
    const cat = builtin_catalog;
    const def = cat.set("core:default").?;
    // core:default members are all present in the catalog.
    for (def.members) |m| {
        try std.testing.expect(cat.permission(m) != null or cat.set(m) != null);
    }
    // core:default does NOT directly include fs/http/shell families.
    for (def.members) |m| {
        try std.testing.expect(!std.mem.startsWith(u8, m, "fs:"));
        try std.testing.expect(!std.mem.startsWith(u8, m, "http:"));
        try std.testing.expect(!std.mem.startsWith(u8, m, "shell:"));
    }
}

test "builtin permissions include the scoped families for later sub-projects" {
    const cat = builtin_catalog;
    try std.testing.expect(cat.permission("fs:read") != null);
    try std.testing.expect(cat.permission("shell:execute") != null);
    try std.testing.expect(cat.permission("http:request") != null);
}
