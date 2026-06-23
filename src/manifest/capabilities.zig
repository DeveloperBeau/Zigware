//! Build-time capability-body loader. Where `parse.listCapabilityIds` records
//! only the present SET of capability identifiers (the validator's cross-check
//! input), this loader OPENS each `src/grants/*.zon` and parses its full
//! `{ identifier, windows, origins, permissions }` body into a `Capability`.
//!
//! The result is consumed by the runtime `Catalog`/`GrantTable` assembly: a
//! capability's `permissions` list names the permission identifiers whose
//! `commands_allow`/`scope_allow` reach G2/G4 on every live invocation.
//!
//! This lives in a SEPARATE file from `parse.zig` deliberately. `Capability`
//! lives in `../security/capability.zig`, and `parse.zig` is a file-member of
//! the `emit_effective` codegen module (rooted at `src/manifest/`); a
//! top-level import of `../security/...` from `parse.zig` would escape that
//! module's path and fail to compile. This file is reached only through a
//! src-rooted test root (and, later, app.zig), never through the codegen graph.
//!
//! Ownership: every loaded `Capability` (and the slice holding them) is parsed
//! into the caller-supplied allocator, which is expected to be an ARENA. Free
//! the whole batch by tearing down that arena; there is no per-field freer.
//! `std.zon.parse.free` is NOT used here because `Capability`/`Permission`
//! carry static-literal slice defaults (`&.{}`) that a type-driven free would
//! try to release.

const std = @import("std");
const cap = @import("../security/capability.zig");

pub const Capability = cap.Capability;

const READ_LIMIT_BYTES: usize = 1 << 20; // 1 MiB upper bound on a capability file.

pub const LoadError = error{
    /// A `src/grants/*.zon` body failed to parse against `Capability`.
    /// Fail-closed: a malformed capability is a hard error, never skipped.
    ParseFailed,
} || std.mem.Allocator.Error;

/// Opens `src/grants/*.zon` under `root_dir`, parses each body into a
/// `Capability`, and returns them in directory-iteration order. A missing
/// directory yields an EMPTY slice (fail-closed: every `security.grants`
/// reference then resolves to nothing), mirroring `listCapabilityIds`.
///
/// `arena` owns every returned allocation; tear down the arena to free.
pub fn loadCapabilities(
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
) LoadError![]const Capability {
    var dir = root_dir.openDir(io, "src/grants", .{ .iterate = true }) catch {
        // Missing dir is the expected fail-closed path; any other open error
        // also degrades to "no capabilities present" rather than aborting.
        const empty: []const Capability = &.{};
        return empty;
    };
    defer dir.close(io);

    var list: std.ArrayList(Capability) = .empty;

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;

        const src = dir.readFileAllocOptions(
            io,
            entry.name,
            arena,
            .limited(READ_LIMIT_BYTES),
            .of(u8),
            0,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A capability file the iterator just listed but cannot be read is
            // a configuration error worth surfacing, not a silent skip.
            else => return error.ParseFailed,
        };

        const c = std.zon.parse.fromSliceAlloc(Capability, arena, src, null, .{}) catch |err| switch (err) {
            error.ParseZon => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        try list.append(arena, c);
    }

    return try list.toOwnedSlice(arena);
}

// ─── tests ───────────────────────────────────────────────────────────────────

fn findLoadedCap(caps: []const Capability, identifier: []const u8) ?*const Capability {
    for (caps) |*c| {
        if (std.mem.eql(u8, c.identifier, identifier)) return c;
    }
    return null;
}

test "loadCapabilities returns empty when the directory is absent" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try std.Io.Dir.cwd().openDir(io, "tests/manifest/missing", .{});
    defer fixture.close(io);

    const caps = try loadCapabilities(arena, io, fixture);
    try std.testing.expectEqual(@as(usize, 0), caps.len);
}

test "loadCapabilities parses permission identifiers and defaulted bodies" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try std.Io.Dir.cwd().openDir(io, "tests/manifest/grants_bodies", .{});
    defer fixture.close(io);

    const caps = try loadCapabilities(arena, io, fixture);
    try std.testing.expectEqual(@as(usize, 2), caps.len);

    // The capability with an explicit permission list carries those identifiers,
    // which the catalog assembly resolves to scoped permissions.
    const main = findLoadedCap(caps, "main") orelse return error.MissingMainCapability;
    try std.testing.expectEqual(@as(usize, 1), main.windows.len);
    try std.testing.expectEqualStrings("main", main.windows[0]);
    try std.testing.expectEqual(@as(usize, 2), main.permissions.len);
    try std.testing.expectEqualStrings("app:hashFile", main.permissions[0]);
    try std.testing.expectEqualStrings("core:compute:cancel", main.permissions[1]);

    // The template-shaped capability omits `permissions`, so it must load on the
    // `Capability` default (`permissions = &.{}`) rather than failing to parse.
    const extra = findLoadedCap(caps, "extra") orelse return error.MissingExtraCapability;
    try std.testing.expectEqual(@as(usize, 0), extra.permissions.len);
}

test "loadCapabilities fails closed on a malformed capability body" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try std.Io.Dir.cwd().openDir(io, "tests/manifest/grants_malformed", .{});
    defer fixture.close(io);

    try std.testing.expectError(
        error.ParseFailed,
        loadCapabilities(arena, io, fixture),
    );
}
