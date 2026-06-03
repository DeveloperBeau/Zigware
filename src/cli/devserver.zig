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
    _ = io;
    _ = gpa;
    _ = url;
    _ = opts;
    _ = shutdown;
    return error.NotImplemented;
}
