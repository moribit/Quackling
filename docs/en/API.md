# API Reference

**English** · [日本語](../ja/API.md)

→ [Documentation index](./README.md)

The public surface of Quackling, as re-exported by
[`../../src/root.zig`](../../src/root.zig). Type decoding is covered separately in
[TYPES.md](./TYPES.md); the wire format is in [PROTOCOL.md](./PROTOCOL.md).

**Contents:** [Exports](#1-what-root-exports) · [Client](#2-client) ·
[Result](#3-result-and-rowstream) · [typed](#4-typed-struct-mapping) ·
[params](#5-params-query-parameters) · [Pool](#6-pool) ·
[Transport](#7-transport) · [Errors](#8-error-handling) ·
[Stats](#9-stats-and-observer) · [Endpoints](#10-endpoint-forms)

---

## 1. What `root` exports

```zig
const quackling = @import("quackling");
```

| Export | Underlying |
|--------|-----------|
| `Client`, `ClientOptions` | [`../../src/client.zig`](../../src/client.zig) |
| `Result`, `RowStream` | [`../../src/result.zig`](../../src/result.zig) |
| `DataChunk`, `Row`, `Vector`, `VectorType`, `Value`, `LogicalType`, `LogicalTypeId`, `ValidityMask` | `../../src/types/` |
| `Transport`, `MockTransport`, `CancelToken`, `Header`, `transport_mod` | [`../../src/transport/transport.zig`](../../src/transport/transport.zig) |
| `NativeTransport` | [`../../src/transport/native.zig`](../../src/transport/native.zig) — `@compileError` on wasm |
| `Stats`, `Observer` | [`../../src/stats.zig`](../../src/stats.zig) |
| `ErrorInfo`, `errors` | [`../../src/error.zig`](../../src/error.zig) |
| `typed` | [`../../src/typed.zig`](../../src/typed.zig) |
| `params`, `Param` | [`../../src/params.zig`](../../src/params.zig) |
| `Pool`, `PoolOptions`, `Lease` | [`../../src/pool.zig`](../../src/pool.zig) |
| `uri` | [`../../src/uri.zig`](../../src/uri.zig) |
| `serialization`, `protocol` | layered modules, for advanced use and testing |

---

## 2. `Client`

One `Client` is one logical Quack connection: one server-side session with one
result cursor. It holds no global state, so many can coexist in a process.

### `Client.Options`

| Field | Type | Default | Meaning |
|-------|------|---------|---------|
| `allocator` | `std.mem.Allocator` | *required* | Allocator for the URL, session id, send buffer, and decoded structures |
| `endpoint` | `[]const u8` | *required* | `quack:host[:port]`, or a plain `http://host:port` / `https://host:port` URL. See [§10](#10-endpoint-forms) |
| `token` | `[]const u8` | `""` | Auth token. Sent **inside** the protocol message, never logged |
| `transport` | `Transport` | *required* | The core library never picks one for you — that is what keeps it usable from wasm |
| `headers` | `[]const Header` | `&.{}` | Extra HTTP headers, e.g. for an authenticating proxy |
| `timeout_ms` | `?u32` | `null` | Per-request deadline handed to the transport |
| `max_response_bytes` | `usize` | `256 * 1024 * 1024` | Refuse to decode a larger response; also becomes the `Reader` byte-length limit |
| `observer` | `?Observer` | `null` | Per-request hooks; see [§9](#9-stats-and-observer) |

`endpoint` and `token` are **borrowed** — they must outlive the client, since
`Options` is stored by value in `Client.options`.

### Methods

```zig
pub fn init(options: Options) Error!Client
```
Parses `endpoint` and builds the request URL (e.g.
`http://localhost:9494/quack`). Performs **no I/O** — no handshake, no socket. So
constructing a client is cheap and cannot block, which is why `Pool` creates them
under its own lock. Errors: `error.InvalidUrl`, `error.EmptyHost`,
`error.InvalidPort`, `error.OutOfMemory`.

```zig
pub fn deinit(self: *Client) void
```
Sends a best-effort `DISCONNECT` if connected (failures ignored), then frees the
URL, session id, server identity strings, send buffer, and last error message.
Any `Result` must be `deinit`ed **before** the client it borrows.

```zig
pub fn connect(self: *Client, cancel: ?*CancelToken) Error!void
```
Performs the handshake: sends `CONNECTION_REQUEST` with the token, validates that
the server's `quack_version` is within `[min_supported_version,
max_supported_version]` (both `1`), and stores the session id from the response
**header** plus the server's DuckDB version and platform. Idempotent — returns
immediately if already connected.

Errors: `error.AuthenticationFailed` when the server's error text matches
`"authenticat"` / `"invalid token"` / `"unauthorized"` (matching is deliberately
narrow; a false negative just reports `ServerError`, which is still accurate),
`error.ServerError` for any other error response,
`error.UnsupportedProtocolVersion`, `error.UnexpectedMessageType` (including a
response with no session id), plus any transport error.

You rarely call this: `query` connects lazily.

```zig
pub fn isConnected(self: *const Client) bool
pub fn lastError(self: *const Client) []const u8
```
`isConnected` is `connection_id.len > 0`. `lastError` returns the last
server-provided text verbatim — DuckDB's message is the most useful thing a user
gets when their SQL is wrong — or `""` if there was none. The string is owned by
the client and replaced on the next server error.

```zig
pub fn disconnect(self: *Client) Error!void
```
Sends `DISCONNECT` and drops the session. No-op when not connected. Teardown is
best-effort: the session id is cleared even if the round trip fails, and the
transport error is still returned.

```zig
pub fn query(self: *Client, sql: []const u8) Error!Result
pub fn queryWithCancel(self: *Client, sql: []const u8, cancel: ?*CancelToken) Error!Result
```
Connects if needed, sends `PREPARE_REQUEST`, and returns a streaming `Result`
holding the first batch of chunks.

The result **borrows the client**: it must be `deinit`ed before the client, and
only one result may be open at a time. `query_generation` is bumped on every
PREPARE — *before* the SQL runs, because the server calls
`duckdb_query_result.reset()` as soon as it accepts a PREPARE, so the previous
cursor is gone even when the new query then fails. An older result that tries to
FETCH afterwards gets `error.ResultSuperseded` rather than the next query's rows.

```zig
var a = try client.query("SELECT * FROM big");
var b = try client.query("SELECT 1");   // discards a's cursor server-side
_ = try a.nextChunk();                  // error.ResultSuperseded
```

Errors: `error.ServerError` (bad SQL — text in `lastError()`),
`error.UnexpectedMessageType`, any transport/serialization error.

```zig
pub fn queryParams(self: *Client, sql: []const u8, args: []const Param) Error!Result
pub fn queryParamsWithCancel(self: *Client, sql: []const u8, args: []const Param, cancel: ?*CancelToken) Error!Result
```
Substitutes `?` placeholders from `args` (see [§5](#5-params-query-parameters))
and then behaves like `query`. When `args.len == 0` the SQL is sent **untouched**
— no rewriting pass at all. The bound SQL is freed before returning.

```zig
var result = try client.queryParams(
    "SELECT * FROM users WHERE id = ? AND name = ?",
    &.{ .{ .integer = 42 }, .{ .text = "o'brien" } },
);
defer result.deinit();
```

Additional errors: `error.ParameterCountMismatch`,
`error.UnsupportedParameter`, `error.InvalidUtf8`.

```zig
pub fn exec(self: *Client, sql: []const u8) Error!void
pub fn execParams(self: *Client, sql: []const u8, args: []const Param) Error!void
```
Run a statement and discard the rows — `query` + drain + `deinit`. Use for DDL
and DML. (If you want the row count, use `query` and `Result.drain()`.)

```zig
try client.exec("CREATE TABLE t (id INTEGER, name VARCHAR)");
try client.execParams("INSERT INTO t VALUES (?, ?)", &.{ Param.int(1), Param.str("a") });
```

```zig
pub fn fetch(self: *Client, uuid: i128, cancel: ?*CancelToken)
    Error!struct { response: Response, body: msg.FetchResponse }
```
Public but intended for `Result`, which calls it to pull the next batch. The
caller owns both returned values. Reach for it only if you are implementing your
own result driver.

```zig
pub fn append(self: *Client, table: []const u8, columns: []const encoder.Column) Error!void
pub fn appendToSchema(
    self: *Client,
    schema: []const u8,
    table: []const u8,
    columns: []const encoder.Column,
    cancel: ?*CancelToken,
) Error!void
```
Bulk insert: sends a whole `DataChunk` as an `APPEND_REQUEST` instead of an
INSERT statement. `append` targets schema `"main"`; `appendToSchema` takes the
schema and a cancel token. Connects lazily, like `query`.

`encoder.Column` is a type plus its values:

```zig
pub const Column = struct {
    type: LogicalType,
    values: []const Value,
};
```

```zig
const ids = [_]quackling.Value{ .{ .integer = 1 }, .{ .integer = 2 } };
const names = [_]quackling.Value{ .{ .varchar = "a" }, .null };
try client.append("events", &.{
    .{ .type = .{ .id = .integer }, .values = &ids },
    .{ .type = .{ .id = .varchar }, .values = &names },
});
```

Constraints, all enforced:

| Rule | Consequence |
|------|-------------|
| The table must already exist | The server rejects a missing table; surfaces as `error.ServerError` |
| `columns` must match the table's schema in order and type | Server-side rejection |
| At most `serialization.encoder.max_rows` (**2048**) rows per call | `error.TooManyRows`, raised client-side before sending |

Why it is worth using: the values are already typed, so no SQL is parsed and one
request carries a whole chunk. Measured against one parameterised INSERT per row
on the same server, **20 480 rows took 10 ms (1.97M rows/s, 10 requests) versus
3 821 ms (5.4k rows/s, 20 480 requests) — roughly 370×.** Values travel in
binary, so this path performs no SQL escaping at all, which also removes the
injection surface described in [§5](#5-params-query-parameters).

The encoder ([`../../src/serialization/encoder.zig`](../../src/serialization/encoder.zig))
is the mirror of the decoder, and its tests assert that everything it emits
decodes back identically.

### Readable state

`Client` exposes these fields directly (read-only by convention):
`server_version`, `server_platform`, `quack_version`, `connection_id`, `url`,
`stats`, `options`, `query_generation`, `last_error`.

### Full example

```zig
var http = try quackling.NativeTransport.init(allocator, .{});
defer http.deinit();

var client = try quackling.Client.init(.{
    .allocator = allocator,
    .endpoint = "quack:localhost:9494",
    .token = "super_secret",
    .transport = http.transport(),
});
defer client.deinit();

var result = client.query("SELECT 42 AS answer") catch |err| switch (err) {
    error.ServerError => {
        std.debug.print("server said: {s}\n", .{client.lastError()});
        return err;
    },
    else => return err,
};
defer result.deinit();

if (try result.scalar()) |v| std.debug.print("{f}\n", .{v});
```

---

## 3. `Result` and `RowStream`

Chunks are surfaced as they arrive and released as soon as the consumer moves on,
so peak memory tracks the batch size rather than the result size.

### Metadata

| Method | Signature | Notes |
|--------|-----------|-------|
| `columnCount` | `fn (*const Result) usize` | |
| `columnName` | `fn (*const Result, usize) ?[]const u8` | `null` when out of range; borrows the PREPARE response buffer |
| `columnType` | `fn (*const Result, usize) ?LogicalType` | `null` when out of range |
| `columnIndex` | `fn (*const Result, []const u8) ?usize` | linear `mem.eql` scan; `null` if no such column |

Column metadata borrows the PREPARE response, which the `Result` keeps alive for
its whole lifetime — so names and types stay valid across `nextChunk` calls, even
though chunk payloads do not.

### Consumption

```zig
pub fn nextChunk(self: *Result) Error!?*const DataChunk
```
The next chunk, or `null` when exhausted. **The returned pointer is invalidated
by the following `nextChunk` call**, which is what keeps the decode zero-copy:
the chunk's payload points into the response buffer the `Result` holds.

Each call: checks the cancel token (`error.Cancelled` if set), hands out a
pending chunk if one remains, otherwise FETCHes another batch (releasing the
previous one first, so exactly one batch is resident), and updates
`client.stats.chunks_received` / `rows_received` plus the observer's `onChunk`.

```zig
pub fn rows(self: *Result) RowStream
pub fn drain(self: *Result) Error!u64
pub fn scalar(self: *Result) Error!?Value
pub fn deinit(self: *Result) void
```

`drain` walks the whole result and returns `rows_seen` — useful for DDL/DML.
`scalar` pulls one chunk and returns row 0 / column 0, or `null` if the result is
empty or has no columns; it does not verify that only one row exists.
`deinit` releases the current FETCH batch, the decoded PREPARE body, and the
PREPARE response buffer.

`RowStream` walks chunk boundaries transparently:

```zig
pub fn next(self: *RowStream) Error!?Row
```

`Row` (from [`../../src/types/data_chunk.zig`](../../src/types/data_chunk.zig))
is a view that copies nothing: `get(col) !Value`, `isNull(col) bool`,
`columnCount() usize`.

### Observable counters

`rows_seen`, `chunks_seen`, `fetches` are plain fields you may read. `result_uuid`
and `generation` are protocol bookkeeping.

### `max_fetches`

```zig
max_fetches: u64 = 5_000_000,
```

End-of-stream is signalled by the *server* sending an empty batch, so a server
that never does would otherwise loop forever. At the documented batch size
(12 chunks × 2048 rows) this ceiling still allows well over 10¹¹ rows, so it
cannot be reached by legitimate use — it exists purely to keep a broken or
hostile peer from hanging the caller, and `error.FetchLimitExceeded` is the
error reserved for it.

### The three consumption styles

**1. Chunk-oriented (fastest).** DuckDB is vectorized, so the first-class API is
too. See [TYPES.md §9](./TYPES.md#9-zero-copy-access-rules) for the accessor
rules.

```zig
while (try result.nextChunk()) |chunk| {
    const col = chunk.column(0).?;
    if (col.asSlice(i64)) |slice| {
        for (slice) |v| consume(v);            // truly zero-copy
    } else if (col.isFlat(i64)) {
        for (0..chunk.row_count) |i| consume(col.at(i64, i).?);
    } else {
        for (0..chunk.row_count) |i| consume((try col.getValue(i)).asI64().?);
    }
}
```

**2. Row-oriented.**

```zig
var rows = result.rows();
while (try rows.next()) |row| {
    if (row.isNull(1)) continue;
    const id = (try row.get(0)).asI64().?;
    const name = (try row.get(1)).asSlice().?;   // borrows the chunk
}
```

**3. Typed struct.** See [§4](#4-typed-struct-mapping).

**4. Scalar.**

```zig
var r = try client.query("SELECT count(*) FROM t");
defer r.deinit();
const n = (try r.scalar()).?.asI64().?;
```

---

## 4. `typed`: struct mapping

Built strictly on top of the `DataChunk` API — the protocol core has no idea this
file exists. Field names are matched to column names at runtime once per result;
the per-field conversion is resolved at comptime.

```zig
pub fn iterator(comptime T: type, result: *Result) Error!Iterator(T)
pub fn collect(comptime T: type, allocator: std.mem.Allocator, result: *Result) Error![]T
pub fn convert(comptime T: type, v: Value) Error!T
pub fn Mapping(comptime T: type) type    // .init(*const Result), .read(Row)
pub fn Iterator(comptime T: type) type   // .next() Error!?T
```

```zig
const User = struct { id: i64, name: []const u8, score: f64, nickname: ?[]const u8 };

var it = try quackling.typed.iterator(User, &result);
while (try it.next()) |user| {
    std.debug.print("{d} {s} {d}\n", .{ user.id, user.name, user.score });
}
```

### Field mapping rules

- `T` must be a `struct`, else a `@compileError`.
- Each field name is looked up with `result.columnIndex(field_name)` — matching is
  **by name, exact, case-sensitive**; column order is irrelevant. Extra columns
  in the result are ignored. A field with no matching column is
  `error.MissingColumn`, raised by `iterator()` (i.e. up front, not mid-stream).

### Conversion table

| Field type | Accepted `Value` | Rule |
|-----------|------------------|------|
| `bool` | `.boolean` | anything else is `error.TypeMismatch` |
| any int | via `asI64()`, plus `.ubigint`/`.hugeint`/`.uhugeint` for values outside `i64` | `std.math.cast`; out of range is `error.TypeMismatch`, never a silent truncation |
| any float | via `asF64()` | `@floatCast` |
| `[]const u8` | `.varchar` / `.blob` / an ENUM's `.label` (via `asSlice()`) | **borrows the chunk buffer** |
| any `enum` | via `asI64()` then `std.meta.intToEnum` | out-of-range is `error.TypeMismatch` |
| `?T` | anything | `.null` → `null`, else recurse into `T` |
| anything else | — | `@compileError` |

Pointer fields other than `[]const u8` (non-slice, non-const, or non-`u8` child)
are a `@compileError`, not a runtime error.

### NULL handling

`?T` fields absorb NULL. **A NULL arriving for a non-optional field is
`error.UnexpectedNull`** — never a silent zero. That is the whole point of the
optional distinction.

```zig
try std.testing.expectError(error.UnexpectedNull, quackling.typed.convert(i64, .null));
try std.testing.expectEqual(@as(?i64, null), try quackling.typed.convert(?i64, .null));
```

### `collect`

```zig
const users = try quackling.typed.collect(User, allocator, &result);
defer allocator.free(users);
```

This defeats streaming, so it is for small results only. Worse, `[]const u8`
fields still borrow the chunk buffer — after `collect` returns, every chunk has
been released, so string fields in the collected slice **dangle**. Use `collect`
only for structs of scalars, or `dupe` the strings yourself in an `iterator`
loop.

### `typed.Error`

`error{ MissingColumn, TypeMismatch, UnexpectedNull } || result.Error`, so a
typed loop can also surface any transport/protocol error.

---

## 5. `params`: query parameters

### Why substitution is client-side

Quack protocol version 1 has **no wire representation for parameters**.
`PrepareRequestMessage` carries exactly one field — the SQL string — and the
server calls `SendQuery(sql)` with it directly
(`duckdb-quack/src/quack_server.cpp`). Two facts verified against a live server:

- `SELECT ?` returns *"Expected 1 parameters, but none were supplied"* — there is
  no channel to supply them.
- Adding an extra field to `PREPARE_REQUEST` makes the server return HTTP 500 —
  unknown fields are rejected, so we cannot invent one.

So parameters are rendered into the SQL text **client-side**, in
[`../../src/params.zig`](../../src/params.zig). That places the entire safety
burden on one small, heavily-tested file, which is why the encoders are strict and
why anything without an unambiguous literal form is rejected rather than
approximated.

Callers who want server-side prepared statements can still use SQL-level
`PREPARE` / `EXECUTE`, which the protocol handles fine.

### The `Param` union

```zig
pub const Param = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    hugeint: i128,     // 128-bit, rendered exactly (they exceed f64 precision)
    unsigned: u64,
    uhugeint: u128,
    double: f64,
    text: []const u8,  // quoted string literal with '' escaping
    blob: []const u8,  // BLOB literal with hex escapes
    date: i32,         // days since 1970-01-01
    timestamp: i64,    // microseconds since the epoch
    decimal: Value.Decimal,
    raw_sql: []const u8,  // pre-rendered SQL, inserted verbatim - NOT escaped
};
```

Deliberately a smaller set than `Value`: every variant has an exact, unambiguous
SQL literal form. Types whose text form would be lossy or dialect-dependent
(`INTERVAL`, `UUID`, `TIME`, `ENUM`, nested types) are **omitted** rather than
guessed at — use `.raw_sql` with a cast, or `.text` plus a server-side
`CAST`.

Convenience constructors:

```zig
pub fn int(v: anytype) Param   // .{ .integer = @intCast(v) }
pub fn str(v: []const u8) Param // .{ .text = v }
```

`Param.int` uses `@intCast`, so a value outside `i64` is a compile-time or safety-
check failure, not a silent wrap. Reach for `.hugeint` / `.unsigned` /
`.uhugeint` for wide integers.

### Rendering table

| Variant | SQL text produced | Example |
|---------|------------------|---------|
| `.null` | `NULL` | `NULL` |
| `.boolean` | `TRUE` / `FALSE` | `TRUE` |
| `.integer` | decimal digits | `42` |
| `.hugeint` | decimal digits, full 128-bit precision | `170141183460469231731687303715884105727` |
| `.unsigned` | decimal digits | `18446744073709551615` |
| `.uhugeint` | decimal digits | — |
| `.double` (finite) | `{d}::DOUBLE` — shortest round-trip form, cast so DuckDB reads DOUBLE not DECIMAL | `1.5::DOUBLE` |
| `.double` (NaN) | `'NaN'::DOUBLE` | `'NaN'::DOUBLE` |
| `.double` (+∞ / −∞) | `'Infinity'::DOUBLE` / `'-Infinity'::DOUBLE` | |
| `.text` | single-quoted, every `'` doubled | `'o''brien'` |
| `.blob` | every byte hex-escaped, then `::BLOB` | `'\x00\xFF\x61'::BLOB` |
| `.date` | `DATE 'YYYY-MM-DD'` | `DATE '2024-03-15'` |
| `.timestamp` | `TIMESTAMP 'YYYY-MM-DD HH:MM:SS[.ffffff]'` | `TIMESTAMP '2024-03-15 12:34:56'` |
| `.decimal` | exact digits from the unscaled value and scale — no float round-trip | `12.34`, `-0.05`, `7` |
| `.raw_sql` | inserted verbatim | `now()` |

Date/timestamp/decimal rendering reuses `writeDate` / `writeTimestamp` /
`writeDecimal` from [`../../src/types/value.zig`](../../src/types/value.zig), so
there is exactly one implementation and no drift between how a value prints and
how a parameter binds.

### ⚠️ WARNING: `.raw_sql` is inserted verbatim

> **`.raw_sql` is not escaped, quoted, or validated in any way. Never build one
> from untrusted input.**
>
> It is an escape hatch for expressions — `now()`, a column reference, a cast — and
> it is the *only* `Param` variant that is not injection-safe. Every other variant
> renders to a self-contained literal that cannot alter the statement's shape. If
> the value came from a user, a request body, a filename, a config file you did
> not write, or any network peer, it does not belong in `.raw_sql`.

```zig
// Fine: a literal your code chose.
try client.execParams("INSERT INTO t VALUES (?, ?)", &.{
    Param.int(1), .{ .raw_sql = "now()" },
});

// Catastrophic: user input as SQL.
// .{ .raw_sql = user_input }   <-- never do this
```

### Strictness rules

`bind(allocator, sql, params) Error![]u8` returns freshly allocated SQL owned by
the caller. It applies all of these:

1. **UTF-8 validation.** A `.text` parameter that is not valid UTF-8 is
   `error.InvalidUtf8`, so a malformed byte sequence cannot produce a surprising
   parse on the server.
2. **NUL rejection.** A `.text` parameter containing a `0` byte is
   `error.UnsupportedParameter` — DuckDB cannot carry NUL inside a string literal.
3. **`''` escaping.** Every `'` in a `.text` value is doubled, so a classic
   injection payload stays inside the literal:
   `"'; DROP TABLE users; --"` renders as `'''; DROP TABLE users; --'`, one
   quoted string, statement shape unchanged.
4. **`?` in these regions is data, not a placeholder** — the scanner copies each
   region through untouched:
   - single-quoted string literals `'...'`, honouring `''` escapes (so
     `'a''?b'` stays intact);
   - double-quoted identifiers `"weird?col"`;
   - dollar-quoted strings `$tag$ ... $tag$`, where the tag may contain only
     alphanumerics and `_`;
   - `--` line comments, to end of line;
   - `/* ... */` block comments (unterminated ones run to end of input).
5. **Exact count match.** Too many placeholders *and* too few are both
   `error.ParameterCountMismatch` — it means the caller and the query disagree
   about the shape of the statement. `bind("SELECT 1", &.{one_param})` fails too.
6. **Exact literal forms** for the cases a naive format would ruin: `NaN` and
   `±Infinity` get explicit quoted-cast forms, 128-bit integers print in full
   precision, and `DECIMAL` is rendered digit-exactly from its unscaled value and
   scale rather than round-tripped through a float.

Nesting is *not* tracked: block comments do not nest, and the scanner is a single
pass. That matches SQL semantics for the constructs above.

### `params.Error`

`error{ ParameterCountMismatch, UnsupportedParameter, InvalidUtf8 } ||
std.mem.Allocator.Error`.

---

## 6. `Pool`

Quack gives each connection its own server-side session and result cursor, so a
single `Client` can only have one query in flight. A server handling several
concurrent requests needs several connections. The pool is mutex-guarded and safe
to share between threads; it holds no global state, so several pools can coexist.

### `Pool.Options`

| Field | Type | Default | Meaning |
|-------|------|---------|---------|
| `allocator` | `std.mem.Allocator` | *required* | Allocates the pool's own lists and each `Client` |
| `endpoint` | `[]const u8` | *required* | Passed to every pooled `Client` |
| `token` | `[]const u8` | `""` | Passed to every pooled `Client` |
| `transport` | `Transport` | *required* | **Shared** by every connection; must be thread-safe if the pool is. `NativeTransport` is, because `std.http.Client` pools its own sockets thread-safely |
| `io` | `std.Io` | *required* | Used for the pool's own blocking waits. Pass the same `Io` the transport uses; `std.Io.Threaded` is the usual choice |
| `headers` | `[]const Header` | `&.{}` | Forwarded to each `Client` |
| `timeout_ms` | `?u32` | `null` | Forwarded to each `Client` |
| `max_response_bytes` | `usize` | `256 * 1024 * 1024` | Forwarded to each `Client` |
| `observer` | `?Observer` | `null` | Forwarded to each `Client` |
| `max_connections` | `usize` | `8` | Hard cap on live connections. `0` makes `init` return `error.PoolExhausted` |
| `min_connections` | `usize` | `0` | Opened eagerly at `init` (clamped to `max_connections`); the rest are created on demand |
| `wait_policy` | `WaitPolicy` | `.wait` | What `acquire` does when saturated |
| `on_deinit_wait` | `?*const fn (ctx: ?*anyopaque, outstanding: usize) void` | `null` | Called by `deinit` when it has to block on outstanding leases |
| `observer_ctx` | `?*anyopaque` | `null` | Opaque context passed to `on_deinit_wait` |

### `WaitPolicy`

| Value | Behaviour |
|-------|-----------|
| `.wait` | Block until a connection is released (or the cancel token fires) |
| `.fail` | Return `error.PoolExhausted` immediately — for a request handler that would rather shed load than queue |

### Methods

```zig
pub fn init(options: Options) Error!Pool
pub fn acquire(self: *Pool, cancel: ?*CancelToken) Error!Lease
pub fn snapshot(self: *Pool) Stats
pub fn deinit(self: *Pool) void
```

`acquire` pops an idle connection, or creates one if below `max_connections`
(creating a `Client` does no I/O — the handshake happens lazily on first query —
so it is fine under the lock), or applies `wait_policy`. It checks the cancel
token on every loop iteration, returning `error.Cancelled`; after `deinit` it
returns `error.PoolClosed`.

### Lease lifecycle

```zig
pub const Lease = struct {
    pool: *Pool,
    client: *Client,
    released: bool = false,

    pub fn release(self: *Lease) void;
    pub fn discard(self: *Lease) void;
};
```

Modelled as an explicit handle rather than a bare `*Client` so the borrow is
visible at the call site and `defer lease.release()` reads naturally.

- `release()` returns the connection to the idle set and signals a waiter.
- `discard()` returns *and retires* it — for when the caller knows the connection
  is in a bad state (protocol desync, transport failure). The slot is freed
  immediately, so a fresh connection can take it.
- Both are guarded by `released`, so a **double release is a safe no-op** rather
  than free-list corruption. Releasing after `deinit` has returned is also safe:
  during shutdown `releaseClient` only adjusts bookkeeping and never dereferences
  the client.

```zig
var lease = try pool.acquire(null);
defer lease.release();

var result = lease.client.query("SELECT 42") catch |err| {
    lease.discard();          // don't reuse a desynced connection
    return err;
};
defer result.deinit();
```

Note that `defer lease.release()` plus a later `discard()` is fine — the second
call is the no-op.

### `deinit` waits for leases — and the self-deadlock

`deinit` sets `closed`, broadcasts to wake anyone in `acquire`, then **blocks
until every outstanding lease is returned**, because destroying a connection a
`Lease` still points at would leave that lease dangling. Each client's `deinit`
sends a `DISCONNECT`, so teardown happens outside the lock.

> **Self-deadlock hazard.** A thread that calls `pool.deinit()` while itself
> holding a lease waits on itself, forever. Release your leases before closing
> the pool.

There is no portable way to detect that from inside the pool, and a library has
no business writing to stderr, so the situation is surfaced through the caller's
own hook:

```zig
fn onDeinitWait(ctx: ?*anyopaque, outstanding: usize) void {
    _ = ctx;
    std.debug.panic("pool.deinit() blocked on {d} outstanding lease(s)", .{outstanding});
}

var pool = try quackling.Pool.init(.{
    .allocator = allocator,
    .endpoint = "quack:localhost:9494",
    .transport = http.transport(),
    .io = threaded.io(),
    .max_connections = 8,
    .on_deinit_wait = onDeinitWait,
});
```

`on_deinit_wait` is called **once**, with the count still out, only when
`leased > 0` at the moment `deinit` starts. Leaving it `null` makes `deinit`
wait silently. Only the caller can tell a legitimate concurrent release from a
leaked lease, so the policy (log, assert, panic) is yours.

### `snapshot()`

Returns a consistent `Pool.Stats` under the lock:

| Field | Meaning |
|-------|---------|
| `total` | Connections owned by the pool, idle or leased |
| `in_use` | Currently leased out |
| `idle` | Ready to hand out |
| `acquires` | Cumulative successful acquires |
| `creates` | Cumulative connections created |
| `discards` | Cumulative `discard()` calls |
| `waits` | Times `acquire` had to block |
| `timeouts` | Times `acquire` returned `error.PoolExhausted` under `.fail` |

### `Pool.Error`

`errors.QueryError || error{ PoolExhausted, PoolClosed }`.

---

## 7. `Transport`

The protocol codec never touches a socket: it hands a request body to a
`Transport` and gets a response body back. That single indirection is what lets
the same codec run over native TCP, browser `fetch()`, or an in-memory mock. It
is a vtable rather than a comptime interface so a client can hold a transport
chosen at runtime, and so `Client` is not generic over it.

### The interface to implement

```zig
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, req: Request) Error!Response,
        close: ?*const fn (ptr: *anyopaque) void = null,
    };

    pub fn send(self: Transport, allocator: std.mem.Allocator, req: Request) Error!Response;
    pub fn close(self: Transport) void;   // no-op when the vtable slot is null
};

pub const Request = struct {
    url: []const u8,            // absolute, e.g. http://localhost:9494/quack
    body: []const u8,
    content_type: []const u8,   // "application/vnd.duckdb"
    headers: []const Header = &.{},
    timeout_ms: ?u32 = null,
    cancel: ?*CancelToken = null,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
    owned: bool = false,
    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void;
};

pub const Header = struct { name: []const u8, value: []const u8 };
```

`Response.owned` makes the lifetime explicit: a transport that can hand back a
borrowed view of its own buffer sets `owned = false` and avoids a copy; one that
allocates sets `owned = true` and the caller frees. That keeps the zero-copy path
available without ambiguity.

Implementation checklist: perform one POST round trip to `req.url` with
`req.content_type`; honour `req.headers`; check `req.cancel` and return
`error.Cancelled`; return the real HTTP status (the `Client` maps non-2xx to
`error.HttpError` itself, recording the status in `last_error.http_status`); set
`owned` correctly. Your `send` must return a member of `transport.Error`.

```zig
const MyTransport = struct {
    fn sendFn(ptr: *anyopaque, allocator: std.mem.Allocator, req: Request) transport.Error!Response {
        const self: *MyTransport = @ptrCast(@alignCast(ptr));
        _ = self; _ = allocator; _ = req;
        return .{ .status = 200, .body = "...", .owned = false };
    }
    pub fn transport(self: *MyTransport) quackling.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = sendFn } };
    }
};
```

### `CancelToken`

```zig
pub const CancelToken = struct {
    flag: std.atomic.Value(bool) = .init(false),
    pub fn cancel(self: *CancelToken) void;
    pub fn isCancelled(self: *const CancelToken) bool;
    pub fn reset(self: *CancelToken) void;
};
```

Deliberately just an atomic bool: it works without a runtime, is safe to set from
another thread or from a signal handler, and imposes no async model on the caller.
Cancellation is **cooperative** — it is observed by `Result.nextChunk`,
`Pool.acquire`, and whatever the transport checks. It does not abort a syscall
already in flight.

```zig
var token = quackling.CancelToken{};
var result = try client.queryWithCancel("SELECT * FROM huge", &token);
defer result.deinit();
// from another thread: token.cancel();
while (result.nextChunk() catch |e| switch (e) {
    error.Cancelled => null,
    else => return e,
}) |chunk| { _ = chunk; }
```

### `MockTransport`

Replays canned responses. Used by the golden tests and available to library users
for testing their own code without a server.

| Field | Type | Default | Meaning |
|-------|------|---------|---------|
| `responses` | `[]const []const u8` | *required* | Handed out in order, one per `send`; exhausting them yields `error.NetworkError` |
| `status` | `u16` | `200` | Returned with every response |
| `sent` | `std.ArrayList([]const u8)` | `.empty` | Captured request bodies, when `record_allocator` is set |
| `record_allocator` | `?std.mem.Allocator` | `null` | Enables capture; freed by `deinit` |
| `index` | `usize` | `0` | Next response to hand out |
| `fail_with` | `?Error` | `null` | When set, `send` returns this error instead of a response |

```zig
var mock = quackling.MockTransport{
    .responses = &.{ connect_fixture, prepare_fixture },
    .record_allocator = allocator,
};
defer mock.deinit();

var client = try quackling.Client.init(.{
    .allocator = allocator,
    .endpoint = "quack:localhost:9494",
    .transport = mock.transport(),
});
defer client.deinit();
```

Responses are returned with `owned = false` (the fixture outlives the response),
and a cancelled token short-circuits before anything is recorded.

### `NativeTransport`

Native HTTP over `std.http.Client` — pure Zig standard library, no libcurl, no C
dependency. This is the only place in the library that knows sockets exist, and
the protocol core never imports it.

```zig
pub const Options = struct {
    max_response_bytes: usize = 256 * 1024 * 1024,
    timeout_ms: ?u32 = null,   // reserved; std.http.Client has no granular hook yet
};

pub fn init(allocator: std.mem.Allocator, options: Options) !NativeTransport
pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io, options: Options) NativeTransport
pub fn deinit(self: *NativeTransport) void
pub fn transport(self: *NativeTransport) Transport
```

`init` creates and owns a `std.Io.Threaded`. Callers who already run an event loop
should use `initWithIo` and pass their own `Io` — that is the seam through which
io_uring/epoll/kqueue backends arrive. `timeout_ms` is currently reserved:
`std.http.Client` exposes no granular timeout hook, so use `CancelToken` for
bounded waits.

> **wasm:** `quackling.NativeTransport` is a `@compileError` on wasm targets
> (`builtin.target.cpu.arch.isWasm()`). Supply your own `Transport` — e.g. the
> browser `fetch` bridge in `src/wasm` — and the protocol core compiles for
> native, WASI and freestanding wasm32 alike.

---

## 8. Error handling

Errors are grouped by *cause* so a caller can react differently to "the network
broke", "the server rejected my SQL" and "this response is not valid Quack". Zig
error values carry no payload, so detailed server text lives alongside them in
`ErrorInfo`, reachable via `client.lastError()`.

`Client.Error` and `Result.Error` are both `errors.QueryError`:

```zig
pub const QueryError = TransportError || ProtocolError || SerializationError ||
    AuthenticationError || ServerError || UnsupportedError || UriError ||
    ParameterError || std.mem.Allocator.Error || error{ColumnOutOfRange};
```

Defined once, rather than assembled by `||` at each layer — otherwise adding one
variant means chasing it through every intermediate signature.

### `TransportError`

| Error | When | Recommended response |
|-------|------|---------------------|
| `ConnectionFailed` | DNS/TCP/connect failure | Retry with backoff; `lease.discard()` if pooled |
| `Timeout` | Transport deadline expired | Retry, or raise `timeout_ms` |
| `HttpError` | Non-2xx status. `client.last_error.http_status` holds it | Inspect the status: 4xx is usually config/auth, 5xx server-side |
| `ResponseTooLarge` | Body exceeded `max_response_bytes` | Narrow the query, or raise the limit deliberately |
| `TlsError` | TLS handshake/verification failure | Fix certificates/proxy config; do not retry blindly |
| `InvalidUrl` | Transport could not parse the URL | Programming/config error |
| `Cancelled` | `CancelToken` was set | Expected on cancellation; clean up and stop |
| `Unsupported` | The transport cannot perform the operation | Programming error in transport selection |
| `NetworkError` | Other network failure (incl. `MockTransport` exhaustion) | Retry with backoff |

### `ProtocolError`

| Error | When | Recommended response |
|-------|------|---------------------|
| `UnexpectedMessageType` | Response was not the message type the exchange required (also: `CONNECTION_RESPONSE` with no session id) | Treat the connection as desynced; discard it |
| `UnknownMessageType` | Unrecognised message type byte | Version mismatch or corruption; discard the connection |
| `UnsupportedProtocolVersion` | Server's `quack_version` outside `[1, 1]` | Upgrade client or server; do not retry |
| `NotConnected` | A request needed a connection id we do not have | Call `connect()`, or let `query` do it |
| `ResultClosed` | Use of a result already drained or closed | Programming error |
| `ResultSuperseded` | A newer query on the same client reset the server-side cursor | Finish or `deinit` a result before the next query, or use a separate connection (see `Pool`) |
| `FetchLimitExceeded` | Reserved for exceeding `Result.max_fetches` (see the caveat in [§3](#max_fetches)) | Treat the peer as broken; stop |

### `SerializationError`

`UnexpectedEndOfBuffer`, `VarIntOverflow`, `LengthLimitExceeded`,
`UnexpectedFieldId`, `UnexpectedField`, `MalformedVector`, `RowCountTooLarge`.

The bytes themselves were malformed: a truncated body, a varint too wide for its
type, a length past a configured limit, a field id the decoder does not model at
that position, a vector payload inconsistent with its type and row count, or a
row count that overflows when multiplied by a width. **Recommended response:**
this is either corruption or an upstream format change — discard the connection
and file it as a bug rather than retrying. Golden fixtures in `tests/fixtures/`
exist so a format change surfaces here as a test failure rather than a silent
misread.

### `AuthenticationError` and `ServerError`

| Error | When | Recommended response |
|-------|------|---------------------|
| `AuthenticationFailed` | Server's error text matched `"authenticat"` / `"invalid token"` / `"unauthorized"` | Fix the token; do not retry |
| `ServerError` | The server executed the request and reported a failure (bad SQL, constraint violation, catalog error) | Read `client.lastError()` for DuckDB's verbatim message and surface it. The connection remains usable |

Because auth failures arrive as ordinary error responses, the only available
signal is the text. Matching is deliberately narrow: a false negative just reports
`ServerError`, which is still accurate.

### `UnsupportedError`

| Error | When | Recommended response |
|-------|------|---------------------|
| `UnsupportedType` | A nested type reached through `getValue`, or a type id this client does not model | Use the vector accessors ([TYPES.md §7](./TYPES.md#7-nested-types)), or cast the column server-side |
| `UnsupportedVectorType` | `VectorType.fsst`, or an unknown encoding | Should be impossible ([TYPES.md §8](./TYPES.md#why-fsst-is-deliberately-unimplemented)); file a bug |

### `UriError` and `ParameterError`

| Error | When | Recommended response |
|-------|------|---------------------|
| `InvalidUrl` | Endpoint had embedded credentials (`@`), a malformed IPv6 bracket, or a control character / space in the host | Fix the endpoint string |
| `EmptyHost` | Empty input, or an empty host component | Fix the endpoint string |
| `InvalidPort` | Port empty, non-numeric, `0`, or above 65535 | Fix the endpoint string |
| `ParameterCountMismatch` | Placeholder count ≠ argument count | Programming error |
| `UnsupportedParameter` | A `.text` value contained a NUL | Sanitise the input |
| `InvalidUtf8` | A `.text` value was not valid UTF-8 | Use `.blob` for binary data |

Plus `error.ColumnOutOfRange` from `DataChunk.getValue`, and
`std.mem.Allocator.Error`.

### `ErrorInfo`

```zig
pub const ErrorInfo = struct {
    allocator: ?std.mem.Allocator = null,
    message: []const u8 = "",        // server-supplied, owned when allocator is set
    http_status: ?u16 = null,        // set when the failure was at that layer
    pub fn deinit(self: *ErrorInfo) void;
    pub fn set(self: *ErrorInfo, allocator: std.mem.Allocator, msg: []const u8) !void;
};
```

Reachable as `client.last_error`; `client.lastError()` returns just the message.
`set` replaces (and frees) any previous message.

### Idiomatic handling

```zig
var result = client.query(sql) catch |err| switch (err) {
    error.ServerError => {
        // DuckDB's own message: catalog error, syntax error, constraint, ...
        std.log.err("query failed: {s}", .{client.lastError()});
        return err;
    },
    error.AuthenticationFailed => return err,             // no point retrying
    error.ResultSuperseded => unreachable,                // caller-side bug
    error.ConnectionFailed, error.Timeout, error.NetworkError => {
        return retryLater(err);
    },
    else => return err,
};
defer result.deinit();
```

---

## 9. `Stats` and `Observer`

Two mechanisms, both dependency-free. No logging framework is imported and
nothing is written anywhere by default — in particular the client **never logs the
auth token**.

### `Stats`

`client.stats` is a plain struct you may read at any time. All `u64`:

| Field | Incremented when |
|-------|-----------------|
| `connects` | A handshake succeeded |
| `requests` | A transport round trip returned a response |
| `queries` | A `PREPARE` succeeded |
| `fetches` | A `FETCH` succeeded |
| `chunks_received` | Each chunk handed out by `nextChunk` |
| `rows_received` | By each chunk's `row_count` |
| `bytes_sent` | By the request body length, per round trip |
| `bytes_received` | By the response body length, per round trip |
| `server_errors` | An `ERROR_RESPONSE` arrived for a PREPARE or FETCH |
| `transport_errors` | The transport failed, or a non-2xx status arrived |
| `protocol_errors` | Declared for protocol-level failures |

```zig
pub fn reset(self: *Stats) void
pub fn format(self: Stats, w: *std.Io.Writer) std.Io.Writer.Error!void
```

`format` prints one line:
`requests=… queries=… fetches=… chunks=… rows=… sent=…B recv=…B errors=s/t/p`.

```zig
std.debug.print("{f}\n", .{client.stats});
```

> **Verified caveat:** `protocol_errors` is declared and printed but never
> incremented in the current source. `connects` counts only *successful*
> handshakes.

### `Observer`

Per-request hooks. Kept as a struct of function pointers rather than an interface
so a caller can supply just the one hook they care about; every field is optional
and the client checks before calling.

```zig
pub const Observer = struct {
    ctx: ?*anyopaque = null,
    on_request_start: ?*const fn (ctx: ?*anyopaque, bytes: usize) void = null,
    on_request_end: ?*const fn (ctx: ?*anyopaque, bytes: usize, failed: bool) void = null,
    on_chunk: ?*const fn (ctx: ?*anyopaque, rows: usize) void = null,

    pub fn onRequestStart(self: Observer, bytes: usize) void;
    pub fn onRequestEnd(self: Observer, bytes: usize, failed: bool) void;
    pub fn onChunk(self: Observer, rows: usize) void;
};
```

| Hook | Called | Arguments |
|------|--------|-----------|
| `on_request_start` | Before every transport `send` | Request body length |
| `on_request_end` | After every transport `send` | Response body length (`0` on failure), and `failed` |
| `on_chunk` | Each time `nextChunk` hands out a chunk | That chunk's row count |

Hooks are called on the calling thread, synchronously, inside the request path —
keep them cheap and non-blocking. `Pool` forwards its `observer` to every pooled
`Client`, so a shared observer must be thread-safe.

```zig
const Metrics = struct {
    requests: std.atomic.Value(u64) = .init(0),
    rows: std.atomic.Value(u64) = .init(0),

    fn onStart(ctx: ?*anyopaque, bytes: usize) void {
        _ = bytes;
        const self: *Metrics = @ptrCast(@alignCast(ctx.?));
        _ = self.requests.fetchAdd(1, .monotonic);
    }
    fn onChunk(ctx: ?*anyopaque, rows: usize) void {
        const self: *Metrics = @ptrCast(@alignCast(ctx.?));
        _ = self.rows.fetchAdd(rows, .monotonic);
    }
};

var metrics = Metrics{};
var client = try quackling.Client.init(.{
    .allocator = allocator,
    .endpoint = "quack:localhost:9494",
    .transport = http.transport(),
    .observer = .{
        .ctx = &metrics,
        .on_request_start = Metrics.onStart,
        .on_chunk = Metrics.onChunk,
    },
});
```

---

## 10. Endpoint forms

`Client.init` runs `uri.parse` on `options.endpoint` and then `toHttpUrl`, which
appends the protocol's fixed path `/quack`. See
[`../../src/uri.zig`](../../src/uri.zig).

### Accepted

| Form | Result |
|------|--------|
| `quack:host` | `http://host:9494/quack` |
| `quack://host` | same |
| `quack:host:1234` | `http://host:1234/quack` |
| `http://host` | `http://host:9494/quack` |
| `http://host:9494` | `http://host:9494/quack` |
| `https://host` | `https://host:9494/quack` — scheme is honoured |
| `host:9494` | `http://host:9494/quack` — no scheme means `http` |
| `quack:[::1]:9494` | `http://[::1]:9494/quack` — brackets preserved |
| `quack:::1` | bare IPv6 with several colons and no port; the whole string is the host and it is re-bracketed on output |
| `http://host:9494/some/path?x=1` | path and query are **discarded** — the endpoint path is fixed by the protocol |

Default port `9494`, default scheme `http`.

### Rejected

| Input | Error | Why |
|-------|-------|-----|
| `""` | `EmptyHost` | |
| `quack:user:pass@host` | `InvalidUrl` | Embedded credentials would be silently dropped, and a URL that looks authenticated but is not is worse than an error |
| `quack:host:0` | `InvalidPort` | Port `0` is not a valid destination |
| `quack:host:99999` | `InvalidPort` | Out of `u16` range |
| `quack:host:abc` | `InvalidPort` | Not numeric |
| `quack:ho st` | `InvalidUrl` | Host bytes `<= 0x20` or `0x7F` are rejected |
| `quack:host\nX` | `InvalidUrl` | Same rule — a control character must never be pasted into a URL |
| `quack:[::1` | `InvalidUrl` | Unclosed IPv6 bracket |
| `quack:[::1]x` | `InvalidUrl` | Junk after the bracket that is not `:port` |

Validation is deliberately strict: a host with control characters, spaces, or
embedded credentials is rejected rather than being pasted into a URL.

> **Security note:** the auth token travels *inside* the protocol body, and the
> Quack server itself does not terminate TLS. Use `https://` through a reverse
> proxy for anything beyond localhost.
