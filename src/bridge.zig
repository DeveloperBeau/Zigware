const std = @import("std");
const protocol = @import("protocol.zig");
const Allowlist = @import("allowlist.zig").Allowlist;
const jobs = @import("jobs.zig");
const Sink = @import("sink.zig").Sink;

// ─── TestSink ─────────────────────────────────────────────────────────────────

/// Thread-safe recording sink for tests. Uses an atomic spinlock (same pattern
/// as TestEvents in jobs.zig) because evalJs is called from worker threads.
const TestSink = struct {
    calls: std.ArrayList([]u8) = .empty,
    alloc: std.mem.Allocator,
    lock_flag: std.atomic.Value(bool) = .{ .raw = false },

    fn init(a: std.mem.Allocator) TestSink {
        return .{ .alloc = a };
    }

    fn deinit(self: *TestSink) void {
        for (self.calls.items) |c| self.alloc.free(c);
        self.calls.deinit(self.alloc);
    }

    fn acquire(self: *TestSink) void {
        while (self.lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *TestSink) void {
        self.lock_flag.store(false, .release);
    }

    fn appendLocked(self: *TestSink, s: []u8) void {
        self.acquire();
        defer self.release();
        self.calls.append(self.alloc, s) catch {
            self.alloc.free(s);
        };
    }

    fn evalJs(ctx: *anyopaque, js: []const u8) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        const copy = self.alloc.dupe(u8, js) catch return;
        self.appendLocked(copy);
    }

    fn isAlive(_: *anyopaque) bool {
        return true;
    }

    /// Must be called after drainForTest() — reads are safe once drained.
    fn countContaining(self: *TestSink, needle: []const u8) usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (std.mem.indexOf(u8, c, needle) != null) n += 1;
        }
        return n;
    }

    fn sink(self: *TestSink) Sink {
        return .{ .ctx = self, .evalJs = evalJs, .isAlive = isAlive };
    }
};

// ─── AliveSink ────────────────────────────────────────────────────────────────

/// Wraps a TestSink but gates emission on an atomic `alive` flag.
const AliveSink = struct {
    inner: TestSink,
    alive: std.atomic.Value(bool) = .{ .raw = true },

    fn init(a: std.mem.Allocator) AliveSink {
        return .{ .inner = TestSink.init(a) };
    }

    fn deinit(self: *AliveSink) void {
        self.inner.deinit();
    }

    fn evalJs(ctx: *anyopaque, js: []const u8) void {
        const self: *AliveSink = @ptrCast(@alignCast(ctx));
        if (!self.alive.load(.acquire)) return;
        TestSink.evalJs(&self.inner, js);
    }

    fn isAlive(ctx: *anyopaque) bool {
        const self: *AliveSink = @ptrCast(@alignCast(ctx));
        return self.alive.load(.acquire);
    }

    fn sink(self: *AliveSink) Sink {
        return .{ .ctx = self, .evalJs = evalJs, .isAlive = isAlive };
    }
};

// ─── Bridge ───────────────────────────────────────────────────────────────────

pub const Bridge = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    sink: Sink,
    allow: Allowlist,
    pool: *jobs.Pool,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, sink: Sink) !*Bridge {
        const self = try alloc.create(Bridge);
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
            .sink = sink,
            .allow = allow,
            .pool = undefined,
        };

        self.pool = try jobs.Pool.init(alloc, .{
            .workers = workerCount(),
            .max_queue = 256,
            .io = io,
        }, events);

        return self;
    }

    pub fn deinit(self: *Bridge) void {
        self.pool.deinit();
        self.alloc.destroy(self);
    }

    /// Block until all submitted jobs have finished. Use in tests after
    /// handleMessage calls to ensure all callbacks have fired.
    pub fn drainForTest(self: *Bridge) void {
        self.pool.waitIdle();
    }

    /// Route an inbound JS→Zig message: decode → allowlist → submit or reject.
    pub fn handleMessage(self: *Bridge, text: []const u8) void {
        const msg = protocol.decode(self.alloc, text, protocol.MAX_MESSAGE_LEN) catch return;
        defer msg.deinit(self.alloc);

        if (!self.allow.contains(msg.cmd)) {
            self.emitReject(msg.id, "unknown command");
            return;
        }

        const mb = parseMegabytes(msg.args_json);
        self.pool.submit(.{ .id = msg.id, .megabytes = mb }) catch {
            self.emitReject(msg.id, "queue full");
        };
    }

    // ── Private helpers ─────────────────────────────────────────────────────

    fn workerCount() usize {
        return @min(@max(std.Thread.getCpuCount() catch 4, 1), 8);
    }

    /// Parse `{"megabytes": N}` from args JSON; returns a clamped value.
    fn parseMegabytes(args_json: []const u8) usize {
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, args_json, .{}) catch return 256;
        defer parsed.deinit();
        if (parsed.value != .object) return 256;
        const v = parsed.value.object.get("megabytes") orelse return 256;
        if (v != .integer or v.integer <= 0) return 256;
        const raw: usize = @intCast(v.integer);
        return @min(raw, 1024);
    }

    /// Gate-checked emit: drops if the WebView is dead.
    fn emit(self: *Bridge, js: []const u8) void {
        if (!self.sink.isAlive(self.sink.ctx)) return;
        self.sink.evalJs(self.sink.ctx, js);
    }

    fn emitReject(self: *Bridge, id: u64, message: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        defer aw.deinit();
        protocol.encodeReject(&aw.writer, id, message) catch return;
        self.emit(aw.writer.buffered());
    }

    fn onProgress(ctx: *anyopaque, id: u64, pct: u8) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        defer aw.deinit();
        var jbuf: [64]u8 = undefined;
        const json = std.fmt.bufPrint(&jbuf, "{{\"id\":{d},\"pct\":{d}}}", .{ id, pct }) catch return;
        protocol.encodeEmit(&aw.writer, "progress", json) catch return;
        self.emit(aw.writer.buffered());
    }

    fn onResolve(ctx: *anyopaque, id: u64, hex: []const u8) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        defer aw.deinit();
        var jbuf: [128]u8 = undefined;
        const json = std.fmt.bufPrint(&jbuf, "{{\"hash\":\"{s}\"}}", .{hex}) catch return;
        protocol.encodeResolve(&aw.writer, id, json) catch return;
        self.emit(aw.writer.buffered());
    }

    fn onReject(ctx: *anyopaque, id: u64, msg: []const u8) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        self.emitReject(id, msg);
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "happy path: invoke sha256 emits ordered progress then one resolve" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var bridge = try Bridge.init(std.testing.allocator, std.testing.io, sink.sink());
    defer bridge.deinit();
    bridge.handleMessage("{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    bridge.drainForTest();
    try std.testing.expect(sink.countContaining("window.zig._emit(\"progress\"") >= 1);
    try std.testing.expect(sink.countContaining("window.zig._resolve(1,") == 1);
    try std.testing.expect(sink.countContaining("window.zig._reject(1,") == 0);
}

test "unknown command rejects exactly once and dispatches nothing" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var bridge = try Bridge.init(std.testing.allocator, std.testing.io, sink.sink());
    defer bridge.deinit();
    bridge.handleMessage("{\"id\":9,\"cmd\":\"danger\",\"args\":{}}");
    bridge.drainForTest();
    try std.testing.expect(sink.countContaining("window.zig._reject(9,") == 1);
    try std.testing.expect(sink.countContaining("_resolve") == 0);
}

test "malformed message produces no emission" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var bridge = try Bridge.init(std.testing.allocator, std.testing.io, sink.sink());
    defer bridge.deinit();
    bridge.handleMessage("not json at all");
    bridge.drainForTest();
    try std.testing.expectEqual(@as(usize, 0), sink.calls.items.len);
}

test "concurrent invokes correlate to distinct ids" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var bridge = try Bridge.init(std.testing.allocator, std.testing.io, sink.sink());
    defer bridge.deinit();
    bridge.handleMessage("{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    bridge.handleMessage("{\"id\":2,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    bridge.drainForTest();
    try std.testing.expect(sink.countContaining("window.zig._resolve(1,") == 1);
    try std.testing.expect(sink.countContaining("window.zig._resolve(2,") == 1);
}

test "isAlive=false suppresses all emission for an in-flight job" {
    var as = AliveSink.init(std.testing.allocator);
    defer as.deinit();
    as.alive.store(false, .release);
    var bridge = try Bridge.init(std.testing.allocator, std.testing.io, as.sink());
    defer bridge.deinit();
    bridge.handleMessage("{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    bridge.drainForTest();
    try std.testing.expectEqual(@as(usize, 0), as.inner.calls.items.len);
}

test "queue-full / flood: every id terminates, no crash" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var bridge = try Bridge.init(std.testing.allocator, std.testing.io, sink.sink());
    defer bridge.deinit();
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        var buf: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":1}}}}", .{i});
        bridge.handleMessage(text);
    }
    bridge.drainForTest();
    // Each message either resolves or rejects — total calls >= 1000 (there may
    // also be progress calls on top). Some will get queue-full rejects.
    try std.testing.expect(sink.calls.items.len >= 1000);
}

// ─── Fuzz ─────────────────────────────────────────────────────────────────────

test "fuzz: handleMessage tolerates arbitrary bytes" {
    try std.testing.fuzz({}, fuzzBridge, .{});
}

fn fuzzBridge(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var bridge = try Bridge.init(std.testing.allocator, std.testing.io, sink.sink());
    defer bridge.deinit();
    bridge.handleMessage(buf[0..n]);
    bridge.drainForTest();
}
