//! Minimal manifest types owned by sub-project D (manifest/config). Created here
//! by C because C consumes them and is built before D. D later takes ownership
//! and extends these (the manifest parser, JSON schema, fuse storage). This file
//! imports nothing from src/security/ so there is no dependency cycle.

const std = @import("std");

/// Build-time, runtime-immutable kill switches (Electron-fuses analog). All
/// default false (deny-by-default posture). C reads `allowRemoteContent` and
/// `allowShell` at GrantTable.compile to force-drop grants; F enforces
/// `allowEval` and `debugInspector`.
pub const Fuses = struct {
    allowRemoteContent: bool = false,
    allowEval: bool = false,
    allowShell: bool = false,
    debugInspector: bool = false,
};

pub const HostRule = struct { host: []const u8, port: ?u16 = null };

/// Per-resource scope. The union tag IS the scope kind (no separate enum).
pub const Scope = union(enum) {
    path: []const u8, // glob with $APPDATA/$HOME/$APPCONFIG/** tokens
    host: HostRule, // host glob plus optional exact port
    argv: []const u8, // exact argv token (no globbing)
    label: []const u8, // window-label glob
};

/// A single permission grants commands and carries scope. Deny beats allow.
pub const Permission = struct {
    identifier: []const u8, // "<plugin>:<action>", lower-ascii
    commandsAllow: []const []const u8 = &.{},
    commandsDeny: []const []const u8 = &.{},
    scopeAllow: []const Scope = &.{},
    scopeDeny: []const Scope = &.{},
};

/// Stable diagnostic codes for the build-time config + capability cross-check
/// stream. D emits the config codes; C emits `fuse_requires_capability` and
/// `capability_window_unknown` (it has the capability-file contents D does not
/// parse). Both streams read uniformly because they share this vocabulary.
pub const Code = enum {
    // --- D-emitted (manifest validation) ---
    zon_parse_error,
    missing_identifier,
    invalid_identifier,
    invalid_version,
    invalid_team_id,
    invalid_bundle_version,
    invalid_display_name,
    invalid_minimum_system_version,
    no_main_window,
    duplicate_window_label,
    empty_window_label,
    unknown_capability_ref,
    permission_not_app_namespaced,
    permission_scope_unconfined,
    inspector_in_release,
    dev_url_without_command, // WARNING (is_error=false)
    override_for_target_dropped, // WARNING: a per-OS override file exists but target_os has no mapping
    // --- C-emitted (capability-file cross-checks); kept here for one vocabulary ---
    fuse_requires_capability,
    capability_window_unknown,
};

/// One build-time diagnostic. `message` is a static template keyed off `code`
/// (no allocation, never freed). `path` is the dotted manifest location of the
/// offending field; allocator-owned when present, freed by Diagnostics.deinit.
///
/// DEVIATION (ratified): `path` is OPTIONAL, not the spec's literal []const u8.
/// C's advisory enforcement diagnostics carry no path; an optional lets C's
/// `.{ .code, .message }` literals compile unchanged and lets deinit free only
/// the non-null, heap-built paths D produces.
pub const Diagnostic = struct {
    code: Code,
    is_error: bool = true,
    message: []const u8,
    /// Invariant: when non-null, `path` MUST be allocator-owned (built with
    /// std.fmt.allocPrint from static segments). Diagnostics.deinit frees it.
    /// A static-string `path` will cause an invalid-free under the testing
    /// allocator; if a static path ever makes sense, dup it before adding.
    path: ?[]const u8 = null,
};

/// Build-time diagnostic sink. Two writers by design:
///   - `report`: OOM-SWALLOWING. C's GrantTable.compile fail-closed path uses
///     this; a dropped advisory diagnostic must never make the build fail-open.
///   - `add`: OOM-SURFACING. D's manifest validation uses this; an allocation
///     failure while recording a config error should abort the build, not
///     silently lose the error.
pub const Diagnostics = struct {
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn report(self: *Diagnostics, alloc: std.mem.Allocator, d: Diagnostic) void {
        self.items.append(alloc, d) catch {};
    }

    pub fn add(self: *Diagnostics, alloc: std.mem.Allocator, d: Diagnostic) std.mem.Allocator.Error!void {
        try self.items.append(alloc, d);
    }

    /// True if any item is error-level (warnings such as dev_url_without_command excluded).
    pub fn hasErrors(self: Diagnostics) bool {
        for (self.items.items) |d| if (d.is_error) return true;
        return false;
    }

    pub fn deinit(self: *Diagnostics, alloc: std.mem.Allocator) void {
        for (self.items.items) |d| if (d.path) |p| alloc.free(p);
        self.items.deinit(alloc);
    }
};

test "Diagnostics collects reported diagnostics" {
    var diags: Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    diags.report(std.testing.allocator, .{ .code = .fuse_requires_capability, .message = "x" });
    try std.testing.expectEqual(@as(usize, 1), diags.items.items.len);
    try std.testing.expectEqual(Code.fuse_requires_capability, diags.items.items[0].code);
}

test "Fuses default to the deny-by-default posture (all false)" {
    const f: Fuses = .{};
    try std.testing.expect(!f.allowRemoteContent and !f.allowEval and !f.allowShell and !f.debugInspector);
}

test "Diagnostics.add surfaces OOM and hasErrors reflects error-level items" {
    var diags: Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    try diags.add(std.testing.allocator, .{ .code = .invalid_version, .message = "bad", .path = null });
    try std.testing.expect(diags.hasErrors());
    try diags.add(std.testing.allocator, .{ .code = .dev_url_without_command, .is_error = false, .message = "warn", .path = null });
    try std.testing.expectEqual(@as(usize, 2), diags.items.items.len);
    // a warnings-only set has no errors:
    var warn_only: Diagnostics = .{};
    defer warn_only.deinit(std.testing.allocator);
    try warn_only.add(std.testing.allocator, .{ .code = .dev_url_without_command, .is_error = false, .message = "w", .path = null });
    try std.testing.expect(!warn_only.hasErrors());
}

/// The app manifest. This type IS the schema: std.zon parses zigware.zon
/// directly into it, and an unknown or mistyped key becomes a parse error
/// against this struct rather than a silent ignore.
pub const Manifest = struct {
    /// Reverse-DNS bundle identifier, e.g. "com.example.app". Required.
    identifier: []const u8,
    /// Display name. Maps to CFBundleName on macOS.
    productName: []const u8,
    /// Semver string, e.g. "0.1.0". Maps to CFBundleShortVersionString.
    version: []const u8,

    app: App = .{},
    security: Security = .{},
    frontend: Frontend = .{},
    bundle: Bundle = .{},
};

pub const App = struct {
    /// Default window options applied to any window that omits a field.
    windowDefaults: WindowDefaults = .{},
    /// Declared windows. Each has a STABLE LABEL (security model section 6).
    /// At least one window with label "main" is required.
    windows: []const Window = &.{},
    /// Platform-aware quit policy. Replaces Electron's hand-written
    /// process.platform !== 'darwin' boilerplate. The macOS default is
    /// keep_running_on_last_close.
    quitOnLastWindowClosed: QuitPolicy = .keep_running_on_last_close,
    /// Fallback timeout (ms) after which a window is shown even if it never
    /// signals first paint, so show:false can never strand a window hidden.
    windowShowFallbackMs: u32 = 5000,
};

/// Defined once here; imported by E (window lifecycle) and by A's lifecycle
/// policy. macOS default = keep_running_on_last_close.
pub const QuitPolicy = enum {
    /// Stay running when the last window closes (macOS default behavior).
    keep_running_on_last_close,
    /// Quit the process when the last window closes.
    quit_on_last_close,
    /// Never quit implicitly; the app exits only on an explicit request.
    explicit,
};

pub const WindowDefaults = struct {
    width: u32 = 800,
    height: u32 = 600,
    /// Hidden until first paint to avoid the white flash (A's show-on-ready).
    show: bool = false,
    /// macOS titlebar style (default | hidden | hidden_inset).
    titleBarStyle: TitleBarStyle = .default,
    decorations: bool = true,
};

pub const Window = struct {
    /// Stable identifier capabilities bind to. NOT the title (titles are
    /// JS-mutable and spoofable; security model section 6). Required, unique.
    label: []const u8,
    /// Initial URL. null means derive: serveUrl in dev, app:// in prod.
    url: ?[]const u8 = null,
    title: []const u8,
    width: u32 = 800,
    height: u32 = 600,
    decorations: bool = true,
    titleBarStyle: TitleBarStyle = .default,
    /// Hidden until first paint to avoid the white flash (A's show-on-ready).
    show: bool = false,
};

pub const TitleBarStyle = enum { default, hidden, hidden_inset };

pub const Security = struct {
    /// Grant identifiers referenced from src/grants/*.zon. Resolution and
    /// enforcement is sub-project C; D validates that each referenced
    /// identifier resolves to a grant file. NOTE: the surface vocabulary is
    /// "grant", but the internal capability-based-security code in src/security/*
    /// and the diagnostic code names (e.g. unknown_capability_ref) deliberately
    /// keep the generic "capability" term; do not rename them to match.
    grants: []const []const u8 = &.{},
    /// App-declared scoped permissions. Each id MUST be `app:`-prefixed and
    /// each scopeAllow path MUST be confined to `$APPDATA` (validate.zig).
    /// Threaded into the live grant catalog by synthAppGrants/App.init.
    permissions: []const Permission = &.{},
    /// Content-Security-Policy. F performs compile-time script-hash injection
    /// for own scripts; the author declares only trusted hosts here.
    csp: Csp = .{},
    /// Build-time fuses. All default OFF/safe. Compiled into the binary as
    /// comptime constants; an auditor reads the whole native attack surface
    /// here. Reuses the canonical Fuses type defined above.
    fuses: Fuses = .{},
};

pub const Csp = struct {
    /// Directive -> sources. Assembled into the policy header string by F.
    /// Default is the model's strict baseline.
    defaultSrc: []const []const u8 = &.{"'self'"},
    scriptSrc: []const []const u8 = &.{"'self'"},
    styleSrc: []const []const u8 = &.{"'self'"},
    connectSrc: []const []const u8 = &.{"'self'"},
    imgSrc: []const []const u8 = &.{"'self'"},
};

pub const Frontend = struct {
    /// Command run before `dev` (e.g. "bun run dev"). Frontend-toolchain
    /// agnostic; keeps the npm/Vite ecosystem unchanged.
    dev: ?[]const u8 = null,
    /// Command run before `build` (e.g. "bun run build").
    build: ?[]const u8 = null,
    /// Dev server URL. A trusted origin ONLY in dev builds (security model
    /// section 12, F). e.g. "http://localhost:5173".
    serveUrl: ?[]const u8 = null,
    /// Directory of built frontend assets embedded for release (app://).
    outDir: []const u8 = "dist",
};

pub const Bundle = struct {
    /// Bundle targets for sub-project G. v0.1.0 honors .app and .dmg.
    targets: []const Target = &.{ .app, .dmg },
    /// Paths to icon files (.icns generated by G).
    icon: []const []const u8 = &.{},
    category: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    /// Marketing/build version string. Maps to CFBundleVersion on macOS. When
    /// null, G falls back to the top-level `version`.
    bundleVersion: ?[]const u8 = null,
    /// Override for the user-visible bundle name. When null, G falls back to
    /// the top-level `productName`.
    displayName: ?[]const u8 = null,
    macos: MacOsBundle = .{},
};

pub const Target = enum { app, dmg };

pub const MacOsBundle = struct {
    /// codesign identity, e.g. "Developer ID Application: Name (TEAMID)".
    signingIdentity: ?[]const u8 = null,
    hardenedRuntime: bool = true,
    /// Path to entitlements.plist.
    entitlements: ?[]const u8 = null,
    /// notarytool provider short name / team id.
    providerShortName: ?[]const u8 = null,
    /// Apple Developer Team ID, e.g. "ABCDE12345". Used by notarytool.
    teamId: ?[]const u8 = null,
    /// Whether G notarizes the signed artifacts. Defaults on.
    notarize: bool = true,
    minimumSystemVersion: []const u8 = "11.0",
};

/// All-optional mirror of `WindowDefaults` for the platform-override merge. Each
/// leaf is optional so the merge can distinguish "field absent in override" from
/// "field present and set to its default". Arrays replace wholesale.
pub const OverrideWindowDefaults = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    show: ?bool = null,
    titleBarStyle: ?TitleBarStyle = null,
    decorations: ?bool = null,
};

/// All-optional mirror of `App` for the platform-override merge. Each leaf is
/// optional so the merge can distinguish "field absent in override" from "field
/// present and set to its default". Arrays replace wholesale.
pub const OverrideApp = struct {
    windowDefaults: ?OverrideWindowDefaults = null,
    windows: ?[]const Window = null,
    quitOnLastWindowClosed: ?QuitPolicy = null,
    windowShowFallbackMs: ?u32 = null,
};

/// All-optional mirror of `Fuses` for the platform-override merge. Each leaf is
/// optional so the merge can distinguish "field absent in override" from "field
/// present and set to its default". Arrays replace wholesale.
pub const OverrideFuses = struct {
    allowRemoteContent: ?bool = null,
    allowEval: ?bool = null,
    allowShell: ?bool = null,
    debugInspector: ?bool = null,
};

/// All-optional mirror of `Csp` for the platform-override merge. Each leaf is
/// optional so the merge can distinguish "field absent in override" from "field
/// present and set to its default". Arrays replace wholesale.
pub const OverrideCsp = struct {
    defaultSrc: ?[]const []const u8 = null,
    scriptSrc: ?[]const []const u8 = null,
    styleSrc: ?[]const []const u8 = null,
    connectSrc: ?[]const []const u8 = null,
    imgSrc: ?[]const []const u8 = null,
};

/// All-optional mirror of `Security` for the platform-override merge. Each leaf
/// is optional so the merge can distinguish "field absent in override" from
/// "field present and set to its default". Arrays replace wholesale.
pub const OverrideSecurity = struct {
    grants: ?[]const []const u8 = null,
    permissions: ?[]const Permission = null,
    csp: ?OverrideCsp = null,
    fuses: ?OverrideFuses = null,
};

/// All-optional mirror of `Frontend` for the platform-override merge. Each leaf is
/// optional so the merge can distinguish "field absent in override" from "field
/// present and set to its default". Arrays replace wholesale.
pub const OverrideFrontend = struct {
    dev: ?[]const u8 = null,
    build: ?[]const u8 = null,
    serveUrl: ?[]const u8 = null,
    outDir: ?[]const u8 = null,
};

/// All-optional mirror of `MacOsBundle` for the platform-override merge. Each
/// leaf is optional so the merge can distinguish "field absent in override" from
/// "field present and set to its default". Arrays replace wholesale.
pub const OverrideMacOsBundle = struct {
    signingIdentity: ?[]const u8 = null,
    hardenedRuntime: ?bool = null,
    entitlements: ?[]const u8 = null,
    providerShortName: ?[]const u8 = null,
    teamId: ?[]const u8 = null,
    notarize: ?bool = null,
    minimumSystemVersion: ?[]const u8 = null,
};

/// All-optional mirror of `Bundle` for the platform-override merge. Each leaf is
/// optional so the merge can distinguish "field absent in override" from "field
/// present and set to its default". Arrays replace wholesale.
pub const OverrideBundle = struct {
    targets: ?[]const Target = null,
    icon: ?[]const []const u8 = null,
    category: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    bundleVersion: ?[]const u8 = null,
    displayName: ?[]const u8 = null,
    macos: ?OverrideMacOsBundle = null,
};

/// All-optional mirror of `Manifest` for the platform-override merge. Each leaf
/// is optional so the merge can distinguish "field absent in override" from
/// "field present and set to its default". Arrays replace wholesale.
pub const OverrideManifest = struct {
    identifier: ?[]const u8 = null,
    productName: ?[]const u8 = null,
    version: ?[]const u8 = null,
    app: ?OverrideApp = null,
    security: ?OverrideSecurity = null,
    frontend: ?OverrideFrontend = null,
    bundle: ?OverrideBundle = null,
};

test "Manifest defaults fill a minimal manifest" {
    const m = Manifest{ .identifier = "com.example.app", .productName = "App", .version = "0.1.0" };
    try std.testing.expectEqual(@as(u32, 800), m.app.windowDefaults.width);
    try std.testing.expectEqual(QuitPolicy.keep_running_on_last_close, m.app.quitOnLastWindowClosed);
    try std.testing.expect(!m.security.fuses.allowShell);
    try std.testing.expectEqualStrings("dist", m.frontend.outDir);
    try std.testing.expectEqual(@as(usize, 2), m.bundle.targets.len);
    try std.testing.expect(m.bundle.macos.hardenedRuntime);
    try std.testing.expectEqualStrings("'self'", m.security.csp.scriptSrc[0]);
}

// Comptime recursive walker: descends every nested struct on the base side
// and asserts the corresponding optional-wrapped Override mirror has the same
// field set, recursively. A new field on App/Bundle/Csp/etc. with no matching
// Override<X> field fails this at COMPILE TIME, not silently at runtime.
fn assertParallel(comptime Base: type, comptime Override: type) void {
    const bf = @typeInfo(Base).@"struct".fields;
    const of = @typeInfo(Override).@"struct".fields;
    if (bf.len != of.len) @compileError(
        "Override mirror field count differs from base; a field was added on one side without the other.",
    );
    inline for (bf) |b| {
        comptime var found_idx: ?usize = null;
        inline for (of, 0..) |o, j| if (comptime std.mem.eql(u8, b.name, o.name)) {
            found_idx = j;
        };
        if (found_idx == null) @compileError(
            "Override mirror is missing a field present in the base: " ++ b.name,
        );
        // Invariant: every struct-typed BASE field maps to an optional-wrapped
        // Override field whose inner type is a struct. Enforce it explicitly;
        // a silent skip would let a non-optional override mirror slip through
        // and break the merge semantics later.
        const BT = b.type;
        const OT = of[found_idx.?].type;
        if (@typeInfo(BT) == .@"struct") {
            if (@typeInfo(OT) != .optional) @compileError(
                "Override mirror for base struct field must be optional: " ++ b.name,
            );
            const Inner = @typeInfo(OT).optional.child;
            if (@typeInfo(Inner) != .@"struct") @compileError(
                "Override mirror for base struct field must wrap a struct (Override<Inner>): " ++ b.name,
            );
            assertParallel(BT, Inner);
        }
    }
}

test "OverrideManifest mirrors every Manifest field recursively" {
    comptime assertParallel(Manifest, OverrideManifest);
}

test "stringify renders a Scope union as a tagged literal" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const p = Permission{ .identifier = "app:hashFile", .scopeAllow = &.{.{ .path = "$APPDATA/notes/**" }} };
    try std.zon.stringify.serialize(p, .{}, &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), ".path") != null);
}
