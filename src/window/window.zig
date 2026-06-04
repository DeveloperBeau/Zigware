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

/// A small heap cell carrying everything a watchdog thread needs, independent of
/// the WindowEntry lifetime. Owns its OWN label copy (distinct from the entry's
/// map-key label) so freeing it never double-frees the entry's label. Non-generic
/// (none of its fields use B): `mgr` is type-erased and cast back inside the
/// manager. `WindowEntry(B).watchdog` is `?*WatchdogCtx`.
pub const WatchdogCtx = struct {
    mgr: *anyopaque, // *WindowManager(B); cast back inside the manager
    label: []u8, // OWNED copy, freed exactly once by cancelWatchdog
    cancel: std.atomic.Value(bool) = .{ .raw = false },
    fallback_ms: u32,
};

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
        // Watchdog bookkeeping (Task 5). null once cancelled/fired-and-reaped.
        watchdog: ?*WatchdogCtx = null,
        watchdog_thread: ?std.Thread = null,
    };
}

test "titleBarStyleToSeam maps D's three variants onto the seam's two" {
    try std.testing.expectEqual(seam.TitleBarStyle.standard, titleBarStyleToSeam(.default));
    try std.testing.expectEqual(seam.TitleBarStyle.hidden, titleBarStyleToSeam(.hidden));
    try std.testing.expectEqual(seam.TitleBarStyle.hidden, titleBarStyleToSeam(.hidden_inset));
}
