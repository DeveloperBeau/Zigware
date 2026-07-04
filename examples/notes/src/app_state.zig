//! The notes example's State, injected into every command handler as
//! `*Ctx(State)`. hashFile is stateless (it reads from disk and hashes), and the
//! framework registers all live commands over the one shared `zigware.State`, so
//! this aliases that shared type rather than defining a distinct empty struct.
//! main.zig and the command handlers both agree on it for the bridge's
//! `*Ctx(State)` first-param contract.
pub const State = @import("zigware").State;
