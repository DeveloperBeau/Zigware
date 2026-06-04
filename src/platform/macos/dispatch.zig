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

// ─── GCD dispatch-source timer (the main-thread show-fallback) ───────────────
//
// A dispatch_source TIMER gives REAL cancellation: after dispatch_source_cancel
// runs, the event handler is GUARANTEED never to fire, so a late fallback cannot
// touch freed state. (A bare dispatch_after_f would still fire at its deadline
// even after teardown and dereference a freed backend/map.) The handler is a C
// function pointer, so no Objective-C block literal is needed — Zig has none.
//
// DISPATCH_SOURCE_TYPE_TIMER is a header-only global struct address (like
// _dispatch_main_q in this file is for dispatch_get_main_queue): declare the
// exported global and take its address rather than calling a static-inline.
pub const dispatch_source_t = ?*anyopaque;
pub extern var _dispatch_source_type_timer: anyopaque;
pub fn DISPATCH_SOURCE_TYPE_TIMER() *anyopaque {
    return &_dispatch_source_type_timer;
}
pub extern fn dispatch_source_create(type_: ?*anyopaque, handle: usize, mask: usize, queue: ?*anyopaque) dispatch_source_t;
pub extern fn dispatch_source_set_timer(source: dispatch_source_t, start: u64, interval: u64, leeway: u64) void;
pub extern fn dispatch_source_set_event_handler_f(source: dispatch_source_t, handler: *const fn (?*anyopaque) callconv(.c) void) void;
pub extern fn dispatch_set_context(object: ?*anyopaque, context: ?*anyopaque) void;
pub extern fn dispatch_get_context(object: ?*anyopaque) ?*anyopaque;
pub extern fn dispatch_source_cancel(source: dispatch_source_t) void;
pub extern fn dispatch_resume(object: ?*anyopaque) void;
pub extern fn dispatch_release(object: ?*anyopaque) void;

// dispatch_time(when, delta_ns): a wall-relative deadline. DISPATCH_TIME_NOW is 0.
pub extern fn dispatch_time(when: u64, delta: i64) u64;
pub const DISPATCH_TIME_NOW: u64 = 0;
pub const NSEC_PER_MSEC: u64 = 1_000_000;
pub const DISPATCH_TIMER_FOREVER: u64 = ~@as(u64, 0); // no repeat: interval = forever

/// pthread_main_np: 1 if the calling thread is the main thread.
pub extern fn pthread_main_np() c_int;

/// CoreFoundation. kCFRunLoopDefaultMode is the framework's mode constant;
/// CFRunLoop compares modes by POINTER IDENTITY, so we must pass the real
/// global, never a CFString we built by name (B4). Link CoreFoundation.
pub const CFTimeInterval = f64;
pub extern const kCFRunLoopDefaultMode: ?*anyopaque;
pub extern fn CFRunLoopRunInMode(mode: ?*anyopaque, seconds: CFTimeInterval, returnAfterSourceHandled: bool) i32;

/// CFRunLoopRunInMode return codes (CFRunLoop.h CFRunLoopRunResult):
///   kCFRunLoopRunFinished = 1, kCFRunLoopRunStopped = 2,
///   kCFRunLoopRunTimedOut = 3, kCFRunLoopRunHandledSource = 4.
/// We loop while the runloop reports it handled a source so a block that
/// enqueues another block (e.g. a future evaluateJavaScript completion handler
/// or B's streaming) is drained too; one pass would under-drain -> latent UAF.
pub const kCFRunLoopRunHandledSource: i32 = 4;

/// Enqueue `work(ctx)` on the main GCD queue, returning immediately.
pub fn async_(work: *const fn (?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void {
    dispatch_async_f(dispatch_get_main_queue(), ctx, work);
}

/// Flush pending main-thread work. Behavior by caller thread:
///   - On the main thread: spin CFRunLoop iterations in DEFAULT mode until no
///     source is handled, so any already-enqueued dispatch_async work runs
///     before we return AND any work it enqueues in turn is drained too. A
///     single iteration would under-drain when a drained block enqueues another
///     (a future evaluateJavaScript completion handler, or B's streaming),
///     leaving latent main-queue work that could UAF after free. A
///     dispatch_sync_f to the main queue FROM the main thread would deadlock
///     (AppKit calls applicationWillTerminate: on the main thread).
///   - On a non-main thread: dispatch_sync_f a no-op behind all pending work.
pub fn drain() void {
    if (pthread_main_np() != 0) {
        while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, false) == kCFRunLoopRunHandledSource) {}
        return;
    }
    var sentinel: u8 = 0;
    dispatch_sync_f(dispatch_get_main_queue(), &sentinel, struct {
        fn f(_: ?*anyopaque) callconv(.c) void {}
    }.f);
}
