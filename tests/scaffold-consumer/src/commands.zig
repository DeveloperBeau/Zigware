//! Stable command barrel. addApp's dts-main and the run exe both reach the
//! app's command surface through this one file, so swapping the leaf command
//! file needs no import patching.
const greet = @import("commands/greet.zig");

pub const State = greet.State;
pub const Commands = greet.Commands;
