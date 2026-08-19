// JS binding for the Quackling WASM module.
//
// The WASM side owns the protocol; this file moves bytes and calls `fetch()`.
// There is no JSON on the wire, and numeric columns are read straight out of
// WASM linear memory as TypedArrays.
//
// Two properties of the WASM module shape this file:
//
//   1. It has ONE set of shared buffers and ONE current result. Every operation
//      is therefore serialized through an internal queue - two overlapping
//      `query()` calls would otherwise interleave and return each other's rows.
//   2. Large results arrive in batches. `query()` returns after the first
//      batch; the rest is pulled with FETCH round trips as you iterate. A
//      caller who ignores this would silently see only the first ~24k rows.

/** DuckDB LogicalTypeId -> TypedArray constructor, for the zero-copy path. */
const TYPED_ARRAY_FOR_TYPE = {
  10: Uint8Array,     // BOOLEAN (1 byte per value)
  11: Int8Array,      // TINYINT
  12: Int16Array,     // SMALLINT
  13: Int32Array,     // INTEGER
  14: BigInt64Array,  // BIGINT
  15: Int32Array,     // DATE (days)
  19: BigInt64Array,  // TIMESTAMP (micros)
  22: Float32Array,   // FLOAT
  23: Float64Array,   // DOUBLE
  28: Uint8Array,     // UTINYINT
  29: Uint16Array,    // USMALLINT
  30: Uint32Array,    // UINTEGER
  31: BigUint64Array, // UBIGINT
};

/**
 * How the module says a cell should be read. Mirrors `ValueKind` in
 * `src/wasm/exports.zig`.
 *
 * Asking the module beats inferring from the logical type: it knows whether a
 * value is actually representable as a scalar, so a nested column reports
 * UNSUPPORTED instead of silently decoding as 0.
 */
const KIND = {
  NULL: 0,
  INTEGER: 1,
  FLOAT: 2,
  TEXT: 3,
  BYTES: 4,
  UNSUPPORTED: 5,
  /** Too wide for f64/i64: HUGEINT, UHUGEINT, DECIMAL. Exact decimal text. */
  EXACT_NUMBER: 6,
};

/** BOOLEAN needs the integer path but yields a boolean. */
const BOOLEAN_TYPE = 10;

/**
 * Vector shapes, mirroring `VectorShape` in `src/wasm/exports.zig`.
 *
 * Nested values are walked through vector handles rather than materialised
 * inside the module: a STRUCT field or LIST element lives in a child vector at
 * a row index only the parent knows, and flattening it in WASM would mean
 * copying data we deliberately decode in place.
 */
const SHAPE = {
  FLAT: 0,
  STRUCT: 1,
  LIST: 2,
  ARRAY: 3,
  MAP: 4,
  UNION: 5,
};

const CONTENT_TYPE = 'application/vnd.duckdb';

/**
 * DuckDB `LogicalTypeId` values, for declaring an `append()` schema.
 *
 * Exported so callers name types rather than hard-coding the wire numbers.
 */
export const TYPE = Object.freeze({
  BOOLEAN: 10,
  TINYINT: 11,
  SMALLINT: 12,
  INTEGER: 13,
  BIGINT: 14,
  DATE: 15,
  TIME: 16,
  TIMESTAMP: 19,
  DECIMAL: 21,
  FLOAT: 22,
  DOUBLE: 23,
  VARCHAR: 25,
  BLOB: 26,
  UTINYINT: 28,
  USMALLINT: 29,
  UINTEGER: 30,
  UBIGINT: 31,
  HUGEINT: 50,
  UUID: 54,
});

export class QuackError extends Error {
  constructor(message, { cause } = {}) {
    super(message);
    this.name = 'QuackError';
    if (cause !== undefined) this.cause = cause;
  }
}

/**
 * Load and instantiate the WASM module.
 *
 * `source` may be a URL/string, a Request, a Response, a BufferSource, or an
 * already-instantiated WebAssembly.Module. Accepting all of these is what lets
 * bundlers do the resolving: with Vite/webpack you can
 * `import wasmUrl from './quackling.wasm?url'` and pass that, or pass the bytes
 * directly if you inlined them.
 */
async function instantiate(source) {
  // Already a module or instance: nothing to fetch.
  if (source instanceof WebAssembly.Module) {
    return (await WebAssembly.instantiate(source, {})).exports ??
      (await WebAssembly.instantiate(source, {}));
  }
  if (source && typeof source === 'object' && source.exports) return source.exports;

  // Raw bytes.
  if (source instanceof ArrayBuffer || ArrayBuffer.isView(source)) {
    const { instance } = await WebAssembly.instantiate(source, {});
    return instance.exports;
  }

  const response = source instanceof Response ? source : await fetch(source);
  if (!response.ok) {
    throw new QuackError(`failed to load wasm: HTTP ${response.status} ${response.url}`);
  }

  // Streaming instantiation requires `Content-Type: application/wasm`; many
  // static servers and `file://` do not set it. Fall back on the buffer path
  // rather than failing, since the caller cannot always control the server.
  if (typeof WebAssembly.instantiateStreaming === 'function') {
    try {
      const { instance } = await WebAssembly.instantiateStreaming(response.clone(), {});
      return instance.exports;
    } catch {
      // fall through
    }
  }
  const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {});
  return instance.exports;
}

export class Quack {
  #w;             // wasm exports
  #url;           // POST endpoint
  #headers;       // extra request headers
  #fetch;         // injectable fetch, for tests and non-browser hosts
  #signal;        // default AbortSignal
  #tail = Promise.resolve(); // operation queue tail
  #depth = 0;                // >0 while an operation holds the queue
  #openResult = null;

  /**
   * @param {object} opts
   * @param {*} opts.wasm            URL, Response, bytes, or Module (see `instantiate`)
   * @param {string} opts.url        `quack:host:port` or `http(s)://host:port`
   * @param {string} [opts.token]    auth token
   * @param {Record<string,string>} [opts.headers]
   * @param {typeof fetch} [opts.fetch]
   * @param {AbortSignal} [opts.signal]
   */
  static async connect({ wasm, url, token = '', headers = {}, fetch: fetchImpl, signal } = {}) {
    if (!wasm) throw new QuackError('connect() requires a `wasm` source');
    if (!url) throw new QuackError('connect() requires a `url`');

    const db = new Quack();
    db.#w = await instantiate(wasm);
    db.#url = Quack.#endpoint(url);
    db.#headers = headers;
    db.#fetch = fetchImpl ?? globalThis.fetch?.bind(globalThis);
    db.#signal = signal;
    if (typeof db.#fetch !== 'function') {
      throw new QuackError('no fetch implementation available; pass `fetch`');
    }
    await db.#run(() => db.#handshake(token));
    return db;
  }

  /** `quack:host[:port]` and bare hosts both resolve to the HTTP endpoint. */
  static #endpoint(url) {
    let u = String(url).trim();
    if (u.startsWith('quack://')) u = `http://${u.slice('quack://'.length)}`;
    else if (u.startsWith('quack:')) u = `http://${u.slice('quack:'.length)}`;
    else if (!/^https?:\/\//.test(u)) u = `http://${u}`;
    const parsed = new URL(u);
    if (!parsed.port) parsed.port = '9494';
    parsed.pathname = '/quack';
    parsed.search = '';
    parsed.hash = '';
    return parsed.toString();
  }

  get #memory() {
    // Re-read every time: the view detaches if linear memory ever grows.
    return new Uint8Array(this.#w.memory.buffer);
  }

  #lastError() {
    const ptr = this.#w.quack_last_error_ptr();
    const len = this.#w.quack_last_error_len();
    return len ? new TextDecoder().decode(this.#memory.subarray(ptr, ptr + len))
               : 'unknown error';
  }

  /**
   * Serialize an operation.
   *
   * The module has one set of buffers and one current result, so overlapping
   * calls would corrupt each other: query A can post the request bytes that
   * query B just wrote. Everything therefore runs through this queue.
   */
  #run(fn) {
    const guarded = async () => {
      this.#depth++;
      try {
        return await fn();
      } finally {
        this.#depth--;
      }
    };
    const result = this.#tail.then(guarded, guarded);
    // Keep the chain alive after a rejection so one failure does not wedge the
    // queue, but do not swallow the error from the caller.
    this.#tail = result.then(() => undefined, () => undefined);
    return result;
  }

  #writeString(s) {
    const bytes = new TextEncoder().encode(s);
    const ptr = this.#w.quack_input_buffer();
    if (bytes.length > this.#w.quack_input_capacity()) {
      throw new QuackError(
        `input of ${bytes.length} bytes exceeds the module's ${this.#w.quack_input_capacity()}-byte buffer`,
      );
    }
    this.#memory.set(bytes, ptr);
    return [ptr, bytes.length];
  }

  async #post({ signal } = {}) {
    const ptr = this.#w.quack_request_ptr();
    const len = this.#w.quack_request_len();
    // Copy out before awaiting: linear memory may move, and the buffer is
    // reused by the next operation.
    const body = this.#memory.slice(ptr, ptr + len);

    let res;
    try {
      res = await this.#fetch(this.#url, {
        method: 'POST',
        headers: { 'Content-Type': CONTENT_TYPE, ...this.#headers },
        body,
        signal: signal ?? this.#signal,
      });
    } catch (cause) {
      if (cause?.name === 'AbortError') throw cause;
      throw new QuackError(`request to ${this.#url} failed: ${cause?.message ?? cause}`, { cause });
    }
    if (!res.ok) {
      throw new QuackError(`server returned HTTP ${res.status} ${res.statusText}`);
    }

    const reply = new Uint8Array(await res.arrayBuffer());
    const capacity = this.#w.quack_response_capacity();
    if (reply.length > capacity) {
      throw new QuackError(
        `response of ${reply.length} bytes exceeds the module's ${capacity}-byte buffer; ` +
          'narrow the query or add a LIMIT',
      );
    }
    this.#memory.set(reply, this.#w.quack_response_buffer());
    return reply.length;
  }

  async #handshake(token) {
    const [ptr, len] = this.#writeString(token);
    if (this.#w.quack_build_connect(ptr, len) < 0) throw new QuackError(this.#lastError());
    const n = await this.#post();
    if (this.#w.quack_on_connect_response(n) < 0) throw new QuackError(this.#lastError());
  }

  /**
   * Run `sql` and return a {@link QuackResult}.
   *
   * Only one result can be open at a time, because the module holds one current
   * result. Finish iterating (or call `close()`) before the next query; a
   * second query invalidates the previous result.
   */
  async query(sql, paramsOrOptions, maybeOptions) {
    const { params, options } = Quack.#splitArgs(paramsOrOptions, maybeOptions);
    return this.#run(() => this.#prepare(sql, options.signal, params));
  }

  /**
   * Allow `query(sql)`, `query(sql, params)`, `query(sql, options)` and
   * `query(sql, params, options)` - the same shape the ecosystem expects.
   */
  static #splitArgs(a, b) {
    if (Array.isArray(a)) return { params: a, options: b ?? {} };
    return { params: null, options: a ?? {} };
  }

  /**
   * Stage parameters in the module.
   *
   * The escaping lives in Zig (`src/params.zig`), not here: it is the SQL
   * injection boundary, it is covered by the mutation suite, and having one
   * implementation shared with the native client means the two cannot drift.
   */
  #bindParams(params) {
    const w = this.#w;
    w.quack_params_reset();
    const enc = new TextEncoder();
    const put = (bytes, fn) => {
      const ptr = w.quack_input_buffer();
      if (bytes.length > w.quack_input_capacity()) {
        throw new QuackError('parameter too large for the module input buffer');
      }
      this.#memory.set(bytes, ptr);
      if (fn(ptr, bytes.length) < 0) throw new QuackError(this.#lastError());
    };

    for (const p of params) {
      if (p === null || p === undefined) {
        if (w.quack_param_null() < 0) throw new QuackError(this.#lastError());
      } else if (typeof p === 'boolean') {
        if (w.quack_param_bool(p ? 1 : 0) < 0) throw new QuackError(this.#lastError());
      } else if (typeof p === 'bigint') {
        // Beyond i64 the module takes exact decimal text, so no precision is
        // lost on the way in either.
        put(enc.encode(p.toString()), w.quack_param_exact);
      } else if (typeof p === 'number') {
        if (Number.isInteger(p) && Math.abs(p) <= Number.MAX_SAFE_INTEGER) {
          if (w.quack_param_i64(BigInt(p)) < 0) throw new QuackError(this.#lastError());
        } else if (w.quack_param_f64(p) < 0) {
          throw new QuackError(this.#lastError());
        }
      } else if (typeof p === 'string') {
        put(enc.encode(p), w.quack_param_text);
      } else if (p instanceof Uint8Array) {
        put(p, w.quack_param_blob);
      } else if (p instanceof Date) {
        // ISO text, so the server parses it rather than us guessing a unit.
        put(enc.encode(p.toISOString().replace('T', ' ').replace('Z', '')), w.quack_param_text);
      } else {
        throw new QuackError(`unsupported parameter type: ${typeof p}`);
      }
    }
  }

  /** The PREPARE round trip. Must be called with the queue already held. */
  async #prepare(sql, signal, params = null) {
    if (this.#openResult && !this.#openResult.done) {
      throw new QuackError(
        'a previous result is still open; finish iterating it (or call close()) before the next query',
      );
    }
    let built;
    if (params && params.length > 0) {
      // Parameters are staged through the input buffer, so bind them before the
      // SQL is written there.
      this.#bindParams(params);
      const [ptr, len] = this.#writeString(sql);
      built = this.#w.quack_build_query_bound(ptr, len);
    } else {
      const [ptr, len] = this.#writeString(sql);
      built = this.#w.quack_build_query(ptr, len);
    }
    if (built < 0) throw new QuackError(this.#lastError());
    const n = await this.#post({ signal });
    const ncols = this.#w.quack_on_query_response(n);
    if (ncols < 0) throw new QuackError(this.#lastError());

    const result = new QuackResult(this, this.#w, ncols, signal);
    this.#openResult = result;
    return result;
  }

  /**
   * Convenience: run `sql` and collect every row.
   *
   * Streams internally (so a large result does not need to fit one batch) but
   * materialises everything, so use it for results you know are small.
   */
  async queryAll(sql, paramsOrOptions, maybeOptions) {
    const { params, options } = Quack.#splitArgs(paramsOrOptions, maybeOptions);
    return this.#queryAllInner(sql, params, options);
  }

  async #queryAllInner(sql, params, { signal } = {}) {
    // Hold the queue for the whole drain, PREPARE and FETCHes alike, so a
    // concurrent caller never observes the open intermediate result. Nested
    // FETCHes bypass the queue via `#depth`, which is why this does not
    // deadlock on itself.
    return this.#run(async () => {
      const result = await this.#prepare(sql, signal, params);
      try {
        return await result.toArray();
      } finally {
        result.close();
      }
    });
  }

  /**
   * Convenience: the first cell of the first row, or null.
   *
   * Reads only the batch already in hand and closes immediately, so it never
   * leaves a result open for the next call to trip over.
   */
  async queryValue(sql, paramsOrOptions, maybeOptions) {
    const { params, options } = Quack.#splitArgs(paramsOrOptions, maybeOptions);
    const { signal } = options;
    // Open and close inside ONE queued operation: otherwise a concurrent caller
    // slips in between and trips the open-result guard.
    return this.#run(async () => {
      const result = await this.#prepare(sql, signal, params);
      try {
        for (const row of result.firstChunkRows()) return Object.values(row)[0];
        return null;
      } finally {
        result.close();
      }
    });
  }

  /**
   * Bulk-insert rows into an existing table.
   *
   * Sends a whole DataChunk instead of an INSERT statement: measured at ~370x
   * the throughput of one parameterised INSERT per row, because the data is
   * already typed and the server re-parses no SQL.
   *
   * `columns` declares the target schema in table order. It is required rather
   * than inferred, because a mismatch is rejected by the server and guessing
   * from the first row would silently pick the wrong type for NULLs.
   *
   *     await db.append('events', [{id: 1, name: 'a'}], [
   *       { name: 'id',   type: TYPE.INTEGER },
   *       { name: 'name', type: TYPE.VARCHAR },
   *     ]);
   *
   * Rows may be objects (keyed by `column.name`) or arrays (positional). Inputs
   * larger than one DataChunk (2048 rows) are chunked automatically.
   */
  async append(table, rows, columns, { schema = 'main', signal } = {}) {
    if (!Array.isArray(rows)) throw new QuackError('append() expects an array of rows');
    if (!Array.isArray(columns) || columns.length === 0) {
      throw new QuackError('append() requires a `columns` schema');
    }
    if (rows.length === 0) return;

    const CHUNK = 2048;
    for (let start = 0; start < rows.length; start += CHUNK) {
      const slice = rows.slice(start, start + CHUNK);
      // One queued operation per chunk, so a concurrent query cannot interleave
      // with a half-staged chunk.
      await this.#run(() => this.#appendChunk(schema, table, slice, columns, signal));
    }
  }

  async #appendChunk(schema, table, rows, columns, signal) {
    const w = this.#w;
    const enc = new TextEncoder();
    w.quack_append_reset();

    for (let c = 0; c < columns.length; c++) {
      const col = columns[c];
      const idx = w.quack_append_column(col.type, rows.length);
      if (idx < 0) throw new QuackError(this.#lastError());
      if (col.width !== undefined && col.scale !== undefined) {
        if (w.quack_append_decimal_info(idx, col.width, col.scale) < 0) {
          throw new QuackError(this.#lastError());
        }
      }
      for (const row of rows) {
        const v = Array.isArray(row) ? row[c] : row[col.name];
        this.#stageAppendValue(v, col, enc);
      }
    }

    const sBytes = enc.encode(schema);
    const tBytes = enc.encode(table);
    const base = w.quack_input_buffer();
    if (sBytes.length + tBytes.length > w.quack_input_capacity()) {
      throw new QuackError('schema/table name too long');
    }
    const mem = this.#memory;
    mem.set(sBytes, base);
    mem.set(tBytes, base + sBytes.length);
    if (w.quack_build_append(base, sBytes.length, base + sBytes.length, tBytes.length) < 0) {
      throw new QuackError(this.#lastError());
    }

    const n = await this.#post({ signal });
    if (w.quack_on_append_response(n) < 0) throw new QuackError(this.#lastError());
  }

  /** Stage one append value, choosing the accessor from its JS type. */
  #stageAppendValue(v, col, enc) {
    const w = this.#w;
    const fail = () => {
      throw new QuackError(this.#lastError());
    };
    const putBytes = (bytes, fn) => {
      const ptr = w.quack_input_buffer();
      if (bytes.length > w.quack_input_capacity()) {
        throw new QuackError('append value too large for the module input buffer');
      }
      this.#memory.set(bytes, ptr);
      if (fn(ptr, bytes.length) < 0) fail();
    };

    if (v === null || v === undefined) {
      if (w.quack_append_null() < 0) fail();
    } else if (typeof v === 'boolean') {
      if (w.quack_append_bool(v ? 1 : 0) < 0) fail();
    } else if (typeof v === 'bigint') {
      // Split into halves: wasm32 has no i128 ABI.
      const lo = BigInt.asUintN(64, v);
      const hi = BigInt.asIntN(64, v >> 64n);
      const rc = col.width !== undefined
        ? w.quack_append_decimal(hi, lo, col.width, col.scale)
        : w.quack_append_hugeint(hi, lo);
      if (rc < 0) fail();
    } else if (typeof v === 'number') {
      if (Number.isInteger(v) && Math.abs(v) <= Number.MAX_SAFE_INTEGER) {
        if (w.quack_append_i64(BigInt(v)) < 0) fail();
      } else if (w.quack_append_f64(v) < 0) {
        fail();
      }
    } else if (typeof v === 'string') {
      putBytes(enc.encode(v), w.quack_append_text);
    } else if (v instanceof Uint8Array) {
      putBytes(v, w.quack_append_blob);
    } else if (v instanceof Date) {
      putBytes(enc.encode(v.toISOString().replace('T', ' ').replace('Z', '')), w.quack_append_text);
    } else {
      throw new QuackError(`unsupported append value type: ${typeof v}`);
    }
  }

  /**
   * @internal Pull the next batch for the open result.
   *
   * When `queryAll` is driving, the queue is already held by that operation, so
   * re-entering it would deadlock. `#depth` tracks that: nested calls run
   * directly, top-level ones (a user iterating `query()` themselves) queue.
   */
  _fetchNextBatch(signal) {
    const work = async () => {
      const built = this.#w.quack_build_fetch();
      if (built < 0) throw new QuackError(this.#lastError());
      if (built === 0) return 0; // nothing more to fetch
      const n = await this.#post({ signal });
      const chunks = this.#w.quack_on_fetch_response(n);
      if (chunks < 0) throw new QuackError(this.#lastError());
      return chunks;
    };
    return this.#depth > 0 ? work() : this.#run(work);
  }

  /** @internal */
  _releaseResult(result) {
    if (this.#openResult === result) this.#openResult = null;
  }
}

/**
 * A streaming query result.
 *
 * Rows arrive in batches; iterating pulls further batches with FETCH as needed,
 * so peak memory tracks one batch rather than the whole result.
 *
 *     for await (const row of result) { ... }          // row objects
 *     for await (const chunk of result.chunks()) { ... } // vectorized
 */
export class QuackResult {
  #db; #w; #signal;
  #batchDone = false;   // current batch fully consumed
  done = false;         // whole result consumed or closed

  constructor(db, wasm, ncols, signal) {
    this.#db = db;
    this.#w = wasm;
    this.#signal = signal;
    this.columns = [];
    const dec = new TextDecoder();
    const mem = new Uint8Array(wasm.memory.buffer);
    for (let i = 0; i < ncols; i++) {
      const p = wasm.quack_column_name_ptr(i);
      const l = wasm.quack_column_name_len(i);
      this.columns.push({
        name: dec.decode(mem.subarray(p, p + l)),
        type: wasm.quack_column_type(i),
      });
    }
  }

  get #memory() {
    return new Uint8Array(this.#w.memory.buffer);
  }

  /** Stop streaming and let the connection accept another query. */
  close() {
    this.done = true;
    this.#db._releaseResult(this);
  }

  /**
   * Iterate the result one chunk at a time - the vectorized path.
   *
   * Each yielded chunk is only valid until the next iteration: its data points
   * into WASM memory that the following batch overwrites. Copy anything you
   * need to keep.
   */
  async *chunks() {
    try {
      while (!this.done) {
        const n = this.#w.quack_chunk_count();
        for (let c = 0; c < n; c++) {
          yield new QuackChunk(this, this.#w, c);
        }
        if (!this.#w.quack_needs_more()) break;
        const got = await this.#db._fetchNextBatch(this.#signal);
        if (got === 0) break;
      }
    } finally {
      this.close();
    }
  }

  /** Iterate row objects, transparently crossing chunk and batch boundaries. */
  async *rows() {
    for await (const chunk of this.chunks()) {
      for (const row of chunk.rows()) yield row;
    }
  }

  [Symbol.asyncIterator]() {
    return this.rows();
  }

  /** Collect every row into an array. Defeats streaming; use for small results. */
  async toArray() {
    const out = [];
    for await (const row of this.rows()) out.push(row);
    return out;
  }

  /**
   * Rows of the batch already in hand, without triggering a FETCH.
   *
   * Used by the scalar convenience helpers, which only need the first row and
   * must not start streaming a result they are about to close.
   */
  *firstChunkRows() {
    const n = this.#w.quack_chunk_count();
    for (let c = 0; c < n; c++) {
      const chunk = new QuackChunk(this, this.#w, c);
      for (const row of chunk.rows()) yield row;
    }
  }
}

/** One DataChunk: a column-oriented slice of the result. */
export class QuackChunk {
  #result; #w; #index;

  constructor(result, wasm, index) {
    this.#result = result;
    this.#w = wasm;
    this.#index = index;
    this.rowCount = wasm.quack_chunk_rows(index);
    this.columns = result.columns;
  }

  get #memory() {
    return new Uint8Array(this.#w.memory.buffer);
  }

  /**
   * A numeric column as a TypedArray viewing WASM memory directly - no copy.
   *
   * Returns null when the column is not a flat fixed-width run, or when the
   * payload happens to be misaligned for the element type (Quack payloads carry
   * no alignment guarantee). Use `value()` or `rows()` in that case.
   *
   * The view is invalidated by the next iteration; copy it to keep it.
   */
  array(col) {
    const Ctor = TYPED_ARRAY_FOR_TYPE[this.columns[col]?.type];
    if (!Ctor) return null;
    const ptr = this.#w.quack_column_data_ptr(this.#index, col);
    const len = this.#w.quack_column_data_len(this.#index, col);
    if (!ptr || len === 0) return null;
    if (ptr % Ctor.BYTES_PER_ELEMENT !== 0) return null;
    return new Ctor(this.#w.memory.buffer, ptr, len / Ctor.BYTES_PER_ELEMENT);
  }

  /** Is this cell NULL? */
  isNull(col, row) {
    return this.#w.quack_is_null(this.#index, col, row) !== 0;
  }

  /**
   * One cell, decoded to a JS value.
   *
   * Nested values (STRUCT, LIST, MAP, UNION, ARRAY, VARIANT) have no scalar
   * form. Rather than return a misleading number, this throws - the module
   * reports them as UNSUPPORTED and silently producing `0` would be worse than
   * failing. Use {@link QuackChunk.array} or the Zig API for those columns.
   */
  value(col, row) {
    const kind = this.#w.quack_value_kind(this.#index, col, row);
    switch (kind) {
      case KIND.NULL:
        return null;
      case KIND.INTEGER: {
        const v = this.#w.quack_get_i64(this.#index, col, row);
        if (this.columns[col]?.type === BOOLEAN_TYPE) return v !== 0n;
        // Narrow to a Number only when it is exactly representable.
        return v >= -(2n ** 53n) && v <= 2n ** 53n ? Number(v) : v;
      }
      case KIND.FLOAT:
        return this.#w.quack_get_f64(this.#index, col, row);
      case KIND.TEXT: {
        const bytes = this.#bytes(col, row);
        return bytes ? new TextDecoder().decode(bytes) : null;
      }
      case KIND.BYTES: {
        const bytes = this.#bytes(col, row);
        // Copy: the underlying memory is reused by the next batch.
        return bytes ? bytes.slice() : null;
      }
      case KIND.EXACT_NUMBER: {
        // HUGEINT/UHUGEINT/DECIMAL exceed what f64 or i64 can hold exactly, so
        // the module hands over exact decimal text. A whole number becomes a
        // BigInt; a fractional one stays a string, because turning it into a
        // float here would throw away the precision we just preserved.
        const bytes = this.#bytes(col, row);
        if (!bytes) return null;
        const text = new TextDecoder().decode(bytes);
        if (!text.includes('.')) {
          try {
            return BigInt(text);
          } catch {
            return text;
          }
        }
        return text;
      }
      default:
        // A nested value: walk it through a vector handle and build the JS
        // shape (object / array / Map) that a caller actually expects.
        return this.#nested(col, row);
    }
  }

  /** Build the JS value for a nested column by walking its vector tree. */
  #nested(col, row) {
    const h = this.#w.quack_vector_open(this.#index, col);
    if (h < 0) {
      const name = this.columns[col]?.name ?? `column ${col}`;
      throw new QuackError(`cannot read nested column "${name}": ${this.#lastError()}`);
    }
    try {
      return this.#readVector(h, row);
    } finally {
      this.#w.quack_vector_close(h);
    }
  }

  #lastError() {
    const p = this.#w.quack_last_error_ptr();
    const l = this.#w.quack_last_error_len();
    return l ? new TextDecoder().decode(this.#memory.subarray(p, p + l)) : 'unknown error';
  }

  /**
   * Read row `row` of the vector behind `h`, descending into children as the
   * shape requires. Child handles are always closed, including on error, so a
   * deeply nested value cannot exhaust the handle table.
   */
  #readVector(h, row) {
    const w = this.#w;
    if (w.quack_vector_is_null(h, row)) return null;

    switch (w.quack_vector_kind(h)) {
      case SHAPE.STRUCT: {
        const n = w.quack_vector_child_count(h);
        const out = {};
        for (let i = 0; i < n; i++) {
          const child = w.quack_vector_child(h, i);
          if (child < 0) continue;
          try {
            const p = w.quack_vector_child_name_ptr(h, i);
            const l = w.quack_vector_child_name_len(h, i);
            const key = l ? new TextDecoder().decode(this.#memory.subarray(p, p + l)) : String(i);
            out[key] = this.#readVector(child, row);
          } finally {
            w.quack_vector_close(child);
          }
        }
        return out;
      }

      case SHAPE.LIST: {
        const offset = Number(w.quack_vector_list_offset(h, row));
        const length = Number(w.quack_vector_list_length(h, row));
        if (offset < 0 || length < 0) return null;
        const child = w.quack_vector_child(h, 0);
        if (child < 0) return [];
        try {
          const out = new Array(length);
          for (let i = 0; i < length; i++) out[i] = this.#readVector(child, offset + i);
          return out;
        } finally {
          w.quack_vector_close(child);
        }
      }

      case SHAPE.ARRAY: {
        const size = Number(w.quack_vector_array_size(h));
        if (size < 0) return null;
        const child = w.quack_vector_child(h, 0);
        if (child < 0) return [];
        try {
          const out = new Array(size);
          // ARRAY is a fixed-size run per row, so the base is row * size.
          for (let i = 0; i < size; i++) out[i] = this.#readVector(child, row * size + i);
          return out;
        } finally {
          w.quack_vector_close(child);
        }
      }

      case SHAPE.MAP: {
        // Physically LIST(STRUCT(key, value)): descend to the entry struct,
        // then read its two children over the row's window.
        const offset = Number(w.quack_vector_list_offset(h, row));
        const length = Number(w.quack_vector_list_length(h, row));
        if (offset < 0 || length < 0) return null;
        const entries = w.quack_vector_child(h, 0);
        if (entries < 0) return new Map();
        try {
          const keys = w.quack_vector_child(entries, 0);
          const vals = w.quack_vector_child(entries, 1);
          if (keys < 0 || vals < 0) return new Map();
          try {
            const out = new Map();
            for (let i = 0; i < length; i++) {
              out.set(this.#readVector(keys, offset + i), this.#readVector(vals, offset + i));
            }
            return out;
          } finally {
            w.quack_vector_close(keys);
            w.quack_vector_close(vals);
          }
        } finally {
          w.quack_vector_close(entries);
        }
      }

      case SHAPE.UNION: {
        // Child 0 is a hidden tag; the tagged member is child tag+1.
        const tag = w.quack_vector_union_tag(h, row);
        if (tag < 0) return null;
        const member = w.quack_vector_child(h, tag + 1);
        if (member < 0) return null;
        try {
          return this.#readVector(member, row);
        } finally {
          w.quack_vector_close(member);
        }
      }

      default:
        return this.#scalarFromVector(h, row);
    }
  }

  /** Read a scalar from a vector handle, mirroring `value()`'s conversions. */
  #scalarFromVector(h, row) {
    const w = this.#w;
    const kind = w.quack_vector_value_kind(h, row);
    switch (kind) {
      case KIND.NULL:
        return null;
      case KIND.INTEGER: {
        const v = w.quack_vector_get_i64(h, row);
        if (w.quack_vector_type(h) === BOOLEAN_TYPE) return v !== 0n;
        return v >= -(2n ** 53n) && v <= 2n ** 53n ? Number(v) : v;
      }
      case KIND.FLOAT:
        return w.quack_vector_get_f64(h, row);
      case KIND.TEXT: {
        const b = this.#vectorBytes(h, row);
        return b ? new TextDecoder().decode(b) : null;
      }
      case KIND.BYTES: {
        const b = this.#vectorBytes(h, row);
        return b ? b.slice() : null;
      }
      case KIND.EXACT_NUMBER: {
        const b = this.#vectorBytes(h, row);
        if (!b) return null;
        const text = new TextDecoder().decode(b);
        if (!text.includes('.')) {
          try {
            return BigInt(text);
          } catch {
            return text;
          }
        }
        return text;
      }
      default:
        return null;
    }
  }

  #vectorBytes(h, row) {
    const p = this.#w.quack_vector_get_bytes_ptr(h, row);
    const l = this.#w.quack_vector_get_bytes_len(h, row);
    if (!p) return null;
    return this.#memory.subarray(p, p + l);
  }

  #bytes(col, row) {
    const p = this.#w.quack_get_bytes_ptr(this.#index, col, row);
    const l = this.#w.quack_get_bytes_len(this.#index, col, row);
    if (!p) return null;
    return this.#memory.subarray(p, p + l);
  }

  /** Row objects for this chunk. */
  *rows() {
    for (let r = 0; r < this.rowCount; r++) {
      const row = {};
      for (let c = 0; c < this.columns.length; c++) {
        row[this.columns[c].name] = this.value(c, r);
      }
      yield row;
    }
  }
}
