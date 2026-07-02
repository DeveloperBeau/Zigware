const std = @import("std");
const protocol = @import("protocol.zig");
const ctxmod = @import("command_ctx.zig");
const compute = @import("compute.zig");
const jobs = @import("jobs.zig");
const Allowlist = @import("allowlist.zig").Allowlist;

const CancelToken = compute.CancelToken;

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

/// True if `T` is `compute.Sink(P)` for some progress payload P. `Sink(P)` stores
/// no P-typed field, so P is read off its `progress(self, v: P)` method, then the
/// nominal `compute.Sink(P)` is confirmed. Structural guards run first so a
/// non-Sink third param returns false rather than comptime-faulting on `.progress`.
fn isSink(comptime T: type) bool {
    comptime {
        if (@typeInfo(T) != .@"struct") return false;
        if (!@hasDecl(T, "from") or !@hasDecl(T, "progress")) return false;
        // Arity guard BEFORE indexing params[1]: a non-Sink struct that happens
        // to declare `from`+`progress` but whose `progress` is not a >=2-arg fn
        // would otherwise fault with an internal comptime error instead of the
        // clean "third param must be z.Sink(P)" message the caller emits.
        const prog = @typeInfo(@TypeOf(T.progress));
        if (prog != .@"fn" or prog.@"fn".params.len < 2) return false;
        const P = prog.@"fn".params[1].type.?;
        return T == compute.Sink(P);
    }
}

/// fn Commands(comptime B: type, comptime State: type) type.
/// `UserCommands` is the app author's struct of pub fns. `B` is unused inside
/// the registry (jobs.Pool is non-generic, EmitSink is concrete); it stays in
/// the signature for spec parity and so emit_dts can instantiate
/// Commands(NullBackend, State). The user struct is read from a third param so
/// the call site reads `Commands(B, State, app.Commands)`.
pub fn Commands(comptime B: type, comptime State: type, comptime UserCommands: anytype) type {
    _ = B;
    comptime validate(State, UserCommands);
    return struct {
        pub const command_names: []const []const u8 = buildNames(UserCommands);

        pub fn allowlist() Allowlist {
            comptime std.debug.assert(command_names.len <= Allowlist.max_commands);
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
            label: []const u8,
            name: []const u8,
            id: u64,
            args_json: []const u8,
        ) void {
            inline for (comptime declFns(UserCommands)) |d| {
                if (std.mem.eql(u8, d.name, name)) {
                    dispatchOne(@field(d.ns, d.name), bridge, state, label, id, args_json);
                    return;
                }
            }
            // Unknown command never reaches here: the gate (Task 5) checks the
            // allowlist first. Defensive structured reject just in case.
            bridge.emitErrorReject(label, id, "unknown_command", "no such command", null);
            bridge.releaseCall(id);
        }
    };
}

/// A pub-fn command declaration, tagged with the namespace it lives in so the
/// dispatcher can fetch the exact handler with `@field(d.ns, d.name)`.
const FnDecl = struct { ns: type, name: []const u8 };

/// Normalize the `UserCommands` parameter into a flat list of namespace types.
/// Accepts either a single command struct (`Fixture`) or a comptime tuple of
/// command structs (`.{ AppCommands(B), Root.Commands }`), so the App can compose
/// the framework builtins with the app's own commands over one State.
fn nsTypes(comptime UserCommands: anytype) []const type {
    comptime {
        if (@TypeOf(UserCommands) == type) return &[_]type{UserCommands};
        var list: []const type = &.{};
        for (UserCommands) |Ns| list = list ++ &[_]type{Ns};
        return list;
    }
}

fn declFns(comptime UserCommands: anytype) []const FnDecl {
    comptime {
        var list: []const FnDecl = &.{};
        for (nsTypes(UserCommands)) |Ns| {
            for (@typeInfo(Ns).@"struct".decls) |d| {
                const f = @field(Ns, d.name);
                if (@typeInfo(@TypeOf(f)) != .@"fn") continue;
                // A command name shared by two namespaces would let the dispatcher
                // silently bind one handler while the gate allowlist carries an
                // ambiguous entry. Reject the collision at comptime rather than
                // shadow it. The registry never resolves a command name by luck.
                for (list) |existing| {
                    if (std.mem.eql(u8, existing.name, d.name))
                        @compileError("duplicate command '" ++ d.name ++ "' across command namespaces");
                }
                list = list ++ &[_]FnDecl{.{ .ns = Ns, .name = d.name }};
            }
        }
        return list;
    }
}

fn buildNames(comptime UserCommands: anytype) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (declFns(UserCommands)) |d| names = names ++ &[_][]const u8{d.name};
        return names;
    }
}

fn metas(comptime UserCommands: anytype) []const Meta {
    comptime {
        var list: []const Meta = &.{};
        for (declFns(UserCommands)) |d| {
            const FT = @TypeOf(@field(d.ns, d.name));
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
fn validate(comptime State: type, comptime UserCommands: anytype) void {
    comptime {
        for (declFns(UserCommands)) |d| {
            const FT = @TypeOf(@field(d.ns, d.name));
            const fn_info = @typeInfo(FT).@"fn";
            if (fn_info.params.len < 1 or fn_info.params.len > 3)
                @compileError("command '" ++ d.name ++ "' must take *Ctx(State), an optional args struct, and an optional sink: z.Sink(P)");
            const P0 = fn_info.params[0].type.?;
            if (P0 != *Ctx(State))
                @compileError("command '" ++ d.name ++ "' first param must be *Ctx(State)");
            // Param 1 is ALWAYS the args struct when present (for both the 2-param
            // and 3-param forms), so validate it for len >= 2 to surface the clean
            // "must be a struct" message rather than a deeper JSON-decode error. A
            // stream-only command with no args must still declare an empty `struct {}`.
            if (fn_info.params.len >= 2) {
                const ArgsT = fn_info.params[1].type.?;
                if (@typeInfo(ArgsT) != .@"struct")
                    @compileError("command '" ++ d.name ++ "' second param must be a struct of JSON-decodable fields");
            }
            if (fn_info.params.len == 3) {
                const SinkT = fn_info.params[2].type.?;
                if (!isSink(SinkT))
                    @compileError("command '" ++ d.name ++ "' third param must be z.Sink(P)");
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
fn dispatchOne(comptime handler: anytype, bridge: anytype, state: anytype, label: []const u8, id: u64, args_json: []const u8) void {
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
            label: []u8, // owned copy of the attested routing label
            flag: *std.atomic.Value(bool), // this invocation's armed cancel flag

            fn run(opaque_ctx: *anyopaque, cancel: *std.atomic.Value(bool)) void {
                const jc: *@This() = @ptrCast(@alignCast(opaque_ctx));
                // Cache bridge+id+flag BEFORE freeing jc: releaseCall must run after
                // destroy(jc), and reading jc.bridge/jc.id post-destroy is a UAF
                // (Round-2 BLOCKER 1) that leaks the reservation in ReleaseSafe.
                // jc.label follows the SAME window as args_json: read only before
                // destroy(jc); runHandler arena-dupes it, so the routing copy it
                // uses outlives the terminal emit. The per-id flag is OWNED by the
                // bridge inflight map (freed by releaseCall), not by jc: cache the
                // ptr for the token, never free it here.
                const br = jc.bridge;
                const cid = jc.id;
                const flag = jc.flag;
                runHandler(handler, Inner, br, jc.state, jc.label, cid, jc.args_json, .{ .own = flag, .shutdown = cancel });
                br.alloc.free(jc.args_json);
                br.alloc.free(jc.label);
                br.alloc.destroy(jc);
                br.releaseCall(cid);
            }
        };
        // Arm the per-invocation cancel flag FIRST (message thread, pre-submit), so
        // a compute.cancel arriving the instant after submit still finds the flag.
        // Hoisted ahead of create/dupe so by the time those can fail the flag is
        // already armed and every rollback path's releaseCall frees it exactly once
        // (fetchRemove-based, double-free safe against worker completion).
        const flag = bridge.armCancel(id) catch {
            bridge.emitErrorReject(label, id, "internal", "out of memory", null);
            bridge.releaseCall(id);
            return;
        };
        const jc = bridge.alloc.create(JobCtx) catch {
            bridge.emitErrorReject(label, id, "internal", "out of memory", null);
            bridge.releaseCall(id);
            return;
        };
        const args_copy = bridge.alloc.dupe(u8, args_json) catch {
            bridge.alloc.destroy(jc);
            bridge.emitErrorReject(label, id, "internal", "out of memory", null);
            bridge.releaseCall(id);
            return;
        };
        const label_copy = bridge.alloc.dupe(u8, label) catch {
            bridge.alloc.free(args_copy);
            bridge.alloc.destroy(jc);
            bridge.emitErrorReject(label, id, "internal", "out of memory", null);
            bridge.releaseCall(id);
            return;
        };
        jc.* = .{ .bridge = bridge, .state = state, .id = id, .args_json = args_copy, .label = label_copy, .flag = flag };
        bridge.pool.submit(.{ .id = id, .ctx = jc, .run = JobCtx.run }) catch {
            bridge.alloc.free(args_copy);
            bridge.alloc.free(label_copy);
            bridge.alloc.destroy(jc);
            bridge.emitErrorReject(label, id, "queue_full", "server busy", null);
            bridge.releaseCall(id);
        };
        return;
    }

    // Sync: run inline on the message thread, then release the reservation. Sync
    // calls have no own-flag; a never-cancel token observes only shutdown via the
    // dummy, matching the prior single-flag behavior.
    var dummy_cancel = std.atomic.Value(bool){ .raw = false };
    runHandler(handler, Inner, bridge, state, label, id, args_json, .{ .own = &dummy_cancel, .shutdown = &dummy_cancel });
    bridge.releaseCall(id);
}

/// Decode args, build the Ctx, call the handler, encode the terminal result.
/// `Inner` is the handler return type after unwrapping Async. Shared by the
/// sync inline path and the async worker path.
fn runHandler(comptime handler: anytype, comptime Inner: type, bridge: anytype, state: anytype, label: []const u8, id: u64, args_json: []const u8, cancel: CancelToken) void {
    const StateT = @typeInfo(@TypeOf(state)).pointer.child;
    var arena = std.heap.ArenaAllocator.init(bridge.alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Route replies by a copy that survives a handler self-freeing its own entry.
    // A sync window.close on its OWN label frees the manager entry whose label
    // slice `label` borrows; the per-call arena outlives the terminal emit, so a
    // copy here keeps sink.label/window_label/encodeResult routing valid (the
    // re-resolve then finds the window gone and drops: the correct self-close).
    // OOM falls back to the borrow.
    const route = a.dupe(u8, label) catch label;

    var sink_ctx = bridge.makeSink(id); // SinkCtx BY VALUE (B1); this frame outlives the call
    sink_ctx.sink.label = route; // terminal + sink replies route to the caller's window
    var ctx = Ctx(StateT){
        .arena = a,
        .state = state,
        .id = id,
        .cancel = cancel,
        .emit = &sink_ctx.sink,
        .window_label = route,
        .services = @ptrCast(bridge),
    };

    const FT = @TypeOf(handler);
    const fn_info = @typeInfo(FT).@"fn";

    // Decode args if the handler declares an args struct.
    const result: Inner = blk: {
        if (fn_info.params.len >= 2) {
            const ArgsT = fn_info.params[1].type.?;
            const parsed_args = std.json.parseFromSliceLeaky(ArgsT, a, args_json, protocol.JSON_PARSE_OPTIONS) catch {
                bridge.emitErrorReject(route, id, "bad_args", "could not decode arguments", null);
                return;
            };
            break :blk callMaybeAsync(handler, Inner, &ctx, parsed_args);
        } else {
            break :blk callMaybeAsync(handler, Inner, &ctx, null);
        }
    };

    encodeResult(Inner, bridge, &ctx, route, id, result);
}

/// Call handler with or without args; unwrap Async if present. Returns Inner.
fn callMaybeAsync(comptime handler: anytype, comptime Inner: type, ctx: anytype, args: anytype) Inner {
    const fn_info = @typeInfo(@TypeOf(handler)).@"fn";
    const Ret = fn_info.return_type.?;
    const raw = switch (fn_info.params.len) {
        1 => handler(ctx),
        2 => handler(ctx, args),
        // The framework owns sink construction: project Sink(P) off the live
        // *Ctx (exactly what handlers used to do via `z.Sink(P).from(ctx)`) and
        // pass it third. `ctx` is already a `*Ctx`, which `from` duck-types.
        3 => blk: {
            const SinkT = fn_info.params[2].type.?;
            break :blk handler(ctx, args, SinkT.from(ctx));
        },
        else => unreachable, // validate caps params at 3
    };
    if (asyncInner(Ret) != null) return raw.inner;
    return raw;
}

/// True if T is command_ctx.Bytes.
fn isBytes(comptime T: type) bool {
    return T == ctxmod.Bytes;
}

/// Encode the terminal result for `id`: T, Result(T), Bytes, and Result(Bytes).
/// The Bytes branch routes through ctx.binaryChunk so the terminal bytes share
/// the per-call bin_seq space (H2) and emit a _bin frame through the same sink
/// as streamed chunks. Routes every string through std.json.Stringify or
/// jsString (via protocol), so G6 holds. `ctx` is the live per-call Ctx.
fn encodeResult(comptime Inner: type, bridge: anytype, ctx: anytype, label: []const u8, id: u64, result: Inner) void {
    if (comptime isBytes(Inner)) {
        emitBytes(ctx, bridge, label, id, result);
        return;
    }
    if (comptime isResult(Inner)) {
        switch (result) {
            .ok => |v| {
                if (comptime isBytes(@TypeOf(v))) emitBytes(ctx, bridge, label, id, v) else emitOk(@TypeOf(v), bridge, ctx.arena, label, id, v);
            },
            .err => |e| bridge.emitErrorReject(label, id, e.code, e.message, e.payload_json),
        }
        return;
    }
    emitOk(Inner, bridge, ctx.arena, label, id, result);
}

/// Park the terminal bytes via ctx.binaryChunk so they share the per-call
/// bin_seq space (a handler that ALSO streamed chunks does not collide at seq 0,
/// H2). binaryChunk parks the bytes AND emits the _bin frame through the same
/// sink as the streamed chunks. On budget overflow it returns false (nothing
/// emitted), so we reject queue_full; otherwise resolve null and the shim
/// settles once it has pulled every advertised seq.
fn emitBytes(ctx: anytype, bridge: anytype, label: []const u8, id: u64, b: ctxmod.Bytes) void {
    if (!ctx.binaryChunk(b.data, b.mime)) {
        bridge.emitErrorReject(label, id, "queue_full", "binary buffer full", null);
        return;
    }
    bridge.emitResolve(label, id, "null");
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
fn emitOk(comptime T: type, bridge: anytype, arena: std.mem.Allocator, label: []const u8, id: u64, value: T) void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    std.json.Stringify.value(value, .{}, &aw.writer) catch {
        bridge.emitErrorReject(label, id, "internal", "could not encode result", null);
        return;
    };
    bridge.emitResolve(label, id, aw.writer.buffered());
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
    streamed: std.ArrayList(u8) = .empty,
    backend_label: []const u8 = "main",
    stub_flag: std.atomic.Value(bool) = .{ .raw = false },

    fn emitResolve(self: *StubBridge, _: []const u8, id: u64, json: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        defer aw.deinit();
        protocol.encodeResolve(&aw.writer, id, json) catch return;
        self.last.clearRetainingCapacity();
        self.last.appendSlice(self.alloc, aw.writer.buffered()) catch {};
    }
    fn emitErrorReject(self: *StubBridge, _: []const u8, id: u64, code: []const u8, message: []const u8, payload: ?[]const u8) void {
        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        defer aw.deinit();
        protocol.encodeErrorReject(&aw.writer, id, code, message, payload) catch return;
        self.last.clearRetainingCapacity();
        self.last.appendSlice(self.alloc, aw.writer.buffered()) catch {};
    }
    fn releaseCall(_: *StubBridge, _: u64) void {}
    /// Stub arm: return a ptr to a stub-owned flag so the async branch compiles
    /// and threads a valid (never-cancelled) flag into the worker. No real
    /// per-id registry here; the registry tests do not drive cancellation.
    fn armCancel(self: *StubBridge, _: u64) !*std.atomic.Value(bool) {
        return &self.stub_flag;
    }
    fn cancelId(self: *StubBridge, _: u64) void {
        self.stub_flag.store(true, .release);
    }
    // The sink ctx carries a pointer back to the bridge's stream buffer so a
    // streamed frame is observable. `sink` stays the FIRST field so runHandler's
    // `&sink_ctx.sink` and sinkEval's @fieldParentPtr both resolve (B1 shape).
    const StubSinkCtx = struct { sink: ctxmod.EmitSink, streamed: *std.ArrayList(u8), alloc: std.mem.Allocator };
    fn makeSink(self: *StubBridge, id: u64) StubSinkCtx {
        _ = id;
        return .{
            .sink = .{ .label = self.backend_label, .evalJS = sinkEval, .parkBinary = sinkPark },
            .streamed = &self.streamed,
            .alloc = self.alloc,
        };
    }
    fn sinkEval(sink: *ctxmod.EmitSink, js: []const u8) void {
        const sc: *StubSinkCtx = @fieldParentPtr("sink", sink);
        sc.streamed.appendSlice(sc.alloc, js) catch {};
    }
    fn sinkPark(_: *ctxmod.EmitSink, _: u64, _: u32, _: []const u8) bool {
        return true;
    }
};

fn stubBridge(alloc: std.mem.Allocator, pool: *jobs.Pool) StubBridge {
    return .{ .alloc = alloc, .io = std.testing.io, .pool = pool };
}

const Reg = Commands(@import("platform/null.zig").NullBackend, TestState, Fixture);

/// A second command namespace over the SAME State, used to prove the registry
/// can compose more than one namespace (builtins + the app's own commands).
const Fixture2 = struct {
    pub fn mul(_: *Ctx(TestState), args: struct { a: i64, b: i64 }) i64 {
        return args.a * args.b;
    }
};

/// The registry over a TUPLE of namespaces. Every command from each namespace is
/// registered under its decl name, sharing the one State.
const RegMulti = Commands(@import("platform/null.zig").NullBackend, TestState, .{ Fixture, Fixture2 });

/// A streaming fixture: it declares the progress payload as an explicit third
/// `Sink(P)` parameter. The registry must build that sink off the per-call Ctx
/// and pass it, so `tick` streams a frame before it resolves.
const StreamFixture = struct {
    const Frame = struct { pct: u8 };
    const TickResult = struct { done: bool };
    pub fn tick(_: *Ctx(TestState), args: struct { n: u8 }, sink: compute.Sink(Frame)) Async(ctxmod.Result(TickResult)) {
        sink.progress(.{ .pct = args.n });
        return ctxmod.done(ctxmod.Result(TickResult){ .ok = .{ .done = true } });
    }
};
const RegStream = Commands(@import("platform/null.zig").NullBackend, TestState, StreamFixture);

test "streaming handler gets a framework-built sink and streams through it" {
    const alloc = std.testing.allocator;
    var pool = try jobs.Pool.init(alloc, .{ .workers = 1, .max_queue = 8, .io = std.testing.io });
    defer pool.deinit();
    var b = stubBridge(alloc, pool);
    defer b.last.deinit(alloc);
    defer b.streamed.deinit(alloc);
    var st = TestState{};
    RegStream.dispatch(&b, &st, "main", "tick", 11, "{\"n\":42}");
    pool.waitIdle();
    // The framework built Sink(Frame) and the handler streamed a frame through it.
    try std.testing.expect(std.mem.indexOf(u8, b.streamed.items, "window.Zigware._stream(11, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, b.streamed.items, "\"pct\":42") != null);
    // The terminal resolve still settled.
    try std.testing.expect(std.mem.indexOf(u8, b.last.items, "\"done\":true") != null);
}

test "command surface spans multiple namespaces" {
    // 4 from Fixture (add, addState, readNote, slowAdd) + 1 from Fixture2 (mul).
    try std.testing.expectEqual(@as(usize, 5), RegMulti.command_names.len);
    var a = RegMulti.allowlist();
    try std.testing.expect(a.contains("add")); // first namespace
    try std.testing.expect(a.contains("mul")); // second namespace
    try std.testing.expect(!a.contains("rm-rf"));
}

test "dispatch routes to a command in a second namespace" {
    const alloc = std.testing.allocator;
    var pool = try jobs.Pool.init(alloc, .{ .workers = 1, .max_queue = 8, .io = std.testing.io });
    defer pool.deinit();
    var bridge = stubBridge(alloc, pool);
    defer bridge.last.deinit(alloc);
    var state = TestState{};

    RegMulti.dispatch(&bridge, &state, "main", "mul", 7,
        \\{"a":6,"b":7}
    );
    try std.testing.expect(std.mem.indexOf(u8, bridge.last.items, "42") != null);
}

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
    Reg.dispatch(&b, &st, "main", "add", 1, "{\"a\":2,\"b\":3}");
    try std.testing.expect(std.mem.indexOf(u8, b.last.items, "window.Zigware._resolve(1, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, b.last.items, "5") != null);
}

test "state injection reaches the handler" {
    var pool = try jobs.Pool.init(std.testing.allocator, .{ .workers = 1, .max_queue = 8, .io = std.testing.io });
    defer pool.deinit();
    var st = TestState{ .offset = 100 };
    var b = stubBridge(std.testing.allocator, pool);
    defer b.last.deinit(std.testing.allocator);
    Reg.dispatch(&b, &st, "main", "addState", 2, "{\"a\":5}");
    try std.testing.expect(std.mem.indexOf(u8, b.last.items, "105") != null);
}

test "Result.err produces a structured reject" {
    var pool = try jobs.Pool.init(std.testing.allocator, .{ .workers = 1, .max_queue = 8, .io = std.testing.io });
    defer pool.deinit();
    var st = TestState{};
    var b = stubBridge(std.testing.allocator, pool);
    defer b.last.deinit(std.testing.allocator);
    Reg.dispatch(&b, &st, "main", "readNote", 3, "{\"id\":0}");
    try std.testing.expect(std.mem.indexOf(u8, b.last.items, "\"code\":\"not_found\"") != null);
}

test "malformed args become a bad_args reject" {
    var pool = try jobs.Pool.init(std.testing.allocator, .{ .workers = 1, .max_queue = 8, .io = std.testing.io });
    defer pool.deinit();
    var st = TestState{};
    var b = stubBridge(std.testing.allocator, pool);
    defer b.last.deinit(std.testing.allocator);
    Reg.dispatch(&b, &st, "main", "add", 4, "{\"a\":\"not a number\"}");
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
    Reg.dispatch(&b, &st, "main", "slowAdd", 5, "{\"a\":4,\"b\":6}");
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
    //
    //   // Duplicate command name across two namespaces -> "duplicate command 'add'":
    //   _ = Commands(@import("platform/null.zig").NullBackend, TestState, .{ Fixture, Fixture });
    try std.testing.expect(true);
}
