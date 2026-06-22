const std = @import("std");

/// A unit of work. The pool owns nothing inside `ctx`; the submitter heap-allocates
/// it and the thunk frees it (the thunk is the only code that knows ctx's real type).
/// `run` is called on a worker thread with the pool's shared cancel flag. The thunk
/// must perform its own resolve/reject by calling back into the submitter's state,
/// which it captured inside `ctx`.
pub const Job = struct {
    /// Caller-side correlation/diagnostics handle. The pool does NOT read it
    /// (the worker only invokes `run`); callers that need to tie a job back to
    /// a request id set it here. The bridge also captures its own id inside the
    /// thunk's ctx, so this is purely for the submitter's own bookkeeping.
    id: u64,
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, cancel: *std.atomic.Value(bool)) void,
};

pub const PoolOptions = struct {
    workers: usize,
    max_queue: usize,
    /// The Io instance to use for mutex/condition operations. Pass
    /// `std.testing.io` in tests; pass your production Io in normal use.
    io: std.Io,
};

pub const Pool = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
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
    /// Checked lock-free by the hashing loop between 64 KB chunks.
    /// Written under mutex in deinit before broadcast. The `.release` store
    /// is correctly sequenced with the mutex unlock that follows.
    cancel_all: std.atomic.Value(bool) = .{ .raw = false },

    pub fn init(alloc: std.mem.Allocator, opts: PoolOptions) !*Pool {
        const self = try alloc.create(Pool);
        errdefer alloc.destroy(self);
        const threads = try alloc.alloc(std.Thread, opts.workers);
        errdefer alloc.free(threads);
        self.* = .{
            .alloc = alloc,
            .io = opts.io,
            .threads = threads,
            .max_queue = opts.max_queue,
        };
        // Spawn workers after the struct is fully initialised so they see a
        // consistent view immediately. If a later spawn fails, signal shutdown
        // and join the workers already spawned so no thread is orphaned and the
        // Pool/threads allocations unwind cleanly (no leak, no double-join).
        var spawned: usize = 0;
        errdefer {
            self.mutex.lockUncancelable(self.io);
            self.shutdown = true;
            self.cancel_all.store(true, .release);
            self.cond.broadcast(self.io);
            self.mutex.unlock(self.io);
            for (self.threads[0..spawned]) |t| t.join();
            self.queue.deinit(self.alloc);
        }
        while (spawned < self.threads.len) : (spawned += 1) {
            self.threads[spawned] = try std.Thread.spawn(.{}, worker, .{self});
        }
        return self;
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.cancel_all.store(true, .release);
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
        for (self.threads) |t| t.join();
        self.queue.deinit(self.alloc);
        self.alloc.free(self.threads);
        const a = self.alloc;
        a.destroy(self);
    }

    pub fn submit(self: *Pool, job: Job) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.inflight >= self.max_queue) return error.QueueFull;
        try self.queue.append(self.alloc, job);
        self.inflight += 1;
        self.cond.signal(self.io);
    }

    pub fn waitIdle(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.inflight != 0) {
            self.idle_cond.waitUncancelable(self.io, &self.mutex);
        }
    }

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

            job.run(job.ctx, &self.cancel_all);

            self.mutex.lockUncancelable(self.io);
            self.inflight -= 1;
            if (self.inflight == 0) self.idle_cond.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

const TestWork = struct {
    resolves: std.atomic.Value(usize) = .{ .raw = 0 },
    fn run(ctx: *anyopaque, _: *std.atomic.Value(bool)) void {
        const self: *TestWork = @ptrCast(@alignCast(ctx));
        _ = self.resolves.fetchAdd(1, .monotonic);
    }
};

test "submitted thunk runs exactly once" {
    var w = TestWork{};
    var pool = try Pool.init(std.testing.allocator, .{ .workers = 2, .max_queue = 16, .io = std.testing.io });
    defer pool.deinit();
    try pool.submit(.{ .id = 1, .ctx = &w, .run = TestWork.run });
    pool.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), w.resolves.load(.monotonic));
}

test "many thunks all run within bounded workers" {
    var w = TestWork{};
    var pool = try Pool.init(std.testing.allocator, .{ .workers = 3, .max_queue = 256, .io = std.testing.io });
    defer pool.deinit();
    var i: u64 = 0;
    while (i < 200) : (i += 1) try pool.submit(.{ .id = i, .ctx = &w, .run = TestWork.run });
    pool.waitIdle();
    try std.testing.expectEqual(@as(usize, 200), w.resolves.load(.monotonic));
}

test "submit returns QueueFull at the cap" {
    var w = TestWork{};
    var pool = try Pool.init(std.testing.allocator, .{ .workers = 0, .max_queue = 4, .io = std.testing.io });
    defer pool.deinit();
    var i: u64 = 0;
    while (i < 4) : (i += 1) try pool.submit(.{ .id = i, .ctx = &w, .run = TestWork.run });
    try std.testing.expectError(error.QueueFull, pool.submit(.{ .id = i, .ctx = &w, .run = TestWork.run }));
}

test "fuzz: submission storms never leak or deadlock" {
    try std.testing.fuzz({}, fuzzStorm, .{});
}

fn fuzzStorm(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const n = smith.slice(&buf);
    var w = TestWork{};
    var pool = try Pool.init(std.testing.allocator, .{ .workers = 2, .max_queue = 64, .io = std.testing.io });
    defer pool.deinit();
    var i: u64 = 0;
    while (i < n) : (i += 1) pool.submit(.{ .id = i, .ctx = &w, .run = TestWork.run }) catch {};
    pool.waitIdle();
}
