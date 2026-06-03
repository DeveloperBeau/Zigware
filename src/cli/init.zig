const std = @import("std");

pub const Template = enum { vanilla, react, vue, svelte };

pub const InitOptions = struct {
    dir: []const u8,
    name: []const u8,
    template: Template = .vanilla,
    force: bool = false,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, opts: InitOptions) anyerror!void {
    _ = io;
    _ = gpa;
    _ = opts;
    return error.NotImplemented;
}
