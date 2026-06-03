//! Test root for the window-lifecycle units. Pulls every window-unit file into
//! one compilation so `zig build test` runs their file-scope tests. Mirrors
//! src/manifest_tests.zig (src-level so the window units' `../platform/...`
//! relative imports resolve inside `src/`). Window unit tests are written as
//! FILE-SCOPE `test` blocks that reference WindowManager(NullBackend)/
//! Lifecycle(NullBackend) directly (refAllDeclsRecursive does NOT instantiate
//! `fn(comptime B) type`, so tests must not hide inside a returned struct body).
const std = @import("std");

comptime {
    _ = @import("window/window.zig");
    _ = @import("window/manager.zig");
    _ = @import("window/lifecycle.zig");
    _ = @import("window/commands.zig");
}
