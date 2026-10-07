# Testing

**English** · [日本語](../ja/TESTING.md)
→ [Documentation index](./README.md)

Quackling is a protocol client: it consumes bytes produced by someone else, and
it is expected to keep working across DuckDB releases of a protocol that is
still beta. Two things follow from that, and they shape the whole test strategy:

1. Correctness cannot be established by testing against our own encoder. The
   ground truth has to come from a real server, captured by something that is
   not this codebase.
2. A green suite proves the tests *run*. It does not prove they would notice if
   a bounds check disappeared. That question is answered separately, by
   mutation testing.

Everything below is measured on the tree as it stands. Counts come from
`zig build test --summary all`; timings are wall-clock on Apple aarch64.

## Contents

- [The suite at a glance](#the-suite-at-a-glance)
- [Layer 1 — Unit tests](#layer-1--unit-tests)
- [Layer 2 — Golden tests](#layer-2--golden-tests)
- [Layer 3 — Decoder guard tests](#layer-3--decoder-guard-tests)
- [Layer 4 — Client tests](#layer-4--client-tests)
- [Layer 5 — Fuzz tests](#layer-5--fuzz-tests)
- [Layer 6 — Integration and WASM boundary tests](#layer-6--integration-and-wasm-boundary-tests)
- [Mutation testing: the meta-layer](#mutation-testing-the-meta-layer)
- [Running the suite](#running-the-suite)
- [The cost of mutation testing](#the-cost-of-mutation-testing)
- [Regenerating the golden fixtures](#regenerating-the-golden-fixtures)
- [Adding a test to the right layer](#adding-a-test-to-the-right-layer)

## The suite at a glance

`zig build test` is one step that runs six independent test binaries, wired in
[`../../build.zig`](../../build.zig):

| # | Layer | Binary / root | Tests | Server needed | On `zig build test` |
|---|---|---|---|---|---|
| 1 | Unit | `lib_tests` — `src/root.zig` | 122 | no | yes |
| 2 | Golden | `golden` — `tests/golden_test.zig` | 31 | no | yes |
| 1 | Unit (CLI) | `cli_tests` — `src/cli/main.zig` | 9 | no | yes (non-wasm only) |
| 3 | Decoder guards | `decoder_tests` — `tests/decoder_test.zig` | 21 | no | yes |
| 4 | Client / mock | `client_tests` — `tests/client_test.zig` | 37 | no | yes |
| 5 | Fuzz | `fuzz_tests` — `tests/fuzz_test.zig` | 7 | no | yes (ReleaseSafe) |
| 6 | Integration | `tests/integration_test.zig` | 29 | **yes** (skips) | no — `test-integration` |
| 6 | WASM boundary | `tests/wasm/boundary_test.mjs` | 1 script | no (needs node) | no — `test-wasm` |

`zig build test` reports **227/227 tests passed** over 14 build steps and takes
about **7.7 s** with a warm cache. The 29 integration tests are deliberately
off the default step (see [`../../build.zig`](../../build.zig): *"Kept off the
default `test` step so CI without a server stays green"*), which is why the
in-repo total is 256 `test` blocks but only 227 of them run by default.

Per-module unit test distribution, for orientation:

| Module | Tests | Module | Tests |
|---|---:|---|---:|
| `src/pool.zig` | 16 | `src/typed.zig` | 5 |
| `src/params.zig` | 13 | `src/types/validity.zig` | 4 |
| `src/types/vector.zig` | 12 | `src/types/logical_type.zig` | 4 |
| `src/serialization/reader.zig` | 12 | `src/transport/transport.zig` | 4 |
| `src/cli/main.zig` | 9 | `src/stats.zig` | 3 |
| `src/uri.zig` | 7 | `src/types/data_chunk.zig` | 2 |
| `src/serialization/writer.zig` | 7 | `src/transport/native.zig` | 2 |
| `src/protocol/message.zig` | 7 | `src/protocol/compat.zig` | 2 |
| `src/types/value.zig` | 5 | `src/error.zig` | 2 |

## Layer 1 — Unit tests

Inline `test` blocks living next to the code they exercise. `src/root.zig` ends
with a `test` block that both calls `std.testing.refAllDecls` and explicitly
`_ = @import(...)`s every module, so adding a module without wiring it there
means its tests silently never run — check that list when you add a file.

**What it proves.** Each primitive behaves as specified in isolation: varint
encode/decode round trips and boundary values, string and blob length handling,
validity-mask bit semantics, logical-type mapping, value formatting, URI
parsing and rejection, parameter escaping, pool mechanics (including a
multi-threaded contention test and a "never leased to two holders at once"
test), statistics accounting, and the CLI's argument parsing plus CSV/JSON
escaping and column-width calculation.

**What it CANNOT prove.** Nothing about the wire format. Every input here is
one we wrote ourselves, so a unit test agrees with our own understanding of the
protocol by construction. It also proves nothing about how the pieces compose
into a session.

**How to run.** `zig build test` (all layers), and the module list above tells
you which binary a given test lands in.

**Cost.** 122 tests in ~63 ms, plus 9 CLI tests in ~17 ms. Effectively free.

## Layer 2 — Golden tests

[`../../tests/golden_test.zig`](../../tests/golden_test.zig) — 31 tests over the
`.bin` fixtures in [`../../tests/fixtures/`](../../tests/fixtures/).

The fixtures are real response payloads from a live
`CALL quack_serve('quack:localhost:9494', token => 'super_secret')` on DuckDB
v1.5.5 with the `quack` extension, over plain HTTP. There are 29 query fixtures
plus `connection_response.bin`, 45,173 bytes in total, and
[`../../tests/fixtures/manifest.json`](../../tests/fixtures/manifest.json)
records the generating SQL, the response message type and the exact byte length
for each one. They are `@embedFile`d, so these tests need no filesystem and run
unchanged on wasm.

**The point that makes this layer worth having:** the fixtures were captured by
[`../../scripts/capture_fixtures.py`](../../scripts/capture_fixtures.py), which
speaks the Quack protocol *itself*, in Python, with no Quackling involved — its
own varint writer, its own field-id framing, its own reader for the handshake
response. From that script's docstring:

> This script speaks the protocol directly (no Quackling involved) so that the
> fixtures stay an *independent* check on the Zig implementation rather than a
> recording of its own behaviour.

That is the difference between a regression test and a conformance test. If the
fixtures had been produced by dumping Quackling's own decoder input they would
pin our current behaviour, including our current misunderstandings. Captured
independently, a disagreement between the Zig decoder and the fixture means one
of the two is wrong about DuckDB — which is exactly the signal you want when
upstream changes the format.

**What it proves.** That the decoder reads real bytes correctly. Each test
asserts the decoded values (42 is 42; `'wörld🦆'` survives as UTF-8; HUGEINT
carries the full 128-bit range; a DECIMAL keeps its scale across storage
widths; a UUID round trips its canonical text; ENUM resolves to its label;
STRUCT/LIST/ARRAY/MAP/UNION/VARIANT expose their children) **and** that the
reader is positioned at end-of-buffer afterwards — every byte consumed, nothing
skipped. A decoder that accidentally ignored a trailing field would pass a
value assertion and fail the byte-consumption assertion. One test decodes every
fixture under the testing allocator to catch leaks, and one cross-checks the
zero-copy slice path (`asSlice`) against value-by-value decoding on the same
fixture.

**What it CANNOT prove.** Anything about inputs a real server does not produce.
A well-behaved server never sends a dictionary index past the end of its
dictionary, so no fixture reaches that bounds check. That gap is Layer 3's job.
It also can't prove anything about a *future* DuckDB — only re-capture does
that.

**How to run.** `zig build test`.

**Cost.** 31 tests in ~28 ms. The maintenance cost is the real one: fixtures
must be re-captured against new DuckDB releases, which needs a live server.

## Layer 3 — Decoder guard tests

[`../../tests/decoder_test.zig`](../../tests/decoder_test.zig) — 21 tests.

Hand-built malformed messages, assembled with a small byte-level DSL so each
test reads as the message it describes rather than as a pile of hex. This layer
exists *because of* mutation testing: its docstring records that mutation
testing found four guards with no covering test at all (the validity mask, the
list-length-versus-remaining-bytes check, the dictionary index bound and the
ENUM index bound) even though the suite was green.

Covered structures include: a truncated validity mask; a list count larger than
the bytes remaining; a chunk claiming more columns than there are bytes; a
dictionary index past the dictionary; a selection vector shorter than the row
count; an ENUM code past its label list; an ENUM whose declared count disagrees
with its label list; a fixed-width payload of the wrong length; a row count
beyond `standard_vector_size` (2048); a column count that disagrees with the
type count; a VARCHAR list whose count differs from the row count; an unknown
field id (rejected, not skipped); an FSST vector (reported as unsupported, not
guessed at); nesting deeper than the depth limit. Positive controls sit
alongside — a *valid* dictionary vector, a valid ENUM code, an honest list
count, a sequence vector, a constant vector — so a guard cannot pass by
rejecting everything.

**What it proves.** Each bounds check rejects exactly the input it exists for,
with the specific typed error, and does not reject legitimate input.

**What it CANNOT prove.** That the set of hostile shapes we thought of is
complete. It is a hand-written list; Layer 5 covers the shapes nobody thought
of.

**How to run.** `zig build test`.

**Cost.** 21 tests in ~10 ms.

## Layer 4 — Client tests

[`../../tests/client_test.zig`](../../tests/client_test.zig) — 37 tests over
`MockTransport`.

The mock replaces the network with a scripted list of response bodies and
records what was sent, so the session and streaming layers are fully covered
with no DuckDB anywhere. It can also produce responses a real server will not
readily produce: truncated bodies, wrong message types, empty batches, HTTP
5xx, a server that never signals end-of-stream. The synthetic responses are
built with the library's own encoder, which is sound here precisely because the
encoder is independently pinned by the golden fixtures and by
`src/protocol/message.zig`'s "connection request encodes the exact bytes the
server accepted" test.

What is covered, grouped by concern:

| Concern | Representative assertions |
|---|---|
| Handshake | session id and server identity stored; `connect` is idempotent; a response with no session id is rejected |
| Version negotiation | a server outside the supported range is refused; the advertised version is accepted |
| Error classification | auth failures separated from other server errors; a non-auth handshake error is a plain `ServerError`; an unexpected message type is a protocol error |
| Transport failures | transport error surfaces and is counted; non-2xx is `HttpError` with no decode attempt; a truncated body is a decode error, not a crash; a response over `max_response_bytes` is refused |
| Multi-batch FETCH | streaming walks multiple FETCH batches to completion; an empty first batch ends the stream immediately; `nextChunk` keeps returning null after exhaustion; the FETCH request echoes the result uuid |
| Hang resistance | *"a server that never signals end-of-stream cannot hang the client"* |
| Supersede detection | a result superseded by a newer query yields `error.ResultSuperseded`; even a FAILED query supersedes an outstanding result; a fully drained result is unaffected by a later query |
| Cancellation | a cancelled token stops a query before it is sent; cancelling mid-stream stops further chunks |
| Token non-leakage | the token appears in none of `lastError()`, `client.url`, or formatted `Stats` — and *is* present in the handshake body, asserted positively, because that is the one place it belongs |
| Parameters | bound parameters reach the server already substituted; a parameter error is raised before anything is sent |
| Observability | the observer sees request and chunk events; byte counters track both directions |

**What it proves.** The state machine is right, including its failure paths,
and the token-secrecy property is enforced rather than merely intended.

**What it CANNOT prove.** That a real DuckDB behaves the way the mock's script
says it does. The mock is our model of the server; Layer 6 checks the model.

**How to run.** `zig build test`.

**Cost.** 37 tests in ~71 ms.

## Layer 5 — Fuzz tests

[`../../tests/fuzz_test.zig`](../../tests/fuzz_test.zig) — 7 tests.

The contract, quoted verbatim from the file's docstring, because the whole layer
is an assertion of one sentence:

> The decoder is the only component that consumes untrusted bytes, so the
> contract it must uphold is narrow and absolute: **arbitrary input produces
> either a successful decode or a typed error — never a panic, an
> out-of-bounds read, an integer overflow, or unbounded allocation.**

Note what is *not* claimed: nothing says a mutated input must fail. A mutated
message that still happens to be valid may decode successfully. The property is
about the absence of undefined behaviour, not about the verdict.

The corpus is 17 fixtures, chosen so the recursive decode paths are represented
— `struct`, `list`, `array`, `map`, `map_nested`, `enum`, `union`,
`nested_deep`, `variant` alongside the flat ones — because that is where a
malformed length or depth does the most damage. Every input goes through
`decodeUntrusted`, which runs the full header-plus-body decode with deliberately
tight limits (`max_byte_length` 1 MiB, `max_list_length` 65536, `max_depth` 32)
so a hostile length cannot make the test itself slow, and which frees memory on
both the success and error paths — so the testing allocator's leak check
doubles as verification of error-path cleanup.

Three strategies, as the docstring states:

1. **Systematic truncation** — every prefix of every fixture, `len` from 0 to
   the full length. Truncation is the most common malformed input and the one
   most likely to walk off the end of a buffer.
2. **Single-byte corruption** — every byte position of every fixture set to
   each of `0x00, 0x01, 0x7F, 0x80, 0xFF`, which covers length prefixes, field
   ids and type tags.
3. **Random and adversarial input** — 4000 pseudo-random buffers from a fixed
   seed (`0xDEADBEEF`, so runs are reproducible), plus hand-built hostile
   bodies behind a valid-looking header: a list claiming 2^32 elements, a string
   claiming 2^40 bytes, a row count beyond `standard_vector_size`, a varint that
   never terminates, an out-of-place field id, and 40 nested objects to probe
   the depth limit.

Two further tests assert directly on the primitives, where the guarantees are
strongest (an overlong varint must not wrap; a length prefix beyond the buffer
must fail before allocating; an empty buffer yields end-of-buffer from
`readFieldId`/`readByte`/`readF64`/`readHugeInt`), and one drives 200 nested
`LogicalType` objects against a `max_depth` of 16 to confirm recursion
terminates with an error rather than dying on the stack.

Together this is roughly **25,000 decodes** per run. The final test is the
coverage-guided entry point: `std.testing.fuzz` returns after one deterministic
input under a normal build and loops under `--fuzz`.

**What it proves.** No input in a large mechanically-generated space causes a
panic, an out-of-bounds access, an overflow, or a leak.

**What it CANNOT prove.** That inputs outside that space are safe. Truncation
and single-byte corruption of *valid* messages explore the neighbourhood of
valid input; they will not construct a deep multi-field hostile message from
nothing. The coverage-guided fuzzer is the tool for that, and it only searches
while you actually run it.

**How to run.** `zig build test` for the deterministic pass;
`zig build test --fuzz` to hand the same entry point to Zig's fuzzer for
unbounded exploration. Note that the docstring's mention of a `zig build fuzz`
step is stale — there is no `fuzz` step in `build.zig`; use `--fuzz`.

**Cost.** 7 tests in ~1 s at ReleaseSafe, with a peak RSS around 634 MB (the
truncation loop over the 40 KB `largeresult` fixture dominates both). This is
the most expensive layer by an order of magnitude, and it is the reason
`build.zig` builds it optimised — see the note under
[The cost of mutation testing](#the-cost-of-mutation-testing).

## Layer 6 — Integration and WASM boundary tests

### Integration tests

[`../../tests/integration_test.zig`](../../tests/integration_test.zig) — 29
tests against a live server. **Not** on the default `test` step.

```sh
duckdb -c "LOAD quack; CALL quack_serve('quack:localhost:9494', token => 'super_secret');"
zig build test-integration
# or point them elsewhere:
zig build test-integration -Dquack-endpoint=quack:host:9494 -Dquack-token=...
```

The endpoint and token arrive as **build options**, not environment variables,
so the same code works identically on every target including Windows and WASI.

**They skip rather than fail when no server is reachable.** The harness catches
`ConnectionFailed`, `NetworkError` and `Timeout` from `connect` and returns
`error.SkipZigTest`; any other error still fails. That makes the file safe to
run in a CI job that may or may not have a server — and it is also the
limitation to keep in mind: a serverless run of `test-integration` is green and
proves nothing.

Coverage: handshake (including that the session id is exactly 32 bytes and the
negotiated `quack_version` is 1), `SELECT 42`, primitives with NULLs and
VARCHAR, multi-row ordering, a large result streaming across FETCH round trips,
server errors carrying DuckDB's own message, syntax errors, empty results with
schema, typed struct mapping and optional fields, DDL/DML, wide types, stats
accounting, a bad token, STRUCT/LIST/ARRAY/MAP/ENUM/UNION round trips, nested
NULLs, bound parameters by type, injection resistance, parameter count mismatch
caught before sending, pooled connections, cancellation, a test that asserts
streaming memory stays bounded by batch size rather than result size, and four
bulk-append tests: a single chunk, a full 2048-row chunk, a missing table
surfacing the server's error, and a throughput comparison against row-wise
INSERT.

**What it proves.** That the model the other five layers encode matches a real
DuckDB. This is the layer that catches an upstream wire-format change. CI runs
it against both DuckDB 1.5.3 (the first release that shipped Quack as a core
extension with `quack_serve`) and `latest`.

**What it CANNOT prove.** Anything, when no server is present. It also does not
exercise TLS — everything runs over plain HTTP against loopback.

**Cost.** Needs a DuckDB binary and a running server; a couple of tests move
100,000 rows.

### WASM FFI boundary test

[`../../tests/wasm/boundary_test.mjs`](../../tests/wasm/boundary_test.mjs) — one
node script, 128 lines, run by `zig build test-wasm` (which depends on the wasm
install step).

The exported functions take raw indices and lengths straight from JavaScript, so
they are an attack surface in the same way the wire decoder is: every argument
is untrusted. The script calls every export with out-of-range, out-of-order and
hostile arguments and asserts nothing traps, reads out of bounds, or leaves the
module unusable — each must return its documented sentinel. Seven phases:

1. Every accessor called before any query (`current == null`), with indices like
   `999999` and `0xFFFFFFF`.
2. `quack_build_query` before connect must return `-1`.
3. Oversized inputs (`0x7FFFFFFF` lengths) rejected by length, not by
   overflowing a buffer.
4. Garbage and truncated bodies fed to both response decoders: empty, a single
   byte, pseudo-random, all-`0xFF`, and a valid-looking-header-only body.
5. A declared length exceeding `quack_response_capacity()`.
6. **The important case:** load the real `select42.bin` fixture, sanity-check
   that `quack_get_i64(0,0,0)` is `42n`, then hammer 17 hostile index
   combinations. With a real result loaded the accessors have chunks and columns
   to index into, so a missing bounds check is an actual out-of-bounds read
   rather than an early null return. Any pointer returned must land inside
   linear memory.
7. `quack_reset()` followed by reuse.

Exit status is non-zero if any probe traps or misbehaves, so CI gates on it.

## Mutation testing: the meta-layer

[`../../scripts/mutation_test.py`](../../scripts/mutation_test.py). The
philosophy, from its docstring:

> A passing test suite only proves the tests *run*; it does not prove they would
> notice if a bounds check disappeared. This script breaks each guard one at a
> time and asserts that `zig build test` fails. A guard whose mutant SURVIVES
> has no covering test, which is a real gap even though CI is green.

### How a mutant is applied

The catalogue is a list of `(name, file, original, replacement)` tuples. Each
entry removes exactly **one** guard, and the replacement must still compile — a
mutant that fails to build tells you nothing about test coverage, which is why
guards are neutralised as `if (false) return Error...` or
`if (cond) {} // detected but allowed` rather than deleted.

Per mutant the script: reads the file; if the `original` pattern is absent
reports `INVALID (pattern not found - code moved?)` and moves on; otherwise
copies the file to `<name>.zig.mutbak`, registers it in an `in_flight` map,
writes the mutated text, runs `zig build test`, and restores the backup in a
`finally`. `zig build test` is launched with `start_new_session=True` so it gets
its own process group: `zig build` spawns the compiled test binaries as
grandchildren, and killing only the direct child would leave a spinning test
binary at 100% CPU forever — which is exactly what a mutant that removes a loop
bound produces.

Restoration is defended three ways: the `finally` per mutant, and `SIGINT`
(exit 130) and `SIGTERM` (exit 143) handlers that kill any live suite *first*
(so the sources are never edited from under a running compiler) and then move
every `in_flight` backup back. An interrupted run never leaves the tree
mutated.

Before mutating anything the script runs the suite once as a baseline and
refuses to continue unless it is green — a baseline failure would make every
subsequent verdict meaningless. It also times that run, and derives the
per-mutant timeout from it.

### The three verdicts

| Verdict | Meaning | Effect on exit status |
|---|---|---|
| `CAUGHT` | The suite failed, or hung and was killed at the timeout. Some test depends on this guard. | none — this is the goal |
| `SURVIVED` | The suite passed with the guard removed. No test covers it. | **exit 1** |
| `INVALID` | The pattern was not found (code moved), or the mutant did not compile. Says nothing about coverage; the catalogue needs updating. | none, but reported |

**A HANG counts as CAUGHT**, and the script is explicit about why:

> A hang counts as CAUGHT: a guard whose removal makes the suite spin forever is
> unambiguously load-bearing (this is how the unbounded FETCH loop was found).

The timeout is derived, not fixed: `TIMEOUT_FLOOR_S = 45.0` and
`TIMEOUT_MULTIPLIER = 6.0`, so the per-mutant ceiling is
`max(45, 6 × baseline)`. The reasoning is in the script: once the suite itself
is fast, waiting out a generously fixed ceiling dominates the whole run — with
an ~8 s suite a 240 s ceiling costs 30× a normal mutant. A small multiple of the
measured baseline still distinguishes "slow" from "never finishes".

### Catalogue coverage

**51 mutants** across 10 files:

| File | Mutants | What they break |
|---|---:|---|
| `src/serialization/decoder.zig` | 10 | payload length agreement, validity-mask assignment, dictionary bounds, selection-vector length, column-count match, row-count cap, VARCHAR count match, ENUM count agreement, FSST rejection, unknown-field rejection |
| `src/serialization/reader.zig` | 8 | varint overflow, varint capacity, byte-length cap, length-vs-remaining, list-count cap, list-vs-remaining, `take` bounds, depth limit |
| `src/params.zig` | 8 | quote escaping, string-literal skipping, line-comment skipping, block-comment skipping, count match, count overrun, UTF-8 validation, NUL rejection |
| `src/client.zig` | 6 | auth classification, protocol version min, protocol version max, HTTP status, response-size cap, missing session id |
| `src/types/vector.zig` | 5 | ENUM index bounds, row bounds, `readFixed` bounds, `asSlice` alignment, `asSlice` length |
| `src/pool.zig` | 4 | mutual exclusion, capacity limit, deinit-waits-for-leases, double-release guard |
| `src/result.zig` | 3 | FETCH ceiling, empty-batch stream terminator, cancel check |
| `src/uri.zig` | 3 | embedded credentials, control characters, zero port |
| `src/types/validity.zig` | 2 | NULL bit semantics (inverted, not removed), mask bounds |
| `src/protocol/message.zig` | 2 | header unknown-field rejection, connection-id default skipping |

One mutant sits in `EXPECTED_SURVIVORS` and is reported without failing the
run: `pool/deinit-waits-for-leases`. Its removal cannot be observed
deterministically, and the script records the argument in full rather than
leaving a silent pass — the guard protects a *caller* that dereferences
`lease.client` after `deinit`, and the library's own release path never touches
the client during shutdown, so observing the fault requires either caller-side
use-after-free (undefined behaviour) or a probe that races the releaser thread
needed to unblock `deinit`. The list is kept deliberately small: "hard to test"
is explicitly not an accepted reason, only "cannot be observed without relying
on undefined behaviour or a race".

So the scoreboard is 50 mutants that must be caught plus 1 documented expected
survivor. Current state is 50/50 caught. Any *unexpected* survivor exits
non-zero and fails CI.

The defects this process actually found, all of them hidden behind a green test
run:

| Defect | How it would have failed in production |
|---|---|
| Unbounded FETCH loop | A server that never sends an empty batch hangs the client forever |
| Pool use-after-free | Closing a pool with leases outstanding freed connections still in use |
| Result not invalidated by a new query | A stale result silently streamed the *next* query's rows |
| Varint shift overflow | A malformed length prefix panicked instead of erroring |
| Leaks on nested-type error paths | Malformed STRUCT/LIST responses leaked memory |
| Missing lower-bound version check | A server below the supported range was accepted |

## Running the suite

Every step defined in [`../../build.zig`](../../build.zig):

```sh
zig build test                  # 227 tests, six binaries, ~7.7s, no server needed
zig build test-integration      # 29 tests against a live quack_serve() instance
zig build test-wasm             # WASM FFI boundary probe (requires node)
zig build bench                 # decode/encode benchmarks (forces ReleaseFast)
zig build check                 # build the core library only — works on every target
zig build wasm                  # wasm32-freestanding reactor module
zig build examples              # build all four examples
zig build run -- "SELECT 42"    # the CLI
```

Useful variations:

```sh
zig build test --summary all              # per-binary pass counts and timings
zig build test --fuzz                     # coverage-guided fuzzing of the decoder
zig build test -Dfuzz-optimize=debug      # fuzz suite in Debug (see below)
zig build check -Dtarget=wasm32-freestanding   # any target; the CLI is skipped for wasm
zig build test-integration -Dquack-endpoint=quack:host:9494 -Dquack-token=secret
```

`check` exists because the CLI needs sockets and the library does not — it
builds `src/root.zig` as a static library and nothing else, which is how CI
proves the protocol core is free of native-only dependencies across
x86_64/aarch64 Linux, macOS, Windows, `wasm32-wasi` and `wasm32-freestanding`.

Mutation testing:

```sh
python3 scripts/mutation_test.py            # all 51 mutants, serially
python3 scripts/mutation_test.py --list     # print the catalogue and exit
python3 scripts/mutation_test.py -k params  # only mutants whose name contains "params"
python3 -u scripts/mutation_test.py         # unbuffered — what CI uses
```

`-k` is a plain substring match on the mutant name, and because names are
prefixed by area (`reader/`, `decoder/`, `params/`, `client/`, `result/`,
`pool/`, `uri/`, `vector/`, `validity/`, `message/`) it doubles as an area
filter. `--list` respects `-k`, so `--list -k reader` shows just that area's
eight mutants with their files. Exit status is non-zero if any unexpected
mutant survives, which is what lets it gate CI.

## The cost of mutation testing

Mutation testing is by far the most expensive thing in this repository. On this
machine a full run is on the order of **an hour**. The reasons are structural,
not incidental:

- **One full `zig build test` per mutant, strictly serially.** 51 mutants means
  52 suite runs including the baseline. Nothing is batched, because two
  simultaneous mutants would confuse attribution.
- **Zig's build cache necessarily misses.** The cache is keyed on content
  hashes. Every mutant edits a file under `src/`, so the hash changes and the
  affected compilations must be redone. This is not a cache that can be tuned —
  it is doing exactly the right thing.
- **One edited line rebuilds six test binaries.** Every mutated file is
  reachable from `src/root.zig`, and `src/root.zig` is the root module (directly
  or via an import) of `lib_tests`, `golden`, `cli_tests`, `decoder_tests`,
  `client_tests` **and** `fuzz_tests`. Touching one line in
  `src/serialization/reader.zig` therefore recompiles all six.
- **Restoration destroys the cache benefit in both directions.** The tree is
  restored to pristine after each mutant, so the next mutant starts from the
  original hashes again — consecutive mutants cannot share compilation work,
  and neither can a mutant reuse the previous mutant's.

Measured on this machine: `zig build test` with a warm cache is **7.7 s**; after
appending a single comment line to `src/params.zig` the same command takes
**71 s**. That ~63 s of rebuild, not the ~8 s of testing, is what a mutant
actually costs. 51 × ~71 s ≈ 60 minutes before hangs.

And then there are the hangs. Every mutant that turns the suite into an infinite
loop spends the **full** per-mutant timeout — `max(45, 6 × baseline)` seconds —
before being killed and (correctly) recorded as CAUGHT. The known candidates:

| Mutant | Why it spins |
|---|---|
| `result/fetch-ceiling` | Removes the `max_fetches` bound, so a mock server that never sends an empty batch is fetched from forever |
| `result/empty-batch-terminates` | Removes the end-of-stream signal, so the stream never finishes |
| `pool/deinit-waits-for-leases` | Removes the shutdown wait (this one is an expected survivor, but the wait is what makes `deinit` bounded) |
| `pool/mutual-exclusion` | Removes the mutex around the pool's state, so the multi-threaded tests can deadlock or spin |

Mitigations, in the order worth trying:

1. **Use `-k` during development.** If you changed `src/params.zig`, run
   `python3 scripts/mutation_test.py -k params` — eight mutants instead of 51,
   roughly a twelfth of the time. Save the full run for CI or a pre-release
   check.
2. **Scope the test step per mutant.** A mutant in `src/uri.zig` cannot be
   caught by `fuzz_tests`, and one in `src/params.zig` cannot be caught by
   `golden`. Adding a per-binary build step (say `test-lib`, `test-golden`) and
   letting catalogue entries declare which one to run would cut both the compile
   and the run for most mutants. This costs a little rigour — a mutant scoped to
   the wrong binary would be wrongly reported as SURVIVED — so the mapping has to
   be conservative.
3. **Parallelise across git worktrees.** Each mutant is independent and touches
   exactly one file, so N worktrees with their own `.zig-cache` can run N
   mutants at once with no interference. This is the biggest available win and
   scales with cores; the cost is N× disk for the caches.
4. **Shorten the timeout for the known hangers.** The four mutants above are
   known to hang. A per-entry timeout override (a few seconds for those, the
   derived ceiling for everything else) removes most of the timeout cost without
   risking a false CAUGHT elsewhere. Note the current derived timeout is already
   a large improvement over the previous fixed 240 s ceiling.
5. **Keep the suite fast.** The fuzz layer's ReleaseSafe build is exactly this
   lever, and it is worth understanding: the fuzz suite performs ~25,000 decodes
   of mutated input, which costs ~14 s in Debug and ~0.2 s optimised — a ~680×
   difference driven by allocator bookkeeping and the absence of inlining, not
   by the amount of work. In Debug it was roughly 80% of the entire test run.
   ReleaseSafe keeps every check the fuzzing relies on (bounds, overflow,
   `unreachable`), which was verified by reintroducing the original varint
   overflow bug and confirming it still panics. `build.zig` selects it
   automatically when the outer build is Debug; `-Dfuzz-optimize=debug`
   overrides for a Debug-level investigation.

## Regenerating the golden fixtures

When validating against a new DuckDB release:

```sh
duckdb -c "LOAD quack; CALL quack_serve('quack:localhost:9494', token => 'super_secret');"
python3 scripts/capture_fixtures.py
```

The script needs a live server on `localhost:9494` with that exact token — both
are hardcoded, so edit the script or forward a port if your setup differs. It
performs its own handshake, prints the session id, writes
`connection_response.bin`, then issues each of the 29 queries in its `QUERIES`
map and writes the raw response bytes to `<name>.bin`. Finally it rewrites
`manifest.json` with the SQL, byte length and response message type for each
fixture, which is what makes a diff on that file a readable summary of what
changed upstream.

Then run `zig build test`. A diff in the `.bin` files with green tests means
DuckDB changed something we tolerate; a red test means it changed something we
do not yet handle.

**Why the independence matters.** The script implements the protocol from
scratch: its own ULEB128 writer, its own `<H` field-id framing, its own
terminator constant, its own minimal reader for the handshake response. It never
imports or invokes Quackling. If it were replaced by a wrapper around the Zig
client — even a thin one — the fixtures would stop being evidence about DuckDB
and become a snapshot of our own behaviour, and the golden layer would degrade
from a conformance test to a regression test. Keep it independent, even at the
cost of duplicating a varint encoder.

Two notes for whoever does the next capture:

- `capture_fixtures.py` advertises `"v1.4.1"` as the *client* version string in
  its handshake, matching `client_version_string` in
  `src/protocol/compat.zig`. That is the client's self-description and is
  unrelated to the server version; the current fixtures were captured from a
  DuckDB v1.5.5 server.
- If a query fails, the script prints `<name> ERR <exception>` and continues,
  leaving the previous `.bin` in place while omitting that entry from the new
  manifest. Check the output for `ERR` lines and compare manifest entry counts
  (currently 29) rather than assuming a clean run.

## Adding a test to the right layer

Pick the cheapest layer that can actually observe the property.

| You are testing | Layer | Where |
|---|---|---|
| A pure function, a boundary value, an encoding rule | 1 — unit | inline `test` in the module; if it is a new module, add it to the `_ = @import(...)` list in `src/root.zig` |
| That we read a real DuckDB payload correctly, or a newly supported type | 2 — golden | new query in `capture_fixtures.py` + re-capture + test in `golden_test.zig`; assert values *and* `isAtEnd()` |
| That a bounds check rejects a structure a real server never sends | 3 — decoder guard | `decoder_test.zig`, using the `B` byte DSL; add the positive control too |
| Session state, error classification, streaming, cancellation, non-leakage | 4 — client | `client_test.zig` with a `Script` of mock responses |
| That *any* input is handled without UB | 5 — fuzz | usually just add the fixture to the `corpus` array; add a hostile body to the `bodies` list for a specific shape |
| That a real DuckDB agrees with us | 6 — integration | `integration_test.zig`, via `Harness.init` so it skips without a server |
| A new WASM export | 6 — WASM | add hostile-argument probes to both the pre-query and loaded-result phases of `boundary_test.mjs` |

Then, if what you added is a **guard** — a bounds check, an escaping rule, a
limit, a version check — add a mutant for it to `MUTANTS` in
`scripts/mutation_test.py` and confirm it is CAUGHT:

```sh
python3 scripts/mutation_test.py -k your-new-mutant-name
```

A guard with no mutant is a guard nobody has verified is load-bearing. If the
mutant survives, the test you just wrote does not actually depend on the guard,
and the fix is the test, not the catalogue.
