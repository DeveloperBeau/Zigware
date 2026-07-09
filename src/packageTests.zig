// Single compilation root for the packaging module's tests. Mirrors manifestTests.zig.
comptime {
    _ = @import("package/packager.zig");
    _ = @import("package/runner.zig");
    _ = @import("package/diagnostics.zig");
    _ = @import("package/configuration.zig");
    _ = @import("package/bundle.zig");
    _ = @import("package/sign.zig");
    _ = @import("package/notarize.zig");
    _ = @import("package/dmg.zig");
    // Force-analyze the top-level `package()` entry (and the private real-environ
    // builder it alone calls) even though the headless tests drive `packageInner`.
    // Without this reference the real-credential path stays unanalyzed until Task 12
    // wires the CLI caller, so a compile error in it would not surface here.
    _ = &@import("package/packager.zig").package;
}
