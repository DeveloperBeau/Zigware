# Crypto Demo (Svelte)

A Zigware desktop app that hashes a password and runs a ChaCha20-Poly1305
encrypt/decrypt round-trip on the Zig side, with a Svelte 5 + Vite frontend.

## What it does

The frontend collects a `password` and a `message` and calls one Zig command,
`cryptoDemo` (`src/commands/crypto.zig`). On the Zig side it:

1. derives a 32-byte key as `SHA-256(password)`,
2. draws a fresh random 12-byte nonce from the platform CSPRNG,
3. encrypts the message with ChaCha20-Poly1305, and
4. decrypts it back to prove the round-trip closes.

> **Security note.** Using `SHA-256(password)` directly as a cipher key is a
> teaching shortcut, not secure password handling. A real app would stretch the
> password through a KDF (`std.crypto.pwhash.argon2`). This example demonstrates
> the bridge round-trip and the `std.crypto` primitives.

## Prerequisites

- Zig 0.16 and Node.js 18+.

## Run

From the repo root — bundles the Svelte app with Vite into a single `app.js`,
embeds it, and opens the macOS window:

```sh
zig build run-crypto-svelte
```

The window registers `cryptoDemo` through `App.initWithCommands` (`src/main.zig`),
so the button's `window.Zigware.invoke("cryptoDemo", …)` reaches the Zig handler.

## Test

```sh
zig build test-crypto   # from the repo root
```

## Layout

```
crypto-svelte/
  zigware.embed.zon        manifest for the runnable exe (title, show=true)
  src/main.zig             App(MacOSBackend) entry; registers cryptoDemo
  src/commands/crypto.zig  the cryptoDemo command + its unit tests
  index.html               Vite entry (inline styles + CSP); built to dist/
  vite.config.js           single-bundle build (app.js), dev server on 5173
  svelte.config.js         svelte preprocessor config
  frontend/src/App.svelte  the Svelte component
```

The production build emits one external `app.js` (strict `script-src 'self'`);
styles are inline in `index.html`.
