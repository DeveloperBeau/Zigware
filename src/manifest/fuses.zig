const std = @import("std");
const m = @import("zigware_manifest_zon");
pub const allow_remote_content = m.security.fuses.allowRemoteContent;
pub const allow_eval = m.security.fuses.allowEval;
pub const allow_shell = m.security.fuses.allowShell;
pub const debug_inspector = m.security.fuses.debugInspector;

test "fuse constants are comptime-known and match the embedded manifest" {
    const embedded = @import("zigware_manifest_zon");
    // The comptime block is the lock: every expression inside must be
    // comptime-evaluable, so if a refactor makes any fuse a runtime value,
    // THIS block fails to compile. The @as(bool, ...) coercion is redundant
    // (bool is the declared type) but explicit; keep both for grep-ability
    // and to make the intent obvious at code-review time.
    comptime {
        _ = @as(bool, allow_remote_content);
        _ = @as(bool, allow_eval);
        _ = @as(bool, allow_shell);
        _ = @as(bool, debug_inspector);
    }
    try std.testing.expectEqual(embedded.security.fuses.allowShell, allow_shell);
    try std.testing.expectEqual(embedded.security.fuses.allowRemoteContent, allow_remote_content);
    try std.testing.expectEqual(embedded.security.fuses.allowEval, allow_eval);
    try std.testing.expectEqual(embedded.security.fuses.debugInspector, debug_inspector);
}
