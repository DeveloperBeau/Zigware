const std = @import("std");
const Manifest = @import("zigware_manifest").Manifest; // D's parsed manifest type

pub const ScriptHash = struct { algo: enum { sha256 }, b64: []const u8 };

/// SHA-256 each script (file bytes or inline <script> body), base64-encode, return 'sha256-<b64>' sources.
pub fn scriptHashes(gpa: std.mem.Allocator, scripts: []const []const u8) ![]const ScriptHash {
    _ = gpa;
    _ = scripts;
    return error.NotImplemented;
}

/// Strict base ("default-src 'self'; script-src 'self' <hashes>; ...", no unsafe-inline/eval) + manifest hosts.
pub fn buildCsp(gpa: std.mem.Allocator, hashes: []const ScriptHash, manifest: *const Manifest) ![]u8 {
    _ = gpa;
    _ = hashes;
    _ = manifest;
    return error.NotImplemented;
}

/// Replace/insert the <meta http-equiv="Content-Security-Policy"> in index.html.
/// Fails csp_conflict if the source HTML already declares a CSP meta with different content.
pub fn injectIntoHtml(gpa: std.mem.Allocator, html: []const u8, csp: []const u8) ![]u8 {
    _ = gpa;
    _ = html;
    _ = csp;
    return error.NotImplemented;
}
