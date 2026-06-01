const std = @import("std");
const protocol = @import("protocol.zig");
const ctxmod = @import("command_ctx.zig");
const jobs = @import("jobs.zig");
const Allowlist = @import("allowlist.zig").Allowlist;

const Ctx = ctxmod.Ctx;
const Async = ctxmod.Async;
const Bytes = ctxmod.Bytes;
const CommandError = ctxmod.CommandError;

/// Per-command comptime metadata.
const Meta = struct {
    name: []const u8,
    is_async: bool,
};

/// True if `T` is `Async(X)` for some X. Detected structurally: a one-field
/// struct named exactly `inner`. (Matches command_ctx.Async's shape.)
fn asyncInner(comptime T: type) ?type {
    const info = @typeInfo(T);
    if (info != .@"struct") return null;
    const s = info.@"struct";
    if (s.fields.len != 1) return null;
    if (!std.mem.eql(u8, s.fields[0].name, "inner")) return null;
    // Confirm it is literally Async(field type), not a coincidental {inner: X}.
    if (T != Async(s.fields[0].type)) return null;
    return s.fields[0].type;
}

/// fn Commands(comptime B: type, comptime State: type) type.
/// `UserCommands` is the app author's struct of pub fns. `B` is unused inside
/// the registry (jobs.Pool is non-generic, EmitSink is concrete); it stays in
/// the signature for spec parity and so emit_dts can instantiate
/// Commands(NullBackend, State). The user struct is read from a third param so
/// the call site reads `Commands(B, State, app.Commands)`.
pub fn Commands(comptime B: type, comptime State: type, comptime UserCommands: type) type {
    _ = B;
    comptime validate(State, UserCommands);
    return struct {
        pub const command_names: []const []const u8 = buildNames(UserCommands);

        pub fn allowlist() Allowlist {
            var a: Allowlist = .empty;
            inline for (command_names) |n| a.add(n) catch unreachable;
            return a;
        }

        pub fn isAsync(name: []const u8) bool {
            inline for (comptime metas(UserCommands)) |m| {
                if (std.mem.eql(u8, m.name, name)) return m.is_async;
            }
            return false;
        }

        /// Decode args_json, run the handler (sync inline or async on the pool),
        /// encode the terminal result through protocol. Never traps on bad input.
        /// `bridge` is duck-typed (see plan deviation 1): the registry calls
        /// exactly bridge.alloc, bridge.pool, bridge.makeSink(id),
        /// bridge.releaseCall(id), bridge.emitResolve, and bridge.emitErrorReject;
        /// it never names a concrete Bridge type. It never calls reserveCall (the
        /// bridge reserves before dispatch) and never reads bridge.io. StubBridge
        /// below is the authoritative shape of that surface.
        pub fn dispatch(
            bridge: anytype,
            state: *State,
            name: []const u8,
            id: u64,
            args_json: []const u8,
        ) void {
            inline for (comptime declFns(UserCommands)) |d| {
                if (std.mem.eql(u8, d.name, name)) {
                    dispatchOne(@field(UserCommands, d.name), bridge, state, id, args_json);
                    return;
                }
            }
            // Unknown command never reaches here: the gate (Task 5) checks the
            // allowlist first. Defensive structured reject just in case.
            bridge.emitErrorReject(id, "unknown_command", "no such command", null);
            bridge.releaseCall(id);
        }
    };
}

/// A declaration that is a pub fn (skips nested consts/types).
const FnDecl = struct { name: []const u8 };

fn declFns(comptime UserCommands: type) []const FnDecl {
    comptime {
        var list: []const FnDecl = &.{};
        for (@typeInfo(UserCommands).@"struct".decls) |d| {
            const f = @field(UserCommands, d.name);
            if (@typeInfo(@TypeOf(f)) != .@"fn") continue;
            list = list ++ &[_]FnDecl{.{ .name = d.name }};
        }
        return list;
    }
}

fn buildNames(comptime UserCommands: type) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (declFns(UserCommands)) |d| names = names ++ &[_][]const u8{d.name};
        return names;
    }
}

fn metas(comptime UserCommands: type) []const Meta {
    comptime {
        var list: []const Meta = &.{};
        for (declFns(UserCommands)) |d| {
            const FT = @TypeOf(@field(UserCommands, d.name));
            const ret = @typeInfo(FT).@"fn".return_type.?;
            list = list ++ &[_]Meta{.{ .name = d.name, .is_async = asyncInner(ret) != null }};
        }
        return list;
    }
}

/// Comptime signature validation. Every pub fn must take *Ctx(State) first,
/// optionally followed by exactly one args struct; the return type must be one
/// of T, Result(T), Bytes, Result(Bytes), or any of those wrapped in Async(...).
/// A bad signature is a @compileError naming the offending function.
fn validate(comptime State: type, comptime UserCommands: type) void {
    comptime {
        for (declFns(UserCommands)) |d| {
            const FT = @TypeOf(@field(UserCommands, d.name));
            const fn_info = @typeInfo(FT).@"fn";
            if (fn_info.params.len < 1 or fn_info.params.len > 2)
                @compileError("command '" ++ d.name ++ "' must take *Ctx(State) and at most one args struct");
            const P0 = fn_info.params[0].type.?;
            if (P0 != *Ctx(State))
                @compileError("command '" ++ d.name ++ "' first param must be *Ctx(State)");
            if (fn_info.params.len == 2) {
                const ArgsT = fn_info.params[1].type.?;
                if (@typeInfo(ArgsT) != .@"struct")
                    @compileError("command '" ++ d.name ++ "' second param must be a struct of JSON-decodable fields");
            }
            if (fn_info.return_type == null)
                @compileError("command '" ++ d.name ++ "' must declare a return type");
            // v0.1.0 (deviation 7): error unions are NOT supported. Handlers
            // return Result(T) for expected failures; a `!T` return is rejected
            // here so the unimplemented error-union path can never compile-fault
            // deeper in codegen. Unwrap Async first, then reject `.error_union`.
            const Ret = fn_info.return_type.?;
            const Inner = if (asyncInner(Ret)) |x| x else Ret;
            if (@typeInfo(Inner) == .error_union)
                @compileError("command '" ++ d.name ++ "' returns an error union; v0.1.0 requires Result(T) instead (deviation 7)");
            // Otherwise the return type is accepted if it is a value, Result(T),
            // Bytes, or Result(Bytes) (optionally Async-wrapped). encodeResult
            // switches on it; an unmappable value type fails JSON encode at runtime
            // as a structured `internal` reject, never a trap.
        }
    }
}

/// Run one command. Comptime-specialized to `handler`'s arg type and return
/// type. Sync handlers run inline; Async(...) handlers submit a heap thunk to
/// bridge.pool. Arg decode failure becomes a structured `bad_args` reject.
fn dispatchOne(comptime handler: anytype, bridge: anytype, state: anytype, id: u64, args_json: []const u8) void {
    const FT = @TypeOf(handler);
    const fn_info = @typeInfo(FT).@"fn";
    const Ret = fn_info.return_type.?;
    const is_async = asyncInner(Ret) != null;
    const Inner = if (is_async) asyncInner(Ret).? else Ret;

    if (is_async) {
        // Heap a job ctx the thunk frees; submit to the pool.
        const StateT = @typeInfo(@TypeOf(state)).pointer.child;
        const JobCtx = struct {
            bridge: @TypeOf(bridge),
            state: *StateT,
            id: u64,
            args_json: []u8, // arena-free copy owned by this ctx

            fn run(opaque_ctx: *anyopaque, cancel: *std.atomic.Value(bool)) void {
                const jc: *@This() = @ptrCast(@alignCast(opaque_ctx));
                // Cache bridge+id BEFORE freeing jc: releaseCall must run after
                // destroy(jc), and reading jc.bridge/jc.id post-destroy is a UAF
                // (Round-2 BLOCKER 1) that leaks the reservation in ReleaseSafe.
                const br = jc.bridge;
                const cid = jc.id;
                runHandler(handler, Inner, br, jc.state, cid, jc.args_json, cancel);
                br.alloc.free(jc.args_json);
                br.alloc.destroy(jc);
                br.releaseCall(cid);
            }
        };
        const jc = bridge.alloc.create(JobCtx) catch {
            bridge.emitErrorReject(id, "internal", "out of memory", null);
            bridge.releaseCall(id);
            return;
        };
        const args_copy = bridge.alloc.dupe(u8, args_json) catch {
            bridge.alloc.destroy(jc);
            bridge.emitErrorReject(id, "internal", "out of memory", null);
            bridge.releaseCall(id);
            return;
        };
        jc.* = .{ .bridge = bridge, .state = state, .id = id, .args_json = args_copy };
        bridge.pool.submit(.{ .id = id, .ctx = jc, .run = JobCtx.run }) catch {
            bridge.alloc.free(args_copy);
            bridge.alloc.destroy(jc);
            bridge.emitErrorReject(id, "queue_full", "server busy", null);
            bridge.releaseCall(id);
        };
        return;
    }

    // Sync: run inline on the message thread, then release the reservation.
    var dummy_cancel = std.atomic.Value(bool){ .raw = false };
    runHandler(handler, Inner, bridge, state, id, args_json, &dummy_cancel);
    bridge.releaseCall(id);
}

/// Decode args, build the Ctx, call the handler, encode the terminal result.
/// `Inner` is the handler return type after unwrapping Async. Shared by the
/// sync inline path and the async worker path.
fn runHandler(comptime handler: anytype, comptime Inner: type, bridge: anytype, state: anytype, id: u64, args_json: []const u8, cancel: *std.atomic.Value(bool)) void {
    const StateT = @typeInfo(@TypeOf(state)).pointer.child;
    var arena = std.heap.ArenaAllocator.init(bridge.alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var sink_ctx = bridge.makeSink(id); // SinkCtx BY VALUE (B1); this frame outlives the call
    var ctx = Ctx(StateT){ .arena = a, .state = state, .id = id, .cancel = cancel, .emit = &sink_ctx.sink };

    const FT = @TypeOf(handler);
    const fn_info = @typeInfo(FT).@"fn";

    // Decode args if the handler declares an args struct.
    const result: Inner = blk: {
        if (fn_info.params.len == 2) {
            const ArgsT = fn_info.params[1].type.?;
            const parsed_args = std.json.parseFromSliceLeaky(ArgsT, a, args_json, protocol.JSON_PARSE_OPTIONS) catch {
                bridge.emitErrorReject(id, "bad_args", "could not decode arguments", null);
                return;
            };
            break :blk callMaybeAsync(handler, Inner, &ctx, parsed_args);
        } else {
            break :blk callMaybeAsync(handler, Inner, &ctx, null);
        }
    };

    encodeResult(Inner, bridge, &ctx, id, result);
}

/// Call handler with or without args; unwrap Async if present. Returns Inner.
fn callMaybeAsync(comptime handler: anytype, comptime Inner: type, ctx: anytype, args: anytype) Inner {
    const Ret = @typeInfo(@TypeOf(handler)).@"fn".return_type.?;
    const raw = if (@TypeOf(args) == @TypeOf(null)) handler(ctx) else handler(ctx, args);
    if (asyncInner(Ret) != null) return raw.inner;
    return raw;
}

/// Encode the terminal result for `id`. T and Result(T) here; the Bytes branch
/// (which uses `ctx` to route through ctx.binaryChunk so the terminal bytes share
/// the per-call bin_seq space, H2) is added in Task 7. Routes every string
/// through std.json.Stringify or jsString (via protocol), so G6 holds. `ctx` is
/// the live per-call Ctx (unused until Task 7's Bytes branch).
fn encodeResult(comptime Inner: type, bridge: anytype, ctx: anytype, id: u64, result: Inner) void {
    _ = ctx; // used by Task 7's Bytes/Result(Bytes) branch
    if (comptime isResult(Inner)) {
        switch (result) {
            .ok => |v| emitOk(@TypeOf(v), bridge, id, v),
            .err => |e| bridge.emitErrorReject(id, e.code, e.message, e.payload_json),
        }
    } else {
        emitOk(Inner, bridge, id, result);
    }
}

/// True if T is Result(X) for some X (union(enum){ok,err} with our CommandError).
fn isResult(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"union") return false;
    if (info.@"union".fields.len != 2) return false;
    const f = info.@"union".fields;
    return std.mem.eql(u8, f[0].name, "ok") and std.mem.eql(u8, f[1].name, "err") and f[1].type == CommandError;
}

/// Serialize a success value to JSON and emit a _resolve via the bridge.
fn emitOk(comptime T: type, bridge: anytype, id: u64, value: T) void {
    var aw: std.Io.Writer.Allocating = .init(bridge.alloc);
    defer aw.deinit();
    std.json.Stringify.value(value, .{}, &aw.writer) catch {
        bridge.emitErrorReject(id, "internal", "could not encode result", null);
        return;
    };
    bridge.emitResolve(id, aw.writer.buffered());
}

// ─── Test fixtures ──────────────────────────────────────────────────────────

const TestState = struct { offset: i64 = 0 };

const Fixture = struct {
    pub fn add(_: *Ctx(TestState), args: struct { a: i64, b: i64 }) i64 {
        return args.a + args.b;
    }
    pub fn addState(c: *Ctx(TestState), args: struct { a: i64 }) i64 {
        return args.a + c.state.offset;
    }
    pub fn readNote(_: *Ctx(TestState), args: struct { id: u64 }) ctxmod.Result(struct { title: []const u8 }) {
        if (args.id == 0) return .{ .err = .{ .code = "not_found", .message = "no such note" } };
        return .{ .ok = .{ .title = "ok" } };
    }
    pub fn slowAdd(_: *Ctx(TestState), args: struct { a: i64, b: i64 }) Async(i64) {
        return ctxmod.done(args.a + args.b);
    }
};

/// Minimal stub bridge: records the last terminal emission. Implements exactly
/// the surface registry.dispatch duck-types.
const StubBridge = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    pool: *jobs.Pool,
    last: std.ArrayList(u8) = .empty,
    backend_label: []const u8 = "main",

    fn emitResolve(self: *StubBridge, id: u64, json: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        defer aw.deinit();
        protocol.encodeResolve(&aw.writer, id, json) catch return;
        self.last.clearRetainingCapacity();
        self.last.appendSlice(self.alloc, aw.writer.buffered()) catch {};
    }
    fn emitErrorReject(self: *StubBridge, id: u64, code: []const u8, message: []const u8, payload: ?[]const u8) void {
        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        defer aw.deinit();
        protocol.encodeErrorReject(&aw.writer, id, code, message, payload) catch return;
        self.last.clearRetainingCapacity();
        self.last.appendSlice(self.alloc, aw.writer.buffered()) catch {};
    }
    fn releaseCall(_: *StubBridge, _: u64) void {}
    /// Stub SinkCtx, mirroring the real bridge's BY-VALUE SinkCtx shape (B1):
    /// `sink` is the first field so runHandler can take `&sink_ctx.sink`.
    const StubSinkCtx = struct { sink: ctxmod.EmitSink };
    fn makeSink(self: *StubBridge, id: u64) StubSinkCtx {
        _ = id;
        return .{ .sink = .{ .label = self.backend_label, .evalJS = sinkEval, .parkBinary = sinkPark } };
    }
    fn sinkEval(_: *ctxmod.EmitSink, _: []const u8) void {}
    fn sinkPark(_: *ctxmod.EmitSink, _: u64, _: u32, _: []const u8) bool {
        return true;
    }
};

fn stubBridge(alloc: std.mem.Allocator, pool: *jobs.Pool) StubBridge {
    return .{ .alloc = alloc, .io = std.testing.io, .pool = pool };
}

const Reg = Commands(@import("platform/null.zig").NullBackend, TestState, Fixture);

test "command_names lists every pub fn" {
    try std.testing.expectEqual(@as(usize, 4), Reg.command_names.len);
    var seen_add = false;
    for (Reg.command_names) |n| if (std.mem.eql(u8, n, "add")) {
        seen_add = true;
    };
    try std.testing.expect(seen_add);
}

test "allowlist contains the registered commands and nothing else" {
    var a = Reg.allowlist();
    try std.testing.expect(a.contains("add"));
    try std.testing.expect(a.contains("slowAdd"));
    try std.testing.expect(!a.contains("rm-rf"));
}

test "isAsync reflects the Async(...) wrapper" {
    try std.testing.expect(!Reg.isAsync("add"));
    try std.testing.expect(Reg.isAsync("slowAdd"));
}

test "sync command decodes args, runs, resolves" {
    var pool = try jobs.Pool.init(std.testing.allocator, .{ .workers = 1, .max_queue = 8, .io = std.testing.io });
    defer pool.deinit();
    var st = TestState{};
    var b = stubBridge(std.testing.allocator, pool);
    defer b.last.deinit(std.testing.allocator);
    Reg.dispatch(&b, &st, "add", 1, "{\"a\":2,\"b\":3}");
    try std.testing.expect(std.mem.indexOf(u8, b.last.items, "window.Zigware._resolve(1, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, b.last.items, "5") != null);
}

test "state injection reaches the handler" {
    var pool = try jobs.Pool.init(std.testing.allocator, .{ .workers = 1, .max_queue = 8, .io = std.testing.io });
    defer pool.deinit();
    var st = TestState{ .offset = 100 };
    var b = stubBridge(std.testing.allocator, pool);
    defer b.last.deinit(std.testing.allocator);
    Reg.dispatch(&b, &st, "addState", 2, "{\"a\":5}");
    try std.testing.expect(std.mem.indexOf(u8, b.last.items, "105") != null);
}

test "Result.err produces a structured reject" {
    var pool = try jobs.Pool.init(std.testing.allocator, .{ .workers = 1, .max_queue = 8, .io = std.testing.io });
    defer pool.deinit();
    var st = TestState{};
    var b = stubBridge(std.testing.allocator, pool);
    defer b.last.deinit(std.testing.allocator);
    Reg.dispatch(&b, &st, "readNote", 3, "{\"id\":0}");
    try std.testing.expect(std.mem.indexOf(u8, b.last.items, "\"code\":\"not_found\"") != null);
}

test "malformed args become a bad_args reject" {
    var pool = try jobs.Pool.init(std.testing.allocator, .{ .workers = 1, .max_queue = 8, .io = std.testing.io });
    defer pool.deinit();
    var st = TestState{};
    var b = stubBridge(std.testing.allocator, pool);
    defer b.last.deinit(std.testing.allocator);
    Reg.dispatch(&b, &st, "add", 4, "{\"a\":\"not a number\"}");
    try std.testing.expect(std.mem.indexOf(u8, b.last.items, "\"code\":\"bad_args\"") != null);
}

// Async path: dispatch submits to the real pool; drain then check the stub.
// The stub's emit runs on the worker thread; guard `last` with the pool's
// single-worker serialization (workers=1) so the test reads it after waitIdle.
test "async command runs on the pool and resolves" {
    var pool = try jobs.Pool.init(std.testing.allocator, .{ .workers = 1, .max_queue = 8, .io = std.testing.io });
    defer pool.deinit();
    var st = TestState{};
    var b = stubBridge(std.testing.allocator, pool);
    defer b.last.deinit(std.testing.allocator);
    Reg.dispatch(&b, &st, "slowAdd", 5, "{\"a\":4,\"b\":6}");
    pool.waitIdle();
    try std.testing.expect(std.mem.indexOf(u8, b.last.items, "window.Zigware._resolve(5, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, b.last.items, "10") != null);
}

test "bad command signatures are rejected at comptime (verified out-of-band)" {
    // A live @compileError cannot sit in a passing test body. To confirm the
    // registry rejects malformed handlers, uncomment ONE of these locally and
    // run `zig build test`; each must fail to compile with the named message.
    //
    //   const BadFirstParam = struct {
    //       pub fn x(_: i64) i64 { return 0; }          // first param not *Ctx(State)
    //   };
    //   _ = Commands(@import("platform/null.zig").NullBackend, TestState, BadFirstParam);
    //
    //   const TwoArgs = struct {
    //       pub fn x(_: *Ctx(TestState), _: struct{a: i64}, _: struct{b: i64}) i64 { return 0; }
    //   };
    //   _ = Commands(@import("platform/null.zig").NullBackend, TestState, TwoArgs);   // more than one args struct
    //
    //   const NonStructArgs = struct {
    //       pub fn x(_: *Ctx(TestState), _: i64) i64 { return 0; }  // args not a struct
    //   };
    //   _ = Commands(@import("platform/null.zig").NullBackend, TestState, NonStructArgs);
    try std.testing.expect(true);
}
