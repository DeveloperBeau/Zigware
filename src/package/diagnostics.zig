const std = @import("std");
const config = @import("config.zig");

// ---------------------------------------------------------------------------
// Error sets (built from the plan's Task 6 + Locked decisions #5/#6, NOT the
// spec's `|| std.Io.Dir.Error` block which does not compile here).
// ---------------------------------------------------------------------------

/// PURE-DOMAIN bundle errors. No std unions: Task 7 catches each raw
/// `Dir.CreateDirPathError`/`CopyFileError`/`SymLinkError`/`SetPermissionsError`
/// and maps it to one of these so the `Code` table can render every failure.
/// `CreateDirPathFailed` replaces the spec's `MakePathFailed` (the `makePath`
/// name is gone; the real call is `createDirPath`).
pub const BundleError = error{
    IconConvertFailed,
    PlistWriteFailed,
    BinaryCopyFailed,
    CreateDirPathFailed,
    OutOfMemory,
};

/// codesign + Gatekeeper-preflight errors.
pub const SignError = error{
    IdentityNotFound,
    CertExpired,
    KeychainLocked,
    CodesignVerifyFailed,
    SpctlRejected,
    RunFailed,
    OutOfMemory,
};

/// notarytool submit/wait/log + stapler errors.
pub const NotarizeError = error{
    NotarizationRejected,
    HardenedRuntimeRequired,
    AppSpecificPasswordRequired,
    NotaryTimeout,
    StapleFailed,
    MalformedNotaryLog,
    RunFailed,
    OutOfMemory,
};

/// dmg errors. Intentionally UNIONS `SignError`/`NotarizeError` (unlike the pure
/// `BundleError` leaf): `makeDmg` re-signs and re-notarizes the `.dmg`, so a
/// `try sign(...)`/`try notarize(...)` inside it requires those sets here or the
/// error set will not unify. `config.CredError` is unioned too because `sign`
/// rejects a missing identity with `MissingSigningIdentity` (a `CredError`
/// member), so `makeDmg`'s re-entrant `try sign(...)` would not unify without it.
pub const DmgError = error{
    HdiutilFailed,
    RunFailed,
    OutOfMemory,
} || SignError || NotarizeError || config.CredError;

/// The full packaging error surface. `CredError`/`ConfigError` are NOT redefined
/// here — they are config's vocabulary, unioned in (config needs nothing from
/// diagnostics, so the config -> diagnostics task order has no import cycle).
pub const PackageError =
    config.CredError ||
    config.ConfigError ||
    BundleError ||
    SignError ||
    NotarizeError ||
    DmgError ||
    error{OutOfMemory};

// ---------------------------------------------------------------------------
// Diagnostic + Code
// ---------------------------------------------------------------------------

/// A structured, human-facing failure. `code`/`title`/`remediation` are stable;
/// `detail` is the captured stderr or formatted notary-log issue list. Zig error
/// values carry no payload, so a `Diagnostic` is written through the `*?Diagnostic`
/// out-pointer before a stage returns its typed error.
///
/// OWNERSHIP: `title`/`remediation` returned by `diagnose` are string LITERALS
/// (static, never freed). `detail` as returned by `diagnose` BORROWS the slice the
/// caller passed in. A stage that persists a `Diagnostic` past the lifetime of its
/// captured `RunResult` (every in-pipeline stage) must `gpa.dupe` `detail` itself
/// BEFORE freeing the `RunResult` and free that dupe at its own free site; `diagnose`
/// does no allocation and frees nothing.
pub const Diagnostic = struct {
    code: Code,
    title: []const u8,
    detail: []const u8,
    remediation: []const u8,
};

/// One variant per documented failure. The 8 spec-table rows + `unknown_tool_failure`
/// (the catch-all for any unmapped child failure, raw stderr attached, never swallowed)
/// + the three preflight-validation rows that map one-to-one to `config.ConfigError`'s
/// `InvalidIdentifier`/`InvalidVersion`/`OptionInjection` (so Task 11's preflight can
/// render a Diagnostic for each `validateConfig` rejection).
pub const Code = enum {
    missing_notary_credentials,
    identity_not_found,
    cert_expired,
    hardened_runtime_required,
    notarization_rejected,
    app_specific_password_required,
    keychain_locked,
    notary_timeout,
    unknown_tool_failure,
    invalid_identifier,
    invalid_version,
    option_injection,
};

/// LAYER OWNERSHIP of the substring/condition matches that drive each `Code`
/// (stated here so each fixture targets the layer that performs the match, and no
/// documented code ships unexercised):
///   - PURE BUILDER (`diagnose`, this file): `missing_notary_credentials`,
///     `notarization_rejected`, `unknown_tool_failure`, and the three preflight
///     codes `invalid_identifier`/`invalid_version`/`option_injection` (driven by
///     `validateConfig`'s typed error, not a substring). `identity_not_found`'s
///     "no identity found" stderr substring is ALSO matched at this layer's caller
///     (the sign stage classifies, then calls `diagnose(.identity_not_found, ...)`);
///     `diagnose` owns only the title/remediation rendering, not the substring scan.
///   - SIGN STAGE (Task 8): `cert_expired`, `keychain_locked` (the codesign-stderr
///     substring scans live with the codesign call).
///   - NOTARIZE STAGE (Task 9): `app_specific_password_required`,
///     `hardened_runtime_required` (notary-log / stderr scans), and `notary_timeout`
///     (the `--wait`-exceeded / `RunError.Timeout` condition).
/// `diagnose` is a PURE switch: given an already-classified `Code` + the captured
/// `detail`, it returns the matching title + remediation literal. It does no
/// substring matching of its own beyond accepting the classification.
pub fn diagnose(code: Code, detail: []const u8) Diagnostic {
    return switch (code) {
        .missing_notary_credentials => .{
            .code = code,
            .title = "No notary credentials configured",
            .detail = detail,
            .remediation = "Set APPLE_API_KEY + APPLE_API_ISSUER + APPLE_API_KEY_PATH, or APPLE_ID + APPLE_PASSWORD + APPLE_TEAM_ID.",
        },
        .identity_not_found => .{
            .code = code,
            .title = "Signing identity not found",
            .detail = detail,
            .remediation = "No 'Developer ID Application' certificate in the keychain. Run `security find-identity -v -p codesigning`.",
        },
        .cert_expired => .{
            .code = code,
            .title = "Signing certificate expired",
            .detail = detail,
            .remediation = "The signing certificate has expired; renew it in the Apple Developer portal.",
        },
        .hardened_runtime_required => .{
            .code = code,
            .title = "Hardened runtime required",
            .detail = detail,
            .remediation = "hardenedRuntime must be true; this is forced unless skip_notarize is set.",
        },
        .notarization_rejected => .{
            .code = code,
            .title = "Notarization rejected",
            // `detail` is the formatted notary-log issue list (built by the notarize
            // stage from the parsed result, gpa-duped there), surfaced verbatim.
            .detail = detail,
            .remediation = "The notary service rejected the submission. Fix the issues listed above and re-run.",
        },
        .app_specific_password_required => .{
            .code = code,
            .title = "App-specific password required",
            .detail = detail,
            .remediation = "APPLE_PASSWORD must be an app-specific password from appleid.apple.com, not your account password.",
        },
        .keychain_locked => .{
            .code = code,
            .title = "CI keychain locked",
            .detail = detail,
            .remediation = "The CI keychain is locked; ensure the APPLE_CERTIFICATE import into the temporary keychain ran.",
        },
        .notary_timeout => .{
            .code = code,
            .title = "Notary service timed out",
            .detail = detail,
            .remediation = "The notary service was slow; re-run. The submission is idempotent by content hash.",
        },
        .unknown_tool_failure => .{
            .code = code,
            .title = "Packaging tool failed",
            // Raw captured stderr, attached so the failure is never swallowed.
            .detail = detail,
            .remediation = "An unmapped tool failure occurred. Inspect the captured output above and re-run.",
        },
        .invalid_identifier => .{
            .code = code,
            .title = "Invalid bundle identifier",
            .detail = detail,
            .remediation = "The bundle identifier must be a reverse-DNS name (at least two labels, no leading digit or hyphen).",
        },
        .invalid_version => .{
            .code = code,
            .title = "Invalid version",
            .detail = detail,
            .remediation = "The version must be a semantic version (MAJOR.MINOR.PATCH).",
        },
        .option_injection => .{
            .code = code,
            .title = "Disallowed leading dash in a config value",
            .detail = detail,
            .remediation = "A configured value begins with '-', which a packaging tool would read as a flag. Remove the leading dash.",
        },
    };
}

// ---------------------------------------------------------------------------
// Notary-log parsing
// ---------------------------------------------------------------------------

/// One notary-log issue. Fields are OPTIONAL because a well-formed log may carry an
/// explicit JSON `null` for any of them; a null field must not be miscategorized as
/// malformed.
pub const NotaryIssue = struct {
    path: ?[]const u8 = null,
    message: ?[]const u8 = null,
    severity: ?[]const u8 = null,
};

/// The slice of the notarytool JSON this module reads. `issues` DEFAULTS to an empty
/// slice so both the `submit --wait` shape (status, no issues) and a bare
/// `{"status":"Invalid"}` parse without an error. `id` DEFAULTS to an empty string:
/// the `submit --wait` JSON carries the submission `id` the `notarytool log <id>`
/// argv needs, while the `log` JSON (status + issues) omits it; one struct serves
/// both parses. Unknown notarytool fields (`jobId`/`statusSummary`/`docUrl`/
/// `architecture`/...) are ignored at parse time.
pub const NotaryResult = struct {
    id: []const u8 = "",
    status: []const u8 = "",
    issues: []const NotaryIssue = &.{},
};

/// The classified notary outcome. An unrecognized-but-parseable `status` resolves to
/// `.unknown` (never silently `.accepted`).
pub const Outcome = enum { accepted, invalid, unknown };

/// Classify a notary `status` string. Only the exact "Accepted"/"Invalid" strings map
/// to their outcomes; anything else (e.g. "In Progress") is `.unknown`.
pub fn classifyNotary(status: []const u8) Outcome {
    if (std.mem.eql(u8, status, "Accepted")) return .accepted;
    if (std.mem.eql(u8, status, "Invalid")) return .invalid;
    return .unknown;
}

/// Parse a notarytool JSON document into a `std.json.Parsed(NotaryResult)`.
///
/// The returned `Parsed` OWNS the parser arena that the `status`/`issues` slices
/// borrow, so the CALLER MUST `defer parsed.deinit()`. This is the named free site for
/// the one otherwise-unaccounted owned allocation in the notarize stage; a stage that
/// keeps any string from the parse result must `gpa.dupe` it (into `Diagnostic.detail`)
/// BEFORE the `defer` frees the arena, never borrow a slice into the parsed value.
///
/// Malformed input maps to `error.MalformedNotaryLog` (a `NotarizeError` member) so an
/// unparseable log is a domain failure, not a leaked std json error.
pub fn parseNotaryResult(
    gpa: std.mem.Allocator,
    json: []const u8,
) error{ MalformedNotaryLog, OutOfMemory }!std.json.Parsed(NotaryResult) {
    return std.json.parseFromSlice(NotaryResult, gpa, json, .{
        .ignore_unknown_fields = true,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedNotaryLog,
    };
}

// ---------------------------------------------------------------------------
// Tests (TDD step 1: written before the implementation above existed).
// ---------------------------------------------------------------------------

test "diagnose renders each pure-builder code with its remediation and the passed detail" {
    // The pure `diagnose` builder owns these codes. Each carries a static title +
    // remediation literal and BORROWS the passed detail slice (never owned/freed).
    const cases = [_]Code{
        .missing_notary_credentials,
        .identity_not_found,
        .notarization_rejected,
        .invalid_identifier,
        .invalid_version,
        .option_injection,
        .unknown_tool_failure,
    };
    for (cases) |code| {
        const d = diagnose(code, "captured-detail");
        try std.testing.expectEqual(code, d.code);
        try std.testing.expect(d.title.len > 0);
        try std.testing.expect(d.remediation.len > 0);
        // Detail is the borrowed passed slice, verbatim.
        try std.testing.expectEqualStrings("captured-detail", d.detail);
    }
}

test "diagnose detail carries no secret of its own (it is exactly the passed slice)" {
    // A Diagnostic never fabricates a secret; detail is whatever the stage passed,
    // which the stages guarantee names the env var, not its value.
    const d = diagnose(.missing_notary_credentials, "APPLE_API_KEY");
    try std.testing.expectEqualStrings("APPLE_API_KEY", d.detail);
    // The remediation names the env vars, never a value.
    try std.testing.expect(std.mem.indexOf(u8, d.remediation, "APPLE_API_KEY") != null);
}

test "parseNotaryResult Accepted yields the accepted outcome with no issues" {
    const gpa = std.testing.allocator;
    const parsed = try parseNotaryResult(gpa, "{\"status\":\"Accepted\"}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Accepted", parsed.value.status);
    try std.testing.expectEqual(@as(Outcome, .accepted), classifyNotary(parsed.value.status));
    try std.testing.expectEqual(@as(usize, 0), parsed.value.issues.len);
}

test "parseNotaryResult Invalid surfaces the issue list verbatim" {
    const gpa = std.testing.allocator;
    const json =
        \\{"status":"Invalid","issues":[
        \\  {"path":"Foo.app","message":"not signed with a hardened runtime","severity":"error"},
        \\  {"path":"Bar","message":"bad","severity":"warning"}
        \\]}
    ;
    const parsed = try parseNotaryResult(gpa, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(Outcome, .invalid), classifyNotary(parsed.value.status));
    try std.testing.expectEqual(@as(usize, 2), parsed.value.issues.len);
    try std.testing.expectEqualStrings("not signed with a hardened runtime", parsed.value.issues[0].message.?);
    try std.testing.expectEqualStrings("error", parsed.value.issues[0].severity.?);
}

test "parseNotaryResult Invalid with no issues key yields an empty list" {
    const gpa = std.testing.allocator;
    const parsed = try parseNotaryResult(gpa, "{\"status\":\"Invalid\"}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(Outcome, .invalid), classifyNotary(parsed.value.status));
    try std.testing.expectEqual(@as(usize, 0), parsed.value.issues.len);
}

test "parseNotaryResult Invalid with an empty issues array yields an empty list" {
    const gpa = std.testing.allocator;
    const parsed = try parseNotaryResult(gpa, "{\"status\":\"Invalid\",\"issues\":[]}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(Outcome, .invalid), classifyNotary(parsed.value.status));
    try std.testing.expectEqual(@as(usize, 0), parsed.value.issues.len);
}

test "parseNotaryResult ignores unknown notarytool fields" {
    const gpa = std.testing.allocator;
    // Real notarytool output carries jobId/statusSummary/docUrl/architecture etc.
    const json =
        \\{"jobId":"abc","statusSummary":"all good","status":"Accepted","docUrl":"http://x"}
    ;
    const parsed = try parseNotaryResult(gpa, json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Accepted", parsed.value.status);
}

test "parseNotaryResult tolerates a null issue field" {
    const gpa = std.testing.allocator;
    const json =
        \\{"status":"Invalid","issues":[{"path":null,"message":"bad","severity":null}]}
    ;
    const parsed = try parseNotaryResult(gpa, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.issues.len);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.issues[0].path);
    try std.testing.expectEqualStrings("bad", parsed.value.issues[0].message.?);
}

test "parseNotaryResult unrecognized-but-parseable status classifies as unknown, never accepted" {
    const gpa = std.testing.allocator;
    const parsed = try parseNotaryResult(gpa, "{\"status\":\"In Progress\"}");
    defer parsed.deinit();
    // Must NOT silently Accept an unexpected status.
    const outcome = classifyNotary(parsed.value.status);
    try std.testing.expect(outcome != .accepted);
    try std.testing.expectEqual(@as(Outcome, .unknown), outcome);
}

test "parseNotaryResult on malformed JSON returns MalformedNotaryLog" {
    const gpa = std.testing.allocator;
    const r = parseNotaryResult(gpa, "{not json");
    try std.testing.expectError(error.MalformedNotaryLog, r);
}

test "PackageError unions config, bundle, sign, notarize, and dmg errors" {
    // Membership smoke: each contributing set's representative variant coerces in.
    const e: PackageError = error.MissingNotaryCredentials; // config.CredError
    try std.testing.expectError(error.MissingNotaryCredentials, @as(PackageError!void, e));
    const e2: PackageError = error.InvalidIdentifier; // config.ConfigError
    try std.testing.expectError(error.InvalidIdentifier, @as(PackageError!void, e2));
    const e3: PackageError = error.CreateDirPathFailed; // BundleError
    try std.testing.expectError(error.CreateDirPathFailed, @as(PackageError!void, e3));
    const e4: PackageError = error.CodesignVerifyFailed; // SignError
    try std.testing.expectError(error.CodesignVerifyFailed, @as(PackageError!void, e4));
    const e5: PackageError = error.NotarizationRejected; // NotarizeError
    try std.testing.expectError(error.NotarizationRejected, @as(PackageError!void, e5));
    const e6: PackageError = error.HdiutilFailed; // DmgError
    try std.testing.expectError(error.HdiutilFailed, @as(PackageError!void, e6));
}

test "BundleError is a pure-domain set with no std unions" {
    // CreateDirPathFailed replaces the spec's MakePathFailed; no raw std.Io.Dir.Error
    // member leaks into the set (every raw FS error is mapped to one of these).
    const e: BundleError = error.CreateDirPathFailed;
    try std.testing.expectError(error.CreateDirPathFailed, @as(BundleError!void, e));
}

test "DmgError unions the re-entered sign and notarize sets" {
    // makeDmg re-signs + re-notarizes the dmg, so DmgError must carry those sets.
    const e: DmgError = error.CodesignVerifyFailed; // from SignError
    try std.testing.expectError(error.CodesignVerifyFailed, @as(DmgError!void, e));
    const e2: DmgError = error.NotarizationRejected; // from NotarizeError
    try std.testing.expectError(error.NotarizationRejected, @as(DmgError!void, e2));
}
