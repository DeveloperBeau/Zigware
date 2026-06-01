const std = @import("std");
const protocol = @import("protocol.zig");
const Allowlist = @import("allowlist.zig").Allowlist;
const jobs = @import("jobs.zig");
const backend_mod = @import("platform/backend.zig");

/// Total in-flight working-set budget. Each submitted job reserves mb*1MiB
/// against this; a submission that would exceed it is rejected with "busy".
/// Bounds total memory regardless of how deep the queue is, replacing a
/// time-based rate limit (deferred to v0.2). 1 GiB headroom for the demo's
/// 300 MB job plus a few concurrent ones.
const BRIDGE_MEMORY_BUDGET: u64 = 1 * 1024 * 1024 * 1024;
const MIB: u64 = 1024 * 1024;

pub const BridgeOptions = struct {
    /// Explicit worker count so tests are deterministic across CI hardware.
    /// main.zig passes null to use the CPU-derived default.
    worker_count: ?usize = null,
    max_queue: usize = 256,
};

/// Bridge over a platform backend `B`. Routes inbound JS messages to the worker
/// pool and emits results back through `B.evalJS`. Liveness is the backend's
/// concern: evalJS after shutdown is dropped by the backend, so the bridge has
/// no separate alive gate.
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
        allow: Allowlist,
        pool: *jobs.Pool,
        /// Per-id reserved bytes for in-flight jobs. `jobs.zig` stays Unchanged
        /// (its callbacks carry only id, not mb), so the bridge keeps its own
        /// id -> reserved-bytes map: insert before submit, remove+subtract on
        /// resolve/reject (which run on worker threads, hence the mutex). This
        /// is the M7-consistent design: no jobs.zig edit. `inflight_total` is
        /// the running sum the budget gate reads.
        inflight_mutex: std.Io.Mutex = .init,
        inflight: std.AutoHashMapUnmanaged(u64, u64) = .empty,
        inflight_total: u64 = 0,

        pub fn init(
            alloc: std.mem.Allocator,
            io: std.Io,
            backend: *B,
            window: B.WindowHandle,
            opts: BridgeOptions,
        ) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);

            var allow: Allowlist = .empty;
            try allow.add("sha256");

            const events = jobs.Events{
                .ctx = self,
                .onProgress = onProgress,
                .onResolve = onResolve,
                .onReject = onReject,
            };

            self.* = .{
                .alloc = alloc,
                .io = io,
                .backend = backend,
                .window = window,
                .allow = allow,
                .pool = undefined,
            };

            self.pool = try jobs.Pool.init(alloc, .{
                .workers = opts.worker_count orelse workerCount(),
                .max_queue = opts.max_queue,
                .io = io,
            }, events);

            return self;
        }

        /// INFALLIBLE by contract. Joins the pool (so no worker touches the
        /// inflight map after this), frees the inflight map, frees state.
        pub fn deinit(self: *Self) void {
            self.pool.deinit();
            self.inflight.deinit(self.alloc);
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
                if (scanId(text)) |id| self.emitReject(id, "message too large");
                return;
            }

            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const a = arena.allocator();

            const msg = protocol.decode(a, text, protocol.MAX_MESSAGE_LEN) catch {
                // Malformed: if a numeric "id" is scannable, send one correlated
                // reject so the page-side promise settles instead of hanging.
                if (scanId(text)) |id| self.emitReject(id, "bad message");
                return;
            };
            // msg is arena-owned; no msg.deinit needed.

            if (!self.allow.contains(msg.cmd)) {
                self.emitReject(msg.id, "unknown command");
                return;
            }

            const mb = self.parseMegabytes(a, msg.args_json);
            const cost: u64 = @as(u64, mb) * MIB;

            // Working-set budget gate (H11). Reserve before submit under the
            // mutex; if we would blow the budget, reject and do not submit. The
            // reservation is recorded per id and released by onResolve/onReject
            // (or rolled back here on a submit failure). Reserving with the
            // allocator (hash insert) can OOM; treat that as a soft "busy".
            self.inflight_mutex.lockUncancelable(self.io);
            // The id is attacker-controlled (the page picks it). If an id is
            // already in flight, reject the duplicate rather than overwriting
            // its reservation in the map: a collided key would make the two
            // releases subtract the wrong cost and underflow inflight_total,
            // permanently wedging the budget (finding B1). getOrPut lets us
            // detect the collision atomically under the lock.
            const gop = self.inflight.getOrPut(self.alloc, msg.id) catch {
                self.inflight_mutex.unlock(self.io);
                self.emitReject(msg.id, "busy");
                return;
            };
            if (gop.found_existing) {
                self.inflight_mutex.unlock(self.io);
                self.emitReject(msg.id, "duplicate id");
                return;
            }
            if (self.inflight_total + cost > BRIDGE_MEMORY_BUDGET) {
                _ = self.inflight.remove(msg.id); // back out the slot we just reserved
                self.inflight_mutex.unlock(self.io);
                self.emitReject(msg.id, "busy");
                return;
            }
            gop.value_ptr.* = cost;
            self.inflight_total += cost;
            self.inflight_mutex.unlock(self.io);

            self.pool.submit(.{ .id = msg.id, .megabytes = mb }) catch {
                self.releaseInflightFor(msg.id);
                self.emitReject(msg.id, "queue full");
            };
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

        /// Parse the optional `megabytes` integer from the args JSON via a
        /// targeted Scanner (no full Value parse, per H2). Absent -> default
        /// 256 (matches the PoC and keeps the 300 MB smoke demo and its hash
        /// oracle valid). Present-but-malformed -> default (the job still runs).
        /// Clamps to MAX_MEGABYTES so a hostile page cannot drive gigabyte
        /// allocations across the bounded pool. Uses the supplied (arena)
        /// allocator, never page_allocator.
        ///
        /// pub for direct boundary + fuzz tests (M15).
        pub const MAX_MEGABYTES: usize = 512;
        const DEFAULT_MEGABYTES: usize = 256;
        pub fn parseMegabytes(self: *Self, a: std.mem.Allocator, args_json: []const u8) usize {
            _ = self;
            // Reuse protocol's single JSON_PARSE_OPTIONS so decode and the
            // megabytes scan can never drift on parse limits.
            const parsed = std.json.parseFromSlice(std.json.Value, a, args_json, protocol.JSON_PARSE_OPTIONS) catch return DEFAULT_MEGABYTES;
            defer parsed.deinit();
            if (parsed.value != .object) return DEFAULT_MEGABYTES;
            const v = parsed.value.object.get("megabytes") orelse return DEFAULT_MEGABYTES;
            if (v != .integer or v.integer <= 0) return DEFAULT_MEGABYTES;
            // Clamp on the i64 domain BEFORE the cast (M11): @intCast of an i64
            // larger than usize traps in ReleaseSafe on a 32-bit target. After
            // the clamp the value is provably in [1, MAX_MEGABYTES], so the cast
            // is total on any target width.
            const clamped: i64 = @min(v.integer, @as(i64, MAX_MEGABYTES));
            return @intCast(clamped);
        }

        /// Emit JS to the window. The backend drops it if the webview is gone.
        fn emit(self: *Self, js: []const u8) void {
            self.backend.evalJS(self.window, js);
        }

        /// Emit a minimal reject from a fixed stack buffer that CANNOT OOM, so
        /// every id always settles even under allocator failure (H5). The
        /// message is truncated to fit; correctness only needs the id and the
        /// reject channel.
        fn emitFixedReject(self: *Self, id: u64) void {
            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "window.zig._reject({d}, \"error\");", .{id}) catch {
                // id formatting cannot realistically overflow 256 bytes; if it
                // somehow does, there is no safe fallback, so drop.
                std.log.warn("bridge: fixed reject overflow for id {d}", .{id});
                return;
            };
            self.emit(js);
        }

        fn emitReject(self: *Self, id: u64, message: []const u8) void {
            var aw: std.Io.Writer.Allocating = .init(self.alloc);
            defer aw.deinit();
            protocol.encodeReject(&aw.writer, id, message) catch |err| {
                std.log.warn("bridge: encodeReject failed: {s}", .{@errorName(err)});
                self.emitFixedReject(id);
                return;
            };
            self.emit(aw.writer.buffered());
        }

        fn onProgress(ctx: *anyopaque, id: u64, pct: u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var aw: std.Io.Writer.Allocating = .init(self.alloc);
            defer aw.deinit();
            var jbuf: [64]u8 = undefined;
            const json = std.fmt.bufPrint(&jbuf, "{{\"id\":{d},\"pct\":{d}}}", .{ id, pct }) catch return;
            protocol.encodeEmit(&aw.writer, "progress", json) catch |err| {
                std.log.warn("bridge: encodeEmit(progress) failed: {s}", .{@errorName(err)});
                return; // progress is non-terminal; the resolve/reject still settles the promise
            };
            self.emit(aw.writer.buffered());
        }

        fn onResolve(ctx: *anyopaque, id: u64, hex: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            defer self.releaseInflightFor(id);
            var aw: std.Io.Writer.Allocating = .init(self.alloc);
            defer aw.deinit();
            var jbuf: [128]u8 = undefined;
            // LOAD-BEARING (M4): `hex` is a charset-restricted SHA-256 digest
            // ([0-9a-f], fixed 64 bytes), so hand-building the JSON and routing
            // it through writeJsonAsJsLiteral (which escapes only LS/PS, NOT
            // arbitrary string content) is safe HERE ONLY. Any command whose
            // result contains attacker-influenced string bytes MUST build the
            // object with std.json.Stringify or route each string through
            // jsString. Sub-project B's typed result codegen enforces this.
            const json = std.fmt.bufPrint(&jbuf, "{{\"hash\":\"{s}\"}}", .{hex}) catch {
                self.emitFixedReject(id);
                return;
            };
            protocol.encodeResolve(&aw.writer, id, json) catch |err| {
                std.log.warn("bridge: encodeResolve failed: {s}", .{@errorName(err)});
                self.emitFixedReject(id);
                return;
            };
            self.emit(aw.writer.buffered());
        }

        fn onReject(ctx: *anyopaque, id: u64, msg: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            defer self.releaseInflightFor(id);
            self.emitReject(id, msg);
        }

        /// Release the reservation recorded for `id` at submit time. Looks the
        /// id up in the inflight map, removes it, and subtracts its exact cost
        /// from the running total. Idempotent: an id not present (already
        /// released, or rejected before submit) is a no-op. Runs on worker
        /// threads via the onResolve/onReject defers, hence the mutex.
        fn releaseInflightFor(self: *Self, id: u64) void {
            self.inflight_mutex.lockUncancelable(self.io);
            defer self.inflight_mutex.unlock(self.io);
            if (self.inflight.fetchRemove(id)) |kv| {
                self.inflight_total -= kv.value;
            }
        }

        /// Test-only accessor: the current reserved total. After a fully drained
        /// flood it must be 0 (proves no reservation leaks, finding B1).
        pub fn inflightBytes(self: *Self) u64 {
            self.inflight_mutex.lockUncancelable(self.io);
            defer self.inflight_mutex.unlock(self.io);
            return self.inflight_total;
        }
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const NullBackend = @import("platform/null.zig").NullBackend;

const TestBridge = struct {
    backend: *NullBackend,
    bridge: *Bridge(NullBackend),
    window_id: u64,

    fn init() !TestBridge {
        const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
        const win = try backend.createWindow(.{ .url = "app://localhost/index.html" });
        const bridge = try Bridge(NullBackend).init(
            std.testing.allocator,
            std.testing.io,
            backend,
            win,
            .{ .worker_count = 4 }, // deterministic concurrency (L9)
        );
        return .{ .backend = backend, .bridge = bridge, .window_id = backend.windowId(win) };
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
        self.backend.markJoined();
        self.backend.deinit();
    }
};

// countResolveExactly / countRejectExactly are pub methods on NullBackend
// (defined in Task 2), so both these bridge tests and the Task 11 regression
// suite call them the same way: `backend.countResolveExactly(id)`.

test "happy path: invoke sha256 emits ordered progress then exactly one resolve" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expect(t.backend.countContaining("window.zig._emit(\"progress\"") >= 1);
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 0), t.backend.countRejectExactly(1));
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
    // After a fully drained flood, every reservation must be released (B1).
    try std.testing.expectEqual(@as(u64, 0), t.bridge.inflightBytes());
}

test "I2: a flood stays within a bounded transient memory budget" {
    // DebugAllocator with a hard transient ceiling. The working-set budget gate
    // (BRIDGE_MEMORY_BUDGET) and per-message arena must keep peak under this.
    // requested_memory_limit is a runtime field set after construction; the
    // config flag that enables it is enable_memory_limit (B2).
    var da = std.heap.DebugAllocator(.{ .thread_safe = true, .enable_memory_limit = true }){};
    da.requested_memory_limit = 256 * 1024 * 1024;
    defer std.testing.expect(da.deinit() == .ok) catch @panic("leak");
    const a = da.allocator();

    const backend = try NullBackend.init(a, std.testing.io);
    const win = try backend.createWindow(.{ .url = "app://localhost/index.html" });
    const bridge = try Bridge(NullBackend).init(a, std.testing.io, backend, win, .{ .worker_count = 4 });
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        var buf: [160]u8 = undefined;
        // Each asks for 256 MB; the budget gate rejects most as "busy" so peak
        // stays bounded well under the 256 MB DebugAllocator ceiling.
        const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":256}}}}", .{i});
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
    // overwriting the first's reservation, so the budget total never underflows
    // (finding B1). After draining, inflightBytes() returns to 0.
    var t = try TestBridge.init();
    defer t.deinit();
    // Use a large job so the first reservation is still in flight when the
    // duplicate arrives. The pool has 4 workers; one 256 MB job keeps a slot.
    t.send("{\"id\":5,\"cmd\":\"sha256\",\"args\":{\"megabytes\":256}}");
    t.send("{\"id\":5,\"cmd\":\"sha256\",\"args\":{\"megabytes\":256}}");
    t.settle();
    // The first settles (resolve or reject); the duplicate is one extra reject.
    const settled = t.backend.countResolveExactly(5) + t.backend.countRejectExactly(5);
    try std.testing.expect(settled >= 1);
    try std.testing.expectEqual(@as(u64, 0), t.bridge.inflightBytes());
}

// ─── parseMegabytes direct boundary tests (M15) ─────────────────────────────────

fn pmb(args_json: []const u8) usize {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // parseMegabytes ignores self; pass undefined-but-valid via a throwaway.
    const backend = NullBackend.init(std.testing.allocator, std.testing.io) catch unreachable;
    defer backend.deinit();
    const win = backend.createWindow(.{ .url = "x" }) catch unreachable;
    const bridge = Bridge(NullBackend).init(std.testing.allocator, std.testing.io, backend, win, .{ .worker_count = 1 }) catch unreachable;
    defer {
        bridge.deinit();
        backend.markJoined();
    }
    return bridge.parseMegabytes(arena.allocator(), args_json);
}

test "parseMegabytes boundaries" {
    try std.testing.expectEqual(@as(usize, 256), pmb("{}")); // absent -> default
    try std.testing.expectEqual(@as(usize, 256), pmb("{\"other\":5}")); // absent -> default
    try std.testing.expectEqual(@as(usize, 256), pmb("not json")); // malformed -> default
    try std.testing.expectEqual(@as(usize, 256), pmb("[]")); // non-object -> default
    try std.testing.expectEqual(@as(usize, 256), pmb("{\"megabytes\":0}")); // <=0 -> default
    try std.testing.expectEqual(@as(usize, 256), pmb("{\"megabytes\":-7}")); // negative -> default
    try std.testing.expectEqual(@as(usize, 256), pmb("{\"megabytes\":\"5\"}")); // wrong type -> default
    try std.testing.expectEqual(@as(usize, 1), pmb("{\"megabytes\":1}"));
    try std.testing.expectEqual(@as(usize, 300), pmb("{\"megabytes\":300}")); // the demo size, intact
    try std.testing.expectEqual(@as(usize, 512), pmb("{\"megabytes\":512}")); // at the cap
    try std.testing.expectEqual(@as(usize, 512), pmb("{\"megabytes\":513}")); // over cap -> clamp
    try std.testing.expectEqual(@as(usize, 512), pmb("{\"megabytes\":1000000}")); // way over -> clamp
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
