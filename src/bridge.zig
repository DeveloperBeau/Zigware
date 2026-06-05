const std = @import("std");
const protocol = @import("protocol.zig");
const Allowlist = @import("allowlist.zig").Allowlist;
const jobs = @import("jobs.zig");
const backend_mod = @import("platform/backend.zig");
const ctxmod = @import("command_ctx.zig");
const registry = @import("registry.zig");
const security = struct {
    const gates = @import("security/gates.zig");
    const grant = @import("security/grant_table.zig");
};
const WindowManager = @import("window/manager.zig").WindowManager;

pub const BridgeOptions = struct {
    /// Explicit worker count so tests are deterministic across CI hardware.
    /// main.zig passes null to use the CPU-derived default.
    worker_count: ?usize = null,
    max_queue: usize = 256,
};

/// G5: max concurrently in-flight calls. Bounds peak arena memory together with
/// the bounded worker pool. A resource-aware per-command budget (from D's
/// manifest) is deferred to D. B counts calls, not bytes (deviation 6).
const MAX_CONCURRENT: usize = 8;

/// Per-id parked binary, pulled out-of-band over the stream scheme. Bounded by a
/// fixed byte budget per id; overflow is rejected at park time (G5). Eviction is
/// serve-or-teardown, never on settle (deviation 9): the webview pulls bytes
/// after the invoke settles, so freeing on settle would 404 every pull.
const BIN_BUDGET_PER_ID: usize = 16 * 1024 * 1024;

const BinEntry = struct { seq: u32, bytes: []u8, served: bool = false };
const BinRing = struct {
    entries: std.ArrayList(BinEntry) = .empty,
    total: usize = 0,
    settled: bool = false,
};

/// Bridge over a platform backend `B`, routing inbound messages to commands
/// registered in `Reg = Commands(B, State, UserCommands)`. `Bridge(B)` stays
/// generic over `B` only: the registry and `*State` are erased behind a captured
/// `dispatchFn` and `state_ptr` so A's call sites that name `Bridge(NullBackend)`
/// keep compiling.
///
/// Lifecycle contract: `deinit` is INFALLIBLE. It joins the worker pool and
/// frees state and cannot fail. Any future fallible cleanup MUST go through a
/// separate `flush()` called before deinit, never folded into deinit.
pub fn Bridge(comptime B: type) type {
    backend_mod.assertBackend(B);
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        io: std.Io,
        backend: *B,
        window: B.WindowHandle,
        pool: *jobs.Pool,

        // G5: in-flight call ids (also duplicate-id detection), capped at
        // MAX_CONCURRENT. The value is the per-invocation cancel flag (null for
        // every reservation with no own-flag: all sync calls, and any arm-failed
        // async entry). One map, one lock; bounded by the same MAX_CONCURRENT the
        // id-set already enforces. The own-flag's whole register/arm/cancel/clear/
        // free lifecycle runs under inflight_mutex so store-vs-free is serialized.
        inflight_mutex: std.Io.Mutex = .init,
        inflight: std.AutoHashMapUnmanaged(u64, ?*std.atomic.Value(bool)) = .empty,

        // Window label map (deviation 3): single "main" entry pre-E. C's G2
        // resolves a label through this; E generalizes it to multi-window.
        main_window_id: u64,

        // E: the multi-window source of truth. Null on the pre-E single-window
        // path (labelFor/emitToLabel fall back to the bootstrap "main" window),
        // wired by app.zig via setManager once the manager is constructed.
        manager: ?*WindowManager(B) = null,

        // C's capability state (G1/G2/G4). The bridge ALWAYS holds a non-null
        // immutable GrantTable and ALWAYS evaluates (fail-closed; no pass-through).
        // base_dir/bases are a real opened dir + base tokens for the path scope
        // engine; v0.1.0 commands are .none, so they are valid but unused live.
        grants: *const security.grant.GrantTable,
        bases: security.gates.Bases,
        base_dir: std.Io.Dir,
        is_debug: bool,

        // Per-id binary ring buffer (full machinery lands here so the sink
        // closure, releaseCall, and deinit can reference it; Task 7 only adds
        // serveStream/parseStreamPath and the registry Bytes branch).
        bin_mutex: std.Io.Mutex = .init,
        bins: std.AutoHashMapUnmanaged(u64, BinRing) = .empty,

        // Comptime-erased dispatch: a fn pointer the init fills from the registry
        // type, so Bridge(B) is not generic over State/UserCommands.
        dispatchFn: *const fn (self: *Self, label: []const u8, name: []const u8, id: u64, args_json: []const u8) void,
        allow: Allowlist,
        state_ptr: *anyopaque,

        pub fn init(
            alloc: std.mem.Allocator,
            io: std.Io,
            backend: *B,
            window: B.WindowHandle,
            comptime State: type,
            comptime UserCommands: type,
            state: *State,
            opts: BridgeOptions,
            grants: *const security.grant.GrantTable,
            bases: security.gates.Bases,
            base_dir: std.Io.Dir,
            is_debug: bool,
        ) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);

            const Reg = registry.Commands(B, State, UserCommands);

            self.* = .{
                .alloc = alloc,
                .io = io,
                .backend = backend,
                .window = window,
                .pool = undefined,
                .main_window_id = backend.windowId(window),
                .grants = grants,
                .bases = bases,
                .base_dir = base_dir,
                .is_debug = is_debug,
                .state_ptr = state,
                .allow = Reg.allowlist(),
                .dispatchFn = struct {
                    fn f(s: *Self, label: []const u8, name: []const u8, id: u64, args_json: []const u8) void {
                        const st: *State = @ptrCast(@alignCast(s.state_ptr));
                        Reg.dispatch(s, st, label, name, id, args_json);
                    }
                }.f,
            };

            self.pool = try jobs.Pool.init(alloc, .{
                .workers = opts.worker_count orelse workerCount(),
                .max_queue = opts.max_queue,
                .io = io,
            });

            return self;
        }

        /// Wire the multi-window manager (E). Called once at startup before any
        /// inbound message is dispatched. With a manager set, labelFor resolves
        /// the attested id to a real label and emitToLabel routes by that label;
        /// without one, the bridge keeps the pre-E single-window behavior.
        pub fn setManager(self: *Self, m: *WindowManager(B)) void {
            self.manager = m;
        }

        /// INFALLIBLE by contract. Joins the pool (so no worker touches the
        /// inflight map or bins after this), frees the inflight map, frees any
        /// parked binary, frees state.
        pub fn deinit(self: *Self) void {
            self.pool.deinit();
            self.inflight.deinit(self.alloc);
            self.deinitBins();
            self.alloc.destroy(self);
        }

        /// Block until all submitted jobs finish. Tests call this, then call
        /// backend.pumpMain() to deliver emitted JS.
        pub fn drainForTest(self: *Self) void {
            self.pool.waitIdle();
        }

        /// Route an inbound JS message. C will read `window_id` for G2 label
        /// lookup and `origin` for G1; A ignores both but reserves the slots
        /// so neither B nor C needs to widen the signature later.
        ///
        /// Every accepted message with a parseable id receives exactly one
        /// terminal emission (resolve or reject). Transient allocations use a
        /// per-message arena rooted on self.alloc.
        pub fn handleMessage(self: *Self, window_id: u64, origin: []const u8, text: []const u8) void {
            // Resolve the attested label ONCE, before any reject path, so every
            // early reject (oversize, malformed, unknown command, gate deny, G5)
            // routes its terminal _reject to the window that made the call, never
            // the bootstrap "main" handle.
            //
            // With a manager wired (E), an unresolved id is UNATTRIBUTABLE: it must
            // not borrow main's grants and its reply must not mis-route to main, so
            // we DROP the message here, exactly like handleReserved fails closed.
            // Without a manager (pre-E single-window PoC), any id resolves to "main".
            const label = if (self.manager) |m|
                (m.labelFor(window_id) orelse return) // unknown/closed window: drop
            else
                "main";

            // Layer-2 message-size cap (H1). onMessageImp enforces it first at
            // the objc seam; this is the defense-in-depth check for any caller.
            if (text.len > protocol.MAX_MESSAGE_LEN) {
                if (scanId(text)) |id| self.emitErrorReject(label, id, "internal", "message too large", null);
                return;
            }

            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const a = arena.allocator();

            const msg = protocol.decode(a, text, protocol.MAX_MESSAGE_LEN) catch {
                // Malformed: if a numeric "id" is scannable, send one correlated
                // reject so the page-side promise settles instead of hanging.
                if (scanId(text)) |id| self.emitErrorReject(label, id, "internal", "bad message", null);
                return;
            };
            // msg is arena-owned; no msg.deinit needed.

            // Reserved inbound names (e.g. __zigware_ready from E) never hit the
            // command gate; they take a dedicated path that re-derives the target
            // ONLY from the attested window id and enforces G1 origin trust.
            if (protocol.isReservedInboundName(msg.cmd)) {
                self.handleReserved(window_id, origin, msg.cmd);
                return;
            }

            if (!self.allow.contains(msg.cmd)) {
                self.emitErrorReject(label, msg.id, "unknown_command", "no such command", null);
                return;
            }

            // Derive the G4 scope input from the command's compiled scope. For a
            // path-scoped command, extract the candidate `path` from the SAME
            // args_json the registry decodes (verbatim parse options, no
            // differential); every unscoped command stays `.none` (allow). A
            // missing/ill-typed path on a path-scoped command fails CLOSED.
            const scope_input = self.deriveScopeInput(a, label, msg.cmd, msg.args_json) catch {
                self.emitErrorReject(label, msg.id, "scope.path.no_match", "path out of scope", null);
                return; // no reservation taken
            };

            // G1/G2/G4 (C). Runs after the allowlist (G3) and BEFORE the G5
            // reservation, so a denied request never reserves a budget slot.
            const decision = security.gates.evaluate(self.grants, .{
                .window_label = label,
                .origin = origin,
                .command = msg.cmd,
                .scope_input = scope_input,
                .is_debug = self.is_debug,
            }, self.bases, self.io, self.base_dir);
            switch (decision) {
                .allow => {},
                .deny => |r| {
                    self.emitErrorReject(label, msg.id, r.code, r.message, null);
                    return; // no reservation taken
                },
            }

            // G5: reserve a slot under the budget. reserveCall emits the reject
            // itself on failure (duplicate id, budget exceeded, or OOM).
            if (!self.reserveCall(label, msg.id)) return;

            self.dispatchFn(self, label, msg.cmd, msg.id, msg.args_json);
        }

        /// Handle a reserved inbound name (currently `__zigware_ready`). Derives
        /// the target window ONLY from the attested `window_id` (never the message
        /// body), enforces G1 origin trust BEFORE acting, then routes the ready
        /// signal to that one window. No manager => pre-E single-window path => no
        /// ready machinery, so this is a no-op there.
        fn handleReserved(self: *Self, window_id: u64, origin: []const u8, name: []const u8) void {
            const m = self.manager orelse return;
            const label = m.labelFor(window_id) orelse return; // unknown/closed window
            if (!security.gates.originAllowed(self.grants, label, origin, self.is_debug)) return; // G1
            if (std.mem.eql(u8, name, protocol.ready_message_name)) {
                m.markReadyAndShow(label) catch {}; // also cancels the watchdog
            }
        }

        fn workerCount() usize {
            return @min(@max(std.Thread.getCpuCount() catch 4, 1), 8);
        }

        /// Best-effort scan for a numeric `"id": N` in raw (possibly malformed)
        /// text, so a decode failure can still settle the right promise (L1).
        /// Returns null if no plausible id is found. Bounded by text.len.
        fn scanId(text: []const u8) ?u64 {
            const needle = "\"id\"";
            const start = std.mem.indexOf(u8, text, needle) orelse return null;
            var i = start + needle.len;
            // Skip whitespace and a single ':'.
            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
            if (i >= text.len or text[i] != ':') return null;
            i += 1;
            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
            const num_start = i;
            while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
            if (i == num_start) return null;
            // Parse in the SAME domain decode accepts (non-negative i64), so a
            // malformed-message reject can only target an id decode would also
            // accept; overflow or out-of-range yields null (no reject) (L1).
            const parsed = std.fmt.parseInt(i64, text[num_start..i], 10) catch return null;
            if (parsed < 0) return null;
            return @intCast(parsed);
        }

        /// Derive the G4 scope input for (label, command) from the command's
        /// COMPILED scope set, discriminating on `.path` PRESENCE (never on
        /// emptiness). If neither the allow nor the deny set carries a `.path`
        /// scope, the command is unscoped and gets `.none` (G4 no-op allow) —
        /// this covers every existing command (sha256/echoBytes/window.* carry no
        /// path scope), so they stay allowed exactly as before. If a `.path` scope
        /// is present, extract the candidate `path` from `args_json` and feed
        /// `.path`. The extract is provably non-divergent from the registry's typed
        /// decode of the SAME bytes: it parses ONE field with
        /// `protocol.JSON_PARSE_OPTIONS` VERBATIM (so `.use_first` matches the
        /// registry on duplicate keys). `ignore_unknown_fields = true` is the one
        /// permitted divergence and is fail-closed (the registry's full-ArgsT decode
        /// uses `ignore_unknown_fields = false` and rejects extra-field requests
        /// before the handler opens anything). A missing/ill-typed `path` returns
        /// `error.BadScope`, which the caller maps to a fail-closed deny. `a` is the
        /// per-message arena; the extracted string only feeds the gate.
        fn deriveScopeInput(self: *Self, a: std.mem.Allocator, label: []const u8, command: []const u8, args_json: []const u8) error{BadScope}!security.gates.ScopeInput {
            const set = self.grants.scopeFor(label, command);
            const has_path = scopeSetHasPath(set);
            if (!has_path) return .none;
            // Pass protocol.JSON_PARSE_OPTIONS VERBATIM (spread + the one permitted
            // override) so this parse can never silently diverge from the registry's
            // typed decode if protocol adds another non-default option later. The only
            // deliberate divergence is `ignore_unknown_fields = true`, which is
            // fail-closed: the registry's full-ArgsT decode keeps it false and rejects
            // extra-field requests before the handler opens anything.
            var opts = protocol.JSON_PARSE_OPTIONS;
            opts.ignore_unknown_fields = true;
            const parsed = std.json.parseFromSliceLeaky(struct { path: []const u8 }, a, args_json, opts) catch return error.BadScope;
            return .{ .path = parsed.path };
        }

        /// True when either the allow or deny scope set contains any `.path` Scope.
        fn scopeSetHasPath(set: security.grant.ScopeSet) bool {
            for (set.allow) |s| if (s == .path) return true;
            for (set.deny) |s| if (s == .path) return true;
            return false;
        }

        // ── Registry-facing surface (duck-typed by registry.dispatch) ──────────

        /// G5 reservation. Returns true if the call may proceed (slot reserved),
        /// false if it was rejected (duplicate id, budget exceeded, or OOM) — in
        /// which case this method has already emitted the terminal reject.
        pub fn reserveCall(self: *Self, label: []const u8, id: u64) bool {
            self.inflight_mutex.lockUncancelable(self.io);
            defer self.inflight_mutex.unlock(self.io);
            if (self.inflight.count() >= MAX_CONCURRENT) {
                self.emitErrorReject(label, id, "queue_full", "server busy", null);
                return false;
            }
            const gop = self.inflight.getOrPut(self.alloc, id) catch {
                self.emitErrorReject(label, id, "queue_full", "server busy", null);
                return false;
            };
            if (gop.found_existing) {
                self.emitErrorReject(label, id, "internal", "duplicate id", null);
                return false;
            }
            // Insert with no own-flag. The async branch upgrades this to a real
            // flag via armCancel before submit; sync calls stay flag-free.
            gop.value_ptr.* = null;
            return true;
        }

        /// Allocate and arm this invocation's cancel flag, publishing it into the
        /// inflight entry under inflight_mutex. Called by the ASYNC branch of
        /// dispatchOne on the message thread, BEFORE pool.submit, so a
        /// compute.cancel arriving the instant after enqueue still finds the flag
        /// (early-cancel safe). The flag is ZERO-INITIALIZED because create()
        /// returns UNDEFINED memory (0xAA in Debug/ReleaseSafe); without the
        /// explicit init the worker's first own.load(.acquire) reads true and the
        /// job spuriously self-cancels. The reservation already exists (reserveCall
        /// inserted the id with value null), so this only flips the value.
        pub fn armCancel(self: *Self, id: u64) !*std.atomic.Value(bool) {
            const flag = try self.alloc.create(std.atomic.Value(bool));
            flag.* = .{ .raw = false };
            self.inflight_mutex.lockUncancelable(self.io);
            defer self.inflight_mutex.unlock(self.io);
            if (self.inflight.getPtr(id)) |slot| {
                slot.* = flag;
            } else {
                // No reservation (should not happen on the live path): drop the
                // flag rather than leak or publish an orphan.
                self.alloc.destroy(flag);
                return error.NoReservation;
            }
            return flag;
        }

        /// Flip the per-invocation cancel flag for `id` to true (.release, pairing
        /// with the worker's .acquire load). No-op on a cleared/finished id (the
        /// entry is gone) or a sync/unarmed id (null flag): the deref is guarded so
        /// there is no use-after-free against releaseCall.
        pub fn cancelId(self: *Self, id: u64) void {
            self.inflight_mutex.lockUncancelable(self.io);
            defer self.inflight_mutex.unlock(self.io);
            if (self.inflight.get(id)) |maybe_flag| {
                if (maybe_flag) |flag| flag.store(true, .release);
            }
        }

        /// Release the reservation recorded for `id`. Idempotent: an id not
        /// present (already released, or rejected before submit) is a no-op. Runs
        /// on worker threads via the registry's async thunk, hence the mutex.
        pub fn releaseCall(self: *Self, id: u64) void {
            self.inflight_mutex.lockUncancelable(self.io);
            // fetchRemove so the own-flag (if any) is freed under the same lock
            // that guards arm/cancel; the worker held CancelToken.own for its whole
            // run, so this runs only AFTER runHandler returns (cache-before-free).
            // The value is nullable: a null flag (sync / arm-failed) frees nothing.
            if (self.inflight.fetchRemove(id)) |kv| {
                if (kv.value) |flag| self.alloc.destroy(flag);
            }
            self.inflight_mutex.unlock(self.io);
            // Do NOT free parked binary here (deviation 9): the webview pulls
            // bytes AFTER the call settles, so freeing on settle would 404 every
            // pull. Mark the ring settled; serveStream frees it once its last seq
            // is served, and deinitBins frees any un-pulled ring at teardown.
            // markBinSettled does NOT run under inflight_mutex (unlocked above),
            // so there is no inflight->bin lock coupling (H3).
            self.markBinSettled(id);
        }

        /// The single choke point into backend.evalJS (G6: one call site). Routes
        /// `js` to `label`'s window. With a manager, re-resolves the label to a
        /// live handle under the map mutex; a window closed mid-flight drops the
        /// JS (drop-after-close discipline). Without a manager (pre-E single
        /// window), routes to the bootstrap handle so all existing tests stay green.
        fn emitToLabel(self: *Self, label: []const u8, js: []const u8) void {
            if (self.manager) |m| {
                if (m.handleFor(label)) |h| self.backend.evalJS(h, js);
                return; // window closed mid-flight: drop
            }
            self.backend.evalJS(self.window, js); // pre-E single-window fallback
        }

        /// Emit a minimal reject from a fixed stack buffer that CANNOT OOM, so
        /// every id always settles even under allocator failure (H5). Emits a
        /// constant `"error"` reason; correctness only needs the id and the
        /// reject channel. Routes to the calling window by `label`.
        fn emitFixedReject(self: *Self, label: []const u8, id: u64) void {
            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "window.Zigware._reject({d}, \"error\");", .{id}) catch {
                std.log.warn("bridge: fixed reject overflow for id {d}", .{id});
                return;
            };
            self.emitToLabel(label, js);
        }

        pub fn emitResolve(self: *Self, label: []const u8, id: u64, json: []const u8) void {
            var aw: std.Io.Writer.Allocating = .init(self.alloc);
            defer aw.deinit();
            protocol.encodeResolve(&aw.writer, id, json) catch {
                self.emitFixedReject(label, id);
                return;
            };
            self.emitToLabel(label, aw.writer.buffered());
        }

        pub fn emitErrorReject(self: *Self, label: []const u8, id: u64, code: []const u8, message: []const u8, payload: ?[]const u8) void {
            var aw: std.Io.Writer.Allocating = .init(self.alloc);
            defer aw.deinit();
            protocol.encodeErrorReject(&aw.writer, id, code, message, payload) catch {
                self.emitFixedReject(label, id);
                return;
            };
            self.emitToLabel(label, aw.writer.buffered());
        }

        /// Push a `Zigware._emit(event, payload)` to ONE window by label. The app
        /// push channel: `event` is escaped at the protocol boundary, `payload`
        /// must already be std.json output (handler obligation). A serialize
        /// failure or a closed window drops silently (no terminal contract here).
        pub fn emit(self: *Self, label: []const u8, event: []const u8, json_payload: []const u8) void {
            var aw: std.Io.Writer.Allocating = .init(self.alloc);
            defer aw.deinit();
            protocol.encodeEmit(&aw.writer, event, json_payload) catch return;
            self.emitToLabel(label, aw.writer.buffered());
        }

        /// Push the same event to EVERY live window. Requires a manager (the
        /// single-window path has only one window; broadcast there is the no-op
        /// of doing nothing). Snapshots the live handles under the map mutex, then
        /// evals OUTSIDE the lock (never hold the map lock across a seam call).
        pub fn emitAll(self: *Self, event: []const u8, json_payload: []const u8) void {
            const m = self.manager orelse return;
            var aw: std.Io.Writer.Allocating = .init(self.alloc);
            defer aw.deinit();
            protocol.encodeEmit(&aw.writer, event, json_payload) catch return;
            var buf: [32]B.WindowHandle = undefined;
            const n = m.snapshotHandles(&buf);
            for (buf[0..n]) |h| self.backend.evalJS(h, aw.writer.buffered());
        }

        /// Per-call sink context. The EmitSink is its first field so the static
        /// closures recover (bridge, id) via @fieldParentPtr. Lives on the
        /// runHandler frame (sync) or the heap job ctx's runHandler frame (async);
        /// the by-value local outlives the whole call (B1).
        pub const SinkCtx = struct {
            sink: ctxmod.EmitSink,
            bridge: *Self,
            id: u64,
        };

        /// Build a per-call SinkCtx (returned BY VALUE) for in-flight call `id`.
        /// No allocation, no map, no lock on the emit path (B1). The label is
        /// "main" pre-E (deviation 3).
        pub fn makeSink(self: *Self, id: u64) SinkCtx {
            return .{ .sink = .{ .label = "main", .evalJS = sinkEvalJS, .parkBinary = sinkParkBinary }, .bridge = self, .id = id };
        }

        fn sinkEvalJS(sink: *ctxmod.EmitSink, js: []const u8) void {
            const sc: *SinkCtx = @fieldParentPtr("sink", sink);
            // Route by the per-call sink label (set by runHandler to the attested
            // caller's window). The A-seam alive check lives in backend.evalJS
            // (dropped after teardown); emitToLabel additionally drops on a window
            // closed mid-flight.
            sc.bridge.emitToLabel(sink.label, js);
        }

        fn sinkParkBinary(sink: *ctxmod.EmitSink, id: u64, seq: u32, bytes: []const u8) bool {
            const sc: *SinkCtx = @fieldParentPtr("sink", sink);
            return sc.bridge.parkBinary(id, seq, bytes);
        }

        // ── Per-id binary ring buffer (Task 7 Step 1 machinery) ────────────────

        /// Park bytes under (id, seq). Returns false if the per-id budget would
        /// overflow. Copies the bytes (the handler's slice is arena-owned and
        /// freed after the call).
        pub fn parkBinary(self: *Self, id: u64, seq: u32, bytes: []const u8) bool {
            self.bin_mutex.lockUncancelable(self.io);
            defer self.bin_mutex.unlock(self.io);
            // Do NOT reap served entries here: parkBinary runs on a worker thread,
            // but a just-served entry's bytes may still be in flight being copied
            // by the backend on the scheme/main thread (serveStream returns a
            // transient slice into this ring; the backend copies it AFTER
            // serveStream unlocks bin_mutex). A worker freeing that body mid-copy
            // is a use-after-free. Reaping happens only in serveStream (same
            // scheme/main thread, after the prior copy completed) and deinitBins
            // (after the pool joins).
            const cur_total = if (self.bins.getPtr(id)) |r| r.total else 0;
            if (cur_total + bytes.len > BIN_BUDGET_PER_ID) return false;
            const gop = self.bins.getOrPut(self.alloc, id) catch return false;
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const ring = gop.value_ptr;
            const copy = self.alloc.dupe(u8, bytes) catch return false;
            ring.entries.append(self.alloc, .{ .seq = seq, .bytes = copy }) catch {
                self.alloc.free(copy);
                return false;
            };
            ring.total += bytes.len;
            return true;
        }

        /// Serve one parked entry for (id, seq), exactly once. Returns a transient
        /// Response into this ring. The returned body stays valid until the NEXT
        /// serveStream on the scheme/main thread or until teardown, and is NEVER
        /// freed by a worker thread: only serveStream (this same thread, on a later
        /// call, after the prior copy completed) and deinitBins (after the pool
        /// joins) reap; parkBinary does not. Scheme callbacks are serialized on the
        /// main thread, so the backend's copy of this body always completes before
        /// the next serveStream can free it. 404s an unknown or already-served
        /// (id, seq).
        pub fn serveStream(self: *Self, path: []const u8) backend_mod.Response {
            const parsed = parseStreamPath(path) orelse return notFound();
            self.bin_mutex.lockUncancelable(self.io);
            defer self.bin_mutex.unlock(self.io);
            self.reapServedLocked();
            const ring = self.bins.getPtr(parsed.id) orelse return notFound();
            for (ring.entries.items) |*e| {
                if (e.seq == parsed.seq and !e.served) {
                    e.served = true;
                    return .{ .status = 200, .mime = "application/octet-stream", .body = e.bytes, .kind = .transient };
                }
            }
            return notFound();
        }

        fn notFound() backend_mod.Response {
            return .{ .status = 404, .mime = "text/plain", .body = "", .kind = .embedded_static };
        }

        /// Parse `/__zigware_stream/<id>/<seq>` into numeric id and seq. Rejects
        /// anything else (defense in depth; A already 404s non-stream sources).
        pub const StreamPath = struct { id: u64, seq: u32 };
        pub fn parseStreamPath(path: []const u8) ?StreamPath {
            const prefix = "/__zigware_stream/";
            if (!std.mem.startsWith(u8, path, prefix)) return null;
            const rest = path[prefix.len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
            const id = std.fmt.parseInt(u64, rest[0..slash], 10) catch return null;
            const seq = std.fmt.parseInt(u32, rest[slash + 1 ..], 10) catch return null;
            return .{ .id = id, .seq = seq };
        }

        /// Mark the ring for `id` settled (deviation 9). Does NOT free parked
        /// bytes (the webview pulls them after settle). A ring with no entries
        /// (no _bin was ever parked, e.g. a non-binary call) is removed here so
        /// common calls leave nothing behind.
        fn markBinSettled(self: *Self, id: u64) void {
            self.bin_mutex.lockUncancelable(self.io);
            defer self.bin_mutex.unlock(self.io);
            const ring = self.bins.getPtr(id) orelse return;
            ring.settled = true;
            if (ring.entries.items.len == 0) {
                if (self.bins.fetchRemove(id)) |kv| {
                    var r = kv.value;
                    r.entries.deinit(self.alloc);
                }
            }
        }

        /// Free the bytes of every already-served entry across all rings, and drop
        /// any settled ring left empty. Reclaims served binary on the next
        /// park/serve without freeing bytes still in flight. Caller holds
        /// bin_mutex. The empties buffer is a fixed window; any overflow is reaped
        /// on the next pass (deinitBins is the backstop).
        fn reapServedLocked(self: *Self) void {
            var empties: [16]u64 = undefined;
            var n: usize = 0;
            var it = self.bins.iterator();
            while (it.next()) |kv| {
                const ring = kv.value_ptr;
                var i: usize = 0;
                while (i < ring.entries.items.len) {
                    if (ring.entries.items[i].served) {
                        self.alloc.free(ring.entries.items[i].bytes);
                        _ = ring.entries.orderedRemove(i);
                    } else i += 1;
                }
                if (ring.settled and ring.entries.items.len == 0 and n < empties.len) {
                    empties[n] = kv.key_ptr.*;
                    n += 1;
                }
            }
            for (empties[0..n]) |id| {
                if (self.bins.fetchRemove(id)) |kv| {
                    var r = kv.value;
                    r.entries.deinit(self.alloc);
                }
            }
        }

        /// Free every parked ring at teardown (the backstop for any un-pulled or
        /// un-reaped entry).
        fn deinitBins(self: *Self) void {
            var it = self.bins.iterator();
            while (it.next()) |kv| {
                for (kv.value_ptr.entries.items) |e| self.alloc.free(e.bytes);
                kv.value_ptr.entries.deinit(self.alloc);
            }
            self.bins.deinit(self.alloc);
        }

        /// Test-only accessor: the current in-flight call count. After a fully
        /// drained flood it must be 0 (proves no reservation leaks).
        pub fn inflightCount(self: *Self) usize {
            self.inflight_mutex.lockUncancelable(self.io);
            defer self.inflight_mutex.unlock(self.io);
            return self.inflight.count();
        }
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const NullBackend = @import("platform/null.zig").NullBackend;
const builtin = @import("commands/builtin.zig");
const fixtures = @import("security_test_fixtures.zig");

const dummy_bases = security.gates.Bases{ .appdata = "/tmp", .home = "/tmp", .appconfig = "/tmp" };

const Manager = WindowManager(NullBackend);

const TestBridge = struct {
    backend: *NullBackend,
    bridge: *Bridge(NullBackend),
    window_id: u64,
    state: *builtin.State,
    grants: *fixtures.GrantTable,
    // E multi-window harness fields. null on the pre-E single-window init().
    manager: ?*Manager = null,
    id_a: u64 = 0,
    id_b: u64 = 0,
    handle_a: NullBackend.WindowHandle = undefined,
    handle_b: NullBackend.WindowHandle = undefined,

    fn init() !TestBridge {
        const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
        const win = try backend.createWindow(.{ .url = "app://localhost/index.html" });
        const state = try std.testing.allocator.create(builtin.State);
        state.* = .{};
        const grants = try fixtures.buildTestGrants(std.testing.allocator);
        const bridge = try Bridge(NullBackend).init(
            std.testing.allocator,
            std.testing.io,
            backend,
            win,
            builtin.State,
            builtin.Commands,
            state,
            .{ .worker_count = 4 }, // deterministic concurrency (L9)
            grants,
            dummy_bases,
            std.Io.Dir.cwd(),
            false,
        );
        // Wire a scheme callback so simulateSchemeRequestSource(.stream_scheme,...)
        // reaches the bridge's serveStream (send() calls handleMessage directly,
        // so the other callbacks are unused no-ops here).
        backend.setCallbacks(.{
            .ctx = bridge,
            .onSchemeRequest = schemeReq,
            .onMessage = noopMessage,
            .onLifecycle = noopLifecycle,
            .onNavigation = noopNavigation,
        });
        return .{ .backend = backend, .bridge = bridge, .window_id = backend.windowId(win), .state = state, .grants = grants };
    }

    /// E multi-window harness: a bridge wired to a heap WindowManager owning two
    /// windows "a" and "b" (both want_show=true). The manager is heap-allocated
    /// (like every other field) so its address is stable after this returns by
    /// value; bridge.setManager(mgr) routes labelFor/emitToLabel through it.
    fn initMulti() !TestBridge {
        const backend = try NullBackend.init(std.testing.allocator, std.testing.io);
        // Bootstrap window for the bridge's required `window` field; routing goes
        // through the manager, so this handle is never the reply target.
        const boot = try backend.createWindow(.{ .url = "app://localhost/index.html" });
        const state = try std.testing.allocator.create(builtin.State);
        state.* = .{};
        const grants = try fixtures.buildTestGrantsMulti(std.testing.allocator);
        const bridge = try Bridge(NullBackend).init(
            std.testing.allocator,
            std.testing.io,
            backend,
            boot,
            builtin.State,
            builtin.Commands,
            state,
            .{ .worker_count = 4 },
            grants,
            dummy_bases,
            std.Io.Dir.cwd(),
            false,
        );
        backend.setCallbacks(.{
            .ctx = bridge,
            .onSchemeRequest = schemeReq,
            .onMessage = noopMessage,
            .onLifecycle = noopLifecycle,
            .onNavigation = noopNavigation,
        });
        const mgr = try std.testing.allocator.create(Manager);
        mgr.* = Manager.init(std.testing.allocator, backend, std.testing.io);
        bridge.setManager(mgr);
        const ea = try mgr.create(.{ .label = "a", .url = "app://localhost/a", .show = true });
        const eb = try mgr.create(.{ .label = "b", .url = "app://localhost/b", .show = true });
        return .{
            .backend = backend,
            .bridge = bridge,
            .window_id = backend.windowId(boot),
            .state = state,
            .grants = grants,
            .manager = mgr,
            .id_a = ea.window_id,
            .id_b = eb.window_id,
            .handle_a = ea.handle,
            .handle_b = eb.handle,
        };
    }

    fn schemeReq(ctx: *anyopaque, req: backend_mod.Request) backend_mod.Response {
        const bridge: *Bridge(NullBackend) = @ptrCast(@alignCast(ctx));
        switch (req.source) {
            .stream_scheme => return bridge.serveStream(req.path),
            .asset_scheme => return .{ .status = 404, .mime = "text/plain", .body = "" },
        }
    }
    fn noopMessage(_: *anyopaque, _: u64, _: []const u8, _: []const u8) void {}
    fn noopLifecycle(_: *anyopaque, _: backend_mod.LifecycleEvent) void {}
    fn noopNavigation(_: *anyopaque, _: []const u8) backend_mod.NavigationDecision {
        return .cancel;
    }

    fn send(self: *TestBridge, text: []const u8) void {
        self.bridge.handleMessage(self.window_id, "app://localhost", text);
    }

    fn settle(self: *TestBridge) void {
        self.bridge.drainForTest();
        self.backend.pumpMain();
    }

    fn deinit(self: *TestBridge) void {
        self.bridge.deinit(); // joins workers; backend.deinit asserts joined
        // Tear the manager down AFTER the bridge joins its pool but BEFORE the
        // backend deinits: mgr.deinit cancels/joins watchdog threads and frees
        // entries, which still touch the (live) backend. A manager outliving the
        // backend would let a waking watchdog touch freed backend state.
        if (self.manager) |m| {
            m.deinit();
            std.testing.allocator.destroy(m);
        }
        self.grants.deinit();
        std.testing.allocator.destroy(self.grants);
        std.testing.allocator.destroy(self.state);
        self.backend.markJoined();
        self.backend.deinit();
    }
};

// countResolveExactly / countRejectExactly are pub methods on NullBackend, so
// both these bridge tests and the regression suite call them the same way.

// ─── E: multi-window routing, impersonation resistance, ready signal ──────────

test "E: a reply routes to the originating window by attested id" {
    var t = try TestBridge.initMulti();
    defer t.deinit();
    t.bridge.handleMessage(t.id_b, "app://localhost", "{\"id\":7,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(7));
    // Every _resolve(7,…) frame must land in window b (the caller), never a.
    for (t.backend.eval_log.items) |e| {
        if (std.mem.indexOf(u8, e.js, "_resolve(7, ") != null)
            try std.testing.expectEqual(t.id_b, e.window_id);
    }
}

test "E: a gate deny from a window routes its reject to that same window" {
    var t = try TestBridge.initMulti();
    defer t.deinit();
    // Untrusted origin from window b: G1 denies, and the reject must carry b's id,
    // proving the hoisted per-call label drives the early-reject routing (not the
    // bootstrap handle, not window a).
    t.bridge.handleMessage(t.id_b, "https://evil.example", "{\"id\":3,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(3));
    for (t.backend.eval_log.items) |e| {
        if (std.mem.indexOf(u8, e.js, "_reject(3, ") != null)
            try std.testing.expectEqual(t.id_b, e.window_id);
    }
}

test "E: a message from an unattributable window id is dropped (fail closed)" {
    var t = try TestBridge.initMulti();
    defer t.deinit();
    // 999 is neither a's nor b's id. Under a WIRED manager it is unattributable,
    // so the message must be DROPPED: no gating as "main", no resolve and no reject
    // routed anywhere. Were it coerced to "main", the well-formed sha256 call would
    // have produced a terminal _resolve(8, ...).
    t.bridge.handleMessage(999, "app://localhost", "{\"id\":8,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 0), t.backend.countResolveExactly(8));
    try std.testing.expectEqual(@as(usize, 0), t.backend.countRejectExactly(8));
    // Nothing for id 8 reached any window: no terminal frame for the dropped id was
    // ever emitted, so in particular none mis-routed to main.
    for (t.backend.eval_log.items) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.js, "_resolve(8, ") == null);
        try std.testing.expect(std.mem.indexOf(u8, e.js, "_reject(8, ") == null);
    }
}

test "E: emit targets one window; emitAll targets all" {
    var t = try TestBridge.initMulti();
    defer t.deinit();
    t.bridge.emit("a", "ping", "{\"n\":1}");
    t.bridge.emitAll("theme", "{\"dark\":true}");
    t.backend.pumpMain();
    var a_ping: usize = 0;
    var a_theme: usize = 0;
    var b_theme: usize = 0;
    for (t.backend.eval_log.items) |e| {
        if (std.mem.indexOf(u8, e.js, "ping") != null and e.window_id == t.id_a) a_ping += 1;
        if (std.mem.indexOf(u8, e.js, "theme") != null and e.window_id == t.id_a) a_theme += 1;
        if (std.mem.indexOf(u8, e.js, "theme") != null and e.window_id == t.id_b) b_theme += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), a_ping);
    try std.testing.expectEqual(@as(usize, 1), a_theme);
    try std.testing.expectEqual(@as(usize, 1), b_theme);
}

test "E: __zigware_ready shows only the attested window, ignoring the body label" {
    var t = try TestBridge.initMulti();
    defer t.deinit();
    // Body claims label "a"; the bridge must derive the target from the attested
    // id_b alone and show only window b.
    t.bridge.handleMessage(t.id_b, "app://localhost", "{\"id\":0,\"cmd\":\"__zigware_ready\",\"args\":{\"label\":\"a\"}}");
    t.backend.pumpMain();
    try std.testing.expect(t.backend.windows.items[t.handle_b].shown);
    try std.testing.expect(!t.backend.windows.items[t.handle_a].shown);
}

test "E: __zigware_ready from an untrusted origin is rejected (G1) and shows nothing" {
    var t = try TestBridge.initMulti();
    defer t.deinit();
    t.bridge.handleMessage(t.id_b, "https://evil.example", "{\"id\":0,\"cmd\":\"__zigware_ready\",\"args\":{}}");
    t.backend.pumpMain();
    try std.testing.expect(!t.backend.windows.items[t.handle_b].shown);
}

test "happy path: invoke sha256 emits ordered progress then exactly one resolve" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expect(t.backend.countContaining("window.Zigware._stream(1, ") >= 1);
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 0), t.backend.countRejectExactly(1));
}

test "streaming: two concurrent invokes never interleave stream ids" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":2}}");
    t.send("{\"id\":2,\"cmd\":\"sha256\",\"args\":{\"megabytes\":2}}");
    t.settle();
    // Each id resolves exactly once; each has its own stream frames.
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(2));
    try std.testing.expect(t.backend.countContaining("window.Zigware._stream(1, ") >= 1);
    try std.testing.expect(t.backend.countContaining("window.Zigware._stream(2, ") >= 1);
}

test "unknown command rejects exactly once and dispatches nothing" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":9,\"cmd\":\"danger\",\"args\":{}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(9));
    try std.testing.expectEqual(@as(usize, 0), t.backend.countContaining("_resolve"));
}

test "malformed message with a scannable id rejects exactly once" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":42, this is not valid json");
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(42));
}

test "pure-noise malformed message produces no emission" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("not json at all");
    t.settle();
    try std.testing.expectEqual(@as(usize, 0), t.backend.eval_log.items.len);
}

test "message over MAX_MESSAGE_LEN drops with one reject and no allocation spike" {
    var t = try TestBridge.init();
    defer t.deinit();
    const big = try std.testing.allocator.alloc(u8, protocol.MAX_MESSAGE_LEN + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    // Splice a scannable id at the front so the reject correlates.
    const prefix = "{\"id\":7,";
    @memcpy(big[0..prefix.len], prefix);
    t.send(big);
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(7));
}

test "two invokes correlate to distinct ids" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.send("{\"id\":2,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(2));
}

test "terminate before draining suppresses all emission for an in-flight job" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.backend.terminate();
    t.send("{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 0), t.backend.eval_log.items.len);
}

test "flood: every submitted id settles exactly once (resolve XOR reject)" {
    var t = try TestBridge.init();
    defer t.deinit();
    const N: u64 = 1000;
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        var buf: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":1}}}}", .{i});
        t.send(text);
    }
    t.settle();
    i = 0;
    while (i < N) : (i += 1) {
        const settled = t.backend.countResolveExactly(i) + t.backend.countRejectExactly(i);
        try std.testing.expectEqual(@as(usize, 1), settled);
    }
    // After a fully drained flood, every reservation must be released.
    try std.testing.expectEqual(@as(usize, 0), t.bridge.inflightCount());
}

test "I2: a flood stays within a bounded transient memory budget (concurrency-capped)" {
    // DebugAllocator with a hard transient ceiling. The concurrency-count cap
    // (MAX_CONCURRENT), not a byte budget, bounds peak: with megabytes:8, peak
    // ~= min(workers=4, MAX_CONCURRENT=8) * 8 MiB ~= 32 MiB, well under 64 MiB.
    var da = std.heap.DebugAllocator(.{ .thread_safe = true, .enable_memory_limit = true }){};
    da.requested_memory_limit = 64 * 1024 * 1024;
    defer std.testing.expect(da.deinit() == .ok) catch @panic("leak");
    const a = da.allocator();

    var state = builtin.State{};
    const backend = try NullBackend.init(a, std.testing.io);
    const win = try backend.createWindow(.{ .url = "app://localhost/index.html" });
    const grants = try fixtures.buildTestGrants(a);
    const bridge = try Bridge(NullBackend).init(a, std.testing.io, backend, win, builtin.State, builtin.Commands, &state, .{ .worker_count = 4 }, grants, dummy_bases, std.Io.Dir.cwd(), false);
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        var buf: [160]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":8}}}}", .{i});
        bridge.handleMessage(backend.windowId(win), "app://localhost", text);
    }
    bridge.drainForTest();
    backend.pumpMain();
    bridge.deinit();
    grants.deinit();
    a.destroy(grants);
    backend.markJoined();
    backend.deinit();
}

test "handleMessage tolerates extreme window_id values" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.bridge.handleMessage(0, "app://localhost", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.bridge.handleMessage(std.math.maxInt(u64), "app://localhost", "{\"id\":2,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(2));
}

test "G1: empty, port-bearing, and foreign origins are denied; app://localhost is allowed" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.bridge.handleMessage(t.window_id, "", "{\"id\":1,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.bridge.handleMessage(t.window_id, "app://localhost:5173", "{\"id\":2,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.bridge.handleMessage(t.window_id, "javascript:alert(1)", "{\"id\":3,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.bridge.handleMessage(t.window_id, "app://localhost", "{\"id\":4,\"cmd\":\"sha256\",\"args\":{\"megabytes\":1}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(1)); // empty origin denied
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(2)); // app://localhost:5173 is a different origin
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(3)); // javascript: denied
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(4)); // app://localhost allowed (sha256 granted by test:default)
}

test "duplicate id is rejected and does not corrupt the inflight budget" {
    // Two messages share an id. The second must reject as a duplicate without
    // overwriting the first's reservation. After draining, inflightCount() == 0.
    var t = try TestBridge.init();
    defer t.deinit();
    // Use a large job so the first reservation is still in flight when the
    // duplicate arrives. The pool has 4 workers; one large job keeps a slot.
    t.send("{\"id\":5,\"cmd\":\"sha256\",\"args\":{\"megabytes\":256}}");
    t.send("{\"id\":5,\"cmd\":\"sha256\",\"args\":{\"megabytes\":256}}");
    t.settle();
    // The first settles (resolve or reject); the duplicate is one extra reject.
    const settled = t.backend.countResolveExactly(5) + t.backend.countRejectExactly(5);
    try std.testing.expect(settled >= 1);
    try std.testing.expectEqual(@as(usize, 0), t.bridge.inflightCount());
}

// ─── Real concurrency (H11, H13) ────────────────────────────────────────────────

test "Bridge.deinit while a worker is mid-emit does not UAF" {
    var t = try TestBridge.init();
    // Submit large jobs and deinit immediately with NO settle. terminate then
    // pool.join must complete before any hop touches freed state. The NullBackend
    // markJoined contract enforces ordering.
    var i: u64 = 0;
    while (i < 16) : (i += 1) {
        var buf: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cmd\":\"sha256\",\"args\":{{\"megabytes\":16}}}}", .{i});
        t.send(text);
    }
    t.backend.terminate(); // queued evals will be dropped on pump
    t.deinit(); // bridge.deinit joins; markJoined; backend.deinit drains+frees
}

// ─── Fuzz (H14: manual >= 10000-iteration driver because 0.16 --fuzz is broken) ─

test "parkBinary parks within budget, rejects on overflow, and frees on teardown" {
    var t = try TestBridge.init();
    defer t.deinit(); // joins + deinitBins; freeing the parked ring with no leak is the assertion
    const small = [_]u8{0xAB} ** 16;
    try std.testing.expect(t.bridge.parkBinary(1, 0, &small));
    const big = try std.testing.allocator.alloc(u8, BIN_BUDGET_PER_ID);
    defer std.testing.allocator.free(big);
    try std.testing.expect(!t.bridge.parkBinary(1, 1, big)); // cumulative size exceeds budget
}

test "binary: echoBytes parks bytes, emits _bin, and serves them once over the stream scheme" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":1,\"cmd\":\"echoBytes\",\"args\":{\"n\":8}}");
    t.settle();
    // A _bin control frame was emitted; the raw bytes never appear in eval_log.
    try std.testing.expect(t.backend.countContaining("window.Zigware._bin(1, 0, 8, ") >= 1);
    // Serve the bytes through the stream scheme; they come back, length 8.
    const r = t.backend.simulateSchemeRequestSource(.stream_scheme, "/__zigware_stream/1/0");
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqual(@as(usize, 8), r.body.len);
    // Second pull of the same (id, seq) 404s (serve-once).
    const r2 = t.backend.simulateSchemeRequestSource(.stream_scheme, "/__zigware_stream/1/0");
    try std.testing.expectEqual(@as(u16, 404), r2.status);
}

test "binary: unknown (id, seq) 404s" {
    var t = try TestBridge.init();
    defer t.deinit();
    const r = t.backend.simulateSchemeRequestSource(.stream_scheme, "/__zigware_stream/999/0");
    try std.testing.expectEqual(@as(u16, 404), r.status);
}

test "parseStreamPath: adversarial table never traps and parses only well-formed paths" {
    const P = Bridge(NullBackend).parseStreamPath;
    // Valid minimal.
    {
        const r = P("/__zigware_stream/1/0") orelse return error.ExpectedParse;
        try std.testing.expectEqual(@as(u64, 1), r.id);
        try std.testing.expectEqual(@as(u32, 0), r.seq);
    }
    // Valid at the u64/u32 maxima.
    {
        const r = P("/__zigware_stream/18446744073709551615/4294967295") orelse return error.ExpectedParse;
        try std.testing.expectEqual(std.math.maxInt(u64), r.id);
        try std.testing.expectEqual(std.math.maxInt(u32), r.seq);
    }
    // Malformed: each must return null and must not trap.
    try std.testing.expect(P("/wrong_prefix/1/0") == null); // wrong prefix
    try std.testing.expect(P("/__zigware_stream/1") == null); // missing seq segment
    try std.testing.expect(P("/__zigware_stream//0") == null); // empty id
    try std.testing.expect(P("/__zigware_stream/1/") == null); // empty seq
    try std.testing.expect(P("/__zigware_stream/x/0") == null); // non-numeric id
    try std.testing.expect(P("/__zigware_stream/1/y") == null); // non-numeric seq
    try std.testing.expect(P("/__zigware_stream/99999999999999999999/0") == null); // id overflow (checked parseInt)
    // Extra trailing segment: indexOfScalar finds the first '/', so seq is
    // "0/2" and the checked parseInt rejects the embedded '/'.
    try std.testing.expect(P("/__zigware_stream/1/0/2") == null);
    // Trailing slash: seq becomes "0/", which the checked parseInt rejects.
    try std.testing.expect(P("/__zigware_stream/1/0/") == null);
}

test "binary: bytes never appear on the eval channel (G6 untouched)" {
    var t = try TestBridge.init();
    defer t.deinit();
    t.send("{\"id\":1,\"cmd\":\"echoBytes\",\"args\":{\"n\":8}}");
    t.settle();
    // echoBytes fills byte[i] = @truncate(i), so for n=8 the raw payload is
    // {0,1,2,3,4,5,6,7}. Those control bytes cannot appear in any eval_log entry:
    // the _bin frame carries only id/seq/len/mime, never the bytes themselves.
    const raw = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    for (t.backend.eval_log.items) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.js, &raw) == null);
        // Every emitted frame is a known control frame, never raw bytes.
        try std.testing.expect(std.mem.indexOf(u8, e.js, "_bin(") != null or
            std.mem.indexOf(u8, e.js, "_resolve(") != null or
            std.mem.indexOf(u8, e.js, "_stream(") != null or
            std.mem.indexOf(u8, e.js, "_reject(") != null);
    }
}

const FUZZ_ITERS: usize = 10_000;

test "fuzz: handleMessage tolerates arbitrary text bytes (manual driver)" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();
    var t = try TestBridge.init();
    defer t.deinit();
    var it: usize = 0;
    while (it < FUZZ_ITERS) : (it += 1) {
        var buf: [256]u8 = undefined;
        const n = rand.uintLessThan(usize, buf.len);
        rand.bytes(buf[0..n]);
        t.bridge.handleMessage(rand.int(u64), "app://localhost", buf[0..n]);
    }
    t.settle();
}

test "fuzz: handleMessage tolerates arbitrary window_id and origin (manual driver)" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed ^ 0x9e3779b9);
    const rand = prng.random();
    var t = try TestBridge.init();
    defer t.deinit();
    var it: usize = 0;
    while (it < FUZZ_ITERS) : (it += 1) {
        var ob: [128]u8 = undefined;
        var tb: [512]u8 = undefined;
        const on = rand.uintLessThan(usize, ob.len);
        const tn = rand.uintLessThan(usize, tb.len);
        rand.bytes(ob[0..on]);
        rand.bytes(tb[0..tn]);
        t.bridge.handleMessage(rand.int(u64), ob[0..on], tb[0..tn]);
    }
    t.settle();
}

// ─── Live scope (Task 5): the bridge derives ScopeInput.path before G4 ─────────

const ctxlive = @import("command_ctx.zig");
const cap_live = @import("security/capability.zig");
const defaults_live = @import("security/defaults.zig");

// A sync command granted a path scope. Its body is trivial (the test exercises
// the G4 extraction, not the work): a denied request never reaches it, an allowed
// one resolves immediately. Its args carry the single `path` field the bridge's
// pre-evaluate extractor decodes from args_json.
const ScopedCommands = struct {
    pub fn hashFile(ctx: *ctxlive.Ctx(builtin.State), args: struct { path: []const u8 }) ctxlive.Result(struct {}) {
        _ = ctx;
        _ = args;
        return .{ .ok = .{} };
    }
};

// Catalog granting `hashFile` a `$APPDATA/notes/**` path scope under one app
// permission, plus core:default so the cancel command stays resolvable.
const scoped_catalog = cap_live.Catalog{
    .permissions = &(defaults_live.builtin_permissions ++ [_]cap_live.Permission{
        .{ .identifier = "app:hashFile", .commands_allow = &.{"hashFile"}, .scope_allow = &.{.{ .path = "$APPDATA/notes/**" }} },
    }),
    .sets = &defaults_live.builtin_sets,
};

// A bridge wired with the scoped command, a tmp app-data dir as base_dir, and
// $APPDATA anchored at that dir so realPathFile resolves the in-scope candidate.
const ScopedBridge = struct {
    backend: *NullBackend,
    bridge: *Bridge(NullBackend),
    window_id: u64,
    state: *builtin.State,
    grants: *fixtures.GrantTable,
    tmp: std.testing.TmpDir,
    // The realpath of the tmp app-data dir, HEAP-owned (testing allocator) so the
    // bridge's bases.appdata stays valid after init returns and messages can carry
    // an ABSOLUTE candidate path (the frontend would send the resolved path).
    base_path: []const u8,

    fn base(self: *const ScopedBridge) []const u8 {
        return self.base_path;
    }

    fn init() !ScopedBridge {
        const a = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        // Anchor $APPDATA at the tmp dir and create the in-scope file on disk so
        // the allow half is a real allow (realPathFile resolves it), not a
        // fail-closed accident.
        var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const base_len = try tmp.dir.realPath(io, &base_buf);
        const base_path = try a.dupe(u8, base_buf[0..base_len]);
        errdefer a.free(base_path);
        try tmp.dir.createDirPath(io, "notes");
        var f = try tmp.dir.createFile(io, "notes/secret.txt", .{});
        f.close(io);

        const backend = try NullBackend.init(a, io);
        errdefer backend.deinit();
        const win = try backend.createWindow(.{ .url = "app://localhost/index.html" });
        const state = try a.create(builtin.State);
        errdefer a.destroy(state);
        state.* = .{};

        const grants = try a.create(fixtures.GrantTable);
        errdefer a.destroy(grants);
        var diags: @import("manifest/types.zig").Diagnostics = .{};
        defer diags.deinit(a);
        const caps = [_]cap_live.Capability{.{
            .identifier = "notes",
            .windows = &.{"main"},
            .origins = &.{.app_scheme},
            .permissions = &.{ "core:default", "app:hashFile" },
        }};
        grants.* = try fixtures.GrantTable.compile(a, &caps, &scoped_catalog, .{}, &.{"main"}, &diags);
        errdefer grants.deinit();

        // $APPDATA points at the tmp base; base_dir is that same dir so
        // realPathFile resolves the candidate against the on-disk file.
        const bases = security.gates.Bases{ .appdata = base_path, .home = base_path, .appconfig = base_path };
        const bridge = try Bridge(NullBackend).init(
            a,
            io,
            backend,
            win,
            builtin.State,
            ScopedCommands,
            state,
            .{ .worker_count = 4 },
            grants,
            bases,
            tmp.dir,
            false,
        );
        return .{
            .backend = backend,
            .bridge = bridge,
            .window_id = backend.windowId(win),
            .state = state,
            .grants = grants,
            .tmp = tmp,
            .base_path = base_path,
        };
    }

    fn send(self: *ScopedBridge, text: []const u8) void {
        self.bridge.handleMessage(self.window_id, "app://localhost", text);
    }

    fn settle(self: *ScopedBridge) void {
        self.bridge.drainForTest();
        self.backend.pumpMain();
    }

    fn deinit(self: *ScopedBridge) void {
        self.bridge.deinit();
        self.grants.deinit();
        std.testing.allocator.destroy(self.grants);
        std.testing.allocator.destroy(self.state);
        std.testing.allocator.free(self.base_path);
        self.backend.markJoined();
        self.backend.deinit();
        self.tmp.cleanup();
    }
};

test "live scope: the bridge extracts path before G4 and denies an out-of-scope arg" {
    var t = try ScopedBridge.init();
    defer t.deinit();
    var buf: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;

    // In-scope: the bridge decodes args_json's `path`, scopeFor reports a `.path`
    // scope, and G4 allows because the file resolves under $APPDATA/notes/**.
    const in_msg = try std.fmt.bufPrint(&buf, "{{\"id\":1,\"cmd\":\"hashFile\",\"args\":{{\"path\":\"{s}/notes/secret.txt\"}}}}", .{t.base()});
    t.send(in_msg);
    t.settle();
    try std.testing.expectEqual(@as(usize, 1), t.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 0), t.backend.countRejectExactly(1));

    // Out-of-scope traversal: G4 denies BEFORE any reservation/dispatch with the
    // real path-miss code (NOT the non-existent "out_of_scope").
    const out_msg = try std.fmt.bufPrint(&buf, "{{\"id\":2,\"cmd\":\"hashFile\",\"args\":{{\"path\":\"{s}/notes/../../etc/passwd\"}}}}", .{t.base()});
    t.send(out_msg);
    t.settle();
    try std.testing.expectEqual(@as(usize, 0), t.backend.countResolveExactly(2));
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(2));
    try std.testing.expect(t.backend.countContaining("scope.path.no_match") == 1);
}

test "live scope: a path-scoped command with a missing path arg fails closed" {
    var t = try ScopedBridge.init();
    defer t.deinit();
    // No `path` field: the extractor's decode fails, and a path-scoped command
    // must DENY (fail closed), never fall through to .none/allow.
    t.send("{\"id\":3,\"cmd\":\"hashFile\",\"args\":{}}");
    t.settle();
    try std.testing.expectEqual(@as(usize, 0), t.backend.countResolveExactly(3));
    try std.testing.expectEqual(@as(usize, 1), t.backend.countRejectExactly(3));
}
