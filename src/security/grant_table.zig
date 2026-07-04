const std = @import("std");
const cap = @import("capability.zig");
const glob = @import("scope/glob.zig");
const manifest = @import("../manifest/types.zig");
const builtin = @import("builtin");

const Capability = cap.Capability;
const Catalog = cap.Catalog;
const Permission = cap.Permission;
const Scope = cap.Scope;
const OriginPattern = cap.OriginPattern;
const Fuses = manifest.Fuses;
const Diagnostics = manifest.Diagnostics;

pub const ScopeSet = struct {
    allow: []const Scope,
    deny: []const Scope,
    pub const empty: ScopeSet = .{ .allow = &.{}, .deny = &.{} };
};

/// One compiled grant for one (matched) capability: its window-label globs, its
/// trusted origins, and the per-command allow/deny + merged scopes. Kept as a
/// flat list; lookups linear-scan (small N for v0.1.0).
const CompiledCap = struct {
    window_globs: []const []const u8,
    origins: []const OriginPattern,
    commands_allow: []const []const u8,
    commands_deny: []const []const u8,
    scope_allow: []const Scope,
    scope_deny: []const Scope,
};

/// Per-known-label merged origin set (union across every matching cap).
const LabelOrigins = struct {
    label: []const u8,
    origins: []const OriginPattern,
};

/// Per-(known-label, command) merged scopes: union of allow and of deny across
/// every cap that matches the label AND grants the command (deny-beats-allow
/// across caps once the gate applies "some allow and no deny").
const LabelCommandScopes = struct {
    label: []const u8,
    command: []const u8,
    allow: []const Scope,
    deny: []const Scope,
};

pub const GrantTable = struct {
    arena: std.heap.ArenaAllocator,
    caps: []const CompiledCap,
    /// Precomputed multi-cap merges so originsFor/scopeFor are allocation-free
    /// and honor union-of-allows + deny-beats-allow across ALL matching caps.
    origins_by_label: []const LabelOrigins,
    scopes_by_label_command: []const LabelCommandScopes,

    pub fn compile(
        gpa: std.mem.Allocator,
        caps: []const Capability,
        catalog: *const Catalog,
        fuses: Fuses,
        known_labels: []const []const u8,
        diags: *Diagnostics,
    ) error{ UnknownPermission, OutOfMemory }!GrantTable {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var compiled: std.ArrayList(CompiledCap) = .empty;

        for (caps) |c| {
            // capability_window_unknown: a windows glob that matches no known label.
            for (c.windows) |wg| {
                const matched_any = for (known_labels) |kl| {
                    if (glob.match(wg, kl)) break true;
                } else false;
                if (!matched_any) {
                    diags.report(gpa, .{ .code = .capability_window_unknown, .message = "capability window label glob matched no known window" });
                }
            }

            // Resolve permissions (transitively expand sets), merging commands/scopes.
            var cmd_allow: std.ArrayList([]const u8) = .empty;
            var cmd_deny: std.ArrayList([]const u8) = .empty;
            var sc_allow: std.ArrayList(Scope) = .empty;
            var sc_deny: std.ArrayList(Scope) = .empty;
            for (c.permissions) |pid| {
                try resolvePerm(a, catalog, pid, fuses, diags, gpa, &cmd_allow, &cmd_deny, &sc_allow, &sc_deny, 0);
            }

            // Origins: drop https_exact when allowRemoteContent is off (force-deny),
            // and drop dev_url outside Debug so a shipped binary's trust set can
            // never include a dev-server origin even if a capability declares one
            // (belt beyond the runtime is_debug gate in gates.originTrusted).
            var origins: std.ArrayList(OriginPattern) = .empty;
            for (c.origins) |o| {
                switch (o) {
                    .https_exact => if (!fuses.allowRemoteContent) {
                        diags.report(gpa, .{ .code = .fuse_requires_capability, .message = "https origin dropped: allowRemoteContent is off" });
                        continue;
                    },
                    .dev_url => if (comptime builtin.mode != .Debug) {
                        continue;
                    },
                    else => {},
                }
                try origins.append(a, o);
            }

            try compiled.append(a, .{
                .window_globs = try a.dupe([]const u8, c.windows),
                .origins = try origins.toOwnedSlice(a),
                .commands_allow = try cmd_allow.toOwnedSlice(a),
                .commands_deny = try cmd_deny.toOwnedSlice(a),
                .scope_allow = try sc_allow.toOwnedSlice(a),
                .scope_deny = try sc_deny.toOwnedSlice(a),
            });
        }

        // Precompute the per-known-label multi-cap merges. Small N for v0.1.0, so
        // linear scans are fine; the point is a correct, allocation-free lookup.
        var lo_list: std.ArrayList(LabelOrigins) = .empty;
        var ls_list: std.ArrayList(LabelCommandScopes) = .empty;
        for (known_labels) |kl| {
            // Origins: concatenate across every cap whose window glob matches kl.
            var merged_origins: std.ArrayList(OriginPattern) = .empty;
            for (compiled.items) |cc| {
                if (!globsMatch(cc.window_globs, kl)) continue;
                for (cc.origins) |o| try merged_origins.append(a, o);
            }
            try lo_list.append(a, .{ .label = try a.dupe(u8, kl), .origins = try merged_origins.toOwnedSlice(a) });

            // Scopes: for each distinct command granted to kl by a matching cap,
            // union allow/deny across the caps that match kl AND grant the command.
            var seen_cmds: std.ArrayList([]const u8) = .empty;
            for (compiled.items) |cc| {
                if (!globsMatch(cc.window_globs, kl)) continue;
                for (cc.commands_allow) |cmd| {
                    if (containsStr(seen_cmds.items, cmd)) continue;
                    try seen_cmds.append(a, cmd);
                    var m_allow: std.ArrayList(Scope) = .empty;
                    var m_deny: std.ArrayList(Scope) = .empty;
                    for (compiled.items) |c2| {
                        if (!globsMatch(c2.window_globs, kl)) continue;
                        if (!containsStr(c2.commands_allow, cmd)) continue;
                        for (c2.scope_allow) |s| try m_allow.append(a, s);
                        for (c2.scope_deny) |s| try m_deny.append(a, s);
                    }
                    try ls_list.append(a, .{
                        .label = try a.dupe(u8, kl),
                        .command = try a.dupe(u8, cmd),
                        .allow = try m_allow.toOwnedSlice(a),
                        .deny = try m_deny.toOwnedSlice(a),
                    });
                }
            }
        }

        return .{
            .arena = arena,
            .caps = try compiled.toOwnedSlice(a),
            .origins_by_label = try lo_list.toOwnedSlice(a),
            .scopes_by_label_command = try ls_list.toOwnedSlice(a),
        };
    }

    pub fn deinit(self: *GrantTable) void {
        self.arena.deinit();
    }

    /// G2: is `command` granted to the window labeled `label`?
    /// Deny-by-default (no matched cap -> false) and deny-beats-allow (command in any
    /// matched deny list -> false regardless of allows).
    pub fn commandGranted(self: *const GrantTable, label: []const u8, command: []const u8) bool {
        var allowed = false;
        for (self.caps) |c| {
            if (!self.windowMatches(c, label)) continue;
            for (c.commands_deny) |d| {
                if (std.mem.eql(u8, d, command)) return false; // deny beats allow
            }
            for (c.commands_allow) |al| {
                if (std.mem.eql(u8, al, command)) allowed = true;
            }
        }
        return allowed;
    }

    /// G4 input: allow/deny scopes for (label, command). A command with no
    /// declared scope, or a label not in `known_labels`, returns ScopeSet.empty.
    /// Merged across every capability that matches the label and grants the
    /// command (union of allows, union of denies; the gate's "some allow and no
    /// deny" yields deny-beats-allow across caps). NOTE: keyed on `known_labels`
    /// (exact match), while commandGranted globs at query time; a label outside
    /// known_labels under a wildcard cap therefore fails CLOSED here (empty),
    /// which is strictly more restrictive, never a leak.
    pub fn scopeFor(self: *const GrantTable, label: []const u8, command: []const u8) ScopeSet {
        for (self.scopes_by_label_command) |ls| {
            if (std.mem.eql(u8, ls.label, label) and std.mem.eql(u8, ls.command, command))
                return .{ .allow = ls.allow, .deny = ls.deny };
        }
        return ScopeSet.empty;
    }

    /// G1 input: origins trusted for this window, unioned across every matching
    /// capability. Empty slice (no matching cap, or a label not in `known_labels`)
    /// means app_scheme only (G1 treats empty as {app_scheme}). Keyed on
    /// `known_labels` (exact match); a label outside known_labels under a wildcard
    /// cap fails CLOSED to app_scheme-only, never widening trust.
    pub fn originsFor(self: *const GrantTable, label: []const u8) []const OriginPattern {
        for (self.origins_by_label) |lo| {
            if (std.mem.eql(u8, lo.label, label)) return lo.origins;
        }
        return &.{};
    }

    fn windowMatches(self: *const GrantTable, c: CompiledCap, label: []const u8) bool {
        _ = self;
        for (c.window_globs) |wg| {
            if (glob.match(wg, label)) return true;
        }
        return false;
    }
};

fn globsMatch(globs: []const []const u8, label: []const u8) bool {
    for (globs) |wg| {
        if (glob.match(wg, label)) return true;
    }
    return false;
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// Expand a permission-or-set id into the accumulators. A set expands its members
/// transitively (bounded depth guards against a cycle the catalog check should
/// already reject). An unknown id is a hard error. The shell: family is dropped
/// when allowShell is off (force-deny: the grant is gone, not left unreachable).
fn resolvePerm(
    a: std.mem.Allocator,
    catalog: *const Catalog,
    id: []const u8,
    fuses: Fuses,
    diags: *Diagnostics,
    gpa: std.mem.Allocator,
    cmd_allow: *std.ArrayList([]const u8),
    cmd_deny: *std.ArrayList([]const u8),
    sc_allow: *std.ArrayList(Scope),
    sc_deny: *std.ArrayList(Scope),
    depth: usize,
) error{ UnknownPermission, OutOfMemory }!void {
    if (depth > 64) return; // cycle backstop; assertCatalog already rejects cycles in the builtin catalog

    if (catalog.permission(id)) |p| {
        // Fuse force-deny: shell family dropped when allowShell is off.
        if (std.mem.startsWith(u8, p.identifier, "shell:") and !fuses.allowShell) {
            diags.report(gpa, .{ .code = .fuse_requires_capability, .message = "shell permission dropped: allowShell is off" });
            return;
        }
        for (p.commands_allow) |c| try cmd_allow.append(a, c);
        for (p.commands_deny) |c| try cmd_deny.append(a, c);
        for (p.scope_allow) |s| try sc_allow.append(a, s);
        for (p.scope_deny) |s| try sc_deny.append(a, s);
        return;
    }
    if (catalog.set(id)) |s| {
        for (s.members) |m| try resolvePerm(a, catalog, m, fuses, diags, gpa, cmd_allow, cmd_deny, sc_allow, sc_deny, depth + 1);
        return;
    }
    return error.UnknownPermission;
}

const defaults = @import("defaults.zig");

fn compileOne(caps: []const Capability, fuses: manifest.Fuses) !GrantTable {
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    return GrantTable.compile(std.testing.allocator, caps, &defaults.builtin_catalog, fuses, &.{"main"}, &diags);
}

test "empty grant set denies every command (deny-by-default)" {
    var gt = try compileOne(&.{}, .{});
    defer gt.deinit();
    try std.testing.expect(!gt.commandGranted("main", "window.setTitle"));
}

test "core:default grants its commands to main, denies others" {
    const caps = [_]Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"core:default"} }};
    var gt = try compileOne(&caps, .{});
    defer gt.deinit();
    try std.testing.expect(gt.commandGranted("main", "window.setTitle"));
    try std.testing.expect(gt.commandGranted("main", "compute.cancel"));
    try std.testing.expect(!gt.commandGranted("main", "fs.readFile")); // not in core:default
    try std.testing.expect(!gt.commandGranted("other", "window.setTitle")); // wrong window
}

test "unknown permission identifier is a hard compile error" {
    const caps = [_]Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"nope:perm"} }};
    try std.testing.expectError(error.UnknownPermission, compileOne(&caps, .{}));
}

test "deny beats allow at the command level" {
    // A custom catalog with a perm that both allows and denies the same command.
    const custom = cap.Catalog{
        .permissions = &.{.{ .identifier = "x:p", .commands_allow = &.{"cmd.a"}, .commands_deny = &.{"cmd.a"} }},
        .sets = &.{},
    };
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    const caps = [_]Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"x:p"} }};
    var gt = try GrantTable.compile(std.testing.allocator, &caps, &custom, .{}, &.{"main"}, &diags);
    defer gt.deinit();
    try std.testing.expect(!gt.commandGranted("main", "cmd.a")); // deny wins
}

test "shell family dropped when allowShell is off; fuse_requires_capability emitted" {
    const caps = [_]Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"shell:execute"} }};
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    var gt = try GrantTable.compile(std.testing.allocator, &caps, &defaults.builtin_catalog, .{ .allowShell = false }, &.{"main"}, &diags);
    defer gt.deinit();
    try std.testing.expect(!gt.commandGranted("main", "shell.execute")); // grant gone
    var saw = false;
    for (diags.items.items) |d| if (d.code == .fuse_requires_capability) {
        saw = true;
    };
    try std.testing.expect(saw);
}

test "shell granted when allowShell is on" {
    const caps = [_]Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"shell:execute"} }};
    var gt = try compileOne(&caps, .{ .allowShell = true });
    defer gt.deinit();
    try std.testing.expect(gt.commandGranted("main", "shell.execute"));
}

test "https origin dropped when allowRemoteContent off; emitted as diagnostic" {
    const caps = [_]Capability{.{ .identifier = "c", .windows = &.{"main"}, .origins = &.{.{ .https_exact = "https://x.example" }}, .permissions = &.{"core:default"} }};
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    var gt = try GrantTable.compile(std.testing.allocator, &caps, &defaults.builtin_catalog, .{}, &.{"main"}, &diags);
    defer gt.deinit();
    try std.testing.expectEqual(@as(usize, 0), gt.originsFor("main").len); // dropped -> empty -> app_scheme only
    var saw = false;
    for (diags.items.items) |d| if (d.code == .fuse_requires_capability) {
        saw = true;
    };
    try std.testing.expect(saw);
}

test "scopeFor returns a granted command's allow/deny scopes" {
    const custom = cap.Catalog{
        .permissions = &.{.{ .identifier = "fs:x", .commands_allow = &.{"fs.readFile"}, .scope_allow = &.{.{ .path = "$APPDATA/**" }}, .scope_deny = &.{.{ .path = "$APPDATA/secret/**" }} }},
        .sets = &.{},
    };
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    const caps = [_]Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"fs:x"} }};
    var gt = try GrantTable.compile(std.testing.allocator, &caps, &custom, .{}, &.{"main"}, &diags);
    defer gt.deinit();
    const set = gt.scopeFor("main", "fs.readFile");
    try std.testing.expectEqual(@as(usize, 1), set.allow.len);
    try std.testing.expectEqual(@as(usize, 1), set.deny.len);
    try std.testing.expectEqual(@as(usize, 0), gt.scopeFor("main", "fs.writeFile").allow.len);
}

test "capability_window_unknown emitted for an unmatched window glob" {
    const caps = [_]Capability{.{ .identifier = "c", .windows = &.{"ghost"}, .permissions = &.{"core:default"} }};
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    var gt = try GrantTable.compile(std.testing.allocator, &caps, &defaults.builtin_catalog, .{}, &.{"main"}, &diags);
    defer gt.deinit();
    var saw = false;
    for (diags.items.items) |d| if (d.code == .capability_window_unknown) {
        saw = true;
    };
    try std.testing.expect(saw);
}

test "originsFor unions origins across all window-matching caps (multi-cap)" {
    // Two caps match "main"; each carries a different trusted origin. The union
    // must expose BOTH. Before the merge, originsFor asserted n<=1 and returned
    // only the first cap's origins.
    const caps = [_]Capability{
        .{ .identifier = "a", .windows = &.{"main"}, .origins = &.{.app_scheme}, .permissions = &.{"core:default"} },
        .{ .identifier = "b", .windows = &.{"main"}, .origins = &.{.{ .https_exact = "https://x.example" }}, .permissions = &.{"core:default"} },
    };
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    var gt = try GrantTable.compile(std.testing.allocator, &caps, &defaults.builtin_catalog, .{ .allowRemoteContent = true }, &.{"main"}, &diags);
    defer gt.deinit();
    const origins = gt.originsFor("main");
    var saw_app = false;
    var saw_https = false;
    for (origins) |o| switch (o) {
        .app_scheme => saw_app = true,
        .https_exact => saw_https = true,
        else => {},
    };
    try std.testing.expect(saw_app and saw_https);
}

test "scopeFor merges scopes across caps, deny beats allow (deviation-5 hole closed)" {
    // Cap A grants fs.readFile with an ALLOW scope; cap B grants the SAME command
    // with a DENY scope. Both must appear in the merged set so the deny wins.
    // Before the merge, scopeFor returned cap A only and B's deny was ignored.
    const custom = cap.Catalog{
        .permissions = &.{
            .{ .identifier = "fs:a", .commands_allow = &.{"fs.readFile"}, .scope_allow = &.{.{ .path = "$APPDATA/**" }} },
            .{ .identifier = "fs:b", .commands_allow = &.{"fs.readFile"}, .scope_deny = &.{.{ .path = "$APPDATA/secret/**" }} },
        },
        .sets = &.{},
    };
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    const caps = [_]Capability{
        .{ .identifier = "a", .windows = &.{"main"}, .permissions = &.{"fs:a"} },
        .{ .identifier = "b", .windows = &.{"main"}, .permissions = &.{"fs:b"} },
    };
    var gt = try GrantTable.compile(std.testing.allocator, &caps, &custom, .{}, &.{"main"}, &diags);
    defer gt.deinit();
    const set = gt.scopeFor("main", "fs.readFile");
    try std.testing.expectEqual(@as(usize, 1), set.allow.len); // from cap a
    try std.testing.expectEqual(@as(usize, 1), set.deny.len); // from cap b (previously dropped)
}

test "scopeFor does not bleed a non-granting cap's scopes onto a command" {
    // Cap B matches the window but grants a DIFFERENT command; its scopes must
    // not attach to fs.readFile.
    const custom = cap.Catalog{
        .permissions = &.{
            .{ .identifier = "fs:a", .commands_allow = &.{"fs.readFile"}, .scope_allow = &.{.{ .path = "$APPDATA/a/**" }} },
            .{ .identifier = "fs:b", .commands_allow = &.{"fs.writeFile"}, .scope_deny = &.{.{ .path = "$APPDATA/b/**" }} },
        },
        .sets = &.{},
    };
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    const caps = [_]Capability{
        .{ .identifier = "a", .windows = &.{"main"}, .permissions = &.{"fs:a"} },
        .{ .identifier = "b", .windows = &.{"main"}, .permissions = &.{"fs:b"} },
    };
    var gt = try GrantTable.compile(std.testing.allocator, &caps, &custom, .{}, &.{"main"}, &diags);
    defer gt.deinit();
    const set = gt.scopeFor("main", "fs.readFile");
    try std.testing.expectEqual(@as(usize, 1), set.allow.len);
    try std.testing.expectEqual(@as(usize, 0), set.deny.len); // cap b's deny does NOT bleed in
}

test "wildcard cap: a label not in known_labels is fail-closed at originsFor/scopeFor" {
    // A wildcard cap ("*") grants fs.readFile with a dev origin + a scope. Under a
    // KNOWN label the merge surfaces both; under a label NOT in known_labels the
    // origin/scope lookups fail closed (empty), even though commandGranted globs
    // "*" and would allow. This pins the intended fail-closed divergence.
    const custom = cap.Catalog{
        .permissions = &.{
            .{ .identifier = "fs:a", .commands_allow = &.{"fs.readFile"}, .scope_allow = &.{.{ .path = "$APPDATA/**" }} },
        },
        .sets = &.{},
    };
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    const caps = [_]Capability{.{ .identifier = "wild", .windows = &.{"*"}, .origins = &.{.{ .https_exact = "https://x.example" }}, .permissions = &.{"fs:a"} }};
    // Only "main" is a known label; "popup" is a runtime-created label absent here.
    var gt = try GrantTable.compile(std.testing.allocator, &caps, &custom, .{ .allowRemoteContent = true }, &.{"main"}, &diags);
    defer gt.deinit();
    // Known label: merged origin + scope present.
    try std.testing.expect(gt.originsFor("main").len == 1);
    try std.testing.expectEqual(@as(usize, 1), gt.scopeFor("main", "fs.readFile").allow.len);
    // Unknown label: fail-closed (app_scheme-only origins, empty scope), despite
    // commandGranted globbing "*".
    try std.testing.expectEqual(@as(usize, 0), gt.originsFor("popup").len);
    try std.testing.expectEqual(@as(usize, 0), gt.scopeFor("popup", "fs.readFile").allow.len);
    try std.testing.expect(gt.commandGranted("popup", "fs.readFile"));
}

test "dev_url origin is dropped from the compiled trust set outside Debug" {
    // Belt: a shipped (ReleaseSafe) binary carries no dev-server origin. Under
    // Debug the dev origin is kept; under ReleaseSafe compile() drops it.
    const caps = [_]Capability{.{ .identifier = "c", .windows = &.{"main"}, .origins = &.{ .app_scheme, .{ .dev_url = "http://localhost:5173" } }, .permissions = &.{"core:default"} }};
    var gt = try compileOne(&caps, .{});
    defer gt.deinit();
    var has_dev = false;
    for (gt.originsFor("main")) |o| if (o == .dev_url) {
        has_dev = true;
    };
    if (builtin.mode == .Debug) {
        try std.testing.expect(has_dev);
    } else {
        try std.testing.expect(!has_dev);
    }
}
