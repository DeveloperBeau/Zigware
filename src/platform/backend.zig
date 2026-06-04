const std = @import("std");

/// Central error sets (finding M16). Both backends declare EXACTLY these on the
/// matching methods, so signatures never drift and assertBackend can compare
/// against one source of truth.
pub const CreateWindowError = error{ ScriptContainsNul, OutOfMemory };
pub const InjectScriptError = error{ ScriptContainsNul, OutOfMemory };
pub const SetTitleError = error{OutOfMemory};

/// Lifecycle events the backend reports through `onLifecycle`.
/// `window_all_closed` is emitted authoritatively by every backend when the
/// last window closes; A's lifecycle policy drives ordered shutdown from it.
pub const LifecycleEvent = enum { did_launch, window_all_closed, reopen, will_terminate };

/// Navigation guard outcome. A enforces a tight deny-by-default (only app:// or
/// the configured dev origin is allowed); sub-project C replaces the policy with
/// capability-aware checks but inherits the same tight default.
pub const NavigationDecision = enum { allow, cancel };

pub const TitleBarStyle = enum { standard, hidden };

/// Options for creating the one window A ships. `url` is the initial document:
/// `app://localhost/index.html` in production, a dev server URL later (F).
/// `user_scripts` are injected at document start, BEFORE the page load begins,
/// so the bridge shim exists before any page script can run. (Injecting after
/// loadRequest: misses the first page on WKWebView.)
pub const WindowOpts = struct {
    url: [:0]const u8,
    user_scripts: []const []const u8 = &.{},
    title: [:0]const u8 = "Zigware",
    width: f64 = 800,
    height: f64 = 600,
    decorations: bool = true,
    titlebar: TitleBarStyle = .standard,
    show: bool = true,
};

/// Which custom-scheme handler the request arrived through; A serves only `.asset_scheme`.
pub const RequestSource = enum { asset_scheme, stream_scheme };

/// A custom-scheme asset request.
///   `source` tags which scheme handler received it (finding M7). A only serves
///   `.asset_scheme`; anything else is 404 at the seam. Sub-project B adds the
///   `.stream_scheme` handler.
///   `path` is the request path. v0.1.0 carries only these two.
pub const Request = struct {
    source: RequestSource = .asset_scheme,
    path: []const u8,
};

/// A custom-scheme asset response.
///
/// LIFETIME CONTRACT (finding I5): `body` is valid only for the synchronous
/// duration of the `onSchemeRequest` callback. The backend MUST finish writing
/// the response (copy `body` into its NSData) before `onSchemeRequest` returns;
/// it must NOT retain `body` past the call. Today every body is an @embedFile
/// slice (forever-valid), but sub-project B's streaming returns transient
/// bodies, so no cache may hold `body` beyond the call.
///   `kind` lets a backend refuse to cache a transient body. A only ever
///   returns `.embedded_static`; `.transient` is reserved for B.
pub const ResponseKind = enum { embedded_static, transient };

pub const Response = struct {
    status: u16,
    mime: [:0]const u8,
    body: []const u8,
    kind: ResponseKind = .embedded_static,
};

/// Inbound callbacks the app registers on the backend via `setCallbacks`.
/// Runtime function pointers (not comptime) so the struct stays non-generic and
/// avoids circular genericity. `window_id` crosses as u64; v0.1.0 pins
/// B.WindowId == u64 (see assertBackend) so there is no truncation.
pub const Callbacks = struct {
    ctx: *anyopaque,
    onSchemeRequest: *const fn (ctx: *anyopaque, req: Request) Response,
    onMessage: *const fn (ctx: *anyopaque, window_id: u64, origin: []const u8, text: []const u8) void,
    onLifecycle: *const fn (ctx: *anyopaque, event: LifecycleEvent) void,
    onNavigation: *const fn (ctx: *anyopaque, url: []const u8) NavigationDecision,
};

/// Expected number of required backend methods; named once so the comptime
/// length assert below carries no bare magic literal.
const required_method_count = 19;

/// One name per line so the count is auditable and the comptime length assert
/// below cannot be silently fooled by an alignment trick (finding L12).
const required_methods = [_][]const u8{
    "createWindow",
    "destroyWindow",
    "setTitle",
    "setSize",
    "setFullscreen",
    "showWindow",
    "focusWindow",
    "evalJS",
    "injectUserScript",
    "windowId",
    "dispatchMain",
    "dispatchMainAfter",
    "cancelMainTimer",
    "pumpMain",
    "run",
    "terminate",
    "nativeWindow",
    "setCallbacks",
    "markJoined",
};

/// MAIN-THREAD TIMER SEAM (show-fallback). The window manager creates each
/// window hidden and arms a fallback that shows it if the page never signals
/// ready. That fallback is a MAIN-THREAD TIMER, never an OS thread: only the
/// main/UI thread touches the backend, so the framework spawns no hidden
/// threads.
///
///   dispatchMainAfter(delay_ms, work, ctx) -> token
///     Schedule `work(ctx)` to run ON THE MAIN THREAD after `delay_ms`.
///     Returns a non-zero cancellation token.
///   cancelMainTimer(token)
///     After this returns (called on the main thread), `work` is GUARANTEED
///     not to run. Idempotent: an unknown or already-fired token is a no-op.
///
/// CONTRACT: all timer scheduling, cancellation, and firing happen on the main
/// thread, so cancel-vs-fire is serialized — there is no data race between a
/// cancel and a fire. The CALLER owns `ctx` and frees it exactly once: on the
/// cancel path the caller frees it (the timer will not fire); on the fire path
/// the `work` callback frees it.
///
/// Comptime conformance check (finding H4, M11, L12). References every required
/// associated type and method by name so a missing one is a clear compile error,
/// not a cryptic instantiation failure deep in generic code. Future OS backends
/// call this too.
///
/// Beyond @hasDecl, each method slot is fetched with @field and required to be
/// an actual function (`@typeInfo(@TypeOf(field)) == .@"fn"`), so a
/// `pub const createWindow = 42;` or a non-callable decl is rejected AT THE SEAM.
/// (Full per-method argument-type comparison is deferred; the .@"fn" gate plus
/// the central error sets close the drift that motivated the finding.)
pub fn assertBackend(comptime B: type) void {
    comptime {
        std.debug.assert(required_methods.len == required_method_count);

        if (!@hasDecl(B, "WindowHandle"))
            @compileError(@typeName(B) ++ " is missing associated type WindowHandle");
        if (!@hasDecl(B, "WindowId"))
            @compileError(@typeName(B) ++ " is missing associated type WindowId");

        // v0.1.0 pins WindowId to u64 so the non-generic Callbacks.window_id
        // never truncates. v0.2 may widen this via an opaque encoding.
        if (B.WindowId != u64)
            @compileError(@typeName(B) ++ ".WindowId must be u64 in v0.1.0 (finding M11)");

        for (required_methods) |name| {
            if (!@hasDecl(B, name))
                @compileError(@typeName(B) ++ " is missing method: " ++ name);
            const field = @field(B, name);
            if (@typeInfo(@TypeOf(field)) != .@"fn")
                @compileError(@typeName(B) ++ "." ++ name ++ " is not a fn");
        }
    }
}

test "assertBackend accepts a conformant stub" {
    const Stub = struct {
        pub const WindowHandle = usize;
        pub const WindowId = u64;
        pub fn createWindow(_: *@This(), _: WindowOpts) CreateWindowError!WindowHandle {
            return 0;
        }
        pub fn destroyWindow(_: *@This(), _: WindowHandle) void {}
        pub fn setTitle(_: *@This(), _: WindowHandle, _: [:0]const u8) SetTitleError!void {}
        pub fn setSize(_: *@This(), _: WindowHandle, _: f64, _: f64) void {}
        pub fn setFullscreen(_: *@This(), _: WindowHandle, _: bool) void {}
        pub fn showWindow(_: *@This(), _: WindowHandle) void {}
        pub fn focusWindow(_: *@This(), _: WindowHandle) void {}
        pub fn evalJS(_: *@This(), _: WindowHandle, _: []const u8) void {}
        pub fn injectUserScript(_: *@This(), _: WindowHandle, _: []const u8) InjectScriptError!void {}
        pub fn windowId(_: *@This(), _: WindowHandle) WindowId {
            return 0;
        }
        pub fn dispatchMain(_: *@This(), _: *const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque) void {}
        pub fn dispatchMainAfter(_: *@This(), _: u32, _: *const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque) u64 {
            return 1;
        }
        pub fn cancelMainTimer(_: *@This(), _: u64) void {}
        pub fn pumpMain(_: *@This()) void {}
        pub fn run(_: *@This()) void {}
        pub fn terminate(_: *@This()) void {}
        pub fn nativeWindow(_: *@This(), _: WindowHandle) ?*anyopaque {
            return null;
        }
        pub fn setCallbacks(_: *@This(), _: Callbacks) void {}
        pub fn markJoined(_: *@This()) void {}
    };
    assertBackend(Stub); // compile-time; if it returns, the contract holds
}

test "assertBackend rejection path is verified out-of-band (see comment)" {
    // This stub mislabels createWindow as a constant. assertBackend MUST reject
    // it at comptime. We document the expectation; this is verified by hand
    // (uncomment locally to confirm the @compileError fires) because a failing
    // comptime check cannot live in a passing test body.
    //
    //   const Bad = struct {
    //       pub const WindowHandle = usize;
    //       pub const WindowId = u64;
    //       pub const createWindow = 42; // not a fn
    //       // ... rest as above ...
    //   };
    //   assertBackend(Bad); // expected: @compileError "createWindow is not a fn"
    try std.testing.expect(true);
}
