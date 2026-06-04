const std = @import("std");

pub const ChangedPath = struct { path: []const u8, kind: enum { zig_src, manifest, other } };

pub const Watcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        // Blocks until a debounced batch is ready; null when the watcher is closed
        // OR when the shutdown flag (handed to polling()) is observed set. The internal
        // scan/sleep loop polls that flag every interval so a SIGINT mid-next() returns
        // null promptly instead of stranding the dev loop until an unrelated file changes.
        // The returned slice is owned by the watcher and valid only until the next next()/close().
        next: *const fn (*anyopaque, io: std.Io) anyerror!?[]const ChangedPath,
        close: *const fn (*anyopaque) void,
    };
    pub fn next(self: Watcher, io: std.Io) anyerror!?[]const ChangedPath {
        return self.vtable.next(self.ptr, io);
    }
    pub fn close(self: Watcher) void {
        self.vtable.close(self.ptr);
    }
};

/// Smallest sleep slice (ms) the scan loop parks for between shutdown rechecks. The
/// interval_ms wait is broken into slices no longer than this so a SIGINT set mid-next()
/// is observed within at most one slice instead of after a full interval.
const slice_ms: u32 = 5;

/// Polling watcher state. Heap-allocated because the returned Watcher.ptr outlives the
/// polling() frame; close() destroys it.
const Poller = struct {
    gpa: std.mem.Allocator,
    roots: []const []const u8,
    interval_ms: u32,
    shutdown: *std.atomic.Value(bool),
    /// path -> last observed mtime (ns). Keys are gpa-owned for the poller's whole life.
    last: std.StringHashMapUnmanaged(i128) = .empty,
    /// Owns the strings of the most recently returned batch; reset on every emit.
    batch_arena: std.heap.ArenaAllocator,
    /// Backing storage for the slice handed back by next(); reused each emit. Allocated
    /// from `gpa`, NOT batch_arena: the per-emit `batch_arena.reset` refills the arena from
    /// offset 0 while this list retains its capacity, so a list backed by the same arena
    /// could be overwritten by a multi-entry batch's path dupes.
    batch: std.ArrayListUnmanaged(ChangedPath) = .empty,
    closed: bool = false,
    /// False until the first next() runs the seeding scan that populates `last` with the
    /// current tree. polling() takes no io, so seeding is deferred to the first next()
    /// (which does); the seed scan suppresses batch recording so the first emitted batch
    /// carries only changes that happen AFTER construction, never the whole tree.
    seeded: bool = false,

    fn classify(path: []const u8) @FieldType(ChangedPath, "kind") {
        if (std.mem.endsWith(u8, path, ".zig")) return .zig_src;
        const base = std.fs.path.basename(path);
        if (std.mem.eql(u8, base, "zigware.zon")) return .manifest;
        return .other;
    }

    fn shuttingDown(self: *Poller) bool {
        return self.shutdown.load(.seq_cst);
    }

    /// Sleep up to interval_ms, in slices, rechecking shutdown between slices.
    /// Returns true if shutdown was observed (caller should bail to null).
    fn sleepInterval(self: *Poller, io: std.Io) bool {
        var remaining = self.interval_ms;
        while (remaining > 0) {
            if (self.shuttingDown()) return true;
            const this_slice = @min(remaining, slice_ms);
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(this_slice), .awake) catch {
                // Canceled (or any sleep failure): treat as a shutdown recheck point.
                return self.shuttingDown();
            };
            remaining -= this_slice;
        }
        return self.shuttingDown();
    }

    /// One scan across every root. Updates `last` for every file. When `record` is true,
    /// each changed path (absent from `last` or a differing mtime) is also appended to the
    /// batch; when false (the seeding scan) `last` is populated but nothing is emitted.
    /// Returns the number of changes seen, or null if shutdown was observed mid-scan.
    fn scan(self: *Poller, io: std.Io, record: bool) std.mem.Allocator.Error!?usize {
        var found: usize = 0;
        for (self.roots) |root| {
            if (self.shuttingDown()) return null;
            var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
                // A root that does not exist (yet) is not fatal; skip it this scan.
                if (err == error.Canceled) {
                    if (self.shuttingDown()) return null;
                }
                continue;
            };
            defer dir.close(io);

            var walker = dir.walk(self.gpa) catch |err| return err;
            defer walker.deinit();

            while (true) {
                const maybe_entry = walker.next(io) catch |err| {
                    if (err == error.Canceled and self.shuttingDown()) return null;
                    // A transient walk error (vanished dir, races): stop this root.
                    break;
                };
                const entry = maybe_entry orelse break;
                if (entry.kind != .file) continue;

                // entry.path aliases the walker's name_buffer, invalidated on the next
                // walker.next(); build the joined root-relative path into a stack copy
                // before any further walk step or allocation that could outlive it.
                const stat = dir.statFile(io, entry.path, .{}) catch |err| {
                    // A file can vanish between walk and stat; skip it. Canceled routes
                    // to the shutdown recheck.
                    if (err == error.Canceled and self.shuttingDown()) return null;
                    continue;
                };
                const mtime: i128 = stat.mtime.nanoseconds;

                // Key the map on a root-joined path so identically named files under
                // different roots do not collide.
                var key_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer key_buf.deinit(self.gpa);
                try key_buf.appendSlice(self.gpa, root);
                try key_buf.append(self.gpa, std.fs.path.sep);
                try key_buf.appendSlice(self.gpa, entry.path);
                const joined = key_buf.items;

                const gop = try self.last.getOrPut(self.gpa, joined);
                const changed = !gop.found_existing or gop.value_ptr.* != mtime;
                if (gop.found_existing) {
                    gop.value_ptr.* = mtime;
                } else {
                    // New key: own a gpa copy that lives with the poller.
                    gop.key_ptr.* = try self.gpa.dupe(u8, joined);
                    gop.value_ptr.* = mtime;
                }

                if (changed) {
                    found += 1;
                    if (record) {
                        const owned = try self.batch_arena.allocator().dupe(u8, joined);
                        try self.batch.append(self.gpa, .{
                            .path = owned,
                            .kind = classify(owned),
                        });
                    }
                }
            }
        }
        return found;
    }

    fn nextImpl(self: *Poller, io: std.Io) anyerror!?[]const ChangedPath {
        if (self.closed) return null;

        // First call: seed `last` with the current tree (no batch recording) so we only
        // ever report changes that postdate construction, then return an empty batch
        // immediately. Seeding does NOT fall into the detect loop: a caller that wrote a
        // change before this first next() expects the SUBSEQUENT next() to report it, and
        // collapsing seed+detect into one call would absorb that change into the seed.
        // An empty batch is classified `no_change` by the dev loop, so this is inert.
        if (!self.seeded) {
            if (self.shuttingDown()) return null;
            _ = (try self.scan(io, false)) orelse return null;
            self.seeded = true;
            self.batch.clearRetainingCapacity();
            return self.batch.items;
        }

        while (true) {
            if (self.shuttingDown()) return null;

            // Reset the batch for this emit attempt.
            _ = self.batch_arena.reset(.retain_capacity);
            self.batch.clearRetainingCapacity();

            const found = (try self.scan(io, true)) orelse return null; // null => shutdown
            if (found > 0) {
                // Debounce: pause one interval and coalesce any follow-on writes into
                // the same batch before emitting. A shutdown during the pause still
                // emits the batch we already have, which the dev loop will rebuild from
                // before observing shutdown on the next next().
                _ = self.sleepInterval(io);
                _ = (try self.scan(io, true)) orelse {}; // coalesce; shutdown handled below
                return self.batch.items;
            }

            // No change this scan: park one interval, rechecking shutdown, then rescan.
            if (self.sleepInterval(io)) return null;
        }
    }

    fn closeImpl(self: *Poller) void {
        if (self.closed) return;
        self.closed = true;
        var it = self.last.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.last.deinit(self.gpa);
        self.batch.deinit(self.gpa);
        self.batch_arena.deinit();
        self.gpa.destroy(self);
    }

    fn nextThunk(ptr: *anyopaque, io: std.Io) anyerror!?[]const ChangedPath {
        return nextImpl(@ptrCast(@alignCast(ptr)), io);
    }
    fn closeThunk(ptr: *anyopaque) void {
        closeImpl(@ptrCast(@alignCast(ptr)));
    }
    const vtable: Watcher.VTable = .{ .next = nextThunk, .close = closeThunk };
};

/// `shutdown` is observed by next()'s scan/sleep loop: when it is set, next() returns
/// null on the next interval boundary (at the latest) instead of blocking until a file
/// changes. The Poller stores this pointer; it does NOT widen the Watcher vtable — fakes
/// receive the same flag by construction.
pub fn polling(gpa: std.mem.Allocator, roots: []const []const u8, interval_ms: u32, shutdown: *std.atomic.Value(bool)) !Watcher {
    const self = try gpa.create(Poller);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .roots = roots,
        .interval_ms = interval_ms,
        .shutdown = shutdown,
        .batch_arena = std.heap.ArenaAllocator.init(gpa),
    };
    // Seeding the current tree into `last` is deferred to the first next() (polling()
    // takes no io); see Poller.seeded.
    return .{ .ptr = self, .vtable = &Poller.vtable };
}

/// Deferred to v0.2: macOS FSEvents has no public std.Io API. polling() is the shipped default.
pub fn fsEvents(gpa: std.mem.Allocator, roots: []const []const u8, debounce_ms: u32) !Watcher {
    _ = gpa;
    _ = roots;
    _ = debounce_ms;
    return error.Unsupported;
}

// ─── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build the cwd-relative path to a tmpDir so polling()'s root strings resolve through
/// std.Io.Dir.cwd().openDir. tmpDir lives under .zig-cache/tmp/<sub_path>.
fn tmpRootPath(buf: []u8, td: *const testing.TmpDir) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{td.sub_path}) catch unreachable;
}

/// Find the single ChangedPath whose basename matches `base`, or null.
fn findByBasename(batch: []const ChangedPath, base: []const u8) ?ChangedPath {
    for (batch) |cp| {
        if (std.mem.eql(u8, std.fs.path.basename(cp.path), base)) return cp;
    }
    return null;
}

test "polling reports a modified .zig file as zig_src" {
    const io = testing.io;
    var td = testing.tmpDir(.{ .iterate = true });
    defer td.cleanup();

    try td.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const a = 1;" });

    var root_buf: [256]u8 = undefined;
    const roots = [_][]const u8{tmpRootPath(&root_buf, &td)};
    var shutdown = std.atomic.Value(bool).init(false);

    const w = try polling(testing.allocator, &roots, 5, &shutdown);
    defer w.close();

    // First next() seeds the current tree and returns an empty batch.
    try testing.expectEqual(@as(usize, 0), (try w.next(io)).?.len);

    // Mutate the file so its mtime moves; sleep a beat so the write lands on a later
    // mtime tick than the seed scan. The next next() detects it.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    try td.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const a = 2; // changed" });

    const batch = (try w.next(io)).?;
    const hit = findByBasename(batch, "main.zig") orelse return error.MissingChange;
    try testing.expectEqual(hit.kind, .zig_src);
}

test "polling reports a new zigware.zon as manifest" {
    const io = testing.io;
    var td = testing.tmpDir(.{ .iterate = true });
    defer td.cleanup();

    // Seed with an unrelated file so the dir is non-empty at construction.
    try td.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const a = 1;" });

    var root_buf: [256]u8 = undefined;
    const roots = [_][]const u8{tmpRootPath(&root_buf, &td)};
    var shutdown = std.atomic.Value(bool).init(false);

    const w = try polling(testing.allocator, &roots, 5, &shutdown);
    defer w.close();

    // Seed first; the seed scan returns an empty batch.
    try testing.expectEqual(@as(usize, 0), (try w.next(io)).?.len);

    // Create zigware.zon after seeding; absent from `last`, so it fires.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    try td.dir.writeFile(io, .{ .sub_path = "zigware.zon", .data = ".{}" });

    const batch = (try w.next(io)).?;
    const hit = findByBasename(batch, "zigware.zon") orelse return error.MissingChange;
    try testing.expectEqual(hit.kind, .manifest);
}

test "polling classifies an unrelated file as other" {
    const io = testing.io;
    var td = testing.tmpDir(.{ .iterate = true });
    defer td.cleanup();

    try td.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const a = 1;" });

    var root_buf: [256]u8 = undefined;
    const roots = [_][]const u8{tmpRootPath(&root_buf, &td)};
    var shutdown = std.atomic.Value(bool).init(false);

    const w = try polling(testing.allocator, &roots, 5, &shutdown);
    defer w.close();

    // Seed first; the seed scan returns an empty batch.
    try testing.expectEqual(@as(usize, 0), (try w.next(io)).?.len);

    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    try td.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "hello" });

    const batch = (try w.next(io)).?;
    const hit = findByBasename(batch, "notes.txt") orelse return error.MissingChange;
    try testing.expectEqual(hit.kind, .other);
}

test "close frees a seeded watcher cleanly" {
    const io = testing.io;
    var td = testing.tmpDir(.{ .iterate = true });
    defer td.cleanup();

    try td.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const a = 1;" });

    var root_buf: [256]u8 = undefined;
    const roots = [_][]const u8{tmpRootPath(&root_buf, &td)};
    var shutdown = std.atomic.Value(bool).init(false);

    const w = try polling(testing.allocator, &roots, 5, &shutdown);
    // Seed so the close path frees a populated map + the gpa-owned keys; the
    // testing allocator then verifies no leak. The locked Watcher API exposes only
    // next()/close(), so close() is the sole teardown and destroys the Poller itself
    // — there is no post-close next() (that would dereference freed memory).
    _ = try w.next(io);
    w.close();
}

test "parked next observes shutdown without any file event" {
    const io = testing.io;
    var td = testing.tmpDir(.{ .iterate = true });
    defer td.cleanup();

    try td.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const a = 1;" });

    var root_buf: [256]u8 = undefined;
    const roots = [_][]const u8{tmpRootPath(&root_buf, &td)};
    var shutdown = std.atomic.Value(bool).init(false);

    const w = try polling(testing.allocator, &roots, 5, &shutdown);
    defer w.close();

    // No file ever changes; set shutdown and assert next() returns null promptly.
    shutdown.store(true, .seq_cst);
    try testing.expectEqual(@as(?[]const ChangedPath, null), try w.next(io));
}
