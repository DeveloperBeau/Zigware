# Crypto Demo (React)

A Zigware desktop app that hashes a password and runs a ChaCha20-Poly1305
encrypt/decrypt round-trip on the Zig side, with a React + Vite frontend.

## What it does

The frontend collects a `password` and a `message` and calls one Zig command,
`cryptoDemo` (`src/commands/crypto.zig`). On the Zig side it:

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

## Prerequisites

- Zig 0.16, the `zigware` CLI on your `PATH`, and Node.js 18+.

## Run

```sh
npm install
zigware dev      # runs `npm run dev` (Vite on :5173), Debug build, opens the window
zigware build    # runs `npm run build`, embeds dist/, ReleaseSafe build
```

## Test

The command is a pure function shared by all four crypto examples, so its
round-trip is proven headlessly from the repo root:

```sh
zig build test-crypto
```

## Layout

```
crypto-react/
  zigware.zon              app manifest (window, fuses, build commands)
  src/commands/crypto.zig  the cryptoDemo command + its unit tests
  src/capabilities/        per-window origin grants (app:// + dev server)
  frontend/                React components (entry: frontend/main.jsx)
  index.html               Vite entry document
  vite.config.js           dev server pinned to 5173, builds to dist/
```
