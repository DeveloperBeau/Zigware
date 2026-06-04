// Single compilation root for the packaging module's tests. Mirrors manifest_tests.zig.
comptime {
    _ = @import("package/packager.zig");
    _ = @import("package/runner.zig");
    _ = @import("package/diagnostics.zig");
    _ = @import("package/config.zig");
    _ = @import("package/bundle.zig");
    _ = @import("package/sign.zig");
    _ = @import("package/notarize.zig");
    _ = @import("package/dmg.zig");
}
