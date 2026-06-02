//! Single test root for the src/security/ package. Each security file imports
//! siblings/parents via `../`, so none can be its own addLogicTest module root;
//! they are all pulled in here under one module rooted at src/. Add a line as
//! each security file lands.
comptime {
    _ = @import("security/capability.zig");
    _ = @import("security/defaults.zig");
    _ = @import("security/scope/glob.zig");
    _ = @import("security/scope/path.zig");
    _ = @import("security/grant_table.zig");
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("security/capability.zig");
    _ = @import("security/defaults.zig");
    _ = @import("security/scope/glob.zig");
    _ = @import("security/scope/path.zig");
    _ = @import("security/grant_table.zig");
}

const std = @import("std");
