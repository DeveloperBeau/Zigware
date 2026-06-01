//! Single test root for the src/security/ package. Each security file imports
//! siblings/parents via `../`, so none can be its own addLogicTest module root;
//! they are all pulled in here under one module rooted at src/. Add a line as
//! each security file lands.
comptime {
    _ = @import("security/capability.zig");
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("security/capability.zig");
}

const std = @import("std");
