//! Semantic validation of an already-parsed and merged `Manifest`.
//!
//! Appends one `Diagnostic` per detected problem to `diag`. Returns `true` iff
//! no error-level diagnostic was added; warnings (currently only
//! `dev_url_without_command`) do not flip the result. The only failure mode is
//! allocation: every other check produces a diagnostic, never an error.
//!
//! Diagnostic invariants honored here:
//! - `message` is a static template keyed off the `Code` (never freed).
//! - `path` is always allocator-owned when non-null, even for "constant" paths
//!   like `"identifier"`. `Diagnostics.deinit` frees every non-null path
//!   uniformly, so a static slice would cause an invalid-free under the
//!   testing allocator. We dup or allocPrint every path before adding.

const std = @import("std");
const types = @import("types.zig");

const Manifest = types.Manifest;
const Diagnostics = types.Diagnostics;
const Diagnostic = types.Diagnostic;
const Code = types.Code;

/// Validates an already-parsed+merged `Manifest`. See file docstring for the
/// returned flag and allocation contract. `capability_ids_present` is the list
/// of capability identifiers discovered under `src/capabilities/` at build
/// time (an empty list makes every `security.capabilities` reference fail as
/// `unknown_capability_ref`, which is the desired fail-closed posture when the
/// directory is absent).
pub fn validate(
    gpa: std.mem.Allocator,
    m: Manifest,
    optimize: std.builtin.OptimizeMode,
    capability_ids_present: []const []const u8,
    diag: *Diagnostics,
) std.mem.Allocator.Error!bool {
    var ok = true;

    // identifier presence and shape.
    if (m.identifier.len == 0) {
        try emit(gpa, diag, .{
            .code = .missing_identifier,
            .message = "identifier is missing",
        }, "identifier");
        ok = false;
    } else if (!isValidReverseDns(m.identifier)) {
        try emit(gpa, diag, .{
            .code = .invalid_identifier,
            .message = "identifier label contains an invalid character; allowed: alphanumerics and hyphen",
        }, "identifier");
        ok = false;
    }

    // version: delegate to std.SemanticVersion.
    _ = std.SemanticVersion.parse(m.version) catch {
        try emit(gpa, diag, .{
            .code = .invalid_version,
            .message = "version is not SemVer 2.0.0",
        }, "version");
        ok = false;
    };

    // Windows: main presence, empty label, duplicate label.
    var has_main = false;
    for (m.app.windows) |w| {
        if (std.mem.eql(u8, w.label, "main")) {
            has_main = true;
            break;
        }
    }
    if (!has_main) {
        try emit(gpa, diag, .{
            .code = .no_main_window,
            .message = "app must declare a window with label 'main'",
        }, "app.windows");
        ok = false;
    }

    for (m.app.windows, 0..) |w, i| {
        if (w.label.len == 0) {
            const path = try std.fmt.allocPrint(gpa, "app.windows[{d}].label", .{i});
            try diag.add(gpa, .{
                .code = .empty_window_label,
                .message = "window label is empty",
                .path = path,
            });
            ok = false;
            continue;
        }
        // Duplicate detection: emit at every later index that collides with an
        // earlier non-empty label. With windows[0], [1], [2] all sharing "x",
        // diagnostics fire at indices 1 AND 2.
        var j: usize = 0;
        while (j < i) : (j += 1) {
            const prior = m.app.windows[j];
            if (prior.label.len == 0) continue;
            if (std.mem.eql(u8, prior.label, w.label)) {
                const path = try std.fmt.allocPrint(gpa, "app.windows[{d}].label", .{i});
                try diag.add(gpa, .{
                    .code = .duplicate_window_label,
                    .message = "window label is duplicated",
                    .path = path,
                });
                ok = false;
                break;
            }
        }
    }

    // Capability references: every entry must resolve to a present capability
    // identifier. Emit at every offending index so the loop iteration is
    // testable.
    for (m.security.capabilities, 0..) |cap, i| {
        var found = false;
        for (capability_ids_present) |present| {
            if (std.mem.eql(u8, cap, present)) {
                found = true;
                break;
            }
        }
        if (!found) {
            const path = try std.fmt.allocPrint(gpa, "security.capabilities[{d}]", .{i});
            try diag.add(gpa, .{
                .code = .unknown_capability_ref,
                .message = "capability identifier has no matching file under src/capabilities/",
                .path = path,
            });
            ok = false;
        }
    }

    // Debug inspector is forbidden in any release mode. .Debug allows it (the
    // intended use case is local debugging).
    if (m.security.fuses.debugInspector and isReleaseMode(optimize)) {
        try emit(gpa, diag, .{
            .code = .inspector_in_release,
            .message = "debug inspector is rejected in release builds",
        }, "security.fuses.debugInspector");
        ok = false;
    }

    // devUrl without beforeDevCommand: WARNING (does not flip `ok`).
    if (m.build.devUrl != null and m.build.beforeDevCommand == null) {
        const path = try gpa.dupe(u8, "build.devUrl");
        try diag.add(gpa, .{
            .code = .dev_url_without_command,
            .is_error = false,
            .message = "devUrl is set but no beforeDevCommand was provided; dev server may not start",
            .path = path,
        });
    }

    return ok;
}

/// Helper: heap-dup a static `path` so `Diagnostics.deinit` can free it
/// uniformly. The `Diagnostic` literal supplies the code/message; the path is
/// applied to the literal here.
fn emit(
    gpa: std.mem.Allocator,
    diag: *Diagnostics,
    template: Diagnostic,
    path: []const u8,
) std.mem.Allocator.Error!void {
    var d = template;
    d.path = try gpa.dupe(u8, path);
    try diag.add(gpa, d);
}

fn isReleaseMode(o: std.builtin.OptimizeMode) bool {
    return switch (o) {
        .ReleaseFast, .ReleaseSafe, .ReleaseSmall => true,
        .Debug => false,
    };
}

/// Reverse-DNS validation per Apple CFBundleIdentifier rules:
///   - at least two ASCII labels separated by '.',
///   - total length 1..=255,
///   - each label 1..=63 chars,
///   - label charset [A-Za-z0-9-],
///   - no leading digit on any label,
///   - no leading or trailing hyphen on any label.
/// Underscores are rejected. ASCII-only.
fn isValidReverseDns(s: []const u8) bool {
    if (s.len == 0 or s.len > 255) return false;

    var labels: usize = 0;
    var label_start: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        const at_end = i == s.len;
        const is_dot = !at_end and s[i] == '.';
        if (!at_end and !is_dot) continue;

        const label = s[label_start..i];
        if (!isValidLabel(label)) return false;
        labels += 1;
        label_start = i + 1;
        if (at_end) break;
    }

    return labels >= 2;
}

fn isValidLabel(label: []const u8) bool {
    if (label.len == 0 or label.len > 63) return false;
    // No leading digit, no leading hyphen.
    const first = label[0];
    if (!std.ascii.isAlphabetic(first)) return false;
    // No trailing hyphen.
    if (label[label.len - 1] == '-') return false;
    for (label) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
    }
    return true;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn countCode(diag: Diagnostics, c: Code) usize {
    var n: usize = 0;
    for (diag.items.items) |d| if (d.code == c) {
        n += 1;
    };
    return n;
}

fn findOne(diag: Diagnostics, c: Code) ?Diagnostic {
    for (diag.items.items) |d| if (d.code == c) return d;
    return null;
}

fn baseValid() Manifest {
    return Manifest{
        .identifier = "com.example.app",
        .productName = "A",
        .version = "0.1.0",
        .app = .{ .windows = &.{.{ .label = "main", .title = "M" }} },
    };
}

test "validate accepts a minimal valid manifest" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    try std.testing.expect(try validate(gpa, baseValid(), .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 0), diag.items.items.len);
}

test "validate flags a missing identifier" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.identifier = "";
    try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 1), countCode(diag, .missing_identifier));
    const d = findOne(diag, .missing_identifier).?;
    try std.testing.expectEqualStrings("identifier", d.path.?);
}

test "validate flags an invalid reverse-DNS identifier" {
    const gpa = std.testing.allocator;
    // Happy case has been covered by baseValid; here we hit each reject case.
    const bad = [_][]const u8{
        "com.1example.app", // leading digit on a label
        "com.example-.app", // trailing hyphen on a label
        "com.example_app", // underscore (not in charset)
    };
    for (bad) |id| {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        var m = baseValid();
        m.identifier = id;
        try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
        try std.testing.expectEqual(@as(usize, 1), countCode(diag, .invalid_identifier));
        const d = findOne(diag, .invalid_identifier).?;
        try std.testing.expectEqualStrings("identifier", d.path.?);
    }
}

test "validate accepts a valid reverse-DNS identifier" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.identifier = "com.example.app";
    try std.testing.expect(try validate(gpa, m, .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 0), countCode(diag, .invalid_identifier));
}

test "validate flags a non-semver version" {
    const gpa = std.testing.allocator;
    const bad = [_][]const u8{ "1.0", "1.0.0.0", "01.0.0", "" };
    for (bad) |v| {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        var m = baseValid();
        m.version = v;
        try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
        try std.testing.expectEqual(@as(usize, 1), countCode(diag, .invalid_version));
        const d = findOne(diag, .invalid_version).?;
        try std.testing.expectEqualStrings("version", d.path.?);
    }
}

test "validate accepts SemVer with pre-release and build metadata" {
    const gpa = std.testing.allocator;
    const good = [_][]const u8{ "0.1.0", "1.0.0-alpha+build.1" };
    for (good) |v| {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        var m = baseValid();
        m.version = v;
        try std.testing.expect(try validate(gpa, m, .Debug, &.{}, &diag));
        try std.testing.expectEqual(@as(usize, 0), countCode(diag, .invalid_version));
    }
}

test "validate flags a missing main window" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.app = .{ .windows = &.{.{ .label = "secondary", .title = "S" }} };
    try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 1), countCode(diag, .no_main_window));
    const d = findOne(diag, .no_main_window).?;
    try std.testing.expectEqualStrings("app.windows", d.path.?);
}

test "validate flags an empty window label" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.app = .{ .windows = &.{
        .{ .label = "main", .title = "M" },
        .{ .label = "", .title = "Empty" },
    } };
    try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 1), countCode(diag, .empty_window_label));
    const d = findOne(diag, .empty_window_label).?;
    try std.testing.expectEqualStrings("app.windows[1].label", d.path.?);
}

test "validate flags duplicate window labels at every duplicate index" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    // Three windows share label "x"; one of them is also "main" so we don't
    // collide with no_main_window. Actually we keep the first as "main" and
    // make the next THREE share "x" so duplicates fire at indices 2 AND 3.
    m.app = .{ .windows = &.{
        .{ .label = "main", .title = "M" },
        .{ .label = "x", .title = "X1" },
        .{ .label = "x", .title = "X2" },
        .{ .label = "x", .title = "X3" },
    } };
    try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
    // Two duplicates, at indices 2 and 3.
    try std.testing.expectEqual(@as(usize, 2), countCode(diag, .duplicate_window_label));
    var saw_2 = false;
    var saw_3 = false;
    for (diag.items.items) |d| {
        if (d.code != .duplicate_window_label) continue;
        if (std.mem.eql(u8, d.path.?, "app.windows[2].label")) saw_2 = true;
        if (std.mem.eql(u8, d.path.?, "app.windows[3].label")) saw_3 = true;
    }
    try std.testing.expect(saw_2);
    try std.testing.expect(saw_3);
}

test "validate flags unknown capability references at every offending index" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.security = .{
        .capabilities = &.{ "missing.one", "missing.two" },
    };
    try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 2), countCode(diag, .unknown_capability_ref));
    var saw_0 = false;
    var saw_1 = false;
    for (diag.items.items) |d| {
        if (d.code != .unknown_capability_ref) continue;
        if (std.mem.eql(u8, d.path.?, "security.capabilities[0]")) saw_0 = true;
        if (std.mem.eql(u8, d.path.?, "security.capabilities[1]")) saw_1 = true;
    }
    try std.testing.expect(saw_0);
    try std.testing.expect(saw_1);
}

test "validate accepts known capability references" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.security = .{ .capabilities = &.{ "fs.read", "shell.exec" } };
    const present: []const []const u8 = &.{ "fs.read", "shell.exec", "net.http" };
    try std.testing.expect(try validate(gpa, m, .Debug, present, &diag));
    try std.testing.expectEqual(@as(usize, 0), countCode(diag, .unknown_capability_ref));
}

test "inspector in release is rejected for every Release mode and allowed in Debug" {
    const gpa = std.testing.allocator;
    for ([_]std.builtin.OptimizeMode{ .ReleaseSafe, .ReleaseFast, .ReleaseSmall }) |mode| {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        var m = baseValid();
        m.security = .{ .fuses = .{ .debugInspector = true } };
        try std.testing.expect(!try validate(gpa, m, mode, &.{}, &diag));
        try std.testing.expectEqual(@as(usize, 1), countCode(diag, .inspector_in_release));
        const d = findOne(diag, .inspector_in_release).?;
        try std.testing.expectEqualStrings("security.fuses.debugInspector", d.path.?);
    }
    // .Debug must allow the inspector with no diagnostic emitted.
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.security = .{ .fuses = .{ .debugInspector = true } };
    try std.testing.expect(try validate(gpa, m, .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 0), countCode(diag, .inspector_in_release));
}

test "validate emits dev_url_without_command as a warning that does not fail" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.build = .{ .devUrl = "http://localhost:5173" };
    try std.testing.expect(try validate(gpa, m, .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 1), countCode(diag, .dev_url_without_command));
    try std.testing.expect(!diag.hasErrors());
    const d = findOne(diag, .dev_url_without_command).?;
    try std.testing.expect(!d.is_error);
    try std.testing.expectEqualStrings("build.devUrl", d.path.?);
}

test "validate does not emit dev_url_without_command when both fields are set" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.build = .{ .devUrl = "http://localhost:5173", .beforeDevCommand = "bun run dev" };
    try std.testing.expect(try validate(gpa, m, .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 0), countCode(diag, .dev_url_without_command));
}
