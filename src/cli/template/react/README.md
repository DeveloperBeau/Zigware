# {{name}}

A Zigware desktop app with a React + Vite frontend.

## Prerequisites

- [Zig 0.16](https://ziglang.org/download/)
- The `zigware` CLI on your `PATH`
- Node.js 18+ (for the Vite dev server and production build)

## Getting started

```sh
cd {{name}}
npm install
```

## Develop

```sh
zigware dev
```

This runs `npm run dev` (Vite on http://localhost:5173), builds the app in
Debug, and opens the main window pointed at the dev server. Saving a `.zig`
source file or `zigware.zon` restarts the app; frontend edits hot-reload through
Vite.

## Build

```sh
zigware build
```

This runs `npm run build` (emitting the production frontend to `dist/`),
computes a strict Content-Security-Policy with per-script hashes, embeds the
assets, and produces a ReleaseSafe binary.

## Project layout

```
{{name}}/
  zigware.zon          app manifest (windows, fuses, build commands)
  capabilities/        per-window navigation and permission grants
  src/commands/        Zig command handlers exposed to the frontend
  frontend/            React components (entry: frontend/main.jsx)
  index.html           Vite entry document
  vite.config.js       dev server pinned to port 5173, builds to dist/
```

## Calling Zig from the frontend

Command handlers live in `src/commands/`. The sample `greet` command is invoked
from `frontend/App.jsx`:

```js
const result = await window.Zigware.invoke("greet", { name: "world" });
```

Regenerate the TypeScript declarations for your commands with:

```sh
zig build dts
```
