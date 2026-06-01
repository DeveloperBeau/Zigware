const std = @import("std");
const demo = @import("commands/demo.zig");
const sha = @import("commands/sha256.zig");

// ─── Public API types ─────────────────────────────────────────────────────────

pub const Events = struct {
    ctx: *anyopaque,
    onProgress: *const fn (ctx: *anyopaque, id: u64, pct: u8) void,
    onResolve: *const fn (ctx: *anyopaque, id: u64, hex: []const u8) void,
    onReject: *const fn (ctx: *anyopaque, id: u64, msg: []const u8) void,
};

pub const Job = struct { id: u64, megabytes: usize };

pub const PoolOptions = struct {
    workers: usize,
    max_queue: usize,
    /// The Io instance to use for mutex/condition operations. Pass
    /// `std.testing.io` in tests; pass your production Io in normal use.
    io: std.Io,
};

// ─── Pool ─────────────────────────────────────────────────────────────────────

pub const Pool = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    events: Events,
    threads: []std.Thread,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    idle_cond: std.Io.Condition = .init,
    queue: std.ArrayList(Job) = .empty,
    /// Number of jobs that are queued OR currently running.
    /// Guarded by mutex everywhere except the idle-wait loop which also
    /// holds the mutex.
    inflight: usize = 0,
    max_queue: usize,
    shutdown: bool = false,
    /// Checked lock-free by hashBuffer between 64 KB chunks.
    /// Written under mutex in deinit before broadcast — sequenced safely.
    cancel_all: std.atomic.Value(bool) = .{ .raw = false },

    pub fn init(alloc: std.mem.Allocator, opts: PoolOptions, events: Events) !*Pool {
        const self = try alloc.create(Pool);
        self.* = .{
            .alloc = alloc,
            .io = opts.io,
            .events = events,
            .threads = try alloc.alloc(std.Thread, opts.workers),
            .max_queue = opts.max_queue,
        };
        // Spawn workers after the struct is fully initialised so they see a
        // consistent view immediately.
        for (self.threads) |*t| {
            t.* = try std.Thread.spawn(.{}, worker, .{self});
        }
        return self;
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        // Signal cancel so in-flight hashBuffer returns error.Cancelled quickly.
        self.cancel_all.store(true, .release);
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);

        for (self.threads) |t| t.join();

        self.queue.deinit(self.alloc);
        self.alloc.free(self.threads);
        const a = self.alloc;
        a.destroy(self);
    }

    /// Enqueue a job. Returns error.QueueFull when the bounded cap is reached.
    pub fn submit(self: *Pool, job: Job) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.inflight >= self.max_queue) return error.QueueFull;
        try self.queue.append(self.alloc, job);
        self.inflight += 1;
        self.cond.signal(self.io);
    }

    /// Block until every submitted job has finished (resolved or rejected).
    pub fn waitIdle(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.inflight != 0) {
            self.idle_cond.waitUncancelable(self.io, &self.mutex);
        }
    }

    // ── Worker goroutine ────────────────────────────────────────────────────

    fn worker(self: *Pool) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            // Wait until there is work or a shutdown request.
            while (self.queue.items.len == 0 and !self.shutdown) {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
            // Shutdown with nothing left to process → exit.
            if (self.shutdown and self.queue.items.len == 0) {
                self.mutex.unlock(self.io);
                return;
            }
            const job = self.queue.orderedRemove(0);
            self.mutex.unlock(self.io);

            // Execute the job outside the lock so other workers run in parallel.
            run(self, job);

            self.mutex.lockUncancelable(self.io);
            self.inflight -= 1;
            if (self.inflight == 0) self.idle_cond.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
    }

    // ── Job execution ───────────────────────────────────────────────────────

    fn run(self: *Pool, job: Job) void {
        const Ctx = struct { pool: *Pool, id: u64 };
        var ctx = Ctx{ .pool = self, .id = job.id };
        const prog = sha.Progress{
            .ctx = &ctx,
            .func = struct {
                fn f(c: *anyopaque, pct: u8) void {
                    const x: *Ctx = @ptrCast(@alignCast(c));
                    x.pool.events.onProgress(x.pool.events.ctx, x.id, pct);
                }
            }.f,
        };
        const digest = demo.hashGenerated(
            self.alloc,
            job.megabytes,
            prog,
            &self.cancel_all,
        ) catch |err| {
            const msg: []const u8 = switch (err) {
                error.Cancelled => "cancelled",
                error.OutOfMemory => "out of memory",
            };
            self.events.onReject(self.events.ctx, job.id, msg);
            return;
        };
        self.events.onResolve(self.events.ctx, job.id, &digest);
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "submitted job runs, reports progress, completes once" {
    var sink = TestEvents.init(std.testing.allocator);
    defer sink.deinit();
    var pool = try Pool.init(
        std.testing.allocator,
        .{ .workers = 2, .max_queue = 16, .io = std.testing.io },
        sink.handler(),
    );
    defer pool.deinit();

    try pool.submit(.{ .id = 1, .megabytes = 1 });
    pool.waitIdle();

    try std.testing.expect(sink.resolves == 1);
    try std.testing.expect(sink.progressCalls >= 1);
    try std.testing.expect(sink.lastPct == 100);
}

test "many jobs all resolve within bounded workers" {
    var sink = TestEvents.init(std.testing.allocator);
    defer sink.deinit();
    var pool = try Pool.init(
        std.testing.allocator,
        .{ .workers = 3, .max_queue = 256, .io = std.testing.io },
        sink.handler(),
    );
    defer pool.deinit();
    var i: u64 = 0;
    while (i < 200) : (i += 1) try pool.submit(.{ .id = i, .megabytes = 1 });
    pool.waitIdle();
    try std.testing.expectEqual(@as(usize, 200), sink.resolves);
}

test "submit returns QueueFull at the cap" {
    var sink = TestEvents.init(std.testing.allocator);
    defer sink.deinit();
    // 0 workers so jobs never drain; everything stacks on the queue.
    var pool = try Pool.init(
        std.testing.allocator,
        .{ .workers = 0, .max_queue = 4, .io = std.testing.io },
        sink.handler(),
    );
    defer pool.deinit();
    try pool.submit(.{ .id = 1, .megabytes = 1 });
    try pool.submit(.{ .id = 2, .megabytes = 1 });
    try pool.submit(.{ .id = 3, .megabytes = 1 });
    try pool.submit(.{ .id = 4, .megabytes = 1 });
    try std.testing.expectError(error.QueueFull, pool.submit(.{ .id = 5, .megabytes = 1 }));
}

test "fuzz: submission storms never leak or deadlock" {
    try std.testing.fuzz({}, fuzzStorm, .{});
}

fn fuzzStorm(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const n = smith.slice(&buf);
    var sink = TestEvents.init(std.testing.allocator);
    defer sink.deinit();
    var pool = try Pool.init(
        std.testing.allocator,
        .{ .workers = 2, .max_queue = 64, .io = std.testing.io },
        sink.handler(),
    );
    defer pool.deinit();
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        pool.submit(.{ .id = i, .megabytes = 1 }) catch {}; // QueueFull expected at cap
    }
    pool.waitIdle();
}

// ─── TestEvents helper ────────────────────────────────────────────────────────

const TestEvents = struct {
    // All fields guarded by mutex; mutex itself uses Io.Mutex.
    // We cannot use Io.Mutex here without an io instance, so we use
    // a simple atomic-flag spinlock for the test-only sink.
    // Actually, to keep it simple we use a plain uncontended seqlock via
    // atomic ops, because test callbacks are short and non-nested.
    //
    // Better: use a raw spinlock since this is test-only and always
    // uncontended for long periods.
    lock_flag: std.atomic.Value(bool) = .{ .raw = false },
    resolves: usize = 0,
    progressCalls: usize = 0,
    lastPct: u8 = 0,
    alloc: std.mem.Allocator,

    fn init(a: std.mem.Allocator) TestEvents { return .{ .alloc = a }; }
    fn deinit(_: *TestEvents) void {}

    fn acquire(self: *TestEvents) void {
        while (self.lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn release(self: *TestEvents) void {
        self.lock_flag.store(false, .release);
    }

    fn onProgress(self: *TestEvents, _: u64, pct: u8) void {
        self.acquire(); defer self.release();
        self.progressCalls += 1; self.lastPct = pct;
    }
    fn onResolve(self: *TestEvents, _: u64, _: []const u8) void {
        self.acquire(); defer self.release();
        self.resolves += 1;
    }
    fn onReject(_: *TestEvents, _: u64, _: []const u8) void {}
    fn handler(self: *TestEvents) Events {
        return .{
            .ctx = self,
            .onProgress = struct {
                fn f(c: *anyopaque, id: u64, p: u8) void {
                    onProgress(@ptrCast(@alignCast(c)), id, p);
                }
            }.f,
            .onResolve = struct {
                fn f(c: *anyopaque, id: u64, h: []const u8) void {
                    onResolve(@ptrCast(@alignCast(c)), id, h);
                }
            }.f,
            .onReject = struct {
                fn f(c: *anyopaque, id: u64, m: []const u8) void {
                    onReject(@ptrCast(@alignCast(c)), id, m);
                }
            }.f,
        };
    }
};
