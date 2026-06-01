const std = @import("std");
const objc = @import("objc");
const dispatch = @import("dispatch.zig");

/// A heap-owned hop carrying an alive flag, the webview, and a sentinel-
/// terminated JS copy from a worker thread to the main thread, where
/// evaluateJavaScript is legal. `alive` is borrowed from the backend; the
/// pointer must outlive any pending hop. The backend's infallible deinit drains
/// the main queue (B2) BEFORE freeing itself, so no hop ever reads freed alive.
/// The hop also RETAINS the webview on enqueue and releases it on run (L5) so a
/// window-close-before-quit (sub-project E) cannot free the webview mid-hop.
pub const Hop = struct {
    alloc: std.mem.Allocator,
    alive: *const std.atomic.Value(bool),
    webview: objc.id,
    js: [:0]u8,
};

pub fn runOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const hop: *Hop = @ptrCast(@alignCast(ctx.?));
    // Autorelease pool around the whole IMP body (M2).
    const NSAutoreleasePool = objc.class("NSAutoreleasePool");
    const poolAlloc = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(NSAutoreleasePool, objc.sel("alloc"));
    const pool = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(poolAlloc, objc.sel("init"));
    defer {
        _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(pool, objc.sel("drain"));
        // Release the retain taken at enqueue (L5), free the hop+js.
        _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(hop.webview, objc.sel("release"));
        hop.alloc.free(hop.js);
        hop.alloc.destroy(hop);
    }
    // Re-check alive on the main thread BEFORE touching the webview. Between
    // enqueue and run, terminate() may have flipped alive. Canonical UAF fix.
    if (!hop.alive.load(.acquire)) return;

    // initWithBytes:length:encoding: (UTF8 = 4), NOT stringWithUTF8String:,
    // so an embedded NUL does not truncate the payload (M8). hop.js is
    // pre-validated NUL-free in eval() (debug assert).
    const NSString = objc.class("NSString");
    const strAlloc = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(NSString, objc.sel("alloc"));
    const nsjs = objc.msgSend(*const fn (objc.id, objc.SEL, [*]const u8, usize, u64) callconv(.c) objc.id)(strAlloc, objc.sel("initWithBytes:length:encoding:"), hop.js.ptr, hop.js.len, 4);
    defer _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(nsjs, objc.sel("release"));
    _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) objc.id)(hop.webview, objc.sel("evaluateJavaScript:completionHandler:"), nsjs, null);
}

/// Copy `js` to a sentinel buffer and hop to the main thread. RETAIN the
/// webview here; runOnMain releases it. Returns silently on OOM. Debug-asserts
/// the payload is NUL-free (M8).
pub fn eval(alloc: std.mem.Allocator, alive: *const std.atomic.Value(bool), webview: objc.id, js: []const u8) void {
    std.debug.assert(std.mem.indexOfScalar(u8, js, 0) == null);
    const buf = alloc.allocSentinel(u8, js.len, 0) catch return;
    @memcpy(buf, js);
    const hop = alloc.create(Hop) catch {
        alloc.free(buf);
        return;
    };
    hop.* = .{ .alloc = alloc, .alive = alive, .webview = webview, .js = buf };
    _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(webview, objc.sel("retain")); // L5
    dispatch.async_(runOnMain, hop);
}

/// Add a user script to the UCC at document start (mainFrameOnly = true).
/// Rejects raw NUL because the silent truncation would inject a partial shim.
/// Uses initWithBytes:length:encoding: (length-explicit, no NUL truncation).
/// Wrapped in alloc/init pairs released explicitly (M2).
pub fn injectUserScript(ucc: objc.id, source: []const u8) error{ScriptContainsNul}!void {
    if (std.mem.indexOfScalar(u8, source, 0) != null) return error.ScriptContainsNul;
    const NSString = objc.class("NSString");
    const strAlloc = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(NSString, objc.sel("alloc"));
    const ns_str = objc.msgSend(*const fn (objc.id, objc.SEL, [*]const u8, usize, u64) callconv(.c) objc.id)(strAlloc, objc.sel("initWithBytes:length:encoding:"), source.ptr, source.len, 4);
    defer _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(ns_str, objc.sel("release"));

    const WKUserScript = objc.class("WKUserScript");
    const scriptAlloc = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(WKUserScript, objc.sel("alloc"));
    const userScript = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id, i64, bool) callconv(.c) objc.id)(scriptAlloc, objc.sel("initWithSource:injectionTime:forMainFrameOnly:"), ns_str, 0, true);
    defer _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(userScript, objc.sel("release"));
    _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) void)(ucc, objc.sel("addUserScript:"), userScript);
    // addUserScript: retains; our explicit release is the alloc-paired release.
}
