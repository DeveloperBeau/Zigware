const objc = @import("objc");
const seam = @import("../backend.zig");

pub const Rect = extern struct { x: f64, y: f64, w: f64, h: f64 };
pub const Size = extern struct { w: f64, h: f64 };

/// Create an NSWindow with the given size. Returns the window id.
pub fn create(opts: seam.WindowOpts) objc.id {
    const NSWindow = objc.class("NSWindow");
    const win = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(NSWindow, objc.sel("alloc"));
    const frame = Rect{ .x = 100, .y = 100, .w = opts.width, .h = opts.height };
    const styleMask: u64 = 1 | 2 | 4 | 8; // titled, closable, miniaturizable, resizable
    const initWin = objc.msgSend(*const fn (objc.id, objc.SEL, Rect, u64, i64, bool) callconv(.c) objc.id);
    const window = initWin(win, objc.sel("initWithContentRect:styleMask:backing:defer:"), frame, styleMask, 2, false);
    _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) void)(window, objc.sel("setTitle:"), objc.nsString(opts.title.ptr));
    return window;
}

pub fn setTitle(window: objc.id, title: [:0]const u8) void {
    _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) void)(window, objc.sel("setTitle:"), objc.nsString(title.ptr));
}

/// setContentSize: takes an NSSize ONLY (no display flag) (L7).
pub fn setSize(window: objc.id, w: f64, h: f64) void {
    _ = objc.msgSend(*const fn (objc.id, objc.SEL, Size) callconv(.c) void)(window, objc.sel("setContentSize:"), .{ .w = w, .h = h });
}

pub fn setFullscreen(window: objc.id, _: bool) void {
    _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) void)(window, objc.sel("toggleFullScreen:"), null);
}

pub fn show(window: objc.id) void {
    _ = objc.msgSend(*const fn (objc.id, objc.SEL, bool) callconv(.c) void)(window, objc.sel("makeKeyAndOrderFront:"), true);
}

pub fn focus(window: objc.id) void {
    _ = objc.msgSend(*const fn (objc.id, objc.SEL, bool) callconv(.c) void)(window, objc.sel("makeKeyAndOrderFront:"), true);
}
