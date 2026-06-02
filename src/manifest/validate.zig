//! STUB — Task 6 replaces this file. Returns true unconditionally so
//! parse.zig compiles before validate logic lands.
const std = @import("std");
const types = @import("types.zig");

pub fn validate(
    _: std.mem.Allocator,
    _: types.Manifest,
    _: std.builtin.OptimizeMode,
    _: []const []const u8,
    _: *types.Diagnostics,
) std.mem.Allocator.Error!bool {
    return true;
}
