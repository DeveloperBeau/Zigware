//! Runtime permission catalog assembly for the App.
//!
//! `GrantTable.compile` resolves every capability's referenced permission ids
//! against a `Catalog`. The framework bundle (`defaults.builtin_catalog`) covers
//! the built-in `core:*`/`fs:*`/`http:*`/`shell:*` permissions, but an app that
//! grants its OWN command (e.g. the notes example's `hashFile`, scoped to a path
//! glob) needs that permission present in the catalog `compile` reads, or
//! `resolvePerm` errors `UnknownPermission`.
//!
//! This file owns the app-declared permission as a static comptime literal and
//! the runtime `Catalog` that splices it onto the built-in sets. Static literals
//! mean the underlying strings (`"hashFile"`, the path glob) outlive the
//! `GrantTable` for the App's lifetime: `compile` copies slice/array HEADERS by
//! reference (grant_table.zig:210-213), so G4 dereferences these exact bytes on
//! every live invocation and they must never be freed/stack-temporary.
//!
//! Adding the permission to the catalog is additive and behavior-neutral: it is
//! resolved ONLY when a capability references its identifier. The framework's
//! synthesized `core:default` cap does not, so every existing init()-path test
//! compiles the same table as before.

const cap = @import("security/capability.zig");
const defaults = @import("security/defaults.zig");

const Permission = cap.Permission;
const Catalog = cap.Catalog;

/// The app-declared permission the notes example grants: the `hashFile` command,
/// scoped to `$APPDATA/notes/**`. Distinct from the built-in `fs:read`, whose
/// commands are `fs.readFile`/`fs.readDir` and which carries no scope.
pub const app_permission = Permission{
    .identifier = "app:hashFile",
    .commands_allow = &.{"hashFile"},
    .scope_allow = &.{.{ .path = "$APPDATA/notes/**" }},
};

/// The runtime catalog `App.init` passes to `GrantTable.compile`: the built-in
/// permissions plus the app-declared permission, with the built-in sets intact
/// (so `core:default` still resolves). `array ++ array` yields an ARRAY; the
/// `&(...)` coerces it to the `[]const T` slice fields.
pub const runtime_catalog = Catalog{
    .permissions = &(defaults.builtin_permissions ++ [_]Permission{app_permission}),
    .sets = &defaults.builtin_sets,
};
