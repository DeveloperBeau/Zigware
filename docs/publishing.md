# Publishing and consuming the zigware package

This document covers two ways to consume the framework: the URL+hash mode for
external projects, and the relative-path mode used by the in-repo examples and
tests.

---

## URL+hash mode (external consumer)

Once a release tag exists on the framework repo, an external project's
`build.zig.zon` declares the dependency like this:

```zig
.dependencies = .{
    .zigware = .{
        .url = "https://github.com/DeveloperBeau/zigware/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "<the hash zig prints on first fetch>",
    },
},
```

The hash field is not invented manually. To get it, run `zig fetch` once inside
the consumer project:

```sh
zig fetch --save=zigware \
  https://github.com/DeveloperBeau/zigware/archive/refs/tags/v0.1.0.tar.gz
```

Zig downloads the archive, computes the content hash, and writes the `.hash`
value directly into `build.zig.zon`. Commit that updated file; subsequent builds
use the cached value without a network round-trip.

### Verifying locally

`tests/fetch-consumer/gate.sh` is runnable proof: it builds a local tarball of
the framework with `git archive`, runs `zig fetch` against it, and compiles a
minimal consumer. This replicates what GitHub serves for a real tag tarball
(Zig hashes only the `.paths` content, so the hash is identical). Run it
directly to confirm the mechanism without needing a published tag.

### Release steps for a maintainer

1. Merge work into `main` and verify `zig build` exits clean.
2. Tag the commit and push: `git tag v0.1.0 && git push origin v0.1.0`.
   The `.github/workflows/release.yml` workflow triggers on the tag push,
   builds the framework, and creates the GitHub Release automatically.
   GitHub serves the tag archive at the URL above; no manual release step
   is needed.

### What the tarball includes

The framework `build.zig.zon` lists explicit paths:

```zig
.paths = .{ "build.zig", "build.zig.zon", "build_helpers.zig", "zigware.zon", "src", "frontend" },
```

This means `examples/` and `tests/` are excluded from the published tarball. A
consumer cannot accidentally resolve a self-surface path while still receiving
the public API surface the consumer build imports (`src/`, `build_helpers.zig`,
the manifest schema, and the frontend shim).

---

## Relative-path mode (in-repo examples and tests)

The in-repo examples under `examples/*` and the gate fixtures under `tests/*`
reference the framework by relative path:

```zig
.dependencies = .{
    .zigware = .{ .path = "../.." },
},
```

This is the supported path for P1 development. The examples do not depend on the
published mode and do not require a tag or network fetch.

---

## The `tests/release-ban-consumer` fixture

`tests/release-ban-consumer` is a dedicated ReleaseFast-ban fixture, committed
and wired as the gate's fourth check, that proves the comptime ban fires for an
external consumer. Its `build.zig` forces
`.optimize = .ReleaseFast` at the module level. When `zig build` runs inside
that directory, the framework barrel (`src/zigware.zig`) triggers:

```zig
comptime {
    if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
        @compileError("Zigware ships ReleaseSafe or Debug only");
    }
}
```

The gate script (`tests/scaffold-consumer/gate.sh`) asserts that the build
fails with that exact message. Success means the ban is working; an unexpected
clean build or a different error causes the gate to fail.

The fixture uses the same relative-path dep as the other in-repo consumers. The
`tests/fetch-consumer` gate proves url+hash consumption on every CI run by
fetching a locally-archived tarball, so the mechanism is verified even before a
public tag is pushed.

---

## Note on `-Doptimize` vs module-level optimize

The scaffold-shaped `build.zig` registers a `-Drelease` boolean flag (not
`-Doptimize`). Passing `-Doptimize=ReleaseFast` on the command line produces an
"unknown option" error before any Zig code compiles, so it never reaches the
comptime ban. To exercise the ban in a test, set `.optimize = .ReleaseFast`
directly in the `addApp` call, not via CLI flags.
