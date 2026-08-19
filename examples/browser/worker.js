// Quackling inside a Web Worker.
//
// Why the library ships this as a *recipe* rather than a built-in RPC layer:
// decoding happens in WASM memory with no copying, and that is the main reason
// to use this client at all. A generic `postMessage` bridge would have to
// structured-clone every value across the thread boundary, which throws that
// advantage away and often costs more than the decode it was meant to offload.
//
// So the Worker owns the connection and does the *reduction* — the app knows
// what it actually needs (an aggregate, a 100-row page, a chart series) and
// posts only that. The 1M rows never cross the boundary.
//
// Usage from the page:
//
//   const worker = new Worker('./worker.js', { type: 'module' });
//   worker.postMessage({ id: 1, op: 'connect', url, token, wasmUrl });
//   worker.postMessage({ id: 2, op: 'sum', sql: 'SELECT i FROM range(1000000) t(i)' });

import { Quack } from '../../web/quack.js';

let db = null;

const reply = (id, ok, payload) =>
  self.postMessage(ok ? { id, ok: true, ...payload } : { id, ok: false, error: String(payload) });

self.onmessage = async (event) => {
  const { id, op } = event.data ?? {};
  try {
    switch (op) {
      case 'connect': {
        const { wasmUrl, url, token } = event.data;
        db = await Quack.connect({ wasm: wasmUrl, url, token });
        reply(id, true, { connected: true });
        break;
      }

      // A bounded page of rows: small enough that cloning it is cheap.
      case 'page': {
        const { sql, limit = 100, params } = event.data;
        const result = params ? await db.query(sql, params) : await db.query(sql);
        const rows = [];
        try {
          for await (const row of result) {
            rows.push(row);
            if (rows.length >= limit) break;
          }
        } finally {
          result.close();
        }
        reply(id, true, { rows, columns: result.columns });
        break;
      }

      // The point of the Worker: reduce a huge result to one number without
      // ever sending the rows anywhere.
      case 'sum': {
        const { sql, column = 0 } = event.data;
        const result = await db.query(sql);
        let total = 0n;
        let rows = 0;
        for await (const chunk of result.chunks()) {
          rows += chunk.rowCount;
          const arr = chunk.array(column);
          if (arr) {
            // Zero-copy fast path: a TypedArray straight over WASM memory.
            for (let i = 0; i < arr.length; i++) total += BigInt(arr[i]);
          } else {
            for (let r = 0; r < chunk.rowCount; r++) {
              total += BigInt(chunk.value(column, r) ?? 0);
            }
          }
        }
        reply(id, true, { sum: total.toString(), rows });
        break;
      }

      // Bulk load, driven entirely from the Worker thread.
      case 'append': {
        const { table, rows, columns } = event.data;
        await db.append(table, rows, columns);
        reply(id, true, { appended: rows.length });
        break;
      }

      case 'exec': {
        const { sql, params } = event.data;
        await (params ? db.queryAll(sql, params) : db.queryAll(sql));
        reply(id, true, { done: true });
        break;
      }

      default:
        reply(id, false, `unknown op: ${op}`);
    }
  } catch (e) {
    reply(id, false, e?.message ?? e);
  }
};
