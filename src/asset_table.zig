// Default asset table for the PoC frontend. `zigware build` regenerates this from frontendDist.
pub const Asset = struct { path: []const u8, body: []const u8, mime: [:0]const u8 };

pub const index_html = @embedFile("frontend/index.html");
pub const app_js = @embedFile("frontend/app.js");
pub const zigware_js = @embedFile("frontend/zigware.js");

pub const table = [_]Asset{
    .{ .path = "/index.html", .body = index_html, .mime = "text/html" },
    .{ .path = "/app.js", .body = app_js, .mime = "text/javascript" },
    .{ .path = "/zigware.js", .body = zigware_js, .mime = "text/javascript" },
};
