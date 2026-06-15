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

- Zig 0.16 and Node.js 18+.

## Run

From the repo root — this bundles the React app with Vite into a single
`app.js`, embeds it, and opens the macOS window:

```sh
zig build run-crypto-react
```

Type a password and a message, hit **Hash & encrypt**, and the digest /
ciphertext / round-trip come back from `cryptoDemo` in Zig. The window registers
the command through `App.initWithCommands` (`src/main.zig`).

## Test

The command is a pure function shared by all four crypto examples, proven
headlessly from the repo root:

```sh
zig build test-crypto
```

## Layout

```
crypto-react/
  zigware.embed.zon        manifest for the runnable exe (title, show=true)
  src/main.zig             App(MacOSBackend) entry; registers cryptoDemo
  src/commands/crypto.zig  the cryptoDemo command + its unit tests
  index.html               Vite entry (inline styles + CSP); built to dist/
  vite.config.js           single-bundle build (app.js), dev server on 5173
  frontend/                React components (entry: frontend/main.jsx)
```

The production build emits one external `app.js` (no inline scripts, so the
`script-src 'self'` CSP stays strict); styles are inline in `index.html`.
