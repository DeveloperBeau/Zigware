//! Coverage aggregation root for the headless logic surface.
//!
//! kcov instruments the single `logic-tests` binary. app.zig transitively
//! reaches bridge, the null backend, assets, the backend contract, protocol,
//! allowlist, jobs, and commands, so rooting here covers all of those. The two
//! pure macOS helpers (origin.zig, schemeLogic.zig) are only imported by the
//! objc backend, which app.zig never pulls in, so they are referenced here
//! explicitly: that runs their tests in this binary and lets kcov report their
//! coverage. They carry no Cocoa/WebKit dependency, so no GUI is needed.
//! The registry, per-call context, and built-in command modules are imported by
//! bridge.zig with plain top-level `const`s, which compile them in but do not run
//! their own `test` blocks. They are referenced here explicitly so those unit
//! tests execute in this binary and kcov reports their coverage.
test {
    _ = @import("app.zig");
    _ = @import("securityRegression.zig");
    _ = @import("platform/macos/origin.zig");
    _ = @import("platform/macos/schemeLogic.zig");
    _ = @import("registry.zig");
    _ = @import("commandContext.zig");
    _ = @import("commands/builtin.zig");
    _ = @import("security/capability.zig");
    _ = @import("security/defaults.zig");
    _ = @import("security/grantTable.zig");
    _ = @import("security/gates.zig");
    _ = @import("security/navigation.zig");
    _ = @import("security/scope/glob.zig");
    _ = @import("security/scope/path.zig");
    _ = @import("security/scope/host.zig");
    _ = @import("security/scope/argv.zig");
    _ = @import("security/scope/label.zig");
    _ = @import("manifest/types.zig");
    _ = @import("manifest/parse.zig");
    _ = @import("manifest/validate.zig");
    _ = @import("manifest/merge.zig");
    _ = @import("manifest/schemaGeneration.zig");
    _ = @import("manifest/fuses.zig");
}
