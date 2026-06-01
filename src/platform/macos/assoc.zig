// src/platform/macos/assoc.zig
const objc = @import("objc");

/// OBJC_ASSOCIATION_ASSIGN = 0. We store a raw Zig *MacOSBackend pointer cast to
/// objc.id, which is NOT a real objc object, so the runtime must not try to
/// retain/release it. The assign policy (0) stores the pointer verbatim.
/// Verified against <objc/runtime.h>: OBJC_ASSOCIATION_ASSIGN == 0.
pub const ASSOCIATION_ASSIGN: usize = 0;

/// OBJC_ASSOCIATION_RETAIN_NONATOMIC = 1. Kept for reference; not used for the
/// backend pointer (see ASSOCIATION_ASSIGN above).
pub const ASSOCIATION_RETAIN_NONATOMIC: usize = 1;

pub extern fn objc_setAssociatedObject(object: objc.id, key: ?*const anyopaque, value: objc.id, policy: usize) void;
pub extern fn objc_getAssociatedObject(object: objc.id, key: ?*const anyopaque) objc.id;
