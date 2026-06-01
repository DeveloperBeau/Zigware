const objc = @import("objc");
const assoc = @import("assoc.zig");
const seam = @import("../backend.zig");
const mac = @import("backend.zig");

var delegate_backend_key: u8 = 0;
pub fn backendKey() *const anyopaque {
    return &delegate_backend_key;
}

fn dispatch(self: objc.id, event: seam.LifecycleEvent) void {
    const backend_obj = assoc.objc_getAssociatedObject(self, backendKey());
    if (@intFromPtr(backend_obj) == 0) return;
    const backend: *mac.MacOSBackend = @ptrCast(@alignCast(backend_obj));
    if (!backend.alive.load(.acquire)) return;
    const cb = backend.cb orelse return;
    cb.onLifecycle(cb.ctx, event);
}

fn onWillTerminate(self: objc.id, _cmd: objc.SEL, notification: objc.id) callconv(.c) void {
    _ = _cmd;
    _ = notification;
    dispatch(self, .will_terminate);
}

fn onAllClosed(self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) bool {
    _ = _cmd;
    _ = sender;
    dispatch(self, .window_all_closed);
    return true; // applicationShouldTerminateAfterLastWindowClosed: -> YES
}

/// Make a ZWAppDelegate instance from the pre-registered class (H7) and stash
/// the backend on it. Maps applicationWillTerminate: and
/// applicationShouldTerminateAfterLastWindowClosed: into onLifecycle.
pub fn makeDelegate(cls: objc.Class, backend: *mac.MacOSBackend) objc.id {
    const a = objc.msgSend(*const fn (objc.Class, objc.SEL) callconv(.c) objc.id)(cls, objc.sel("alloc"));
    const delegate = objc.msgSend(*const fn (objc.id, objc.SEL) callconv(.c) objc.id)(a, objc.sel("init"));
    assoc.objc_setAssociatedObject(delegate, backendKey(), @ptrCast(backend), assoc.ASSOCIATION_ASSIGN);
    return delegate;
}

/// Register the two lifecycle methods on `cls` (called once from init).
pub fn addMethods(cls: objc.Class) void {
    _ = objc.class_addMethod(cls, objc.sel("applicationWillTerminate:"), @ptrCast(&onWillTerminate), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("applicationShouldTerminateAfterLastWindowClosed:"), @ptrCast(&onAllClosed), "c@:@");
}
