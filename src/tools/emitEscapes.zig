const std = @import("std");
const protocol = @import("protocol");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Build JSONL fixture bytes into memory.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try protocol.emitEscapeFixtures(&aw.writer);
    const bytes = aw.writer.buffered();

    // Set up Io so we can use the Dir/File APIs.
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Ensure test/fixtures/ exists, then write the file.
    try std.Io.Dir.cwd().createDirPath(io, "test/fixtures");
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "test/fixtures/js_escapes.jsonl",
        .data = bytes,
    });
}
