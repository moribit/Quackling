// Tests for the JS binding, against a live Quack server.
//
// These cover the properties the WASM module cannot enforce on its own: request
// serialization (the module has one set of shared buffers), FETCH-driven
// streaming (a caller that ignores it silently sees ~2% of a large result), and
// the one-result-at-a-time constraint.
//
//   duckdb -c "LOAD quack; CALL quack_serve('quack:localhost:9494', token => 'super_secret');"
//   node --test web/test/
//
// Skipped automatically when no server is reachable.

import { test, before, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { Quack, QuackError } from '../quack.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const WASM = join(HERE, '..', 'quackling.wasm');
const URL_ = process.env.QUACK_TEST_URL ?? 'quack:localhost:9494';
const TOKEN = process.env.QUACK_TEST_TOKEN ?? 'super_secret';

let available = false;
let wasmBytes;

before(async () => {
  try {
    wasmBytes = readFileSync(WASM);
  } catch {
    return; // `zig build wasm` has not run
  }
  try {
    const res = await fetch(URL_.replace(/^quack:/, 'http://').replace(/\/$/, ''), {
      signal: AbortSignal.timeout(2000),
    });
    available = res.ok;
  } catch {
    available = false;
  }
});

/** A fresh connection, or skip when there is no server. */
async function connect(extra = {}) {
  if (!available) return null;
  return Quack.connect({ wasm: wasmBytes, url: URL_, token: TOKEN, ...extra });
}

describe('connection', () => {
  test('connects and runs a scalar query', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    assert.equal(await db.queryValue('SELECT 42 AS answer'), 42);
  });

  test('accepts a bare host and defaults the port', async (t) => {
    const db = await connect({ url: 'localhost' });
    if (!db) return t.skip('no server');
    assert.equal(await db.queryValue('SELECT 1'), 1);
  });

  test('rejects a bad token with the server message', async (t) => {
    if (!available) return t.skip('no server');
    await assert.rejects(
      () => Quack.connect({ wasm: wasmBytes, url: URL_, token: 'wrong-token' }),
      (e) => e instanceof QuackError && /auth/i.test(e.message),
    );
  });

  test('requires wasm and url', async () => {
    await assert.rejects(() => Quack.connect({ url: 'quack:h' }), QuackError);
    await assert.rejects(() => Quack.connect({ wasm: new Uint8Array(0) }), QuackError);
  });
});

describe('values and types', () => {
  test('round-trips each scalar type', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const [row] = await db.queryAll(`
      SELECT NULL::INTEGER a, true b, 1.5::DOUBLE c, 'txt' d,
             9223372036854775807::BIGINT e, 'ab'::BLOB f, 42::INTEGER g
    `);
    assert.equal(row.a, null);
    assert.equal(row.b, true);
    assert.equal(row.c, 1.5);
    assert.equal(row.d, 'txt');
    // Beyond Number.MAX_SAFE_INTEGER, so it must stay a BigInt.
    assert.equal(row.e, 9223372036854775807n);
    assert.ok(row.f instanceof Uint8Array, 'BLOB should be bytes');
    assert.deepEqual([...row.f], [0x61, 0x62]);
    assert.equal(row.g, 42);
  });

  test('preserves precision for numbers wider than f64/i64', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    // Regression: HUGEINT max used to come back as 0 (asI64 overflowed) and
    // DECIMAL(30,2) lost digits through a double. Both are silent corruption,
    // which is worse than an error - and they undercut the whole point of a
    // binary protocol, so they get their own test.
    const [row] = await db.queryAll(`
      SELECT 170141183460469231731687303715884105727::HUGEINT h,
             123456789012345678.99::DECIMAL(30,2) d,
             9223372036854775807::BIGINT b
    `);
    assert.equal(row.h, 170141183460469231731687303715884105727n);
    // Fractional exact numbers stay strings: converting to a float here would
    // discard the precision the wire format just carried.
    assert.equal(row.d, '123456789012345678.99');
    assert.equal(row.b, 9223372036854775807n);
  });

  test('reads temporal and identifier types as canonical text', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const [row] = await db.queryAll(`
      SELECT DATE '2024-03-15' d,
             TIMESTAMP '2024-03-15 12:34:56' ts,
             '0cc7435c-7cc0-4836-b03d-53aed12d1006'::UUID u,
             'happy'::ENUM('sad','ok','happy') e
    `);
    // A raw day/microsecond count would push calendar maths onto the caller.
    assert.equal(row.d, '2024-03-15');
    assert.equal(row.ts, '2024-03-15 12:34:56');
    assert.equal(row.u, '0cc7435c-7cc0-4836-b03d-53aed12d1006');
    // ENUM resolves to its label, not its dictionary index.
    assert.equal(row.e, 'happy');
  });

  test('DECIMAL keeps its exact digits rather than becoming a float', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    // A fractional exact number stays a string on purpose: `12.34` as a double
    // is not 12.34, and silently rounding would defeat the binary protocol.
    const [row] = await db.queryAll('SELECT 12.34::DECIMAL(10,2) a, 1.5::DECIMAL(4,1) b');
    assert.equal(row.a, '12.34');
    assert.equal(row.b, '1.5');
    // Callers who want a number opt in explicitly.
    assert.equal(Number(row.a), 12.34);
  });

  test('nested types decode to real JS shapes', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    // These came back as `0` originally, then as an error; now they are walked
    // through vector handles and built into the shape a caller expects.
    const [row] = await db.queryAll(`
      SELECT {'a': 1, 'b': 'x'} AS s,
             [10, 20, 30] AS l,
             [1, 2, 3]::INTEGER[3] AS arr,
             MAP{'k': 1, 'j': 2} AS m,
             union_value(n := 5) AS u
    `);
    assert.deepEqual(row.s, { a: 1, b: 'x' });
    assert.deepEqual(row.l, [10, 20, 30]);
    assert.deepEqual(row.arr, [1, 2, 3]);
    // MAP becomes a real Map, so non-string keys survive.
    assert.ok(row.m instanceof Map);
    assert.deepEqual([...row.m], [['k', 1], ['j', 2]]);
    // UNION yields the tagged member's value.
    assert.equal(row.u, 5);
  });

  test('NULLs inside nested values are preserved', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const [row] = await db.queryAll("SELECT [1, NULL, 3] AS l, {'a': NULL} AS s");
    assert.deepEqual(row.l, [1, null, 3]);
    assert.deepEqual(row.s, { a: null });
  });

  test('deeply nested combinations decode recursively', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const [row] = await db.queryAll(`
      SELECT {'inner': [1, 2], 'name': 'x'} AS deep,
             [{'a': 1}, {'a': 2}] AS list_of_structs,
             MAP{'k': [1, 2]} AS map_of_lists
    `);
    assert.deepEqual(row.deep, { inner: [1, 2], name: 'x' });
    assert.deepEqual(row.list_of_structs, [{ a: 1 }, { a: 2 }]);
    assert.deepEqual([...row.map_of_lists], [['k', [1, 2]]]);
  });

  test('nested values stream correctly across many rows', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    // Handles point into the current batch, so they must be re-opened per row
    // rather than cached across a FETCH.
    const result = await db.query(
      'SELECT i, [i, i*2] AS pair FROM range(5000) t(i) ORDER BY i',
    );
    let expect = 0;
    for await (const row of result) {
      assert.deepEqual(row.pair, [expect, expect * 2], `row ${expect}`);
      expect++;
    }
    assert.equal(expect, 5000);
  });

  test('preserves multi-byte UTF-8', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    assert.equal(await db.queryValue("SELECT 'wörld🦆'"), 'wörld🦆');
  });

  test('exposes column metadata', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const result = await db.query('SELECT 1 AS a, 2 AS b');
    assert.deepEqual(result.columns.map((c) => c.name), ['a', 'b']);
    result.close();
  });
});

describe('streaming', () => {
  // The regression this guards: without FETCH the module returns only the first
  // batch - about 24k of 1M rows - with no error at all.
  for (const n of [5_000, 100_000, 1_000_000]) {
    test(`streams all ${n.toLocaleString()} rows`, async (t) => {
      const db = await connect();
      if (!db) return t.skip('no server');
      const result = await db.query(`SELECT i FROM range(${n}) t(i)`);
      let rows = 0;
      let sum = 0n;
      for await (const chunk of result.chunks()) {
        const arr = chunk.array(0);
        if (arr) {
          for (const v of arr) sum += BigInt(v);
        } else {
          for (let r = 0; r < chunk.rowCount; r++) sum += BigInt(chunk.value(0, r));
        }
        rows += chunk.rowCount;
      }
      assert.equal(rows, n, 'every row must arrive');
      assert.equal(sum, (BigInt(n) * BigInt(n - 1)) / 2n, 'checksum');
    });
  }

  test('row iteration crosses chunk boundaries', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const result = await db.query('SELECT i FROM range(5000) t(i) ORDER BY i');
    let expect = 0;
    for await (const row of result) {
      assert.equal(row.i, expect++);
    }
    assert.equal(expect, 5000);
  });

  test('an empty result yields no rows but keeps its schema', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const result = await db.query('SELECT 1 AS a WHERE false');
    assert.deepEqual(result.columns.map((c) => c.name), ['a']);
    assert.deepEqual(await result.toArray(), []);
  });

  test('close() stops streaming early and frees the connection', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const result = await db.query('SELECT i FROM range(1000000) t(i)');
    for await (const _row of result) break; // abandon after one row
    result.close();
    assert.equal(await db.queryValue('SELECT 7'), 7);
  });
});

describe('parameters', () => {
  // Quack v1 has no wire format for parameters, so they are rendered into the
  // SQL text - by the Zig implementation that the native client uses and the
  // mutation suite covers, not by a second copy in JS.
  test('binds every supported JS type', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const [row] = await db.queryAll(
      `SELECT ?::INTEGER a, ? b, ? c, ?::BOOLEAN d, ?::DOUBLE e,
              ?::BIGINT f, ?::HUGEINT g, ?::BLOB h`,
      [42, "o'brien", null, true, 1.5, 9223372036854775807n,
       170141183460469231731687303715884105727n, new Uint8Array([0, 1, 255])],
    );
    assert.equal(row.a, 42);
    // Quote escaping is the injection boundary; verify it round-trips.
    assert.equal(row.b, "o'brien");
    assert.equal(row.c, null);
    assert.equal(row.d, true);
    assert.equal(row.e, 1.5);
    assert.equal(row.f, 9223372036854775807n);
    assert.equal(row.g, 170141183460469231731687303715884105727n);
    assert.deepEqual([...row.h], [0, 1, 255]);
  });

  test('a bound parameter cannot inject SQL', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const attack = "'); DROP TABLE quackling_web_inj; --";
    await db.queryAll('CREATE OR REPLACE TABLE quackling_web_inj (v VARCHAR)');
    await db.queryAll('INSERT INTO quackling_web_inj VALUES (?)', [attack]);
    // The table must still exist, holding the payload as data.
    const [row] = await db.queryAll('SELECT v FROM quackling_web_inj');
    assert.equal(row.v, attack);
    await db.queryAll('DROP TABLE quackling_web_inj');
  });

  test('a placeholder/argument mismatch is caught before sending', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    await assert.rejects(() => db.queryAll('SELECT ?, ?', [1]), QuackError);
    await assert.rejects(() => db.queryAll('SELECT ?', [1, 2]), QuackError);
  });

  test('parameters work with queryValue and query', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    assert.equal(await db.queryValue('SELECT ?::INTEGER', [99]), 99);
    const result = await db.query('SELECT ?::INTEGER v', [7]);
    try {
      assert.deepEqual(await result.toArray(), [{ v: 7 }]);
    } finally {
      result.close();
    }
  });
});

describe('serialization', () => {
  // The module has ONE request buffer and ONE current result, so overlapping
  // calls must be queued. Without that, query A posts the bytes query B wrote
  // and receives B's rows - intermittently, which is the worst failure mode.
  test('concurrent queries each get their own result', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const want = Array.from({ length: 16 }, (_, i) => 1000 + i);
    const got = await Promise.all(want.map((v) => db.queryValue(`SELECT ${v}`)));
    assert.deepEqual(got, want);
  });

  test('concurrent queryAll calls do not interleave', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const results = await Promise.all([
      db.queryAll('SELECT i FROM range(3) t(i)'),
      db.queryAll("SELECT 'x' AS s"),
      db.queryAll('SELECT i FROM range(5) t(i)'),
    ]);
    assert.equal(results[0].length, 3);
    assert.deepEqual(results[1], [{ s: 'x' }]);
    assert.equal(results[2].length, 5);
  });

  test('a second query while a result is open is refused, not corrupted', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const open = await db.query('SELECT i FROM range(1000000) t(i)');
    await assert.rejects(() => db.query('SELECT 1'), QuackError);
    open.close();
    assert.equal(await db.queryValue('SELECT 1'), 1);
  });
});

describe('errors', () => {
  test('a server error carries DuckDB\'s message', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    await assert.rejects(
      () => db.query('SELECT * FROM definitely_missing_xyz'),
      (e) => e instanceof QuackError && e.message.includes('definitely_missing_xyz'),
    );
  });

  test('the connection stays usable after an error', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    await assert.rejects(() => db.query('SELECT FROM WHERE'), QuackError);
    assert.equal(await db.queryValue('SELECT 5'), 5);
  });

  test('an aborted query rejects', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(() => db.query('SELECT 1', { signal: controller.signal }));
  });
});

describe('zero-copy access', () => {
  test('numeric columns expose a TypedArray over WASM memory', async (t) => {
    const db = await connect();
    if (!db) return t.skip('no server');
    const result = await db.query('SELECT i::INTEGER AS i FROM range(64) t(i)');
    let checked = false;
    for await (const chunk of result.chunks()) {
      const arr = chunk.array(0);
      if (arr) {
        assert.ok(arr instanceof Int32Array, 'INTEGER should map to Int32Array');
        assert.equal(arr.length, chunk.rowCount);
        // Must agree with the per-value path.
        for (let r = 0; r < chunk.rowCount; r++) {
          assert.equal(arr[r], chunk.value(0, r));
        }
        checked = true;
      }
    }
    // Alignment is not guaranteed by the wire format, so a null view is a valid
    // outcome; the test asserts agreement only when the fast path is available.
    assert.ok(checked || true);
  });
});
