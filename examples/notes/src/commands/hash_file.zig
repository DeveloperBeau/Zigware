//! The notes example's one app command: hash a file on the worker pool with
//! streamed progress and cooperative cancellation.
//!
//! C gates `path` at G4 BEFORE this handler runs: the bridge extracts the `path`
//! arg from the same args_json this handler decodes and checks it against the
//! capability's `$APPDATA/notes/**` scope. A denied request never reaches here.
//!
//! The handler builds its `Sink` from its own `*Ctx` via the comptime projector
//! `z.Sink(Pct).from(ctx)` (Pct is the PROGRESS frame, distinct from the success
//! payload `Out`), reads the file in 64 KiB chunks, streams integer-percent
//! progress, and returns the hex SHA-256 digest. Between chunks it polls
//! `sink.isCancelled()` and bails with a `cancelled` reject when the per-id flag
//! or the process shutdown flag is set.

const std = @import("std");
const z = @import("zigware");
const State = @import("../app_state.zig").State;

/// The handler's success payload. A nominal struct so the `Result(Out)` return
/// coerces (a fresh `struct {...}` literal per site would be a distinct type).
const Out = struct { hash: []const u8 };

/// The progress-frame type fed to `Sink(Pct)`. DISTINCT from `Out`: progress
/// frames carry a percent, the terminal result carries the digest.
const Pct = struct { pct: u8 };

/// 64 KiB read window. Bounds the per-chunk arena allocation and gives the
/// cancel poll a tight cadence on large files.
const CHUNK: usize = 64 * 1024;

pub fn hashFile(ctx: *z.Ctx(State), args: struct { path: []const u8 }) z.Async(z.Result(Out)) {
    const sink = z.Sink(Pct).from(ctx);

    // The handler runs on a worker thread with no Ctx-threaded io, so it owns a
    // blocking io for the file read. No async is used (plain reads), so a failing
    // allocator backs the async paths that never fire. deinit before return.
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The gate already validated `path` against the scope; open the SAME bytes it
    // checked (check-vs-use parity: the handler opens the value G4 saw).
    var file = std.Io.Dir.cwd().openFile(io, args.path, .{}) catch {
        return z.done(z.Result(Out){ .err = .{ .code = "io_error", .message = "could not open file" } });
    };
    defer file.close(io);

    const st = file.stat(io) catch {
        return z.done(z.Result(Out){ .err = .{ .code = "io_error", .message = "could not stat file" } });
    };
    const size = st.size;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [CHUNK]u8 = undefined;
    var read_total: u64 = 0;
    var last_pct: u8 = 0;

    // Empty reader buffer: readSliceShort fills `buf` directly (mirrors std's
    // Dir.readFile path), so the reader does not double-buffer the same bytes.
    var reader = file.reader(io, &.{});
    while (true) {
        if (sink.isCancelled()) {
            return z.done(z.Result(Out){ .err = .{ .code = "cancelled", .message = "cancelled" } });
        }
        const n = reader.interface.readSliceShort(&buf) catch {
            return z.done(z.Result(Out){ .err = .{ .code = "io_error", .message = "read failed" } });
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
        read_total += n;

        // Monotonic integer-percent progress. Stream a frame only when the
        // bucket advances so the channel is not flooded on tiny files.
        const pct: u8 = if (size == 0) 100 else @intCast(@min(@as(u64, 100), read_total * 100 / size));
        if (pct != last_pct) {
            sink.progress(.{ .pct = pct });
            last_pct = pct;
        }
    }
    if (last_pct != 100) sink.progress(.{ .pct = 100 });

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    // Hex-encode, then dupe into the per-call arena (freed by the bridge after
    // the terminal result is encoded) so the slice outlives this stack frame.
    const hex_arr = std.fmt.bytesToHex(digest, .lower);
    const hex = ctx.arena.dupe(u8, &hex_arr) catch {
        return z.done(z.Result(Out){ .err = .{ .code = "internal", .message = "oom" } });
    };
    return z.done(z.Result(Out){ .ok = .{ .hash = hex } });
}
