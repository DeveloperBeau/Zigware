# {{name}}

A Zigware desktop application with a Svelte + Vite frontend.

## Prerequisites

- Zig 0.16.0
- Node.js 18+ (for the Svelte dev server and production build)

## Install frontend dependencies

```sh
cd frontend
npm install
cd ..
```

## Develop

```sh
zigware dev
```

This starts the Vite dev server (`npm run dev` on http://localhost:5173),
compiles the app in Debug, and launches the window pointed at the dev server.
Editing Svelte files hot-reloads in place; editing Zig sources rebuilds and
restarts the app.

## Build

```sh
zigware build
```

This runs `npm run build` to emit the production frontend into `dist/`,
injects the computed Content-Security-Policy into `index.html`, embeds the
assets, and produces a ReleaseSafe binary.

## Project layout

- `zigware.zon` — app manifest (windows, fuses, build commands).
- `src/commands/greet.zig` — a sample backend command, callable from the
  frontend via `window.Zigware.invoke("greet", { name })`.
- `src/capabilities/main.zon` — nav-origin trust for the `main` window.
- `frontend/` — the Svelte + Vite source; `npm run build` emits `dist/`.

## Regenerate frontend bindings

```sh
zig build dts
```

Writes `frontend/bindings.d.ts` with typed signatures for every command in
`src/commands`.
