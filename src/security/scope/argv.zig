const std = @import("std");
const grant = @import("../grantTable.zig");
const ScopeSet = grant.ScopeSet;

/// Shell scope is strictest: every candidate argv token must appear as an EXACT
/// allow entry. No globbing. (deny carve-outs are unnecessary because allow is
/// exhaustive, but a deny token still force-rejects if present.)
pub fn argvMatches(set: ScopeSet, argv: []const []const u8) bool {
    for (argv) |tok| {
        for (set.deny) |s| switch (s) {
            .argv => |d| if (std.mem.eql(u8, d, tok)) return false,
            else => {},
        };
        const allowed = for (set.allow) |s| switch (s) {
            .argv => |al| if (std.mem.eql(u8, al, tok)) break true else continue,
            else => continue,
        } else false;
        if (!allowed) return false; // any token not allowed -> reject the whole argv
    }
    return argv.len > 0; // empty argv against a shell command is not a grant
}

test "argv: every token must be allowed exactly" {
    const set = ScopeSet{ .allow = &.{ .{ .argv = "ls" }, .{ .argv = "-la" } }, .deny = &.{} };
    try std.testing.expect(argvMatches(set, &.{ "ls", "-la" }));
    try std.testing.expect(!argvMatches(set, &.{ "ls", "-rf" })); // -rf not allowed
    try std.testing.expect(!argvMatches(set, &.{"rm"}));
    try std.testing.expect(!argvMatches(set, &.{})); // empty -> no grant
}

test "argv: deny token rejects" {
    const set = ScopeSet{ .allow = &.{ .{ .argv = "ls" }, .{ .argv = "-rf" } }, .deny = &.{.{ .argv = "-rf" }} };
    try std.testing.expect(!argvMatches(set, &.{ "ls", "-rf" }));
}
