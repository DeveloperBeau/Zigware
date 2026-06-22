const std = @import("std");
const config = @import("config.zig");
const diagnostics = @import("diagnostics.zig");
const runner_mod = @import("runner.zig");

const Credentials = config.Credentials;
const NotarizeError = diagnostics.NotarizeError;
const Diagnostic = diagnostics.Diagnostic;
const Runner = runner_mod.Runner;

// ---------------------------------------------------------------------------
// Pure argv builders. Three tools take part in this stage and each gets its own
// builder + assertion: `notarytool submit`, `notarytool log`, and `stapler
// staple`. Every builder returns a gpa-owned slice of gpa-owned strings; the
// caller frees each element then the slice (see `freeArgvOwned`).
//
// No secret reaches a LOG line: the API-key form carries only the .p8 PATH +
// issuer + key-id (never the key bytes). The Apple-ID fallback necessarily puts
// `--password <app-specific-pw>` in the child argv (inherent to notarytool's
// CLI, visible to local `ps` for the call's lifetime), so API-key is preferred.
// The guarantee is "no secret in a Diagnostic / log line", NOT
// "argv is secret-free"; `notarize` never copies an argv into a Diagnostic.
// ---------------------------------------------------------------------------

/// `xcrun notarytool submit <path> <creds...> --wait --output-format json`.
/// The creds form is selected off the `Credentials` union tag; `.none` is
/// unreachable here (package() gates a missing-notary-credentials config before
/// ever reaching the stage).
pub fn buildNotarizeArgv(
    gpa: std.mem.Allocator,
    target_path: []const u8,
    creds: Credentials,
) std.mem.Allocator.Error![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer freeArgvBuilding(gpa, &args);

    try appendDup(gpa, &args, "xcrun");
    try appendDup(gpa, &args, "notarytool");
    try appendDup(gpa, &args, "submit");
    try appendDup(gpa, &args, target_path);
    try appendCreds(gpa, &args, creds);
    try appendDup(gpa, &args, "--wait");
    try appendDup(gpa, &args, "--output-format");
    try appendDup(gpa, &args, "json");

    return try args.toOwnedSlice(gpa);
}

/// `xcrun notarytool log <submission-id> <creds...> --output-format json`. Fetches
/// the per-submission issue log after an `Invalid` result. The submission id is
/// carried from the submit JSON's `id` field.
pub fn buildNotaryLogArgv(
    gpa: std.mem.Allocator,
    submission_id: []const u8,
    creds: Credentials,
) std.mem.Allocator.Error![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer freeArgvBuilding(gpa, &args);

    try appendDup(gpa, &args, "xcrun");
    try appendDup(gpa, &args, "notarytool");
    try appendDup(gpa, &args, "log");
    try appendDup(gpa, &args, submission_id);
    try appendCreds(gpa, &args, creds);
    try appendDup(gpa, &args, "--output-format");
    try appendDup(gpa, &args, "json");

    return try args.toOwnedSlice(gpa);
}

/// `xcrun stapler staple <path>`. Staples the notary ticket into the target so it
/// validates offline. `stapler` is a distinct tool from `notarytool`.
pub fn buildStapleArgv(
    gpa: std.mem.Allocator,
    target_path: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer freeArgvBuilding(gpa, &args);

    try appendDup(gpa, &args, "xcrun");
    try appendDup(gpa, &args, "stapler");
    try appendDup(gpa, &args, "staple");
    try appendDup(gpa, &args, target_path);

    return try args.toOwnedSlice(gpa);
}

/// Append the credential flags for whichever notary strategy is active. API-key
/// passes the .p8 PATH only; Apple-ID passes the app-specific password into argv
/// (inherent to notarytool; the password is never copied into a Diagnostic). `.none` is a caller
/// bug (package() gates it), so it is unreachable.
fn appendCreds(gpa: std.mem.Allocator, args: *std.ArrayList([]const u8), creds: Credentials) std.mem.Allocator.Error!void {
    switch (creds) {
        .api_key => |k| {
            try appendDup(gpa, args, "--key");
            try appendDup(gpa, args, k.key_path);
            try appendDup(gpa, args, "--key-id");
            try appendDup(gpa, args, k.key_id);
            try appendDup(gpa, args, "--issuer");
            try appendDup(gpa, args, k.issuer);
        },
        .apple_id => |a| {
            try appendDup(gpa, args, "--apple-id");
            try appendDup(gpa, args, a.apple_id);
            try appendDup(gpa, args, "--password");
            try appendDup(gpa, args, a.password);
            try appendDup(gpa, args, "--team-id");
            try appendDup(gpa, args, a.team_id);
        },
        .none => unreachable, // package() rejects a missing-creds config upstream.
    }
}

/// Dupe `s` into gpa and append it; the ArrayList owns the element on success.
fn appendDup(gpa: std.mem.Allocator, args: *std.ArrayList([]const u8), s: []const u8) std.mem.Allocator.Error!void {
    const dup = try gpa.dupe(u8, s);
    errdefer gpa.free(dup);
    try args.append(gpa, dup);
}

// ---------------------------------------------------------------------------
// notarize: submit, wait, parse, then staple-on-accept / fetch-log-on-reject.
//
// On a failure path `notarize` writes a `gpa.dupe`-owned `Diagnostic` through
// `diag` BEFORE freeing its `RunResult` / parse result, then returns the typed
// `NotarizeError`. `creds` is the notary union (NOT `ResolvedCredentials`):
// package() splits the resolved creds and hands only the notary arm here.
//
// Parse lifetimes: each `parseNotaryResult` returns a `std.json.Parsed` owning a
// parser arena the `status`/`id`/`issues` slices borrow, so each is `defer
// parsed.deinit()`'d. Anything kept past the arena (the formatted issue list into
// `Diagnostic.detail`) is `gpa.dupe`'d before the arena frees; no slice may borrow into the parsed value.
// ---------------------------------------------------------------------------

pub fn notarize(
    io: std.Io,
    gpa: std.mem.Allocator,
    runner: *Runner,
    target_path: []const u8,
    creds: Credentials,
    diag: *?Diagnostic,
) NotarizeError!void {
    // 1) submit --wait. A runner-level Timeout is the documented `notary_timeout`
    //    code (the `--wait` window exceeded), classified at the catch site so the
    //    diagnostic is set; OOM propagates; other runner failures are RunFailed.
    const submit_argv = try buildNotarizeArgv(gpa, target_path, creds);
    defer freeArgvOwned(gpa, submit_argv);

    const submit_id = blk: {
        const result = runner.run(io, gpa, submit_argv) catch |e| return mapRunError(e, gpa, diag);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);

        if (!termOk(result.term)) {
            // A non-zero submit exit: classify the stderr. The one stage-owned
            // stderr code here is `app_specific_password_required`; otherwise the
            // unknown_tool_failure catch-all (raw stderr attached, never swallowed).
            return classifySubmitFailure(gpa, result.stderr, diag);
        }

        // Parse the submit JSON for status + submission id. Both slices borrow the
        // parser arena, so dupe the id out before the arena frees.
        const parsed = parseOrDiagnose(gpa, result.stdout, diag) catch |e| return e;
        defer parsed.deinit();

        switch (diagnostics.classifyNotary(parsed.value.status)) {
            .accepted => break :blk null, // staple, no id needed
            .invalid => break :blk gpa.dupe(u8, parsed.value.id) catch return error.OutOfMemory,
            .unknown => {
                // A parseable-but-unrecognized status is never silently accepted;
                // surface it as a rejection with the status as detail.
                const detail = gpa.dupe(u8, parsed.value.status) catch return error.OutOfMemory;
                diag.* = diagnostics.diagnose(.notarization_rejected, detail);
                return error.NotarizationRejected;
            },
        }
    };

    // 2a) Invalid → fetch the per-submission log, format the issue list into the
    //     diagnostic, classify hardened-runtime, and reject.
    if (submit_id) |id| {
        defer gpa.free(id);
        return fetchLogAndReject(io, gpa, runner, id, creds, diag);
    }

    // 2b) Accepted → staple the ticket. A stapler failure is a hard error.
    const staple_argv = try buildStapleArgv(gpa, target_path);
    defer freeArgvOwned(gpa, staple_argv);
    const result = runner.run(io, gpa, staple_argv) catch |e| return mapRunError(e, gpa, diag);
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!termOk(result.term)) {
        const detail = gpa.dupe(u8, result.stderr) catch return error.OutOfMemory;
        diag.* = diagnostics.diagnose(.unknown_tool_failure, detail);
        return error.StapleFailed;
    }
}

/// Fetch `notarytool log <id>`, parse the issue list, format it into the
/// diagnostic detail (gpa-owned, never a borrow into the parsed arena), classify
/// hardened-runtime vs a generic rejection, and return the typed error.
fn fetchLogAndReject(
    io: std.Io,
    gpa: std.mem.Allocator,
    runner: *Runner,
    submission_id: []const u8,
    creds: Credentials,
    diag: *?Diagnostic,
) NotarizeError!void {
    const log_argv = try buildNotaryLogArgv(gpa, submission_id, creds);
    defer freeArgvOwned(gpa, log_argv);

    const result = runner.run(io, gpa, log_argv) catch |e| return mapRunError(e, gpa, diag);
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // A failed log fetch still means the submission was rejected; format what we
    // can (the raw stderr) and reject rather than masking the rejection.
    if (!termOk(result.term)) {
        const detail = gpa.dupe(u8, result.stderr) catch return error.OutOfMemory;
        diag.* = diagnostics.diagnose(.notarization_rejected, detail);
        return error.NotarizationRejected;
    }

    const parsed = parseOrDiagnose(gpa, result.stdout, diag) catch |e| return e;
    defer parsed.deinit();

    // Format the issue list into an owned string BEFORE the parsed arena frees.
    const detail = try formatIssues(gpa, parsed.value.issues);
    // `detail` is now gpa-owned and handed to the diagnostic on both branches
    // below, so no errdefer: every branch returns WITH the diagnostic owning it.

    if (containsCi(detail, "hardened runtime")) {
        diag.* = diagnostics.diagnose(.hardened_runtime_required, detail);
        return error.HardenedRuntimeRequired;
    }
    diag.* = diagnostics.diagnose(.notarization_rejected, detail);
    return error.NotarizationRejected;
}

/// Classify a non-zero `notarytool submit` stderr. The one stage-owned stderr code
/// is `app_specific_password_required`; everything else is the unknown_tool_failure
/// catch-all. The matched stderr is duped into the Diagnostic (owned by `diag.*`
/// thereafter); no errdefer (every branch returns WITH the diagnostic populated).
///
/// SECURITY: `detail` is built from stderr only, NEVER from the argv/creds, so the
/// app-specific password (which legitimately sits in the submit argv) cannot leak
/// into a Diagnostic.
fn classifySubmitFailure(gpa: std.mem.Allocator, stderr: []const u8, diag: *?Diagnostic) NotarizeError {
    const detail = gpa.dupe(u8, stderr) catch return error.OutOfMemory;

    if (containsCi(stderr, "app-specific password") or containsCi(stderr, "app specific password")) {
        diag.* = diagnostics.diagnose(.app_specific_password_required, detail);
        return error.AppSpecificPasswordRequired;
    }
    diag.* = diagnostics.diagnose(.unknown_tool_failure, detail);
    return error.RunFailed;
}

/// Parse a notary JSON document, mapping a malformed log to its diagnostic +
/// typed error. On success the caller owns the returned `Parsed` and must
/// `defer parsed.deinit()`.
fn parseOrDiagnose(
    gpa: std.mem.Allocator,
    json: []const u8,
    diag: *?Diagnostic,
) NotarizeError!std.json.Parsed(diagnostics.NotaryResult) {
    return diagnostics.parseNotaryResult(gpa, json) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MalformedNotaryLog => {
            const detail = gpa.dupe(u8, "the notary service returned an unparseable JSON document") catch
                return error.OutOfMemory;
            diag.* = diagnostics.diagnose(.unknown_tool_failure, detail);
            return error.MalformedNotaryLog;
        },
    };
}

/// Format the parsed issue list into a single gpa-owned string. Each issue is one
/// line `severity: message (path)`; null fields are rendered as `?`. The result is
/// independent of the parsed arena (it is built fresh), so it survives the caller's
/// `parsed.deinit()`.
fn formatIssues(gpa: std.mem.Allocator, issues: []const diagnostics.NotaryIssue) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    if (issues.len == 0) {
        w.writeAll("the notary service rejected the submission (no issue list returned)") catch return error.OutOfMemory;
    } else {
        for (issues) |issue| {
            w.print("{s}: {s} ({s})\n", .{
                issue.severity orelse "?",
                issue.message orelse "?",
                issue.path orelse "?",
            }) catch return error.OutOfMemory;
        }
    }
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

/// Map a runner failure to a NotarizeError. A `Timeout` is the documented
/// `notary_timeout` code (the `--wait` window exceeded) and sets the diagnostic at
/// this site (it cannot be a pure error-only helper). OOM propagates; everything
/// else collapses to RunFailed.
fn mapRunError(e: runner_mod.RunError, gpa: std.mem.Allocator, diag: *?Diagnostic) NotarizeError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Timeout => {
            const detail = gpa.dupe(u8, "notarytool --wait exceeded the timeout window") catch
                return error.OutOfMemory;
            diag.* = diagnostics.diagnose(.notary_timeout, detail);
            return error.NotaryTimeout;
        },
        else => error.RunFailed,
    };
}

/// Case-insensitive substring match (notary/Security messages vary in casing).
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

/// Free a partially-built argv ArrayList (each element, then the backing).
fn freeArgvBuilding(gpa: std.mem.Allocator, args: *std.ArrayList([]const u8)) void {
    for (args.items) |a| gpa.free(a);
    args.deinit(gpa);
}

// ---------------------------------------------------------------------------
// Tests (TDD step 1: written before the implementation above existed).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn freeArgv(gpa: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| gpa.free(a);
    gpa.free(argv);
}

fn apiKeyCreds() Credentials {
    return .{ .api_key = .{
        .key_id = "AbCdEf12",
        .issuer = "issuer-uuid",
        .key_path = "/keys/AuthKey.p8",
    } };
}

fn appleIdCreds() Credentials {
    return .{ .apple_id = .{
        .apple_id = "dev@example.com",
        .password = "app-specific-pw",
        .team_id = "TEAMID1234",
    } };
}

// ── buildNotarizeArgv (pure) ─────────────────────────────────────────────────

test "buildNotarizeArgv emits the API-key submit form" {
    const gpa = testing.allocator;
    const argv = try buildNotarizeArgv(gpa, "Foo.dmg", apiKeyCreds());
    defer freeArgv(gpa, argv);

    const expected = [_][]const u8{
        "xcrun",    "notarytool",       "submit",   "Foo.dmg",
        "--key",    "/keys/AuthKey.p8", "--key-id", "AbCdEf12",
        "--issuer", "issuer-uuid",      "--wait",   "--output-format",
        "json",
    };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try testing.expectEqualStrings(e, a);
}

test "buildNotarizeArgv emits the Apple-ID submit form" {
    const gpa = testing.allocator;
    const argv = try buildNotarizeArgv(gpa, "Foo.dmg", appleIdCreds());
    defer freeArgv(gpa, argv);

    const expected = [_][]const u8{
        "xcrun",      "notarytool",      "submit",     "Foo.dmg",
        "--apple-id", "dev@example.com", "--password", "app-specific-pw",
        "--team-id",  "TEAMID1234",      "--wait",     "--output-format",
        "json",
    };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try testing.expectEqualStrings(e, a);
}

// ── buildNotaryLogArgv (pure) ────────────────────────────────────────────────

test "buildNotaryLogArgv carries the submission id and output-format json" {
    const gpa = testing.allocator;
    const argv = try buildNotaryLogArgv(gpa, "sub-1234", apiKeyCreds());
    defer freeArgv(gpa, argv);

    const expected = [_][]const u8{
        "xcrun",    "notarytool",       "log",             "sub-1234",
        "--key",    "/keys/AuthKey.p8", "--key-id",        "AbCdEf12",
        "--issuer", "issuer-uuid",      "--output-format", "json",
    };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try testing.expectEqualStrings(e, a);
}

// ── buildStapleArgv (pure) ───────────────────────────────────────────────────

test "buildStapleArgv emits the stapler staple shape" {
    const gpa = testing.allocator;
    const argv = try buildStapleArgv(gpa, "Foo.dmg");
    defer freeArgv(gpa, argv);

    const expected = [_][]const u8{ "xcrun", "stapler", "staple", "Foo.dmg" };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try testing.expectEqualStrings(e, a);
}

// ── notarize over a FakeRunner ───────────────────────────────────────────────

test "notarize on Accepted submits then staples" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "{\"id\":\"sub-1\",\"status\":\"Accepted\"}", .stderr = "" });
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" }); // stapler
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    try notarize(io, gpa, &runner, "Foo.dmg", apiKeyCreds(), &diag);

    try testing.expect(diag == null);
    try testing.expectEqual(@as(usize, 2), fr.argv_log.items.len);
    try testing.expectEqualStrings("notarytool", fr.argv_log.items[0][1]);
    try testing.expectEqualStrings("submit", fr.argv_log.items[0][2]);
    // The staple call.
    const staple = fr.argv_log.items[1];
    try testing.expectEqualStrings("stapler", staple[1]);
    try testing.expectEqualStrings("staple", staple[2]);
    try testing.expectEqualStrings("Foo.dmg", staple[3]);
}

test "notarize on Invalid fetches the log and surfaces the issue list" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "{\"id\":\"sub-9\",\"status\":\"Invalid\"}", .stderr = "" });
    try fr.push(.{
        .term = .{ .exited = 0 },
        .stdout =
        \\{"status":"Invalid","issues":[{"path":"Foo.app","message":"binary is not signed","severity":"error"}]}
        ,
        .stderr = "",
    });
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const r = notarize(io, gpa, &runner, "Foo.dmg", apiKeyCreds(), &diag);
    try testing.expectError(error.NotarizationRejected, r);

    // submit then log; no staple.
    try testing.expectEqual(@as(usize, 2), fr.argv_log.items.len);
    const log = fr.argv_log.items[1];
    try testing.expectEqualStrings("log", log[2]);
    try testing.expectEqualStrings("sub-9", log[3]);

    try testing.expect(diag != null);
    try testing.expectEqual(diagnostics.Code.notarization_rejected, diag.?.code);
    // The parsed issue text reached the diagnostic detail (gpa-owned, not a borrow).
    try testing.expect(std.mem.indexOf(u8, diag.?.detail, "binary is not signed") != null);
    gpa.free(diag.?.detail);
}

test "notarize on a malformed submit JSON returns MalformedNotaryLog" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "{not json", .stderr = "" });
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const r = notarize(io, gpa, &runner, "Foo.dmg", apiKeyCreds(), &diag);
    try testing.expectError(error.MalformedNotaryLog, r);
    try testing.expect(diag != null);
    gpa.free(diag.?.detail);
}

test "notarize on Accepted then a failing staple returns StapleFailed" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "{\"id\":\"sub-1\",\"status\":\"Accepted\"}", .stderr = "" });
    try fr.push(.{ .term = .{ .exited = 1 }, .stdout = "", .stderr = "stapler: could not staple" });
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const r = notarize(io, gpa, &runner, "Foo.dmg", apiKeyCreds(), &diag);
    try testing.expectError(error.StapleFailed, r);
    try testing.expect(diag != null);
    gpa.free(diag.?.detail);
}

// ── classifier coverage (the three codes this stage owns) ────────────────────

test "notarize classifies an app-specific-password submit failure" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{
        .term = .{ .exited = 1 },
        .stdout = "",
        .stderr = "Error: You must provide an app-specific password for this account.",
    });
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const r = notarize(io, gpa, &runner, "Foo.dmg", appleIdCreds(), &diag);
    try testing.expectError(error.AppSpecificPasswordRequired, r);
    try testing.expect(diag != null);
    try testing.expectEqual(diagnostics.Code.app_specific_password_required, diag.?.code);
    gpa.free(diag.?.detail);
}

test "notarize classifies a hardened-runtime notary-log rejection" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    try fr.push(.{ .term = .{ .exited = 0 }, .stdout = "{\"id\":\"sub-3\",\"status\":\"Invalid\"}", .stderr = "" });
    try fr.push(.{
        .term = .{ .exited = 0 },
        .stdout =
        \\{"status":"Invalid","issues":[{"path":"Foo","message":"The executable does not have the hardened runtime enabled.","severity":"error"}]}
        ,
        .stderr = "",
    });
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const r = notarize(io, gpa, &runner, "Foo.dmg", apiKeyCreds(), &diag);
    try testing.expectError(error.HardenedRuntimeRequired, r);
    try testing.expect(diag != null);
    try testing.expectEqual(diagnostics.Code.hardened_runtime_required, diag.?.code);
    gpa.free(diag.?.detail);
}

test "notarize maps a runner timeout to notary_timeout" {
    const gpa = testing.allocator;

    // A runner whose run always reports Timeout, to exercise the --wait window map.
    const TimeoutRunner = struct {
        fn run(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const []const u8) runner_mod.RunError!runner_mod.RunResult {
            return error.Timeout;
        }
    };
    var ctx: u8 = 0;
    var runner = Runner{ .ctx = &ctx, .runFn = TimeoutRunner.run };

    var diag: ?Diagnostic = null;
    const r = notarize(testing.io, gpa, &runner, "Foo.dmg", apiKeyCreds(), &diag);
    try testing.expectError(error.NotaryTimeout, r);
    try testing.expect(diag != null);
    try testing.expectEqual(diagnostics.Code.notary_timeout, diag.?.code);
    gpa.free(diag.?.detail);
}

// ── secret-leak assertion on the Apple-ID path ───────────────────────────────

test "notarize never copies the app-specific password into the diagnostic" {
    const io = testing.io;
    const gpa = testing.allocator;

    var fr = runner_mod.FakeRunner.init(gpa);
    defer fr.deinit();
    // A generic submit failure on the Apple-ID path: detail is the stderr only.
    try fr.push(.{ .term = .{ .exited = 1 }, .stdout = "", .stderr = "Error: submission failed for an unrelated reason." });
    var runner = fr.runner();

    var diag: ?Diagnostic = null;
    const r = notarize(io, gpa, &runner, "Foo.dmg", appleIdCreds(), &diag);
    try testing.expectError(error.RunFailed, r);
    try testing.expect(diag != null);
    // The password is in the argv_log (test-only) but MUST NOT appear in the diagnostic.
    try testing.expect(std.mem.indexOf(u8, diag.?.detail, "app-specific-pw") == null);
    // It is, however, present in the recorded argv (proving the test is meaningful).
    const submit = fr.argv_log.items[0];
    var found_pw = false;
    for (submit) |a| {
        if (std.mem.eql(u8, a, "app-specific-pw")) found_pw = true;
    }
    try testing.expect(found_pw);
    gpa.free(diag.?.detail);
}
