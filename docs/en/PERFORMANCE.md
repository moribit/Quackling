# Performance

**English** · [日本語](../ja/PERFORMANCE.md)

→ [Documentation index](./README.md)

Every number on this page was measured on the machine described in
[§1](#1-measurement-environment) and can be reproduced with the commands given.
Where a figure is a median of repeated runs, that is stated. No number here is
an estimate.

## Contents

1. [Measurement environment](#1-measurement-environment)
2. [Codec benchmarks](#2-codec-benchmarks)
3. [Reading the allocation column](#3-reading-the-allocation-column)
4. [The typed path versus the Value path](#4-the-typed-path-versus-the-value-path)
5. [Nested types](#5-nested-types)
6. [End-to-end streaming](#6-end-to-end-streaming)
7. [Memory is bounded by batch size](#7-memory-is-bounded-by-batch-size)
8. [Performance traps](#8-performance-traps)
9. [How the harness works](#9-how-the-harness-works)
10. [What is not measured](#10-what-is-not-measured)

---

## 1. Measurement environment

| Property | Value |
|----------|-------|
| Date measured | 2026-08-19 |
| CPU | Apple silicon, `aarch64` |
| OS | macOS (Darwin 25.0.0) |
| Zig | 0.16.0 |
| Optimize mode | `ReleaseFast` |
| Server | DuckDB v1.5.5, `quack` extension, over loopback HTTP |
| Harness | [`bench/bench.zig`](../../bench/bench.zig) |

```sh
zig build bench -Doptimize=fast
```

The codec benchmarks do **no network I/O**. They decode golden fixtures captured
from a live server (`tests/fixtures/*.bin`), so they isolate the codec from
transport latency. End-to-end figures in [§6](#6-end-to-end-streaming) do use the
network.

## 2. Codec benchmarks

Median of three consecutive runs. Allocation counts were identical in all three
runs, so they are exact rather than a median.

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

Run-to-run spread over the three runs was within ±4 % for every row except
`decode NULL-heavy` (157–189 ns, ±10 %), which is short enough that scheduler
noise dominates.

`MB/s` counts wire bytes decoded per second. `rows/s` divides the row count of
the fixture by the elapsed time, so single-row fixtures produce a small number
and the 5 000-row fixture a very large one — compare `ns/op` across rows, not
`rows/s`.

## 3. Reading the allocation column

This is the most load-bearing column in the table.

**Allocations do not scale with row count.** `decode SELECT 42` (1 row) costs 5
allocations; `decode 5k-row BIGINT` (5 000 rows) costs 9. A 5 000× increase in
rows costs 4 more allocations.

The reason is that the decoder **borrows** bulk payloads out of the response
buffer instead of copying them. A flat `BIGINT` column is not allocated and
filled row by row; the vector keeps a slice pointing into the bytes that already
arrived. Allocation therefore scales with the *structure* of a result — columns,
chunks, nesting depth — not its *size*.

The direct consequence for callers is the lifetime rule: borrowed data dies when
the chunk is released, which happens on the next `nextChunk()`. See
[TYPES.md](./TYPES.md) for the full ownership rules.

## 4. The typed path versus the Value path

Two rows in the table decode the *same* 5 000-row fixture and then read every
value out of it:

| Path | ns/op | Relative |
|------|------:|---------:|
| `decode+flat 5k-row` — `at(T, i)` / `asSlice(T)` | 9 142 | 1.0× |
| `decode+values 5k-row` — `getValue()` → `Value` | 16 535 | 1.8× |

The typed accessors are **~1.8× faster** for the same work. `Value` is a tagged
union, so every read allocates nothing but does pay for a switch on the type tag
and a copy into the union. `at(i64, i)` compiles to a bounds check and a load.

Use `Value` when ergonomics matter (mixed-type columns, generic printing, the
CLI). Use `at`/`asSlice` when throughput matters. Both are correct; the choice is
purely about cost.

`asSlice(T)` is faster still when it succeeds, because it hands back a slice
aliasing the response buffer with no per-value work at all. It returns `null`
when the payload is misaligned for `T` or the stored width does not match, which
in practice happens often — see [§8](#8-performance-traps).

## 5. Nested types

| benchmark | ns/op | allocs/op |
|-----------|------:|----------:|
| decode STRUCT | 363 | 9 |
| decode MAP | 509 | 13 |

A MAP costs 13 allocations **regardless of how many entries it holds**, because
DuckDB stores it as `LIST(STRUCT(key, value))` and Quackling borrows the key and
value child vectors rather than materialising pairs. The same reasoning applies
to STRUCT and LIST.

So nesting is cheap in allocation terms, and its cost is a function of the
*schema*, not the data volume.

## 6. End-to-end streaming

With the network in the loop, over loopback HTTP against a live
`quack_serve()` instance:

```sh
zig build -Doptimize=fast
./zig-out/bin/example-streaming
```

```
1000000 rows in 489 chunks, sum = 499999500000
fetches: 41, bytes received: 16024162
        0.49 real         0.10 user         0.02 sys
```

| Metric | Value |
|--------|-------|
| Rows | 1 000 000 |
| Chunks | 489 |
| FETCH round trips | 41 |
| Wire bytes received | 16 024 162 (~16 MB) |
| Wall clock | 0.49 s |
| User CPU | 0.10 s |

Two things to note. First, 41 round trips for 489 chunks — a FETCH response
carries multiple chunks (the server default is 12, see
`compat.default_fetch_batch_chunks`), so round trips are amortised. Second, user
CPU is 0.10 s of the 0.49 s wall clock: this workload is dominated by waiting on
the server and the socket, not by decoding.

## 7. Memory is bounded by batch size

The streaming contract is that peak memory tracks **one FETCH batch**, not the
whole result. Measured with the CLI, which streams and writes each chunk without
retaining it:

```sh
/usr/bin/time -l ./zig-out/bin/quackling --token … --format csv \
    "SELECT i FROM range($N) t(i)" > /dev/null
```

| Rows | Peak RSS |
|-----:|---------:|
| 100 000 | 2.8 MB |
| 1 000 000 | 2.8 MB |
| 5 000 000 | 2.8 MB |

**Fifty times the data costs no additional memory.** The curve is flat, not
merely sublinear, because exactly one batch is resident at a time.

A caller that *accumulates* will of course grow: `example-streaming` peaks at
6.3 MB for the same 1 000 000 rows because it keeps running totals and a larger
output buffer. The bound is on what the *library* retains, not on what the
application chooses to keep.

### What the test actually asserts

`tests/integration_test.zig` has
`"integration: streaming memory is bounded by batch size, not result size"`. Be
precise about what it checks, because it is weaker than the table above:

- it counts **live allocated bytes at the high-water mark**, not RSS — the
  comment in the test says RSS and timing are "too noisy to gate a test on";
- it compares **10 000 rows against 500 000 rows**, not 100 k/1 M/5 M;
- it asserts only `large < small * 4` — a deliberately generous ceiling that
  fails loudly if streaming regresses into buffering, but does not pin a MB
  figure.

So the test guards the *property*; the table above is a measurement. Neither
substitutes for the other.

## 8. Performance traps

**`asSlice(T)` returning `null` is the normal case, not the exception.** Wire
payloads carry no alignment guarantee. Measured through the WASM bridge, a plain
`INTEGER` column's payload pointer came back at `ptr % 4 == 3` — misaligned for
`i32` — so the zero-copy path was refused for *every* chunk. Always write the
fallback:

```zig
if (col.asSlice(i64)) |slice| {
    for (slice) |v| consume(v);          // zero-copy when alignment allows
} else if (col.isFlat(i64)) {
    for (0..chunk.row_count) |i| consume(col.at(i64, i).?);  // always works
}
```

Treating `asSlice` as the expected path and the fallback as rare will mislead
your own benchmarks.

**One result per connection.** A second query on the same connection discards the
first result's server-side cursor. Concurrency requires a `Pool`, not more
queries on one client. Attempting to interleave costs you an
`error.ResultSuperseded`, not a speedup.

**`typed.collect` defeats streaming.** It materialises the whole result, so peak
memory becomes proportional to row count. It also releases each chunk as it goes,
which means `[]const u8` fields in the collected structs point into freed
buffers. Use `typed.iterator` unless the result is small and free of slice
fields.

**Debug builds are not indicative.** The fuzz suite alone runs ~680× slower in
Debug than in ReleaseSafe (~14 s versus ~0.2 s) — allocator bookkeeping and the
absence of inlining, not the amount of work. Always benchmark optimised.

## 9. How the harness works

[`bench/bench.zig`](../../bench/bench.zig) is deliberately small. Per benchmark:

1. **Warm-up.** `min(iters / 10 + 1, 50)` untimed iterations run first, so
   first-touch page faults do not land inside the measurement.
2. **Allocation counting.** A `CountingAllocator` wraps the real allocator and
   counts every call, giving the exact `allocs/op` rather than an estimate.
3. **Timing.** `std.Io.Clock.now(.awake, io)` brackets the timed loop, so time
   spent with the machine asleep is excluded.
4. **Dead-code protection.** Results feed `std.mem.doNotOptimizeAway`, so
   `ReleaseFast` cannot delete the work being measured.

Iteration counts are per benchmark (200 000 for the cheap single-row decodes,
1 000–2 000 for the 5 000-row ones) so each measurement runs long enough to be
stable.

Add a case with one line in `bench/bench.zig`:

```zig
try bench(io, allocator, "decode MY CASE", my_fixture, 100_000, decodeFull);
```

## 10. What is not measured

Stated plainly, so nothing here is read as a broader claim than it is:

- **No TLS.** Every measurement is plain HTTP over loopback. TLS handshake and
  record-layer cost are not included anywhere on this page.
- **No real network.** Loopback has no packet loss, no RTT worth measuring, and
  no MTU effects. Round-trip counts ([§6](#6-end-to-end-streaming)) are the
  figure that will predict behaviour over a real link; the wall-clock numbers
  will not.
- **No concurrency benchmark.** `Pool` has correctness tests, including a
  multi-threaded contention test, but there is no throughput-versus-connections
  measurement.
- **Single machine, single architecture.** Apple `aarch64` only. Nothing here is
  validated on x86-64, and the WASM build is not benchmarked at all.
- **No comparison against other clients.** There is no measurement of Quackling
  against DuckDB's own client, DuckDB-Wasm, or any other implementation.
- **Server-side cost is out of scope.** These figures measure the client. Query
  execution time inside DuckDB is not attributed here.
