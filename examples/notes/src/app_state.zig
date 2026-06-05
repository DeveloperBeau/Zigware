//! The notes example's per-app State, injected into every command handler.
//! hashFile is stateless (it reads from disk and hashes), so this is empty; it
//! exists as one nominal type both `main.zig` and the command handlers agree on
//! for the bridge's `*Ctx(State)` first-param contract.
pub const State = struct {};
