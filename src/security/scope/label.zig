const std = @import("std");
const glob = @import("glob.zig");
const grant = @import("../grantTable.zig");
const ScopeSet = grant.ScopeSet;

/// Window-label value-set scope (E's window.* cross-window commands): which target
/// labels the calling window may act on. Same label glob as the GrantTable window
/// rules (via the shared glob matcher). Deny-first, then require an allow.
pub fn labelMatches(set: ScopeSet, label: []const u8) bool {
    for (set.deny) |s| switch (s) {
        .label => |d| if (glob.match(d, label)) return false,
        else => {},
    };
    for (set.allow) |s| switch (s) {
        .label => |al| if (glob.match(al, label)) return true,
        else => {},
    };
    return false;
}

test "label: glob match, deny beats allow, empty denies" {
    const set = ScopeSet{ .allow = &.{.{ .label = "win-*" }}, .deny = &.{.{ .label = "win-secret" }} };
    try std.testing.expect(labelMatches(set, "win-3"));
    try std.testing.expect(!labelMatches(set, "win-secret")); // deny wins
    try std.testing.expect(!labelMatches(set, "main")); // no allow
    try std.testing.expect(!labelMatches(ScopeSet.empty, "main"));
}

test "label: v0.1.0 only main is a resolvable target" {
    // A label scope allowing "main" is satisfiable; the bridge only resolves "main".
    const set = ScopeSet{ .allow = &.{.{ .label = "main" }}, .deny = &.{} };
    try std.testing.expect(labelMatches(set, "main"));
}
