const std = @import("std");
const seam = @import("../platform/backend.zig");
const D = @import("../manifest/types.zig");

/// Map D's titlebar enum (default | hidden | hidden_inset) to the seam's
/// (standard | hidden). hidden_inset collapses to .hidden; the inset distinction
/// is not modeled at the seam in v0.1.0 (documented v0.2 item).
pub fn titleBarStyleToSeam(s: D.TitleBarStyle) seam.TitleBarStyle {
    return switch (s) {
        .default => .standard,
        .hidden, .hidden_inset => .hidden,
    };
}

/// Create options for a runtime window. Field names match D's `Window`. width/
/// height are u32 (D's units), converted to the seam's f64 by the manager.
pub fn CreateOptions(comptime B: type) type {
    _ = B;
    return struct {
        label: []const u8,
        url: ?[]const u8 = null, // null derives app:// (dev URL later, F)
        title: []const u8 = "",
        width: u32 = 800,
        height: u32 = 600,
        decorations: bool = true,
        title_bar_style: D.TitleBarStyle = .default,
        show: bool = false, // caller intent; manager always creates hidden
    };
}

/// One live window. Heap-allocated (`gpa.create`) and borrowed through the maps,
/// so a returned `*WindowEntry` stays valid until that entry is closed.
pub fn WindowEntry(comptime B: type) type {
    return struct {
        label: []const u8, // manager-owned map key, freed on close
        handle: B.WindowHandle,
        window_id: B.WindowId,
        want_show: bool,
        shown: bool,
        ready: bool,
        closing: bool,
        // Show-fallback bookkeeping. The fallback is a MAIN-THREAD TIMER (no OS
        // thread). `fallback_timer` is the backend cancellation token; null once
        // cancelled or fired. `fallback_ctx` is the manager's heap FireCtx (typed
        // *anyopaque here because window.zig must not import the manager), freed
        // exactly once by whichever of fireMain/cancelWatchdog runs first.
        fallback_timer: ?u64 = null,
        fallback_ctx: ?*anyopaque = null,
    };
}

test "titleBarStyleToSeam maps D's three variants onto the seam's two" {
    try std.testing.expectEqual(seam.TitleBarStyle.standard, titleBarStyleToSeam(.default));
    try std.testing.expectEqual(seam.TitleBarStyle.hidden, titleBarStyleToSeam(.hidden));
    try std.testing.expectEqual(seam.TitleBarStyle.hidden, titleBarStyleToSeam(.hidden_inset));
}
