//! The crypto-demo example's one app command: hash a password and run a
//! ChaCha20-Poly1305 encrypt/decrypt round-trip, all on the Zig side.
//!
//! The frontend hands over a `password` and a `message`. The handler:
//!   1. derives a 32-byte key as SHA-256(password) (32 bytes is exactly the
//!      ChaCha20-Poly1305 key size),
//!   2. draws a fresh random 12-byte nonce from the platform CSPRNG,
//!   3. encrypts `message` under (key, nonce) with no associated data, then
//!   4. decrypts the ciphertext back to prove the round-trip closes.
//! Every byte string is hex-encoded into the per-call arena and returned, so the
//! frontend can render the digest, nonce, ciphertext, tag, and recovered text.
//!
//! DEMO SECURITY NOTE: deriving an encryption key straight from SHA-256(password)
//! is NOT how to handle real passwords — a plain hash is fast and brute-forceable.
//! A production app would stretch the password through a KDF
//! (`std.crypto.pwhash.argon2`) and store only the KDF verifier, never use the
//! digest as a cipher key. This example exists to show the bridge round-trip and
//! the `std.crypto` primitives, not a shippable key schedule.

const std = @import("std");
const z = @import("zigware");

/// ChaCha20-Poly1305 AEAD. key_length = 32, nonce_length = 12, tag_length = 16.
const ChaCha = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

/// Per-app State injected into every handler. cryptoDemo is stateless, so this
/// is empty — but it must be a NOMINAL type (not an inline `struct {}`) so the
/// command surface and the bridge agree on one `*Ctx(State)` first-param type.
/// Two separate inline `struct {}` literals are distinct types in Zig, which
/// would not bind to a `Bridge(B)` constructed over a State type.
pub const State = struct {};

/// The handler's success payload. A nominal struct so the `Result(Out)` return
/// coerces. Every field is hex except `decrypted` (the recovered plaintext) and
/// `roundTrip` (whether decrypt authenticated AND matched the input).
const Out = struct {
    sha256: []const u8,
    nonce: []const u8,
    ciphertext: []const u8,
    tag: []const u8,
    decrypted: []const u8,
    roundTrip: bool,
};

/// The app command surface. `cryptoDemo` is the example's one app command; the
/// framework wires its own builtins (compute.cancel, window.*) alongside.
pub const Commands = struct {
    pub fn cryptoDemo(
        ctx: *z.Ctx(State),
        args: struct { password: []const u8, message: []const u8 },
    ) z.Result(Out) {
        return seal(ctx.arena, args.password, args.message) catch
            .{ .err = .{ .code = "internal", .message = "out of memory" } };
    }
};

/// The pure core: derive the key, encrypt, decrypt, and hex-encode the outputs
/// into `arena`. Split out from the handler so the headless test drives the exact
/// same path without a bridge or window. Allocation failure is the only error;
/// ChaCha20-Poly1305 itself never fails to encrypt, and a decrypt that fails to
/// authenticate surfaces as `roundTrip = false`, not an error.
fn seal(arena: std.mem.Allocator, password: []const u8, message: []const u8) !z.Result(Out) {
    // Key = SHA-256(password). The 32-byte digest is shown to the user and is
    // also the ChaCha20-Poly1305 key (see the demo security note above).
    var key: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &key, .{});

    // Fresh random nonce, unique per call. NEVER reuse a nonce with the same key
    // or Poly1305's authentication guarantee collapses. The handler runs off the
    // UI thread with no Ctx-threaded io, so it owns a blocking io purely to reach
    // the platform CSPRNG; `random` is threadsafe and cannot fail.
    var nonce: [ChaCha.nonce_length]u8 = undefined;
    {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        defer threaded.deinit();
        threaded.io().random(&nonce);
    }

    // Encrypt `message` with no associated data.
    const ciphertext = try arena.alloc(u8, message.len);
    var tag: [ChaCha.tag_length]u8 = undefined;
    ChaCha.encrypt(ciphertext, &tag, message, "", nonce, key);

    // Decrypt to prove the round-trip. A bad tag would reject here; we report
    // that as roundTrip=false rather than erroring the whole command.
    const recovered = try arena.alloc(u8, message.len);
    var authentic = true;
    ChaCha.decrypt(recovered, ciphertext, tag, "", nonce, key) catch {
        authentic = false;
    };

    return .{ .ok = .{
        .sha256 = try hex(arena, &key),
        .nonce = try hex(arena, &nonce),
        .ciphertext = try hex(arena, ciphertext),
        .tag = try hex(arena, &tag),
        .decrypted = try arena.dupe(u8, recovered),
        .roundTrip = authentic and std.mem.eql(u8, recovered, message),
    } };
}

/// Lowercase-hex-encode `bytes` into a fresh `arena` slice. Hand-rolled rather
/// than via std.fmt so it is independent of std formatting churn and works for a
/// runtime-length slice (std.fmt.bytesToHex needs a comptime length).
fn hex(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const lut = "0123456789abcdef";
    const out = try arena.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = lut[b >> 4];
        out[i * 2 + 1] = lut[b & 0x0f];
    }
    return out;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "cryptoDemo round-trips and exposes correctly sized hex fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const r = try seal(arena.allocator(), "correct horse battery staple", "attack at dawn");
    const o = switch (r) {
        .ok => |o| o,
        .err => return error.TestUnexpectedResult,
    };

    try std.testing.expect(o.roundTrip);
    try std.testing.expectEqualStrings("attack at dawn", o.decrypted);
    try std.testing.expectEqual(@as(usize, 64), o.sha256.len); // 32-byte digest
    try std.testing.expectEqual(@as(usize, 24), o.nonce.len); //  12-byte nonce
    try std.testing.expectEqual(@as(usize, 28), o.ciphertext.len); // 14 bytes
    try std.testing.expectEqual(@as(usize, 32), o.tag.len); //      16-byte tag
}

test "key is the real SHA-256 of the password" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // SHA-256("abc") is a published test vector; proves the digest shown to the
    // user is a genuine SHA-256 and not a stand-in.
    const r = try seal(arena.allocator(), "abc", "");
    const o = switch (r) {
        .ok => |o| o,
        .err => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        o.sha256,
    );
    // An empty message still round-trips (zero-length ciphertext, real tag).
    try std.testing.expect(o.roundTrip);
    try std.testing.expectEqualStrings("", o.ciphertext);
    try std.testing.expectEqual(@as(usize, 32), o.tag.len);
}

test "a different password yields a different key and ciphertext" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = switch (try seal(arena.allocator(), "alpha", "same message")) {
        .ok => |o| o,
        .err => return error.TestUnexpectedResult,
    };
    const b = switch (try seal(arena.allocator(), "bravo", "same message")) {
        .ok => |o| o,
        .err => return error.TestUnexpectedResult,
    };
    try std.testing.expect(!std.mem.eql(u8, a.sha256, b.sha256));
    try std.testing.expect(!std.mem.eql(u8, a.ciphertext, b.ciphertext));
    try std.testing.expect(a.roundTrip and b.roundTrip);
}
