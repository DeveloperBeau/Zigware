# {{name}}

A Zigware desktop app with a plain HTML/JS frontend. No build tooling, no
package manager: the frontend is served directly from source.

## Prerequisites

- [Zig 0.16](https://ziglang.org/download/)
- The `zigware` CLI on your `PATH`

## Develop

```sh
cd {{name}}
zigware dev
```

This builds the app in Debug and opens the main window. The frontend in
`frontend/` is served straight through the `app://` scheme, so there is no dev
server to start. Saving a `.zig` source file or `zigware.zon` restarts the app;
reload the window to pick up frontend edits.

## Build

```sh
zigware build
```

This computes a strict Content-Security-Policy with per-script hashes, embeds the
`frontend/` assets, and produces a ReleaseSafe binary.

## Project layout

```
{{name}}/
  zigware.zon          app manifest (windows, fuses, build commands)
  src/capabilities/    per-window navigation and permission grants
  src/commands/        Zig command handlers exposed to the frontend
  frontend/            plain HTML/CSS/JS served directly (entry: index.html)
```

## Calling Zig from the frontend

Command handlers live in `src/commands/`. The sample `greet` command is invoked
from `frontend/app.js`:

```js
const result = await window.Zigware.invoke("greet", { name: "world" });
```

Regenerate the TypeScript declarations for your commands with:

```sh
zig build dts
```
