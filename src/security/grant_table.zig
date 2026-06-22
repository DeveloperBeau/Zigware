const std = @import("std");
const cap = @import("capability.zig");
const glob = @import("scope/glob.zig");
const manifest = @import("../manifest/types.zig");

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

pub const GrantTable = struct {
    arena: std.heap.ArenaAllocator,
    caps: []const CompiledCap,

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

            // Origins: drop https_exact when allowRemoteContent is off (force-deny).
            var origins: std.ArrayList(OriginPattern) = .empty;
            for (c.origins) |o| {
                switch (o) {
                    .https_exact => if (!fuses.allowRemoteContent) {
                        diags.report(gpa, .{ .code = .fuse_requires_capability, .message = "https origin dropped: allowRemoteContent is off" });
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

        return .{ .arena = arena, .caps = try compiled.toOwnedSlice(a) };
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

    /// G4 input: allow/deny scopes for (label, command). A command with no declared
    /// scope returns ScopeSet.empty. (v0.1.0 commands are .none, so this is exercised
    /// by unit tests, not the live path.)
    ///
    /// SECURITY TODO(multi-cap, deviation #5): this returns the FIRST matched cap's
    /// scopes only. If TWO caps match the same window and one carries a DENY scope,
    /// that deny is IGNORED when a different cap is the first allow-match. This is a
    /// deny-beats-allow hole at the TABLE level. This is INERT in v0.1.0 because every
    /// caller (App.init, all test harnesses) declares exactly ONE capability per
    /// window. Before D allows multiple caps per window-label, scopeFor MUST merge
    /// allow across all matched caps and deny across all matched caps (precompute the
    /// merge in compile() per window so the lookup stays allocation-free). A runtime
    /// guard enforces the single-cap assumption: see the assert below.
    pub fn scopeFor(self: *const GrantTable, label: []const u8, command: []const u8) ScopeSet {
        // INERT-GUARD: assert at most one matched cap grants this command for this
        // label, so the multi-cap hole above cannot silently activate. (Cheap; runs
        // only on the .none-free path, which v0.1.0 never hits live.)
        {
            var n: usize = 0;
            for (self.caps) |c| {
                if (!self.windowMatches(c, label)) continue;
                for (c.commands_allow) |al| if (std.mem.eql(u8, al, command)) {
                    n += 1;
                    break;
                };
            }
            std.debug.assert(n <= 1); // multi-cap scope merge not implemented (deviation #5)
        }
        for (self.caps) |c| {
            if (!self.windowMatches(c, label)) continue;
            const grants_cmd = for (c.commands_allow) |al| {
                if (std.mem.eql(u8, al, command)) break true;
            } else false;
            if (grants_cmd) return .{ .allow = c.scope_allow, .deny = c.scope_deny };
        }
        return ScopeSet.empty;
    }

    /// G1 input: origins trusted for this window. Empty slice means app_scheme only.
    pub fn originsFor(self: *const GrantTable, label: []const u8) []const OriginPattern {
        // INERT-GUARD: assert at most one matched cap carries non-empty origins for
        // this label. Multi-cap origin merge is deferred to D (deviation #5 cluster),
        // inert in v0.1.0 (one cap per window).
        {
            var n: usize = 0;
            for (self.caps) |c| {
                if (!self.windowMatches(c, label)) continue;
                if (c.origins.len > 0) n += 1;
            }
            std.debug.assert(n <= 1); // multi-cap origin merge not implemented (deviation #5)
        }
        for (self.caps) |c| {
            if (self.windowMatches(c, label)) {
                if (c.origins.len > 0) return c.origins;
            }
        }
        return &.{}; // empty => app_scheme only (G1 treats empty as {app_scheme})
    }

    fn windowMatches(self: *const GrantTable, c: CompiledCap, label: []const u8) bool {
        _ = self;
        for (c.window_globs) |wg| {
            if (glob.match(wg, label)) return true;
        }
        return false;
    }
};

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

test "scopeFor returns a granted command's allow/deny scopes (and the inert single-cap guard holds)" {
    const custom = cap.Catalog{
        .permissions = &.{.{ .identifier = "fs:x", .commands_allow = &.{"fs.readFile"}, .scope_allow = &.{.{ .path = "$APPDATA/**" }}, .scope_deny = &.{.{ .path = "$APPDATA/secret/**" }} }},
        .sets = &.{},
    };
    var diags: manifest.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    const caps = [_]Capability{.{ .identifier = "c", .windows = &.{"main"}, .permissions = &.{"fs:x"} }};
    var gt = try GrantTable.compile(std.testing.allocator, &caps, &custom, .{}, &.{"main"}, &diags);
    defer gt.deinit();
    const set = gt.scopeFor("main", "fs.readFile"); // exercises the assert(n<=1) inert guard
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
