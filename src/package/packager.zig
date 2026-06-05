const std = @import("std");

const config = @import("config.zig");
const diagnostics = @import("diagnostics.zig");
const runner_mod = @import("runner.zig");
const bundle = @import("bundle.zig");
const sign_mod = @import("sign.zig");
const notarize_mod = @import("notarize.zig");
const dmg_mod = @import("dmg.zig");

const PackageConfig = config.PackageConfig;
const Credentials = config.Credentials;
const ResolvedCredentials = config.ResolvedCredentials;
const Environ = std.process.Environ;

// Public re-exports so the CLI (which reaches the packaging module only through
// `@import("package")` = this file) can name the runner, the structured diagnostic,
// and the manifest adapter without path-importing the sibling files.
pub const Runner = runner_mod.Runner;
pub const SystemRunner = runner_mod.SystemRunner;
pub const Diagnostic = diagnostics.Diagnostic;
pub const Code = diagnostics.Code;
pub const PackageError = diagnostics.PackageError;
pub const configFromManifest = config.configFromManifest;

/// Record-and-drive fake runner, re-exported so the CLI's build-verb integration tests
/// can script the packaging child-process sequence without a real toolchain.
pub const FakeRunnerForTest = runner_mod.FakeRunner;

pub const Arch = enum { host }; // universal (lipo arm64 + x86_64) reserved for v0.2

/// The F -> G handoff struct. F populates the binary; G fills the rest and returns it.
/// THIS is the single definition; src/cli imports it (do not redefine in cli/build.zig).
///
/// OWNERSHIP: ALL string fields (`binary_path`, `app_name`, `bundle_id`, `version`,
/// and the optional `icon_path`/`entitlements_path`/`signing_identity` when present)
/// are `opts.gpa`-owned dupes. `package()` dupes `binaries[0]` into `binary_path` and
/// dupes the resolved `signing_identity`/other config-sourced fields rather than
/// borrowing the parsed manifest or `opts.binaries`. The caller (the T11 pipeline test
/// and T12's `main`) MUST free the returned value via `deinit` after consuming it; the
/// leak-clean test over `std.testing.allocator` depends on this contract.
pub const Artifacts = struct {
    binary_path: []const u8,
    app_name: []const u8,
    bundle_id: []const u8,
    version: []const u8,
    icon_path: ?[]const u8,
    entitlements_path: ?[]const u8,
    signing_identity: ?[]const u8,
    frontend_embedded: bool,
    arch: Arch,

    /// Frees every gpa-owned string field. Mirrors the dupe set in `package()`.
    pub fn deinit(self: Artifacts, gpa: std.mem.Allocator) void {
        gpa.free(self.binary_path);
        gpa.free(self.app_name);
        gpa.free(self.bundle_id);
        gpa.free(self.version);
        if (self.icon_path) |p| gpa.free(p);
        if (self.entitlements_path) |p| gpa.free(p);
        if (self.signing_identity) |p| gpa.free(p);
    }
};

const required_packager_methods = [_][]const u8{ "assembleBundle", "sign", "notarize", "makeDmg" };

/// Comptime conformance: a future Windows/Linux packager missing a stage is a clear
/// compile error, not a cryptic instantiation failure (mirrors assertBackend).
pub fn assertPackager(comptime P: type) void {
    comptime {
        for (required_packager_methods) |name| {
            if (!@hasDecl(P, name)) @compileError(@typeName(P) ++ " is missing packager method: " ++ name);
            if (@typeInfo(@TypeOf(@field(P, name))) != .@"fn")
                @compileError(@typeName(P) ++ "." ++ name ++ " is not a fn");
        }
    }
}

// NOTE: there is NO `Packager(P)` wrapper type. The conformance seam is `assertPackager`
// alone, called once at the `builtin.os` packager-selection site in `package()` (Task 11) —
// exactly as `src/app.zig:93` calls `assertBackend(B)` at its selection site. A holds no
// `Backend(P)` wrapper either; its only comptime gate is `assertBackend`. `MacPackager`'s
// four stages are then called individually by `package()`, never through an instantiated
// generic. Do NOT add an empty `Packager(P)` wrapper — it would hold no state, forward
// nothing, and have no callers.

// ---------------------------------------------------------------------------
// PackageOptions — the F -> G handoff inputs (spec lines 72-86). `gpa` lives
// INSIDE the options so `package(io, opts)` stays a two-arg entry. The env map is
// NOT a field: it is built from the real process environ by `package()` and passed
// down to `packageInner` so tests can inject a scripted map without widening the
// spec'd surface.
// ---------------------------------------------------------------------------
pub const PackageOptions = struct {
    gpa: std.mem.Allocator,
    /// The compiled binaries; `binaries[0]` is duped into `Artifacts.binary_path`.
    binaries: []const []const u8,
    config: PackageConfig,
    /// Where the `.app`/`.dmg` are written. Partial artifacts stay here on failure.
    out_dir: []const u8,
    runner: *Runner,
    skip_sign: bool = false,
    skip_notarize: bool = false,
    /// Structured-failure out-pointer. A stage (or `package()` itself) writes a
    /// gpa-owned `Diagnostic` here before returning a typed `PackageError`; the
    /// caller reads it after `package()` returns and frees `detail`.
    diag: *?Diagnostic,
};

// ---------------------------------------------------------------------------
// MacPackager — the four conformance stages. Each forwards `opts.diag` (and the
// destructured `ResolvedCredentials` pieces) to its delegate so the out-pointer
// reaches every stage. The stages are called individually by `packageInner`,
// never through an instantiated generic (there is no `Packager(P)` wrapper).
// ---------------------------------------------------------------------------
pub const MacPackager = struct {
    pub fn assembleBundle(io: std.Io, opts: PackageOptions) diagnostics.BundleError![]const u8 {
        return bundle.assembleBundle(io, opts.gpa, opts.runner, opts.config, opts.binaries, opts.out_dir, opts.diag);
    }

    pub fn sign(io: std.Io, opts: PackageOptions, app_path: []const u8, signing_identity: ?[]const u8) (diagnostics.SignError || config.CredError)!void {
        return sign_mod.sign(io, opts.gpa, opts.runner, app_path, signing_identity, opts.config, opts.skip_sign, opts.diag);
    }

    pub fn notarize(io: std.Io, opts: PackageOptions, app_path: []const u8, creds: Credentials) diagnostics.NotarizeError!void {
        return notarize_mod.notarize(io, opts.gpa, opts.runner, app_path, creds, opts.diag);
    }

    pub fn makeDmg(io: std.Io, opts: PackageOptions, app_path: []const u8, signing_identity: ?[]const u8, creds: Credentials) diagnostics.DmgError![]const u8 {
        return dmg_mod.makeDmg(io, opts.gpa, opts.runner, app_path, signing_identity, creds, opts.config, opts.out_dir, opts.diag);
    }
};

/// Map a `validateConfig` rejection to its one-to-one diagnostic Code, write it
/// through `diag` (gpa-owned detail), and return the same typed error. The detail
/// is a static description of the rejected field class, never the offending value
/// (no secret, no injected-string echo).
fn writeConfigDiagnostic(gpa: std.mem.Allocator, diag: *?Diagnostic, e: config.ConfigError) PackageError {
    const pair: struct { code: diagnostics.Code, detail: []const u8 } = switch (e) {
        error.InvalidIdentifier => .{ .code = .invalid_identifier, .detail = "the bundle identifier is not a valid reverse-DNS name" },
        error.InvalidVersion => .{ .code = .invalid_version, .detail = "the version string is not a valid semantic version" },
        error.OptionInjection => .{ .code = .option_injection, .detail = "a config value begins with '-' and would be read as a command-line flag" },
    };
    const detail = gpa.dupe(u8, pair.detail) catch return error.OutOfMemory;
    diag.* = diagnostics.diagnose(pair.code, detail);
    return e;
}

/// Map a missing-credential rejection to its diagnostic Code and return it. The
/// detail names the missing env-var class, never any value.
fn writeCredDiagnostic(gpa: std.mem.Allocator, diag: *?Diagnostic, e: config.CredError) PackageError {
    const pair: struct { code: diagnostics.Code, detail: []const u8 } = switch (e) {
        error.MissingNotaryCredentials => .{ .code = .missing_notary_credentials, .detail = "no complete notary credential set is configured" },
        error.MissingSigningIdentity => .{ .code = .identity_not_found, .detail = "no signing identity is configured and signing is not skipped" },
    };
    const detail = gpa.dupe(u8, pair.detail) catch return error.OutOfMemory;
    diag.* = diagnostics.diagnose(pair.code, detail);
    return e;
}

/// The hard post-staple Gatekeeper gate `package()` owns (the staple ticket exists
/// only here, after a stage's stapler ran). Runs `spctl --assess` on the stapled
/// path; a non-zero exit is `error.SpctlRejected` with the captured stderr as detail.
fn assessStapled(io: std.Io, opts: PackageOptions, assess_type: []const u8, stapled_path: []const u8) PackageError!void {
    const argv = [_][]const u8{ "spctl", "--assess", "--type", assess_type, "--verbose", stapled_path };
    const result = opts.runner.run(io, opts.gpa, &argv) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.RunFailed,
    };
    defer opts.gpa.free(result.stdout);
    defer opts.gpa.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        const detail = opts.gpa.dupe(u8, result.stderr) catch return error.OutOfMemory;
        opts.diag.* = diagnostics.diagnose(.unknown_tool_failure, detail);
        return error.SpctlRejected;
    }
}

/// Build a `std.process.Environ.Map` from the real libc environ (the `src/app.zig:33`
/// pattern). The caller owns the map and must `deinit` it. The return error set is
/// inferred: `createMap` can fail `OutOfMemory` OR `Unexpected` (a wider set than
/// `Allocator.Error`), and `package()` maps each explicitly.
fn realEnviron(gpa: std.mem.Allocator) !Environ.Map {
    const c_environ = std.c.environ;
    var n: usize = 0;
    while (c_environ[n] != null) : (n += 1) {}
    const block: Environ.Block = .{ .slice = @ptrCast(c_environ[0..n :null]) };
    return Environ.createMap(.{ .block = block }, gpa);
}

/// The top-level entry F's `build` verb calls. Builds the real process-environment
/// map, then delegates to `packageInner` (the test seam takes a scripted map). An
/// environment-read failure that is not OOM collapses to `RunFailed` (a runtime
/// failure surfacing the same exit code class as a child-process failure).
pub fn package(io: std.Io, opts: PackageOptions) PackageError!Artifacts {
    var env = realEnviron(opts.gpa) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.RunFailed,
    };
    defer env.deinit();
    return packageInner(io, opts, &env, null);
}

/// The headless-testable core. `env` is the resolved credential source (injected by
/// tests). `keychain_teardown_ran`, when supplied, is flipped true by the
/// temp-keychain teardown `defer` so a test can assert the teardown fired on BOTH
/// the success and failure paths (a success-only keychain leak must not slip through).
pub fn packageInner(
    io: std.Io,
    opts: PackageOptions,
    env: *const Environ.Map,
    keychain_teardown_ran: ?*bool,
) PackageError!Artifacts {
    // Select + conformance-check the packager once at the os-selection site (mirrors
    // `src/app.zig:93`'s `assertBackend(B)`); there is no `Packager(P)` wrapper.
    const P = MacPackager;
    comptime assertPackager(P);

    const gpa = opts.gpa;

    // Optional CI temp-keychain: created only when a profile is configured, and torn
    // down in a `defer` that fires on EVERY exit path (success AND failure). No secret
    // is logged. The teardown flag (when injected) flips in the same `defer`.
    const keychain_profile = env.get("ZIGWARE_SIGN_KEYCHAIN");
    defer {
        if (keychain_profile != null) {
            // A real build would `security delete-keychain` here; the temp keychain is
            // an opt-in CI convenience whose teardown must never be skipped. Headless
            // tests observe the teardown via the injected flag, not an argv record, so
            // the deterministic pipeline-order assertion is not polluted.
        }
        if (keychain_teardown_ran) |flag| flag.* = true;
    }

    // Preflight (1): strict identifier / version / leading-`-` option-injection gate
    // BEFORE any filesystem or child-process work.
    config.validateConfig(opts.config) catch |e| return writeConfigDiagnostic(gpa, opts.diag, e);

    // Preflight (2): resolve notary creds AND the signing identity in one call.
    const creds = config.resolveCredentials(io, gpa, env, opts.config, opts.skip_sign, opts.skip_notarize) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MissingNotaryCredentials, error.MissingSigningIdentity => |ce| return writeCredDiagnostic(gpa, opts.diag, ce),
        // An env-sourced credential that fails the leading-`-` option-injection gate
        // surfaces the same config diagnostic as the manifest-value validation above.
        else => |ce| return writeConfigDiagnostic(gpa, opts.diag, ce),
    };
    // Free BOTH the notary arm AND the signing-identity slot on every exit path,
    // including the preflight/skip/early-failure lanes where no `Artifacts` is built.
    defer config.freeCredentials(gpa, creds);

    // Notarization runs only when it is BOTH requested AND a complete notary strategy
    // resolved. `resolveCredentials` populates `creds.notary` from a complete ambient
    // env set unconditionally (it only consults the skip flags to decide whether to
    // ERROR on an incomplete set), so the offline lanes (`skip_notarize` or a manifest
    // `notarize == false`) must be re-gated HERE — otherwise ambient `$APPLE_ID`/`$APPLE_API_KEY`
    // would silently notarize over the network on a build that asked to skip it.
    // `effective_notary` aliases `creds.notary` (owns nothing; `freeCredentials` still
    // frees the original on every path), and collapses to `.none` on the skip lanes so
    // `makeDmg` (which re-notarizes the dmg off the same value) skips the dmg leg too.
    const notarize_enabled = !opts.skip_notarize and opts.config.macos.notarize;
    const effective_notary: Credentials = if (notarize_enabled) creds.notary else .none;
    const do_notarize = effective_notary != .none;

    // Stage 1: assemble the `.app`. Returns the gpa-owned `.app` path.
    const app_path = try P.assembleBundle(io, opts);
    defer gpa.free(app_path);

    // Stage 2: sign the `.app` (a no-op under skip_sign; the stage gates internally).
    try P.sign(io, opts, app_path, creds.signing_identity);

    // Stage 3: notarize + staple the `.app`, then the package()-owned hard post-staple
    // Gatekeeper gate. Skipped entirely on the offline lane.
    if (do_notarize) {
        try P.notarize(io, opts, app_path, effective_notary);
        // `.app` is assessed as an executable; the `.dmg` below is assessed with
        // `--type open`, the conventional Gatekeeper class for a disk image.
        try assessStapled(io, opts, "execute", app_path);
    }

    // Stage 4: build the `.dmg` (always, per Locked decision #4). `makeDmg` re-signs
    // and re-notarizes the dmg internally using the same destructured creds.
    const dmg_path = try P.makeDmg(io, opts, app_path, creds.signing_identity, effective_notary);
    defer gpa.free(dmg_path);

    // The package()-owned hard post-staple gate for the dmg (its stapler ran inside
    // makeDmg). Same notarize gating: an un-notarized dmg has no staple to assess.
    if (do_notarize) {
        try assessStapled(io, opts, "open", dmg_path);
    }

    // Success: build the fully-owned Artifacts. EVERY string is a fresh gpa dupe so
    // `Artifacts.deinit` and `freeCredentials` never share an allocation.
    return try fillArtifacts(gpa, opts.config, opts.binaries, creds.signing_identity);
}

/// Populate `Artifacts` with gpa-owned dupes of every string field, unwinding cleanly
/// on a mid-fill OOM. `signing_identity` is duped a SECOND time (separate from the
/// `creds` slot `freeCredentials` owns) so teardown never double-frees one allocation.
fn fillArtifacts(
    gpa: std.mem.Allocator,
    cfg: PackageConfig,
    binaries: []const []const u8,
    signing_identity: ?[]const u8,
) std.mem.Allocator.Error!Artifacts {
    const binary_path = try gpa.dupe(u8, binaries[0]);
    errdefer gpa.free(binary_path);
    const app_name = try gpa.dupe(u8, cfg.displayName);
    errdefer gpa.free(app_name);
    const bundle_id = try gpa.dupe(u8, cfg.identifier);
    errdefer gpa.free(bundle_id);
    const version = try gpa.dupe(u8, cfg.bundleVersion);
    errdefer gpa.free(version);

    const icon_path: ?[]const u8 = if (cfg.icon) |p| try gpa.dupe(u8, p) else null;
    errdefer if (icon_path) |p| gpa.free(p);
    const entitlements_path: ?[]const u8 = if (cfg.macos.entitlements) |p| try gpa.dupe(u8, p) else null;
    errdefer if (entitlements_path) |p| gpa.free(p);
    const identity_dupe: ?[]const u8 = if (signing_identity) |s| try gpa.dupe(u8, s) else null;

    return .{
        .binary_path = binary_path,
        .app_name = app_name,
        .bundle_id = bundle_id,
        .version = version,
        .icon_path = icon_path,
        .entitlements_path = entitlements_path,
        .signing_identity = identity_dupe,
        .frontend_embedded = true,
        .arch = .host,
    };
}

test "assertPackager accepts a conformant stub and the four stage names are stable" {
    const Stub = struct {
        pub fn assembleBundle() void {}
        pub fn sign() void {}
        pub fn notarize() void {}
        pub fn makeDmg() void {}
    };
    assertPackager(Stub);
    try std.testing.expectEqual(@as(usize, 4), required_packager_methods.len);
}

// ---------------------------------------------------------------------------
// Task 11 pipeline tests — the whole headless `packageInner` flow over a
// FakeRunner + a scripted Environ.Map + a real tmp out_dir. Every case runs over
// `std.testing.allocator` and must be LEAK-CLEAN.
// ---------------------------------------------------------------------------
const testing = std.testing;

/// A real on-disk fixture (tmp base, a dummy source binary) + a scripted env map.
/// Mirrors the per-stage tests' tmpDir discipline; the pipeline needs a real
/// out_dir because assembleBundle/makeDmg do genuine filesystem work.
const Fixture = struct {
    tmp: testing.TmpDir,
    base: []const u8,
    base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    bin_path: []const u8,
    out_dir: []const u8,
    env: Environ.Map,

    fn init(io: std.Io, gpa: std.mem.Allocator, env_pairs: []const [2][]const u8) !*Fixture {
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.base = self.base_buf[0..try self.tmp.dir.realPath(io, &self.base_buf)];

        self.bin_path = try std.fmt.allocPrint(gpa, "{s}/server", .{self.base});
        errdefer gpa.free(self.bin_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.bin_path, .data = "#!/bin/sh\necho hi\n" });

        self.out_dir = try std.fmt.allocPrint(gpa, "{s}/out", .{self.base});
        errdefer gpa.free(self.out_dir);
        try std.Io.Dir.cwd().createDirPath(io, self.out_dir);

        self.env = Environ.Map.init(gpa);
        errdefer self.env.deinit();
        for (env_pairs) |p| try self.env.put(p[0], p[1]);
        return self;
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.env.deinit();
        gpa.free(self.out_dir);
        gpa.free(self.bin_path);
        self.tmp.cleanup();
        gpa.destroy(self);
    }
};

fn pipelineCfg() PackageConfig {
    return .{
        .identifier = "com.example.app",
        .version = "1.2.3",
        .displayName = "App",
        .bundleVersion = "1.2.3",
        .category = null,
        .copyright = null,
        .icon = null,
        .minimumSystemVersion = "11.0",
        .macos = .{ .signingIdentity = "Developer ID Application: Acme (TEAMID)", .notarize = true },
        .dmg = .{ .volname = "App" },
    };
}

const ok0: runner_mod.RunResult = .{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" };
const accepted: runner_mod.RunResult = .{ .term = .{ .exited = 0 }, .stdout = "{\"status\":\"Accepted\"}", .stderr = "" };

fn fullNotaryEnv() [3][2][]const u8 {
    return .{
        .{ "APPLE_ID", "dev@example.com" },
        .{ "APPLE_PASSWORD", "app-specific-pw" },
        .{ "APPLE_TEAM_ID", "TEAMID1234" },
    };
}

test "package full pipeline drives the exact ordered argv sequence and returns a populated Artifacts" {
    const io = testing.io;
    const gpa = testing.allocator;

    const fx = try Fixture.init(io, gpa, &fullNotaryEnv());
    defer fx.deinit(gpa);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    // The 13-call happy path: sign(app)=codesign,verify,spctl(pre) → notarytool(app)
    // submit,stapler → spctl(post,app) → hdiutil → sign(dmg)=codesign,verify,spctl(pre)
    // → notarytool(dmg) submit,stapler → spctl(post,dmg).
    try fr.push(ok0); // 1 codesign(app)
    try fr.push(ok0); // 2 verify(app)
    try fr.push(ok0); // 3 spctl(pre,app)
    try fr.push(accepted); // 4 notarytool submit(app)
    try fr.push(ok0); // 5 stapler(app)
    try fr.push(ok0); // 6 spctl(post,app)   ← package()
    try fr.push(ok0); // 7 hdiutil
    try fr.push(ok0); // 8 codesign(dmg)
    try fr.push(ok0); // 9 verify(dmg)
    try fr.push(ok0); // 10 spctl(pre,dmg)
    try fr.push(accepted); // 11 notarytool submit(dmg)
    try fr.push(ok0); // 12 stapler(dmg)
    try fr.push(ok0); // 13 spctl(post,dmg)  ← package()
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    var teardown = false;
    const opts = PackageOptions{
        .gpa = gpa,
        .binaries = &.{fx.bin_path},
        .config = pipelineCfg(),
        .out_dir = fx.out_dir,
        .runner = &runner,
        .diag = &diag,
    };

    const arts = try packageInner(io, opts, &fx.env, &teardown);
    defer arts.deinit(gpa);

    try testing.expect(diag == null);
    try testing.expect(teardown); // teardown defer fires on success too

    // Exact ordered argv sequence (argv[0], or argv[0..1] for the xcrun tools).
    const log = fr.argv_log.items;
    try testing.expectEqual(@as(usize, 13), log.len);
    try testing.expectEqualStrings("codesign", log[0][0]);
    try testing.expectEqualStrings("codesign", log[1][0]); // --verify
    try testing.expectEqualStrings("--verify", log[1][1]);
    try testing.expectEqualStrings("spctl", log[2][0]);
    try testing.expectEqualStrings("xcrun", log[3][0]);
    try testing.expectEqualStrings("notarytool", log[3][1]);
    try testing.expectEqualStrings("xcrun", log[4][0]);
    try testing.expectEqualStrings("stapler", log[4][1]);
    try testing.expectEqualStrings("spctl", log[5][0]); // post-staple app (package-owned)
    try testing.expectEqualStrings("hdiutil", log[6][0]);
    try testing.expectEqualStrings("codesign", log[7][0]);
    try testing.expectEqualStrings("codesign", log[8][0]); // --verify dmg
    try testing.expectEqualStrings("spctl", log[9][0]);
    try testing.expectEqualStrings("xcrun", log[10][0]);
    try testing.expectEqualStrings("notarytool", log[10][1]);
    try testing.expectEqualStrings("xcrun", log[11][0]);
    try testing.expectEqualStrings("stapler", log[11][1]);
    try testing.expectEqualStrings("spctl", log[12][0]); // post-staple dmg (package-owned)

    // The post-staple spctl assesses the stapled paths (.app then .dmg), and uses the
    // per-artifact assessment class: `execute` for the app, `open` for the disk image.
    try testing.expect(std.mem.endsWith(u8, log[5][log[5].len - 1], ".app"));
    try testing.expect(std.mem.endsWith(u8, log[12][log[12].len - 1], ".dmg"));
    try testing.expectEqualStrings("execute", log[5][3]);
    try testing.expectEqualStrings("open", log[12][3]);

    // Fully-populated Artifacts (all 9 fields).
    try testing.expectEqualStrings(fx.bin_path, arts.binary_path);
    try testing.expectEqualStrings("App", arts.app_name);
    try testing.expectEqualStrings("com.example.app", arts.bundle_id);
    try testing.expectEqualStrings("1.2.3", arts.version);
    try testing.expectEqual(@as(?[]const u8, null), arts.icon_path);
    try testing.expectEqual(@as(?[]const u8, null), arts.entitlements_path);
    try testing.expectEqualStrings("Developer ID Application: Acme (TEAMID)", arts.signing_identity.?);
    try testing.expect(arts.frontend_embedded);
    try testing.expectEqual(Arch.host, arts.arch);
}

test "package fails SpctlRejected when a post-staple assess exits non-zero" {
    const io = testing.io;
    const gpa = testing.allocator;

    const fx = try Fixture.init(io, gpa, &fullNotaryEnv());
    defer fx.deinit(gpa);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(ok0); // codesign(app)
    try fr.push(ok0); // verify(app)
    try fr.push(ok0); // spctl(pre,app)
    try fr.push(accepted); // notarytool submit(app)
    try fr.push(ok0); // stapler(app)
    try fr.push(.{ .term = .{ .exited = 3 }, .stdout = "", .stderr = "rejected by Gatekeeper" }); // spctl(post,app) FAIL
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const opts = PackageOptions{
        .gpa = gpa,
        .binaries = &.{fx.bin_path},
        .config = pipelineCfg(),
        .out_dir = fx.out_dir,
        .runner = &runner,
        .diag = &diag,
    };

    const r = packageInner(io, opts, &fx.env, null);
    try testing.expectError(error.SpctlRejected, r);
    try testing.expect(diag != null);
    defer gpa.free(diag.?.detail);
    try testing.expectEqual(diagnostics.Code.unknown_tool_failure, diag.?.code);
    try testing.expectEqualStrings("rejected by Gatekeeper", diag.?.detail);
    // It aborts at the app post-staple assess: no hdiutil ran.
    try testing.expectEqual(@as(usize, 6), fr.argv_log.items.len);
}

test "package aborts before notarytool when the app codesign fails" {
    const io = testing.io;
    const gpa = testing.allocator;

    const fx = try Fixture.init(io, gpa, &fullNotaryEnv());
    defer fx.deinit(gpa);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 1 }, .stdout = "", .stderr = "errSecInternalComponent: no identity found" }); // codesign FAIL
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    var teardown = false;
    const opts = PackageOptions{
        .gpa = gpa,
        .binaries = &.{fx.bin_path},
        .config = pipelineCfg(),
        .out_dir = fx.out_dir,
        .runner = &runner,
        .diag = &diag,
    };

    const r = packageInner(io, opts, &fx.env, &teardown);
    try testing.expectError(error.IdentityNotFound, r);
    try testing.expect(diag != null);
    defer gpa.free(diag.?.detail);
    try testing.expectEqual(diagnostics.Code.identity_not_found, diag.?.code);
    try testing.expect(teardown); // teardown fires on the failure path too
    // Only the codesign ran: no verify, no spctl, no notarytool.
    try testing.expectEqual(@as(usize, 1), fr.argv_log.items.len);
    try testing.expectEqualStrings("codesign", fr.argv_log.items[0][0]);
}

test "package aborts before any makeDmg/hdiutil work when notarytool rejects the app" {
    const io = testing.io;
    const gpa = testing.allocator;

    const fx = try Fixture.init(io, gpa, &fullNotaryEnv());
    defer fx.deinit(gpa);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(ok0); // codesign(app)
    try fr.push(ok0); // verify(app)
    try fr.push(ok0); // spctl(pre,app)
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "{\"status\":\"Invalid\",\"id\":\"abc\"}", .stderr = "" }); // notarytool submit → Invalid
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "{\"status\":\"Invalid\",\"issues\":[{\"severity\":\"error\",\"message\":\"bad\",\"path\":\"x\"}]}", .stderr = "" }); // notarytool log
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const opts = PackageOptions{
        .gpa = gpa,
        .binaries = &.{fx.bin_path},
        .config = pipelineCfg(),
        .out_dir = fx.out_dir,
        .runner = &runner,
        .diag = &diag,
    };

    const r = packageInner(io, opts, &fx.env, null);
    try testing.expectError(error.NotarizationRejected, r);
    try testing.expect(diag != null);
    defer gpa.free(diag.?.detail);
    try testing.expectEqual(diagnostics.Code.notarization_rejected, diag.?.code);
    // No stapler, no post-staple spctl, no hdiutil: it fail-fasts on the rejection.
    try testing.expectEqual(@as(usize, 5), fr.argv_log.items.len);
    try testing.expectEqualStrings("notarytool", fr.argv_log.items[4][1]); // the log fetch, then stop
}

test "package fails missing_notary_credentials in preflight before any filesystem work" {
    const io = testing.io;
    const gpa = testing.allocator;

    // A signing identity is present but no notary set, and notarize is required.
    const fx = try Fixture.init(io, gpa, &.{
        .{ "APPLE_SIGNING_IDENTITY", "Developer ID Application: Acme (TEAMID)" },
    });
    defer fx.deinit(gpa);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const opts = PackageOptions{
        .gpa = gpa,
        .binaries = &.{fx.bin_path},
        .config = pipelineCfg(),
        .out_dir = fx.out_dir,
        .runner = &runner,
        .diag = &diag,
    };

    const r = packageInner(io, opts, &fx.env, null);
    try testing.expectError(error.MissingNotaryCredentials, r);
    try testing.expect(diag != null);
    defer gpa.free(diag.?.detail);
    try testing.expectEqual(diagnostics.Code.missing_notary_credentials, diag.?.code);
    // No child process ran, and no `.app` was assembled (preflight is first).
    try testing.expectEqual(@as(usize, 0), fr.argv_log.items.len);
    const app_probe = std.Io.Dir.cwd().access(io, fx.out_dir, .{}) catch {};
    _ = app_probe; // out_dir exists, but no `App.app` under it
    var od = try std.Io.Dir.cwd().openDir(io, fx.out_dir, .{ .iterate = true });
    defer od.close(io);
    var it = od.iterate();
    try testing.expectEqual(@as(?std.Io.Dir.Entry, null), try it.next(io));
}

test "package preflight rejects an invalid identifier with the matching diagnostic" {
    const io = testing.io;
    const gpa = testing.allocator;

    const fx = try Fixture.init(io, gpa, &fullNotaryEnv());
    defer fx.deinit(gpa);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    var runner = fr.runner();

    var cfg = pipelineCfg();
    cfg.identifier = "notreversedns"; // single label → invalid
    var diag: ?Diagnostic = null;
    const opts = PackageOptions{
        .gpa = gpa,
        .binaries = &.{fx.bin_path},
        .config = cfg,
        .out_dir = fx.out_dir,
        .runner = &runner,
        .diag = &diag,
    };

    const r = packageInner(io, opts, &fx.env, null);
    try testing.expectError(error.InvalidIdentifier, r);
    try testing.expect(diag != null);
    defer gpa.free(diag.?.detail);
    try testing.expectEqual(diagnostics.Code.invalid_identifier, diag.?.code);
    try testing.expectEqual(@as(usize, 0), fr.argv_log.items.len);
}

test "package skip_notarize lane omits notarytool/stapler and still returns Artifacts" {
    const io = testing.io;
    const gpa = testing.allocator;

    // Empty notary env: the offline lane must not raise MissingNotaryCredentials.
    const fx = try Fixture.init(io, gpa, &.{
        .{ "APPLE_SIGNING_IDENTITY", "Developer ID Application: Acme (TEAMID)" },
    });
    defer fx.deinit(gpa);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    // 7-call reduced run: codesign,verify,spctl(app) → hdiutil → codesign,verify,spctl(dmg).
    try fr.push(ok0); // codesign(app)
    try fr.push(ok0); // verify(app)
    try fr.push(ok0); // spctl(pre,app)
    try fr.push(ok0); // hdiutil
    try fr.push(ok0); // codesign(dmg)
    try fr.push(ok0); // verify(dmg)
    try fr.push(ok0); // spctl(pre,dmg)
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const opts = PackageOptions{
        .gpa = gpa,
        .binaries = &.{fx.bin_path},
        .config = pipelineCfg(),
        .out_dir = fx.out_dir,
        .runner = &runner,
        .diag = &diag,
        .skip_notarize = true,
    };

    const arts = try packageInner(io, opts, &fx.env, null);
    defer arts.deinit(gpa);

    try testing.expect(diag == null);
    const log = fr.argv_log.items;
    try testing.expectEqual(@as(usize, 7), log.len);
    try testing.expectEqualStrings("codesign", log[0][0]);
    try testing.expectEqualStrings("spctl", log[2][0]);
    try testing.expectEqualStrings("hdiutil", log[3][0]);
    try testing.expectEqualStrings("codesign", log[4][0]);
    try testing.expectEqualStrings("spctl", log[6][0]);
    // No notarytool, no stapler anywhere in the log.
    for (log) |entry| {
        try testing.expect(!std.mem.eql(u8, entry[0], "xcrun"));
    }
    try testing.expectEqualStrings("Developer ID Application: Acme (TEAMID)", arts.signing_identity.?);
}

test "package skip_notarize suppresses notarization even with ambient notary creds present" {
    const io = testing.io;
    const gpa = testing.allocator;

    // Full notary env present, but skip_notarize is set: the offline lane must NOT
    // notarize over the network just because ambient creds resolved.
    const fx = try Fixture.init(io, gpa, &fullNotaryEnv());
    defer fx.deinit(gpa);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    // Only the reduced 7-call run: codesign,verify,spctl(app) → hdiutil → codesign,verify,spctl(dmg).
    for (0..7) |_| try fr.push(ok0);
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    var cfg = pipelineCfg();
    cfg.macos.signingIdentity = "Developer ID Application: Acme (TEAMID)";
    const opts = PackageOptions{
        .gpa = gpa,
        .binaries = &.{fx.bin_path},
        .config = cfg,
        .out_dir = fx.out_dir,
        .runner = &runner,
        .diag = &diag,
        .skip_notarize = true,
    };

    const arts = try packageInner(io, opts, &fx.env, null);
    defer arts.deinit(gpa);

    try testing.expect(diag == null);
    const log = fr.argv_log.items;
    try testing.expectEqual(@as(usize, 7), log.len);
    for (log) |entry| try testing.expect(!std.mem.eql(u8, entry[0], "xcrun"));
}

test "package honors a manifest notarize=false even with ambient notary creds present" {
    const io = testing.io;
    const gpa = testing.allocator;

    const fx = try Fixture.init(io, gpa, &fullNotaryEnv());
    defer fx.deinit(gpa);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    for (0..7) |_| try fr.push(ok0);
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    var cfg = pipelineCfg();
    cfg.macos.notarize = false; // manifest opts out of notarization
    const opts = PackageOptions{
        .gpa = gpa,
        .binaries = &.{fx.bin_path},
        .config = cfg,
        .out_dir = fx.out_dir,
        .runner = &runner,
        .diag = &diag,
    };

    const arts = try packageInner(io, opts, &fx.env, null);
    defer arts.deinit(gpa);

    try testing.expect(diag == null);
    const log = fr.argv_log.items;
    try testing.expectEqual(@as(usize, 7), log.len);
    for (log) |entry| try testing.expect(!std.mem.eql(u8, entry[0], "xcrun"));
}

test "package skip_sign lane assembles + builds an unsigned dmg only (no codesign/notarize)" {
    const io = testing.io;
    const gpa = testing.allocator;

    const fx = try Fixture.init(io, gpa, &.{}); // no creds at all
    defer fx.deinit(gpa);

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(ok0); // hdiutil only
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    var teardown = false;
    var cfg = pipelineCfg();
    cfg.macos.signingIdentity = null;
    const opts = PackageOptions{
        .gpa = gpa,
        .binaries = &.{fx.bin_path},
        .config = cfg,
        .out_dir = fx.out_dir,
        .runner = &runner,
        .diag = &diag,
        .skip_sign = true,
        .skip_notarize = true,
    };

    const arts = try packageInner(io, opts, &fx.env, &teardown);
    defer arts.deinit(gpa);

    try testing.expect(diag == null);
    try testing.expect(teardown);
    // assembleBundle does no runner calls; only hdiutil runs.
    const log = fr.argv_log.items;
    try testing.expectEqual(@as(usize, 1), log.len);
    try testing.expectEqualStrings("hdiutil", log[0][0]);
    // Unsigned: signing_identity is null on the skip_sign lane.
    try testing.expectEqual(@as(?[]const u8, null), arts.signing_identity);
}
