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

> **Current limitation.** A running window can only call the framework's built-in
> commands; an app cannot yet register its own command (`cryptoDemo`) into the
> live window. Until that lands, the command is exercised headlessly by the tests
> below, which drive the exact dispatch path a window will use.

## Test

Two headless checks cover the command from the repo root:

```sh
zig build test-crypto
```

- the unit tests in `src/commands/crypto.zig` prove the pure crypto core
  (SHA-256 against a published vector, the encrypt/decrypt round-trip, distinct
  keys per password, field sizing), and
- `src/integration_test.zig` drives `cryptoDemo` end to end through the real
  `Bridge`: a JSON envelope passes the capability gate, dispatches to the
  handler, and resolves with the digest, recovered plaintext, and round-trip
  flag — plus a negative case proving an ungranted command is denied.

## Layout

```
crypto-vanilla/
  zigware.zon              app manifest (window, fuses, CSP)
  src/commands/crypto.zig  the cryptoDemo command + its unit tests
  src/integration_test.zig headless bridge round-trip + gate-denial test
  src/capabilities/        per-window origin grants
  frontend/                static HTML/CSS/JS (no bundler)
```
