// Single compilation root for the packaging module's tests. Mirrors manifest_tests.zig.
comptime {
    _ = @import("package/packager.zig");
    _ = @import("package/runner.zig");
    _ = @import("package/diagnostics.zig");
    // config.zig, bundle.zig, sign.zig, notarize.zig, dmg.zig added as their tasks land.
}
