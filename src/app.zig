const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const c = objc;
const Bridge = @import("bridge.zig").Bridge;
const scheme = @import("scheme.zig");
const PlatformSink = @import("platform_macos.zig").PlatformSink;

const app_js = @embedFile("frontend/app.js");

const Rect = extern struct { x: f64, y: f64, w: f64, h: f64 };

/// File-scope globals so the C-callconv IMPs (message handler, app delegate)
/// can reach the bridge/sink without per-call context plumbing.
var g: struct {
    alloc: std.mem.Allocator,
    bridge: ?*Bridge = null,
    psink: ?*PlatformSink = null,
} = .{ .alloc = undefined };

/// WKScriptMessageHandler callback: forward NSString message bodies (only) to
/// the bridge. Non-string bodies are dropped — the protocol is JSON text.
fn onMessage(self: c.id, _cmd: c.SEL, ucc: c.id, message: c.id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = ucc;
    const body = c.msgSend(*const fn (c.id, c.SEL) callconv(.c) c.id)(message, c.sel("body"));
    if (!c.isKindOf(body, c.class("NSString"))) return;
    const text = c.utf8(body) orelse return;
    const bridge = g.bridge orelse return;
    bridge.handleMessage(std.mem.span(text));
}

/// applicationWillTerminate: ordered shutdown — stop emitting, join workers,
/// flush pending main-thread hops, then free the sink.
fn onWillTerminate(self: c.id, _cmd: c.SEL, notification: c.id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = notification;
    if (g.psink) |ps| ps.alive.store(false, .release);
    if (g.bridge) |b| {
        b.deinit();
        g.bridge = null;
    }
    if (g.psink) |ps| {
        ps.drainOnMain();
        g.alloc.destroy(ps);
        g.psink = null;
    }
}

pub fn run(alloc: std.mem.Allocator, io: std.Io) !void {
    g = .{ .alloc = alloc };

    const NSApplication = c.class("NSApplication");
    const app = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(NSApplication, c.sel("sharedApplication"));
    _ = c.msgSend(*const fn (c.id, c.SEL, i64) callconv(.c) void)(app, c.sel("setActivationPolicy:"), 0);

    // ── App delegate for ordered shutdown ──────────────────────────────────
    const NSObject = c.class("NSObject");
    const delegateCls = c.objc_allocateClassPair(NSObject, "ZWAppDelegate", 0);
    _ = c.class_addMethod(delegateCls, c.sel("applicationWillTerminate:"), @ptrCast(&onWillTerminate), "v@:@");
    c.objc_registerClassPair(delegateCls);
    const delegateAlloc = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(delegateCls, c.sel("alloc"));
    const delegate = c.msgSend(*const fn (c.id, c.SEL) callconv(.c) c.id)(delegateAlloc, c.sel("init"));
    _ = c.msgSend(*const fn (c.id, c.SEL, c.id) callconv(.c) void)(app, c.sel("setDelegate:"), delegate);

    // ── Window ──────────────────────────────────────────────────────────────
    const NSWindow = c.class("NSWindow");
    const win = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(NSWindow, c.sel("alloc"));
    const frame = Rect{ .x = 100, .y = 100, .w = 800, .h = 600 };
    const styleMask: u64 = 1 | 2 | 4 | 8;
    const initWin = c.msgSend(*const fn (c.id, c.SEL, Rect, u64, i64, bool) callconv(.c) c.id);
    const window = initWin(win, c.sel("initWithContentRect:styleMask:backing:defer:"), frame, styleMask, 2, false);

    // ── WKUserContentController: message handler + injected shim ────────────
    const WKUCC = c.class("WKUserContentController");
    const uccAlloc = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(WKUCC, c.sel("alloc"));
    const ucc = c.msgSend(*const fn (c.id, c.SEL) callconv(.c) c.id)(uccAlloc, c.sel("init"));

    const handlerCls = c.objc_allocateClassPair(NSObject, "ZWHandler", 0);
    _ = c.class_addMethod(handlerCls, c.sel("userContentController:didReceiveScriptMessage:"), @ptrCast(&onMessage), "v@:@@");
    c.objc_registerClassPair(handlerCls);
    const handlerAlloc = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(handlerCls, c.sel("alloc"));
    const handler = c.msgSend(*const fn (c.id, c.SEL) callconv(.c) c.id)(handlerAlloc, c.sel("init"));
    _ = c.msgSend(*const fn (c.id, c.SEL, c.id, c.id) callconv(.c) void)(ucc, c.sel("addScriptMessageHandler:name:"), handler, c.nsString("zig"));

    // Inject app.js at document start so the JS-side bridge shim exists before
    // page scripts run. injectionTime 0 = atDocumentStart; mainFrameOnly = true.
    const WKUserScript = c.class("WKUserScript");
    const scriptAlloc = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(WKUserScript, c.sel("alloc"));
    const userScript = c.msgSend(*const fn (c.id, c.SEL, c.id, i64, bool) callconv(.c) c.id)(scriptAlloc, c.sel("initWithSource:injectionTime:forMainFrameOnly:"), c.nsString(app_js.ptr), 0, true);
    _ = c.msgSend(*const fn (c.id, c.SEL, c.id) callconv(.c) void)(ucc, c.sel("addUserScript:"), userScript);

    // ── WKWebViewConfiguration: ucc + app:// scheme handler ─────────────────
    const WKCfg = c.class("WKWebViewConfiguration");
    const cfgAlloc = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(WKCfg, c.sel("alloc"));
    const cfg = c.msgSend(*const fn (c.id, c.SEL) callconv(.c) c.id)(cfgAlloc, c.sel("init"));
    _ = c.msgSend(*const fn (c.id, c.SEL, c.id) callconv(.c) void)(cfg, c.sel("setUserContentController:"), ucc);

    const schemeHandler = scheme.makeHandler();
    _ = c.msgSend(*const fn (c.id, c.SEL, c.id, c.id) callconv(.c) void)(cfg, c.sel("setURLSchemeHandler:forURLScheme:"), schemeHandler, c.nsString("app"));

    // ── WKWebView ───────────────────────────────────────────────────────────
    const WKWebView = c.class("WKWebView");
    const wvAlloc = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(WKWebView, c.sel("alloc"));
    const initWV = c.msgSend(*const fn (c.id, c.SEL, Rect, c.id) callconv(.c) c.id);
    const webview = initWV(wvAlloc, c.sel("initWithFrame:configuration:"), frame, cfg);
    _ = c.msgSend(*const fn (c.id, c.SEL, c.id) callconv(.c) void)(window, c.sel("setContentView:"), webview);

    // Dev affordance gated to debug builds only; never leak Web Inspector into release.
    if (builtin.mode == .Debug) {
        _ = c.msgSend(*const fn (c.id, c.SEL, bool) callconv(.c) void)(webview, c.sel("setInspectable:"), true);
    }

    // ── Sink + Bridge ─────────────────────────────────────────────────────────
    const psink = try alloc.create(PlatformSink);
    errdefer alloc.destroy(psink);
    psink.* = .{ .alloc = alloc, .webview = webview };
    g.psink = psink;

    const bridge = try Bridge.init(alloc, io, psink.sink());
    g.bridge = bridge;

    // ── Load app://localhost/index.html ─────────────────────────────────────
    const NSURL = c.class("NSURL");
    const url = c.msgSend(*const fn (c.Class, c.SEL, c.id) callconv(.c) c.id)(NSURL, c.sel("URLWithString:"), c.nsString("app://localhost/index.html"));
    const NSURLRequest = c.class("NSURLRequest");
    const reqAlloc = c.msgSend(*const fn (c.Class, c.SEL) callconv(.c) c.id)(NSURLRequest, c.sel("alloc"));
    const request = c.msgSend(*const fn (c.id, c.SEL, c.id) callconv(.c) c.id)(reqAlloc, c.sel("initWithURL:"), url);
    _ = c.msgSend(*const fn (c.id, c.SEL, c.id) callconv(.c) c.id)(webview, c.sel("loadRequest:"), request);

    // ── Show + run ──────────────────────────────────────────────────────────
    _ = c.msgSend(*const fn (c.id, c.SEL, bool) callconv(.c) void)(window, c.sel("makeKeyAndOrderFront:"), true);
    _ = c.msgSend(*const fn (c.id, c.SEL, bool) callconv(.c) void)(app, c.sel("activateIgnoringOtherApps:"), true);

    c.msgSend(*const fn (c.id, c.SEL) callconv(.c) void)(app, c.sel("run"));
}
