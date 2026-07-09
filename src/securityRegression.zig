//! Security regression bench.
//!
//! A dedicated, named suite of adversarial integration tests driving the whole
//! headless surface (App(NullBackend) / Bridge(NullBackend) over the real
//! jobs.zig worker pool). Every future B-H change runs against this bench. It
//! must pass under BOTH `zig build test` (Debug) and
//! `zig build test -Doptimize=ReleaseSafe`.
//!
//! No struct-scope `var` statics (M12). Every @memcpy asserts the destination
//! fits (M12). Manual fuzz drivers loop >= 10000 iterations seeded by
//! std.testing.random_seed because the native --fuzz corpus mode is broken on
//! 0.16 (H14).

const std = @import("std");
const seam = @import("platform/backend.zig");
const NullBackend = @import("platform/null.zig").NullBackend;
const App = @import("app.zig").App;
const Bridge = @import("bridge.zig").Bridge;
const builtin = @import("commands/builtin.zig");
const protocol = @import("protocol.zig");
const assets = @import("assets.zig");
const fixtures = @import("securityTestFixtures.zig");
const security_gates = @import("security/gates.zig");
const manifest_types = @import("manifest/types.zig");

const dummy_bases = security_gates.Bases{ .appdata = "/tmp", .home = "/tmp", .appconfig = "/tmp" };

// ─── Helpers ────────────────────────────────────────────────────────────────

/// Full App over the NullBackend: exercises the real onMessage -> bridge ->
/// pool -> evalJS path and the real shutdown handshake. `App.deinit` runs the
/// shutdown body (terminate, sentinel callbacks, join, markJoined, pump), so
/// the Harness deinit only has to deinit the App and then the backend.
const Harness = struct {
    backend: *NullBackend,
    app: *App(NullBackend),
    main_id: u64,

    fn init() !Harness {
        const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
        const grants = try fixtures.buildTestGrants(std.testing.allocator);
        // One "main" window with quit_on_last_close so the existing single-window
        // shutdown expectations hold (E's production default is keep-running).
        const windows = [_]manifest_types.Window{.{ .label = "main", .url = "app://localhost/index.html", .title = "Zigware", .show = true }};
        // fallback_ms = 0: no show-fallback timer. The fuzz driver builds a fresh
        // Harness per iteration (>=10000 of them); arming and cancelling a timer
        // per Harness is pointless work for tests that assert message-handling
        // safety, not window visibility, so skip it.
        const app = App(NullBackend).initWithConfig(struct {}, std.testing.allocator, std.testing.io, backend, grants, dummy_bases, std.Io.Dir.cwd(), false, true, &windows, .quit_on_last_close, 0) catch |err| {
            grants.deinit();
            std.testing.allocator.destroy(grants);
            return err;
        };
        const main_id = app.manager.lookup("main").?.window_id;
        return .{ .backend = backend, .app = app, .main_id = main_id };
    }
    fn settle(self: *Harness) void {
        self.app.bridge.drainForTest();
        self.backend.pumpMain();
    }
    fn deinit(self: *Harness) void {
        self.app.deinit(); // runs shutdown -> markJoined
        self.backend.deinit();
    }
};

/// Direct Bridge over the NullBackend (no App). The bridge-only path owns the
/// join handshake manually: bridge.deinit joins the pool, then the test calls
/// markJoined before backend.deinit (App.shutdown would do this in the full
/// path).
const TestBridge = struct {
    backend: *NullBackend,
    bridge: *Bridge(NullBackend),
    window_id: u64,
    state: *builtin.State,
    grants: *fixtures.GrantTable,

    fn init() !TestBridge {
        const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
        const win = try backend.createWindow(.{ .url = "app://localhost/index.html" });
        const state = try std.testing.allocator.create(builtin.State);
        state.* = .{};
        const grants = try fixtures.buildTestGrants(std.testing.allocator);
        const bridge = try Bridge(NullBackend).init(
            std.testing.allocator,
            std.testing.io,
            backend,
            win,
            builtin.State,
            builtin.Commands,
            state,
            .{ .worker_count = 4 }, // deterministic concurrency (L9)
            grants,
            dummy_bases,
            std.Io.Dir.cwd(),
            false,
        );
        return .{ .backend = backend, .bridge = bridge, .window_id = backend.windowId(win), .state = state, .grants = grants };
    }
    fn send(self: *TestBridge, text: []const u8) void {
        self.bridge.handleMessage(self.window_id, "app://localhost", text);
    }
    fn settle(self: *TestBridge) void {
        self.bridge.drainForTest();
        self.backend.pumpMain();
    }
    fn deinit(self: *TestBridge) void {
        self.bridge.deinit(); // joins workers
        self.grants.deinit();
        std.testing.allocator.destroy(self.grants);
        std.testing.allocator.destroy(self.state);
        self.backend.markJoined(); // bridge-only test owns the handshake
        self.backend.deinit();
    }
};

/// Parse the numeric id out of a `window.Zigware._resolve(ID, ...` or
/// `window.Zigware._reject(ID, ...` terminal emission. Returns null for anything
/// else (progress `_stream` calls, malformed entries), so a single pass over
/// eval_log can tally terminals without an O(n) substring scan per id.
fn terminalEmissionId(js: []const u8) ?u64 {
    const resolve = "window.Zigware._resolve(";
    const reject = "window.Zigware._reject(";
    const rest = if (std.mem.startsWith(u8, js, resolve))
        js[resolve.len..]
    else if (std.mem.startsWith(u8, js, reject))
        js[reject.len..]
    else
        return null;
    const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    return std.fmt.parseInt(u64, rest[0..comma], 10) catch null;
}

// ─── Attack vector 1: DoS via oversize / malformed megabytes ─────────────────

test "attack: gigabyte megabytes request is clamped to MAX_MEGABYTES" {
    var h = try Harness.init();
    defer h.deinit();
    h.backend.simulateMessage(h.main_id, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1073741824}}");
    h.settle();
    // Clamped to MAX_MEGABYTES (512), runs, resolves once. Not a panic, not OOM,
    // not a silent drop. The working-set budget (Bridge) bounds total memory.
    try std.testing.expect(h.backend.countResolveExactly(1) == 1);
}

test "attack: negative megabytes is a bad_args reject" {
    var h = try Harness.init();
    defer h.deinit();
    // The registry decodes sha256's `megabytes: u32` strictly: a negative value
    // fails decode and becomes a structured bad_args reject, not a default run.
    h.backend.simulateMessage(h.main_id, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":-1}}");
    h.settle();
    try std.testing.expect(h.backend.countRejectExactly(1) == 1);
    try std.testing.expect(h.backend.countContaining("\"code\":\"bad_args\"") >= 1);
}

test "attack: non-integer megabytes is a bad_args reject" {
    var h = try Harness.init();
    defer h.deinit();
    // A non-integer megabytes value fails the strict u32 decode -> bad_args.
    h.backend.simulateMessage(h.main_id, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":\"big\"}}");
    h.settle();
    try std.testing.expect(h.backend.countRejectExactly(1) == 1);
    try std.testing.expect(h.backend.countContaining("\"code\":\"bad_args\"") >= 1);
}

// ─── Attack vector 2: reserved-route exfil attempts ──────────────────────────
// Split into reserved (isReservedRoute == true) and boundary (== false) so a
// deleted isReservedRoute cannot leave the test green (H12).

test "attack: truly-reserved routes are flagged reserved AND 404 via App.onSchemeRequest" {
    var h = try Harness.init();
    defer h.deinit();
    const reserved = [_][]const u8{
        "/__zigware_stream",
        "/__zigware_stream/",
        "/__zigware_stream/anything",
    };
    for (reserved) |v| {
        try std.testing.expect(protocol.isReservedRoute(v));
        const r = h.backend.simulateSchemeRequest(v);
        try std.testing.expectEqual(@as(u16, 404), r.status);
    }
}

test "attack: boundary look-alike routes are NOT reserved AND still 404 (no asset match)" {
    var h = try Harness.init();
    defer h.deinit();
    const boundary = [_][]const u8{
        "/__zigware_streamattack",
        "/__zigware_streamABC/foo",
        "/__zigware_stream\x00/index.html",
    };
    for (boundary) |v| {
        try std.testing.expect(!protocol.isReservedRoute(v));
        const r = h.backend.simulateSchemeRequest(v);
        try std.testing.expectEqual(@as(u16, 404), r.status);
    }
}

// ─── Attack vector 3: malformed JSON does not crash or emit (no id present) ──

test "attack: malformed JSON inbound messages with no id drop silently" {
    var h = try Harness.init();
    defer h.deinit();
    const vectors = [_][]const u8{
        "",
        "}",
        "{",
        "null",
        "[]",
        "{\"cmd\":\"sha256\"}", // missing id
        "{\"id\":\"x\",\"cmd\":\"sha256\"}", // wrong id type, not scannable
    };
    for (vectors) |v| {
        h.backend.simulateMessage(h.main_id, "app://localhost", v);
    }
    h.settle();
    try std.testing.expectEqual(@as(usize, 0), h.backend.eval_log.items.len);
}

test "attack: malformed-but-has-numeric-id emits exactly one correlated reject (L1)" {
    var h = try Harness.init();
    defer h.deinit();
    // Decodable id, undecodable body: the bridge scans for the id and rejects.
    h.backend.simulateMessage(h.main_id, "app://localhost", "{\"id\":42,\"cmd\":");
    h.settle();
    try std.testing.expect(h.backend.countRejectExactly(42) == 1);
    try std.testing.expect(h.backend.countContaining("_resolve") == 0);
}

// ─── Attack vector 4: unknown command always rejects, never crashes ──────────

test "attack: unknown command names always reject with structured error" {
    var h = try Harness.init();
    defer h.deinit();
    const vectors = [_][]const u8{
        "{\"id\":1,\"cmd\":\"\",\"args\":{}}",
        "{\"id\":2,\"cmd\":\"shell:rm\",\"args\":{}}",
        "{\"id\":3,\"cmd\":\"../sha256\",\"args\":{}}",
        "{\"id\":4,\"cmd\":\"sha256\\u0000\",\"args\":{}}",
    };
    for (vectors) |v| {
        h.backend.simulateMessage(h.main_id, "app://localhost", v);
    }
    h.settle();
    try std.testing.expect(h.backend.countRejectExactly(1) == 1);
    try std.testing.expect(h.backend.countRejectExactly(2) == 1);
    try std.testing.expect(h.backend.countRejectExactly(3) == 1);
    try std.testing.expect(h.backend.countRejectExactly(4) == 1);
    try std.testing.expect(h.backend.countContaining("_resolve") == 0);
}

test "attack: Unicode-normalized cmd names are unknown commands (NFC vs NFD)" {
    var h = try Harness.init();
    defer h.deinit();
    // "sha256" is ASCII; a homoglyph / decomposed variant must NOT match the
    // ASCII allowlist entry. The allowlist compares bytes, so any non-ASCII
    // variant is rejected.
    const vectors = [_][]const u8{
        "{\"id\":1,\"cmd\":\"\\u0455ha256\",\"args\":{}}", // Cyrillic dze look-alike for 's'
        "{\"id\":2,\"cmd\":\"sha256\\u0301\",\"args\":{}}", // combining acute accent appended
        "{\"id\":3,\"cmd\":\"SHA256\",\"args\":{}}", // case variant, byte-distinct
    };
    for (vectors) |v| h.backend.simulateMessage(h.main_id, "app://localhost", v);
    h.settle();
    try std.testing.expect(h.backend.countRejectExactly(1) == 1);
    try std.testing.expect(h.backend.countRejectExactly(2) == 1);
    try std.testing.expect(h.backend.countRejectExactly(3) == 1);
    try std.testing.expect(h.backend.countContaining("_resolve") == 0);
}

// ─── Attack vector 5: extreme and overflowing ids ────────────────────────────

test "attack: maxInt ids and out-of-i64-range ids are handled, never panic" {
    var h = try Harness.init();
    defer h.deinit();
    // id = maxInt(u64) is not representable as a JSON i64; protocol.decode must
    // reject it cleanly (no panic, no resolve). id = maxInt(i64) is the largest
    // valid id and must round-trip to exactly one resolve.
    var buf: [128]u8 = undefined;
    const max_i64 = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":1}}}}", .{std.math.maxInt(i64)});
    h.backend.simulateMessage(h.main_id, "app://localhost", max_i64);
    // maxInt(u64) overflows i64; decode rejects or the id scan must not panic.
    h.backend.simulateMessage(h.main_id, "app://localhost", "{\"id\":18446744073709551615,\"cmd\":\"sha256\",\"args\":{}}");
    // maxInt(i64)+1 likewise out of range.
    h.backend.simulateMessage(h.main_id, "app://localhost", "{\"id\":9223372036854775808,\"cmd\":\"sha256\",\"args\":{}}");
    h.settle();
    try std.testing.expect(h.backend.countResolveExactly(std.math.maxInt(i64)) == 1);
    // The two out-of-range ids must not have produced a resolve.
    try std.testing.expect(h.backend.countResolveExactly(std.math.maxInt(u64)) == 0);
}

// ─── Attack vector 6: post-terminate inbound is a no-op ──────────────────────

test "attack: post-terminate flood produces no emissions" {
    var h = try Harness.init();
    defer h.deinit();
    h.backend.simulateLifecycle(.window_all_closed); // App.shutdown path sets terminate
    // App.shutdown() calls bridge.deinit() which frees the bridge and the pool.
    // h.settle() would UAF through the freed bridge pointer. Use pumpMain directly:
    // the backend is still alive and pumpMain with terminated=true drops anything
    // pending. This mirrors app.zig's "L10" test which avoids drainForTest after
    // shutdown for the same reason.
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        var buf: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":1}}}}", .{i});
        h.backend.simulateMessage(h.main_id, "app://localhost", text);
    }
    h.backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 0), h.backend.eval_log.items.len);
}

test "attack: simulate* after app.deinit never reaches the freed App (fail-closed cb)" {
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer backend.deinit();
    const app = try App(NullBackend).init(std.testing.allocator, std.testing.io, backend);
    const main_id = app.manager.lookup("main").?.window_id;
    app.deinit(); // runs App.shutdown: installs the fail-closed sentinel callbacks + markJoined
    // After shutdown, backend.terminated is set, so simulate* short-circuit; even
    // if they did not, the fail-closed sentinel returns 404 / no-op and never
    // touches the freed App. No crash, no callback into freed memory.
    backend.simulateMessage(main_id, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{}}");
    const r = backend.simulateSchemeRequest("/index.html");
    try std.testing.expectEqual(@as(u16, 404), r.status);
    const nav = backend.simulateNavigation("app://localhost/index.html");
    try std.testing.expectEqual(seam.NavigationDecision.cancel, nav);
}

// ─── Attack vector 7: navigation policy is deny-by-default (M6) ──────────────

test "attack: evil https navigation is cancelled; app scheme is allowed" {
    var h = try Harness.init();
    defer h.deinit();
    try std.testing.expectEqual(seam.NavigationDecision.cancel, h.backend.simulateNavigation("https://evil.example/"));
    try std.testing.expectEqual(seam.NavigationDecision.cancel, h.backend.simulateNavigation("javascript:alert(1)"));
    try std.testing.expectEqual(seam.NavigationDecision.cancel, h.backend.simulateNavigation("file:///etc/passwd"));
    try std.testing.expectEqual(seam.NavigationDecision.allow, h.backend.simulateNavigation("app://localhost/index.html"));
}

// ─── Attack vector 8: stream_scheme source is 404 at the seam (M7) ───────────

test "attack: a stream_scheme request returns 404 from A's onSchemeRequest" {
    var h = try Harness.init();
    defer h.deinit();
    const r = h.backend.simulateSchemeRequestSource(.stream_scheme, "/index.html");
    try std.testing.expectEqual(@as(u16, 404), r.status);
    // The same path via the asset scheme resolves to 200 (sanity).
    const ok = h.backend.simulateSchemeRequestSource(.asset_scheme, "/index.html");
    try std.testing.expectEqual(@as(u16, 200), ok.status);
}

// ─── Attack vector 9: NUL-in-user-script is rejected, no truncation ──────────

test "attack: user_script containing NUL is rejected, no partial inject" {
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer backend.deinit();
    backend.markJoined();
    const opts = seam.WindowOpts{
        .url = "app://localhost/index.html",
        .user_scripts = &.{"window.x = 1;\x00window.y = 2;"},
    };
    try std.testing.expectError(error.ScriptContainsNul, backend.createWindow(opts));
    try std.testing.expectEqual(@as(usize, 0), backend.injected_scripts.items.len);
    try std.testing.expectEqual(@as(usize, 0), backend.windows.items.len);
}

test "attack: late injectUserScript with NUL is rejected, no partial inject" {
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer backend.deinit();
    backend.markJoined();
    const h = try backend.createWindow(.{ .url = "app://localhost/index.html" });
    const before = backend.injected_scripts.items.len;
    try std.testing.expectError(error.ScriptContainsNul, backend.injectUserScript(h, "ok();\x00evil();"));
    try std.testing.expectEqual(before, backend.injected_scripts.items.len);
}

// ─── Attack vector 10: JSON depth bomb is rejected without crash (H2) ────────

test "attack: deeply nested JSON object/array is rejected, never blows the stack" {
    var h = try Harness.init();
    defer h.deinit();
    // Build a 200-level nested args array. The decode depth/nesting pre-scan
    // (max 32) rejects it; no resolve, no crash, no stack overflow.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"id\":1,\"cmd\":\"sha256\",\"args\":");
    var d: usize = 0;
    while (d < 200) : (d += 1) try buf.append(std.testing.allocator, '[');
    while (d > 0) : (d -= 1) try buf.append(std.testing.allocator, ']');
    try buf.append(std.testing.allocator, '}');
    h.backend.simulateMessage(h.main_id, "app://localhost", buf.items);
    h.settle();
    try std.testing.expect(h.backend.countContaining("_resolve") == 0);
}

// ─── Attack vector 11: 100 MB string field is bounded and rejected (H2/M13) ──

test "attack: a 100 MB string args field is bounded by max_value_len, rejected" {
    var h = try Harness.init();
    defer h.deinit();
    // A single 100 MB string in args. max_value_len = 4096 in decode's
    // ParseOptions rejects the value before it is materialized; the message
    // size cap (MAX_MESSAGE_LEN = 64 KiB) rejects it even earlier. Either way:
    // one reject for the scannable id, no 100 MB allocation.
    const big_len = 100 * 1024 * 1024;
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(std.testing.allocator);
    try msg.appendSlice(std.testing.allocator, "{\"id\":7,\"cmd\":\"sha256\",\"args\":{\"x\":\"");
    try msg.appendNTimes(std.testing.allocator, 'A', big_len);
    try msg.appendSlice(std.testing.allocator, "\"}}");
    h.backend.simulateMessage(h.main_id, "app://localhost", msg.items);
    h.settle();
    try std.testing.expect(h.backend.countContaining("_resolve") == 0);
    try std.testing.expect(h.backend.countRejectExactly(7) == 1);
}

// ─── Attack vector 12: oversize asset path falls through cleanly ────────────

test "attack: oversize asset path returns 404, no panic" {
    const long_path = "/" ++ "a" ** 8000;
    const r = assets.serveAsset(long_path);
    try std.testing.expectEqual(@as(u16, 404), r.status);
}

// ─── Attack vector 13: shutdown idempotency under hostile timing ────────────

test "attack: terminate then will_terminate then deinit is safe (exactly-once shutdown)" {
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    const app = try App(NullBackend).init(std.testing.allocator, std.testing.io, backend);
    defer backend.deinit();
    backend.simulateLifecycle(.window_all_closed); // App.shutdown (swap acq_rel guard) + markJoined
    backend.simulateLifecycle(.will_terminate); // shutdown_done already true: no-op
    app.deinit(); // shutdown_done already true: no-op, then frees the App
    // No panic, no double-free, no double-join. testing.allocator catches leaks.
}

// ─── Attack vector 14: real concurrency on the backend (H11) ─────────────────

test "NullBackend.evalJS is safe under 8-thread contention with interleaved pump and terminate" {
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer backend.deinit();
    const h = try backend.createWindow(.{ .url = "app://localhost/index.html" });

    const Worker = struct {
        b: *NullBackend,
        hnd: NullBackend.WindowHandle,
        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) self.b.evalJS(self.hnd, "x()");
        }
    };
    var workers: [8]Worker = undefined;
    var threads: [8]std.Thread = undefined;
    for (&workers, 0..) |*w, idx| {
        w.* = .{ .b = backend, .hnd = h };
        threads[idx] = try std.Thread.spawn(.{}, Worker.run, .{w});
    }
    // Main interleaves pumps and exactly one terminate while workers run.
    var pumps: usize = 0;
    while (pumps < 50) : (pumps += 1) {
        backend.pumpMain();
        if (pumps == 25) backend.terminate();
    }
    for (threads) |t| t.join();
    backend.pumpMain(); // final drain

    // Every one of the 8000 enqueued evals is either delivered (in eval_log) or
    // dropped (post-terminate or OOM). Accounting: delivered + dropped == 8000,
    // and the pending queue is empty after the final pump.
    const delivered = backend.eval_log.items.len;
    const dropped = backend.dropCount(); // post-terminate drops + eval_drops
    try std.testing.expectEqual(@as(usize, 8000), delivered + dropped);
    try std.testing.expectEqual(@as(usize, 0), backend.pending.items.len);

    backend.markJoined(); // pool-free backend; satisfy deinit's joined assert
}

// ─── Attack vector 15: Bridge.deinit while a worker is mid-emit (H11) ────────

test "Bridge.deinit while workers are mid-flight does not UAF" {
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    const win = try backend.createWindow(.{ .url = "app://localhost/index.html" });
    var state = builtin.State{};
    const grants = try fixtures.buildTestGrants(std.testing.allocator);
    const bridge = try Bridge(NullBackend).init(std.testing.allocator, std.testing.io, backend, win, builtin.State, builtin.Commands, &state, .{ .worker_count = 4 }, grants, dummy_bases, std.Io.Dir.cwd(), false);
    // Submit jobs with NO settle, then deinit immediately. bridge.deinit joins
    // the pool; backend.deinit then drains and frees. No UAF, no leak. The
    // UAF-safety property is independent of per-job size, so use the smallest
    // size (1 MB) that still puts workers mid-flight without hashing gigabytes.
    var i: u64 = 1;
    while (i <= 16) : (i += 1) {
        var buf: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":1}}}}", .{i});
        bridge.handleMessage(0, "app://localhost", text);
    }
    bridge.deinit(); // joins workers (does NOT call markJoined)
    grants.deinit();
    std.testing.allocator.destroy(grants);
    backend.pumpMain(); // drain hops the joined workers enqueued
    backend.markJoined(); // direct-bridge test owns the handshake (App.shutdown would do this)
    backend.deinit();
}

// ─── Attack vector 16: FailingAllocator OOM at each trust boundary (H11) ─────
// fail_index is an ALLOCATION ORDINAL (count of alloc calls), NOT a byte count
// (B2). Sweep the ordinal over a small range so a different allocation faults
// on each iteration; the backend must stay consistent every time.

test "OOM: createWindow at the Nth user-script dupe frees cleanly, no leak, no double-free" {
    var fail_at: usize = 0;
    while (fail_at < 12) : (fail_at += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_at });
        const a = fa.allocator();
        const backend = NullBackend.init(a, std.testing.io) catch continue;
        defer {
            backend.markJoined();
            backend.deinit();
        }
        _ = backend.createWindow(.{
            .url = "app://localhost/index.html",
            .user_scripts = &.{ "a();", "b();", "c();" },
        }) catch {
            // Expected on the failing index: no leak (FailingAllocator + testing
            // allocator assert), no double-free, no partial window committed.
            try std.testing.expectEqual(@as(usize, 0), backend.windows.items.len);
            continue;
        };
    }
}

test "OOM: pumpMain reservation failure leaves pending intact, no double-free" {
    var fail_at: usize = 0;
    while (fail_at < 16) : (fail_at += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_at });
        const a = fa.allocator();
        const backend = NullBackend.init(a, std.testing.io) catch continue;
        defer {
            backend.markJoined();
            backend.deinit();
        }
        const h = backend.createWindow(.{ .url = "app://localhost/index.html" }) catch continue;
        backend.evalJS(h, "x()");
        backend.pumpMain(); // may hit the reservation OOM depending on fail_at
        // Invariant on every iteration: the one queued eval is either still
        // pending (reservation OOM) or delivered, never lost or double-freed.
        try std.testing.expect(backend.pending.items.len + backend.eval_log.items.len <= 1);
    }
}

test "OOM: handleMessage JSON parse failure emits nothing and leaks nothing" {
    // The bound 24 must stay ABOVE the decode-allocation window. Construction
    // (NullBackend.init + createWindow + buildTestGrants + Bridge.init) consumes
    // the first ~10 ordinals; handleMessage's decode allocates ordinals ~10..17.
    // 24 spans that with headroom. If you GROW construction (e.g. add a field that
    // allocates in Bridge/App init), bump this bound so the decode-OOM path stays
    // covered (otherwise coverage silently regresses to construction-only OOM).
    var fail_at: usize = 0;
    while (fail_at < 24) : (fail_at += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_at });
        const a = fa.allocator();
        const backend = NullBackend.init(a, std.testing.io) catch continue;
        const win = backend.createWindow(.{ .url = "app://localhost/index.html" }) catch {
            backend.markJoined();
            backend.deinit();
            continue;
        };
        var state = builtin.State{};
        // The grants build on the SAME failing allocator: a compile-OOM is just
        // another injected-OOM path, handled like the init failure below (continue).
        const grants = fixtures.buildTestGrants(a) catch {
            backend.markJoined();
            backend.deinit();
            continue;
        };
        const bridge = Bridge(NullBackend).init(a, std.testing.io, backend, win, builtin.State, builtin.Commands, &state, .{ .worker_count = 2 }, grants, dummy_bases, std.Io.Dir.cwd(), false) catch {
            grants.deinit();
            a.destroy(grants);
            backend.markJoined();
            backend.deinit();
            continue;
        };
        defer {
            bridge.deinit();
            grants.deinit();
            a.destroy(grants);
            backend.markJoined();
            backend.pumpMain();
            backend.deinit();
        }
        // megabytes:1 keeps the (possibly successful) hash tiny: the property
        // here is "OOM during decode drops or fixed-buffer rejects, no leak, no
        // crash", which is independent of per-job size.
        bridge.handleMessage(0, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
        bridge.drainForTest();
        backend.pumpMain();
        // OOM during decode => drop or fixed-buffer reject (H5). No leak, no crash.
    }
}

// ─── Attack vector 17: working-set memory ceiling under flood (I2/H11) ───────

test "I2: a 1000-message flood stays within a bounded transient budget (concurrency-capped)" {
    const N: u64 = 1000;
    var dbg = std.heap.DebugAllocator(.{ .thread_safe = true, .enable_memory_limit = true }){};
    // The concurrency-count cap (MAX_CONCURRENT = 8), not a byte budget, bounds
    // peak. This test goes through App.init, which uses workerCount() = up to 8
    // workers, so with megabytes:8 peak ~= min(workers, MAX_CONCURRENT) * 8 MiB
    // ~= 64 MiB worst case on an >=8-core host. A 128 MiB ceiling gives 2x
    // headroom over that peak: it still proves the heap does not run away under
    // the flood (the unbounded-queue failure mode the cap prevents) while
    // leaving room for the recorded emission log so the gate sheds load rather
    // than the allocator spuriously failing terminal emissions under parallel
    // test load.
    dbg.requested_memory_limit = 128 * 1024 * 1024; // runtime field; flag is enable_memory_limit (B2)
    defer std.debug.assert(dbg.deinit() == .ok);
    const a = dbg.allocator();
    const backend = try NullBackend.init(a, std.testing.io);
    // Grant sha256 so the flood reaches reserveCall and the G5 count-cap sheds the
    // excess as "busy" (core:default would deny every sha256 at G2 before G5).
    // Build on `a` so the App (owns_grants=true) frees them with the same allocator.
    const grants = try fixtures.buildTestGrants(a);
    const windows = [_]manifest_types.Window{.{ .label = "main", .url = "app://localhost/index.html", .title = "Zigware", .show = true }};
    const app = App(NullBackend).initWithConfig(struct {}, a, std.testing.io, backend, grants, dummy_bases, std.Io.Dir.cwd(), false, true, &windows, .quit_on_last_close, 5000) catch |err| {
        grants.deinit();
        a.destroy(grants);
        return err;
    };
    const main_id = app.manager.lookup("main").?.window_id;
    defer {
        app.deinit();
        backend.deinit();
    }
    var i: u64 = 1;
    while (i <= N) : (i += 1) {
        var buf: [160]u8 = undefined;
        // Each asks for 8 MB. The count cap admits at most MAX_CONCURRENT = 8
        // concurrent calls, so the gate sheds the vast majority of the flood as
        // "server busy" rejects WITHOUT ever hashing them (mirrors bridge.zig's
        // I2 vector). The property under test ("every id gets exactly one
        // terminal emission and the heap stays under the DebugAllocator ceiling
        // under a flood that trips the cap") is independent of per-job size.
        const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":8}}}}", .{i});
        backend.simulateMessage(main_id, "app://localhost", text);
    }
    app.bridge.drainForTest();
    backend.pumpMain();
    // The concurrency cap must have tripped: a large fraction of the
    // flood is shed as "server busy" without hashing, so the gate path is
    // covered (not just queued and resolved).
    try std.testing.expect(backend.countContaining("busy") > 0);
    // Every id received exactly one terminal emission (resolve OR busy-reject).
    // Tally in a single O(n) pass: parse each emission's id and bump its slot,
    // instead of scanning the whole log once per id. The old per-id scan was
    // O(n^2) over the emission log (terminals plus progress _emit) and made this
    // test dominate the suite's runtime.
    const counts = try a.alloc(u8, N + 1);
    defer a.free(counts);
    @memset(counts, 0);
    for (backend.eval_log.items) |e| {
        const id = terminalEmissionId(e.js) orelse continue;
        if (id >= 1 and id <= N and counts[id] < 255) counts[id] += 1;
    }
    i = 1;
    while (i <= N) : (i += 1) {
        try std.testing.expectEqual(@as(u8, 1), counts[i]);
    }
}

// ─── Attack vector 18: deterministic delivery-gate interleaving (M13) ─────────
// NullBackend's explicit pumpMain IS the deterministic stepping mechanism:
// evalJS from a worker lands in `pending`, and nothing reaches `eval_log` until
// the test calls pumpMain. So a test can script the exact race: drain the pool
// (workers finish, emissions queue in pending), then choose to deliver
// (pumpMain) or terminate-then-pump (drop).

test "M13: pumpMain is the sole delivery gate; terminate before it drops every queued emission" {
    // Phase 1: drain then pump delivers every id exactly once.
    {
        var t = try TestBridge.init();
        defer t.deinit();
        var i: u64 = 1;
        while (i <= 20) : (i += 1) {
            var buf: [128]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":1}}}}", .{i});
            t.send(text);
        }
        t.bridge.drainForTest(); // workers finish; emissions sit in pending
        t.backend.pumpMain(); // the delivery gate
        i = 1;
        while (i <= 20) : (i += 1) {
            try std.testing.expect(t.backend.countResolveExactly(i) + t.backend.countRejectExactly(i) == 1);
        }
    }
    // Phase 2: same flood, but terminate before the pump drops everything.
    {
        var t = try TestBridge.init();
        defer t.deinit();
        var i: u64 = 1;
        while (i <= 20) : (i += 1) {
            var buf: [128]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":1}}}}", .{i});
            t.send(text);
        }
        t.bridge.drainForTest(); // emissions queued in pending
        t.backend.terminate(); // flip the gate closed
        t.backend.pumpMain(); // drops, does not deliver
        try std.testing.expectEqual(@as(usize, 0), t.backend.eval_log.items.len);
        try std.testing.expect(t.backend.post_terminate_drops >= 20);
    }
}

// ─── Attack vector 19: jsString / writeJsonAsJsLiteral fuzz, manual driver ───
// (H14/M13) The manual driver runs >= 10000 iterations and then replays the
// committed corpus. jsString and writeJsonAsJsLiteral are pub in protocol.zig.

test "fuzz: jsString output is a safe JS string literal for any input (manual driver)" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        var buf: [512]u8 = undefined;
        const n = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..n]);
        try checkJsString(buf[0..n]);
    }
    // Also replay the committed corpus.
    try replayCorpusDir("test/fuzz/corpus", checkJsString);
}

test "fuzz: writeJsonAsJsLiteral output never leaks a literal LS/PS (manual driver)" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed +% 1);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        var buf: [512]u8 = undefined;
        const n = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..n]);
        try checkJsonAsJsLiteral(buf[0..n]);
    }
    try replayCorpusDir("test/fuzz/corpus", checkJsonAsJsLiteral);
}

/// jsString is THE injection boundary: for ANY input bytes, the emitted literal
/// (between its delimiter quotes) must contain no byte that could break out of a
/// `<script>` string position. Concretely: no raw `</script`, no raw newline /
/// carriage return, and no raw LS/PS (U+2028/U+2029) byte sequence. The opening
/// and closing delimiter quotes are the only `"` allowed.
fn checkJsString(input: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    protocol.jsString(&aw.writer, input) catch return; // OOM is acceptable
    const out = aw.writer.buffered();
    // Always wrapped in delimiter quotes.
    try std.testing.expect(out.len >= 2);
    try std.testing.expect(out[0] == '"' and out[out.len - 1] == '"');
    const inner = out[1 .. out.len - 1];
    // No unescaped `</script`, no raw control/newline, no raw LS/PS.
    try std.testing.expect(std.mem.indexOf(u8, inner, "</script") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, inner, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, inner, '\r') == null);
    try std.testing.expect(std.mem.indexOf(u8, inner, "\xe2\x80\xa8") == null);
    try std.testing.expect(std.mem.indexOf(u8, inner, "\xe2\x80\xa9") == null);
    // The `/` in `</script` is escaped to `\/`, so a closing `</script>` can
    // never appear verbatim; the indexOf above is the load-bearing check.
}

/// writeJsonAsJsLiteral passes pre-validated JSON through, escaping only the
/// LS/PS code points that are valid JSON yet terminate a JS string literal. The
/// structural invariant for ANY input: the output contains no raw U+2028/U+2029
/// byte sequence (they are rewritten to   /  ). It does not own the
/// `</script>` boundary (that is jsString's job for raw bytes), so only the
/// LS/PS invariant is asserted here.
fn checkJsonAsJsLiteral(input: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    protocol.writeJsonAsJsLiteral(&aw.writer, input) catch return; // OOM/overflow is fine
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\xe2\x80\xa8") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\xe2\x80\xa9") == null);
}

/// Replay every file under `dir` through `check`. A missing dir is not an error
/// (corpus is optional at the call site; CI commits it). The cwd at test time is
/// the project root under `zig build test`; under kcov the binary may run from a
/// different cwd, in which case the open fails and is skipped harmlessly.
///
/// 0.16 filesystem API: std.Io.Dir.cwd() + io-taking openDir/iterate/readFile
/// (std.fs.cwd() does not exist on this toolchain).
fn replayCorpusDir(dir: []const u8, comptime check: fn ([]const u8) anyerror!void) !void {
    const io = std.testing.io;
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const data = d.readFileAlloc(io, entry.name, std.testing.allocator, std.Io.Limit.limited(1 << 20)) catch continue;
        defer std.testing.allocator.free(data);
        try check(data);
    }
}

// ─── Attack vector 20: handleMessage triple fuzz, manual driver (H14) ────────

test "fuzz: handleMessage triple-input never panics or emits to a dead webview (manual driver)" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed +% 2);
    const rand = prng.random();
    // A single Harness reused across iterations would accumulate eval_log/inflight
    // state and slow each pass; a fresh Harness per iteration is the cleaner
    // oracle for "no panic, no UAF" and keeps every iteration independent.
    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        var h = try Harness.init();
        defer h.deinit();
        const window_id: u64 = rand.int(u64);
        var origin_buf: [256]u8 = undefined;
        const origin_len = rand.intRangeAtMost(usize, 0, origin_buf.len);
        rand.bytes(origin_buf[0..origin_len]);
        var text_buf: [4096]u8 = undefined;
        const text_len = rand.intRangeAtMost(usize, 0, text_buf.len);
        rand.bytes(text_buf[0..text_len]);
        h.app.bridge.handleMessage(window_id, origin_buf[0..origin_len], text_buf[0..text_len]);
        h.settle();
    }
}

// ─── Attack vector 21: G6 over the typed-arg result, stream, and error paths ──
// echo (builtin) drives attacker-controlled bytes through the resolve channel,
// the stream frame, and (when fail is set) the reject channel. Every emitted
// frame must be a structurally safe JS literal: no raw </script>, no raw LS/PS.

const HOSTILE = "</script><script>alert(1)</script>\u{2028}\u{2029}\"'\\";

test "G6: a hostile string resolves to a structurally safe literal" {
    var t = try TestBridge.init();
    defer t.deinit();
    // Send the hostile string as a JSON-escaped arg.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"id\":1,\"cmd\":\"echo\",\"args\":{\"s\":");
    try protocol.jsString(&aw.writer, HOSTILE);
    try aw.writer.writeAll("}}");
    t.send(aw.writer.buffered());
    t.settle();
    // The stream frame AND the resolve must have been emitted (so the scan below
    // is not vacuous): one _stream + one _resolve.
    try std.testing.expect(t.backend.eval_log.items.len >= 2);
    // The resolve/stream payload travels the Stringify + writeJsonAsJsLiteral
    // channel. That channel's breakout invariant (protocol.zig: writeJsonAsJsLiteral)
    // is "no raw LS/PS": those terminate a JS string literal. It deliberately does
    // NOT escape `/` (the resolve JS is delivered via WKWebView evaluateJavaScript,
    // a direct JS-eval context where `</script>` inside a string literal is inert,
    // not HTML-embedded). So assert the real breakout invariant on every frame:
    // no raw LS/PS.
    for (t.backend.eval_log.items) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.js, "\u{2028}") == null);
        try std.testing.expect(std.mem.indexOf(u8, e.js, "\u{2029}") == null);
    }
    // And prove faithful, inert delivery (not silent loss/corruption): the resolve
    // frame's payload round-trips back to the hostile string byte-for-byte.
    var seen_resolve = false;
    for (t.backend.eval_log.items) |e| {
        const prefix = "window.Zigware._resolve(1, ";
        if (!std.mem.startsWith(u8, e.js, prefix)) continue;
        seen_resolve = true;
        const json = e.js[prefix.len .. e.js.len - 2]; // strip trailing ");"
        const Parsed = struct { s: []const u8 };
        var parsed = try std.json.parseFromSlice(Parsed, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(HOSTILE, parsed.value.s);
    }
    try std.testing.expect(seen_resolve);
}

test "G6: a hostile error message is escaped on the reject channel" {
    var t = try TestBridge.init();
    defer t.deinit();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"id\":1,\"cmd\":\"echo\",\"args\":{\"s\":");
    try protocol.jsString(&aw.writer, HOSTILE);
    try aw.writer.writeAll(",\"fail\":true}}");
    t.send(aw.writer.buffered());
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(1));
    // No raw LS/PS on ANY frame (the universal string-literal breakout invariant).
    for (t.backend.eval_log.items) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.js, "\u{2028}") == null);
        try std.testing.expect(std.mem.indexOf(u8, e.js, "\u{2029}") == null);
    }
    // The error `code`/`message` cross via encodeErrorReject's jsString channel,
    // which DOES escape `/` to neutralise `</script>`. Assert that on the _reject
    // frame, where the strong invariant genuinely holds.
    for (t.backend.eval_log.items) |e| {
        if (!std.mem.startsWith(u8, e.js, "window.Zigware._reject(")) continue;
        try std.testing.expect(std.mem.indexOf(u8, e.js, "</script>") == null);
    }
}

test "G6: a hostile mime string is escaped in the _bin frame" {
    // echoBytes uses a fixed mime; this pins encodeBinReady's jsString path
    // directly so a future variable-mime command cannot inject.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try protocol.encodeBinReady(&aw.writer, 1, 0, 4, "x\"</script>");
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "</script>") == null);
}

// ─── Attack vector 22: per-id binary budget overflow is a queue_full reject ───

test "G5: exceeding the per-id binary budget yields a queue_full-class reject" {
    // A command that parks more than BIN_BUDGET_PER_ID must reject. Drive it via
    // an oversized echoBytes (n > 16 MiB). The bench uses std.testing.allocator
    // (no memory limit), so the 20 MB transient arena alloc succeeds and the
    // parkBinary budget check (16 MiB) is what rejects.
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":1,\"cmd\":\"echoBytes\",\"args\":{\"n\":20000000}}"); // 20 MB > 16 MiB budget
    t.settle();
    // The park fails, so the command rejects rather than resolving with bytes.
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(1));
    try std.testing.expect(t.backend.countContaining("\"code\":\"queue_full\"") >= 1);
}

// ─── Attack vector 23: cancel/shutdown ordering for streaming commands ────────

test "shutdown: an in-flight streaming command after terminate drops all further frames" {
    var t = try TestBridge.init();
    t.backend.terminate();
    t.send("{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":4}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 0), t.backend.eval_log.items.len);
    t.deinit();
}

// ─── Attack vector 24: args_json typed-decode fuzz, manual driver (H14) ───────
// The existing handleMessage fuzz feeds raw text. This driver builds VALID-JSON
// args objects from a corpus of well-formed JSON value tokens so the envelope
// always passes decode() and parseFromSliceLeaky(ArgsT, ...) is exercised on
// every iteration. Most iterations hit the bad_args reject path (type mismatch,
// out-of-range, extra field); a few run cheaply. The decode must never trap.

test "fuzz: typed args_json decode for registered commands never traps (manual >= 10000)" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed ^ 0xB17E);
    const rand = prng.random();
    var t = try TestBridge.init();
    defer t.deinit();
    const cmds = [_][]const u8{ "sha256", "echoBytes", "echo" };
    // Field names spanning the three command shapes + an unknown, and a corpus
    // of well-formed JSON value tokens (type-mismatched, boundary, and a few
    // small-valid) so the envelope is ALWAYS valid JSON and the typed decoder runs.
    const fields = [_][]const u8{ "megabytes", "n", "s", "fail", "x" };
    const values = [_][]const u8{
        "0",          "1",                    "2",    "256",   "-1",            "true",        "false", "null", "3.14",
        "4294967296", "18446744073709551615", "\"\"", "\"x\"", "\"</script>\"", "\"\\u2028\"", "[]",    "{}",   "[1,2,3]",
        "{\"k\":1}",
    };
    var it: usize = 0;
    while (it < 10_000) : (it += 1) {
        const cmd = cmds[rand.uintLessThan(usize, cmds.len)];
        const f1 = fields[rand.uintLessThan(usize, fields.len)];
        const v1 = values[rand.uintLessThan(usize, values.len)];
        var msg: [256]u8 = undefined;
        // Sometimes one field, sometimes two, sometimes empty {}; all valid JSON.
        const text = switch (rand.uintLessThan(u8, 3)) {
            0 => std.fmt.bufPrint(&msg, "{{\"id\":{d},\"cmd\":\"{s}\",\"args\":{{}}}}", .{ it, cmd }) catch continue,
            1 => std.fmt.bufPrint(&msg, "{{\"id\":{d},\"cmd\":\"{s}\",\"args\":{{\"{s}\":{s}}}}}", .{ it, cmd, f1, v1 }) catch continue,
            else => blk: {
                const f2 = fields[rand.uintLessThan(usize, fields.len)];
                const v2 = values[rand.uintLessThan(usize, values.len)];
                break :blk std.fmt.bufPrint(&msg, "{{\"id\":{d},\"cmd\":\"{s}\",\"args\":{{\"{s}\":{s},\"{s}\":{s}}}}}", .{ it, cmd, f1, v1, f2, v2 }) catch continue;
            },
        };
        t.bridge.handleMessage(t.window_id, "app://localhost", text);
        if (it % 256 == 0) t.settle(); // drain periodically so the pool/budget never backs up
    }
    t.settle();
}

// ─── Attack vector 25: live gate integration over App(NullBackend) ────────────
// These tests exercise the G1/G2 gate codes through the full App path.

test "live gate: a foreign origin is denied with origin.untrusted" {
    // The granting Harness grants sha256, so a good-origin send would resolve.
    // Using a foreign origin verifies G1 fires before G2 (sha256 would pass G2).
    var h = try Harness.init();
    defer h.deinit();
    h.backend.simulateMessage(h.main_id, "https://evil.example", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    h.settle();
    try std.testing.expect(h.backend.countRejectExactly(1) == 1);
    try std.testing.expect(h.backend.countContaining("\"code\":\"origin.untrusted\"") >= 1);
}

test "live gate: an ungranted command is denied with command.not_granted" {
    // App.init grants only core:default (window.setTitle, dialog.open,
    // compute.cancel). sha256 is on the G3 allowlist (registered builtin) but
    // NOT in core:default, so it reaches G2 and is denied there.
    const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
    defer backend.deinit();
    const app = try App(NullBackend).init(std.testing.allocator, std.testing.io, backend);
    const main_id = app.manager.lookup("main").?.window_id;
    backend.simulateMessage(main_id, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    app.bridge.drainForTest();
    backend.pumpMain();
    try std.testing.expect(backend.countRejectExactly(1) == 1);
    try std.testing.expect(backend.countContaining("\"code\":\"command.not_granted\"") >= 1);
    app.deinit();
}

test "live gate: a granted command from app://localhost resolves" {
    // Harness uses the granting table (sha256 granted), app://localhost is trusted.
    var h = try Harness.init();
    defer h.deinit();
    h.backend.simulateMessage(h.main_id, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    h.settle();
    try std.testing.expect(h.backend.countResolveExactly(1) == 1);
}

test "live gate: navigation to a foreign origin returns cancel" {
    var h = try Harness.init();
    defer h.deinit();
    try std.testing.expectEqual(seam.NavigationDecision.cancel, h.backend.simulateNavigation("https://evil.example/"));
    try std.testing.expectEqual(seam.NavigationDecision.cancel, h.backend.simulateNavigation("javascript:alert(1)"));
}

test "live gate: navigation to app://localhost returns allow" {
    var h = try Harness.init();
    defer h.deinit();
    try std.testing.expectEqual(seam.NavigationDecision.allow, h.backend.simulateNavigation("app://localhost/index.html"));
    try std.testing.expectEqual(seam.NavigationDecision.allow, h.backend.simulateNavigation("app://localhost"));
}
