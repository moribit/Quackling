/**
 * Quackling — DuckDB Quack protocol client, decoded in WebAssembly.
 *
 * The protocol is parsed by Zig compiled to WASM; JavaScript only supplies
 * `fetch()` and reads decoded columns out of linear memory.
 */

/** DuckDB `LogicalTypeId` values, as reported by {@link ColumnInfo.type}. */
export type LogicalTypeId = number;

/**
 * A cell value.
 *
 * `BLOB`/`BIGNUM` come back as bytes; temporal, `UUID` and `ENUM` values come
 * back as their canonical text (`"2024-03-15"`, the enum label, ...).
 *
 * Precision is never silently lost: 64-bit integers become `bigint` past
 * `Number.MAX_SAFE_INTEGER`, 128-bit integers are always `bigint`, and `DECIMAL`
 * is an exact decimal `string` (a double cannot represent `12.34`).
 */
export type QuackValue = null | boolean | number | bigint | string | Uint8Array;

/**
 * A nested value: STRUCT/VARIANT as an object, LIST/ARRAY as an array, MAP as a
 * `Map` (so non-string keys survive), UNION as its active member's value.
 */
export type QuackNested =
  | { [field: string]: QuackCell }
  | QuackCell[]
  | Map<QuackCell, QuackCell>;

/** Any cell: a scalar or a nested structure. */
export type QuackCell = QuackValue | QuackNested;

/** A row, keyed by column name. */
export type QuackRow = Record<string, QuackCell>;

/**
 * A bindable query parameter.
 *
 * `bigint` is rendered as exact decimal text, so 128-bit values lose no
 * precision on the way in. `Date` is sent as ISO text for the server to parse.
 */
export type QuackParam =
  | null
  | undefined
  | boolean
  | number
  | bigint
  | string
  | Uint8Array
  | Date;

export interface ColumnInfo {
  /** Column name as reported by the server. */
  readonly name: string;
  /** DuckDB `LogicalTypeId`; use it to pick a TypedArray for {@link QuackChunk.array}. */
  readonly type: LogicalTypeId;
}

/**
 * Anything {@link Quack.connect} accepts as the WASM module.
 *
 * A URL/string works, but passing a bundler-resolved asset is preferable:
 * ```ts
 * import wasmUrl from 'quackling/quackling.wasm?url'; // Vite
 * await Quack.connect({ wasm: wasmUrl, url: 'quack:localhost:9494' });
 * ```
 */
export type WasmSource =
  | string
  | URL
  | Request
  | Response
  | ArrayBuffer
  | ArrayBufferView
  | WebAssembly.Module;

export interface ConnectOptions {
  /** The compiled module: URL, Response, bytes, or an instantiated Module. */
  wasm: WasmSource;
  /** `quack:host[:port]`, `http(s)://host[:port]`, or a bare host. Port defaults to 9494. */
  url: string;
  /** Authentication token. Travels inside the protocol body, so use HTTPS in production. */
  token?: string;
  /** Extra request headers, e.g. for an authenticating proxy. */
  headers?: Record<string, string>;
  /** Override `fetch`, for tests or non-browser hosts. */
  fetch?: typeof fetch;
  /** Default abort signal applied to every request. */
  signal?: AbortSignal;
}

export interface QueryOptions {
  /** Abort this query's HTTP requests. */
  signal?: AbortSignal;
}

/**
 * DuckDB `LogicalTypeId` constants, for declaring an {@link Quack.append}
 * schema by name rather than by wire number.
 */
export declare const TYPE: {
  readonly BOOLEAN: 10; readonly TINYINT: 11; readonly SMALLINT: 12;
  readonly INTEGER: 13; readonly BIGINT: 14; readonly DATE: 15;
  readonly TIME: 16; readonly TIMESTAMP: 19; readonly DECIMAL: 21;
  readonly FLOAT: 22; readonly DOUBLE: 23; readonly VARCHAR: 25;
  readonly BLOB: 26; readonly UTINYINT: 28; readonly USMALLINT: 29;
  readonly UINTEGER: 30; readonly UBIGINT: 31; readonly HUGEINT: 50;
  readonly UUID: 54;
};

/** One column of an {@link Quack.append} target schema. */
export interface AppendColumn {
  /** Column name, used to read the field from object-shaped rows. */
  name: string;
  /** DuckDB type; use {@link TYPE}. */
  type: LogicalTypeId;
  /** Required for `DECIMAL`: total digits. */
  width?: number;
  /** Required for `DECIMAL`: digits after the point. */
  scale?: number;
}

export interface AppendOptions {
  /** Target schema; defaults to `main`. */
  schema?: string;
  signal?: AbortSignal;
}

/** Errors raised by this library. Server messages are preserved verbatim. */
export declare class QuackError extends Error {
  readonly name: 'QuackError';
  constructor(message: string, options?: { cause?: unknown });
}

/**
 * A connection to a Quack server.
 *
 * One connection is one server-side session with **one** result cursor, so only
 * one result may be open at a time and operations are serialized internally.
 * For concurrent queries, open multiple connections.
 */
export declare class Quack {
  static connect(options: ConnectOptions): Promise<Quack>;

  /**
   * Run `sql` and return a streaming result.
   *
   * Large results arrive in batches; iterating pulls the rest with FETCH round
   * trips. Finish iterating or call {@link QuackResult.close} before the next
   * query.
   *
   * `?` placeholders are filled from `params`. The escaping happens in the WASM
   * module, sharing one audited implementation with the native client.
   */
  query(sql: string, options?: QueryOptions): Promise<QuackResult>;
  query(sql: string, params: QuackParam[], options?: QueryOptions): Promise<QuackResult>;

  /** Run `sql` and collect every row. Materialises everything; small results only. */
  queryAll(sql: string, options?: QueryOptions): Promise<QuackRow[]>;
  queryAll(sql: string, params: QuackParam[], options?: QueryOptions): Promise<QuackRow[]>;

  /** The first cell of the first row, or `null`. */
  queryValue(sql: string, options?: QueryOptions): Promise<QuackCell>;
  queryValue(sql: string, params: QuackParam[], options?: QueryOptions): Promise<QuackCell>;

  /**
   * Bulk-insert rows into an existing table.
   *
   * Sends a whole DataChunk rather than an INSERT statement — roughly 370x the
   * throughput of one parameterised INSERT per row. Values travel in binary, so
   * this path involves no SQL escaping.
   *
   * `rows` may be objects (keyed by `column.name`) or arrays (positional).
   * `columns` must match the table in order and type; it is required rather than
   * inferred, because the server rejects a mismatch and a first row containing
   * `NULL` carries no type information. Inputs beyond one DataChunk (2048 rows)
   * are chunked automatically.
   */
  append(
    table: string,
    rows: ReadonlyArray<Record<string, QuackParam> | readonly QuackParam[]>,
    columns: readonly AppendColumn[],
    options?: AppendOptions,
  ): Promise<void>;
}

/**
 * A streaming query result.
 *
 * ```ts
 * for await (const row of result) { ... }              // rows
 * for await (const chunk of result.chunks()) { ... }   // vectorized
 * ```
 */
export declare class QuackResult {
  /** Column metadata, in result order. */
  readonly columns: readonly ColumnInfo[];
  /** True once the result is exhausted or closed. */
  readonly done: boolean;

  /** Stop streaming and let the connection accept another query. */
  close(): void;

  /**
   * Iterate chunk by chunk — the vectorized path.
   *
   * Each chunk is valid only until the next iteration; its data points into WASM
   * memory that the following batch overwrites. Copy what you need to keep.
   */
  chunks(): AsyncGenerator<QuackChunk, void, undefined>;

  /** Iterate rows, crossing chunk and batch boundaries transparently. */
  rows(): AsyncGenerator<QuackRow, void, undefined>;

  [Symbol.asyncIterator](): AsyncGenerator<QuackRow, void, undefined>;

  /** Collect every remaining row. Defeats streaming; small results only. */
  toArray(): Promise<QuackRow[]>;

  /** Rows of the batch already in hand, without triggering a FETCH. */
  firstChunkRows(): Generator<QuackRow, void, undefined>;
}

/** One DataChunk: a column-oriented slice of the result. */
export declare class QuackChunk {
  readonly rowCount: number;
  readonly columns: readonly ColumnInfo[];

  /**
   * A numeric column as a TypedArray **viewing WASM memory directly** — no copy.
   *
   * Returns `null` for non-numeric columns, and for numeric ones whose payload
   * is misaligned for the element type (Quack payloads carry no alignment
   * guarantee). Fall back to {@link value} or {@link rows} in that case.
   *
   * The view is invalidated by the next iteration.
   */
  array(col: number): ArrayBufferView | null;

  /** Is this cell NULL? */
  isNull(col: number, row: number): boolean;

  /**
   * One cell, decoded to a JS value.
   *
   * Nested columns are walked in the module and built into an object, array or
   * `Map` here - no copying happens inside WASM.
   */
  value(col: number, row: number): QuackCell;

  /** Row objects for this chunk. */
  rows(): Generator<QuackRow, void, undefined>;
}
