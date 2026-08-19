# quackling (web)

DuckDB Quack protocol client for the browser. The wire protocol is decoded by
Zig compiled to WebAssembly (~37 KB); JavaScript only supplies `fetch()`.

This is **not** DuckDB in the browser. It is a thin client that talks to a remote
DuckDB running `quack_serve()`. Your data stays on the server, and the page
downloads 37 KB instead of an engine.

## Install

```sh
npm install quackling
```

Or build from source — `zig build wasm` writes `web/quackling.wasm` in place, so
this directory is publishable as-is.

## Quick start

```js
import { Quack } from 'quackling';
import wasmUrl from 'quackling/quackling.wasm?url';   // Vite; see below for others

const db = await Quack.connect({
  wasm: wasmUrl,
  url: 'quack:localhost:9494',
  token: import.meta.env.VITE_QUACK_TOKEN,
});

const answer = await db.queryValue('SELECT 42');             // 42
const rows   = await db.queryAll('SELECT * FROM t LIMIT 10'); // [{...}, ...]

// Bound parameters
const user = await db.queryAll('SELECT * FROM users WHERE id = ?', [42]);
```

### Parameters

```js
await db.queryAll('SELECT * FROM t WHERE name = ? AND at > ?', ["o'brien", new Date()]);
```

`?` placeholders are filled from the array. Quack v1 has no wire format for
parameters, so they are rendered into the SQL text — by the **Zig**
implementation the native client uses, not a second copy in JavaScript. That
keeps one audited escaping path (covered by the mutation suite) instead of two
that can drift.

Accepted: `null`, `boolean`, `number`, `bigint`, `string`, `Uint8Array`, `Date`.
`bigint` goes over as exact decimal text, so 128-bit values lose no precision on
the way in either. A placeholder/argument count mismatch is caught before
anything is sent.

### Nested types

```js
const [row] = await db.queryAll(`
  SELECT {'a': 1, 'b': 'x'} s, [10,20,30] l, MAP{'k': 1} m
`);
row.s   // { a: 1, b: 'x' }
row.l   // [10, 20, 30]
row.m   // Map { 'k' => 1 }
```

`STRUCT`/`VARIANT` become objects, `LIST`/`ARRAY` arrays, `MAP` a real `Map`, and
`UNION` its active member. Arbitrary nesting works (`[{'a':1}]`,
`MAP{'k':[1,2]}`). Nothing is copied inside WASM: JavaScript walks the decoded
vector tree through opaque handles, so a nested column costs no more memory than
the batch it lives in.

## Loading the `.wasm`

`wasm` accepts a URL, a `Response`, raw bytes, or a compiled
`WebAssembly.Module`, so the bundler can own asset resolution rather than you
hard-coding a path:

```js
// Vite / Rollup
import wasmUrl from 'quackling/quackling.wasm?url';
await Quack.connect({ wasm: wasmUrl, url });

// webpack 5 (asset modules)
const wasmUrl = new URL('quackling/quackling.wasm', import.meta.url);
await Quack.connect({ wasm: wasmUrl, url });

// Next.js / any server-rendered app: fetch it at runtime
await Quack.connect({ wasm: '/quackling.wasm', url });

// Node / tests: pass the bytes
import { readFileSync } from 'node:fs';
await Quack.connect({ wasm: readFileSync('./quackling.wasm'), url });
```

Streaming instantiation is used when the server sends
`Content-Type: application/wasm`, and it falls back to the buffer path otherwise
— so a static host that gets the MIME type wrong still works.

## Streaming large results

A Quack result arrives in batches. `query()` returns after the first one and the
rest is pulled with FETCH round trips as you iterate, so peak memory tracks one
batch rather than the whole result.

```js
const result = await db.query('SELECT * FROM events');   // millions of rows

for await (const row of result) {
  render(row);            // crosses chunk and batch boundaries transparently
}
```

Stop early whenever you like:

```js
for await (const row of result) {
  if (enough(row)) { result.close(); break; }
}
```

> `queryAll()` materialises everything. It streams internally, so it is correct
> for large results — but it still holds them all in memory. Prefer iteration.

### Vectorized access

DuckDB is column-oriented, and so is this. For numeric columns you can read a
`TypedArray` that **views WASM memory directly**, with no copy and no
per-value conversion:

```js
for await (const chunk of result.chunks()) {
  const values = chunk.array(0);        // e.g. Int32Array over wasm memory
  if (values) {
    total += values.reduce((a, b) => a + b, 0);
  } else {
    // Not a flat numeric column, or the payload is misaligned for this element
    // type (the wire format carries no alignment guarantee).
    for (let r = 0; r < chunk.rowCount; r++) total += chunk.value(0, r);
  }
}
```

The view is invalidated by the next iteration — copy it if you need to keep it.

## Bulk insert

`append()` sends a whole DataChunk instead of an INSERT statement. Measured
against one parameterised INSERT per row on the same server: **~370x the
throughput** (1.97M rows/s vs 5.4k), because the data is already typed and the
server re-parses no SQL.

```js
import { Quack, TYPE } from 'quackling';

await db.append('events', rows, [
  { name: 'id',   type: TYPE.INTEGER },
  { name: 'name', type: TYPE.VARCHAR },
  { name: 'at',   type: TYPE.TIMESTAMP },
]);
```

`rows` may be objects (keyed by `column.name`) or arrays (positional). `columns`
is required rather than inferred: the server rejects a schema mismatch, and
guessing from the first row would pick the wrong type as soon as a `NULL` appears
in it. The table must already exist.

Inputs larger than one DataChunk (2048 rows) are chunked automatically. Values
are sent in binary, so there is no SQL escaping in this path at all.

For `DECIMAL`, give the precision so the wire format can pick a storage width:

```js
await db.append('t', rows, [{ name: 'amount', type: TYPE.DECIMAL, width: 10, scale: 2 }]);
```

## Web Workers

Decoding runs on whichever thread calls it, so a very large result can occupy the
main thread. The fix is to put the connection in a Worker — but note *how*:

**Do not build a generic `postMessage` bridge.** Every value would have to be
structured-cloned across the thread boundary, which throws away the zero-copy
decode that is the reason to use this client, and often costs more than the
decode it was meant to offload.

Instead let the Worker **reduce**. The app knows what it actually needs — an
aggregate, a 100-row page, a chart series — so compute that inside the Worker and
post only the answer:

```js
// worker.js
import { Quack } from 'quackling';
let db;
self.onmessage = async ({ data }) => {
  if (data.op === 'connect') {
    db = await Quack.connect({ wasm: data.wasmUrl, url: data.url, token: data.token });
    return self.postMessage({ id: data.id, ok: true });
  }
  if (data.op === 'sum') {
    const result = await db.query(data.sql);
    let total = 0n;
    for await (const chunk of result.chunks()) {
      const arr = chunk.array(0);              // TypedArray over WASM memory
      for (let i = 0; i < arr.length; i++) total += BigInt(arr[i]);
    }
    // One number crosses the boundary, not a million rows.
    self.postMessage({ id: data.id, ok: true, sum: total.toString() });
  }
};
```

The binding has no DOM dependencies, so it runs in a Worker unchanged. A complete
recipe is in [`examples/browser/worker.js`](../examples/browser/worker.js), and
`web/test/worker.test.mjs` runs that exact file in a real worker thread — summing
1,000,000 rows and returning a single value.

## One result at a time

A connection is one server-side session with **one** result cursor. Opening a
second query while a result is still streaming would make the server discard the
first cursor, so it is refused:

```js
const a = await db.query('SELECT * FROM big');
await db.query('SELECT 1');   // QuackError: a previous result is still open
```

Finish iterating, or call `a.close()`. For genuinely concurrent queries, open
more than one connection.

Overlapping calls are otherwise safe: the module has a single set of shared
buffers, so every operation is serialized internally. `Promise.all` of sixteen
`queryValue()` calls returns sixteen correct answers rather than sixteen copies
of whichever one won a race.

## Types

Ships with `quack.d.ts`. `strict` mode is clean, and misuse is a compile error:

```ts
import { Quack, type QuackRow } from 'quackling';

const db = await Quack.connect({ wasm, url: 'quack:localhost:9494' });
const rows: QuackRow[] = await db.queryAll('SELECT 1 AS a');
```

Value mapping:

| DuckDB | JavaScript |
|---|---|
| `BOOLEAN` | `boolean` |
| `TINYINT`…`INTEGER`, `FLOAT`, `DOUBLE` | `number` |
| `BIGINT`, `UBIGINT` | `number` when exactly representable, else `bigint` |
| `HUGEINT`, `UHUGEINT` | `bigint` (exact; 128-bit does not fit `number`) |
| `DECIMAL` | `string` (exact digits; see below) |
| `VARCHAR`, `DATE`, `TIME`, `TIMESTAMP`, `UUID`, `INTERVAL`, `ENUM` | `string` (canonical text, e.g. `"2024-03-15"`; `ENUM` gives its label) |
| `BLOB`, `BIGNUM` | `Uint8Array` |
| `NULL` | `null` |
| `STRUCT`, `VARIANT` | plain object `{a: 1, b: "x"}` |
| `LIST`, `ARRAY` | array `[1, 2, 3]` |
| `MAP` | `Map` (so non-string keys survive) |
| `UNION` | the active member's value |

Precision is preserved rather than quietly lost:

- 64-bit integers become `bigint` past `Number.MAX_SAFE_INTEGER`.
- 128-bit integers (`HUGEINT`, `UHUGEINT`) are always `bigint`.
- `DECIMAL` is a **string**, because `12.34` as a double is not `12.34`. Call
  `Number(v)` if you want a float, or hand the string to a decimal library. This
  is deliberate: rounding here would throw away the exactness the binary
  protocol just carried.

## Cancellation

```js
const controller = new AbortController();
const result = await db.query('SELECT * FROM huge', { signal: controller.signal });
// later
controller.abort();
```

A signal passed to `connect()` applies to every request on that connection.

## Errors

Everything throws `QuackError`, with DuckDB's own message preserved:

```js
try {
  await db.query('SELECT * FROM nope');
} catch (e) {
  console.error(e.message);
  // Table with name nope does not exist! Did you mean "pg_enum"? ...
}
```

A failed query does not break the connection; the next one works.

## Security

The auth token travels **inside the protocol body**, not in a header, so it is
only as protected as the transport. Serve over HTTPS in production and terminate
TLS at a reverse proxy — the Quack server does not do TLS itself.

Do not embed a token in client-side code you ship to untrusted users: anyone with
it can run arbitrary SQL. For a public app, put an authenticating proxy in front
that scopes what a browser session may do.

## Limits

- The module reserves fixed buffers: a single response must fit in 16 MB. Very
  wide rows or huge `BLOB`s can exceed that, and you get a clear error rather
  than a truncated result. Batch size is a server setting
  (`quack_fetch_batch_chunks`).
- Decoding happens on whichever thread calls it. For results large enough to
  jank the UI, run the connection inside a Web Worker (see above).
- Arrow interoperability is not implemented, deliberately: `apache-arrow` is
  ~8 MB and this package has zero dependencies. If you need an Arrow `Table`,
  `@quack-protocol/sdk` provides one.
- Server-side prepared statements and explicit transactions are not exposed yet.

## Testing

```sh
duckdb -c "LOAD quack; CALL quack_serve('quack:localhost:9494', token => 'super_secret');"
zig build test-web        # or: node --test web/test/binding.test.mjs
```

The tests cover request serialization, FETCH streaming (all 1,000,000 rows of a
`range(1000000)`), the one-result guard, type mapping, nested types, bound
parameters and injection resistance, bulk append, abort, and error paths — plus a
separate suite that runs the Worker recipe in a real worker thread. They skip
rather than fail when no server is reachable.
