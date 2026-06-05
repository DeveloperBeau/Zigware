//! src/-rooted aggregator for the pure hashing leaves. Rooting the test here
//! (not at src/commands/sha256.zig) keeps their `../compute.zig` import inside
//! the src/ module root, so the by-value CancelToken signature resolves the same
//! way it does in every real compilation context.

test {
    _ = @import("commands/sha256.zig");
    _ = @import("commands/demo.zig");
}
