//! Stable command barrel for the four crypto examples. addApp's dts-main and
//! the run exe both reach the app command surface through this one file, so the
//! examples carry no per-example Zig source. The four examples' build.zig files
//! root this barrel via b.path("../_shared/commands.zig").
const crypto = @import("crypto.zig");

pub const State = crypto.State;
pub const Commands = crypto.Commands;

test {
    // Pull the crypto unit tests (in crypto.zig) into the headless `zig build
    // test` step. Imported-file tests are not auto-discovered; this reference is
    // what runs them.
    _ = crypto;
}
