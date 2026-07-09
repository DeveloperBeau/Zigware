# CLI (`src/cli/`)

## Purpose

The `zigware`/`zw` CLI owns project scaffolding, the dev loop, and release
orchestration. It exposes three verbs (`init`, `dev`, `build`) built over
dependency-injection seams so the logic is testable while production runs real
child processes (`zig`, `npm`, before-commands) with clean shutdown.

## Key files

| File | Responsibility |
|------|----------------|
| `main.zig` | Verb dispatch, error→exit-code mapping, SIGINT install, reads the manifest from cwd, `SystemBuildRunner` (real `zig build`). |
| `init.zig` | Scaffolding: writes the embedded template set, substitutes tokens (name, identifier, fingerprint, framework-dep path). |
| `build.zig` | Release orchestration: before-build command, frontend walk, CSP inject, asset staging, `asset_table.zig` emission, release compile. |
| `dev.zig` | Dev loop: `BuildRunner`/`BuildSpec`/`DevContext` seams, rebuild-on-change, ordered child teardown. |
| `watch.zig` | Polling file watcher (`src/` + `zigware.zon`), debounced batches, shutdown-responsive sleep slices. |
| `devserver.zig` | `waitForUrl` probe for the dev-server URL (backoff, shutdown-gated, 30s default). |
| `proc.zig` | Child-process `Spawner` seam: spawn/wait/kill, process groups, env merge, SIGTERM→SIGKILL grace. |
| `csp.zig` | CSP build: SHA-256 script hashing, deny-scan, fail-closed `<meta>` injection (see [security.md](security.md)). |
| `assetsEmbed.zig` | Frontend-dist walk (realpath containment), MIME table, `asset_table.zig` emission. |
| `template/` | The scaffold template set (the generated project's `build.zig`, `build.zig.zon`, `src/main.zig`, frontend, `zigware.zon`). |

## Seams (dependency injection)

All exist so the verb logic can run over fakes in tests:

- **`Spawner`** (`proc.zig`): a `spawn`/`wait`/`kill` vtable over `ChildSpec`.
- **`BuildRunner`** (`dev.zig`): `build(BuildSpec) → BuildResult`; production
  `SystemBuildRunner` shells `zig build`. `BuildSpec` carries `optimize`, `dev`,
  and an optional `asset_table` path.
- **`Watcher`** (`watch.zig`): `next() → ?[]ChangedPath`, `close()`.
- **`UrlProbe`** (`dev.zig`): a thin wrapper over `devserver.waitForUrl`; tests
  inject a timeout-returning fake.

## Verbs

**`init`**: parse args (`--template`, `--force`, `--name`, `--framework-path` or
`ZIGWARE_FRAMEWORK_PATH`); resolve the framework path to an absolute path; scaffold
(create/empty-check target, compute substitutions, write `_shared` + template
files). The package fingerprint is deterministic: `crc32(name_ident)` in the high
32 bits (which Zig validates against the package name) and a `Wyhash` id in the
low 32. The framework dependency is written as a **relative** path (Zig rejects
absolute path deps). See [manifest.md](manifest.md) for the generated `zigware.zon`.

**`dev`**: read manifest (Debug; the debug-inspector fuse is allowed here),
install SIGINT onto an atomic shutdown flag, start the polling watcher, then run
the dev loop: spawn `frontend.dev` (own process group), wait for `frontend.serveUrl`
(vanilla skips), initial Debug build, spawn the app, loop on watcher batches
rebuilding+respawning. Ordered teardown on every exit path: kill app → kill
beforeDev → close watcher.

**`build`**: read manifest (ReleaseSafe; debug-inspector forbidden), run the
orchestrator: before-build command → walk dist → hash scripts → build strict CSP
→ inject into `index.html` → stage all assets colocated with a generated
`asset_table.zig` → release compile via `zig build -Drelease=true
-Dasset_table=<staged>/asset_table.zig` → hand the binary to packaging
(see [packaging.md](packaging.md)).

## Dependencies

Imports the `zigware_manifest` (parser), `package`, and `diag` modules. Consumed
by the build system (which embeds the templates) and the test harness (which
injects fakes).

## Invariants

- **ReleaseSafe only** for release; `-Drelease=true`, never `-Doptimize` (the
  framework registers `-Drelease`, not `-Doptimize`).
- **`inherit_stdio = true` for all non-test spawns.** `false` detaches all three
  std streams to `/dev/null` and is used **only by tests**: a child that inherited the
  test runner's `--listen=-` stdout/stdin would deadlock `zig build`. See the loud note
  on `ChildSpec.inherit_stdio` in `proc.zig`.
- **Dev children run in their own process group** so an interactive Ctrl-C reaches
  the CLI alone; teardown signals the whole group to also kill grandchildren
  (e.g. Vite under `npm run dev`).
- **Asset table is colocated with the staged assets**, so its `@embedFile` names
  resolve from the table's own directory (not prefixed `staged/`).
- **CSP fails closed**: a differing author `<meta>` CSP is an error, never a
  silent overwrite.
- **Ordered teardown on every exit path**, and a distinct exit code per error
  variant (exhaustive switch makes a new variant a compile error).

## Process / threading model

Children are spawned through the `Spawner` seam: the app and `frontend.dev`
run in their own process groups with inherited stdio; `frontend.build` runs
to completion (failure is fatal). The watcher rechecks the shutdown flag in small
sleep slices so SIGINT is observed promptly. A failed dev rebuild leaves the
running app alive so the next good build can replace it.
