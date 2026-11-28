# Changelog

## 0.2.0

### Breaking

- Renamed the snake_case keys in the capability schema to camelCase to match the
  rest of the manifest. In `zigware.zon` and `src/grants/*.zon`, update:
  - `commands_allow` to `commandsAllow`
  - `commands_deny` to `commandsDeny`
  - `scope_allow` to `scopeAllow`
  - `scope_deny` to `scopeDeny`
  - `dev_url` to `devUrl`
  - `https_exact` to `httpsExact`
  - `app_scheme` to `appScheme`

- The minimum Zig version is 0.17.1. Zig 0.16.0 can no longer build the
  framework or a consumer that depends on it.
- Zig 0.17 renamed the optimize mode tags. In a consumer `build.zig`, write
  `.debug`, `.safe`, `.fast` and `.small` in place of `.Debug`, `.ReleaseSafe`,
  `.ReleaseFast` and `.ReleaseSmall`. The error string
  `Zigware ships ReleaseSafe or Debug only` is unchanged.
- A ZON parse failure in a manifest diagnostic now reads
  `<file>:<line>:<col>: error: ...`. It previously read
  `<file>: <line>:<col>: error: ...`.
