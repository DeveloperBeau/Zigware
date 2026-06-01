const std = @import("std");

/// VERIFY-ON-TOOLCHAIN ADAPTATION (L2): `dispatch_get_main_queue()` is a
/// header-only `static inline` in <dispatch/queue.h>; it is NOT an exported
/// symbol, so `extern fn dispatch_get_main_queue()` fails to link
/// (`undefined symbol: _dispatch_get_main_queue`). The inline simply returns
/// `&_dispatch_main_q`, the real exported global. Declare that global and take
/// its address; libdispatch links via libSystem (pulled in by Cocoa + libc).
pub extern var _dispatch_main_q: anyopaque;
pub fn dispatch_get_main_queue() ?*anyopaque {
    return &_dispatch_main_q;
}
pub extern fn dispatch_async_f(queue: ?*anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
pub extern fn dispatch_sync_f(queue: ?*anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

/// pthread_main_np: 1 if the calling thread is the main thread.
pub extern fn pthread_main_np() c_int;

/// CoreFoundation. kCFRunLoopDefaultMode is the framework's mode constant;
/// CFRunLoop compares modes by POINTER IDENTITY, so we must pass the real
/// global, never a CFString we built by name (B4). Link CoreFoundation.
pub const CFTimeInterval = f64;
pub extern const kCFRunLoopDefaultMode: ?*anyopaque;
pub extern fn CFRunLoopRunInMode(mode: ?*anyopaque, seconds: CFTimeInterval, returnAfterSourceHandled: bool) i32;

/// Enqueue `work(ctx)` on the main GCD queue, returning immediately.
pub fn async_(work: *const fn (?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void {
    dispatch_async_f(dispatch_get_main_queue(), ctx, work);
}

/// Flush pending main-thread work. Behavior by caller thread:
///   - On the main thread: spin one CFRunLoop iteration in DEFAULT mode so any
///     already-enqueued dispatch_async work runs before we return. A
///     dispatch_sync_f to the main queue FROM the main thread would deadlock
///     (AppKit calls applicationWillTerminate: on the main thread).
///   - On a non-main thread: dispatch_sync_f a no-op behind all pending work.
pub fn drain() void {
    if (pthread_main_np() != 0) {
        _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, false);
        return;
    }
    var sentinel: u8 = 0;
    dispatch_sync_f(dispatch_get_main_queue(), &sentinel, struct {
        fn f(_: ?*anyopaque) callconv(.c) void {}
    }.f);
}
