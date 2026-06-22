const std = @import("std");

/// Captured outcome of a child process. `stdout`/`stderr` are gpa-owned (freed by the
/// caller with `gpa.free`). The fields are `[]const u8`: `std.process.run` returns `[]u8`
/// which const-widens on assignment, and `FakeRunner` returns gpa-owned `[]const u8`
/// copies; both runners yield the same const-typed, gpa-owned slices the stages free
/// uniformly.
pub const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
};

/// The runner's narrow, pure-domain error set. Wider than a 2-variant set on purpose so
/// output truncation (`StreamTooLong`) and timeouts do not collapse silently onto a
/// generic spawn failure (Locked decision #5: those must not be lost).
pub const RunError = error{
    SpawnFailed,
    OutputTooLong,
    Timeout,
    OutOfMemory,
};

/// Runtime fn-ptr seam over child-process execution (mirrors F's `BuildRunner`). Every
/// `codesign`/`notarytool`/`hdiutil`/`stapler` call in the pipeline goes through this so
/// the whole thing is headless-testable via `FakeRunner`.
pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const []const u8) RunError!RunResult,

    pub fn run(
        self: Runner,
        io: std.Io,
        gpa: std.mem.Allocator,
        argv: []const []const u8,
    ) RunError!RunResult {
        return self.runFn(self.ctx, io, gpa, argv);
    }
};

/// Production runner over `std.process.run` (full stdout+stderr capture with a timeout).
/// The limits and timeout are FIELDS, not hardcoded inside `run`, so tests can drive the
/// `StreamTooLong`/`Timeout` mappings with tiny values while production keeps generous
/// bounds (notarytool output is otherwise unbounded).
pub const SystemRunner = struct {
    stdout_limit: std.Io.Limit = .limited(64 * 1024 * 1024),
    stderr_limit: std.Io.Limit = .limited(64 * 1024 * 1024),
    timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromNanoseconds(30 * 60 * std.time.ns_per_s) } },

    pub fn runner(self: *SystemRunner) Runner {
        return .{ .ctx = self, .runFn = run };
    }

    fn run(
        ctx: *anyopaque,
        io: std.Io,
        gpa: std.mem.Allocator,
        argv: []const []const u8,
    ) RunError!RunResult {
        const self: *SystemRunner = @ptrCast(@alignCast(ctx));
        // `gpa` and `io` are POSITIONAL; RunOptions has no `.allocator` field. Map the std
        // RunError explicitly so truncation and timeouts keep their own domain variants;
        // everything else (SpawnError / MultiReader.UnendingError) falls through to else.
        // No logging here: error mapping only (the no-secret-in-logs rule covers this seam).
        const result = std.process.run(gpa, io, .{
            .argv = argv,
            .stdout_limit = self.stdout_limit,
            .stderr_limit = self.stderr_limit,
            .timeout = self.timeout,
        }) catch |e| switch (e) {
            error.StreamTooLong => return error.OutputTooLong,
            error.Timeout => return error.Timeout,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SpawnFailed,
        };
        return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
    }
};

/// Record-and-drive fake (mirrors A's NullBackend discipline). Records every argv in order
/// and returns the next scripted result. Internal storage (the argv log and the scripted
/// queue) uses the init allocator; returned stdout/stderr are duped via the `run` gpa so
/// the caller's free is uniform with `SystemRunner`.
pub const FakeRunner = struct {
    gpa: std.mem.Allocator,
    scripted: std.ArrayList(RunResult) = .empty,
    next: usize = 0,
    argv_log: std.ArrayList([]const []const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) FakeRunner {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FakeRunner) void {
        for (self.argv_log.items) |logged| {
            for (logged) |arg| self.gpa.free(arg);
            self.gpa.free(logged);
        }
        self.argv_log.deinit(self.gpa);
        // Any scripted results never consumed still own duped stdout/stderr copies.
        for (self.scripted.items[self.next..]) |r| {
            self.gpa.free(r.stdout);
            self.gpa.free(r.stderr);
        }
        self.scripted.deinit(self.gpa);
    }

    /// Queue one scripted outcome. The provided stdout/stderr are duped into the fake's
    /// arena so callers may pass string literals; `run` re-dupes them for the caller.
    pub fn push(self: *FakeRunner, result: RunResult) !void {
        const out = try self.gpa.dupe(u8, result.stdout);
        errdefer self.gpa.free(out);
        const err = try self.gpa.dupe(u8, result.stderr);
        errdefer self.gpa.free(err);
        try self.scripted.append(self.gpa, .{ .term = result.term, .stdout = out, .stderr = err });
    }

    pub fn runner(self: *FakeRunner) Runner {
        return .{ .ctx = self, .runFn = run };
    }

    fn run(
        ctx: *anyopaque,
        io: std.Io,
        gpa: std.mem.Allocator,
        argv: []const []const u8,
    ) RunError!RunResult {
        _ = io;
        const self: *FakeRunner = @ptrCast(@alignCast(ctx));

        // Deep-dup the argv into the fake's own arena so the log outlives the caller's slice.
        const logged = self.gpa.alloc([]const u8, argv.len) catch return error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (logged[0..filled]) |arg| self.gpa.free(arg);
            self.gpa.free(logged);
        }
        for (argv, 0..) |arg, i| {
            logged[i] = self.gpa.dupe(u8, arg) catch return error.OutOfMemory;
            filled = i + 1;
        }
        self.argv_log.append(self.gpa, logged) catch return error.OutOfMemory;

        std.debug.assert(self.next < self.scripted.items.len); // script underrun is a test bug
        const scripted = self.scripted.items[self.next];
        self.next += 1;

        // Hand the caller gpa-owned copies, then release the consumed arena originals so the
        // fake owns nothing for an already-driven entry (deinit only sweeps the unconsumed
        // tail). The caller frees its copies uniformly regardless of which runner ran.
        const out = gpa.dupe(u8, scripted.stdout) catch return error.OutOfMemory;
        errdefer gpa.free(out);
        const err = gpa.dupe(u8, scripted.stderr) catch return error.OutOfMemory;
        self.gpa.free(scripted.stdout);
        self.gpa.free(scripted.stderr);
        return .{ .term = scripted.term, .stdout = out, .stderr = err };
    }
};

test "FakeRunner records argv in order and returns scripted results" {
    var fr = FakeRunner.init(std.testing.allocator);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "ok", .stderr = "" });
    var runner = fr.runner();
    const r = try runner.run(std.testing.io, std.testing.allocator, &.{ "codesign", "--sign", "X" });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expectEqualStrings("ok", r.stdout);
    try std.testing.expectEqual(@as(usize, 1), fr.argv_log.items.len);
    try std.testing.expectEqualStrings("codesign", fr.argv_log.items[0][0]);
}

test "SystemRunner maps StreamTooLong to OutputTooLong" {
    var sr = SystemRunner{ .stdout_limit = .limited(16) };
    var runner = sr.runner();
    const r = runner.run(std.testing.io, std.testing.allocator, &.{ "sh", "-c", "head -c 100000 /dev/zero" });
    try std.testing.expectError(error.OutputTooLong, r);
}

test "SystemRunner maps a timeout to Timeout" {
    var sr = SystemRunner{ .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromNanoseconds(std.time.ns_per_ms) } } };
    var runner = sr.runner();
    const r = runner.run(std.testing.io, std.testing.allocator, &.{ "sh", "-c", "sleep 1" });
    try std.testing.expectError(error.Timeout, r);
}

test "SystemRunner maps a spawn failure to SpawnFailed" {
    var sr = SystemRunner{};
    var runner = sr.runner();
    const r = runner.run(std.testing.io, std.testing.allocator, &.{"/nonexistent/zzz"});
    try std.testing.expectError(error.SpawnFailed, r);
}
