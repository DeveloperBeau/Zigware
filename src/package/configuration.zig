const std = @import("std");
const manifest = @import("zigware_manifest");

const Manifest = manifest.Manifest;
const Environ = std.process.Environ;

/// macOS-specific signing knobs G reads off the manifest. Distinct from D's
/// `MacOsBundle`: the adapter flattens `minimumSystemVersion` up into
/// `PackageConfig` and drops D fields G's v0.1.0 argv builders never read
/// (`providerShortName`, `hardenedRuntime` is kept for the plist/entitlements path).
pub const MacSignConfig = struct {
    /// codesign identity. The RESOLVED identity (env-over-manifest) is what
    /// `sign` uses; this manifest value is only the fallback source.
    signingIdentity: ?[]const u8 = null,
    hardenedRuntime: bool = true,
    /// Path to an entitlements .plist (reaches an argv slot → leading-`-` checked).
    entitlements: ?[]const u8 = null,
    /// Apple Developer Team ID (notarytool / argv slot → leading-`-` checked).
    teamId: ?[]const u8 = null,
    /// Whether G notarizes the signed artifacts.
    notarize: bool = true,
};

/// Disk-image knobs. v0.1.0 ships a plain dmg with hardcoded hdiutil defaults;
/// only `volname` is configurable, and it reaches the hdiutil argv (leading-`-` checked).
pub const DmgConfig = struct {
    volname: []const u8 = "Install",
};

/// G-owned packaging config, adapted from the D manifest by `configFromManifest`.
/// `displayName`/`bundleVersion` are NON-optional: the adapter unwraps each
/// optional manifest field against its non-optional top-level fallback. All slices
/// here BORROW the parsed manifest (the config is a transient view, not owned).
pub const PackageConfig = struct {
    /// Reverse-DNS bundle identifier (validated via the strict manifest validator).
    identifier: []const u8,
    /// Semver string (validated via std.SemanticVersion.parse).
    version: []const u8,
    /// User-visible name = bundle.displayName orelse manifest.productName.
    displayName: []const u8,
    /// Build version = bundle.bundleVersion orelse manifest.version.
    bundleVersion: []const u8,
    category: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    /// First-present icon path, or null for a no-icon manifest.
    icon: ?[]const u8 = null,
    /// macOS deployment target (e.g. "11.0"). Flattened from bundle.macos.
    minimumSystemVersion: []const u8 = "11.0",
    macos: MacSignConfig = .{},
    dmg: DmgConfig = .{},
};

/// Credential-resolution failures (distinct from the validation set ConfigError).
pub const CredError = error{
    MissingNotaryCredentials,
    MissingSigningIdentity,
};

/// Config-validation failures. The three variants map one-to-one to the
/// `invalid_identifier`/`invalid_version`/`option_injection` Diagnostic codes.
pub const ConfigError = error{
    InvalidIdentifier,
    InvalidVersion,
    OptionInjection,
};

/// App-Store-Connect API-key notary credentials (preferred: only the .p8 PATH
/// reaches argv, never the key bytes).
pub const ApiKeyCreds = struct {
    key_id: []const u8,
    issuer: []const u8,
    key_path: []const u8,
};

/// Apple-ID + app-specific-password notary credentials (fallback: the password
/// necessarily reaches the notarytool argv, which is why API-key is preferred).
pub const AppleIdCreds = struct {
    apple_id: []const u8,
    password: []const u8,
    team_id: []const u8,
};

/// The selected notary strategy. Every populated string is gpa-owned (duped from
/// the env map or manifest), freed uniformly by `freeCredentials`.
pub const Credentials = union(enum) {
    api_key: ApiKeyCreds,
    apple_id: AppleIdCreds,
    none,
};

/// Notary creds + the separately-resolved signing identity. The identity gets its
/// own gpa-owned slot because it resolves independently of notarization (needed
/// even under skip_notarize) and the notary union has no slot for it.
pub const ResolvedCredentials = struct {
    notary: Credentials,
    signing_identity: ?[]const u8,
};

/// Adapt a parsed D manifest into G's transient PackageConfig view. Borrows the
/// manifest's slices (no ownership transfer). Honors Locked decision #3 precedence.
pub fn configFromManifest(m: *const Manifest) PackageConfig {
    const bundle = m.bundle;
    return .{
        .identifier = m.identifier,
        .version = m.version,
        .displayName = bundle.displayName orelse m.productName,
        .bundleVersion = bundle.bundleVersion orelse m.version,
        .category = bundle.category,
        .copyright = bundle.copyright,
        .icon = if (bundle.icon.len > 0) bundle.icon[0] else null,
        .minimumSystemVersion = bundle.macos.minimumSystemVersion,
        .macos = .{
            .signingIdentity = bundle.macos.signingIdentity,
            .hardenedRuntime = bundle.macos.hardenedRuntime,
            .entitlements = bundle.macos.entitlements,
            .teamId = bundle.macos.teamId,
            .notarize = bundle.macos.notarize,
        },
        .dmg = .{},
    };
}

/// Dupe an optional env value into gpa, returning null when the key is absent.
fn dupeEnv(gpa: std.mem.Allocator, env: *const Environ.Map, key: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const v = env.get(key) orelse return null;
    return try gpa.dupe(u8, v);
}

/// Resolve notary credentials (env precedence, completeness-gated) and the signing
/// identity into uniformly gpa-owned slots. `skip_sign`/`skip_notarize` gate the
/// two fail-fast checks. EVERY returned value is a gpa.dupe so `freeCredentials`
/// frees uniformly and the env map's own copies stay independent.
///
/// `io` is accepted for signature parity with the rest of the pipeline; credential
/// resolution needs no I/O (the env map is pre-built by the caller).
pub fn resolveCredentials(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *const Environ.Map,
    cfg: PackageConfig,
    skip_sign: bool,
    skip_notarize: bool,
) (CredError || ConfigError || std.mem.Allocator.Error)!ResolvedCredentials {
    _ = io;

    // Signing identity: $APPLE_SIGNING_IDENTITY, else manifest, else null (skip_sign only).
    var signing_identity: ?[]const u8 = blk: {
        if (env.get("APPLE_SIGNING_IDENTITY")) |v|
            break :blk gpa.dupe(u8, v) catch return error.OutOfMemory;
        if (cfg.macos.signingIdentity) |v|
            break :blk gpa.dupe(u8, v) catch return error.OutOfMemory;
        break :blk null;
    };
    errdefer if (signing_identity) |s| gpa.free(s);
    if (signing_identity == null and !skip_sign) return error.MissingSigningIdentity;
    // Option-injection on an env-sourced identity (`$APPLE_SIGNING_IDENTITY`): codesign
    // would read a leading-`-` value as a flag. The exact ad-hoc identity "-" is the one
    // intended single dash and is allowed; anything else starting with `-` is rejected.
    if (signing_identity) |s| {
        if (!std.mem.eql(u8, s, "-")) try rejectLeadingDash(s);
    }

    // Notary: completeness-gated, API-key preferred over Apple-ID.
    const api_key = env.get("APPLE_API_KEY");
    const api_issuer = env.get("APPLE_API_ISSUER");
    const api_path = env.get("APPLE_API_KEY_PATH");
    const api_complete = api_key != null and api_issuer != null and api_path != null;

    const aid = env.get("APPLE_ID");
    const aid_pw = env.get("APPLE_PASSWORD");
    const aid_team = env.get("APPLE_TEAM_ID");
    const aid_complete = aid != null and aid_pw != null and aid_team != null;

    var notary: Credentials = .none;
    errdefer freeNotary(gpa, notary);

    if (api_complete) {
        // Option-injection: notarytool reads a leading-`-` value after --key-id/--issuer/--key
        // as a flag. Check the env values BEFORE duping so a reject allocates nothing.
        try rejectLeadingDash(api_key.?);
        try rejectLeadingDash(api_issuer.?);
        try rejectLeadingDash(api_path.?);
        // Dupe into locals with per-local errdefer so a mid-set OOM never leaves an
        // `undefined` slice for the function-level errdefer to free-of-garbage. The
        // union is assigned only once all three dupes succeed.
        const key_id = gpa.dupe(u8, api_key.?) catch return error.OutOfMemory;
        errdefer gpa.free(key_id);
        const issuer = gpa.dupe(u8, api_issuer.?) catch return error.OutOfMemory;
        errdefer gpa.free(issuer);
        const key_path = gpa.dupe(u8, api_path.?) catch return error.OutOfMemory;
        notary = .{ .api_key = .{ .key_id = key_id, .issuer = issuer, .key_path = key_path } };
    } else if (aid_complete) {
        try rejectLeadingDash(aid.?);
        try rejectLeadingDash(aid_pw.?);
        try rejectLeadingDash(aid_team.?);
        const apple_id = gpa.dupe(u8, aid.?) catch return error.OutOfMemory;
        errdefer gpa.free(apple_id);
        const password = gpa.dupe(u8, aid_pw.?) catch return error.OutOfMemory;
        errdefer gpa.free(password);
        const team_id = gpa.dupe(u8, aid_team.?) catch return error.OutOfMemory;
        notary = .{ .apple_id = .{ .apple_id = apple_id, .password = password, .team_id = team_id } };
    } else {
        // Neither set complete. Fail-fast only when notarization is required.
        const notarize_required = cfg.macos.notarize and !skip_notarize;
        if (notarize_required) return error.MissingNotaryCredentials;
    }

    const result = ResolvedCredentials{ .notary = notary, .signing_identity = signing_identity };
    notary = .none; // ownership moved into result; defuse the notary errdefer
    signing_identity = null; // defuse the identity errdefer
    return result;
}

/// Free the populated strings of whichever notary arm is active (`.none` frees nothing).
fn freeNotary(gpa: std.mem.Allocator, notary: Credentials) void {
    switch (notary) {
        .api_key => |k| {
            gpa.free(k.key_id);
            gpa.free(k.issuer);
            gpa.free(k.key_path);
        },
        .apple_id => |a| {
            gpa.free(a.apple_id);
            gpa.free(a.password);
            gpa.free(a.team_id);
        },
        .none => {},
    }
}

/// Free both the active notary arm AND the signing-identity slot. Symmetric with
/// the dupe set in `resolveCredentials`; safe on every exit path.
pub fn freeCredentials(gpa: std.mem.Allocator, creds: ResolvedCredentials) void {
    freeNotary(gpa, creds.notary);
    if (creds.signing_identity) |s| gpa.free(s);
}

/// Reject any free-text value that, placed in an argv slot, a tool would read as a
/// flag (option-injection). An empty string is not a leading dash and is allowed here.
fn rejectLeadingDash(s: []const u8) ConfigError!void {
    if (s.len > 0 and s[0] == '-') return error.OptionInjection;
}

fn rejectLeadingDashOpt(s: ?[]const u8) ConfigError!void {
    if (s) |v| try rejectLeadingDash(v);
}

/// Reject a value that becomes a filesystem name (the `.app` directory from
/// `displayName`, the `.dmg` from `volname`): a `/` or `..` would escape the intended
/// directory. Reuses `OptionInjection` as the "unsafe in its slot" reject.
fn rejectPathSep(s: []const u8) ConfigError!void {
    if (std.mem.indexOfScalar(u8, s, '/') != null) return error.OptionInjection;
    if (std.mem.indexOf(u8, s, "..") != null) return error.OptionInjection;
}

/// Preflight the config before any filesystem/child-process work: strict reverse-DNS
/// identifier, semver version, and a leading-`-` sweep over EVERY value that reaches
/// an argv slot (Locked decision #7).
pub fn validateConfig(cfg: PackageConfig) ConfigError!void {
    if (!manifest.isValidReverseDns(cfg.identifier)) return error.InvalidIdentifier;
    _ = std.SemanticVersion.parse(cfg.version) catch return error.InvalidVersion;

    try rejectLeadingDash(cfg.displayName);
    try rejectLeadingDashOpt(cfg.category);
    try rejectLeadingDashOpt(cfg.copyright);
    try rejectLeadingDashOpt(cfg.icon);
    try rejectLeadingDashOpt(cfg.macos.signingIdentity);
    try rejectLeadingDashOpt(cfg.macos.teamId);
    try rejectLeadingDashOpt(cfg.macos.entitlements);
    try rejectLeadingDash(cfg.dmg.volname);

    // The .app directory name (displayName) and the .dmg name (volname) must not carry
    // path separators that would place the artifact outside its intended directory.
    try rejectPathSep(cfg.displayName);
    try rejectPathSep(cfg.dmg.volname);
}

test "configFromManifest maps fields with bundle-override precedence" {
    const m = Manifest{
        .identifier = "com.example.app",
        .productName = "FallbackName",
        .version = "1.2.3",
        .bundle = .{
            .icon = &.{ "assets/icon.png", "assets/other.png" },
            .category = "public.app-category.utilities",
            .copyright = "(c) 2026 Example",
            .bundleVersion = "9.9.9",
            .displayName = "OverrideName",
            .macos = .{
                .signingIdentity = "Developer ID Application: Example (TEAMID)",
                .teamId = "TEAMID1234",
                .notarize = false,
                .entitlements = "ent.plist",
                .hardenedRuntime = true,
                .minimumSystemVersion = "12.0",
            },
        },
    };
    const cfg = configFromManifest(&m);
    try std.testing.expectEqualStrings("com.example.app", cfg.identifier);
    try std.testing.expectEqualStrings("1.2.3", cfg.version);
    // Bundle override wins for displayName/bundleVersion.
    try std.testing.expectEqualStrings("OverrideName", cfg.displayName);
    try std.testing.expectEqualStrings("9.9.9", cfg.bundleVersion);
    try std.testing.expectEqualStrings("public.app-category.utilities", cfg.category.?);
    try std.testing.expectEqualStrings("(c) 2026 Example", cfg.copyright.?);
    try std.testing.expectEqualStrings("assets/icon.png", cfg.icon.?); // first-present wins
    try std.testing.expectEqualStrings("12.0", cfg.minimumSystemVersion);
    try std.testing.expectEqualStrings("Developer ID Application: Example (TEAMID)", cfg.macos.signingIdentity.?);
    try std.testing.expectEqualStrings("TEAMID1234", cfg.macos.teamId.?);
    try std.testing.expectEqual(false, cfg.macos.notarize);
    try std.testing.expectEqualStrings("ent.plist", cfg.macos.entitlements.?);
}

test "configFromManifest falls back to top-level productName and version" {
    const m = Manifest{
        .identifier = "com.example.app",
        .productName = "TopName",
        .version = "0.4.0",
        .bundle = .{}, // bundleVersion/displayName null → fallbacks
    };
    const cfg = configFromManifest(&m);
    try std.testing.expectEqualStrings("TopName", cfg.displayName);
    try std.testing.expectEqualStrings("0.4.0", cfg.bundleVersion);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.category);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.copyright);
    try std.testing.expectEqual(true, cfg.macos.notarize); // default
}

test "configFromManifest no-icon manifest yields null icon (no bounds panic)" {
    const m = Manifest{
        .identifier = "com.example.app",
        .productName = "App",
        .version = "1.0.0",
        .bundle = .{ .icon = &.{} },
    };
    const cfg = configFromManifest(&m);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.icon);
}

fn testCfg() PackageConfig {
    return .{
        .identifier = "com.example.app",
        .version = "1.0.0",
        .displayName = "App",
        .bundleVersion = "1.0.0",
        .category = null,
        .copyright = null,
        .icon = null,
        .minimumSystemVersion = "11.0",
        .macos = .{},
        .dmg = .{},
    };
}

fn mapWith(gpa: std.mem.Allocator, pairs: []const [2][]const u8) !Environ.Map {
    var map = Environ.Map.init(gpa);
    errdefer map.deinit();
    for (pairs) |p| try map.put(p[0], p[1]);
    return map;
}

test "resolveCredentials prefers API-key when complete; env over manifest" {
    const gpa = std.testing.allocator;
    var cfg = testCfg();
    cfg.macos.signingIdentity = "ManifestIdentity";
    var env = try mapWith(gpa, &.{
        .{ "APPLE_API_KEY", "AbCdEf12" },
        .{ "APPLE_API_ISSUER", "issuer-uuid" },
        .{ "APPLE_API_KEY_PATH", "/keys/AuthKey.p8" },
        .{ "APPLE_SIGNING_IDENTITY", "EnvIdentity" },
    });
    defer env.deinit();
    const creds = try resolveCredentials(std.testing.io, gpa, &env, cfg, false, false);
    defer freeCredentials(gpa, creds);
    try std.testing.expect(creds.notary == .api_key);
    try std.testing.expectEqualStrings("AbCdEf12", creds.notary.api_key.key_id);
    try std.testing.expectEqualStrings("issuer-uuid", creds.notary.api_key.issuer);
    try std.testing.expectEqualStrings("/keys/AuthKey.p8", creds.notary.api_key.key_path);
    // Env identity overrides the manifest one.
    try std.testing.expectEqualStrings("EnvIdentity", creds.signing_identity.?);
}

test "resolveCredentials partial API-key does not shadow a complete Apple-ID set" {
    const gpa = std.testing.allocator;
    var cfg = testCfg();
    cfg.macos.signingIdentity = "ManifestIdentity";
    var env = try mapWith(gpa, &.{
        .{ "APPLE_API_KEY", "AbCdEf12" }, // only 2 of 3 → incomplete
        .{ "APPLE_API_ISSUER", "issuer-uuid" },
        .{ "APPLE_ID", "dev@example.com" },
        .{ "APPLE_PASSWORD", "app-specific-pw" },
        .{ "APPLE_TEAM_ID", "TEAMID1234" },
    });
    defer env.deinit();
    const creds = try resolveCredentials(std.testing.io, gpa, &env, cfg, false, false);
    defer freeCredentials(gpa, creds);
    try std.testing.expect(creds.notary == .apple_id);
    try std.testing.expectEqualStrings("dev@example.com", creds.notary.apple_id.apple_id);
    try std.testing.expectEqualStrings("app-specific-pw", creds.notary.apple_id.password);
    try std.testing.expectEqualStrings("TEAMID1234", creds.notary.apple_id.team_id);
    // No env identity → falls back to (duped) manifest identity.
    try std.testing.expectEqualStrings("ManifestIdentity", creds.signing_identity.?);
}

test "resolveCredentials raises MissingNotaryCredentials on partial sets when notarize required" {
    const gpa = std.testing.allocator;
    var cfg = testCfg();
    cfg.macos.signingIdentity = "ManifestIdentity";
    var env = try mapWith(gpa, &.{
        .{ "APPLE_API_KEY", "AbCdEf12" }, // partial API-key
        .{ "APPLE_ID", "dev@example.com" }, // partial Apple-ID
    });
    defer env.deinit();
    const r = resolveCredentials(std.testing.io, gpa, &env, cfg, false, false);
    try std.testing.expectError(error.MissingNotaryCredentials, r);
}

test "resolveCredentials returns .none when notarize disabled and no notary set" {
    const gpa = std.testing.allocator;
    var cfg = testCfg();
    cfg.macos.signingIdentity = "ManifestIdentity";
    var env = try mapWith(gpa, &.{});
    defer env.deinit();
    // skip_notarize = true
    const creds = try resolveCredentials(std.testing.io, gpa, &env, cfg, false, true);
    defer freeCredentials(gpa, creds);
    try std.testing.expect(creds.notary == .none);
    try std.testing.expectEqualStrings("ManifestIdentity", creds.signing_identity.?);
}

test "resolveCredentials fails MissingSigningIdentity when no identity and not skip_sign" {
    const gpa = std.testing.allocator;
    var cfg = testCfg();
    cfg.macos.signingIdentity = null;
    var env = try mapWith(gpa, &.{});
    defer env.deinit();
    const r = resolveCredentials(std.testing.io, gpa, &env, cfg, false, true);
    try std.testing.expectError(error.MissingSigningIdentity, r);
}

test "resolveCredentials skip_sign yields null signing_identity and no error" {
    const gpa = std.testing.allocator;
    var cfg = testCfg();
    cfg.macos.signingIdentity = null;
    var env = try mapWith(gpa, &.{});
    defer env.deinit();
    // skip_sign = true, skip_notarize = true
    const creds = try resolveCredentials(std.testing.io, gpa, &env, cfg, true, true);
    defer freeCredentials(gpa, creds);
    try std.testing.expectEqual(@as(?[]const u8, null), creds.signing_identity);
    try std.testing.expect(creds.notary == .none);
}

test "resolveCredentials config-sourced signing identity is gpa-owned (leak-clean)" {
    const gpa = std.testing.allocator;
    var cfg = testCfg();
    cfg.macos.signingIdentity = "ManifestIdentity";
    var env = try mapWith(gpa, &.{});
    defer env.deinit();
    const creds = try resolveCredentials(std.testing.io, gpa, &env, cfg, false, true);
    defer freeCredentials(gpa, creds);
    try std.testing.expectEqualStrings("ManifestIdentity", creds.signing_identity.?);
}

test "resolveCredentials apple-id path is leak-clean over testing allocator" {
    const gpa = std.testing.allocator;
    var cfg = testCfg();
    cfg.macos.signingIdentity = "ManifestIdentity";
    var env = try mapWith(gpa, &.{
        .{ "APPLE_ID", "dev@example.com" },
        .{ "APPLE_PASSWORD", "app-specific-pw" },
        .{ "APPLE_TEAM_ID", "TEAMID1234" },
    });
    defer env.deinit();
    const creds = try resolveCredentials(std.testing.io, gpa, &env, cfg, false, false);
    defer freeCredentials(gpa, creds);
    try std.testing.expect(creds.notary == .apple_id);
}

test "validateConfig accepts a clean config" {
    const cfg = testCfg();
    try validateConfig(cfg);
}

test "validateConfig rejects an invalid reverse-DNS identifier" {
    var cfg = testCfg();
    cfg.identifier = "notreversedns"; // single label, no dots
    try std.testing.expectError(error.InvalidIdentifier, validateConfig(cfg));
}

test "validateConfig rejects an invalid version" {
    var cfg = testCfg();
    cfg.version = "not.a.version";
    try std.testing.expectError(error.InvalidVersion, validateConfig(cfg));
}

test "validateConfig rejects leading-dash argv values" {
    {
        var cfg = testCfg();
        cfg.displayName = "-evil";
        try std.testing.expectError(error.OptionInjection, validateConfig(cfg));
    }
    {
        var cfg = testCfg();
        cfg.macos.entitlements = "-rf";
        try std.testing.expectError(error.OptionInjection, validateConfig(cfg));
    }
    {
        var cfg = testCfg();
        cfg.icon = "-payload.png";
        try std.testing.expectError(error.OptionInjection, validateConfig(cfg));
    }
    {
        var cfg = testCfg();
        cfg.dmg.volname = "-volname";
        try std.testing.expectError(error.OptionInjection, validateConfig(cfg));
    }
    {
        var cfg = testCfg();
        cfg.macos.teamId = "-TEAM";
        try std.testing.expectError(error.OptionInjection, validateConfig(cfg));
    }
}

test "validateConfig rejects path separators in the names that become files" {
    {
        var cfg = testCfg();
        cfg.displayName = "Evil/App";
        try std.testing.expectError(error.OptionInjection, validateConfig(cfg));
    }
    {
        var cfg = testCfg();
        cfg.displayName = "..";
        try std.testing.expectError(error.OptionInjection, validateConfig(cfg));
    }
    {
        var cfg = testCfg();
        cfg.dmg.volname = "../escape";
        try std.testing.expectError(error.OptionInjection, validateConfig(cfg));
    }
}

test "resolveCredentials rejects a leading-dash env identity but allows ad-hoc dash" {
    const gpa = std.testing.allocator;
    const cfg = testCfg();
    {
        var env = try mapWith(gpa, &.{.{ "APPLE_SIGNING_IDENTITY", "-x" }});
        defer env.deinit();
        try std.testing.expectError(error.OptionInjection, resolveCredentials(std.testing.io, gpa, &env, cfg, false, true));
    }
    {
        // The exact ad-hoc identity "-" is the one allowed single dash.
        var env = try mapWith(gpa, &.{.{ "APPLE_SIGNING_IDENTITY", "-" }});
        defer env.deinit();
        const creds = try resolveCredentials(std.testing.io, gpa, &env, cfg, false, true);
        defer freeCredentials(gpa, creds);
        try std.testing.expectEqualStrings("-", creds.signing_identity.?);
    }
}

test "resolveCredentials rejects a leading-dash env notary value" {
    const gpa = std.testing.allocator;
    var cfg = testCfg();
    cfg.macos.signingIdentity = "ManifestIdentity";
    var env = try mapWith(gpa, &.{
        .{ "APPLE_API_KEY", "-badkeyid" },
        .{ "APPLE_API_ISSUER", "issuer-uuid" },
        .{ "APPLE_API_KEY_PATH", "/keys/AuthKey.p8" },
    });
    defer env.deinit();
    try std.testing.expectError(error.OptionInjection, resolveCredentials(std.testing.io, gpa, &env, cfg, false, false));
}
