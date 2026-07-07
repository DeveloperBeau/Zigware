//! Src-rooted entry wrapper for the manifest/grants codegen exe. Rooting the
//! module at src/ (instead of src/manifest/) lets emit_effective.zig import
//! manifest/capabilities.zig, whose `../security/capability.zig` import would
//! otherwise escape a src/manifest-rooted module. Import resolution stays
//! file-relative, so emit_effective.zig's own sibling imports are unchanged.
pub const main = @import("manifest/emit_effective.zig").main;
