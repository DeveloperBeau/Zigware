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
/// of capability identifiers discovered under `src/grants/` at build
/// time (an empty list makes every `security.grants` reference fail as
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

    // Bundle/macOS signing fields. These feed the packaging argv and the
    // Info.plist, so each is shape-checked here (defense in depth) and every
    // free-text value is rejected when it would land in a tool argv slot
    // leading with '-' (option injection).
    if (m.bundle.macos.teamId) |team| {
        if (!isValidTeamId(team)) {
            try emit(gpa, diag, .{
                .code = .invalid_team_id,
                .message = "teamId must be non-empty alphanumerics (no leading hyphen)",
            }, "bundle.macos.teamId");
            ok = false;
        }
    }
    if (m.bundle.bundleVersion) |bv| {
        if (bv.len == 0 or bv[0] == '-') {
            try emit(gpa, diag, .{
                .code = .invalid_bundle_version,
                .message = "bundleVersion must be non-empty and not start with a hyphen",
            }, "bundle.bundleVersion");
            ok = false;
        }
    }
    if (m.bundle.displayName) |dn| {
        if (dn.len == 0 or dn[0] == '-') {
            try emit(gpa, diag, .{
                .code = .invalid_display_name,
                .message = "displayName must be non-empty and not start with a hyphen",
            }, "bundle.displayName");
            ok = false;
        }
    }
    // minimumSystemVersion: lenient digits-and-dots, <=3 numeric components.
    // macOS deployment targets are routinely two-component ("11.0", "12"),
    // and the field DEFAULTS to "11.0", which SemVer.parse would reject; do
    // NOT use std.SemanticVersion.parse here.
    if (!isValidDeploymentVersion(m.bundle.macos.minimumSystemVersion)) {
        try emit(gpa, diag, .{
            .code = .invalid_minimum_system_version,
            .message = "minimumSystemVersion must be digits and dots with at most three components",
        }, "bundle.macos.minimumSystemVersion");
        ok = false;
    }

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
            errdefer gpa.free(path);
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
                errdefer gpa.free(path);
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
    for (m.security.grants, 0..) |cap, i| {
        var found = false;
        for (capability_ids_present) |present| {
            if (std.mem.eql(u8, cap, present)) {
                found = true;
                break;
            }
        }
        if (!found) {
            const path = try std.fmt.allocPrint(gpa, "security.grants[{d}]", .{i});
            errdefer gpa.free(path);
            try diag.add(gpa, .{
                .code = .unknown_capability_ref,
                .message = "grant identifier has no matching file under src/grants/",
                .path = path,
            });
            ok = false;
        }
    }

    // App-declared permissions: namespacing + scope confinement. An app may
    // only scope a declared permission to its OWN $APPDATA; everything else
    // (other tokens, tokenless verbatim globs, absolute paths, non-path
    // scopes) is rejected. The `app:` prefix requirement also forbids
    // shadowing a builtin id (all builtins use a non-app: namespace).
    // `commands_allow` is intentionally not constrained here: the app's
    // command names are Zig (not in the manifest), so they are unvalidatable
    // at manifest-build-time, and `synthAppGrants` only reuses a declared
    // permission for the app's own registered commands.
    const APPDATA = "$APPDATA";
    for (m.security.permissions, 0..) |perm, i| {
        if (!std.mem.startsWith(u8, perm.identifier, "app:")) {
            const path = try std.fmt.allocPrint(gpa, "security.permissions[{d}].identifier", .{i});
            errdefer gpa.free(path);
            try diag.add(gpa, .{
                .code = .permission_not_app_namespaced,
                .message = "app-declared permission identifier must be 'app:'-prefixed",
                .path = path,
            });
            ok = false;
        }
        for (perm.scope_allow, 0..) |sc, j| {
            const confined = switch (sc) {
                .path => |p| blk: {
                    if (!std.mem.startsWith(u8, p, APPDATA)) break :blk false;
                    if (!(p.len == APPDATA.len or p[APPDATA.len] == '/')) break :blk false;
                    // A lexical $APPDATA prefix does NOT confine if the pattern can
                    // traverse out of app-data: the runtime matcher realpaths the
                    // literal prefix, so `$APPDATA/../etc/**` resolves to /etc and
                    // would be ALLOWED. Reject any `..`/`.` path segment.
                    var it = std.mem.splitScalar(u8, p, '/');
                    while (it.next()) |seg| {
                        if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            };
            if (!confined) {
                const path = try std.fmt.allocPrint(gpa, "security.permissions[{d}].scope_allow[{d}]", .{ i, j });
                errdefer gpa.free(path);
                try diag.add(gpa, .{
                    .code = .permission_scope_unconfined,
                    .message = "app-declared scope must be a $APPDATA-confined path",
                    .path = path,
                });
                ok = false;
            }
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

    // serveUrl without a dev command: WARNING (does not flip `ok`).
    if (m.frontend.serveUrl != null and m.frontend.dev == null) {
        const path = try gpa.dupe(u8, "frontend.serveUrl");
        errdefer gpa.free(path);
        try diag.add(gpa, .{
            .code = .dev_url_without_command,
            .is_error = false,
            .message = "serveUrl is set but no dev command was provided; dev server may not start",
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
    const path_owned = try gpa.dupe(u8, path);
    errdefer gpa.free(path_owned);
    d.path = path_owned;
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
pub fn isValidReverseDns(s: []const u8) bool {
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

/// Apple Team IDs are short ASCII-alphanumeric strings (e.g. "ABCDE12345").
/// Non-empty, alphanumeric only, which also forbids a leading hyphen (so the
/// value can never be read as a flag by notarytool/codesign).
fn isValidTeamId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

/// macOS deployment-target shape: one to three numeric components separated by
/// dots, digits only (e.g. "11", "11.0", "12.3.1"). Deliberately lenient and
/// NOT SemVer (the default "11.0" is two-component). Rejects a leading hyphen
/// implicitly (only digits and dots are allowed).
fn isValidDeploymentVersion(s: []const u8) bool {
    if (s.len == 0) return false;
    var components: usize = 1;
    var digits_in_component: usize = 0;
    for (s) |c| {
        if (c == '.') {
            if (digits_in_component == 0) return false; // empty component
            components += 1;
            digits_in_component = 0;
            if (components > 3) return false;
            continue;
        }
        if (!std.ascii.isDigit(c)) return false;
        digits_in_component += 1;
    }
    return digits_in_component > 0; // no trailing dot
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
        .grants = &.{ "missing.one", "missing.two" },
    };
    try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 2), countCode(diag, .unknown_capability_ref));
    var saw_0 = false;
    var saw_1 = false;
    for (diag.items.items) |d| {
        if (d.code != .unknown_capability_ref) continue;
        if (std.mem.eql(u8, d.path.?, "security.grants[0]")) saw_0 = true;
        if (std.mem.eql(u8, d.path.?, "security.grants[1]")) saw_1 = true;
    }
    try std.testing.expect(saw_0);
    try std.testing.expect(saw_1);
}

test "validate accepts known capability references" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.security = .{ .grants = &.{ "fs.read", "shell.exec" } };
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
    m.frontend = .{ .serveUrl = "http://localhost:5173" };
    try std.testing.expect(try validate(gpa, m, .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 1), countCode(diag, .dev_url_without_command));
    try std.testing.expect(!diag.hasErrors());
    const d = findOne(diag, .dev_url_without_command).?;
    try std.testing.expect(!d.is_error);
    try std.testing.expectEqualStrings("frontend.serveUrl", d.path.?);
}

test "validate does not emit dev_url_without_command when both fields are set" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.frontend = .{ .serveUrl = "http://localhost:5173", .dev = "bun run dev" };
    try std.testing.expect(try validate(gpa, m, .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 0), countCode(diag, .dev_url_without_command));
}

test "validate flags an invalid team id and accepts a valid one" {
    const gpa = std.testing.allocator;
    const bad = [_][]const u8{ "", "-ABCDE", "ABC DE", "ABC.DE" };
    for (bad) |t| {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        var m = baseValid();
        m.bundle = .{ .macos = .{ .teamId = t } };
        try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
        try std.testing.expectEqual(@as(usize, 1), countCode(diag, .invalid_team_id));
        const d = findOne(diag, .invalid_team_id).?;
        try std.testing.expectEqualStrings("bundle.macos.teamId", d.path.?);
    }
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.bundle = .{ .macos = .{ .teamId = "ABCDE12345" } };
    try std.testing.expect(try validate(gpa, m, .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 0), countCode(diag, .invalid_team_id));
}

test "validate flags empty or leading-hyphen bundleVersion and displayName" {
    const gpa = std.testing.allocator;
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        var m = baseValid();
        m.bundle = .{ .bundleVersion = "-1" };
        try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
        try std.testing.expectEqual(@as(usize, 1), countCode(diag, .invalid_bundle_version));
        try std.testing.expectEqualStrings("bundle.bundleVersion", findOne(diag, .invalid_bundle_version).?.path.?);
    }
    {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        var m = baseValid();
        m.bundle = .{ .displayName = "-bad" };
        try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
        try std.testing.expectEqual(@as(usize, 1), countCode(diag, .invalid_display_name));
        try std.testing.expectEqualStrings("bundle.displayName", findOne(diag, .invalid_display_name).?.path.?);
    }
    // Valid values pass.
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.bundle = .{ .bundleVersion = "42", .displayName = "My App" };
    try std.testing.expect(try validate(gpa, m, .Debug, &.{}, &diag));
}

test "validate accepts lenient minimumSystemVersion and rejects malformed ones" {
    const gpa = std.testing.allocator;
    const good = [_][]const u8{ "11.0", "12", "10.15.7", "11" };
    for (good) |v| {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        var m = baseValid();
        m.bundle = .{ .macos = .{ .minimumSystemVersion = v } };
        try std.testing.expect(try validate(gpa, m, .Debug, &.{}, &diag));
        try std.testing.expectEqual(@as(usize, 0), countCode(diag, .invalid_minimum_system_version));
    }
    const bad = [_][]const u8{ "11.0.0.1", "11.", ".11", "11-beta", "11..0", "-11", "" };
    for (bad) |v| {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        var m = baseValid();
        m.bundle = .{ .macos = .{ .minimumSystemVersion = v } };
        try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
        try std.testing.expectEqual(@as(usize, 1), countCode(diag, .invalid_minimum_system_version));
        try std.testing.expectEqualStrings("bundle.macos.minimumSystemVersion", findOne(diag, .invalid_minimum_system_version).?.path.?);
    }
}

// Build a manifest that fires several path-allocating diagnostics so the OOM
// sweep below hits multiple allocation sites (identifier, duplicate window
// label, unknown capability ref, dev_url_without_command warning). Each site
// must roll back the just-allocated path string when `Diagnostics.add` errors,
// or the testing allocator surfaces the leak.
fn oomTestImpl(gpa: std.mem.Allocator) !void {
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);

    var m = baseValid();
    // Trigger invalid_identifier (alloc), duplicate_window_label (alloc),
    // unknown_capability_ref (alloc), and dev_url_without_command (alloc).
    m.identifier = "bad_id";
    m.app = .{ .windows = &.{
        .{ .label = "main", .title = "M" },
        .{ .label = "dup", .title = "A" },
        .{ .label = "dup", .title = "B" },
    } };
    m.security = .{
        .grants = &.{ "missing.one", "missing.two" },
        .permissions = &.{.{ .identifier = "nope", .scope_allow = &.{.{ .path = "$HOME/x" }} }},
    };
    m.frontend = .{ .serveUrl = "http://localhost:5173" };

    _ = try validate(gpa, m, .Debug, &.{}, &diag);
}

test "validate under checkAllAllocationFailures has zero leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, oomTestImpl, .{});
}

test "validate accepts an app permission confined to $APPDATA" {
    const gpa = std.testing.allocator;
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var m = baseValid();
    m.security = .{
        .permissions = &.{.{
            .identifier = "app:hashFile",
            .commands_allow = &.{"hashFile"},
            // Two entries exercise BOTH accept branches of the boundary condition:
            // `$APPDATA` alone (len == 8) and `$APPDATA/...` (p[8] == '/').
            .scope_allow = &.{ .{ .path = "$APPDATA" }, .{ .path = "$APPDATA/notes/**" } },
        }},
    };
    try std.testing.expect(try validate(gpa, m, .Debug, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 0), countCode(diag, .permission_scope_unconfined));
    try std.testing.expectEqual(@as(usize, 0), countCode(diag, .permission_not_app_namespaced));
}

test "validate rejects an app permission scoped outside $APPDATA" {
    const gpa = std.testing.allocator;
    const bad = [_]types.Scope{
        .{ .path = "$HOME/notes/**" }, // wrong token
        .{ .path = "$APPCONFIG/x/**" }, // wrong token
        .{ .path = "notes/**" }, // tokenless verbatim passthrough
        .{ .path = "/etc/**" }, // absolute
        .{ .host = .{ .host = "example.com" } }, // non-path scope
        .{ .path = "$APPDATALOLOL/x" }, // boundary: p[8]='L', not '/'
        .{ .path = "$APPDATA/../etc/**" }, // .. traversal escapes app-data at realpath
        .{ .path = "$APPDATA/./x/**" }, // . segment
    };
    for (bad) |sc| {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        var m = baseValid();
        m.security = .{ .permissions = &.{.{ .identifier = "app:hashFile", .scope_allow = &.{sc} }} };
        try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
        try std.testing.expectEqual(@as(usize, 1), countCode(diag, .permission_scope_unconfined));
        try std.testing.expectEqualStrings(
            "security.permissions[0].scope_allow[0]",
            findOne(diag, .permission_scope_unconfined).?.path.?,
        );
    }
}

test "validate rejects an app permission whose id is not app: namespaced" {
    const gpa = std.testing.allocator;
    const bad_ids = [_][]const u8{ "fs:read", "hashFile", "core:default" };
    for (bad_ids) |id| {
        var diag: Diagnostics = .{};
        defer diag.deinit(gpa);
        var m = baseValid();
        m.security = .{ .permissions = &.{.{ .identifier = id }} };
        try std.testing.expect(!try validate(gpa, m, .Debug, &.{}, &diag));
        try std.testing.expectEqual(@as(usize, 1), countCode(diag, .permission_not_app_namespaced));
        try std.testing.expectEqualStrings(
            "security.permissions[0].identifier",
            findOne(diag, .permission_not_app_namespaced).?.path.?,
        );
    }
}
