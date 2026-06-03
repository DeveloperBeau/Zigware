const std = @import("std");

pub const Entry = struct {
    /// served path, always begins with "/", forward-slash normalized
    serve_path: []const u8,
    /// path relative to frontendDist, used as the addAnonymousImport name
    import_name: []const u8,
    /// sentinel-terminated MIME for seam.Response.mime
    mime: [:0]const u8,
};

pub const WalkResult = struct {
    entries: []const Entry,
    arena: std.heap.ArenaAllocator, // owns all entry strings; caller deinits
    pub fn deinit(self: *WalkResult) void {
        self.arena.deinit();
    }
};

/// Enumerate frontendDist; canonicalize each path and reject anything resolving outside it
/// (.., out-pointing symlinks, absolute paths, embedded NUL) with error.asset_outside_dist.
pub fn walk(io: std.Io, gpa: std.mem.Allocator, dist_dir: []const u8) anyerror!WalkResult {
    _ = io;
    _ = gpa;
    _ = dist_dir;
    return error.NotImplemented;
}

/// Emit the generated build.zig fragment (addAnonymousImport per entry).
pub fn emitBuildFragment(w: *std.Io.Writer, entries: []const Entry) !void {
    _ = w;
    _ = entries;
    return error.NotImplemented;
}

/// Emit asset_table.zig: `pub const table = [_]Asset{ .{...} };` consumed by serveAsset.
pub fn emitAssetTable(w: *std.Io.Writer, entries: []const Entry) !void {
    _ = w;
    _ = entries;
    return error.NotImplemented;
}

/// Extension -> MIME, sentinel-terminated. Unknown extensions fall back to application/octet-stream.
pub fn mimeForExt(ext: []const u8) [:0]const u8 {
    const table = .{
        .{ ".html", "text/html" },        .{ ".js", "text/javascript" },
        .{ ".css", "text/css" },          .{ ".json", "application/json" },
        .{ ".svg", "image/svg+xml" },     .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },         .{ ".woff2", "font/woff2" },
        .{ ".woff", "font/woff" },        .{ ".ico", "image/x-icon" },
        .{ ".wasm", "application/wasm" }, .{ ".map", "application/json" },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, ext, row[0])) return row[1];
    }
    return "application/octet-stream";
}
