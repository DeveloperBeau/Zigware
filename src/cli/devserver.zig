const std = @import("std");

pub const WaitOptions = struct {
    timeout_ms: u32 = 30_000,
    poll_interval_ms: u32 = 200,
};

/// Polls `url` with HTTP GET + backoff until it answers (any status < 500) or the timeout elapses.
/// Returns error.dev_url_timeout (mapped to CliError by the caller) on timeout.
/// `shutdown` is polled each backoff interval: when it is set, waitForUrl returns
/// error.dev_url_timeout immediately (the caller treats that as "exit -> teardown")
/// so a SIGINT during the up-to-30s wait does not strand the dev loop. No new CliError
/// variant is introduced; the stage-gate shutdown check in dev.run routes to teardown.
pub fn waitForUrl(io: std.Io, gpa: std.mem.Allocator, url: []const u8, opts: WaitOptions, shutdown: *std.atomic.Value(bool)) anyerror!void {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const start = std.Io.Timestamp.now(io, .awake);
    const deadline = start.addDuration(.fromMilliseconds(opts.timeout_ms));

    while (true) {
        // Stage-gate the shutdown flag at the top of every iteration: a SIGINT
        // during the wait must unwind to teardown, not stall here.
        if (shutdown.load(.seq_cst)) return error.dev_url_timeout;
        if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds)
            return error.dev_url_timeout;

        const result = client.fetch(.{ .location = .{ .url = url } }) catch |err| switch (err) {
            // A cancelation request (SIGINT-driven teardown elsewhere in the
            // process) surfaces here as Canceled: treat it as a shutdown
            // recheck rather than a propagated error.
            error.Canceled => return error.dev_url_timeout,
            // Any other fetch failure (connection refused, DNS, reset, a
            // half-up server) means "not ready yet" -> back off and retry.
            else => {
                try backoff(io, opts.poll_interval_ms, deadline, shutdown);
                continue;
            },
        };

        // The server answered. Anything below 500 means it is serving (4xx is
        // still "up" for our purposes); 5xx means it is starting but not ready.
        if (@intFromEnum(result.status) < 500) return;

        try backoff(io, opts.poll_interval_ms, deadline, shutdown);
    }
}

/// Sleep up to `interval_ms`, sliced so the shutdown flag and the overall
/// deadline are re-observed promptly. Returns error.dev_url_timeout when the
/// shutdown flag flips or the deadline passes mid-sleep so the caller exits
/// straight to teardown instead of finishing a full interval.
fn backoff(io: std.Io, interval_ms: u32, deadline: std.Io.Timestamp, shutdown: *std.atomic.Value(bool)) error{dev_url_timeout}!void {
    // Slice the interval so a SIGINT mid-sleep is observed within ~slice_ms.
    const slice_ms: u32 = 25;
    var slept: u32 = 0;
    while (slept < interval_ms) {
        if (shutdown.load(.seq_cst)) return error.dev_url_timeout;
        if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds)
            return error.dev_url_timeout;

        const remaining = interval_ms - slept;
        const chunk = @min(slice_ms, remaining);
        io.sleep(.fromMilliseconds(chunk), .awake) catch |err| switch (err) {
            // A cancelation point during the sleep -> bail to teardown.
            error.Canceled => return error.dev_url_timeout,
        };
        slept += chunk;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// One-shot loopback server: accept a single connection, drain the request
/// line/headers up to the blank line, and write a bare 200 OK with an empty
/// body. Driven via io.concurrent so it makes progress while waitForUrl blocks
/// in fetch on the same thread.
fn oneShot200(io: std.Io, server: *std.Io.net.Server) void {
    var stream = server.accept(io) catch return;
    defer stream.close(io);

    // Drain the inbound request so the client's write completes cleanly. We do
    // not need to parse it; read until we see the header terminator or the
    // peer stops sending.
    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    _ = reader.interface.takeDelimiterExclusive('\n') catch {};

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch return;
    writer.interface.flush() catch return;
}

test "waitForUrl returns when a loopback server answers 200" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    const port = server.socket.address.getPort();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    // Run the accept/respond on a concurrent task so it progresses while the
    // main task blocks inside fetch. concurrent (not async) is required: async
    // may defer the task until await, which would deadlock the fetch.
    var server_future = try io.concurrent(oneShot200, .{ io, &server });
    defer _ = server_future.await(io);

    var shut = std.atomic.Value(bool).init(false);
    try waitForUrl(io, testing.allocator, url, .{ .timeout_ms = 5_000, .poll_interval_ms = 50 }, &shut);
}

test "waitForUrl times out against a closed port" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Port 1 on loopback is reserved/closed; connections are refused fast, so
    // the backoff loop runs to the (short) deadline and returns the timeout.
    var shut = std.atomic.Value(bool).init(false);
    const result = waitForUrl(io, testing.allocator, "http://127.0.0.1:1/", .{ .timeout_ms = 300, .poll_interval_ms = 50 }, &shut);
    try testing.expectError(error.dev_url_timeout, result);
}

test "waitForUrl short-circuits when shutdown is set" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A long timeout against a closed port; with shutdown pre-set, the loop
    // must return on the first shutdown check, well before the deadline.
    var shut = std.atomic.Value(bool).init(true);
    const start = std.Io.Timestamp.now(io, .awake);
    const result = waitForUrl(io, testing.allocator, "http://127.0.0.1:1/", .{ .timeout_ms = 30_000, .poll_interval_ms = 200 }, &shut);
    const elapsed_ms = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();

    try testing.expectError(error.dev_url_timeout, result);
    // Returned promptly: nowhere near the 30s timeout.
    try testing.expect(elapsed_ms < 1_000);
}
