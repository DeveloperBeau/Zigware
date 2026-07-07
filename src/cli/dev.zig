const std = @import("std");
const proc = @import("proc.zig");
const watch = @import("watch.zig");
const Manifest = @import("zigware_manifest").Manifest;
const diag = @import("diag");

const log = diag.scoped("dev");

pub const BuildSpec = struct {
    optimize: std.builtin.OptimizeMode,
    dev: bool,
    /// When set (prod packaging), the path to a staged `asset_table.zig` the
    /// scaffold build wires via `-Dasset_table`. Null for dev (loads from serveUrl).
    asset_table: ?[]const u8 = null,
    /// Zig target triple passed to the consumer build as `-Dtarget=<triple>`
    /// (e.g. "aarch64-macos"). Null builds for the host. Set by `zigware build
    /// --arch`.
    target: ?[]const u8 = null,
};
pub const BuildResult = struct { ok: bool, stderr: []u8 }; // stderr owned by caller (gpa)

pub const BuildRunner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        build: *const fn (*anyopaque, io: std.Io, gpa: std.mem.Allocator, BuildSpec) anyerror!BuildResult,
    };
    pub fn build(self: BuildRunner, io: std.Io, gpa: std.mem.Allocator, spec: BuildSpec) anyerror!BuildResult {
        return self.vtable.build(self.ptr, io, gpa, spec);
    }
};

pub const ReloadOutcome = enum { reloaded, build_failed, no_change };

/// Injectable dev-server probe seam so C1 can drive a fake that times out without a live
/// server. `waitForUrl` is otherwise a concrete free function (devserver.zig) with no seam,
/// leaving the startup-timeout teardown path untestable. Production wires
/// `devserver.waitForUrl`; tests wire a fake returning error.dev_url_timeout.
pub const UrlProbe = *const fn (io: std.Io, gpa: std.mem.Allocator, url: []const u8, shutdown: *std.atomic.Value(bool)) anyerror!void;

pub const DevContext = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    manifest: *const Manifest,
    proc: proc.Spawner,
    watcher: watch.Watcher,
    builder: BuildRunner,
    wait_for_url: UrlProbe, // production: a thin wrapper over devserver.waitForUrl; tests: a fake
    shutdown: *std.atomic.Value(bool),
    /// The currently running app child, owned by the dev loop. `run` spawns it after the
    /// initial build and stores it here; `rebuildAndReload` reaches it through `ctx` to
    /// kill the old instance and publish the replacement (the locked `rebuildAndReload`
    /// signature carries neither the child nor a return slot for it). The ordered teardown
    /// reaps it when present. Null before the initial spawn and after teardown.
    app_child: ?proc.Child = null,
};

/// True when a changed batch contains at least one entry that warrants a rebuild
/// (a .zig source edit or a manifest edit). Batches of only `.other` paths are inert.
fn batchNeedsRebuild(changed: []const watch.ChangedPath) bool {
    for (changed) |c| switch (c.kind) {
        .zig_src, .manifest => return true,
        .other => {},
    };
    return false;
}

/// The spec used to (re)spawn the app child. Kept in one place so the initial spawn
/// (run) and every reload spawn (rebuildAndReload) are byte-identical: same dev env,
/// same own-process-group so an interactive Ctrl-C reaches the CLI alone.
fn appSpec(ctx: *DevContext) proc.ChildSpec {
    const dev_url = ctx.manifest.frontend.serveUrl orelse "app://";
    return .{
        .argv = &.{ "zig", "build", "run" },
        .env = &.{
            .{ .key = "ZIGWARE_DEV_URL", .value = dev_url },
            .{ .key = "ZIGWARE_DEV", .value = "1" },
        },
        .inherit_stdio = true,
        .new_process_group = true,
    };
}

/// Ordered teardown run on EVERY exit path (success, build error, shutdown, startup
/// timeout). Reaps the app child first (so the app window closes before the dev server
/// it talks to), then the beforeDev child, then closes the watcher. Children are
/// optional: a startup-window teardown may run before the app child exists.
///
/// Teardown is kill-ONLY (locked decision 7): `proc.kill` blocks through the SIGTERM
/// grace window and reaps the child, nulling its `id`. A trailing `proc.wait` would
/// trip std Child.wait's `assert(id != null)`, so it is deliberately absent.
fn teardown(ctx: *DevContext, before_dev: ?*proc.Child) void {
    if (ctx.app_child) |*c| {
        ctx.proc.kill(ctx.io, c) catch {};
        ctx.app_child = null;
    }
    if (before_dev) |c| ctx.proc.kill(ctx.io, c) catch {};
    ctx.watcher.close();
}

/// One reload cycle, exposed for headless testing. Classifies the batch; an inert batch
/// (no .zig_src/.manifest) returns `.no_change` without touching the running app. On a
/// build failure the running app is left ALIVE and the captured compiler stderr is
/// printed verbatim; on success the old app is killed THEN the replacement is spawned
/// (that order, so two app windows never coexist).
pub fn rebuildAndReload(ctx: *DevContext, changed: []const watch.ChangedPath) anyerror!ReloadOutcome {
    if (!batchNeedsRebuild(changed)) return .no_change;

    const result = try ctx.builder.build(ctx.io, ctx.gpa, .{ .optimize = .Debug, .dev = true });
    if (!result.ok) {
        // Leave the running app untouched; surface the compiler error and free the buffer.
        if (result.stderr.len > 0) log.err("build failed", &.{diag.str("stderr", result.stderr)});
        ctx.gpa.free(result.stderr);
        return .build_failed;
    }
    // stderr is gpa-owned on the ok path too; free it so the long-lived loop does not leak.
    ctx.gpa.free(result.stderr);

    // Kill the old app first, then publish the replacement.
    if (ctx.app_child) |*c| {
        ctx.proc.kill(ctx.io, c) catch {};
        ctx.app_child = null;
    }
    ctx.app_child = try ctx.proc.spawn(ctx.io, ctx.gpa, appSpec(ctx));
    return .reloaded;
}

/// Full dev loop until shutdown is set or the watcher closes. Reaps all children on
/// every exit path via the single ordered `teardown` helper.
pub fn run(ctx: *DevContext) anyerror!void {
    const io = ctx.io;
    const gpa = ctx.gpa;

    // dev command (if any), in its own process group so Ctrl-C reaches the CLI only.
    var before_dev: ?proc.Child = null;
    if (ctx.manifest.frontend.dev) |cmd| {
        before_dev = try ctx.proc.spawn(io, gpa, .{
            .argv = &.{ "/bin/sh", "-c", cmd },
            .inherit_stdio = true,
            .new_process_group = true,
        });
    }
    // Pointer the teardown helper uses to reap the beforeDev child. It outlives every
    // exit below because `before_dev` is a frame-local that the helper reads.
    const before_dev_ptr: ?*proc.Child = if (before_dev != null) &before_dev.? else null;

    // Single ordered teardown on EVERY exit path (success, build error, shutdown, startup
    // timeout, and any propagated infra error): reaps the app child then the beforeDev
    // child, then closes the watcher exactly once. Registered before the first blocking
    // stage so no early return or `try` can leak a child.
    defer teardown(ctx, before_dev_ptr);

    // SIGINT mid-startup goes straight to teardown rather than stranding the loop.
    if (ctx.shutdown.load(.seq_cst)) return;

    // Wait for the dev server (framework templates). Vanilla carries no serveUrl and skips
    // this. A shutdown or timeout during the wait routes to the same ordered teardown,
    // reaping the already-spawned beforeDev child (no leak).
    if (ctx.manifest.frontend.serveUrl) |url| {
        ctx.wait_for_url(io, gpa, url, ctx.shutdown) catch return;
    }

    if (ctx.shutdown.load(.seq_cst)) return;

    // Initial Debug build. A failure here returns (teardown reaps the beforeDev child).
    {
        const result = try ctx.builder.build(io, gpa, .{ .optimize = .Debug, .dev = true });
        defer ctx.gpa.free(result.stderr);
        if (!result.ok) {
            if (result.stderr.len > 0) log.err("build failed", &.{diag.str("stderr", result.stderr)});
            return;
        }
    }

    // Launch the app child and store it so rebuildAndReload and teardown can reach it.
    ctx.app_child = try ctx.proc.spawn(io, gpa, appSpec(ctx));

    // Watch loop. The injected watcher already carries the shutdown flag by construction,
    // so next() returns null on close OR shutdown; either ends the loop and triggers
    // the deferred teardown.
    while (true) {
        if (ctx.shutdown.load(.seq_cst)) break;
        const batch = (try ctx.watcher.next(io)) orelse break;
        if (ctx.shutdown.load(.seq_cst)) break;
        _ = try rebuildAndReload(ctx, batch);
    }
}

// ─────────────────────────── tests ───────────────────────────

const testing = std.testing;

/// Records a flat, ordered log of spawn/kill events so order assertions read straight
/// off the log. Each spawned Child carries a synthetic id (stamped into inner.id) so a
/// kill can name WHICH child it reaped. The fake never touches any other inner field.
const FakeSpawner = struct {
    next_id: std.posix.pid_t = 1,
    events: std.ArrayListUnmanaged(Event) = .empty,
    gpa: std.mem.Allocator,

    const Event = union(enum) { spawn: std.posix.pid_t, kill: std.posix.pid_t };

    fn make(self: *FakeSpawner) proc.Spawner {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: proc.Spawner.VTable = .{ .spawn = spawn, .wait = wait, .kill = kill };

    fn spawn(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, spec: proc.ChildSpec) anyerror!proc.Child {
        const self: *FakeSpawner = @ptrCast(@alignCast(ptr));
        const id = self.next_id;
        self.next_id += 1;
        try self.events.append(self.gpa, .{ .spawn = id });
        var inner: std.process.Child = undefined;
        inner.id = id;
        return .{ .inner = inner, .group_leader = spec.new_process_group };
    }
    fn wait(_: *anyopaque, _: std.Io, _: *proc.Child) anyerror!proc.Term {
        return .{ .exited = 0 };
    }
    fn kill(ptr: *anyopaque, _: std.Io, child: *proc.Child) anyerror!void {
        const self: *FakeSpawner = @ptrCast(@alignCast(ptr));
        const id = child.inner.id orelse return; // idempotent: already reaped
        try self.events.append(self.gpa, .{ .kill = id });
        child.inner.id = null; // mirror the real kill: reap nulls the id
    }
};

/// A BuildRunner that returns a canned ok/!ok plus an OWNED stderr copy each call (so the
/// dev loop's frees exercise real allocator bookkeeping under std.testing.allocator).
const FakeBuilder = struct {
    ok: bool,
    stderr_text: []const u8 = "",
    builds: usize = 0,
    /// When set, the FIRST build returns this ok value and later builds return `.ok`.
    /// Models "initial build fails, steady-state succeeds" without per-call scripting.
    first_ok: ?bool = null,
    gpa: std.mem.Allocator,

    fn make(self: *FakeBuilder) BuildRunner {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: BuildRunner.VTable = .{ .build = build };
    fn build(ptr: *anyopaque, _: std.Io, gpa: std.mem.Allocator, _: BuildSpec) anyerror!BuildResult {
        const self: *FakeBuilder = @ptrCast(@alignCast(ptr));
        const ok = if (self.builds == 0 and self.first_ok != null) self.first_ok.? else self.ok;
        self.builds += 1;
        const buf = try gpa.alloc(u8, self.stderr_text.len);
        @memcpy(buf, self.stderr_text);
        return .{ .ok = ok, .stderr = buf };
    }
};

/// Emits a scripted sequence of batches, then null forever. close() is recorded.
const FakeWatcher = struct {
    batches: []const []const watch.ChangedPath,
    idx: usize = 0,
    closed: bool = false,

    fn make(self: *FakeWatcher) watch.Watcher {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: watch.Watcher.VTable = .{ .next = next, .close = close };
    fn next(ptr: *anyopaque, _: std.Io) anyerror!?[]const watch.ChangedPath {
        const self: *FakeWatcher = @ptrCast(@alignCast(ptr));
        if (self.idx >= self.batches.len) return null;
        const b = self.batches[self.idx];
        self.idx += 1;
        return b;
    }
    fn close(ptr: *anyopaque) void {
        const self: *FakeWatcher = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
};

/// A watcher whose next() models "woke because shutdown": it sets the shutdown flag and
/// returns null deterministically (no real thread, no flakiness). Proves run treats
/// null -> teardown and does not rebuild after a shutdown wakeup.
const ShutdownWatcher = struct {
    shutdown: *std.atomic.Value(bool),
    closed: bool = false,
    nexts: usize = 0,

    fn make(self: *ShutdownWatcher) watch.Watcher {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: watch.Watcher.VTable = .{ .next = next, .close = close };
    fn next(ptr: *anyopaque, _: std.Io) anyerror!?[]const watch.ChangedPath {
        const self: *ShutdownWatcher = @ptrCast(@alignCast(ptr));
        self.nexts += 1;
        self.shutdown.store(true, .seq_cst);
        return null;
    }
    fn close(ptr: *anyopaque) void {
        const self: *ShutdownWatcher = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
};

fn okProbe(_: std.Io, _: std.mem.Allocator, _: []const u8, _: *std.atomic.Value(bool)) anyerror!void {
    return; // server is up immediately
}
fn timeoutProbe(_: std.Io, _: std.mem.Allocator, _: []const u8, _: *std.atomic.Value(bool)) anyerror!void {
    return error.dev_url_timeout;
}

fn testManifest() Manifest {
    return .{ .identifier = "com.example.app", .productName = "Example", .version = "0.1.0" };
}

// The fakes never dereference io (the probe is a fake free function, and the fake
// Spawner/Builder/Watcher ignore their io param), so an undefined io is safe here.
const nul_io: std.Io = undefined;

test "rebuildAndReload: build failure keeps the app alive and records no kill" {
    var spawner = FakeSpawner{ .gpa = testing.allocator };
    defer spawner.events.deinit(testing.allocator);
    var builder = FakeBuilder{ .ok = false, .stderr_text = "boom", .gpa = testing.allocator };
    var fw = FakeWatcher{ .batches = &.{} };
    var shutdown = std.atomic.Value(bool).init(false);
    var manifest = testManifest();

    var ctx = DevContext{
        .io = nul_io,
        .gpa = testing.allocator,
        .manifest = &manifest,
        .proc = spawner.make(),
        .watcher = fw.make(),
        .builder = builder.make(),
        .wait_for_url = okProbe,
        .shutdown = &shutdown,
        .app_child = blk: {
            // Pretend an app is already running (id 99): it must survive a build failure.
            var inner: std.process.Child = undefined;
            inner.id = 99;
            break :blk .{ .inner = inner, .group_leader = true };
        },
    };

    const changed = [_]watch.ChangedPath{.{ .path = "src/main.zig", .kind = .zig_src }};
    const outcome = try rebuildAndReload(&ctx, &changed);

    try testing.expectEqual(ReloadOutcome.build_failed, outcome);
    try testing.expectEqual(@as(usize, 0), spawner.events.items.len); // no kill, no spawn
    try testing.expect(ctx.app_child != null); // app stayed alive
}

test "rebuildAndReload: success kills old app THEN spawns new app, in that order" {
    var spawner = FakeSpawner{ .gpa = testing.allocator };
    defer spawner.events.deinit(testing.allocator);
    var builder = FakeBuilder{ .ok = true, .gpa = testing.allocator };
    var fw = FakeWatcher{ .batches = &.{} };
    var shutdown = std.atomic.Value(bool).init(false);
    var manifest = testManifest();

    var inner: std.process.Child = undefined;
    inner.id = 42;
    var ctx = DevContext{
        .io = nul_io,
        .gpa = testing.allocator,
        .manifest = &manifest,
        .proc = spawner.make(),
        .watcher = fw.make(),
        .builder = builder.make(),
        .wait_for_url = okProbe,
        .shutdown = &shutdown,
        .app_child = .{ .inner = inner, .group_leader = true },
    };

    const changed = [_]watch.ChangedPath{.{ .path = "src/foo.zig", .kind = .zig_src }};
    const outcome = try rebuildAndReload(&ctx, &changed);

    try testing.expectEqual(ReloadOutcome.reloaded, outcome);
    try testing.expectEqual(@as(usize, 2), spawner.events.items.len);
    // Kill of the old app (id 42) must precede the spawn of the replacement.
    try testing.expectEqual(@as(std.posix.pid_t, 42), spawner.events.items[0].kill);
    try testing.expect(spawner.events.items[1] == .spawn);
    try testing.expect(ctx.app_child != null);
}

test "rebuildAndReload: an .other-only batch does not rebuild" {
    var spawner = FakeSpawner{ .gpa = testing.allocator };
    defer spawner.events.deinit(testing.allocator);
    var builder = FakeBuilder{ .ok = true, .gpa = testing.allocator };
    var fw = FakeWatcher{ .batches = &.{} };
    var shutdown = std.atomic.Value(bool).init(false);
    var manifest = testManifest();

    var ctx = DevContext{
        .io = nul_io,
        .gpa = testing.allocator,
        .manifest = &manifest,
        .proc = spawner.make(),
        .watcher = fw.make(),
        .builder = builder.make(),
        .wait_for_url = okProbe,
        .shutdown = &shutdown,
    };

    const changed = [_]watch.ChangedPath{
        .{ .path = "dist/app.css", .kind = .other },
        .{ .path = "README.md", .kind = .other },
    };
    const outcome = try rebuildAndReload(&ctx, &changed);

    try testing.expectEqual(ReloadOutcome.no_change, outcome);
    try testing.expectEqual(@as(usize, 0), builder.builds); // never built
    try testing.expectEqual(@as(usize, 0), spawner.events.items.len);
}

test "run: shutdown set while watcher is parked runs ordered teardown" {
    var spawner = FakeSpawner{ .gpa = testing.allocator };
    defer spawner.events.deinit(testing.allocator);
    var builder = FakeBuilder{ .ok = true, .gpa = testing.allocator };
    var shutdown = std.atomic.Value(bool).init(false);
    var sw = ShutdownWatcher{ .shutdown = &shutdown };
    // frontend.dev + serveUrl so both children exist and the probe runs.
    var manifest = testManifest();
    manifest.frontend.dev = "true";
    manifest.frontend.serveUrl = "http://localhost:5173";

    var ctx = DevContext{
        .io = nul_io,
        .gpa = testing.allocator,
        .manifest = &manifest,
        .proc = spawner.make(),
        .watcher = sw.make(),
        .builder = builder.make(),
        .wait_for_url = okProbe,
        .shutdown = &shutdown,
    };

    try run(&ctx);

    // beforeDev (id 1) spawned, app (id 2) spawned, then teardown kills app FIRST then
    // beforeDev. The shutdown-wakeup must NOT trigger a rebuild.
    const ev = spawner.events.items;
    try testing.expectEqual(@as(usize, 4), ev.len);
    try testing.expectEqual(@as(std.posix.pid_t, 1), ev[0].spawn); // beforeDev
    try testing.expectEqual(@as(std.posix.pid_t, 2), ev[1].spawn); // app
    try testing.expectEqual(@as(std.posix.pid_t, 2), ev[2].kill); // app killed first
    try testing.expectEqual(@as(std.posix.pid_t, 1), ev[3].kill); // beforeDev second
    try testing.expect(sw.closed);
    try testing.expectEqual(@as(usize, 1), builder.builds); // only the initial build
}

test "run: scripted batch reload then close runs full loop and ordered teardown" {
    var spawner = FakeSpawner{ .gpa = testing.allocator };
    defer spawner.events.deinit(testing.allocator);
    var builder = FakeBuilder{ .ok = true, .gpa = testing.allocator };
    var shutdown = std.atomic.Value(bool).init(false);
    const b0 = [_]watch.ChangedPath{.{ .path = "src/x.zig", .kind = .zig_src }};
    const batches = [_][]const watch.ChangedPath{&b0};
    var fw = FakeWatcher{ .batches = &batches };
    var manifest = testManifest(); // no dev command, no serveUrl (vanilla)

    var ctx = DevContext{
        .io = nul_io,
        .gpa = testing.allocator,
        .manifest = &manifest,
        .proc = spawner.make(),
        .watcher = fw.make(),
        .builder = builder.make(),
        .wait_for_url = okProbe,
        .shutdown = &shutdown,
    };

    try run(&ctx);

    // app spawned (id1); batch reload kills it (id1) and spawns the replacement (id2);
    // watcher returns null -> teardown kills the replacement (id2). No beforeDev child.
    const ev = spawner.events.items;
    try testing.expectEqual(@as(usize, 4), ev.len);
    try testing.expectEqual(@as(std.posix.pid_t, 1), ev[0].spawn);
    try testing.expectEqual(@as(std.posix.pid_t, 1), ev[1].kill);
    try testing.expectEqual(@as(std.posix.pid_t, 2), ev[2].spawn);
    try testing.expectEqual(@as(std.posix.pid_t, 2), ev[3].kill);
    try testing.expect(fw.closed);
    try testing.expectEqual(@as(usize, 2), builder.builds); // initial + reload
}

test "run: initial waitForUrl timeout reaps the beforeDev child (no leak)" {
    var spawner = FakeSpawner{ .gpa = testing.allocator };
    defer spawner.events.deinit(testing.allocator);
    var builder = FakeBuilder{ .ok = true, .gpa = testing.allocator };
    var shutdown = std.atomic.Value(bool).init(false);
    var fw = FakeWatcher{ .batches = &.{} };
    var manifest = testManifest();
    manifest.frontend.dev = "true";
    manifest.frontend.serveUrl = "http://localhost:5173";

    var ctx = DevContext{
        .io = nul_io,
        .gpa = testing.allocator,
        .manifest = &manifest,
        .proc = spawner.make(),
        .watcher = fw.make(),
        .builder = builder.make(),
        .wait_for_url = timeoutProbe,
        .shutdown = &shutdown,
    };

    try run(&ctx);

    // beforeDev spawned (id1) then killed during teardown; the app never spawned.
    const ev = spawner.events.items;
    try testing.expectEqual(@as(usize, 2), ev.len);
    try testing.expectEqual(@as(std.posix.pid_t, 1), ev[0].spawn);
    try testing.expectEqual(@as(std.posix.pid_t, 1), ev[1].kill);
    try testing.expectEqual(@as(usize, 0), builder.builds); // timed out before any build
    try testing.expect(fw.closed);
}

test "run: initial build failure during startup reaps the beforeDev child" {
    var spawner = FakeSpawner{ .gpa = testing.allocator };
    defer spawner.events.deinit(testing.allocator);
    var builder = FakeBuilder{ .ok = true, .first_ok = false, .stderr_text = "compile error", .gpa = testing.allocator };
    var shutdown = std.atomic.Value(bool).init(false);
    var fw = FakeWatcher{ .batches = &.{} };
    var manifest = testManifest();
    manifest.frontend.dev = "true";
    manifest.frontend.serveUrl = "http://localhost:5173";

    var ctx = DevContext{
        .io = nul_io,
        .gpa = testing.allocator,
        .manifest = &manifest,
        .proc = spawner.make(),
        .watcher = fw.make(),
        .builder = builder.make(),
        .wait_for_url = okProbe,
        .shutdown = &shutdown,
    };

    try run(&ctx);

    // beforeDev spawned (id1), initial build fails, teardown kills it; app never spawned.
    const ev = spawner.events.items;
    try testing.expectEqual(@as(usize, 2), ev.len);
    try testing.expectEqual(@as(std.posix.pid_t, 1), ev[0].spawn);
    try testing.expectEqual(@as(std.posix.pid_t, 1), ev[1].kill);
    try testing.expectEqual(@as(usize, 1), builder.builds); // the one failing initial build
    try testing.expect(fw.closed);
}
