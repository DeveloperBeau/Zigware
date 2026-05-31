const std = @import("std");
const objc = @import("objc.zig");

const index_html = @embedFile("frontend/index.html");
const app_js = @embedFile("frontend/app.js");

const Entry = struct { path: []const u8, body: []const u8, mime: [*:0]const u8 };
const table = [_]Entry{
    .{ .path = "/", .body = index_html, .mime = "text/html" },
    .{ .path = "/index.html", .body = index_html, .mime = "text/html" },
    .{ .path = "/app.js", .body = app_js, .mime = "text/javascript" },
};

fn lookup(path: []const u8) ?Entry {
    for (table) |e| if (std.mem.eql(u8, e.path, path)) return e;
    return null;
}

fn failTask(task: objc.id, code: i64) void {
    const NSError = objc.class("NSError");
    const err = objc.msgSend(*const fn (objc.Class, objc.SEL, objc.id, i64, objc.id) callconv(.c) objc.id)(NSError, objc.sel("errorWithDomain:code:userInfo:"), objc.nsString("ZWSchemeErrorDomain"), code, null);
    _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) void)(task, objc.sel("didFailWithError:"), err);
}

export fn zw_scheme_start(self: objc.id, _cmd: objc.SEL, webview: objc.id, task: objc.id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = webview;
    const request = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(task, objc.sel("request"));
    const url = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(request, objc.sel("URL"));
    const pathObj = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(url, objc.sel("path"));
    const pathC = objc.utf8(pathObj) orelse return failTask(task, 404);
    const path = std.mem.span(pathC);
    const entry = lookup(path) orelse return failTask(task, 404);

    const NSData = objc.class("NSData");
    const data = objc.msgSend(*const fn (objc.Class, objc.SEL, [*]const u8, usize) callconv(.c) objc.id)(NSData, objc.sel("dataWithBytes:length:"), entry.body.ptr, entry.body.len);

    const NSURLResponse = objc.class("NSURLResponse");
    const respAlloc = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(NSURLResponse, objc.sel("alloc"));
    const resp = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id, objc.id, i64, objc.id) callconv(.c) objc.id)(respAlloc, objc.sel("initWithURL:MIMEType:expectedContentLength:textEncodingName:"), url, objc.nsString(entry.mime), @as(i64, @intCast(entry.body.len)), objc.nsString("utf-8"));

    _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) void)(task, objc.sel("didReceiveResponse:"), resp);
    _ = objc.msgSend(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) void)(task, objc.sel("didReceiveData:"), data);
    _ = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) void)(task, objc.sel("didFinish"));
}

export fn zw_scheme_stop(self: objc.id, _cmd: objc.SEL, webview: objc.id, task: objc.id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = webview;
    _ = task;
}

/// Build a WKURLSchemeHandler instance serving the embedded frontend.
pub fn makeHandler() objc.id {
    const NSObject = objc.class("NSObject");
    const cls = objc.objc_allocateClassPair(NSObject, "ZWScheme", 0);
    _ = objc.class_addMethod(cls, objc.sel("webView:startURLSchemeTask:"), @ptrCast(&zw_scheme_start), "v@:@@");
    _ = objc.class_addMethod(cls, objc.sel("webView:stopURLSchemeTask:"), @ptrCast(&zw_scheme_stop), "v@:@@");
    objc.objc_registerClassPair(cls);
    const inst = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(cls, objc.sel("alloc"));
    return objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(inst, objc.sel("init"));
}
