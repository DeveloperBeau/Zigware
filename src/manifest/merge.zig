//! STUB — Task 7 replaces this file with the deep-dup merge. Returns the
//! base verbatim (no merge applied) so parse.zig compiles before merge
//! logic lands.
const std = @import("std");
const types = @import("types.zig");

pub fn merge(
    _: std.mem.Allocator,
    base: types.Manifest,
    _: ?types.OverrideManifest,
) std.mem.Allocator.Error!types.Manifest {
    return base;
}
