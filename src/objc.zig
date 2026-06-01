const std = @import("std");

pub const id = ?*anyopaque;
pub const SEL = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const IMP = *const fn () callconv(.c) void;

pub extern fn objc_getClass(name: [*:0]const u8) Class;
pub extern fn sel_registerName(name: [*:0]const u8) SEL;
pub extern fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra: usize) Class;
pub extern fn objc_registerClassPair(cls: Class) void;
pub extern fn class_addMethod(cls: Class, name: SEL, imp: IMP, types: [*:0]const u8) bool;
pub extern fn object_getClass(obj: id) Class;

extern fn objc_msgSend() callconv(.c) void;

pub fn msgSend(comptime Fn: type) Fn {
    return @ptrCast(&objc_msgSend);
}

pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}
pub fn class(name: [*:0]const u8) Class {
    return objc_getClass(name);
}

pub fn nsString(cstr: [*:0]const u8) id {
    const NSString = class("NSString");
    const f = msgSend(*const fn (Class, SEL, [*:0]const u8) callconv(.c) id);
    return f(NSString, sel("stringWithUTF8String:"), cstr);
}

pub fn utf8(nsstr: id) ?[*:0]const u8 {
    if (nsstr == null) return null;
    const f = msgSend(*const fn (id, SEL) callconv(.c) [*:0]const u8);
    return f(nsstr, sel("UTF8String"));
}

pub fn isKindOf(obj: id, cls: Class) bool {
    if (obj == null or cls == null) return false;
    const f = msgSend(*const fn (id, SEL, Class) callconv(.c) bool);
    return f(obj, sel("isKindOfClass:"), cls);
}
