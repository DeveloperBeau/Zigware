//! Stable command barrel for the notes example. addApp's dts-main and the run
//! exe reach the app command surface through this one file.
const hash_file = @import("commands/hash_file.zig");

pub const State = @import("app_state.zig").State;

pub const Commands = struct {
    pub const hashFile = hash_file.hashFile;
};

test {
    // Pull any hash_file unit tests into the headless `zig build test` step.
    _ = hash_file;
}
