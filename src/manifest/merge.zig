//! Platform-override merge over the optional mirror.
//!
//! Two-phase shape (locked in the design review):
//!   1. `pickX` helpers BORROW from base or override. Each returns a substruct
//!      whose slice fields point into either base.X.* or override.X.*. Zero
//!      allocation, cannot fail. A `null` leaf in the override leaves the base
//!      field; a non-null leaf swaps in the override field. Arrays replace
//!      wholesale.
//!   2. `dupAll` is the single allocation site. It deep-copies every slice in
//!      the picked Manifest into `gpa`, using one helper per nested type so
//!      each helper owns its own watermark + errdefer. A mid-dup OOM frees
//!      ONLY the fields that helper successfully duped, then re-raises so the
//!      caller's errdefer unwinds its own prior dups. Borrowed-unchanged
//!      slices (those still pointing at a comptime static default) are never
//!      freed by an errdefer. The static-skip rule is consulted before every
//!      `gpa.dupe` AND inside every cleanup path, exactly as `freeManifest`
//!      does.
//!
//! Ownership: every returned Manifest is FULLY gpa-owned (deep-duped).
//! Callers free the merged result with `parse.freeManifest`. `std.zon.parse.free`
//! is NOT safe on Manifest: it double-frees the static-literal defaults like
//! Csp.scriptSrc = &.{"'self'"}; verified empirically in Task 1's spike.
//! Base and override may be freed via parse.freeManifest immediately after
//! merge returns (deep-dup makes both disposable).

const std = @import("std");
const types = @import("types.zig");

const Manifest = types.Manifest;
const OverrideManifest = types.OverrideManifest;

// ─── public entry point ──────────────────────────────────────────────────────

pub fn merge(
    gpa: std.mem.Allocator,
    base: Manifest,
    override: ?OverrideManifest,
) std.mem.Allocator.Error!Manifest {
    var picked = base;
    if (override) |o| {
        if (o.identifier) |v| picked.identifier = v;
        if (o.productName) |v| picked.productName = v;
        if (o.version) |v| picked.version = v;
        if (o.app) |oa| picked.app = pickApp(base.app, oa);
        if (o.security) |os| picked.security = pickSecurity(base.security, os);
        if (o.frontend) |of| picked.frontend = pickFrontend(base.frontend, of);
        if (o.bundle) |obu| picked.bundle = pickBundle(base.bundle, obu);
    }
    return try dupAll(gpa, picked);
}

// ─── pickX: borrow-only assemblers (no allocation, cannot fail) ──────────────

fn pickApp(base: types.App, ov: types.OverrideApp) types.App {
    var out = base;
    if (ov.windowDefaults) |w| out.windowDefaults = pickWindowDefaults(base.windowDefaults, w);
    if (ov.windows) |w| out.windows = w;
    if (ov.quitOnLastWindowClosed) |q| out.quitOnLastWindowClosed = q;
    if (ov.windowShowFallbackMs) |m| out.windowShowFallbackMs = m;
    return out;
}

fn pickWindowDefaults(base: types.WindowDefaults, ov: types.OverrideWindowDefaults) types.WindowDefaults {
    var out = base;
    if (ov.width) |v| out.width = v;
    if (ov.height) |v| out.height = v;
    if (ov.show) |v| out.show = v;
    if (ov.titleBarStyle) |v| out.titleBarStyle = v;
    if (ov.decorations) |v| out.decorations = v;
    return out;
}

fn pickSecurity(base: types.Security, ov: types.OverrideSecurity) types.Security {
    var out = base;
    if (ov.grants) |v| out.grants = v;
    if (ov.csp) |c| out.csp = pickCsp(base.csp, c);
    if (ov.fuses) |f| out.fuses = pickFuses(base.fuses, f);
    return out;
}

fn pickCsp(base: types.Csp, ov: types.OverrideCsp) types.Csp {
    var out = base;
    if (ov.defaultSrc) |v| out.defaultSrc = v;
    if (ov.scriptSrc) |v| out.scriptSrc = v;
    if (ov.styleSrc) |v| out.styleSrc = v;
    if (ov.connectSrc) |v| out.connectSrc = v;
    if (ov.imgSrc) |v| out.imgSrc = v;
    return out;
}

fn pickFuses(base: types.Fuses, ov: types.OverrideFuses) types.Fuses {
    var out = base;
    if (ov.allowRemoteContent) |v| out.allowRemoteContent = v;
    if (ov.allowEval) |v| out.allowEval = v;
    if (ov.allowShell) |v| out.allowShell = v;
    if (ov.debugInspector) |v| out.debugInspector = v;
    return out;
}

fn pickFrontend(base: types.Frontend, ov: types.OverrideFrontend) types.Frontend {
    var out = base;
    if (ov.dev) |v| out.dev = v;
    if (ov.build) |v| out.build = v;
    if (ov.serveUrl) |v| out.serveUrl = v;
    if (ov.outDir) |v| out.outDir = v;
    return out;
}

fn pickBundle(base: types.Bundle, ov: types.OverrideBundle) types.Bundle {
    var out = base;
    if (ov.targets) |v| out.targets = v;
    if (ov.icon) |v| out.icon = v;
    if (ov.category) |v| out.category = v;
    if (ov.copyright) |v| out.copyright = v;
    if (ov.bundleVersion) |v| out.bundleVersion = v;
    if (ov.displayName) |v| out.displayName = v;
    if (ov.macos) |m| out.macos = pickMacOsBundle(base.macos, m);
    return out;
}

fn pickMacOsBundle(base: types.MacOsBundle, ov: types.OverrideMacOsBundle) types.MacOsBundle {
    var out = base;
    if (ov.signingIdentity) |v| out.signingIdentity = v;
    if (ov.hardenedRuntime) |v| out.hardenedRuntime = v;
    if (ov.entitlements) |v| out.entitlements = v;
    if (ov.providerShortName) |v| out.providerShortName = v;
    if (ov.teamId) |v| out.teamId = v;
    if (ov.notarize) |v| out.notarize = v;
    if (ov.minimumSystemVersion) |v| out.minimumSystemVersion = v;
    return out;
}

// ─── dupAll: single allocation site, decomposed per nested type ──────────────

/// Returns true iff `runtime_slice.ptr` equals the slice's comptime default
/// `.ptr` for field `f` on parent struct `T`. A defaulted slice still pointing
/// at the static literal MUST NOT be `gpa.free`'d (the data lives in `.rodata`).
fn isStaticDefault(
    comptime T: type,
    comptime field_name: []const u8,
    runtime_slice: anytype,
) bool {
    const f = comptime fieldInfo(T, field_name);
    const FT = f.type;
    if (f.default_value_ptr) |dvp| {
        const default_val: *const FT = @ptrCast(@alignCast(dvp));
        return runtime_slice.ptr == default_val.*.ptr;
    }
    return false;
}

fn fieldInfo(comptime T: type, comptime field_name: []const u8) std.builtin.Type.StructField {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, field_name)) return f;
    }
    @compileError("no such field: " ++ field_name);
}

/// Dup a `[]const u8` field unless it is still its comptime static-literal
/// default (in which case the static pointer is returned unchanged).
fn dupString(
    gpa: std.mem.Allocator,
    comptime T: type,
    comptime field_name: []const u8,
    runtime_slice: []const u8,
) std.mem.Allocator.Error![]const u8 {
    if (isStaticDefault(T, field_name, runtime_slice)) return runtime_slice;
    return try gpa.dupe(u8, runtime_slice);
}

/// Optional-string dup: null stays null, non-null dups (no static-default
/// check; the comptime default for `?T` fields is `null`, so a non-null
/// runtime value is always allocator-owned). Tracking the source pointer
/// against the parent struct's default is not meaningful for nullables.
fn dupOptString(
    gpa: std.mem.Allocator,
    s: ?[]const u8,
) std.mem.Allocator.Error!?[]const u8 {
    if (s) |inner| return try gpa.dupe(u8, inner);
    return null;
}

/// Dup a `[]const []const u8` field (e.g. `Csp.scriptSrc`). When the outer
/// slice is still the static-literal default, no allocation happens. Otherwise
/// the outer slice is duped AND every inner string is duped. The inner
/// strings have no per-element static default, so dup is unconditional.
/// An OOM partway through frees the prefix of inner strings already duped
/// then frees the outer slice.
fn dupStringList(
    gpa: std.mem.Allocator,
    comptime T: type,
    comptime field_name: []const u8,
    runtime: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    if (isStaticDefault(T, field_name, runtime)) return runtime;
    const outer = try gpa.alloc([]const u8, runtime.len);
    errdefer gpa.free(outer);
    var done: usize = 0;
    errdefer for (outer[0..done]) |s| gpa.free(s);
    while (done < runtime.len) : (done += 1) {
        outer[done] = try gpa.dupe(u8, runtime[done]);
    }
    return outer;
}

/// Dup a `[]const Window` field. When still the static default (empty
/// literal), no allocation. Otherwise dup the outer slice AND each Window's
/// owned string fields (label, title, and url-if-Some). Window has no
/// per-element static default, so each is dup'd unconditionally.
fn dupWindowList(
    gpa: std.mem.Allocator,
    comptime T: type,
    comptime field_name: []const u8,
    runtime: []const types.Window,
) std.mem.Allocator.Error![]const types.Window {
    if (isStaticDefault(T, field_name, runtime)) return runtime;
    const outer = try gpa.alloc(types.Window, runtime.len);
    errdefer gpa.free(outer);

    var done: usize = 0;
    // Free strings of any fully-duped windows up to `done`.
    errdefer {
        var i: usize = 0;
        while (i < done) : (i += 1) {
            gpa.free(outer[i].label);
            gpa.free(outer[i].title);
            if (outer[i].url) |u| gpa.free(u);
        }
    }

    while (done < runtime.len) : (done += 1) {
        var w = runtime[done];
        // Allocate label first.
        const label = try gpa.dupe(u8, w.label);
        errdefer gpa.free(label);
        const title = try gpa.dupe(u8, w.title);
        errdefer gpa.free(title);
        const url_opt: ?[]const u8 = if (w.url) |u| try gpa.dupe(u8, u) else null;
        // No errdefer past this; once the optional url alloc succeeded, the
        // window record is committed and we advance `done` on the next loop
        // iteration after writing.
        w.label = label;
        w.title = title;
        w.url = url_opt;
        outer[done] = w;
    }
    return outer;
}

/// Dup a `[]const Target` (enum) field. When still the static default, return
/// it unchanged. Otherwise dup the outer slice (enum elements own no
/// memory).
fn dupTargetList(
    gpa: std.mem.Allocator,
    comptime T: type,
    comptime field_name: []const u8,
    runtime: []const types.Target,
) std.mem.Allocator.Error![]const types.Target {
    if (isStaticDefault(T, field_name, runtime)) return runtime;
    return try gpa.dupe(types.Target, runtime);
}

/// Free a `[]const []const u8` previously produced by `dupStringList`. Used
/// only by `dupX` errdefer paths to unwind partial progress in this helper.
fn freeStringListDuped(
    gpa: std.mem.Allocator,
    comptime T: type,
    comptime field_name: []const u8,
    runtime: []const []const u8,
) void {
    if (isStaticDefault(T, field_name, runtime)) return;
    for (runtime) |s| gpa.free(s);
    gpa.free(runtime);
}

fn freeWindowListDuped(
    gpa: std.mem.Allocator,
    comptime T: type,
    comptime field_name: []const u8,
    runtime: []const types.Window,
) void {
    if (isStaticDefault(T, field_name, runtime)) return;
    for (runtime) |w| {
        gpa.free(w.label);
        gpa.free(w.title);
        if (w.url) |u| gpa.free(u);
    }
    gpa.free(runtime);
}

fn freeTargetListDuped(
    gpa: std.mem.Allocator,
    comptime T: type,
    comptime field_name: []const u8,
    runtime: []const types.Target,
) void {
    if (isStaticDefault(T, field_name, runtime)) return;
    gpa.free(runtime);
}

fn freeStringDuped(
    gpa: std.mem.Allocator,
    comptime T: type,
    comptime field_name: []const u8,
    runtime: []const u8,
) void {
    if (isStaticDefault(T, field_name, runtime)) return;
    gpa.free(runtime);
}

// ─── dupX per nested type ────────────────────────────────────────────────────

fn dupWindowDefaults(gpa: std.mem.Allocator, in: types.WindowDefaults) std.mem.Allocator.Error!types.WindowDefaults {
    _ = gpa;
    // All scalars; no allocation.
    return in;
}

fn dupApp(gpa: std.mem.Allocator, in: types.App) std.mem.Allocator.Error!types.App {
    var out = in;
    out.windowDefaults = try dupWindowDefaults(gpa, in.windowDefaults);
    // windows: []const Window with static default &.{} (empty).
    out.windows = try dupWindowList(gpa, types.App, "windows", in.windows);
    return out;
}

fn dupFuses(gpa: std.mem.Allocator, in: types.Fuses) std.mem.Allocator.Error!types.Fuses {
    _ = gpa;
    return in;
}

fn dupCsp(gpa: std.mem.Allocator, in: types.Csp) std.mem.Allocator.Error!types.Csp {
    var out = in;
    out.defaultSrc = try dupStringList(gpa, types.Csp, "defaultSrc", in.defaultSrc);
    errdefer freeStringListDuped(gpa, types.Csp, "defaultSrc", out.defaultSrc);
    out.scriptSrc = try dupStringList(gpa, types.Csp, "scriptSrc", in.scriptSrc);
    errdefer freeStringListDuped(gpa, types.Csp, "scriptSrc", out.scriptSrc);
    out.styleSrc = try dupStringList(gpa, types.Csp, "styleSrc", in.styleSrc);
    errdefer freeStringListDuped(gpa, types.Csp, "styleSrc", out.styleSrc);
    out.connectSrc = try dupStringList(gpa, types.Csp, "connectSrc", in.connectSrc);
    errdefer freeStringListDuped(gpa, types.Csp, "connectSrc", out.connectSrc);
    out.imgSrc = try dupStringList(gpa, types.Csp, "imgSrc", in.imgSrc);
    // success: no errdefer for the last field; caller's errdefer covers the whole Csp.
    return out;
}

fn freeCspDuped(gpa: std.mem.Allocator, c: types.Csp) void {
    freeStringListDuped(gpa, types.Csp, "defaultSrc", c.defaultSrc);
    freeStringListDuped(gpa, types.Csp, "scriptSrc", c.scriptSrc);
    freeStringListDuped(gpa, types.Csp, "styleSrc", c.styleSrc);
    freeStringListDuped(gpa, types.Csp, "connectSrc", c.connectSrc);
    freeStringListDuped(gpa, types.Csp, "imgSrc", c.imgSrc);
}

fn dupSecurity(gpa: std.mem.Allocator, in: types.Security) std.mem.Allocator.Error!types.Security {
    var out = in;
    out.grants = try dupStringList(gpa, types.Security, "grants", in.grants);
    errdefer freeStringListDuped(gpa, types.Security, "grants", out.grants);
    out.csp = try dupCsp(gpa, in.csp);
    errdefer freeCspDuped(gpa, out.csp);
    out.fuses = try dupFuses(gpa, in.fuses);
    return out;
}

fn freeSecurityDuped(gpa: std.mem.Allocator, s: types.Security) void {
    freeStringListDuped(gpa, types.Security, "grants", s.grants);
    freeCspDuped(gpa, s.csp);
}

fn dupFrontend(gpa: std.mem.Allocator, in: types.Frontend) std.mem.Allocator.Error!types.Frontend {
    var out = in;
    out.dev = try dupOptString(gpa, in.dev);
    errdefer if (out.dev) |s| gpa.free(s);
    out.build = try dupOptString(gpa, in.build);
    errdefer if (out.build) |s| gpa.free(s);
    out.serveUrl = try dupOptString(gpa, in.serveUrl);
    errdefer if (out.serveUrl) |s| gpa.free(s);
    // outDir has a static-literal default "dist".
    out.outDir = try dupString(gpa, types.Frontend, "outDir", in.outDir);
    return out;
}

fn freeFrontendDuped(gpa: std.mem.Allocator, b: types.Frontend) void {
    if (b.dev) |s| gpa.free(s);
    if (b.build) |s| gpa.free(s);
    if (b.serveUrl) |s| gpa.free(s);
    freeStringDuped(gpa, types.Frontend, "outDir", b.outDir);
}

fn dupMacOsBundle(gpa: std.mem.Allocator, in: types.MacOsBundle) std.mem.Allocator.Error!types.MacOsBundle {
    var out = in;
    out.signingIdentity = try dupOptString(gpa, in.signingIdentity);
    errdefer if (out.signingIdentity) |s| gpa.free(s);
    out.entitlements = try dupOptString(gpa, in.entitlements);
    errdefer if (out.entitlements) |s| gpa.free(s);
    out.providerShortName = try dupOptString(gpa, in.providerShortName);
    errdefer if (out.providerShortName) |s| gpa.free(s);
    out.teamId = try dupOptString(gpa, in.teamId);
    errdefer if (out.teamId) |s| gpa.free(s);
    out.minimumSystemVersion = try dupString(gpa, types.MacOsBundle, "minimumSystemVersion", in.minimumSystemVersion);
    return out;
}

fn freeMacOsBundleDuped(gpa: std.mem.Allocator, m: types.MacOsBundle) void {
    if (m.signingIdentity) |s| gpa.free(s);
    if (m.entitlements) |s| gpa.free(s);
    if (m.providerShortName) |s| gpa.free(s);
    if (m.teamId) |s| gpa.free(s);
    freeStringDuped(gpa, types.MacOsBundle, "minimumSystemVersion", m.minimumSystemVersion);
}

fn dupBundle(gpa: std.mem.Allocator, in: types.Bundle) std.mem.Allocator.Error!types.Bundle {
    var out = in;
    out.targets = try dupTargetList(gpa, types.Bundle, "targets", in.targets);
    errdefer freeTargetListDuped(gpa, types.Bundle, "targets", out.targets);
    out.icon = try dupStringList(gpa, types.Bundle, "icon", in.icon);
    errdefer freeStringListDuped(gpa, types.Bundle, "icon", out.icon);
    out.category = try dupOptString(gpa, in.category);
    errdefer if (out.category) |s| gpa.free(s);
    out.copyright = try dupOptString(gpa, in.copyright);
    errdefer if (out.copyright) |s| gpa.free(s);
    out.bundleVersion = try dupOptString(gpa, in.bundleVersion);
    errdefer if (out.bundleVersion) |s| gpa.free(s);
    out.displayName = try dupOptString(gpa, in.displayName);
    errdefer if (out.displayName) |s| gpa.free(s);
    out.macos = try dupMacOsBundle(gpa, in.macos);
    return out;
}

fn freeBundleDuped(gpa: std.mem.Allocator, b: types.Bundle) void {
    freeTargetListDuped(gpa, types.Bundle, "targets", b.targets);
    freeStringListDuped(gpa, types.Bundle, "icon", b.icon);
    if (b.category) |s| gpa.free(s);
    if (b.copyright) |s| gpa.free(s);
    if (b.bundleVersion) |s| gpa.free(s);
    if (b.displayName) |s| gpa.free(s);
    freeMacOsBundleDuped(gpa, b.macos);
}

fn dupAll(gpa: std.mem.Allocator, in: Manifest) std.mem.Allocator.Error!Manifest {
    var out = in;

    out.identifier = try gpa.dupe(u8, in.identifier);
    errdefer gpa.free(out.identifier);
    out.productName = try gpa.dupe(u8, in.productName);
    errdefer gpa.free(out.productName);
    out.version = try gpa.dupe(u8, in.version);
    errdefer gpa.free(out.version);

    out.app = try dupApp(gpa, in.app);
    errdefer freeWindowListDuped(gpa, types.App, "windows", out.app.windows);
    // (windowDefaults inside App has no allocation, so only windows need freeing.)

    out.security = try dupSecurity(gpa, in.security);
    errdefer freeSecurityDuped(gpa, out.security);

    out.frontend = try dupFrontend(gpa, in.frontend);
    errdefer freeFrontendDuped(gpa, out.frontend);

    out.bundle = try dupBundle(gpa, in.bundle);

    return out;
}

// ─── tests ───────────────────────────────────────────────────────────────────

const parse = @import("parse.zig");

fn baseFixture() Manifest {
    return Manifest{
        .identifier = "com.example.app",
        .productName = "BaseProduct",
        .version = "0.1.0",
        .app = .{
            .windowDefaults = .{ .width = 800, .height = 600 },
            .windows = &.{
                .{ .label = "main", .title = "Main", .width = 900, .height = 680 },
            },
        },
    };
}

test "override scalar replaces base" {
    const gpa = std.testing.allocator;
    const base = baseFixture();
    const override = OverrideManifest{ .productName = "OverrideProduct" };
    const m = try merge(gpa, base, override);
    defer parse.freeManifest(gpa, m);
    try std.testing.expectEqualStrings("OverrideProduct", m.productName);
    // Base identifier and version survive unchanged.
    try std.testing.expectEqualStrings("com.example.app", m.identifier);
    try std.testing.expectEqualStrings("0.1.0", m.version);
}

test "base scalar equal to its default is preserved when override omits it" {
    // base.app.windowDefaults.width = 800 explicitly (which happens to equal the
    // type's default). Override carries an OverrideApp with windowDefaults set
    // but width=null. Merged width must stay 800. This is the test that
    // discriminates the optional-mirror design from a "two default-filled
    // structs are indistinguishable" merge.
    const gpa = std.testing.allocator;
    const base = baseFixture();
    const override = OverrideManifest{
        .app = .{
            .windowDefaults = .{ .height = 720 }, // width omitted (null)
        },
    };
    const m = try merge(gpa, base, override);
    defer parse.freeManifest(gpa, m);
    try std.testing.expectEqual(@as(u32, 800), m.app.windowDefaults.width);
    try std.testing.expectEqual(@as(u32, 720), m.app.windowDefaults.height);
}

test "override array replaces base array wholesale" {
    const gpa = std.testing.allocator;
    const base = baseFixture();
    const ov_windows = [_]types.Window{
        .{ .label = "alt", .title = "Alt" },
        .{ .label = "main", .title = "Main" },
    };
    const override = OverrideManifest{
        .app = .{ .windows = &ov_windows },
    };
    const m = try merge(gpa, base, override);
    defer parse.freeManifest(gpa, m);
    try std.testing.expectEqual(@as(usize, 2), m.app.windows.len);
    try std.testing.expectEqualStrings("alt", m.app.windows[0].label);
    try std.testing.expectEqualStrings("main", m.app.windows[1].label);
}

test "absent nested override leaves the base subtree untouched" {
    const gpa = std.testing.allocator;
    const base = baseFixture();
    // override carries productName only; o.bundle is null.
    const override = OverrideManifest{ .productName = "X" };
    const m = try merge(gpa, base, override);
    defer parse.freeManifest(gpa, m);
    // Bundle is byte-identical to the base default (all defaults).
    try std.testing.expectEqual(base.bundle.targets.len, m.bundle.targets.len);
    try std.testing.expectEqual(base.bundle.targets[0], m.bundle.targets[0]);
    try std.testing.expectEqual(base.bundle.targets[1], m.bundle.targets[1]);
    try std.testing.expectEqualStrings(
        base.bundle.macos.minimumSystemVersion,
        m.bundle.macos.minimumSystemVersion,
    );
    try std.testing.expectEqual(base.bundle.macos.hardenedRuntime, m.bundle.macos.hardenedRuntime);
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        m.bundle.macos.signingIdentity,
    );
}

test "platform override carries the new macos/bundle fields and frees cleanly" {
    const gpa = std.testing.allocator;
    const base = Manifest{
        .identifier = "com.example.app",
        .productName = "BaseProduct",
        .version = "0.1.0",
        .app = .{ .windows = &.{.{ .label = "main", .title = "Main" }} },
        .bundle = .{
            .macos = .{ .teamId = "BASE", .notarize = true },
            .bundleVersion = "1",
            .displayName = "Base",
        },
    };
    const override = OverrideManifest{
        .bundle = .{
            .macos = .{ .teamId = "OVR", .notarize = false },
            .bundleVersion = "9",
            .displayName = "Ovr",
        },
    };
    const m = try merge(gpa, base, override);
    defer parse.freeManifest(gpa, m);
    try std.testing.expectEqualStrings("OVR", m.bundle.macos.teamId.?);
    try std.testing.expect(!m.bundle.macos.notarize);
    try std.testing.expectEqualStrings("9", m.bundle.bundleVersion.?);
    try std.testing.expectEqualStrings("Ovr", m.bundle.displayName.?);
}

// OOM sweep: every allocation index must produce zero leaks, no invalid-frees,
// and leave the inputs intact (the inputs are stack values composed of static
// slices, so they need no separate cleanup here).
fn oomTestImpl(gpa: std.mem.Allocator) !void {
    // Build a base + override that exercise every allocating helper:
    //   - identifier/productName/version (always dup)
    //   - app.windows (non-static list with three Windows, each with url Some)
    //   - security.grants (non-static []const []const u8)
    //   - security.csp.scriptSrc (non-static []const []const u8 via override)
    //   - frontend.dev (non-null optional)
    //   - bundle.icon (non-static []const []const u8)
    //   - bundle.targets (non-static []const Target)
    //   - bundle.category / copyright (non-null optionals)
    //   - bundle.macos.signingIdentity (non-null optional)
    //   - bundle.macos.minimumSystemVersion (non-default string)
    const base_windows = [_]types.Window{
        .{ .label = "main", .title = "Main", .url = "app://main" },
        .{ .label = "alt", .title = "Alt", .url = "app://alt" },
        .{ .label = "third", .title = "Third" },
    };
    const base_caps = [_][]const u8{ "fs.read", "net.fetch" };
    const ov_script_src = [_][]const u8{ "'self'", "'unsafe-inline'" };
    const base_icons = [_][]const u8{ "icon-256.png", "icon-512.png" };
    const base_targets = [_]types.Target{ .app, .dmg, .app };

    const base = Manifest{
        .identifier = "com.example.deep",
        .productName = "Deep",
        .version = "1.2.3",
        .app = .{ .windows = &base_windows },
        .security = .{ .grants = &base_caps },
        .frontend = .{ .dev = "bun run dev" },
        .bundle = .{
            .targets = &base_targets,
            .icon = &base_icons,
            .category = "public.app-category.developer-tools",
            .copyright = "(c) 2026",
            .bundleVersion = "1",
            .displayName = "Base",
            .macos = .{
                .signingIdentity = "Developer ID Application: X",
                .teamId = "BASE",
                .minimumSystemVersion = "12.0",
            },
        },
    };
    const override = OverrideManifest{
        .productName = "DeepOverride",
        .security = .{ .csp = .{ .scriptSrc = &ov_script_src } },
        .bundle = .{
            .bundleVersion = "9",
            .displayName = "Ovr",
            .macos = .{ .teamId = "OVR", .notarize = false },
        },
    };
    const m = try merge(gpa, base, override);
    parse.freeManifest(gpa, m);
}

test "merge under checkAllAllocationFailures has zero leaks AND base remains freeable" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, oomTestImpl, .{});
}
