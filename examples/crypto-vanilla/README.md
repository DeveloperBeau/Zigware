# Crypto Demo (Vanilla)

A Zigware desktop app that hashes a password and runs a ChaCha20-Poly1305
encrypt/decrypt round-trip on the Zig side, with a dependency-free vanilla-JS
frontend (no build step).

## What it does

The frontend collects a `password` and a `message` and calls one Zig command,
`cryptoDemo`. On the Zig side (`src/commands/crypto.zig`) it:

1. derives a 32-byte key as `SHA-256(password)`,
2. draws a fresh random 12-byte nonce from the platform CSPRNG,
3. encrypts the message with ChaCha20-Poly1305, and
4. decrypts it back to prove the round-trip closes.

It returns the digest, nonce, ciphertext, tag, recovered plaintext, and a
round-trip flag — all hex-encoded except the recovered text.

> **Security note.** Using `SHA-256(password)` directly as a cipher key is a
> teaching shortcut, not secure password handling: a plain hash is fast and
> brute-forceable. A real app would stretch the password through a KDF
> (`std.crypto.pwhash.argon2`) and never use the digest as a key. This example
> demonstrates the bridge round-trip and the `std.crypto` primitives.

## Run

```sh
zigware dev      # Debug build, opens the window
zigware build    # ReleaseSafe build with a strict per-script CSP
```

## Test

The command is a pure function, so its round-trip is proven headlessly:

```sh
zig build test-crypto   # from the repo root
```

## Layout

```
crypto-vanilla/
  zigware.zon              app manifest (window, fuses, CSP)
  src/commands/crypto.zig  the cryptoDemo command + its unit tests
  src/capabilities/        per-window origin grants
  frontend/                static HTML/CSS/JS (no bundler)
```
