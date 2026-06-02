const std = @import("std");
const cap = @import("../capability.zig");
const glob = @import("glob.zig");
const grant = @import("../grant_table.zig");
const HostRule = cap.HostRule;
const ScopeSet = grant.ScopeSet;

/// Lower-ASCII fold a host into `buf`. IDN is out of scope for v0.1.0; bytes are
/// folded as ASCII only.
fn foldHost(buf: []u8, host: []const u8) ?[]const u8 {
    if (host.len > buf.len) return null;
    for (host, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..host.len];
}

/// Match a host rule's glob: `*.example.com` matches one or more leftmost labels
/// (never the bare apex unless listed separately). Port null == any port.
fn ruleMatches(rule: HostRule, host: []const u8, port: ?u16) bool {
    if (rule.port) |rp| {
        if (port == null or port.? != rp) return false;
    }
    // Host glob over '.'-separated labels. Reuse the segment globber by swapping
    // '.' for '/' so `*` stays within a label and we get apex semantics right via
    // an explicit leftmost-label rule.
    return hostGlob(rule.host, host);
}

fn hostGlob(pattern: []const u8, host: []const u8) bool {
    // `*.suffix` requires at least one leading label. Otherwise exact (case-folded).
    if (std.mem.startsWith(u8, pattern, "*.")) {
        const suffix = pattern[2..];
        if (!std.mem.endsWith(u8, host, suffix)) return false;
        if (host.len <= suffix.len) return false; // must have a non-empty leading label
        const lead = host[0 .. host.len - suffix.len];
        // lead must end with '.' (a full label boundary) and be non-empty before it.
        return lead.len >= 2 and lead[lead.len - 1] == '.';
    }
    return std.mem.eql(u8, pattern, host);
}

pub fn hostMatches(set: ScopeSet, candidate: HostRule) bool {
    var hb: [253]u8 = undefined; // max DNS name
    const folded = foldHost(&hb, candidate.host) orelse return false;
    for (set.deny) |s| switch (s) {
        .host => |r| {
            var rb: [253]u8 = undefined;
            const rf = foldHost(&rb, r.host) orelse continue;
            if (ruleMatches(.{ .host = rf, .port = r.port }, folded, candidate.port)) return false;
        },
        else => {},
    };
    for (set.allow) |s| switch (s) {
        .host => |r| {
            var rb: [253]u8 = undefined;
            const rf = foldHost(&rb, r.host) orelse continue;
            if (ruleMatches(.{ .host = rf, .port = r.port }, folded, candidate.port)) return true;
        },
        else => {},
    };
    return false;
}

test "host glob: wildcard subdomain, exact, port" {
    const set = ScopeSet{ .allow = &.{.{ .host = .{ .host = "*.example.com", .port = 443 } }}, .deny = &.{} };
    try std.testing.expect(hostMatches(set, .{ .host = "api.example.com", .port = 443 }));
    try std.testing.expect(!hostMatches(set, .{ .host = "api.example.com", .port = 80 })); // wrong port
    try std.testing.expect(!hostMatches(set, .{ .host = "example.com", .port = 443 })); // apex not matched by *.
    try std.testing.expect(!hostMatches(set, .{ .host = "evil.com", .port = 443 }));
}

test "host: case-folded, deny beats allow" {
    const set = ScopeSet{ .allow = &.{.{ .host = .{ .host = "api.x.com" } }}, .deny = &.{.{ .host = .{ .host = "api.x.com" } }} };
    try std.testing.expect(!hostMatches(set, .{ .host = "API.X.COM" }));
}

test "host: empty set denies" {
    try std.testing.expect(!hostMatches(ScopeSet.empty, .{ .host = "x.com" }));
}
