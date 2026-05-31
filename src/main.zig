const std = @import("std");
const objc = @import("objc.zig");
const c = objc;

extern var _dispatch_main_q: anyopaque; // dispatch_get_main_queue() resolves to &_dispatch_main_q
extern fn dispatch_async_f(queue: ?*anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

var g_webview: c.id = null;

fn onMessage(self: c.id, _cmd: c.SEL, ucc: c.id, message: c.id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = ucc;
    const body = c.msgSend(*const fn (c.id, c.SEL) callconv(.c) c.id)(message, c.sel("body"));
    if (!c.isKindOf(body, c.class("NSString"))) {
        std.debug.print("JS->Zig: non-string body, dropped\n", .{});
        return;
    }
    const text = c.utf8(body) orelse return;
    std.debug.print("JS->Zig: {s}\n", .{text});
    const js = c.nsString("window.__spikeEcho && window.__spikeEcho('zig got it')");
    _ = c.msgSend(*const fn (c.id, c.SEL, c.id, c.id) callconv(.c) c.id)(g_webview, c.sel("evaluateJavaScript:completionHandler:"), js, null);
    std.debug.print("evaluateJavaScript returned (no crash)\n", .{});
}

fn mainThreadPing(_: ?*anyopaque) callconv(.c) void {
    std.debug.print("dispatch_async_f reached main thread\n", .{});
}

pub fn main() !void {
    const NSApplication = c.class("NSApplication");
    const app = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(NSApplication, c.sel("sharedApplication"));
    _ = c.msgSend(*const fn (c.id, c.SEL, i64) callconv(.c) void)(app, c.sel("setActivationPolicy:"), 0);

    const NSWindow = c.class("NSWindow");
    const win = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(NSWindow, c.sel("alloc"));
    const Rect = extern struct { x: f64, y: f64, w: f64, h: f64 };
    const frame = Rect{ .x = 100, .y = 100, .w = 800, .h = 600 };
    const styleMask: u64 = 1 | 2 | 4 | 8;
    const initWin = c.msgSend(*const fn (c.id, c.SEL, Rect, u64, i64, bool) callconv(.c) c.id);
    const window = initWin(win, c.sel("initWithContentRect:styleMask:backing:defer:"), frame, styleMask, 2, false);

    const WKUCC = c.class("WKUserContentController");
    const ucc = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(WKUCC, c.sel("alloc"));
    _ = c.msgSend(*const fn (c.id, c.SEL) callconv(.c) c.id)(ucc, c.sel("init"));

    const NSObject = c.class("NSObject");
    const handlerCls = c.objc_allocateClassPair(NSObject, "ZWHandler", 0);
    _ = c.class_addMethod(handlerCls, c.sel("userContentController:didReceiveScriptMessage:"), @ptrCast(&onMessage), "v@:@@");
    c.objc_registerClassPair(handlerCls);
    const handler = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(handlerCls, c.sel("alloc"));
    _ = c.msgSend(*const fn (c.id, c.SEL) callconv(.c) c.id)(handler, c.sel("init"));
    c.msgSend(*const fn (c.id, c.SEL, c.id, c.id) callconv(.c) void)(ucc, c.sel("addScriptMessageHandler:name:"), handler, c.nsString("zig"));

    const WKCfg = c.class("WKWebViewConfiguration");
    const cfg = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(WKCfg, c.sel("alloc"));
    _ = c.msgSend(*const fn (c.id, c.SEL) callconv(.c) c.id)(cfg, c.sel("init"));
    c.msgSend(*const fn (c.id, c.SEL, c.id) callconv(.c) void)(cfg, c.sel("setUserContentController:"), ucc);

    const WKWebView = c.class("WKWebView");
    const wv = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(WKWebView, c.sel("alloc"));
    const initWV = c.msgSend(*const fn (c.id, c.SEL, Rect, c.id) callconv(.c) c.id);
    g_webview = initWV(wv, c.sel("initWithFrame:configuration:"), frame, cfg);
    c.msgSend(*const fn (c.id, c.SEL, c.id) callconv(.c) void)(window, c.sel("setContentView:"), g_webview);

    const html =
        "<html><body><h1>spike</h1><script>" ++
        "window.__spikeEcho=function(s){document.body.innerHTML+='<p>'+s+'</p>'};" ++
        "window.webkit.messageHandlers.zig.postMessage(JSON.stringify({hello:'from js'}));" ++
        "</script></body></html>";
    _ = c.msgSend(*const fn (c.id, c.SEL, c.id, c.id) callconv(.c) c.id)(g_webview, c.sel("loadHTMLString:baseURL:"), c.nsString(html), null);

    c.msgSend(*const fn (c.id, c.SEL, bool) callconv(.c) void)(window, c.sel("makeKeyAndOrderFront:"), true);
    c.msgSend(*const fn (c.id, c.SEL, bool) callconv(.c) void)(app, c.sel("activateIgnoringOtherApps:"), true);

    dispatch_async_f(&_dispatch_main_q, null, &mainThreadPing);
    c.msgSend(*const fn (c.id, c.SEL) callconv(.c) void)(app, c.sel("run"));
}
