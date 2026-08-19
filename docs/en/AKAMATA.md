# Integrating with Akamata

**English** · [日本語](../ja/AKAMATA.md)

→ [Documentation index](./README.md)

Quackling has no dependency on Akamata and never will — Akamata is a *user* of
this library, not part of it ([todo.md §17](../../todo.md)). This document
records what an adapter actually looks like, and what was verified by building
one.

Everything below was compiled against a real Akamata checkout (v0.0.2, Zig
0.16.0) and run against a live `quack_serve()`. Findings are from the compiler
and the server, not from reading the spec.

---

## 1. What already lines up

| Concern | Akamata | Quackling | Verdict |
|---|---|---|---|
| Zig version | `minimum_zig_version = "0.16.0"` | 0.16.0 | Match |
| Dependencies | `.dependencies = .{}` | none | Both zero-dep |
| Module export | `dep.module("akamata")` | `dep.module("quackling")` | Both consumable |
| Workers target | `wasm32-freestanding` | builds for it | Match |
| Transport injection | needs its own HTTP client used | `transport` is a required field | Match |
| Global state | forbidden | none | Match |

The important one is the last pair. `quackling.Client.init` has **no default
transport**; it must be injected. That is what makes an adapter possible at all,
rather than requiring a fork.

---

## 2. Transport adapter

Akamata expects a backend to use `am.http_client`, because that is what works on
both native (TLS) and Workers (the JS `fetch` bridge). Its `send()` takes an
arena and returns borrowed slices, which maps onto Quackling's
`Response.owned = false` path with no copy:

```zig
const std = @import("std");
const am = @import("akamata");
const quackling = @import("quackling");

pub const AkamataTransport = struct {
    arena: std.mem.Allocator,
    max_response_bytes: usize = 16 * 1024 * 1024,

    pub fn transport(self: *AkamataTransport) quackling.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = sendFn } };
    }

    fn sendFn(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        req: quackling.transport.Request,
    ) quackling.transport.Error!quackling.transport.Response {
        const self: *AkamataTransport = @ptrCast(@alignCast(ptr));
        _ = allocator; // Akamata allocates from its own arena.

        if (req.cancel) |c| if (c.isCancelled()) return error.Cancelled;

        // The two Header types are structurally identical but nominally
        // distinct, so translate rather than @ptrCast.
        var headers: [8]am.http_client.Header = undefined;
        var n: usize = 0;
        headers[n] = .{ .name = "content-type", .value = req.content_type };
        n += 1;
        for (req.headers) |h| {
            if (n == headers.len) break;
            headers[n] = .{ .name = h.name, .value = h.value };
            n += 1;
        }

        const resp = am.http_client.send(self.arena, .{
            .method = .POST,
            .url = req.url,
            .headers = headers[0..n],
            .body = req.body,
            .max_response_bytes = self.max_response_bytes,
            .timeout_ms = req.timeout_ms,
        }) catch |err| return mapError(err);

        return .{ .status = resp.status, .body = resp.body, .owned = false };
    }

    fn mapError(err: am.http_client.HttpClientError) quackling.transport.Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ConnectFailed => error.ConnectionFailed,
            error.TlsCertVerifyFailed, error.TlsHandshakeFailed => error.TlsError,
            error.InvalidUrl => error.InvalidUrl,
            error.ResponseTooLarge => error.ResponseTooLarge,
            error.UnsupportedOnTarget => error.Unsupported,
            error.HttpProtocolError => error.HttpError,
            error.ReadFailed, error.WriteFailed => error.NetworkError,
        };
    }
};
```

That is the whole transport layer: ~60 lines, no changes to either project.

### Verified on the Workers target

Built for `wasm32-freestanding` with Akamata's `-Dbackend=workers`, the linked
module imports exactly:

```
akamata_env.akamata_monotonic_ns
akamata_http.akamata_fetch
```

No libc, no WASI, no sockets. Quackling's protocol codec runs on Cloudflare
Workers through Akamata's own fetch bridge.

> Note: an earlier version of this check only *referenced* the types and the
> linker stripped the module to 79 bytes — which proved nothing. The number above
> comes from a build that calls through the adapter, producing 63 KB of real code.

### One caveat

`am.http_client.Request` accepts `timeout_ms`, but `HttpClientError` has **no
`Timeout` variant** — an expired deadline surfaces as `ReadFailed`/`WriteFailed`.
So through this adapter a caller cannot distinguish "timed out" from "connection
broke", even though Quackling's error taxonomy has a separate `Timeout`. If that
distinction matters, it needs a change on the Akamata side.

---

## 3. The `am.db.Db` question

This is where the two designs genuinely disagree, and it is worth being precise
rather than optimistic.

Akamata's `am.db.Db` is a **row-oriented pull cursor**: positional `bind`, then
`step()`, then per-column getters (`column_int`, `column_text`, …). Its Turso,
D1 and SQLite backends all implement that vtable.

Quackling is **chunk-oriented** by design — `todo.md §7` explicitly required that
the API not be row-only. The two are opposites at the interface level.

A shim is still possible, and was built and tested:

- `bind()` stages values, rendered into SQL by Quackling's own audited escaper at
  `step()` time (Quack v1 has no wire format for parameters). No second escaper.
- `step()` walks the current DataChunk and only issues a FETCH when it is
  exhausted, so **streaming survives** the row-at-a-time interface.

Verified against a live server:

| Test | Result |
|---|---|
| `SELECT 42, 'hi'` through `am.db.Stmt` | pass |
| `stmt.bindAll(.{20, 22})` → `42` | pass |
| 100,000 rows via `while (step() == .row)` | pass — `fetches > 0`, `chunks_received > 1` |
| `stmt.fetchOne(struct { id: i64, name: []const u8 })` | pass |

The 100k case asserts on `client.stats` specifically so a single-chunk result or
a silent skip cannot produce a false pass.

**The cost is real:** this facade throws away vectorized access, which is
Quackling's main performance advantage. It exists for code that wants to treat
Quack like any other Akamata backend.

### The better path

`ctx.db()` is generic over `State.db`:

```zig
pub fn db(self: *Self) if (@TypeOf(self.app_state.db) == db_mod.Db)
    db_mod.Db
else
    @TypeOf(self.app_state.db)
```

A custom type **passes through untouched**. So an app can put
`quackling.Client` (or a `Pool`) directly on its `State` and get the chunk API
inside a handler, with no shim and no loss:

```zig
const State = struct {
    db: *quackling.Pool,   // not am.db.Db
    cfg: Config,
};

fn handler(c: *Ctx) !void {
    var lease = try c.db().acquire();
    defer lease.release();

    var result = try lease.client.query("SELECT ...");
    defer result.deinit();

    while (try result.nextChunk()) |chunk| {
        // vectorized, straight into the response stream
    }
}
```

This is the recommended integration. Use the `am.db.Db` shim only when
uniformity with other backends matters more than throughput.

---

## 4. Remaining gaps

Nothing here blocks integration, but these are honest limitations:

- **Transactions.** `am.db.Transaction` issues `BEGIN`/`COMMIT` as SQL, which
  works, but Quackling exposes no explicit transaction API and Quack v1 has no
  transaction message. D1 already fails closed here (`TransactionsUnsupported`),
  so the precedent exists.
- **Timeout fidelity.** See §2.
- **Observability.** Akamata records DB spans via `trace.recordDb`, and Quackling
  has its own `Observer`/`Stats`. An adapter should bridge them; the PoC does not.
- **Packaging.** The adapter belongs in its own package that depends on both, so
  neither project gains a dependency.

---

## 5. Verification commands

```sh
# From a scratch project depending on both by path:
zig build test    # 6/6 pass against a live quack_serve()
zig build wasm    # links for wasm32-freestanding + -Dbackend=workers
```

The Akamata dependency must be instantiated with its own backend option, not
merely a wasm target, or its bundled SQLite forces libc:

```zig
const wa = b.dependency("akamata", .{
    .backend = @as([]const u8, "workers"),
    .optimize = .ReleaseSmall,
});
```
