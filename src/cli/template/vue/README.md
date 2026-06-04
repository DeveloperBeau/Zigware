# {{name}}

A Zigware desktop app with a Vue + Vite frontend.

## Prerequisites

- [Zig](https://ziglang.org/) 0.16
- [Node.js](https://nodejs.org/) 18 or newer
- The `zigware` CLI on your `PATH`

## Getting started

Install the frontend dependencies:

```sh
cd frontend
npm install
cd ..
```

## Develop

```sh
zigware dev
```

This runs `npm run dev` (Vite on http://localhost:5173), waits for the dev
server, then launches the app pointed at it. Saving a `.zig` source file rebuilds
and restarts the app; saving frontend files hot-reloads through Vite.

## Build

```sh
zigware build
```

This runs `npm run build` (Vite emits `frontend/dist`), embeds the built assets
with a strict Content-Security-Policy, and produces a release binary.

## Project layout

- `zigware.zon` — app manifest (windows, security fuses, build commands)
- `src/commands/greet.zig` — native commands callable from JS via
  `window.Zigware.invoke`
- `frontend/` — Vue + Vite source; `frontend/dist` is the built output

Native command signatures are mirrored into `frontend/bindings.d.ts` by
`zig build dts`.
