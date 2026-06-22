//! Single test root for the src/security/ package. Each security file imports
//! siblings/parents via `../`, so none can be its own addLogicTest module root;
//! they are all pulled in here under one module rooted at src/. Add a line as
//! each security file lands.
comptime {
    _ = @import("security/capability.zig");
    _ = @import("security/defaults.zig");
    _ = @import("security/scope/glob.zig");
    _ = @import("security/scope/path.zig");
    _ = @import("security/grant_table.zig");
    _ = @import("security/scope/host.zig");
    _ = @import("security/scope/argv.zig");
    _ = @import("security/scope/label.zig");
    _ = @import("security/gates.zig");
    _ = @import("security/navigation.zig");
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("security/capability.zig");
    _ = @import("security/defaults.zig");
    _ = @import("security/scope/glob.zig");
    _ = @import("security/scope/path.zig");
    _ = @import("security/grant_table.zig");
    _ = @import("security/scope/host.zig");
    _ = @import("security/scope/argv.zig");
    _ = @import("security/scope/label.zig");
    _ = @import("security/gates.zig");
    _ = @import("security/navigation.zig");
}

const std = @import("std");
const cap = @import("security/capability.zig");
const grant = @import("security/grant_table.zig");
const gates = @import("security/gates.zig");
const app_catalog = @import("app_catalog.zig");
const manifest = @import("manifest/types.zig");

// ─── Live scope (Task 5): the app-command path scope gates at G4 ──────────────

// A capability that references the app-declared `app:hashFile` permission grants
// `hashFile` to "main" and carries its `$APPDATA/notes/**` path scope. Compiled
// against the runtime catalog (built-in permissions + the app permission), the
// table must ALLOW an in-scope path and DENY an out-of-scope one with the real
// G4 path-miss code `scope.path.no_match`. Asserting both halves from one fixture
// proves G4 discriminates allow-from-deny ON THE PATH, not a fail-closed accident:
// the in-scope file exists on disk so `$APPDATA` expansion + realPathFile
// succeed for the allow half.
test "live scope: hashFile allows an in-scope path and denies an out-of-scope one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Anchor $APPDATA at the tmp dir and create the in-scope file on disk so
    // realPathFile resolves it (else both halves fail closed and the deny is
    // meaningless).
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base_buf);
    const base = base_buf[0..base_len];
    try tmp.dir.createDirPath(io, "notes");
    var f = try tmp.dir.createFile(io, "notes/secret.txt", .{});
    f.close(io);

    const bases = gates.Bases{ .appdata = base, .home = base, .appconfig = base };

    // One capability per window granting the app permission (one-cap-per-window
    // keeps scopeFor's inert n<=1 guard satisfied).
    const caps = [_]cap.Capability{.{
        .identifier = "notes",
        .windows = &.{"main"},
        .origins = &.{.app_scheme},
        .permissions = &.{ "core:default", "app:hashFile" },
    }};
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    var table = try grant.GrantTable.compile(std.testing.allocator, &caps, &app_catalog.runtime_catalog, .{}, &.{"main"}, &diags);
    defer table.deinit();

    // G2: the command is granted; G4: the path scope discriminates.
    try std.testing.expect(table.commandGranted("main", "hashFile"));

    // In-scope path: the gate ALLOWS (the file exists under $APPDATA/notes/**).
    var in_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const in_path = try std.fmt.bufPrint(&in_buf, "{s}/notes/secret.txt", .{base});
    const allow = gates.evaluate(&table, .{
        .window_label = "main",
        .origin = "app://localhost",
        .command = "hashFile",
        .scope_input = .{ .path = in_path },
        .is_debug = false,
    }, bases, io, tmp.dir);
    try std.testing.expect(allow == .allow);

    // Out-of-scope path: the gate DENIES with the real G4 code (NOT "out_of_scope").
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&out_buf, "{s}/notes/../../etc/passwd", .{base});
    const deny = gates.evaluate(&table, .{
        .window_label = "main",
        .origin = "app://localhost",
        .command = "hashFile",
        .scope_input = .{ .path = out_path },
        .is_debug = false,
    }, bases, io, tmp.dir);
    try std.testing.expectEqual(gates.Gate.g4_scope, deny.deny.gate);
    try std.testing.expectEqualStrings("scope.path.no_match", deny.deny.code);
}
