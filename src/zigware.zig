//! Public framework surface for in-repo example apps.
//!
//! An in-repo example (e.g. `examples/notes/`) is rooted in its OWN module dir,
//! so it cannot reach `src/*.zig` by relative path without escaping that root.
//! This barrel is rooted in `src/` and re-exports the public types an app
//! author needs, so the example imports the framework as a single named module
//! (`@import("zigware")`) and every framework file resolves its `src/`-relative
//! imports inside this module.
//!
//! The example links the REAL framework modules through this barrel; it does not
//! vendor a template copy (that concern belongs to the scaffold path, not the
//! in-repo example).

const command_ctx = @import("command_ctx.zig");
const compute_mod = @import("compute.zig");
const builtin = @import("builtin");

// ReleaseSafe enforcement: Zigware never ships with bounds checks stripped.
// Lives here so ANY consumer compiling against the framework barrel inherits
// the ban; a scaffolded main.zig keeps a documentation-only mirror.
comptime {
    if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
        @compileError("Zigware ships ReleaseSafe or Debug only");
    }
}

/// PER-OS BACKEND SEAM. Selects a backend by target OS. The primary per-OS
/// seams are this switch and `addApp`'s link guard (build_helpers.zig, Task 4):
/// add a branch here plus a new backend module, and a link branch there. A port
/// also conditionalizes the `objc` import (src/objc.zig, wired into the barrel)
/// and the `platform/macos/*` reachability, which are macOS-coupled touchpoints.
/// No Linux/Windows code now (YAGNI).
/// A scaffolded main.zig calls `z.Backend()` instead of duplicating this switch.
pub fn Backend() type {
    return switch (builtin.os.tag) {
        .macos => MacOSBackend,
        else => @compileError("zigware v0.1.0 targets macOS only"),
    };
}

// ── Backend + orchestrator ──────────────────────────────────────────────────
pub const App = @import("app.zig").App;
pub const MacOSBackend = @import("platform/macos/backend.zig").MacOSBackend;
pub const NullBackend = @import("platform/null.zig").NullBackend;
pub const Bridge = @import("bridge.zig").Bridge;

// ── Command handler surface ─────────────────────────────────────────────────
pub const Ctx = command_ctx.Ctx;
pub const Result = command_ctx.Result;
pub const Async = command_ctx.Async;
pub const done = command_ctx.done;
pub const Bytes = command_ctx.Bytes;
pub const Channel = command_ctx.Channel;
pub const CommandError = command_ctx.CommandError;
/// The shared command State. App handlers take `*Ctx(State)`; this is the exact
/// type the App's bridge instantiates, so an app's commands compose with the
/// builtins over one State. Stateless apps ignore `ctx.state`.
pub const State = @import("commands/builtin.zig").State;

// ── Compute sugar (offload progress + cancel) ───────────────────────────────
pub const Sink = compute_mod.Sink;
pub const CancelToken = compute_mod.CancelToken;
pub const ComputeError = compute_mod.ComputeError;
pub const Worker = compute_mod.Worker;

// ── Security catalog + grant table (for headless integration harnesses) ─────
pub const capability = @import("security/capability.zig");
pub const gates = @import("security/gates.zig");
pub const GrantTable = @import("security/grant_table.zig").GrantTable;
pub const defaults = @import("security/defaults.zig");

// ── Manifest loader (D) ─────────────────────────────────────────────────────
pub const manifest = @import("manifest/types.zig");
pub const parse = @import("manifest/parse.zig");

test {
    // Pull the re-exported surface into this root so a `zig test` over the
    // barrel still compiles every referenced framework decl.
    @import("std").testing.refAllDecls(@This());
}
