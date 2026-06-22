//! Headless end-to-end proof for the crypto-demo example.
//!
//! The unit tests in `commands/crypto.zig` prove the pure crypto core. This test
//! proves the SAME `cryptoDemo` handler resolves through the REAL command
//! pipeline a window would use: a JSON envelope arrives at `Bridge(NullBackend)`,
//! passes the gate (the window holds a capability granting the `app:cryptoDemo`
//! permission), dispatches to the handler, and settles the promise with a JSON
//! resolve carrying the digest, ciphertext, and round-trip flag.
//!
//! It runs over NullBackend because a real macOS window cannot register an
//! app-defined command yet (the framework App wires only its built-in command
//! surface); the bridge is the highest layer that can exercise `cryptoDemo`
//! today, and it is the exact dispatch/encode path the eventual window will use.

const std = @import("std");
const z = @import("zigware");
const crypto = @import("commands/crypto.zig");

const NullBackend = z.NullBackend;
const Bridge = z.Bridge;

/// SHA-256("abc"), a published test vector. The resolve must carry this exact
/// digest, proving the key shown to the user is a genuine SHA-256.
const sha256_abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

/// The example command surface the bridge registers. `crypto.Commands` already
/// exposes `pub fn cryptoDemo`, so it IS the surface. No wrapper needed.
const CryptoCommands = crypto.Commands;

/// An unscoped app permission granting the one command. `cryptoDemo` touches no
/// filesystem, so unlike the notes example it carries no path scope. The gate
/// authorizes it on the command being in `commands_allow`.
const crypto_permission = z.capability.Permission{
    .identifier = "app:cryptoDemo",
    .commands_allow = &.{"cryptoDemo"},
};

/// A minimal catalog holding that permission. The capability references
/// only `app:cryptoDemo`, so no built-in sets are needed to resolve it.
const crypto_catalog = z.capability.Catalog{
    .permissions = &.{crypto_permission},
    .sets = &.{},
};

const Harness = struct {
    backend: *NullBackend,
    bridge: *Bridge(NullBackend),
    window_id: u64,
    state: *crypto.State,
    grants: *z.GrantTable,

    fn init() !Harness {
        const a = std.testing.allocator;
        const io = std.testing.io;

        const backend = try NullBackend.init(a, io);
        errdefer backend.deinit();
        const win = try backend.createWindow(.{ .url = "app://localhost/index.html" });

        const state = try a.create(crypto.State);
        errdefer a.destroy(state);
        state.* = .{};

        // Grant `cryptoDemo` to "main" via the app:cryptoDemo permission. One cap
        // per window keeps scopeFor's inert n<=1 guard satisfied.
        const grants = try a.create(z.GrantTable);
        errdefer a.destroy(grants);
        var gdiag: z.manifest.Diagnostics = .{};
        defer gdiag.deinit(a);
        const caps = [_]z.capability.Capability{.{
            .identifier = "crypto",
            .windows = &.{"main"},
            .origins = &.{.app_scheme},
            .permissions = &.{"app:cryptoDemo"},
        }};
        grants.* = try z.GrantTable.compile(a, &caps, &crypto_catalog, .{}, &.{"main"}, &gdiag);
        errdefer grants.deinit();

        // cryptoDemo declares no scope, so the path bases are never consulted;
        // anchor them at "." and use cwd as the base dir.
        const bases = z.gates.Bases{ .appdata = ".", .home = ".", .appconfig = "." };
        const bridge = try Bridge(NullBackend).init(
            a,
            io,
            backend,
            win,
            crypto.State,
            CryptoCommands,
            state,
            .{ .worker_count = 4 },
            grants,
            bases,
            std.Io.Dir.cwd(),
            false,
        );
        return .{
            .backend = backend,
            .bridge = bridge,
            .window_id = backend.windowId(win),
            .state = state,
            .grants = grants,
        };
    }

    fn send(self: *Harness, text: []const u8) void {
        self.bridge.handleMessage(self.window_id, "app://localhost", text);
    }

    fn settle(self: *Harness) void {
        self.bridge.drainForTest();
        self.backend.pumpMain();
    }

    fn deinit(self: *Harness) void {
        self.bridge.deinit();
        self.grants.deinit();
        std.testing.allocator.destroy(self.grants);
        std.testing.allocator.destroy(self.state);
        self.backend.markJoined();
        self.backend.deinit();
    }
};

test "crypto example: cryptoDemo resolves through the real bridge with the digest and round-trip" {
    var h = try Harness.init();
    defer h.deinit();

    h.send(
        \\{"id":1,"cmd":"cryptoDemo","args":{"password":"abc","message":"hi"}}
    );
    h.settle();

    // Exactly one resolve, no reject, for this invocation id.
    try std.testing.expectEqual(@as(usize, 1), h.backend.countResolveExactly(1));
    try std.testing.expectEqual(@as(usize, 0), h.backend.countRejectExactly(1));

    // The resolve carries the real SHA-256 digest, the recovered plaintext, and a
    // successful round-trip flag: the full encrypt/decrypt closed over the bridge.
    try std.testing.expect(h.backend.countContaining(sha256_abc) >= 1);
    try std.testing.expect(h.backend.countContaining("\"decrypted\":\"hi\"") >= 1);
    try std.testing.expect(h.backend.countContaining("\"roundTrip\":true") >= 1);
}

test "crypto example: cryptoDemo resolves through a real App via initWithCommands" {
    // The production wiring: App.initWithCommands registers cryptoDemo AND
    // synthesizes the grant that authorizes it for the "main" window. This is the
    // exact path the shipping exe (src/main.zig) takes, with no hand-built grants.
    const backend = try z.NullBackend.init(std.testing.allocator, std.testing.io);
    const app = try z.App(z.NullBackend).initWithCommands(crypto.Commands, std.testing.allocator, std.testing.io, backend);
    defer {
        app.deinit();
        backend.markJoined();
        backend.deinit();
    }
    const main_id = app.manager.lookup("main").?.window_id;
    backend.simulateMessage(main_id, "app://localhost",
        \\{"id":1,"cmd":"cryptoDemo","args":{"password":"abc","message":"hi"}}
    );
    app.bridge.drainForTest();
    backend.pumpMain();

    try std.testing.expectEqual(@as(usize, 1), backend.countContaining("window.Zigware._resolve(1, "));
    try std.testing.expect(backend.countContaining(sha256_abc) >= 1);
    try std.testing.expect(backend.countContaining("\"decrypted\":\"hi\"") >= 1);
    try std.testing.expect(backend.countContaining("\"roundTrip\":true") >= 1);
}

test "crypto example: an ungranted command is denied at the gate" {
    var h = try Harness.init();
    defer h.deinit();

    // "encryptAll" is not in commands_allow, so the gate must reject it before any
    // handler runs, proving the grant gates the surface.
    h.send(
        \\{"id":2,"cmd":"encryptAll","args":{}}
    );
    h.settle();

    try std.testing.expectEqual(@as(usize, 0), h.backend.countResolveExactly(2));
    try std.testing.expectEqual(@as(usize, 1), h.backend.countRejectExactly(2));
}
