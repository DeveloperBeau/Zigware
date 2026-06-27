//! Headless capstone proof for the notes example (Task 7).
//!
//! Loads `examples/notes/zigware.zon` through D's loader (no hand-rolled zon
//! parsing here; D owns it) to prove the example manifest is well-formed and
//! declares the `main` window, then drives the REAL `hashFile` handler over a
//! `Bridge(NullBackend)` wired with the example's capability scope:
//!
//!   - an IN-scope path (under $APPDATA/notes/**, present on disk) RESOLVES with
//!     the hex digest and emits monotonic progress, and
//!   - an OUT-of-scope traversal REJECTS at G4 with the real path-miss code
//!     `scope.path.no_match` (NOT the non-existent "out_of_scope").
//!
//! Both halves are asserted from one fixture, order-independently. The in-scope
//! file exists so the allow half is a real allow, not a fail-closed
//! accident (if realPathFile failed, both halves would reject for the same reason
//! and the deny would prove nothing).

const std = @import("std");
const z = @import("zigware");
const hash_file = @import("commands/hash_file.zig");
const State = @import("app_state.zig").State;

const NullBackend = z.NullBackend;
const Bridge = z.Bridge;

/// The example command surface the bridge registers: the one app command.
/// compute.cancel/window.* are framework builtins not exercised here.
const NotesCommands = struct {
    pub const hashFile = hash_file.hashFile;
};

/// A bridge wired with the example's `hashFile`, a tmp app-data dir as base_dir,
/// and $APPDATA anchored at that dir so realPathFile resolves the in-scope path.
const Harness = struct {
    backend: *NullBackend,
    bridge: *Bridge(NullBackend),
    window_id: u64,
    state: *State,
    grants: *z.GrantTable,
    tmp: std.testing.TmpDir,
    base_path: []const u8,

    fn base(self: *const Harness) []const u8 {
        return self.base_path;
    }

    fn init() !Harness {
        const a = std.testing.allocator;
        const io = std.testing.io;

        // D's loader validates the example manifest (and cross-checks its
        // capability files) and yields its windows. This proves the in-repo
        // example loads end to end through the real parser; the test never parses
        // zon itself. The loader reads zigware.zon + src/grants/*.zon
        // relative to the passed root, so open the example dir explicitly (the
        // test binary's CWD is the build root, not examples/notes/).
        var example_dir = try std.Io.Dir.cwd().openDir(io, "examples/notes", .{ .iterate = true });
        defer example_dir.close(io);
        var diag: z.manifest.Diagnostics = .{};
        defer diag.deinit(a);
        const m = try z.parse.parseAtBuild(a, io, example_dir, .macos, .Debug, &diag);
        defer z.parse.freeManifest(a, m);
        try std.testing.expect(m.app.windows.len >= 1);
        try std.testing.expectEqualStrings("main", m.app.windows[0].label);

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        // Anchor $APPDATA at the tmp dir and create the in-scope file on disk so
        // the allow half resolves through realPathFile.
        var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const base_len = try tmp.dir.realPath(io, &base_buf);
        const base_path = try a.dupe(u8, base_buf[0..base_len]);
        errdefer a.free(base_path);
        try tmp.dir.createDirPath(io, "notes");
        // Span several 64 KiB read chunks so the handler emits DISTINCT sub-100%
        // progress buckets (a small file would stream a single 100% frame and the
        // monotonicity assert would prove nothing). 320 KiB = 5 chunks -> percent
        // buckets at 20/40/60/80/100.
        const fixture = try a.alloc(u8, 320 * 1024);
        defer a.free(fixture);
        for (fixture, 0..) |*byte, i| byte.* = @truncate(i * 31 + 7);
        try tmp.dir.writeFile(io, .{ .sub_path = "notes/secret.txt", .data = fixture });

        const backend = try NullBackend.init(a, io);
        errdefer backend.deinit();
        const win = try backend.createWindow(.{ .url = "app://localhost/index.html" });
        const state = try a.create(State);
        errdefer a.destroy(state);
        state.* = .{};

        // Grant `hashFile` to "main" via the runtime catalog's app:hashFile
        // permission (scope $APPDATA/notes/**), plus core:default. One cap per
        // window keeps scopeFor's inert n<=1 guard satisfied.
        const grants = try a.create(z.GrantTable);
        errdefer a.destroy(grants);
        var gdiag: z.manifest.Diagnostics = .{};
        defer gdiag.deinit(a);
        const caps = [_]z.capability.Capability{.{
            .identifier = "notes",
            .windows = &.{"main"},
            .origins = &.{.app_scheme},
            .permissions = &.{ "core:default", "app:hashFile" },
        }};
        grants.* = try z.GrantTable.compile(a, &caps, &z.app_catalog.runtime_catalog, .{}, &.{"main"}, &gdiag);
        errdefer grants.deinit();

        const bases = z.gates.Bases{ .appdata = base_path, .home = base_path, .appconfig = base_path };
        const bridge = try Bridge(NullBackend).init(
            a,
            io,
            backend,
            win,
            State,
            NotesCommands,
            state,
            .{ .worker_count = 4 },
            grants,
            bases,
            tmp.dir,
            false,
        );
        return .{
            .backend = backend,
            .bridge = bridge,
            .window_id = backend.windowId(win),
            .state = state,
            .grants = grants,
            .tmp = tmp,
            .base_path = base_path,
        };
    }

    fn send(self: *Harness, text: []const u8) void {
        self.bridge.handleMessage(self.window_id, "app://localhost", text);
    }

    fn settle(self: *Harness) void {
        self.bridge.drainForTest();
        self.backend.pumpMain();
    }

    fn deinit(self: *Harness) void {
        self.bridge.deinit();
        self.grants.deinit();
        std.testing.allocator.destroy(self.grants);
        std.testing.allocator.destroy(self.state);
        std.testing.allocator.free(self.base_path);
        self.backend.markJoined();
        self.backend.deinit();
        self.tmp.cleanup();
    }

    const Progress = struct { count: usize, monotonic: bool, last: i32 };

    /// Walk every `_stream` frame's `{"pct":N}` payload and report the frame
    /// count, whether the sequence never regressed, and the final percent.
    /// The example streams a frame only when the bucket advances, so over a
    /// multi-chunk file several distinct non-decreasing frames must appear,
    /// ending at 100.
    fn progress(self: *Harness) Progress {
        var last: i32 = -1;
        var count: usize = 0;
        var monotonic = true;
        for (self.backend.eval_log.items) |e| {
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, e.js, i, "\"pct\":")) |at| {
                const start = at + "\"pct\":".len;
                var j = start;
                while (j < e.js.len and e.js[j] >= '0' and e.js[j] <= '9') : (j += 1) {}
                const val = std.fmt.parseInt(i32, e.js[start..j], 10) catch {
                    i = j;
                    continue;
                };
                if (val < last) monotonic = false;
                last = val;
                count += 1;
                i = j;
            }
        }
        return .{ .count = count, .monotonic = monotonic, .last = last };
    }
};

test "notes example: in-scope hashFile resolves with a digest and monotonic progress" {
    var h = try Harness.init();
    defer h.deinit();
    var buf: [std.Io.Dir.max_path_bytes + 96]u8 = undefined;

    const in_msg = try std.fmt.bufPrint(&buf, "{{\"id\":1,\"cmd\":\"hashFile\",\"args\":{{\"path\":\"{s}/notes/secret.txt\"}}}}", .{h.base()});
    h.send(in_msg);
    h.settle();

    try std.testing.expectEqual(@as(usize, 1), h.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 0), h.backend.countRejectExactly(1));
    // The resolve carries a 64-hex-char digest.
    try std.testing.expect(h.backend.countContaining("\"hash\":\"") >= 1);
    // The 320 KiB fixture spans 5 read chunks, so several distinct progress
    // buckets must stream, non-decreasing, ending at 100.
    const p = h.progress();
    try std.testing.expect(p.count >= 2);
    try std.testing.expect(p.monotonic);
    try std.testing.expectEqual(@as(i32, 100), p.last);
}

test "notes example: out-of-scope hashFile is denied at G4 with scope.path.no_match" {
    var h = try Harness.init();
    defer h.deinit();
    var buf: [std.Io.Dir.max_path_bytes + 96]u8 = undefined;

    const out_msg = try std.fmt.bufPrint(&buf, "{{\"id\":2,\"cmd\":\"hashFile\",\"args\":{{\"path\":\"{s}/notes/../../etc/passwd\"}}}}", .{h.base()});
    h.send(out_msg);
    h.settle();

    try std.testing.expectEqual(@as(usize, 0), h.backend.countResolveExactly(2));
    try std.testing.expectEqual(@as(usize, 1), h.backend.countRejectExactly(2));
    try std.testing.expect(h.backend.countContaining("scope.path.no_match") == 1);
}
