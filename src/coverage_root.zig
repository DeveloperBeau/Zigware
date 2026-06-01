//! Coverage aggregation root for the headless logic surface.
//!
//! kcov instruments the single `logic-tests` binary. app.zig transitively
//! reaches bridge, the null backend, assets, the backend contract, protocol,
//! allowlist, jobs, and commands, so rooting here covers all of those. The two
//! pure macOS helpers (origin.zig, scheme_logic.zig) are only imported by the
//! objc backend, which app.zig never pulls in, so they are referenced here
//! explicitly: that runs their tests in this binary and lets kcov report their
//! coverage. They carry no Cocoa/WebKit dependency, so no GUI is needed.
test {
    _ = @import("app.zig");
    _ = @import("platform/macos/origin.zig");
    _ = @import("platform/macos/scheme_logic.zig");
}
