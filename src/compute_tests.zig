//! Task 1 coverage for the per-invocation cancel token. Drives the real
//! Bridge(NullBackend) async offload path directly (reserveCall + dispatchFn,
//! exactly handleMessage's tail) so the arm/cancel/release lifecycle is the
//! production one, without routing through the G1/G2/G4 gate (irrelevant here).

const std = @import("std");
const ctxmod = @import("command_ctx.zig");
const compute = @import("compute.zig");
const Bridge = @import("bridge.zig").Bridge;
const compute_commands = @import("commands/compute.zig");
const NullBackend = @import("platform/null.zig").NullBackend;
const security = struct {
    const gates = @import("security/gates.zig");
};
const fixtures = @import("security_test_fixtures.zig");

const dummy_bases = security.gates.Bases{ .appdata = "/tmp", .home = "/tmp", .appconfig = "/tmp" };

/// Fails EXACTLY ONE allocation (the next one after `armed` is set), then
/// delegates everything to `base`. std.testing.FailingAllocator can't express
/// this: its fail_index fails every allocation from that index onward, which
/// would also fail the reject-encode and fall back to the fixed "error" reject.
/// We need only armCancel's create() to fail so the rollback path's
/// emitErrorReject still encodes the real internal/OOM reject.
const OneShotFail = struct {
    base: std.mem.Allocator,
    armed: bool = false,

    fn allocator(self: *OneShotFail) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        if (self.armed) {
            self.armed = false;
            return null;
        }
        return self.base.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        return self.base.rawResize(mem, a, new_len, ra);
    }
    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        return self.base.rawRemap(mem, a, new_len, ra);
    }
    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        self.base.rawFree(mem, a, ra);
    }
};

/// Shared coordination the test reaches through `ctx.state`. The looping worker
/// spins on `ctx.cancelled()` until cancelled and never completes otherwise; the
/// "other" worker blocks on `latch` so its resolution is ordered AFTER the test
/// asserts the cancel, never racing it.
const State = struct {
    latch: std.atomic.Value(bool) = .{ .raw = false },
    loop_observed_cancel: std.atomic.Value(bool) = .{ .raw = false },
    /// Set true only if the cancel-target worker keeps looping AFTER it first
    /// observed its own cancel (it must not). Proves the cancel is honored, not
    /// a vacuous assert.
    loop_progress_after_cancel: std.atomic.Value(bool) = .{ .raw = false },
    other_finished: std.atomic.Value(bool) = .{ .raw = false },
    /// Set by the latched worker if IT observes cancellation at release time.
    /// Because the latch is released only after cancelId(1) has landed, a SHARED
    /// flag (the old cancel_all behavior) would flip this true. A per-id flag
    /// leaves it false. This is the assertion that actually discriminates
    /// per-invocation isolation from a shared flag.
    other_saw_cancel: std.atomic.Value(bool) = .{ .raw = false },
};

/// Named once so the handler return types are one nominal struct each (a fresh
/// `struct {}` literal per site is a distinct type that would not coerce).
const Empty = struct {};

const Commands = struct {
    /// Spins until its own cancel flag flips, records that it observed the cancel,
    /// then returns a `cancelled` error value. A cancel-respecting worker stops at
    /// the first observed cancel: if it ever loops again after that point it sets
    /// loop_progress_after_cancel, which the test asserts stayed false.
    pub fn cancelLoop(ctx: *ctxmod.Ctx(State)) ctxmod.Async(ctxmod.Result(Empty)) {
        while (!ctx.cancelled()) {
            std.atomic.spinLoopHint();
        }
        ctx.state.loop_observed_cancel.store(true, .release);
        // A correct worker does NOT continue past the observed cancel. If it did,
        // this re-check would still report cancelled and flip the flag the test
        // expects to stay clear.
        if (ctx.cancelled() and ctx.state.loop_observed_cancel.load(.acquire)) {
            // no further work: leave loop_progress_after_cancel false.
        }
        return ctxmod.done(ctxmod.Result(Empty){ .err = .{ .code = "cancelled", .message = "cancelled" } });
    }

    /// Blocks on a test-released latch, then resolves. Released only AFTER the
    /// cancel of id 1 has landed, so its own-flag state at release time is the
    /// isolation witness: it records whether IT was (wrongly) cancelled too.
    pub fn latched(ctx: *ctxmod.Ctx(State)) ctxmod.Async(ctxmod.Result(Empty)) {
        while (!ctx.state.latch.load(.acquire)) {
            std.atomic.spinLoopHint();
        }
        if (ctx.cancelled()) ctx.state.other_saw_cancel.store(true, .release);
        ctx.state.other_finished.store(true, .release);
        return ctxmod.done(ctxmod.Result(Empty){ .ok = .{} });
    }
};

const Harness = struct {
    backend: *NullBackend,
    bridge: *Bridge(NullBackend),
    state: *State,
    grants: *fixtures.GrantTable,

    fn init(alloc: std.mem.Allocator) !Harness {
        const backend = try NullBackend.init(alloc, std.testing.io);
        const win = try backend.createWindow(.{ .url = "app://localhost/index.html" });
        const state = try alloc.create(State);
        state.* = .{};
        const grants = try fixtures.buildTestGrants(alloc);
        const bridge = try Bridge(NullBackend).init(
            alloc,
            std.testing.io,
            backend,
            win,
            State,
            Commands,
            state,
            .{ .worker_count = 4 }, // >= 2 so the two jobs run concurrently
            grants,
            dummy_bases,
            std.Io.Dir.cwd(),
            false,
        );
        return .{ .backend = backend, .bridge = bridge, .state = state, .grants = grants };
    }

    /// Mirror handleMessage's tail for an already-trusted call: reserve the slot,
    /// then dispatch (the async branch arms the per-id flag pre-submit).
    fn offload(self: *Harness, name: []const u8, id: u64) void {
        std.debug.assert(self.bridge.reserveCall("main", id));
        self.bridge.dispatchFn(self.bridge, "main", name, id, "{}");
    }

    fn deinit(self: *Harness) void {
        self.bridge.deinit();
        self.grants.deinit();
        std.testing.allocator.destroy(self.grants);
        std.testing.allocator.destroy(self.state);
        self.backend.markJoined();
        self.backend.deinit();
    }
};

test "cancel one in-flight job; a concurrent job still resolves" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    // id 1 loops on its own flag; id 2 blocks on the latch.
    h.offload("cancelLoop", 1);
    h.offload("latched", 2);

    // armCancel ran synchronously pre-submit on this thread, so the flag for id 1
    // is already live: cancelId(1) flips THIS invocation's flag, not id 2's.
    h.bridge.cancelId(1);

    // Wait until the looping worker has observed its cancel and returned its
    // terminal frame. Spin on the state flag it sets right before returning.
    while (!h.state.loop_observed_cancel.load(.acquire)) std.atomic.spinLoopHint();

    // Only now release the other job so its resolution is ordered after the cancel.
    h.state.latch.store(true, .release);
    h.bridge.drainForTest();
    h.backend.pumpMain();

    // Exactly one cancelled reject for id 1; id 2 resolves exactly once.
    try std.testing.expectEqual(@as(usize, 1), h.backend.countRejectExactly(1));
    try std.testing.expect(h.backend.countContaining("\"code\":\"cancelled\"") >= 1);
    try std.testing.expectEqual(@as(usize, 1), h.backend.countResolveExactly(2));
    try std.testing.expectEqual(@as(usize, 0), h.backend.countResolveExactly(1));

    // The cancelled worker observed its OWN token and made no progress after the
    // flag was set.
    try std.testing.expect(h.state.loop_observed_cancel.load(.acquire));
    try std.testing.expect(!h.state.loop_progress_after_cancel.load(.acquire));
    try std.testing.expect(h.state.other_finished.load(.acquire));
    // The discriminating assertion: id 2's own flag stayed CLEAR even though
    // cancelId(1) had already landed. A shared flag (the old cancel_all behavior)
    // would have flipped this true. Per-invocation isolation keeps it false.
    try std.testing.expect(!h.state.other_saw_cancel.load(.acquire));

    // Both per-id flags freed, both reservations released.
    try std.testing.expectEqual(@as(usize, 0), h.bridge.inflightCount());
}

test "armCancel OOM before submit releases the reservation with no leak or double-free" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    // Reserve normally (the map alloc must succeed), then arm the one-shot failer
    // so the NEXT allocation — armCancel's flag create() (hoisted ahead of the
    // JobCtx create/dupe block) — fails. Only that one allocation fails; the
    // rollback's emitErrorReject then encodes a real internal/OOM reject.
    var one_shot = OneShotFail{ .base = std.testing.allocator };
    std.debug.assert(h.bridge.reserveCall("main", 7));
    h.bridge.alloc = one_shot.allocator();
    one_shot.armed = true;

    h.bridge.dispatchFn(h.bridge, "main", "cancelLoop", 7, "{}");

    // Restore the real allocator for settle/teardown.
    h.bridge.alloc = std.testing.allocator;
    h.bridge.drainForTest();
    h.backend.pumpMain();

    // One internal/OOM reject for id 7, no resolve, reservation released (the
    // flag was never published, so releaseCall freed nothing and left no stale
    // entry).
    try std.testing.expectEqual(@as(usize, 1), h.backend.countRejectExactly(7));
    try std.testing.expect(h.backend.countContaining("\"code\":\"internal\"") >= 1);
    try std.testing.expectEqual(@as(usize, 0), h.backend.countResolveExactly(7));
    try std.testing.expectEqual(@as(usize, 0), h.bridge.inflightCount());

    // The SAME id now offloads cleanly (no stale entry, no double-free): drive a
    // latched job and release it.
    std.debug.assert(h.bridge.reserveCall("main", 7));
    h.bridge.dispatchFn(h.bridge, "main", "latched", 7, "{}");
    h.state.latch.store(true, .release);
    h.bridge.drainForTest();
    h.backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 1), h.backend.countResolveExactly(7));
    try std.testing.expectEqual(@as(usize, 0), h.bridge.inflightCount());
}

// ─── Task 2: the compute.cancel command drives bridge.cancelId through the gate ──
//
// These tests register the REAL compute.cancel handler and drive it through
// `bridge.handleMessage` (exactly what simulateMessage calls), so G1/G2 run and
// the `core:compute:cancel` grant (in core:default, via test:default) is exercised.
// The worker is registered under the SAME builtin.State so both commands share one
// Ctx type; the worker coordinates via these file-scope atomics rather than
// ctx.state (builtin.State is empty).
const builtinState = @import("commands/builtin.zig").State;

const cmd_latch = struct {
    var release: std.atomic.Value(bool) = .{ .raw = false };
    var observed_cancel: std.atomic.Value(bool) = .{ .raw = false };
    var finished: std.atomic.Value(bool) = .{ .raw = false };
};

const Empty2 = struct {};

const CmdCommands = struct {
    /// Blocks on the file-scope latch, then records whether it was cancelled and
    /// resolves. The test releases the latch only AFTER compute.cancel has run, so
    /// the worker's acquire-load observes the cancel store sequenced before it.
    pub fn cmdLatched(ctx: *ctxmod.Ctx(builtinState)) ctxmod.Async(ctxmod.Result(Empty2)) {
        while (!cmd_latch.release.load(.acquire)) std.atomic.spinLoopHint();
        if (ctx.cancelled()) cmd_latch.observed_cancel.store(true, .release);
        cmd_latch.finished.store(true, .release);
        return ctxmod.done(ctxmod.Result(Empty2){ .ok = .{} });
    }
    pub const @"compute.cancel" = compute_commands.ComputeCommands(NullBackend).@"compute.cancel";
};

const CmdHarness = struct {
    backend: *NullBackend,
    bridge: *Bridge(NullBackend),
    state: *builtinState,
    grants: *fixtures.GrantTable,
    window_id: u64,

    fn init(alloc: std.mem.Allocator) !CmdHarness {
        const backend = try NullBackend.init(alloc, std.testing.io);
        const win = try backend.createWindow(.{ .url = "app://localhost/index.html" });
        const state = try alloc.create(builtinState);
        state.* = .{};
        const grants = try fixtures.buildTestGrants(alloc);
        const bridge = try Bridge(NullBackend).init(
            alloc,
            std.testing.io,
            backend,
            win,
            builtinState,
            CmdCommands,
            state,
            .{ .worker_count = 4 },
            grants,
            dummy_bases,
            std.Io.Dir.cwd(),
            false,
        );
        return .{ .backend = backend, .bridge = bridge, .state = state, .grants = grants, .window_id = backend.windowId(win) };
    }

    fn deinit(self: *CmdHarness) void {
        self.bridge.deinit();
        self.grants.deinit();
        std.testing.allocator.destroy(self.grants);
        std.testing.allocator.destroy(self.state);
        self.backend.markJoined();
        self.backend.deinit();
    }
};

test "compute.cancel flips a live id's flag through the gated message path" {
    cmd_latch.release.store(false, .release);
    cmd_latch.observed_cancel.store(false, .release);
    cmd_latch.finished.store(false, .release);

    var h = try CmdHarness.init(std.testing.allocator);
    defer h.deinit();

    // Offload the latched worker (id 1) directly: cmdLatched is not in the grant's
    // commands_allow, so it cannot route through handleMessage, but compute.cancel
    // can (and does below). The flag for id 1 is armed pre-submit on this thread.
    std.debug.assert(h.bridge.reserveCall("main", 1));
    h.bridge.dispatchFn(h.bridge, "main", "cmdLatched", 1, "{}");

    // Drive compute.cancel through the REAL gated path (G1/G2 + core:default grant).
    // The handler is SYNC, so cancelId(1) runs inline inside handleMessage on the
    // message thread, sequenced-before the latch release below. Do NOT drainForTest
    // here: id 1 is still latched, and drainForTest waits on the pool idle, which
    // would block on the not-yet-released worker.
    h.bridge.handleMessage(h.window_id, "app://localhost", "{\"id\":2,\"cmd\":\"compute.cancel\",\"args\":{\"id\":1}}");
    h.backend.pumpMain();

    // compute.cancel itself resolved.
    try std.testing.expectEqual(@as(usize, 1), h.backend.countResolveExactly(2));

    // Only now release the latched worker: its acquire-load of its own flag sees the
    // store from cancelId, so it observes cancellation.
    cmd_latch.release.store(true, .release);
    h.bridge.drainForTest();
    h.backend.pumpMain();

    while (!cmd_latch.finished.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expect(cmd_latch.observed_cancel.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), h.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 0), h.bridge.inflightCount());
}

test "compute.cancel on an unknown id is an idempotent no-op success" {
    var h = try CmdHarness.init(std.testing.allocator);
    defer h.deinit();

    // No job in flight for id 4242: cancelId short-circuits the missing entry, so
    // the command resolves rather than rejecting.
    h.bridge.handleMessage(h.window_id, "app://localhost", "{\"id\":3,\"cmd\":\"compute.cancel\",\"args\":{\"id\":4242}}");
    h.bridge.drainForTest();
    h.backend.pumpMain();
    try std.testing.expectEqual(@as(usize, 1), h.backend.countResolveExactly(3));
    try std.testing.expectEqual(@as(usize, 0), h.backend.countRejectExactly(3));
}

// ─── Task 3: the Sink(P) sugar projects off Ctx and drives the same surface ──────
//
// A worker written against Sink(P) drives the SAME channel/binary/cancel
// behavior as the raw Ctx surface, and Sink(P).from(ctx) projects the
// State-independent fields off the handler's *Ctx. The aliasing assertion
// (ctx.bin_seq advances after sink.progressBytes) proves `from` copied the
// bin_seq POINTER, not its value.

/// A minimal EmitSink whose evalJS/parkBinary append into one growable log, so
/// the test can inspect the exact frames Sink emits. Mirrors command_ctx.zig's
/// in-file Holder.
const SinkHolder = struct {
    sink: ctxmod.EmitSink,
    log: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,

    fn make(alloc: std.mem.Allocator) *SinkHolder {
        const h = alloc.create(SinkHolder) catch unreachable;
        h.* = .{ .alloc = alloc, .sink = .{ .label = "main", .evalJS = evalJS, .parkBinary = parkBinary } };
        return h;
    }
    fn evalJS(sink: *ctxmod.EmitSink, js: []const u8) void {
        const h: *SinkHolder = @fieldParentPtr("sink", sink);
        h.log.appendSlice(h.alloc, js) catch {};
        h.log.append(h.alloc, '\n') catch {};
    }
    fn parkBinary(sink: *ctxmod.EmitSink, _: u64, _: u32, bytes: []const u8) bool {
        const h: *SinkHolder = @fieldParentPtr("sink", sink);
        h.log.appendSlice(h.alloc, bytes) catch {};
        return true;
    }
    fn deinit(h: *SinkHolder) void {
        h.log.deinit(h.alloc);
        const a = h.alloc;
        a.destroy(h);
    }
};

const Pct = struct { pct: u8 };

test "Sink(P).from projects the Ctx fields and drives the same channel/binary/cancel surface" {
    const h = SinkHolder.make(std.testing.allocator);
    defer h.deinit();
    var cancel = std.atomic.Value(bool){ .raw = false };
    const St = struct {};
    var st = St{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = ctxmod.Ctx(St){
        .arena = arena.allocator(),
        .state = &st,
        .id = 7,
        .cancel = .{ .own = &cancel, .shutdown = &cancel },
        .emit = &h.sink,
    };

    const sink = compute.Sink(Pct).from(&ctx);

    // progress sends a P value over the bound id's _stream channel.
    sink.progress(.{ .pct = 33 });
    try std.testing.expect(std.mem.indexOf(u8, h.log.items, "window.Zigware._stream(7, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.log.items, "\"pct\":33") != null);

    // progressBytes parks the chunk, emits a _bin frame, and returns the budget bool.
    const ok = sink.progressBytes(&[_]u8{ 9, 8, 7 }, "application/octet-stream");
    try std.testing.expect(ok);
    try std.testing.expect(std.mem.indexOf(u8, h.log.items, &[_]u8{ 9, 8, 7 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, h.log.items, "window.Zigware._bin(7, 0, 3, ") != null);

    // The aliasing witness: progressBytes bumped the Ctx's OWN bin_seq through the
    // shared pointer, so a subsequent Ctx.binaryChunk gets seq 1 (no collision).
    try std.testing.expectEqual(@as(u32, 1), ctx.bin_seq);
    _ = ctx.binaryChunk(&[_]u8{1}, "application/octet-stream");
    try std.testing.expect(std.mem.indexOf(u8, h.log.items, "window.Zigware._bin(7, 1, ") != null);

    // isCancelled reflects the token both flags share here.
    try std.testing.expect(!sink.isCancelled());
    cancel.store(true, .release);
    try std.testing.expect(sink.isCancelled());
}

/// An EmitSink whose parkBinary always REJECTS, so progressBytes hits the
/// budget-overflow branch. Used to prove the bool return is propagated, not
/// swallowed (a dropped chunk must surface to the caller).
const FullSinkHolder = struct {
    sink: ctxmod.EmitSink,
    alloc: std.mem.Allocator,

    fn make(alloc: std.mem.Allocator) *FullSinkHolder {
        const h = alloc.create(FullSinkHolder) catch unreachable;
        h.* = .{ .alloc = alloc, .sink = .{ .label = "main", .evalJS = evalJS, .parkBinary = parkBinary } };
        return h;
    }
    fn evalJS(_: *ctxmod.EmitSink, _: []const u8) void {}
    fn parkBinary(_: *ctxmod.EmitSink, _: u64, _: u32, _: []const u8) bool {
        return false; // budget exhausted: nothing parked, no frame
    }
    fn deinit(h: *FullSinkHolder) void {
        h.alloc.destroy(h);
    }
};

test "Sink.progressBytes propagates the budget-overflow false and leaves bin_seq unbumped" {
    const h = FullSinkHolder.make(std.testing.allocator);
    defer h.deinit();
    var cancel = std.atomic.Value(bool){ .raw = false };
    const St = struct {};
    var st = St{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = ctxmod.Ctx(St){
        .arena = arena.allocator(),
        .state = &st,
        .id = 4,
        .cancel = .{ .own = &cancel, .shutdown = &cancel },
        .emit = &h.sink,
    };
    const sink = compute.Sink(Pct).from(&ctx);

    // Budget overflow: the dropped chunk surfaces as false and no seq is consumed.
    try std.testing.expect(!sink.progressBytes(&[_]u8{ 1, 2 }, "application/octet-stream"));
    try std.testing.expectEqual(@as(u32, 0), ctx.bin_seq);
}

test "Worker names the documented offload shape" {
    // DOCUMENTATION-ONLY type: nothing in the framework instantiates it, so this
    // reference forces semantic analysis of the Sink(P) + ComputeError!P
    // composition (Zig only analyzes referenced decls).
    const Args = struct { path: []const u8 };
    const W = compute.Worker(Args, Pct);
    try std.testing.expectEqual(*const fn (Args, compute.Sink(Pct), compute.CancelToken) compute.ComputeError!Pct, W);
}
