const std = @import("std");
const cap = @import("capability.zig");
const backend_mod = @import("../platform/backend.zig");
const OriginPattern = cap.OriginPattern;

/// Wire A's reserved onNavigation. Returns A's NavigationDecision (C does not
/// redefine it). Fail-closed: only app://, the dev URL (debug only), and an
/// already-fuse-filtered https_exact origin are allowed; everything else cancels.
pub fn decideNavigation(origins: []const OriginPattern, target: []const u8, is_debug: bool) backend_mod.NavigationDecision {
    // The trusted prod origin is EXACTLY app://localhost (the one app host), not
    // any app:// host. `app://evil/` and `app://localhost.attacker.com/` must be
    // cancelled (the bug the current app.zig nav guard fixed). Allow app://localhost
    // (with a path) or the bare app://localhost, independent of `origins`, so a
    // window with an empty grant set can still load its own content.
    if (std.mem.startsWith(u8, target, "app://localhost/") or std.mem.eql(u8, target, "app://localhost")) return .allow;
    for (origins) |o| switch (o) {
        .app_scheme => {}, // handled above
        .dev_url => |u| if (is_debug and std.mem.eql(u8, u, target)) return .allow,
        .https_exact => |u| if (std.mem.eql(u8, u, target)) return .allow,
    };
    return .cancel;
}

test "navigation: app://localhost allowed; foreign and app://evil cancelled" {
    try std.testing.expectEqual(backend_mod.NavigationDecision.allow, decideNavigation(&.{}, "app://localhost/index.html", false));
    try std.testing.expectEqual(backend_mod.NavigationDecision.allow, decideNavigation(&.{}, "app://localhost", false));
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, decideNavigation(&.{}, "https://evil.example/", false));
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, decideNavigation(&.{}, "javascript:alert(1)", false));
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, decideNavigation(&.{}, "app://evil/", false)); // not localhost
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, decideNavigation(&.{}, "app://localhost.attacker.com/", false)); // host is not localhost
}

test "navigation: dev url allowed only in debug" {
    const origins = [_]OriginPattern{.{ .dev_url = "http://localhost:1420" }};
    try std.testing.expectEqual(backend_mod.NavigationDecision.allow, decideNavigation(&origins, "http://localhost:1420", true));
    try std.testing.expectEqual(backend_mod.NavigationDecision.cancel, decideNavigation(&origins, "http://localhost:1420", false));
}
