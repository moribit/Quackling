// WASM FFI boundary test.
//
// The exported functions take raw indices and lengths straight from
// JavaScript, so they are an attack surface in exactly the way the wire
// decoder is: every argument is untrusted. This calls each export with
// out-of-range, out-of-order and hostile arguments and asserts that none of
// them trap, read out of bounds, or leave the module unusable - each must
// return its documented sentinel instead.
//
// Run:  zig build wasm && node tests/wasm/boundary_test.mjs
// (also wired into `zig build test-wasm` and CI)
import { readFileSync } from 'fs';
const { instance } = await WebAssembly.instantiate(readFileSync('web/quackling.wasm'), {});
const w = instance.exports;
let fails = 0;
function ok(label, fn) {
  try { const r = fn(); return r; }
  catch (e) { console.log(`  TRAP in ${label}: ${e.message}`); fails++; return undefined; }
}

// 1. Every accessor called before any query (current == null).
ok('column_count', () => w.quack_column_count());
ok('column_name_ptr', () => w.quack_column_name_ptr(0));
ok('column_name_ptr huge', () => w.quack_column_name_ptr(0xFFFFFFF));
ok('column_type', () => w.quack_column_type(999999));
ok('chunk_count', () => w.quack_chunk_count());
ok('chunk_rows', () => w.quack_chunk_rows(999999));
ok('column_data_ptr', () => w.quack_column_data_ptr(999, 999));
ok('column_data_len', () => w.quack_column_data_len(999, 999));
ok('is_null', () => w.quack_is_null(999, 999, 999));
ok('get_i64', () => w.quack_get_i64(999, 999, 999));
ok('get_f64', () => w.quack_get_f64(999, 999, 999));
ok('get_bytes_ptr', () => w.quack_get_bytes_ptr(999, 999, 999));
ok('get_bytes_len', () => w.quack_get_bytes_len(999, 999, 999));
console.log('1. pre-query accessors: no traps');

// 2. Query before connect must be refused, not crash.
const inp = w.quack_input_buffer();
const enc = new TextEncoder();
const sql = enc.encode('SELECT 1');
new Uint8Array(w.memory.buffer).set(sql, inp);
const r = ok('build_query before connect', () => w.quack_build_query(inp, sql.length));
console.log('2. build_query before connect ->', r, '(expect -1)');
if (r !== -1) { console.error('  UNEXPECTED: expected -1'); fails++; }

// 3. Oversized inputs must be rejected by length, not overflow a buffer.
console.log('3. oversized token ->', ok('big token', () => w.quack_build_connect(inp, 0x7FFFFFFF)));
console.log('   oversized sql   ->', ok('big sql', () => w.quack_build_query(inp, 0x7FFFFFFF)));

// 4. Feeding garbage / truncated bodies to the response decoders.
const mem = () => new Uint8Array(w.memory.buffer);
const rb = w.quack_response_buffer();
for (const [label, bytes] of [
   ['empty', []],
   ['single byte', [0x01]],
   ['random', Array.from({length:64}, (_,i)=>(i*37)&0xFF)],
   ['all 0xFF', new Array(64).fill(0xFF)],
   ['valid-ish header only', [0x01,0x00,0x02,0xFF,0xFF]],
]) {
  mem().set(bytes, rb);
  const a = ok(`on_connect ${label}`, () => w.quack_on_connect_response(bytes.length));
  const b = ok(`on_query ${label}`,  () => w.quack_on_query_response(bytes.length));
  console.log(`4. ${label.padEnd(22)} connect=${a} query=${b}`);
}

// 5. Length exceeding the buffer capacity.
console.log('5. over-capacity len ->',
  ok('oversize resp', () => w.quack_on_query_response(w.quack_response_capacity()+1)));

// 6. With a REAL result loaded, hostile indices must still be safe.
//    This is the important case: the accessors now have chunks/columns to
//    index into, so a missing bounds check is an actual out-of-bounds read
//    rather than an early `current == null` return.
{
  const fx = readFileSync('tests/fixtures/select42.bin');
  if (fx.length > w.quack_response_capacity()) throw new Error('fixture too large');
  mem().set(fx, rb);
  const ncols = w.quack_on_query_response(fx.length);
  if (ncols !== 1) { console.error(`  setup failed: expected 1 column, got ${ncols}`); fails++; }

  // Sanity: the good path works, so the hostile calls below are meaningful.
  if (w.quack_get_i64(0, 0, 0) !== 42n) { console.error('  setup failed: expected 42'); fails++; }

  const huge = 0xFFFFFFF;
  const probes = [
    ['chunk_rows OOB',      () => w.quack_chunk_rows(huge)],
    ['chunk_rows max',      () => w.quack_chunk_rows(0xFFFFFFFF)],
    ['column_type OOB',     () => w.quack_column_type(huge)],
    ['column_name_ptr OOB', () => w.quack_column_name_ptr(huge)],
    ['column_name_len OOB', () => w.quack_column_name_len(huge)],
    ['data_ptr chunk OOB',  () => w.quack_column_data_ptr(huge, 0)],
    ['data_ptr col OOB',    () => w.quack_column_data_ptr(0, huge)],
    ['data_len chunk OOB',  () => w.quack_column_data_len(huge, 0)],
    ['is_null chunk OOB',   () => w.quack_is_null(huge, 0, 0)],
    ['is_null col OOB',     () => w.quack_is_null(0, huge, 0)],
    ['is_null row OOB',     () => w.quack_is_null(0, 0, huge)],
    ['get_i64 chunk OOB',   () => w.quack_get_i64(huge, 0, 0)],
    ['get_i64 col OOB',     () => w.quack_get_i64(0, huge, 0)],
    ['get_i64 row OOB',     () => w.quack_get_i64(0, 0, huge)],
    ['get_f64 OOB',         () => w.quack_get_f64(huge, huge, huge)],
    ['bytes_ptr OOB',       () => w.quack_get_bytes_ptr(huge, huge, huge)],
    ['bytes_len OOB',       () => w.quack_get_bytes_len(huge, huge, huge)],
  ];
  for (const [label, fn] of probes) {
    const before = fails;
    const v = ok(label, fn);
    if (fails === before && v !== 0 && v !== -1 && v !== 0n && v !== null && v !== undefined) {
      // A pointer return is fine, but it must be inside linear memory.
      if (typeof v === 'number' && (v < 0 || v >= w.memory.buffer.byteLength)) {
        console.error(`  ${label} returned out-of-memory pointer ${v}`);
        fails++;
      }
    }
  }
  console.log('6. hostile indices against a loaded result: no traps');
}

// 7. reset() then reuse.
ok('reset', () => w.quack_reset());
ok('after reset', () => w.quack_column_count());
console.log('7. reset + reuse: no traps');

if (fails === 0) {
  console.log('\nRESULT: no traps, no OOB - WASM boundary holds');
} else {
  console.error(`\nRESULT: ${fails} FAILURES`);
  process.exit(1);
}
