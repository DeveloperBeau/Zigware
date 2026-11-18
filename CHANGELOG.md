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
