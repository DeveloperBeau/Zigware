const std = @import("std");

pub const Allowlist = struct {
    pub const max_commands = 64;

    names: [max_commands][]const u8 = undefined,
    count: usize = 0,

    pub const empty: Allowlist = .{};

    /// The slice must remain valid for the Allowlist's lifetime (PoC passes string literals).
    pub fn add(self: *Allowlist, name: []const u8) !void {
        if (self.count >= max_commands) return error.TooManyCommands;
        if (self.contains(name)) return error.DuplicateCommand;
        self.names[self.count] = name;
        self.count += 1;
    }

    pub fn contains(self: *const Allowlist, name: []const u8) bool {
        if (name.len == 0) return false;
        for (self.names[0..self.count]) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }
};

test "registered command is allowed; unknown is rejected" {
    var a: Allowlist = .empty;
    try a.add("sha256");
    try std.testing.expect(a.contains("sha256"));
    try std.testing.expect(!a.contains("rm-rf"));
    try std.testing.expect(!a.contains(""));
}

test "duplicate add errors" {
    var a: Allowlist = .empty;
    try a.add("sha256");
    try std.testing.expectError(error.DuplicateCommand, a.add("sha256"));
}

test "fuzz: arbitrary names never bypass the allowlist" {
    try std.testing.fuzz({}, fuzzAllow, .{});
}

fn fuzzAllow(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    const input = buf[0..n];
    var a: Allowlist = .empty;
    try a.add("sha256");
    if (a.contains(input)) try std.testing.expectEqualStrings("sha256", input);
}
