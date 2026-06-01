const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const protocol = @import("../../protocol.zig"); // for MAX_MESSAGE_LEN at the inbound seam
const assoc = @import("assoc.zig");
const seam = @import("../backend.zig");
const window_mod = @import("window.zig");
const webview_mod = @import("webview.zig");
const scheme_mod = @import("scheme.zig");
const delegate_mod = @import("delegate.zig");
const dispatch = @import("dispatch.zig");
const origin = @import("origin.zig");

var handler_backend_key: u8 = 0;

fn notFound() seam.Response {
    return .{ .status = 404, .mime = "text/plain", .body = "" };
}

/// WKScriptMessageHandler IMP: read backend off the handler instance (H3/I4),
/// gate on alive AND isKindOf(body, NSString), then call onMessage.
fn onMessageImp(self_obj: objc.id, _cmd: objc.SEL, ucc: objc.id, message: objc.id) callconv(.c) void {
    _ = _cmd;
    _ = ucc;
    // Autorelease pool around the IMP (M2).
    const NSAutoreleasePool = objc.class("NSAutoreleasePool");
    const poolAlloc = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(NSAutoreleasePool, objc.sel("alloc"));
    const pool = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(poolAlloc, objc.sel("init"));
    defer _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(pool, objc.sel("drain"));

    const backend_obj = assoc.objc_getAssociatedObject(self_obj, &handler_backend_key);
    if (@intFromPtr(backend_obj) == 0) return;
    const self: *MacOSBackend = @ptrCast(@alignCast(backend_obj));
    if (!self.alive.load(.acquire)) return;
    const cb = self.cb orelse return;

    const body = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(message, objc.sel("body"));
    if (!objc.isKindOf(body, objc.class("NSString"))) return;

    // Layer-1 message-size cap (H1/H3): the cap is in UTF-8 BYTES, not UTF-16
    // code units. NSString.length is UTF-16 units, which undercounts non-BMP
    // text, so we measure the actual UTF-8 byte length and reject before span.
    // NSUTF8StringEncoding == 4.
    const utf8_bytes: usize = @intCast(objc.msgSend(*const fn (objc.id, objc.SEL, u64) callconv(.c) u64)(body, objc.sel("lengthOfBytesUsingEncoding:"), 4));
    if (utf8_bytes == 0 or utf8_bytes > protocol.MAX_MESSAGE_LEN) return; // empty or oversized: drop at the seam
    const text_c = objc.utf8(body) orelse return;
    // Bound the span by the terminator so a span never runs away even if the
    // buffer is not where we expect; sliceTo stops at the NUL.
    const text = std.mem.sliceTo(text_c, 0);
    if (text.len > protocol.MAX_MESSAGE_LEN) return;

    const frameInfo = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(message, objc.sel("frameInfo"));
    const secOrigin = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(frameInfo, objc.sel("securityOrigin"));
    var origin_buf: [256]u8 = undefined;
    const origin_str = origin.readSecurityOrigin(&origin_buf, secOrigin);

    cb.onMessage(cb.ctx, self.current_window_id, origin_str, text);
}

pub const MacOSBackend = struct {
    pub const WindowHandle = struct { window: objc.id, webview: objc.id };
    pub const WindowId = u64;

    alloc: std.mem.Allocator,
    app: objc.id = null,
    cb: ?seam.Callbacks = null,
    alive: std.atomic.Value(bool) = .init(true),
    next_window_id: u64 = 0, // monotonic counter (H8)
    current_window_id: u64 = std.math.maxInt(u64),

    // Cached classes, each registered ONCE here (H7).
    handler_cls: objc.Class = null,
    scheme_cls: objc.Class = null,
    delegate_cls: objc.Class = null,

    // The IMP instances that carry the backend pointer via objc_setAssociatedObject.
    // Stored so deinit can null those associations before freeing the backend, so
    // a late IMP reads nil and bails at the @intFromPtr==0 gate instead of
    // dereferencing freed memory (H5). v0.1.0 has one of each (single window).
    handler_inst: objc.id = null,
    scheme_inst: objc.id = null,
    delegate_inst: objc.id = null,

    /// pure-objc backend: no `io` parameter (M17 io policy). Bridge owns its io.
    pub fn init(alloc: std.mem.Allocator) !*MacOSBackend {
        const self = try alloc.create(MacOSBackend);
        self.* = .{ .alloc = alloc };

        // Register each ZW* class once (H7): getClass-or-allocateClassPair.
        const NSObject = objc.class("NSObject");

        self.handler_cls = getOrAllocClass(NSObject, "ZWHandler");
        _ = objc.class_addMethod(self.handler_cls, objc.sel("userContentController:didReceiveScriptMessage:"), @ptrCast(&onMessageImp), "v@:@@");
        objc.objc_registerClassPair(self.handler_cls);

        self.scheme_cls = getOrAllocClass(NSObject, "ZWScheme");
        _ = objc.class_addMethod(self.scheme_cls, objc.sel("webView:startURLSchemeTask:"), @ptrCast(&scheme_mod.zw_scheme_start), "v@:@@");
        _ = objc.class_addMethod(self.scheme_cls, objc.sel("webView:stopURLSchemeTask:"), @ptrCast(&scheme_mod.zw_scheme_stop), "v@:@@");
        objc.objc_registerClassPair(self.scheme_cls);

        self.delegate_cls = getOrAllocClass(NSObject, "ZWAppDelegate");
        delegate_mod.addMethods(self.delegate_cls);
        objc.objc_registerClassPair(self.delegate_cls);

        const NSApplication = objc.class("NSApplication");
        const app = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(NSApplication, objc.sel("sharedApplication"));
        _ = objc.msgSend(*const fn (objc.id, objc.SEL, i64) callconv(.c) void)(app, objc.sel("setActivationPolicy:"), 0);
        const delegate = delegate_mod.makeDelegate(self.delegate_cls, self);
        self.delegate_inst = delegate;
        _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) void)(app, objc.sel("setDelegate:"), delegate);
        self.app = app;
        return self;
    }

    /// objc_getClass-or-allocateClassPair so a re-init (or class already
    /// registered from a prior run in the same process) does not return nil (H7).
    fn getOrAllocClass(superclass: objc.Class, name: [*:0]const u8) objc.Class {
        const existing = objc.objc_getClass(name);
        if (@intFromPtr(existing) != 0) return existing;
        return objc.objc_allocateClassPair(superclass, name, 0);
    }

    /// INFALLIBLE drain-then-free (B2). alive=false, flush the main GCD queue so
    /// every pending hop runs (and early-returns on !alive) before we free, THEN
    /// destroy. App.shutdown already ordered terminate -> bridge.deinit (joins) ->
    /// pumpMain; this deinit re-drains defensively so a direct backend.deinit is
    /// still safe.
    pub fn deinit(self: *MacOSBackend) void {
        self.alive.store(false, .release);
        dispatch.drain(); // run/flush any in-flight hops; they see !alive and no-op
        // Null the backend pointer on every IMP instance so a late callback
        // (the objc instances are retained by the webview/config/NSApp and
        // outlive us) reads nil and bails at the @intFromPtr==0 gate rather
        // than dereferencing this freed backend (H5). Each IMP file owns its
        // own association key, so clear each with its matching key.
        if (@intFromPtr(self.handler_inst) != 0)
            assoc.objc_setAssociatedObject(self.handler_inst, &handler_backend_key, null, assoc.ASSOCIATION_ASSIGN);
        if (@intFromPtr(self.scheme_inst) != 0)
            assoc.objc_setAssociatedObject(self.scheme_inst, scheme_mod.backendKey(), null, assoc.ASSOCIATION_ASSIGN);
        if (@intFromPtr(self.delegate_inst) != 0)
            assoc.objc_setAssociatedObject(self.delegate_inst, delegate_mod.backendKey(), null, assoc.ASSOCIATION_ASSIGN);
        self.alloc.destroy(self);
    }

    /// Bridge from the scheme IMP into onSchemeRequest. The scheme IMP already
    /// gated alive; this just forwards through the registered callback.
    pub fn dispatchSchemeRequest(self: *MacOSBackend, req: seam.Request) seam.Response {
        const cb = self.cb orelse return notFound();
        return cb.onSchemeRequest(cb.ctx, req);
    }

    pub fn createWindow(self: *MacOSBackend, opts: seam.WindowOpts) seam.CreateWindowError!WindowHandle {
        // Validate scripts BEFORE allocating any objc objects (load-bearing
        // ordering: a malformed script must fail with no leaked window/UCC) (M10).
        for (opts.user_scripts) |s| {
            if (std.mem.indexOfScalar(u8, s, 0) != null) return error.ScriptContainsNul;
        }

        const window = window_mod.create(opts);
        errdefer _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(window, objc.sel("release"));

        // WKUserContentController with the message handler and the user scripts.
        // CRITICAL ORDERING: addUserScript: MUST happen BEFORE loadRequest:, or
        // WKWebView does not inject into the first page load.
        const WKUCC = objc.class("WKUserContentController");
        const uccAlloc = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(WKUCC, objc.sel("alloc"));
        const ucc = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(uccAlloc, objc.sel("init"));
        errdefer _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(ucc, objc.sel("release"));

        // Instance of the pre-registered handler class (H7); stash backend on it.
        const handlerAlloc = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(self.handler_cls, objc.sel("alloc"));
        const handler = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(handlerAlloc, objc.sel("init"));
        errdefer _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(handler, objc.sel("release"));
        assoc.objc_setAssociatedObject(handler, &handler_backend_key, @ptrCast(self), assoc.ASSOCIATION_ASSIGN);
        self.handler_inst = handler; // stored so deinit can null the association (H5)
        _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) void)(ucc, objc.sel("addScriptMessageHandler:name:"), handler, objc.nsString("zig"));

        // Inject boot scripts (pre-validated NUL-free). injectUserScript only
        // returns ScriptContainsNul, which we already excluded; treat as
        // infallible here but keep try for shape parity with the contract.
        for (opts.user_scripts) |script| {
            webview_mod.injectUserScript(ucc, script) catch return error.ScriptContainsNul;
        }

        const WKCfg = objc.class("WKWebViewConfiguration");
        const cfgAlloc = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(WKCfg, objc.sel("alloc"));
        const cfg = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(cfgAlloc, objc.sel("init"));
        errdefer _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(cfg, objc.sel("release"));
        _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) void)(cfg, objc.sel("setUserContentController:"), ucc);
        const schemeHandler = scheme_mod.makeHandler(self.scheme_cls, self);
        self.scheme_inst = schemeHandler; // stored so deinit can null the association (H5)
        _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) void)(cfg, objc.sel("setURLSchemeHandler:forURLScheme:"), schemeHandler, objc.nsString("app"));

        const WKWebView = objc.class("WKWebView");
        const wvAlloc = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(WKWebView, objc.sel("alloc"));
        const frame = window_mod.Rect{ .x = 0, .y = 0, .w = opts.width, .h = opts.height };
        const initWV = objc.msgSend(*const fn (objc.id, objc.SEL, window_mod.Rect, objc.id) callconv(.c) objc.id);
        const webview = initWV(wvAlloc, objc.sel("initWithFrame:configuration:"), frame, cfg);
        errdefer _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(webview, objc.sel("release"));
        _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) void)(window, objc.sel("setContentView:"), webview);

        if (builtin.mode == .Debug) {
            _ = objc.msgSend(*const fn (objc.id, objc.SEL, bool) callconv(.c) void)(webview, objc.sel("setInspectable:"), true);
        }

        const NSURL = objc.class("NSURL");
        const url = objc.msgSend(*const fn (objc.Class, objc.SEL, objc.id) callconv(.c) objc.id)(NSURL, objc.sel("URLWithString:"), objc.nsString(opts.url.ptr));
        const NSURLRequest = objc.class("NSURLRequest");
        const reqAlloc = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(NSURLRequest, objc.sel("alloc"));
        const request = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.id)(reqAlloc, objc.sel("initWithURL:"), url);
        defer _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(request, objc.sel("release"));
        _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.id)(webview, objc.sel("loadRequest:"), request);

        if (opts.show) window_mod.show(window);

        // All objc allocations succeeded: assign the monotonic id (H8) and
        // commit. From here no error path remains, so the errdefers do not fire.
        const id = self.next_window_id;
        self.next_window_id += 1;
        self.current_window_id = id;

        return .{ .window = window, .webview = webview };
    }

    pub fn destroyWindow(_: *MacOSBackend, h: WindowHandle) void {
        _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(h.window, objc.sel("close"));
    }

    pub fn setTitle(_: *MacOSBackend, h: WindowHandle, title: [:0]const u8) seam.SetTitleError!void {
        window_mod.setTitle(h.window, title);
    }

    pub fn setSize(_: *MacOSBackend, h: WindowHandle, w: f64, ht: f64) void {
        window_mod.setSize(h.window, w, ht);
    }

    pub fn setFullscreen(_: *MacOSBackend, h: WindowHandle, on: bool) void {
        window_mod.setFullscreen(h.window, on);
    }

    pub fn showWindow(_: *MacOSBackend, h: WindowHandle) void {
        window_mod.show(h.window);
    }

    pub fn focusWindow(_: *MacOSBackend, h: WindowHandle) void {
        window_mod.focus(h.window);
    }

    pub fn evalJS(self: *MacOSBackend, h: WindowHandle, js: []const u8) void {
        if (!self.alive.load(.acquire)) return;
        std.debug.assert(std.mem.indexOfScalar(u8, js, 0) == null); // M8 debug guard
        webview_mod.eval(self.alloc, &self.alive, h.webview, js);
    }

    pub fn injectUserScript(_: *MacOSBackend, h: WindowHandle, js: []const u8) seam.InjectScriptError!void {
        const cfg = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(h.webview, objc.sel("configuration"));
        const ucc = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(cfg, objc.sel("userContentController"));
        try webview_mod.injectUserScript(ucc, js);
    }

    /// Returns the monotonic id assigned at createWindow (H8). Never the raw
    /// pointer; never panics. An unknown/stale handle returns the sentinel.
    pub fn windowId(self: *MacOSBackend, h: WindowHandle) WindowId {
        // v0.1.0: one window. A handle whose webview/window does not match the
        // current window yields the sentinel rather than a panic.
        if (@intFromPtr(h.window) == 0) return std.math.maxInt(u64);
        return self.current_window_id;
    }

    pub fn dispatchMain(_: *MacOSBackend, work: *const fn (?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void {
        dispatch.async_(work, ctx);
    }

    pub fn pumpMain(_: *MacOSBackend) void {
        dispatch.drain();
    }

    pub fn run(self: *MacOSBackend) void {
        objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(self.app, objc.sel("run"));
    }

    pub fn terminate(self: *MacOSBackend) void {
        self.alive.store(false, .release);
    }

    pub fn nativeWindow(_: *MacOSBackend, h: WindowHandle) ?*anyopaque {
        return h.window;
    }

    pub fn setCallbacks(self: *MacOSBackend, cb: seam.Callbacks) void {
        self.cb = cb;
    }

    /// No-op: AppKit joins its work via the runloop and deinit drains the main
    /// GCD queue directly, so there is no joined assert to satisfy. Present to
    /// satisfy the contract so App.shutdown can call it generically over B.
    pub fn markJoined(_: *MacOSBackend) void {}
};

comptime {
    seam.assertBackend(MacOSBackend);
}
