const std = @import("std");

test {
    _ = @import("manifest/types.zig");
    _ = @import("manifest/parse.zig");
    _ = @import("manifest/validate.zig");
    _ = @import("manifest/merge.zig");
}

test "manifest test root mounted" {
    try std.testing.expect(@typeInfo(@import("manifest/types.zig").Manifest).@"struct".fields.len >= 4);
}
