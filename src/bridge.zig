const std = @import("std");
const protocol = @import("protocol.zig");
const Allowlist = @import("allowlist.zig").Allowlist;
const jobs = @import("jobs.zig");
const backend_mod = @import("platform/backend.zig");
const ctxmod = @import("command_ctx.zig");
const registry = @import("registry.zig");

pub const BridgeOptions = struct {
    /// Explicit worker count so tests are deterministic across CI hardware.
    /// main.zig passes null to use the CPU-derived default.
    worker_count: ?usize = null,
    max_queue: usize = 256,
};

/// G5: max concurrently in-flight calls. Bounds peak arena memory together with
/// the bounded worker pool. A resource-aware per-command budget (from D's
/// manifest) is deferred to D. B counts calls, not bytes (deviation 6).
const MAX_CONCURRENT: usize = 8;

/// Per-id parked binary, pulled out-of-band over the stream scheme. Bounded by a
/// fixed byte budget per id; overflow is rejected at park time (G5). Eviction is
/// serve-or-teardown, never on settle (deviation 9): the webview pulls bytes
/// after the invoke settles, so freeing on settle would 404 every pull.
const BIN_BUDGET_PER_ID: usize = 16 * 1024 * 1024;

const BinEntry = struct { seq: u32, bytes: []u8, served: bool = false };
const BinRing = struct {
    entries: std.ArrayList(BinEntry) = .empty,
    total: usize = 0,
    settled: bool = false,
};

/// Bridge over a platform backend `B`, routing inbound messages to commands
/// registered in `Reg = Commands(B, State, UserCommands)`. `Bridge(B)` stays
/// generic over `B` only: the registry and `*State` are erased behind a captured
/// `dispatchFn` and `state_ptr` so A's call sites that name `Bridge(NullBackend)`
/// keep compiling.
///
/// Lifecycle contract: `deinit` is INFALLIBLE. It joins the worker pool and
/// frees state and cannot fail. Any future fallible cleanup MUST go through a
/// separate `flush()` called before deinit, never folded into deinit.
pub fn Bridge(comptime B: type) type {
    backend_mod.assertBackend(B);
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        io: std.Io,
        backend: *B,
        window: B.WindowHandle,
        pool: *jobs.Pool,

        // G5: in-flight call ids (also duplicate-id detection), capped at
        // MAX_CONCURRENT. The map value is void; this is an id set, not a byte
        // budget (deviation 6).
        inflight_mutex: std.Io.Mutex = .init,
        inflight: std.AutoHashMapUnmanaged(u64, void) = .empty,

        // Window label map (deviation 3): single "main" entry pre-E. C's G2
        // resolves a label through this; E generalizes it to multi-window.
        main_window_id: u64,

        // Per-id binary ring buffer (full machinery lands here so the sink
        // closure, releaseCall, and deinit can reference it; Task 7 only adds
        // serveStream/parseStreamPath and the registry Bytes branch).
        bin_mutex: std.Io.Mutex = .init,
        bins: std.AutoHashMapUnmanaged(u64, BinRing) = .empty,

        // Comptime-erased dispatch: a fn pointer the init fills from the registry
        // type, so Bridge(B) is not generic over State/UserCommands.
        dispatchFn: *const fn (self: *Self, name: []const u8, id: u64, args_json: []const u8) void,
        allow: Allowlist,
        state_ptr: *anyopaque,

        pub fn init(
            alloc: std.mem.Allocator,
            io: std.Io,
            backend: *B,
            window: B.WindowHandle,
            comptime State: type,
            comptime UserCommands: type,
            state: *State,
            opts: BridgeOptions,
        ) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);

            const Reg = registry.Commands(B, State, UserCommands);

            self.* = .{
                .alloc = alloc,
                .io = io,
                .backend = backend,
                .window = window,
                .pool = undefined,
                .main_window_id = backend.windowId(window),
                .state_ptr = state,
                .allow = Reg.allowlist(),
                .dispatchFn = struct {
                    fn f(s: *Self, name: []const u8, id: u64, args_json: []const u8) void {
                        const st: *State = @ptrCast(@alignCast(s.state_ptr));
                        Reg.dispatch(s, st, name, id, args_json);
                    }
                }.f,
            };

            self.pool = try jobs.Pool.init(alloc, .{
                .workers = opts.worker_count orelse workerCount(),
                .max_queue = opts.max_queue,
                .io = io,
            });

            return self;
        }

        /// INFALLIBLE by contract. Joins the pool (so no worker touches the
        /// inflight map or bins after this), frees the inflight map, frees any
        /// parked binary, frees state.
        pub fn deinit(self: *Self) void {
            self.pool.deinit();
            self.inflight.deinit(self.alloc);
            self.deinitBins();
            self.alloc.destroy(self);
        }

        /// Block until all submitted jobs finish. Tests call this, then call
        /// backend.pumpMain() to deliver emitted JS.
        pub fn drainForTest(self: *Self) void {
            self.pool.waitIdle();
        }

        /// Route an inbound JS message. C will read `window_id` for G2 label
        /// lookup and `origin` for G1; A ignores both but reserves the slots
        /// so neither B nor C needs to widen the signature later.
        ///
        /// Every accepted message with a parseable id receives exactly one
        /// terminal emission (resolve or reject). Transient allocations use a
        /// per-message arena rooted on self.alloc.
        pub fn handleMessage(self: *Self, window_id: u64, origin: []const u8, text: []const u8) void {
            _ = window_id;
            _ = origin;

            // Layer-2 message-size cap (H1). onMessageImp enforces it first at
            // the objc seam; this is the defense-in-depth check for any caller.
            if (text.len > protocol.MAX_MESSAGE_LEN) {
                if (scanId(text)) |id| self.emitErrorReject(id, "internal", "message too large", null);
                return;
            }

            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const a = arena.allocator();

            const msg = protocol.decode(a, text, protocol.MAX_MESSAGE_LEN) catch {
                // Malformed: if a numeric "id" is scannable, send one correlated
                // reject so the page-side promise settles instead of hanging.
                if (scanId(text)) |id| self.emitErrorReject(id, "internal", "bad message", null);
                return;
            };
            // msg is arena-owned; no msg.deinit needed.

            // Reserved inbound names (e.g. __zigware_ready from E) never hit the gate.
            if (protocol.isReservedInboundName(msg.cmd)) return;

            if (!self.allow.contains(msg.cmd)) {
                self.emitErrorReject(msg.id, "unknown_command", "no such command", null);
                return;
            }

            // G5: reserve a slot under the budget. reserveCall emits the reject
            // itself on failure (duplicate id, budget exceeded, or OOM).
            if (!self.reserveCall(msg.id)) return;

            // C's G1/G2/G4 hook here in the future (origin trusted, window granted,
            // args in scope). Today a pass-through.

            self.dispatchFn(self, msg.cmd, msg.id, msg.args_json);
        }

        fn workerCount() usize {
            return @min(@max(std.Thread.getCpuCount() catch 4, 1), 8);
        }

        /// Best-effort scan for a numeric `"id": N` in raw (possibly malformed)
        /// text, so a decode failure can still settle the right promise (L1).
        /// Returns null if no plausible id is found. Bounded by text.len.
        fn scanId(text: []const u8) ?u64 {
            const needle = "\"id\"";
            const start = std.mem.indexOf(u8, text, needle) orelse return null;
            var i = start + needle.len;
            // Skip whitespace and a single ':'.
            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
            if (i >= text.len or text[i] != ':') return null;
            i += 1;
            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
            const num_start = i;
            while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
            if (i == num_start) return null;
            // Parse in the SAME domain decode accepts (non-negative i64), so a
            // malformed-message reject can only target an id decode would also
            // accept; overflow or out-of-range yields null (no reject) (L1).
            const parsed = std.fmt.parseInt(i64, text[num_start..i], 10) catch return null;
            if (parsed < 0) return null;
            return @intCast(parsed);
        }

        // ── Registry-facing surface (duck-typed by registry.dispatch) ──────────

        /// G5 reservation. Returns true if the call may proceed (slot reserved),
        /// false if it was rejected (duplicate id, budget exceeded, or OOM) — in
        /// which case this method has already emitted the terminal reject.
        pub fn reserveCall(self: *Self, id: u64) bool {
            self.inflight_mutex.lockUncancelable(self.io);
            defer self.inflight_mutex.unlock(self.io);
            if (self.inflight.count() >= MAX_CONCURRENT) {
                self.emitErrorReject(id, "queue_full", "server busy", null);
                return false;
            }
            const gop = self.inflight.getOrPut(self.alloc, id) catch {
                self.emitErrorReject(id, "queue_full", "server busy", null);
                return false;
            };
            if (gop.found_existing) {
                self.emitErrorReject(id, "internal", "duplicate id", null);
                return false;
            }
            return true;
        }

        /// Release the reservation recorded for `id`. Idempotent: an id not
        /// present (already released, or rejected before submit) is a no-op. Runs
        /// on worker threads via the registry's async thunk, hence the mutex.
        pub fn releaseCall(self: *Self, id: u64) void {
            self.inflight_mutex.lockUncancelable(self.io);
            _ = self.inflight.remove(id);
            self.inflight_mutex.unlock(self.io);
            // Do NOT free parked binary here (deviation 9): the webview pulls
            // bytes AFTER the call settles, so freeing on settle would 404 every
            // pull. Mark the ring settled; serveStream frees it once its last seq
            // is served, and deinitBins frees any un-pulled ring at teardown.
            // markBinSettled does NOT run under inflight_mutex (unlocked above),
            // so there is no inflight->bin lock coupling (H3).
            self.markBinSettled(id);
        }

        fn emit(self: *Self, js: []const u8) void {
            self.backend.evalJS(self.window, js);
        }

        /// Emit a minimal reject from a fixed stack buffer that CANNOT OOM, so
        /// every id always settles even under allocator failure (H5). Emits a
        /// constant `"error"` reason; correctness only needs the id and the
        /// reject channel.
        fn emitFixedReject(self: *Self, id: u64) void {
            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "window.Zigware._reject({d}, \"error\");", .{id}) catch {
                std.log.warn("bridge: fixed reject overflow for id {d}", .{id});
                return;
            };
            self.emit(js);
        }

        pub fn emitResolve(self: *Self, id: u64, json: []const u8) void {
            var aw: std.Io.Writer.Allocating = .init(self.alloc);
            defer aw.deinit();
            protocol.encodeResolve(&aw.writer, id, json) catch {
                self.emitFixedReject(id);
                return;
            };
            self.emit(aw.writer.buffered());
        }

        pub fn emitErrorReject(self: *Self, id: u64, code: []const u8, message: []const u8, payload: ?[]const u8) void {
            var aw: std.Io.Writer.Allocating = .init(self.alloc);
            defer aw.deinit();
            protocol.encodeErrorReject(&aw.writer, id, code, message, payload) catch {
                self.emitFixedReject(id);
                return;
            };
            self.emit(aw.writer.buffered());
        }

        /// Per-call sink context. The EmitSink is its first field so the static
        /// closures recover (bridge, id) via @fieldParentPtr. Lives on the
        /// runHandler frame (sync) or the heap job ctx's runHandler frame (async);
        /// the by-value local outlives the whole call (B1).
        pub const SinkCtx = struct {
            sink: ctxmod.EmitSink,
            bridge: *Self,
            id: u64,
        };

        /// Build a per-call SinkCtx (returned BY VALUE) for in-flight call `id`.
        /// No allocation, no map, no lock on the emit path (B1). The label is
        /// "main" pre-E (deviation 3).
        pub fn makeSink(self: *Self, id: u64) SinkCtx {
            return .{ .sink = .{ .label = "main", .evalJS = sinkEvalJS, .parkBinary = sinkParkBinary }, .bridge = self, .id = id };
        }

        fn sinkEvalJS(sink: *ctxmod.EmitSink, js: []const u8) void {
            const sc: *SinkCtx = @fieldParentPtr("sink", sink);
            // The A-seam alive check lives in backend.evalJS (dropped after teardown).
            sc.bridge.emit(js);
        }

        fn sinkParkBinary(sink: *ctxmod.EmitSink, id: u64, seq: u32, bytes: []const u8) bool {
            const sc: *SinkCtx = @fieldParentPtr("sink", sink);
            return sc.bridge.parkBinary(id, seq, bytes);
        }

        // ── Per-id binary ring buffer (Task 7 Step 1 machinery) ────────────────

        /// Park bytes under (id, seq). Returns false if the per-id budget would
        /// overflow. Copies the bytes (the handler's slice is arena-owned and
        /// freed after the call).
        pub fn parkBinary(self: *Self, id: u64, seq: u32, bytes: []const u8) bool {
            self.bin_mutex.lockUncancelable(self.io);
            defer self.bin_mutex.unlock(self.io);
            self.reapServedLocked();
            const cur_total = if (self.bins.getPtr(id)) |r| r.total else 0;
            if (cur_total + bytes.len > BIN_BUDGET_PER_ID) return false;
            const gop = self.bins.getOrPut(self.alloc, id) catch return false;
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const ring = gop.value_ptr;
            const copy = self.alloc.dupe(u8, bytes) catch return false;
            ring.entries.append(self.alloc, .{ .seq = seq, .bytes = copy }) catch {
                self.alloc.free(copy);
                return false;
            };
            ring.total += bytes.len;
            return true;
        }

        /// Mark the ring for `id` settled (deviation 9). Does NOT free parked
        /// bytes (the webview pulls them after settle). A ring with no entries
        /// (no _bin was ever parked, e.g. a non-binary call) is removed here so
        /// common calls leave nothing behind.
        fn markBinSettled(self: *Self, id: u64) void {
            self.bin_mutex.lockUncancelable(self.io);
            defer self.bin_mutex.unlock(self.io);
            const ring = self.bins.getPtr(id) orelse return;
            ring.settled = true;
            if (ring.entries.items.len == 0) {
                if (self.bins.fetchRemove(id)) |kv| {
                    var r = kv.value;
                    r.entries.deinit(self.alloc);
                }
            }
        }

        /// Free the bytes of every already-served entry across all rings, and drop
        /// any settled ring left empty. Reclaims served binary on the next
        /// park/serve without freeing bytes still in flight. Caller holds
        /// bin_mutex. The empties buffer is a fixed window; any overflow is reaped
        /// on the next pass (deinitBins is the backstop).
        fn reapServedLocked(self: *Self) void {
            var empties: [16]u64 = undefined;
            var n: usize = 0;
            var it = self.bins.iterator();
            while (it.next()) |kv| {
                const ring = kv.value_ptr;
                var i: usize = 0;
                while (i < ring.entries.items.len) {
                    if (ring.entries.items[i].served) {
                        self.alloc.free(ring.entries.items[i].bytes);
                        _ = ring.entries.orderedRemove(i);
                    } else i += 1;
                }
                if (ring.settled and ring.entries.items.len == 0 and n < empties.len) {
                    empties[n] = kv.key_ptr.*;
                    n += 1;
                }
            }
            for (empties[0..n]) |id| {
                if (self.bins.fetchRemove(id)) |kv| {
                    var r = kv.value;
                    r.entries.deinit(self.alloc);
                }
            }
        }

        /// Free every parked ring at teardown (the backstop for any un-pulled or
        /// un-reaped entry).
        fn deinitBins(self: *Self) void {
            var it = self.bins.iterator();
            while (it.next()) |kv| {
                for (kv.value_ptr.entries.items) |e| self.alloc.free(e.bytes);
                kv.value_ptr.entries.deinit(self.alloc);
            }
            self.bins.deinit(self.alloc);
        }

        /// Test-only accessor: the current in-flight call count. After a fully
        /// drained flood it must be 0 (proves no reservation leaks).
        pub fn inflightCount(self: *Self) usize {
            self.inflight_mutex.lockUncancelable(self.io);
            defer self.inflight_mutex.unlock(self.io);
            return self.inflight.count();
        }
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const NullBackend = @import("platform/null.zig").NullBackend;
const builtin = @import("commands/builtin.zig");

const TestBridge = struct {
    backend: *NullBackend,
    bridge: *Bridge(NullBackend),
    window_id: u64,
    state: *builtin.State,

    fn init() !TestBridge {
        const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
        const win = try backend.createWindow(.{ .url = "app://localhost/index.html" });
        const state = try std.testing.allocator.create(builtin.State);
        state.* = .{};
        const bridge = try Bridge(NullBackend).init(
            std.testing.allocator,
            std.testing.io,
            backend,
            win,
            builtin.State,
            builtin.Commands,
            state,
            .{ .worker_count = 4 }, // deterministic concurrency (L9)
        );
        return .{ .backend = backend, .bridge = bridge, .window_id = backend.windowId(win), .state = state };
    }

    fn send(self: *TestBridge, text: []const u8) void {
        self.bridge.handleMessage(self.window_id, "app://localhost", text);
    }

    fn settle(self: *TestBridge) void {
        self.bridge.drainForTest();
        self.backend.pumpMain();
    }

    fn deinit(self: *TestBridge) void {
        self.bridge.deinit(); // joins workers; backend.deinit asserts joined
        std.testing.allocator.destroy(self.state);
        self.backend.markJoined();
        self.backend.deinit();
    }
};

// countResolveExactly / countRejectExactly are pub methods on NullBackend, so
// both these bridge tests and the regression suite call them the same way.

test "happy path: invoke sha256 emits ordered progress then exactly one resolve" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expect(t.backend.countContaining("window.Zigware._stream(1, ") >= 1);
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 0), t.backend.countRejectExactly(1));
}

test "streaming: two concurrent invokes never interleave stream ids" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":2}}");
    t.send("{\"id\":2,\"cmd\":\"sha256\",\"args\":{\"megabytes\":2}}");
    t.settle();
    // Each id resolves exactly once; each has its own stream frames.
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(2));
    try std.testing.expect(t.backend.countContaining("window.Zigware._stream(1, ") >= 1);
    try std.testing.expect(t.backend.countContaining("window.Zigware._stream(2, ") >= 1);
}

test "unknown command rejects exactly once and dispatches nothing" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":9,\"cmd\":\"danger\",\"args\":{}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(9));
    try std.testing.expectEqual(@as(usize, 0), t.backend.countContaining("_resolve"));
}

test "malformed message with a scannable id rejects exactly once" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":42, this is not valid json");
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(42));
}

test "pure-noise malformed message produces no emission" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("not json at all");
    t.settle();
    try std.testing.expectEqual(@as(usize, 0), t.backend.eval_log.items.len);
}

test "message over MAX_MESSAGE_LEN drops with one reject and no allocation spike" {
    var t = try TestBridge.init();
    defer t.deinit();
    const big = try std.testing.allocator.alloc(u8, protocol.MAX_MESSAGE_LEN + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    // Splice a scannable id at the front so the reject correlates.
    const prefix = "{\"id\":7,";
    @memcpy(big[0..prefix.len], prefix);
    t.send(big);
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(7));
}

test "two invokes correlate to distinct ids" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.send("{\"id\":2,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(2));
}

test "terminate before draining suppresses all emission for an in-flight job" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.backend.terminate();
    t.send("{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 0), t.backend.eval_log.items.len);
}

test "flood: every submitted id settles exactly once (resolve XOR reject)" {
    var t = try TestBridge.init();
    defer t.deinit();
    const N: u64 = 1000;
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        var buf: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":1}}}}", .{i});
        t.send(text);
    }
    t.settle();
    i = 0;
    while (i < N) : (i += 1) {
        const settled = t.backend.countResolveExactly(i) + t.backend.countRejectExactly(i);
        try std.testing.expectEqual(@as(usize, 1), settled);
    }
    // After a fully drained flood, every reservation must be released.
    try std.testing.expectEqual(@as(usize, 0), t.bridge.inflightCount());
}

test "I2: a flood stays within a bounded transient memory budget (concurrency-capped)" {
    // DebugAllocator with a hard transient ceiling. The concurrency-count cap
    // (MAX_CONCURRENT), not a byte budget, bounds peak: with megabytes:8, peak
    // ~= min(workers=4, MAX_CONCURRENT=8) * 8 MiB ~= 32 MiB, well under 64 MiB.
    var da = std.heap.DebugAllocator(.{ .thread_safe = true, .enable_memory_limit = true }){};
    da.requested_memory_limit = 64 * 1024 * 1024;
    defer std.testing.expect(da.deinit() == .ok) catch @panic("leak");
    const a = da.allocator();

    var state = builtin.State{};
    const backend = try NullBackend.init(a, std.testing.io);
    const win = try backend.createWindow(.{ .url = "app://localhost/index.html" });
    const bridge = try Bridge(NullBackend).init(a, std.testing.io, backend, win, builtin.State, builtin.Commands, &state, .{ .worker_count = 4 });
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        var buf: [160]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":8}}}}", .{i});
        bridge.handleMessage(backend.windowId(win), "app://localhost", text);
    }
    bridge.drainForTest();
    backend.pumpMain();
    bridge.deinit();
    backend.markJoined();
    backend.deinit();
}

test "handleMessage tolerates extreme window_id values" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.bridge.handleMessage(0, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.bridge.handleMessage(std.math.maxInt(u64), "app://localhost", "{\"id\":2,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(2));
}

test "handleMessage tolerates empty and exotic origin values" {
    // TODO(C): tighten when the origin gate (G1) lands; A ignores origin so all
    // three resolve here. C deletes or inverts these assertions.
    var t = try TestBridge.init();
    defer t.deinit();
    t.bridge.handleMessage(t.window_id, "", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.bridge.handleMessage(t.window_id, "app://localhost:5173", "{\"id\":2,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.bridge.handleMessage(t.window_id, "javascript:alert(1)", "{\"id\":3,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(2));
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(3));
}

test "duplicate id is rejected and does not corrupt the inflight budget" {
    // Two messages share an id. The second must reject as a duplicate without
    // overwriting the first's reservation. After draining, inflightCount() == 0.
    var t = try TestBridge.init();
    defer t.deinit();
    // Use a large job so the first reservation is still in flight when the
    // duplicate arrives. The pool has 4 workers; one large job keeps a slot.
    t.send("{\"id\":5,\"cmd\":\"sha256\",\"args\":{\"megabytes\":256}}");
    t.send("{\"id\":5,\"cmd\":\"sha256\",\"args\":{\"megabytes\":256}}");
    t.settle();
    // The first settles (resolve or reject); the duplicate is one extra reject.
    const settled = t.backend.countResolveExactly(5) + t.backend.countRejectExactly(5);
    try std.testing.expect(settled >= 1);
    try std.testing.expectEqual(@as(usize, 0), t.bridge.inflightCount());
}

// ─── Real concurrency (H11, H13) ────────────────────────────────────────────────

test "Bridge.deinit while a worker is mid-emit does not UAF" {
    var t = try TestBridge.init();
    // Submit large jobs and deinit immediately with NO settle. terminate then
    // pool.join must complete before any hop touches freed state. The NullBackend
    // markJoined contract enforces ordering.
    var i: u64 = 0;
    while (i < 16) : (i += 1) {
        var buf: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":16}}}}", .{i});
        t.send(text);
    }
    t.backend.terminate(); // queued evals will be dropped on pump
    t.deinit(); // bridge.deinit joins; markJoined; backend.deinit drains+frees
}

// ─── Fuzz (H14: manual >= 10000-iteration driver because 0.16 --fuzz is broken) ─

test "parkBinary parks within budget, rejects on overflow, and frees on teardown" {
    var t = try TestBridge.init();
    defer t.deinit(); // joins + deinitBins; freeing the parked ring with no leak is the assertion
    const small = [_]u8{0xAB} ** 16;
    try std.testing.expect(t.bridge.parkBinary(1, 0, &small));
    const big = try std.testing.allocator.alloc(u8, BIN_BUDGET_PER_ID);
    defer std.testing.allocator.free(big);
    try std.testing.expect(!t.bridge.parkBinary(1, 1, big)); // cumulative size exceeds budget
}

const FUZZ_ITERS: usize = 10_000;

test "fuzz: handleMessage tolerates arbitrary text bytes (manual driver)" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();
    var t = try TestBridge.init();
    defer t.deinit();
    var it: usize = 0;
    while (it < FUZZ_ITERS) : (it += 1) {
        var buf: [256]u8 = undefined;
        const n = rand.uintLessThan(usize, buf.len);
        rand.bytes(buf[0..n]);
        t.bridge.handleMessage(rand.int(u64), "app://localhost", buf[0..n]);
    }
    t.settle();
}

test "fuzz: handleMessage tolerates arbitrary window_id and origin (manual driver)" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed ^ 0x9e3779b9);
    const rand = prng.random();
    var t = try TestBridge.init();
    defer t.deinit();
    var it: usize = 0;
    while (it < FUZZ_ITERS) : (it += 1) {
        var ob: [128]u8 = undefined;
        var tb: [512]u8 = undefined;
        const on = rand.uintLessThan(usize, ob.len);
        const tn = rand.uintLessThan(usize, tb.len);
        rand.bytes(ob[0..on]);
        rand.bytes(tb[0..tn]);
        t.bridge.handleMessage(rand.int(u64), ob[0..on], tb[0..tn]);
    }
    t.settle();
}
