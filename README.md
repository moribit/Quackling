# Quackling

**English** · [日本語](README.ja.md)

A lightweight, standalone **DuckDB Quack protocol client written in Zig**,
targeting native and WebAssembly environments.

```zig
var result = try client.query("SELECT 42 AS answer");
defer result.deinit();

while (try result.nextChunk()) |chunk| {
    // vectorized processing
}
```

- **Pure Zig** — standard library only. No `libduckdb`, no C/C++ runtime, no libcurl.
- **Standalone** — the wire protocol is implemented here, not delegated to DuckDB.
- **Native + WASM** — the protocol core compiles for Linux, macOS, Windows, WASI
  and `wasm32-freestanding` from the same source.
- **Streaming, DataChunk-oriented** — results arrive as vectors, not row objects.
- **Low allocation** — bulk payloads are borrowed from the response buffer;
  decoding 5 000 `BIGINT` rows costs 9 allocations.
- **Transport-agnostic** — HTTP, browser `fetch()`, or a mock, chosen by the caller.

---

## Documentation

| Guide | Contents |
|-------|----------|
| [Server setup](docs/en/SERVER_SETUP.md) | Running `quack_serve()`, URIs, TLS, troubleshooting |
| [API reference](docs/en/API.md) | `Client`, `Result`, `typed`, `params`, `Pool`, `Transport`, errors |
| [Type support](docs/en/TYPES.md) | Every DuckDB type, NULL handling, nested access, zero-copy rules |
| [Architecture](docs/en/ARCHITECTURE.md) | Layering, session state machine, ownership, streaming model |
| [Wire protocol](docs/en/PROTOCOL.md) | Byte-level Quack format reference |
| [CLI](docs/en/CLI.md) | `quackling` flags and output formats |
| [WASM](docs/en/WASM.md) | Building for wasm32, the FFI surface, browser usage |
| [Performance](docs/en/PERFORMANCE.md) | Benchmarks, method, allocation behaviour, performance traps |
| [Testing](docs/en/TESTING.md) | The six test layers and mutation testing |
| [Security](docs/en/SECURITY.md) | Threat model, resource limits, injection boundary |

日本語版のドキュメントは [docs/ja/](docs/ja/) にあります。

## What is this?

[Quack](https://duckdb.org/quack/) is DuckDB's client/server protocol: an RPC
layer over HTTP that lets a client run SQL against a remote DuckDB instance.
Quackling speaks that protocol directly from Zig.

Concretely:

```
Zig application
      │
      ▼
Quack Client  (this library)
      │  HTTP / HTTPS
      ▼
DuckDB Quack Server
```

## Why not DuckDB-Wasm?

They solve different problems and are not competitors.

|                | DuckDB-Wasm                       | Quackling                              |
|----------------|-----------------------------------|----------------------------------------|
| What it is     | The DuckDB **engine**, in the browser | A **client** for a remote DuckDB    |
| Where SQL runs | Locally, in the browser           | On the server                          |
| Payload        | Tens of MB of engine              | ~73 KB WASM module                     |
| Data location  | Must reach the browser            | Stays on the server                    |
| Use it when    | You want local, offline analytics | You have a shared/large remote database |

Reach for DuckDB-Wasm to run a database in the browser. Reach for Quackling to
*talk to* one — from a CLI, a server, an embedded target, or a browser tab that
should not download an engine.

## Why Quack?

Quack is HTTP-based, needs no proprietary driver, preserves DuckDB's full type
system losslessly, and is designed for a single round trip per query. That makes
it a good fit for a small, dependency-free client.

## Installation

### CLI

```sh
curl -fsSL https://raw.githubusercontent.com/OWNER/Quackling/main/scripts/install.sh | sh
```

```powershell
irm https://raw.githubusercontent.com/OWNER/Quackling/main/scripts/install.ps1 | iex
```

Downloads a static binary for your platform, verifies its SHA-256, and installs
to a user-owned directory — no `sudo`, and no compiler needed. Linux builds are
static musl, so one binary covers glibc and musl distros alike.

You get two names for one binary: `quackling`, and `qkl` as a shorter alias for
typing. `--version` prints the canonical name either way, so scripts parse one
string.

```sh
quackling "SELECT 42"
qkl "SELECT 42"                  # same command, 3 characters
```

```sh
# pin a version, choose a location, or build from source instead
sh install.sh --version v0.1.0
sh install.sh --bin-dir ~/bin
sh install.sh --build            # needs Zig 0.16
sh install.sh --dry-run          # show what it would do
sh install.sh --no-alias         # install only `quackling`
```

The installer refuses to proceed on a checksum mismatch, says so plainly when it
*cannot* verify rather than implying it did, runs the binary once to confirm the
platform is right, and never invokes `sudo` on your behalf — if the target needs
root it prints the exact command for you to run.

To publish those artifacts: `zig build release -Dversion=v0.1.0` cross-compiles
all six platforms into `zig-out/release/` with a matching `SHA256SUMS`.

### Library

Requires **Zig 0.16.0**.

```sh
zig fetch --save git+https://github.com/<you>/quackling
```

```zig
// build.zig
const quackling = b.dependency("quackling", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("quackling", quackling.module("quackling"));
```

## Quick start

Start a server. The `quack` extension is a pre-release extension that works on
**DuckDB v1.5.5** today — it does not require DuckDB 2.0:

```sh
duckdb
```

```sql
LOAD quack;
CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);
```

Keep that session open — the server lives only as long as the DuckDB process
does. See [Server setup](docs/en/SERVER_SETUP.md) for long-running recipes, TLS
and troubleshooting.

Then:

```zig
const std = @import("std");
const quackling = @import("quackling");

pub fn main(init: std.process.Init) !void {
    // The transport is supplied by the caller - the library never opens a
    // socket on its own.
    var http = quackling.NativeTransport.initWithIo(init.gpa, init.io, .{});
    defer http.deinit();

    var client = try quackling.Client.init(.{
        .allocator = init.gpa,
        .endpoint = "quack:localhost:9494",
        .token = "super_secret",
        .transport = http.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT 42 AS answer");
    defer result.deinit();

    const answer = (try result.scalar()).?;
    std.debug.print("answer = {f}\n", .{answer});
}
```

Or straight from the command line:

```sh
quackling --token super_secret "SELECT 42 AS answer"
```

```
┌────────┐
│ answer │
├────────┤
│ 42     │
└────────┘
```

### DataChunk is the primary API

DuckDB is vectorized, so the first-class API is too. Rows are a convenience
layer on top, not the other way round.

```zig
while (try result.nextChunk()) |chunk| {
    const col = chunk.column(0).?;

    if (col.asSlice(i64)) |slice| {
        // Truly zero-copy: `slice` aliases the response buffer.
        for (slice) |v| consume(v);
    } else if (col.isFlat(i64)) {
        // Wire payloads are not alignment-guaranteed; `at` is always safe.
        for (0..chunk.row_count) |i| consume(col.at(i64, i).?);
    }
}
```

Row-at-a-time, walking chunk boundaries transparently:

```zig
var rows = result.rows();
while (try rows.next()) |row| {
    const id = (try row.get(0)).asI64().?;
}
```

Or mapped onto a struct with comptime reflection:

```zig
const User = struct { id: i64, name: []const u8, score: f64, nickname: ?[]const u8 };

var it = try quackling.typed.iterator(User, &result);
while (try it.next()) |user| { ... }
```

`?T` fields accept NULL; a NULL in a non-optional field is an error, never a
silent zero.

Borrowed data is valid only until the next `nextChunk()`. The full ownership
rules are in [Type support](docs/en/TYPES.md).

### Query parameters

```zig
var result = try client.queryParams(
    "SELECT * FROM users WHERE id = ? AND name = ?",
    &.{ .{ .integer = 42 }, .{ .text = "o'brien" } },
);
```

Quack v1 has **no wire format for parameters** — `PrepareRequestMessage` carries
only a SQL string — so Quackling renders parameters into the SQL text
client-side, in [`src/params.zig`](src/params.zig). That places the whole safety
burden on one small, heavily-tested file, so it is strict: `''` escaping, UTF-8
validation, NUL rejection, exact placeholder/argument count matching, and `?`
inside string literals, quoted identifiers, dollar-quoted strings and `--` /
`/* */` comments is **not** treated as a placeholder.

> [!WARNING]
> `.raw_sql` is inserted verbatim by design. Never build one from untrusted input.

For server-side prepared statements, SQL-level `PREPARE` / `EXECUTE` works over
the protocol normally. Details and the full `Param` union:
[API reference](docs/en/API.md).

### One result at a time per connection

A Quack connection has exactly one server-side result cursor, and the server
discards it the moment it accepts the next `PREPARE` — whether or not that query
then succeeds. So starting a second query invalidates any result still being
streamed:

```zig
var a = try client.query("SELECT * FROM big");
var b = try client.query("SELECT 1");   // discards a's cursor server-side
_ = try a.nextChunk();                  // error.ResultSuperseded
```

Quackling detects this instead of letting the stale result silently fetch the
new query's rows. Finish or `deinit` a result before the next query, or give
each concurrent query its own connection.

### Connection pooling

A Quack connection is a single server-side session with one result cursor, so
concurrent queries need concurrent connections:

```zig
var pool = try quackling.Pool.init(.{
    .allocator = allocator,
    .endpoint = "quack:localhost:9494",
    .token = token,
    .transport = http.transport(),
    .io = threaded.io(),
    .max_connections = 8,
});
defer pool.deinit();

var lease = try pool.acquire(null);
defer lease.release();
var result = try lease.client.query("SELECT 42");
```

The pool is mutex-guarded and safe to share across threads. `wait_policy`
chooses between blocking and shedding load (`error.PoolExhausted`) when
saturated; `lease.discard()` retires a connection instead of reusing it.

`Pool.deinit` waits for every outstanding lease to come back, because freeing a
connection a lease still points at would leave it dangling. Release your leases
before closing the pool: a caller that holds one while calling `deinit` waits on
itself. Set `on_deinit_wait` to be told when that happens — the library does not
log, so this is the hook that surfaces it. See
[API reference](docs/en/API.md).

## CLI

```sh
quackling --url quack:localhost:9494 --token secret "SELECT 42"
quackling --format json     "SELECT * FROM t"   # also: csv, ndjson, markdown
quackling --timing --stats  "SELECT 1"
quackling --version
echo "SELECT 42" | quackling                    # SQL on stdin
```

`qkl` is an alias for the same binary, so every line above also works as
`qkl ...`.

CLI-specific behaviour lives entirely in `src/cli/`; none of it leaks into the
library. Full flag and format reference: [CLI](docs/en/CLI.md).

## WASM

```sh
zig build wasm      # -> zig-out/bin/quackling.wasm  (~73 KB)
```

The protocol core has no OS, libc, thread or filesystem dependency, so the same
decoder runs in a browser with JavaScript providing `fetch()`:

`web/` is a publishable npm package: ESM entry point, `quack.d.ts` for
TypeScript, and the `.wasm` written in place by the build.

```js
import { Quack } from 'quackling';
import wasmUrl from 'quackling/quackling.wasm?url';   // Vite

const db = await Quack.connect({ wasm: wasmUrl, url: 'quack:localhost:9494', token });

await db.queryValue('SELECT 42');                     // 42

// Large results stream via FETCH, so nothing is silently truncated.
const result = await db.query('SELECT * FROM events');
for await (const row of result) render(row);
```

Bound parameters and nested types work from JS too:

```js
await db.queryAll('SELECT * FROM users WHERE id = ?', [42]);
const [row] = await db.queryAll("SELECT {'a':1} s, [1,2] l, MAP{'k':1} m");
// row.s -> {a: 1}   row.l -> [1, 2]   row.m -> Map { 'k' => 1 }
```

Nested values are walked through opaque vector handles rather than materialised
in WASM, so they cost no extra memory. Parameter escaping happens in Zig, shared
with the native client, so there is one audited implementation rather than two.

`wasm` also accepts a `Response`, raw bytes, or a compiled `WebAssembly.Module`,
so the bundler owns asset resolution rather than the app hard-coding a path.
Operations on one connection are serialized internally, because the module has a
single set of shared buffers.

See [`web/README.md`](web/README.md) for bundler recipes, the type mapping, and
current limits.

The FFI boundary is deliberately narrow: JS moves bytes in and out of linear
memory and never sees JSON. Numeric columns are read back as **TypedArray views
directly over WASM memory**, with no copy and no per-value marshalling. The whole
export surface is documented in [WASM](docs/en/WASM.md).

A runnable browser PoC is in `examples/browser/`. The build does not write into
that directory, so refresh its copy of the module and serve over HTTP —
`file://` cannot load ES modules or `.wasm`:

```sh
zig build wasm
cp web/quackling.wasm examples/browser/
python3 -m http.server 8080          # then open
                                     # http://127.0.0.1:8080/examples/browser/
```

The DuckDB server sends `Access-Control-Allow-Origin: *`, so a page served from a
different port reaches it without extra configuration.

## Architecture

Each layer depends only on the one below it. The protocol never touches a socket,
which is what makes the `wasm32-freestanding` build possible.

```
             Public API          client.zig, result.zig, typed.zig
                  ↓
        Session / state machine  client.zig
                  ↓
            Quack messages       protocol/message.zig, protocol/compat.zig
                  ↓
     DuckDB serialization codec  serialization/{reader,writer,decoder}.zig
                  ↓
       Transport abstraction     transport/transport.zig
                  ↓
      HTTP · fetch() · mock      transport/native.zig, src/wasm/exports.zig
```

```
src/
├── root.zig            public surface
├── client.zig          connection + session
├── result.zig          streaming results (chunks, rows)
├── typed.zig           comptime struct mapping
├── uri.zig             quack:/http:/https: parsing + validation
├── error.zig           error taxonomy
├── stats.zig           counters and hooks
├── protocol/
│   ├── message.zig     message encode/decode
│   └── compat.zig      every protocol constant, in one file
├── serialization/
│   ├── reader.zig      bounds-checked primitive decoding
│   ├── writer.zig      primitive encoding
│   └── decoder.zig     LogicalType / Vector / DataChunk
├── types/
│   ├── logical_type.zig, value.zig, vector.zig,
│   └── data_chunk.zig, validity.zig
├── transport/
│   ├── transport.zig   the Transport interface + MockTransport
│   └── native.zig      std.http.Client
├── cli/main.zig
└── wasm/exports.zig
```

Protocol constants (message ids, field ids, versions) are confined to
[`src/protocol/compat.zig`](src/protocol/compat.zig) and
`serialization/decoder.zig`, so tracking an upstream change is a local edit. Full
walkthrough in [Architecture](docs/en/ARCHITECTURE.md); the wire format itself is
documented in [Wire protocol](docs/en/PROTOCOL.md).

## Supported types

Every DuckDB scalar type is decoded to a `Value`: all signed and unsigned integer
widths including 128-bit, `FLOAT` / `DOUBLE` / `DECIMAL`, `VARCHAR` / `BLOB` /
`BIT` / `BIGNUM`, the full temporal family (`DATE`, `TIME`, `TIME_TZ`,
`TIMESTAMP` in s/ms/us/ns and `TIMESTAMP_TZ`, `INTERVAL`), `UUID`, `ENUM` and
`NULL` — plus NULL/validity handling for all of them.

`ENUM` resolves to its label, not the raw dictionary index:

```zig
const v = try chunk.getValue(0, 0);
v.@"enum".label;   // "happy"
v.@"enum".index;   // 2
```

`STRUCT`, `LIST`, `ARRAY`, `MAP`, `UNION` and `VARIANT` are decoded
structurally. Because the flat `Value` union cannot own nested storage, reach
them through the vector accessors (`children`, `listEntry`, `listChild`,
`mapEntry`, `unionValue`) — worked examples for each are in
[Type support](docs/en/TYPES.md).

MAP and UNION need no special decoding path: DuckDB stores a MAP as
`LIST(STRUCT(key, value))` and a UNION as a STRUCT with a hidden `UTINYINT`
tag, so they reuse the LIST and STRUCT machinery.

Vector encodings `FLAT`, `CONSTANT`, `DICTIONARY` and `SEQUENCE` are all decoded,
without expanding the compressed forms.

**FSST** is deliberately not implemented. `Vector::Serialize` in DuckDB has no
FSST branch — such a vector falls through to `ToUnifiedFormat` and is flattened
before it reaches the wire — so an FSST-encoded vector cannot arrive. Rather
than guess at an undocumented symbol-table format, the decoder returns
`error.UnsupportedVectorType` if one ever does.

Anything else this client does not model returns `error.UnsupportedType`.
Nothing is ever silently mis-decoded.

## Supported DuckDB versions

Verified against **DuckDB v1.5.5** (`quack` extension, Quack protocol version 1).
The client advertises protocol version 1 and refuses to connect to a server
outside that range rather than guessing.

## Protocol status

Quack is **beta** and upstream expects breaking changes. It graduates to stable
in DuckDB 2.0 ("Cyanoptera"), announced for Fall 2026 and not yet released; the
extension is usable today on DuckDB v1.5.5.

This client is written against the DuckDB sources (`duckdb/duckdb-quack` and
DuckDB's `BinarySerializer`) and validated byte-for-byte against a live server —
never against blog posts or guesswork. Golden fixtures captured from a real
server are committed in `tests/fixtures/`, so an upstream format change surfaces
as a test failure rather than a silent misread.

## Security

The client consumes untrusted bytes from the network, so the decoder is the whole
attack surface. Its contract: **arbitrary input produces either a successful
decode or a typed error — never a panic, an out-of-bounds read, an integer
overflow, or unbounded allocation.**

- Every decode is bounds-checked. Wire data is **never** `@ptrCast` into a
  struct; fixed-width values are read with explicit little-endian loads.
- Length and count prefixes are validated against both a configurable limit and
  the bytes actually available, before any allocation — a hostile length field
  cannot trigger a large allocation.
- Nesting depth is bounded, so a deeply nested message cannot exhaust the stack.
- Response size is capped (`max_response_bytes`), and a single result is capped at
  `Result.max_fetches` FETCH round trips. End of stream is the *server's* signal
  (an empty batch), so without a ceiling a peer that never sends one would hang
  the client indefinitely.
- URLs are validated; embedded credentials and control characters are rejected.
- Tokens are never logged, printed, or included in error messages — asserted by
  test.

> [!IMPORTANT]
> The auth token travels **inside** the protocol body, and the DuckDB server does
> not terminate TLS itself. Put a reverse proxy in front for anything beyond
> localhost.

The decoder is fuzz-tested (`tests/fuzz_test.zig`): every prefix and single-byte
corruption of every fixture, plus random and adversarial inputs, must produce a
typed error rather than a panic.

Threat model, every limit with its default, and an honest out-of-scope list:
[Security](docs/en/SECURITY.md).

## Performance

Codec only, no network, `ReleaseFast`, Apple aarch64 — reproduce with
`zig build bench`:

Median of three runs, 2026-08-19:

| benchmark              |   ns/op |     MB/s |        rows/s | allocs/op |
|------------------------|--------:|---------:|--------------:|----------:|
| decode `SELECT 42`     |     156 |    583.1 |     6 408 896 |         5 |
| decode 5k-row BIGINT   |     320 |119 732.4 |15 634 160 641 |         9 |
| decode+values 5k-row   |  16 535 |  2 315.8 |   302 391 158 |         9 |
| decode+flat 5k-row     |   9 142 |  4 188.5 |   546 913 831 |         9 |
| decode VARCHAR         |     252 |    511.4 |     3 972 458 |         7 |
| decode NULL-heavy      |     166 |    784.9 |    60 071 183 |         5 |
| decode STRUCT          |     363 |    477.8 |     2 753 054 |         9 |
| decode MAP             |     509 |    470.5 |     1 965 541 |        13 |
| encode PREPARE request |      20 |  4 446.4 |    49 077 755 |         1 |
| bind 4 parameters      |     142 |    637.6 |     7 038 051 |         1 |

Three things worth reading off this table:

- **Allocations do not scale with rows.** 5 000 rows costs 9 allocations and 1 row
  costs 5, because bulk payloads are borrowed from the response buffer rather
  than copied. Allocation tracks a result's *structure*, not its size.
- **The typed path (`at`/`asSlice`) is ~1.8× faster than the `Value` path**
  (9 142 ns vs 16 535 ns for the same 5 000 rows). Use `Value` for ergonomics,
  the typed accessors for throughput.
- **Nested types stay cheap.** A MAP costs 13 allocations regardless of how many
  entries it holds, because its keys and values are borrowed child vectors.

End to end, streaming 1 000 000 rows over loopback HTTP takes **0.49 s** in 489
chunks over 41 FETCH round trips, receiving ~16 MB of wire data — see
[`examples/streaming.zig`](examples/streaming.zig).

Peak RSS while streaming with the CLI confirms the streaming contract:
**100 k, 1 M and 5 M rows all peak at 2.8 MB.** Fifty times the data costs no
extra memory, because only one FETCH batch is resident at a time.

No optimisation in this library was made without a measurement. Full method,
per-benchmark analysis, performance traps and an explicit list of what is *not*
measured: [Performance](docs/en/PERFORMANCE.md).

## Testing

```sh
zig build test                  # 227 tests in ~10s, no server needed
zig build test-integration      # 29 tests against a live quack_serve() instance
zig build test-wasm             # WASM FFI boundary (requires node)
zig build test-web              # JS binding + Web Worker (node + a live server)
zig build bench
zig build check -Dtarget=...    # library-only build for any target

python3 scripts/mutation_test.py            # verify the tests catch real breakage
python3 scripts/mutation_test.py -k params  # just one area
python3 scripts/mutation_test.py --list     # the mutant catalogue
```

Six layers cover the client: **unit tests** (primitives, boundaries, malformed
input, URI validation, parameter escaping, pool mechanics including a
multi-threaded contention test), **golden tests** replaying real payloads
captured from a live server and asserting both the decoded values *and* that
every byte is consumed, **decoder guard tests** built from hostile structures a
real server never sends, **client tests** over a mock transport, **fuzz tests**
(~25 000 decodes of truncated, corrupted and adversarial input), and
**integration tests** against a live server that skip — not fail — when none is
reachable.

The fixtures are captured by [`scripts/capture_fixtures.py`](scripts/capture_fixtures.py),
which implements the protocol independently in Python. That keeps them a genuine
cross-check on the Zig code rather than a recording of its own output.

The test suite is itself validated by **mutation testing**
([`scripts/mutation_test.py`](scripts/mutation_test.py)). It removes each safety
guard one at a time and asserts that a test fails; a guard whose mutant
*survives* has no covering test, even though CI is green. The catalogue holds 51
mutants covering every bounds check, every injection-escaping rule, the protocol
version range, the FETCH ceiling and the pool's locking. It runs in CI and fails
the build on any unexpected survivor. One documented `EXPECTED_SURVIVORS` entry
(`pool/deinit-waits-for-leases`) cannot be observed without relying on undefined
behaviour — the reasoning is recorded in the script rather than left as a silent
pass.

A note on test-suite speed, since mutation testing runs the whole suite once per
mutant: the fuzz suite is built **ReleaseSafe**, not Debug. It performs ~25 000
decodes of mutated input, which costs ~14 s in Debug and ~0.2 s optimised — a
~680x difference driven by allocator bookkeeping and the absence of inlining,
not by the amount of work. ReleaseSafe keeps every check the fuzzing relies on
(bounds, overflow, `unreachable`), verified by reintroducing the original varint
overflow bug and confirming it still panics. Use `-Dfuzz-optimize=Debug` to
override.

That process found and fixed real defects that a green test run had hidden:

| Defect | How it would have failed in production |
|---|---|
| Unbounded FETCH loop | A server that never sends an empty batch hangs the client forever |
| Pool use-after-free | Closing a pool with leases outstanding freed connections still in use |
| Result not invalidated by a new query | A stale result silently streamed the *next* query's rows |
| Varint shift overflow | A malformed length prefix panicked instead of erroring |
| Leaks on nested-type error paths | Malformed STRUCT/LIST responses leaked memory |
| Missing lower-bound version check | A server below the supported range was accepted |

Mutation testing runs the whole suite once per mutant and is therefore slow;
[Testing](docs/en/TESTING.md) explains why and how to scope it down.

Regenerate fixtures against a new DuckDB with `python3 scripts/capture_fixtures.py`.

## Bulk insert

`APPEND_REQUEST` sends a whole DataChunk rather than an INSERT statement:

```zig
const ids = [_]quackling.Value{ .{ .integer = 1 }, .{ .integer = 2 } };
const names = [_]quackling.Value{ .{ .varchar = "a" }, .null };
try client.append("events", &.{
    .{ .type = .{ .id = .integer }, .values = &ids },
    .{ .type = .{ .id = .varchar }, .values = &names },
});
```

Measured against one parameterised INSERT per row on the same server:
**20 480 rows in 10 ms (1.97M rows/s, 10 requests) versus 3 821 ms (5.4k rows/s,
20 480 requests) — ~370x.** The data is already typed, so no SQL is parsed and
one request carries a whole chunk. Values go over in binary, so this path
involves no SQL escaping at all.

The encoder (`serialization/encoder.zig`) is the mirror of the decoder, and its
tests assert that everything it emits decodes back identically — which is what
keeps the two halves from drifting.

## Roadmap

- Async I/O: the `Transport` interface and `std.Io` seam are already in place
- Concurrent FETCH across pooled connections
- Arrow interoperability / Arrow IPC output (kept out of `web/` on purpose:
  `apache-arrow` is ~8 MB and that package has zero dependencies)
- Server-side prepared statements and explicit transactions
- Interactive CLI shell
- Akamata adapter, as a separate package — the transport adapter and an
  `am.db.Db` shim are both **built and verified** against a real Akamata
  checkout (including Cloudflare Workers), so what remains is packaging;
  see [docs/en/AKAMATA.md](docs/en/AKAMATA.md)

## Design constraints

Two rules shaped this codebase and are worth stating plainly:

1. **The core library depends on nothing above it.** No CLI, WASM, or framework
   concern reaches into `src/protocol`, `src/serialization` or `src/types`.
   Akamata (and anything else) can become a *user* of this library; the library
   never becomes a user of them.
2. **Untrusted bytes are treated as untrusted.** The decoder either produces a
   value or a typed error. It does not guess, and it does not reinterpret wire
   data as native structs.

## License

MIT
