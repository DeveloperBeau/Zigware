const std = @import("std");
const config = @import("config.zig");
const diagnostics = @import("diagnostics.zig");
const runner_mod = @import("runner.zig");

const PackageConfig = config.PackageConfig;
const SignError = diagnostics.SignError;
/// `sign`'s preflight can reject with `MissingSigningIdentity`, which lives in
/// config's `CredError`, not `SignError`. The return set unions both; both are
/// already members of `PackageError`, so `package()` propagates without widening.
const SignResult = SignError || config.CredError;
const Diagnostic = diagnostics.Diagnostic;
const Runner = runner_mod.Runner;

// ---------------------------------------------------------------------------
// buildSignArgv — the pure codesign argv builder. Returns a gpa-owned slice of
// gpa-owned strings; the caller frees each element then the slice. A
// Developer-ID identity gets the hardened-runtime form (`--timestamp --options
// runtime`); the ad-hoc identity ("-") drops BOTH (the secure timestamp server
// and the hardened runtime are meaningless for an ad-hoc signature).
//
// Every value placed in an argv slot (`identity`, `entitlements`, `path`) is
// already leading-`-`-checked by `validateConfig` (Locked decision #7); the
// ad-hoc "-" identity is the one intentional exception and is gated by `ad_hoc`.
// ---------------------------------------------------------------------------

pub fn buildSignArgv(
    gpa: std.mem.Allocator,
    identity: []const u8,
    entitlements: ?[]const u8,
    ad_hoc: bool,
    path: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    // On any failure free the partially-built argv (each element + the backing).
    errdefer {
        for (args.items) |a| gpa.free(a);
        args.deinit(gpa);
    }

    try appendDup(gpa, &args, "codesign");
    try appendDup(gpa, &args, "--force");
    if (!ad_hoc) {
        try appendDup(gpa, &args, "--timestamp");
        try appendDup(gpa, &args, "--options");
        try appendDup(gpa, &args, "runtime");
    }
    try appendDup(gpa, &args, "--sign");
    try appendDup(gpa, &args, identity);
    if (entitlements) |ent| {
        try appendDup(gpa, &args, "--entitlements");
        try appendDup(gpa, &args, ent);
    }
    try appendDup(gpa, &args, path);

    return try args.toOwnedSlice(gpa);
}

/// Dupe `s` into gpa and append it; the ArrayList owns the element on success.
fn appendDup(gpa: std.mem.Allocator, args: *std.ArrayList([]const u8), s: []const u8) std.mem.Allocator.Error!void {
    const dup = try gpa.dupe(u8, s);
    errdefer gpa.free(dup);
    try args.append(gpa, dup);
}

// ---------------------------------------------------------------------------
// sign — drive the inside-out codesign + verify + (pre-staple) spctl preflight.
//
// `signing_identity` is the RESOLVED identity (`$APPLE_SIGNING_IDENTITY` over
// manifest) that `package()` resolved via `resolveCredentials` — NOT
// `cfg.macos.signingIdentity`. Reading it from `cfg` would silently ignore the
// documented env override and leave the resolved/duped identity with no consumer.
// The null-without-skip preflight and the ad-hoc detection both key off this
// passed value; `entitlements` still comes from `cfg`.
//
// On a failure path `sign` writes a `gpa.dupe`-owned `Diagnostic` through `diag`
// BEFORE freeing its `RunResult`, then returns the typed `SignError` (Zig error
// values carry no payload). The POST-staple `spctl --assess` is NOT here: there
// is no staple ticket at sign time. `package()` (Task 11) owns it.
// ---------------------------------------------------------------------------

pub fn sign(
    io: std.Io,
    gpa: std.mem.Allocator,
    runner: *Runner,
    bundle_path: []const u8,
    signing_identity: ?[]const u8,
    cfg: PackageConfig,
    skip_sign: bool,
    diag: *?Diagnostic,
) SignResult!void {
    // Preflight (test (c)): skip_sign short-circuits everything first, so a null
    // identity is legal only on that lane. The skip_sign signal is a separate
    // input from the identity because both the skip lane and a genuinely missing
    // identity present as `signing_identity == null` — they are only
    // distinguishable by this flag.
    if (skip_sign) return;

    const identity = signing_identity orelse return error.MissingSigningIdentity;

    const ad_hoc = std.mem.eql(u8, identity, "-");
    if (ad_hoc and cfg.macos.notarize) {
        // An ad-hoc signature can never be notarized; surface it as a missing
        // real identity rather than failing opaquely at the notary service.
        const detail = gpa.dupe(u8, "ad-hoc signing identity ('-') cannot be notarized") catch
            return error.OutOfMemory;
        diag.* = diagnostics.diagnose(.identity_not_found, detail);
        return error.IdentityNotFound;
    }

    // 1) codesign (sign). A non-zero exit classifies the stderr to the owned
    //    cert_expired/keychain_locked/identity_not_found codes (else the
    //    unknown_tool_failure catch-all), then returns before --verify.
    const sign_argv = try buildSignArgv(gpa, identity, cfg.macos.entitlements, ad_hoc, bundle_path);
    defer freeArgvOwned(gpa, sign_argv);
    {
        const result = runner.run(io, gpa, sign_argv) catch |e| return mapRunError(e);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (!termOk(result.term)) {
            return classifyCodesignFailure(gpa, result.stderr, diag);
        }
    }

    // 2) codesign --verify --strict --verbose=2. A non-zero exit is a hard
    //    verify failure; notarize (run by package() after sign) is never reached.
    {
        const verify_argv = [_][]const u8{ "codesign", "--verify", "--strict", "--verbose=2", bundle_path };
        const result = runner.run(io, gpa, &verify_argv) catch |e| return mapRunError(e);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (!termOk(result.term)) {
            const detail = gpa.dupe(u8, result.stderr) catch return error.OutOfMemory;
            diag.* = diagnostics.diagnose(.unknown_tool_failure, detail);
            return error.CodesignVerifyFailed;
        }
    }

    // 3) spctl --assess (PRE-staple): advisory only. The staple ticket does not
    //    exist yet, so a rejection here is expected and downgraded to a warning
    //    (no error, no diagnostic). The HARD post-staple assess is package()'s.
    {
        const spctl_argv = [_][]const u8{ "spctl", "--assess", "--type", "execute", "--verbose", bundle_path };
        const result = runner.run(io, gpa, &spctl_argv) catch |e| return mapRunError(e);
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        // Intentionally ignore the term: pre-staple assess failure is not fatal.
    }
}

/// Map a runner failure (spawn/timeout/truncation/OOM) to a SignError. OOM
/// propagates as itself; everything else collapses to RunFailed.
fn mapRunError(e: runner_mod.RunError) SignError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.RunFailed,
    };
}

/// Classify a non-zero codesign-SIGN stderr into the two codes this stage owns
/// (`cert_expired`/`keychain_locked`) plus `identity_not_found` and the
/// `unknown_tool_failure` catch-all. The matched stderr is duped into the
/// Diagnostic BEFORE the caller frees the RunResult, then the typed error returns.
fn classifyCodesignFailure(gpa: std.mem.Allocator, stderr: []const u8, diag: *?Diagnostic) SignError {
    // `detail` is handed to the Diagnostic on every branch below, so once duped
    // it is owned by `diag.*` (freed at the diagnostic's free site). No errdefer:
    // each branch returns an error WITH the diagnostic populated, so an errdefer
    // here would free the slice the Diagnostic now owns (double-free).
    const detail = gpa.dupe(u8, stderr) catch return error.OutOfMemory;

    if (containsCi(stderr, "expired")) {
        diag.* = diagnostics.diagnose(.cert_expired, detail);
        return error.CertExpired;
    }
    if (containsCi(stderr, "locked")) {
        diag.* = diagnostics.diagnose(.keychain_locked, detail);
        return error.KeychainLocked;
    }
    if (containsCi(stderr, "no identity found")) {
        diag.* = diagnostics.diagnose(.identity_not_found, detail);
        return error.IdentityNotFound;
    }
    diag.* = diagnostics.diagnose(.unknown_tool_failure, detail);
    return error.RunFailed;
}

/// Case-insensitive substring match (codesign/Security framework messages vary
/// in casing across macOS versions, so the triggers match case-insensitively).
fn containsCi(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// True only for a clean `exited == 0` termination.
fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// Free a gpa-owned argv (each element, then the backing slice).
fn freeArgvOwned(gpa: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| gpa.free(a);
    gpa.free(argv);
}

// ---------------------------------------------------------------------------
// Tests (TDD step 1: written before the implementation).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn baseCfg() PackageConfig {
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

fn freeArgv(gpa: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| gpa.free(a);
    gpa.free(argv);
}

// ── buildSignArgv (pure) ─────────────────────────────────────────────────────

test "buildSignArgv for a Developer-ID identity emits the hardened-runtime form" {
    const gpa = testing.allocator;
    const argv = try buildSignArgv(gpa, "Developer ID Application: Acme (TEAMID)", null, false, "Foo.app");
    defer freeArgv(gpa, argv);

    const expected = [_][]const u8{
        "codesign",
        "--force",
        "--timestamp",
        "--options",
        "runtime",
        "--sign",
        "Developer ID Application: Acme (TEAMID)",
        "Foo.app",
    };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try testing.expectEqualStrings(e, a);
}

test "buildSignArgv inserts --entitlements when present, before the path" {
    const gpa = testing.allocator;
    const argv = try buildSignArgv(gpa, "Developer ID Application: Acme", "ent.plist", false, "Foo.app");
    defer freeArgv(gpa, argv);

    const expected = [_][]const u8{
        "codesign",
        "--force",
        "--timestamp",
        "--options",
        "runtime",
        "--sign",
        "Developer ID Application: Acme",
        "--entitlements",
        "ent.plist",
        "Foo.app",
    };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try testing.expectEqualStrings(e, a);
}

test "buildSignArgv for ad-hoc drops --timestamp and --options runtime" {
    const gpa = testing.allocator;
    const argv = try buildSignArgv(gpa, "-", null, true, "Foo.app");
    defer freeArgv(gpa, argv);

    const expected = [_][]const u8{
        "codesign",
        "--force",
        "--sign",
        "-",
        "Foo.app",
    };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try testing.expectEqualStrings(e, a);
    // The hardened-runtime flags MUST be absent for ad-hoc.
    for (argv) |a| {
        try testing.expect(!std.mem.eql(u8, a, "--timestamp"));
        try testing.expect(!std.mem.eql(u8, a, "runtime"));
    }
}

// ── sign over a FakeRunner ───────────────────────────────────────────────────

test "sign runs codesign, then --verify, then spctl on success" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // codesign sign
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // codesign --verify
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // spctl
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    try sign(io, gpa, &runner, "Foo.app", "Developer ID Application: Acme", baseCfg(), false, &diag);

    try testing.expect(diag == null);
    try testing.expectEqual(@as(usize, 3), fr.argv_log.items.len);
    try testing.expectEqualStrings("codesign", fr.argv_log.items[0][0]);
    // The verify command.
    const verify = fr.argv_log.items[1];
    try testing.expectEqualStrings("codesign", verify[0]);
    try testing.expectEqualStrings("--verify", verify[1]);
    try testing.expectEqualStrings("--strict", verify[2]);
    try testing.expectEqualStrings("--verbose=2", verify[3]);
    try testing.expectEqualStrings("Foo.app", verify[verify.len - 1]);
    // The pre-staple spctl assess.
    try testing.expectEqualStrings("spctl", fr.argv_log.items[2][0]);
}

test "sign aborts before verify when codesign fails" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 1 }, .stdout = "", .stderr = "codesign: some failure" });
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const r = sign(io, gpa, &runner, "Foo.app", "Developer ID Application: Acme", baseCfg(), false, &diag);
    try testing.expectError(error.RunFailed, r);

    // Only the codesign sign ran; verify/spctl never reached.
    try testing.expectEqual(@as(usize, 1), fr.argv_log.items.len);
    try testing.expect(diag != null);
    try testing.expectEqual(diagnostics.Code.unknown_tool_failure, diag.?.code);
    gpa.free(diag.?.detail);
}

test "sign maps a verify failure to CodesignVerifyFailed and never reaches notarize" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // codesign sign OK
    try fr.push(.{ .term = .{ .exited = 3 }, .stdout = "", .stderr = "Foo.app: invalid signature" }); // verify FAIL
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const r = sign(io, gpa, &runner, "Foo.app", "Developer ID Application: Acme", baseCfg(), false, &diag);
    try testing.expectError(error.CodesignVerifyFailed, r);

    // spctl (and notarize, which package() runs after) is never reached.
    try testing.expectEqual(@as(usize, 2), fr.argv_log.items.len);
    try testing.expect(diag != null);
    gpa.free(diag.?.detail);
}

test "sign downgrades a PRE-staple spctl failure to a warning (no error)" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // codesign sign
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // verify
    try fr.push(.{ .term = .{ .exited = 1 }, .stdout = "", .stderr = "rejected" }); // spctl FAIL (pre-staple)
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    // No error: pre-staple assess is advisory; the staple ticket does not exist yet.
    try sign(io, gpa, &runner, "Foo.app", "Developer ID Application: Acme", baseCfg(), false, &diag);
    try testing.expect(diag == null);
    try testing.expectEqual(@as(usize, 3), fr.argv_log.items.len);
}

// ── preflight ────────────────────────────────────────────────────────────────

test "sign with skip_sign returns immediately and runs nothing" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    // Null identity is legal on the skip_sign lane.
    try sign(io, gpa, &runner, "Foo.app", null, baseCfg(), true, &diag);
    try testing.expect(diag == null);
    try testing.expectEqual(@as(usize, 0), fr.argv_log.items.len);
}

test "sign with a null identity and no skip_sign returns MissingSigningIdentity" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const r = sign(io, gpa, &runner, "Foo.app", null, baseCfg(), false, &diag);
    try testing.expectError(error.MissingSigningIdentity, r);
    try testing.expectEqual(@as(usize, 0), fr.argv_log.items.len);
}

test "sign with an ad-hoc identity but notarize required rejects with IdentityNotFound" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    var runner = fr.runner();

    var cfg = baseCfg();
    cfg.macos.notarize = true; // notarization wants a real Developer-ID identity
    var diag: ?Diagnostic = null;
    const r = sign(io, gpa, &runner, "Foo.app", "-", cfg, false, &diag);
    try testing.expectError(error.IdentityNotFound, r);
    try testing.expectEqual(@as(usize, 0), fr.argv_log.items.len);
    try testing.expect(diag != null);
    gpa.free(diag.?.detail);
}

test "sign with an ad-hoc identity and notarize disabled proceeds to codesign" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // codesign sign
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // verify
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // spctl
    var runner = fr.runner();

    var cfg = baseCfg();
    cfg.macos.notarize = false;
    var diag: ?Diagnostic = null;
    try sign(io, gpa, &runner, "Foo.app", "-", cfg, false, &diag);
    try testing.expect(diag == null);
    // Ad-hoc sign argv has neither --timestamp nor --options runtime.
    const sign_argv = fr.argv_log.items[0];
    for (sign_argv) |a| {
        try testing.expect(!std.mem.eql(u8, a, "--timestamp"));
        try testing.expect(!std.mem.eql(u8, a, "runtime"));
    }
}

// ── classifier coverage (the two codes this stage owns) ──────────────────────

test "sign classifies an expired-cert codesign failure as cert_expired" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{
        .term = .{ .exited = 1 },
        .stdout = "",
        .stderr = "Foo.app: CSSMERR_TP_CERT_EXPIRED: the certificate has expired",
    });
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const r = sign(io, gpa, &runner, "Foo.app", "Developer ID Application: Acme", baseCfg(), false, &diag);
    try testing.expectError(error.CertExpired, r);
    try testing.expect(diag != null);
    try testing.expectEqual(diagnostics.Code.cert_expired, diag.?.code);
    gpa.free(diag.?.detail);
}

test "sign classifies a locked-keychain codesign failure as keychain_locked" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{
        .term = .{ .exited = 1 },
        .stdout = "",
        .stderr = "Foo.app: errSecInternalComponent (the user keychain is locked)",
    });
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const r = sign(io, gpa, &runner, "Foo.app", "Developer ID Application: Acme", baseCfg(), false, &diag);
    try testing.expectError(error.KeychainLocked, r);
    try testing.expect(diag != null);
    try testing.expectEqual(diagnostics.Code.keychain_locked, diag.?.code);
    gpa.free(diag.?.detail);
}

test "sign classifies a no-identity codesign failure as identity_not_found" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{
        .term = .{ .exited = 1 },
        .stdout = "",
        .stderr = "Foo.app: no identity found",
    });
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const r = sign(io, gpa, &runner, "Foo.app", "Developer ID Application: Acme", baseCfg(), false, &diag);
    try testing.expectError(error.IdentityNotFound, r);
    try testing.expect(diag != null);
    try testing.expectEqual(diagnostics.Code.identity_not_found, diag.?.code);
    gpa.free(diag.?.detail);
}

test "sign's diagnostic detail carries the captured stderr, no fabricated secret" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 1 }, .stdout = "", .stderr = "codesign: generic boom" });
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const r = sign(io, gpa, &runner, "Foo.app", "Developer ID Application: Acme", baseCfg(), false, &diag);
    try testing.expectError(error.RunFailed, r);
    try testing.expect(diag != null);
    try testing.expectEqualStrings("codesign: generic boom", diag.?.detail);
    gpa.free(diag.?.detail);
}
