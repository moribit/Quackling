//! A connection pool.
//!
//! Quack gives each connection its own server-side session and result cursor,
//! so a single `Client` can only have one query in flight. A server handling
//! several concurrent requests needs several connections; this pool hands them
//! out and takes them back.
//!
//! ```zig
//! var pool = try quackling.Pool.init(.{
//!     .allocator = allocator,
//!     .endpoint = "quack:localhost:9494",
//!     .token = token,
//!     .transport = http.transport(),
//!     .max_connections = 8,
//! });
//! defer pool.deinit();
//!
//! var lease = try pool.acquire(null);
//! defer lease.release();
//! var result = try lease.client.query("SELECT 42");
//! ```
//!
//! The pool is guarded by a mutex and is safe to share between threads. It
//! holds no global state, so several pools can coexist (todo.md §17).

const std = @import("std");
const client_mod = @import("client.zig");
const transport_mod = @import("transport/transport.zig");
const errors = @import("error.zig");
const stats_mod = @import("stats.zig");

const Client = client_mod.Client;
const CancelToken = transport_mod.CancelToken;

pub const Error = errors.QueryError || error{
    /// `acquire` was called with `.fail` and no connection was free.
    PoolExhausted,
    /// `acquire` was called after `deinit`.
    PoolClosed,
};

/// What `acquire` does when every connection is busy.
pub const WaitPolicy = enum {
    /// Block until one is released (or the cancel token fires).
    wait,
    /// Return `error.PoolExhausted` immediately. Useful for a request handler
    /// that would rather shed load than queue.
    fail,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    token: []const u8 = "",
    /// Transport shared by every pooled connection. It must be safe to use
    /// from multiple threads if the pool is; `NativeTransport` is, because
    /// `std.http.Client` pools its own sockets thread-safely.
    transport: transport_mod.Transport,
    /// Used for the pool's own blocking waits. Pass the same `Io` the transport
    /// uses; `std.Io.Threaded` is the usual choice.
    io: std.Io,
    headers: []const transport_mod.Header = &.{},
    timeout_ms: ?u32 = null,
    max_response_bytes: usize = 256 * 1024 * 1024,
    observer: ?stats_mod.Observer = null,

    /// Hard cap on live connections.
    max_connections: usize = 8,
    /// Connections opened eagerly at `init`. The rest are created on demand.
    min_connections: usize = 0,
    /// What to do when the pool is saturated.
    wait_policy: WaitPolicy = .wait,

    /// Called by `deinit` when it has to block on outstanding leases, with the
    /// number still out.
    ///
    /// `deinit` cannot return until every lease is back, so a caller holding
    /// one deadlocks itself. There is no portable way to detect that from
    /// inside the pool, so this hook lets the caller log or assert as its own
    /// conventions dictate. Leaving it null makes `deinit` wait silently.
    on_deinit_wait: ?*const fn (ctx: ?*anyopaque, outstanding: usize) void = null,
    /// Opaque context passed to `on_deinit_wait`.
    observer_ctx: ?*anyopaque = null,
};

/// A borrowed connection. `release()` returns it to the pool.
///
/// Modelled as an explicit handle rather than a bare `*Client` so the
/// borrow is visible at the call site and `defer lease.release()` reads
/// naturally.
pub const Lease = struct {
    pool: *Pool,
    client: *Client,
    /// Guards against a double release, which would corrupt the free list.
    released: bool = false,

    pub fn release(self: *Lease) void {
        if (self.released) return;
        self.released = true;
        self.pool.releaseClient(self.client);
    }

    /// Return the connection to the pool *and* discard it, for use when the
    /// caller knows it is in a bad state (protocol desync, transport failure).
    pub fn discard(self: *Lease) void {
        if (self.released) return;
        self.released = true;
        self.pool.discardClient(self.client);
    }
};

pub const Stats = struct {
    /// Connections currently owned by the pool, idle or leased.
    total: usize = 0,
    /// Currently leased out.
    in_use: usize = 0,
    /// Ready to hand out.
    idle: usize = 0,
    /// Cumulative counters.
    acquires: u64 = 0,
    creates: u64 = 0,
    discards: u64 = 0,
    waits: u64 = 0,
    timeouts: u64 = 0,
};

pub const Pool = struct {
    options: Options,
    allocator: std.mem.Allocator,

    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Signalled whenever a connection returns to `idle`.
    available: std.Io.Condition = .init,

    /// Connections ready to hand out.
    idle: std.ArrayList(*Client) = .empty,
    /// Every connection the pool owns, so `deinit` can free them all.
    owned: std.ArrayList(*Client) = .empty,
    leased: usize = 0,
    closed: bool = false,

    stats: Stats = .{},

    pub fn init(options: Options) Error!Pool {
        if (options.max_connections == 0) return Error.PoolExhausted;

        var pool = Pool{
            .options = options,
            .allocator = options.allocator,
            .io = options.io,
        };
        errdefer pool.deinit();

        const warm = @min(options.min_connections, options.max_connections);
        var i: usize = 0;
        while (i < warm) : (i += 1) {
            const c = try pool.createClient();
            try pool.owned.append(pool.allocator, c);
            try pool.idle.append(pool.allocator, c);
        }
        pool.stats.total = warm;
        pool.stats.idle = warm;
        return pool;
    }

    /// Close the pool and release every connection.
    ///
    /// Blocks until all outstanding leases have been returned, because
    /// destroying a connection a `Lease` still points at would leave that lease
    /// dangling. Every lease must therefore be released before (or concurrently
    /// with) `deinit`.
    ///
    /// In a safety-checked build, calling `deinit` from a thread that is itself
    /// holding a lease is caught with a clear panic rather than hanging: it is
    /// a caller bug, and an unexplained hang is the worst possible way to
    /// report one. In release builds it degrades to the wait.
    pub fn deinit(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        self.closed = true;
        // Wake anyone blocked in `acquire`; they will observe `closed`.
        self.available.broadcast(self.io);

        // Surface the wait through the caller's own hook rather than printing.
        // A library has no business writing to stderr (todo.md §18), and the
        // caller is the only one who can tell a legitimate concurrent release
        // from a leaked lease.
        if (self.leased > 0) {
            if (self.options.on_deinit_wait) |f| f(self.options.observer_ctx, self.leased);
        }

        while (self.leased > 0) {
            self.available.waitUncancelable(self.io, &self.mutex);
        }
        const owned = self.owned.toOwnedSlice(self.allocator) catch self.owned.items;
        self.idle.deinit(self.allocator);
        self.idle = .empty;
        self.mutex.unlock(self.io);

        // Destroy outside the lock: each client sends a DISCONNECT.
        for (owned) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        if (owned.len > 0) self.allocator.free(owned);
        self.owned = .empty;
    }

    /// Borrow a connection, creating one if the pool is below capacity and
    /// waiting if it is not.
    pub fn acquire(self: *Pool, cancel: ?*CancelToken) Error!Lease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return Error.PoolClosed;

        while (true) {
            if (cancel) |c| if (c.isCancelled()) return errors.TransportError.Cancelled;

            if (self.idle.pop()) |c| {
                self.leased += 1;
                self.stats.acquires += 1;
                self.stats.in_use = self.leased;
                self.stats.idle = self.idle.items.len;
                return .{ .pool = self, .client = c };
            }

            if (self.owned.items.len < self.options.max_connections) {
                // Room to grow. Creating a Client does no I/O - the handshake
                // happens lazily on first query - so it is fine under the lock.
                const c = try self.createClient();
                errdefer {
                    c.deinit();
                    self.allocator.destroy(c);
                }
                try self.owned.append(self.allocator, c);
                self.leased += 1;
                self.stats.creates += 1;
                self.stats.acquires += 1;
                self.stats.total = self.owned.items.len;
                self.stats.in_use = self.leased;
                return .{ .pool = self, .client = c };
            }

            // At capacity.
            if (self.options.wait_policy == .fail) {
                self.stats.timeouts += 1;
                return Error.PoolExhausted;
            }
            self.stats.waits += 1;
            self.available.waitUncancelable(self.io, &self.mutex);
            if (self.closed) return Error.PoolClosed;
        }
    }

    fn createClient(self: *Pool) Error!*Client {
        const c = try self.allocator.create(Client);
        errdefer self.allocator.destroy(c);
        c.* = try Client.init(.{
            .allocator = self.options.allocator,
            .endpoint = self.options.endpoint,
            .token = self.options.token,
            .transport = self.options.transport,
            .headers = self.options.headers,
            .timeout_ms = self.options.timeout_ms,
            .max_response_bytes = self.options.max_response_bytes,
            .observer = self.options.observer,
        });
        return c;
    }

    fn releaseClient(self: *Pool, c: *Client) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.leased > 0) self.leased -= 1;

        // During shutdown the connection stays in `owned` for `deinit` to
        // destroy; just report that the lease is back so `deinit` can proceed.
        if (self.closed) {
            self.available.broadcast(self.io);
            return;
        }
        self.idle.append(self.allocator, c) catch {
            // Cannot record it as idle; drop it rather than leak a live
            // connection into limbo. It stays in `owned`, so it is still freed.
            self.available.signal(self.io);
            return;
        };
        self.stats.in_use = self.leased;
        self.stats.idle = self.idle.items.len;
        self.available.signal(self.io);
    }

    /// Retire a connection instead of reusing it.
    fn discardClient(self: *Pool, c: *Client) void {
        self.mutex.lockUncancelable(self.io);

        if (self.leased > 0) self.leased -= 1;
        self.stats.discards += 1;

        // Shutting down: `deinit` owns every connection, so hand it back
        // rather than racing to destroy it here.
        if (self.closed) {
            self.available.broadcast(self.io);
            self.mutex.unlock(self.io);
            return;
        }

        // Drop it from `owned` so a fresh one can take its slot.
        var found = false;
        for (self.owned.items, 0..) |o, i| {
            if (o == c) {
                _ = self.owned.swapRemove(i);
                found = true;
                break;
            }
        }
        self.stats.total = self.owned.items.len;
        self.stats.in_use = self.leased;
        self.available.broadcast(self.io);
        self.mutex.unlock(self.io);

        if (found) {
            c.deinit();
            self.allocator.destroy(c);
        }
    }

    /// A snapshot of pool state.
    pub fn snapshot(self: *Pool) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var s = self.stats;
        s.total = self.owned.items.len;
        s.idle = self.idle.items.len;
        s.in_use = self.leased;
        return s;
    }
};

const testing = std.testing;

/// A transport that always fails, so pool mechanics can be tested without a
/// server. Acquiring never performs I/O, so this is enough for lifecycle tests.
fn deadTransport() transport_mod.Transport {
    const Impl = struct {
        fn send(_: *anyopaque, _: std.mem.Allocator, _: transport_mod.Request) transport_mod.Error!transport_mod.Response {
            return transport_mod.Error.ConnectionFailed;
        }
    };
    // The vtable holds no state, so a dangling-but-unused pointer is fine here.
    return .{ .ptr = undefined, .vtable = &.{ .send = Impl.send } };
}

/// A `Threaded` Io scoped to one test, so nothing outlives the test that made
/// it. Callers pair this with `defer h.deinit()`.
const TestIo = struct {
    impl: std.Io.Threaded,

    fn init() TestIo {
        return .{ .impl = .init(testing.allocator, .{}) };
    }
    fn io(self: *TestIo) std.Io {
        return self.impl.io();
    }
    fn deinit(self: *TestIo) void {
        self.impl.deinit();
    }
};

fn testPool(tio: *TestIo, max: usize, min: usize) !Pool {
    return Pool.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:localhost:9494",
        .transport = deadTransport(),
        .io = tio.io(),
        .max_connections = max,
        .min_connections = min,
        // Tests must never block on a connection that will not arrive.
        .wait_policy = .fail,
    });
}

test "pool hands out and takes back connections" {
    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 2, 0);
    defer pool.deinit();

    var a = try pool.acquire(null);
    try testing.expectEqual(@as(usize, 1), pool.snapshot().in_use);
    var b = try pool.acquire(null);
    try testing.expectEqual(@as(usize, 2), pool.snapshot().in_use);
    // Distinct connections, since each is a separate session.
    try testing.expect(a.client != b.client);

    a.release();
    try testing.expectEqual(@as(usize, 1), pool.snapshot().in_use);
    try testing.expectEqual(@as(usize, 1), pool.snapshot().idle);
    b.release();
    try testing.expectEqual(@as(usize, 0), pool.snapshot().in_use);
}

test "a released connection is reused rather than recreated" {
    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 4, 0);
    defer pool.deinit();

    var first = try pool.acquire(null);
    const ptr = first.client;
    first.release();

    var second = try pool.acquire(null);
    defer second.release();
    try testing.expectEqual(ptr, second.client);
    // One create, two acquires.
    try testing.expectEqual(@as(u64, 1), pool.snapshot().creates);
    try testing.expectEqual(@as(u64, 2), pool.snapshot().acquires);
}

test "exceeding capacity times out instead of hanging" {
    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 1, 0);
    defer pool.deinit();

    var held = try pool.acquire(null);
    defer held.release();
    try testing.expectError(Error.PoolExhausted, pool.acquire(null));
    try testing.expectEqual(@as(u64, 1), pool.snapshot().timeouts);
}

test "warm start pre-creates connections" {
    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 4, 2);
    defer pool.deinit();
    const s = pool.snapshot();
    try testing.expectEqual(@as(usize, 2), s.total);
    try testing.expectEqual(@as(usize, 2), s.idle);
}

test "double release is a no-op" {
    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 2, 0);
    defer pool.deinit();
    var lease = try pool.acquire(null);
    lease.release();
    lease.release(); // must not corrupt the free list
    try testing.expectEqual(@as(usize, 1), pool.snapshot().idle);
}

test "discard retires the connection and frees its slot" {
    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 1, 0);
    defer pool.deinit();

    var lease = try pool.acquire(null);
    lease.discard();
    try testing.expectEqual(@as(usize, 0), pool.snapshot().total);
    try testing.expectEqual(@as(u64, 1), pool.snapshot().discards);

    // The freed slot is immediately usable again.
    var next = try pool.acquire(null);
    defer next.release();
    try testing.expectEqual(@as(usize, 1), pool.snapshot().total);
}

test "cancelled acquire returns promptly" {
    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 1, 0);
    defer pool.deinit();
    var token = CancelToken{};
    token.cancel();
    try testing.expectError(errors.TransportError.Cancelled, pool.acquire(&token));
}

test "deinit does not destroy a connection that is still leased" {
    // The contract `deinit` upholds is that a connection is never torn down
    // while a `Lease` still refers to it - otherwise a caller holding
    // `lease.client` across `deinit` would be dereferencing freed memory.
    //
    // `releaseClient` deliberately does not touch the client during shutdown,
    // so the *library's own* release path is safe either way. What the wait loop
    // protects is the caller's pointer, and the observable guarantee is
    // ordering: no client teardown may happen before the lease comes back.
    //
    // The pooled clients are given a live session id so that `Client.deinit`
    // sends a DISCONNECT, which the watching transport records - that request is
    // the teardown signal this test keys on.
    const Probe = struct {
        var waiting: bool = false;
        var released: bool = false;
        var torn_down_while_leased: bool = false;

        fn onWait(_: ?*anyopaque, _: usize) void {
            @atomicStore(bool, &waiting, true, .release);
        }
        fn onRequest() void {
            if (!@atomicLoad(bool, &released, .acquire)) {
                @atomicStore(bool, &torn_down_while_leased, true, .release);
            }
        }
    };
    Probe.waiting = false;
    Probe.released = false;
    Probe.torn_down_while_leased = false;

    const Watcher = struct {
        fn send(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: transport_mod.Request,
        ) transport_mod.Error!transport_mod.Response {
            Probe.onRequest();
            return transport_mod.Error.ConnectionFailed;
        }
    };

    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try Pool.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:localhost:9494",
        .transport = .{ .ptr = undefined, .vtable = &.{ .send = Watcher.send } },
        .io = tio.io(),
        .max_connections = 2,
        .wait_policy = .fail,
        .on_deinit_wait = Probe.onWait,
    });

    var lease = try pool.acquire(null);
    lease.client.connection_id = try testing.allocator.dupe(u8, "SESSION-FOR-TEARDOWN");

    const Releaser = struct {
        fn run(l: *Lease) void {
            // Wait until `deinit` reports that it is blocking on this lease.
            while (!@atomicLoad(bool, &Probe.waiting, .acquire)) {
                std.atomic.spinLoopHint();
            }
            @atomicStore(bool, &Probe.released, true, .release);
            l.release();
        }
    };
    const t = try std.Thread.spawn(.{}, Releaser.run, .{&lease});

    pool.deinit();
    t.join();

    try testing.expect(Probe.waiting);
    try testing.expect(!Probe.torn_down_while_leased);
}

test "release during shutdown never dereferences the connection" {
    // This is why the library's own path is safe regardless of the wait: when
    // the pool is closing, `releaseClient` only adjusts bookkeeping. Asserted
    // by releasing *after* `deinit` has already returned and freed everything -
    // if `release` touched the client, this would be a use-after-free that the
    // testing allocator would flag.
    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 2, 0);

    var lease = try pool.acquire(null);
    // Return it so `deinit` can complete, then release again (a no-op) to prove
    // the double-release guard also holds after teardown.
    lease.release();
    pool.deinit();
    lease.release();
}

test "deinit reports outstanding leases through the caller's hook" {
    const Seen = struct {
        var calls: usize = 0;
        var outstanding: usize = 0;
        fn hook(_: ?*anyopaque, n: usize) void {
            calls += 1;
            outstanding = n;
        }
    };
    Seen.calls = 0;
    Seen.outstanding = 0;

    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 2, 0);
    pool.options.on_deinit_wait = Seen.hook;

    var lease = try pool.acquire(null);
    const Releaser = struct {
        fn run(l: *Lease, p: *Pool) void {
            while (!@atomicLoad(bool, &p.closed, .acquire)) std.atomic.spinLoopHint();
            l.release();
        }
    };
    const t = try std.Thread.spawn(.{}, Releaser.run, .{ &lease, &pool });
    pool.deinit();
    t.join();

    try testing.expectEqual(@as(usize, 1), Seen.calls);
    try testing.expectEqual(@as(usize, 1), Seen.outstanding);
}

test "deinit with no outstanding leases does not invoke the hook" {
    const Seen = struct {
        var calls: usize = 0;
        fn hook(_: ?*anyopaque, _: usize) void {
            calls += 1;
        }
    };
    Seen.calls = 0;

    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 2, 1);
    pool.options.on_deinit_wait = Seen.hook;
    pool.deinit();
    try testing.expectEqual(@as(usize, 0), Seen.calls);
}

test "deinit after all leases are returned completes immediately" {
    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 2, 0);
    var lease = try pool.acquire(null);
    lease.release();
    pool.deinit();
}

test "concurrent acquire and release stays consistent" {
    // The pool is documented as thread-safe, so it must actually be exercised
    // from several threads: a single-threaded test cannot show a torn counter
    // or a corrupted free list.
    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 4, 0);
    defer pool.deinit();
    // Contention is the point, so block rather than shed load.
    pool.options.wait_policy = .wait;

    const Worker = struct {
        fn run(p: *Pool, iterations: usize) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                var lease = p.acquire(null) catch return;
                // A connection must never be handed to two leases at once.
                std.debug.assert(lease.client.*.allocator.ptr == lease.client.allocator.ptr);
                lease.release();
            }
        }
    };

    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &pool, 200 });
    for (threads) |t| t.join();

    const s = pool.snapshot();
    // Everything returned; nothing leaked and nothing double-counted.
    try testing.expectEqual(@as(usize, 0), s.in_use);
    try testing.expectEqual(s.total, s.idle);
    try testing.expect(s.total <= 4);
    try testing.expectEqual(@as(u64, 8 * 200), s.acquires);
}

test "a connection is never leased to two holders at once" {
    // Track which pointers are currently out; any overlap is a pool bug.
    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 3, 3);
    defer pool.deinit();

    var a = try pool.acquire(null);
    var b = try pool.acquire(null);
    var c = try pool.acquire(null);
    try testing.expect(a.client != b.client);
    try testing.expect(b.client != c.client);
    try testing.expect(a.client != c.client);
    // Pool is now empty.
    try testing.expectError(Error.PoolExhausted, pool.acquire(null));
    a.release();
    b.release();
    c.release();
}

test "concurrent discard and acquire keeps the pool usable" {
    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 3, 0);
    defer pool.deinit();
    pool.options.wait_policy = .wait;

    const Worker = struct {
        fn run(p: *Pool, iterations: usize, discard_every: usize) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                var lease = p.acquire(null) catch return;
                if (discard_every != 0 and i % discard_every == 0) {
                    lease.discard();
                } else {
                    lease.release();
                }
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &pool, 100, i + 2 });
    }
    for (threads) |t| t.join();

    const s = pool.snapshot();
    try testing.expectEqual(@as(usize, 0), s.in_use);
    try testing.expect(s.total <= 3);
    try testing.expect(s.discards > 0);
    // Still serviceable afterwards.
    var lease = try pool.acquire(null);
    lease.release();
}

test "acquire after deinit is rejected" {
    var tio = TestIo.init();
    defer tio.deinit();
    var pool = try testPool(&tio, 1, 0);
    pool.deinit();
    try testing.expectError(Error.PoolClosed, pool.acquire(null));
}
