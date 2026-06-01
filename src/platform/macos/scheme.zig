const std = @import("std");
const objc = @import("objc");
const assoc = @import("assoc.zig");
const logic = @import("scheme_logic.zig");
const seam = @import("../backend.zig");
const mac = @import("backend.zig");

/// Association key: the address of this static is unique per process.
var scheme_backend_key: u8 = 0;
pub fn backendKey() *const anyopaque {
    return &scheme_backend_key;
}

fn failTask(task: objc.id, code: i64) void {
    const NSError = objc.class("NSError");
    const err = objc.msgSend(*const fn (objc.Class, objc.SEL, objc.id, i64, objc.id) callconv(.c) objc.id)(NSError, objc.sel("errorWithDomain:code:userInfo:"), objc.nsString("ZWSchemeErrorDomain"), code, null);
    _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) void)(task, objc.sel("didFailWithError:"), err);
}

pub export fn zw_scheme_start(self: objc.id, _cmd: objc.SEL, webview: objc.id, task: objc.id) callconv(.c) void {
    _ = _cmd;
    _ = webview;
    // Autorelease pool around the whole IMP (M2).
    const NSAutoreleasePool = objc.class("NSAutoreleasePool");
    const poolAlloc = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(NSAutoreleasePool, objc.sel("alloc"));
    const pool = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(poolAlloc, objc.sel("init"));
    defer _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(pool, objc.sel("drain"));

    // Read the backend off the handler instance (H3/I4); no file-scope state.
    const backend_obj = assoc.objc_getAssociatedObject(self, backendKey());
    if (@intFromPtr(backend_obj) == 0) return failTask(task, 404);
    const backend: *mac.MacOSBackend = @ptrCast(@alignCast(backend_obj));
    if (!backend.alive.load(.acquire)) return failTask(task, 404);

    const request = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(task, objc.sel("request"));
    const url = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(request, objc.sel("URL"));
    const pathObj = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(url, objc.sel("path"));
    const pathC = objc.utf8(pathObj) orelse return failTask(task, 404);

    // NUL-bounded first (H2): never form a fixed 4096-wide slice from a
    // many-pointer, which would read past the WebKit-owned buffer when the
    // path is shorter than MAX_PATH. std.mem.sliceTo stops at the terminator.
    const path_slice = std.mem.sliceTo(pathC, 0);
    const path = switch (logic.extractPath(path_slice)) {
        .ok => |p| p,
        .empty => return failTask(task, 400),
        .too_long => return failTask(task, 414),
    };

    const resp = backend.dispatchSchemeRequest(.{ .source = .asset_scheme, .path = path });
    if (resp.status != 200) return failTask(task, @intCast(resp.status));

    const NSData = objc.class("NSData");
    const data = objc.msgSend(*const fn (objc.Class, objc.SEL, [*]const u8, usize) callconv(.c) objc.id)(NSData, objc.sel("dataWithBytes:length:"), resp.body.ptr, resp.body.len);

    const NSURLResponse = objc.class("NSURLResponse");
    const respAlloc = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(NSURLResponse, objc.sel("alloc"));
    const nsResp = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id, objc.id, i64, objc.id) callconv(.c) objc.id)(respAlloc, objc.sel("initWithURL:MIMEType:expectedContentLength:textEncodingName:"), url, objc.nsString(resp.mime), @as(i64, @intCast(resp.body.len)), objc.nsString("utf-8"));
    defer _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(nsResp, objc.sel("release"));

    _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) void)(task, objc.sel("didReceiveResponse:"), nsResp);
    _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) void)(task, objc.sel("didReceiveData:"), data);
    _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(task, objc.sel("didFinish"));
}

pub export fn zw_scheme_stop(self: objc.id, _cmd: objc.SEL, webview: objc.id, task: objc.id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = webview;
    _ = task;
}

/// Allocate an instance of the pre-registered ZWScheme class and stash the
/// backend pointer on it. The class itself is registered once in
/// MacOSBackend.init (H7); this only makes an instance.
pub fn makeSchemeHandler(cls: objc.Class, backend: *mac.MacOSBackend) objc.id {
    const inst = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(cls, objc.sel("alloc"));
    const handler = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(inst, objc.sel("init"));
    // ASSIGN, not RETAIN: the value is a Zig *MacOSBackend cast to objc.id, not
    // a real objc object. A RETAIN policy would call objc_retain on a non-objc
    // pointer and crash. The backend nulls this association in its deinit (H5).
    assoc.objc_setAssociatedObject(handler, backendKey(), @ptrCast(backend), assoc.ASSOCIATION_ASSIGN);
    return handler;
}
