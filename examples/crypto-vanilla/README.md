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

From the repo root, build and open the real macOS window — type a password and a
message, hit **Hash & encrypt**, and the digest/ciphertext/round-trip come back
from Zig:

```sh
zig build run-crypto
```

The window registers `cryptoDemo` through `App.initWithCommands` (see
`src/main.zig`), which composes it with the framework builtins and grants it to
the window — so `window.Zigware.invoke("cryptoDemo", …)` reaches the Zig handler.

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
  src/main.zig             App(MacOSBackend) entry; registers cryptoDemo
  src/commands/crypto.zig  the cryptoDemo command + its unit tests
  src/integration_test.zig headless bridge + App round-trip + gate-denial tests
  src/capabilities/        per-window origin grants
  frontend/                static HTML (inline CSS) + app.js, no bundler
```
