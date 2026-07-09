//! Src-rooted entry wrapper for the manifest/grants codegen exe. Rooting the
//! module at src/ (instead of src/manifest/) lets emitEffective.zig import
//! manifest/capabilities.zig, whose `../security/capability.zig` import would
//! otherwise escape a src/manifest-rooted module. Import resolution stays
//! file-relative, so emitEffective.zig's own sibling imports are unchanged.
pub const main = @import("manifest/emitEffective.zig").main;
