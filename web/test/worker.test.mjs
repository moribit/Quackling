// The Web Worker recipe, exercised in a real worker thread.
//
// `examples/browser/worker.js` is a recipe rather than a built-in RPC layer
// because a generic postMessage bridge would structured-clone every value across
// the thread boundary, discarding the zero-copy decode that is the reason to use
// this client. The Worker therefore *reduces* inside the thread and posts only
// the answer.
//
// This test proves that design actually holds: 1,000,000 rows are summed inside
// the worker and a single number comes back.
//
//   duckdb -c "LOAD quack; CALL quack_serve('quack:localhost:9494', token => 'super_secret');"
//   node --test web/test/worker.test.mjs

import { test, before, describe } from 'node:test';
import assert from 'node:assert/strict';
import { Worker } from 'node:worker_threads';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const URL_ = process.env.QUACK_TEST_URL ?? 'quack:localhost:9494';
const TOKEN = process.env.QUACK_TEST_TOKEN ?? 'super_secret';

let available = false;
let wasmBytes;
let workerSource;

before(async () => {
  try {
    wasmBytes = readFileSync(join(ROOT, 'web', 'quackling.wasm'));
    // Run the *same* recipe, with the browser Worker API bridged onto node's.
    // Rewriting only the import and the `self` shim keeps this an honest test of
    // the shipped file rather than of a copy.
    workerSource = readFileSync(join(ROOT, 'examples', 'browser', 'worker.js'), 'utf8').replace(
      "import { Quack } from '../../web/quack.js';",
      `import { Quack } from ${JSON.stringify(join(ROOT, 'web', 'quack.js'))};\n` +
        "import { parentPort } from 'node:worker_threads';\n" +
        'const self = { postMessage: (m) => parentPort.postMessage(m),' +
        ' set onmessage(f) { parentPort.on("message", (d) => f({ data: d })); } };',
    );
  } catch {
    return;
  }
  try {
    const res = await fetch(URL_.replace(/^quack:/, 'http://'), { signal: AbortSignal.timeout(2000) });
    available = res.ok;
  } catch {
    available = false;
  }
});

/** A worker plus a small promise-based RPC helper. */
function spawn() {
  const w = new Worker(workerSource, { eval: true });
  let next = 1;
  const pending = new Map();
  w.on('message', (m) => {
    const resolve = pending.get(m.id);
    pending.delete(m.id);
    resolve?.(m);
  });
  const call = (msg) =>
    new Promise((resolve) => {
      const id = next++;
      pending.set(id, resolve);
      w.postMessage({ id, ...msg });
    });
  return { worker: w, call };
}

async function connected() {
  const { worker, call } = spawn();
  const res = await call({ op: 'connect', wasmUrl: wasmBytes, url: URL_, token: TOKEN });
  if (!res.ok) {
    await worker.terminate();
    throw new Error(res.error);
  }
  return { worker, call };
}

describe('web worker', () => {
  test('connects from inside a worker', async (t) => {
    if (!available) return t.skip('no server');
    const { worker, call } = await connected();
    try {
      const r = await call({ op: 'page', sql: 'SELECT 42 AS a', limit: 1 });
      assert.ok(r.ok, r.error);
      assert.deepEqual(r.rows, [{ a: 42 }]);
    } finally {
      await worker.terminate();
    }
  });

  test('reduces 1M rows without sending them across the boundary', async (t) => {
    if (!available) return t.skip('no server');
    const { worker, call } = await connected();
    try {
      const r = await call({ op: 'sum', sql: 'SELECT i FROM range(1000000) t(i)' });
      assert.ok(r.ok, r.error);
      assert.equal(r.rows, 1000000);
      // The whole point: one number came back, not a million rows.
      assert.equal(r.sum, ((1000000n * 999999n) / 2n).toString());
      assert.equal(typeof r.sum, 'string');
    } finally {
      await worker.terminate();
    }
  });

  test('pages a large result to a bounded row count', async (t) => {
    if (!available) return t.skip('no server');
    const { worker, call } = await connected();
    try {
      const r = await call({
        op: 'page',
        sql: 'SELECT i, i*2 AS d FROM range(100000) t(i) ORDER BY i',
        limit: 3,
      });
      assert.ok(r.ok, r.error);
      assert.deepEqual(r.rows, [
        { i: 0, d: 0 },
        { i: 1, d: 2 },
        { i: 2, d: 4 },
      ]);
      assert.deepEqual(r.columns.map((c) => c.name), ['i', 'd']);
    } finally {
      await worker.terminate();
    }
  });

  test('bulk appends from inside a worker', async (t) => {
    if (!available) return t.skip('no server');
    const { worker, call } = await connected();
    try {
      await call({ op: 'exec', sql: 'CREATE OR REPLACE TABLE quackling_worker (i INTEGER)' });
      // More than one DataChunk, so the auto-chunking path is exercised too.
      const rows = Array.from({ length: 3000 }, (_, i) => ({ i }));
      const ap = await call({
        op: 'append',
        table: 'quackling_worker',
        rows,
        columns: [{ name: 'i', type: 13 }],
      });
      assert.ok(ap.ok, ap.error);
      assert.equal(ap.appended, 3000);

      const chk = await call({ op: 'page', sql: 'SELECT count(*) c FROM quackling_worker', limit: 1 });
      assert.equal(chk.rows[0].c, 3000);
      await call({ op: 'exec', sql: 'DROP TABLE quackling_worker' });
    } finally {
      await worker.terminate();
    }
  });

  test('a server error is reported back, not swallowed', async (t) => {
    if (!available) return t.skip('no server');
    const { worker, call } = await connected();
    try {
      const r = await call({ op: 'page', sql: 'SELECT * FROM no_such_table_in_worker', limit: 1 });
      assert.equal(r.ok, false);
      assert.match(r.error, /no_such_table_in_worker/);
    } finally {
      await worker.terminate();
    }
  });

  test('an unknown op is rejected', async (t) => {
    if (!available) return t.skip('no server');
    const { worker, call } = await connected();
    try {
      const r = await call({ op: 'nonsense' });
      assert.equal(r.ok, false);
      assert.match(r.error, /unknown op/);
    } finally {
      await worker.terminate();
    }
  });
});
