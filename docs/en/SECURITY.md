# Security

**English** · [日本語](../ja/SECURITY.md)
→ [Documentation index](./README.md)

A Quack server exposes SQL execution over HTTP. A Quack *client* parses whatever
that server — or anything that can impersonate it — sends back. This document
states what Quackling defends against, how each defence is implemented and
tested, and what it explicitly does not cover.

## Contents

- [Threat model](#threat-model)
- [Token handling](#token-handling)
- [Memory safety](#memory-safety)
- [Resource limits](#resource-limits)
- [SQL injection boundary](#sql-injection-boundary)
- [Endpoint validation](#endpoint-validation)
- [Protocol version negotiation](#protocol-version-negotiation)
- [Denial of service](#denial-of-service)
- [Verification](#verification)
- [Not covered / out of scope](#not-covered--out-of-scope)
- [Reporting a vulnerability](#reporting-a-vulnerability)

## Threat model

**The client consumes untrusted bytes from the network. The decoder is the whole
attack surface.**

Quackling sends a request and gets back a byte string. Everything interesting
about that byte string — message type, field ids, length prefixes, element
counts, nesting structure, type tags, payload widths — is chosen by the peer. A
compromised server, a hostile proxy, an off-path attacker on a plaintext
connection, or simply a buggy server can put arbitrary bytes there.

Assume, in the client's threat model:

- The response body is fully attacker-controlled.
- The HTTP status and headers are attacker-controlled.
- The peer may stall, may never terminate a stream, and may lie about lengths.
- The SQL text is chosen by *our* caller, and parameter values may be untrusted
  input from that caller's own users.

The contract, stated in
[`../../tests/fuzz_test.zig`](../../tests/fuzz_test.zig):

> The decoder is the only component that consumes untrusted bytes, so the
> contract it must uphold is narrow and absolute: **arbitrary input produces
> either a successful decode or a typed error — never a panic, an
> out-of-bounds read, an integer overflow, or unbounded allocation.**

Two consequences of how the library is structured make this contract auditable.
First, the protocol/serialization/type layers are pure computation over byte
slices — no sockets, no libc, no OS calls — so all untrusted-byte handling is
confined to code you can reach with a `[]const u8` and a testing allocator.
Second, transport is injected by the caller, so the decoder can be driven by a
mock or a fuzzer with no network at all.

What is explicitly *not* in scope: protecting the server from its own clients,
authorisation (Quack has a single shared token and no notion of users), and
anything about the SQL semantics of a query the caller chose to run.

## Token handling

The auth token travels **inside the protocol body**, as field 1 of
`CONNECTION_REQUEST` — not as an HTTP header, not in the URL. See
[`../en/PROTOCOL.md`](./PROTOCOL.md) for the framing.

That has one unavoidable implication:

> **Use TLS for anything beyond localhost. The DuckDB server does not terminate
> TLS itself, so put a reverse proxy in front of it.**

Without transport encryption the token is on the wire in cleartext on every
handshake. A reverse proxy (nginx, Caddy, a cloud load balancer) terminating TLS
and forwarding to `quack_serve()` on loopback is the supported deployment.
`ClientOptions.headers` exists partly for this case — an authenticating proxy
can be satisfied with extra HTTP headers without touching the Quack token.

Quackling never logs, prints, or includes the token in an error message. There
are no log statements in the library at all: observability goes through the
`Observer` callback and the `Stats` struct, neither of which is given the token.
`Client.lastError()` returns the server's own message text, verbatim and
unmodified.

This is enforced by tests, not just intended.
[`../../tests/client_test.zig`](../../tests/client_test.zig) has *"the auth token
never leaks into errors, stats or debug output"*, which drives a failing
handshake with a distinctive secret and asserts the secret appears in none of:

| Surface | Assertion |
|---|---|
| `client.lastError()` | secret absent |
| `client.url` | secret absent |
| formatted `client.stats` | secret absent |
| `mock.sent.items[0]` (the handshake body) | secret **present** — asserted positively |

The last row matters: the test pins down the one place the token belongs, so a
future refactor that stopped sending it, or started sending it somewhere else,
fails.

A companion test, *"a query error message cannot echo the token"*, scripts a
server that reflects the token back inside an error string and asserts the
message is preserved verbatim. The guarantee is deliberately precise: **we never
add the token to anything; we do not censor the server.** If your server echoes
secrets into error text, that is a server-side problem, and Quackling will not
silently hide it from you.

Operational notes:

- The token is stored in `ClientOptions` for the lifetime of the client, because
  reconnection needs it. It is not zeroed on `deinit`.
- A `Pool` shares one token across every pooled connection.
- Failed auth is classified as `error.AuthenticationFailed`, distinct from
  `error.ServerError`, so a caller can react without string-matching. The
  classification is by message text (`"authenticat"`, `"invalid token"`,
  `"unauthorized"`, case-insensitive) because the server reports a bad token as
  an ordinary error response — see
  [Error classification](#protocol-version-negotiation) below. Matching is
  deliberately narrow: a false negative degrades to `ServerError`, which is
  still accurate.

## Memory safety

- **Every decode is bounds-checked.** `Reader.take(n)` refuses when
  `n > remaining()`, and every primitive reader goes through it. See
  [`../../src/serialization/reader.zig`](../../src/serialization/reader.zig).
- **Wire data is never `@ptrCast` into a struct.** There is no `extern struct`
  overlaid on a response buffer anywhere in the decode path. Every field is read
  explicitly, one at a time, by a function that can fail.
- **Fixed-width values are read with explicit little-endian loads.**
  `std.mem.readInt(T, bytes[off..][0..@sizeOf(T)], .little)` and `@bitCast` for
  floats — so decoding is correct on a big-endian target and does not depend on
  the host's byte order.
- **Alignment is not assumed.** Quack payloads are byte-packed and generally not
  aligned for the type they contain. Two accessors, two contracts:

  | Accessor | Behaviour |
  |---|---|
  | `Vector.asSlice(T)` | Returns `?[]const T` — **null** unless the vector is a flat run of `T` *and* the borrowed buffer happens to be correctly aligned (`@intFromPtr(ptr) % @alignOf(T) == 0`). Treat a non-null result as an optimisation, never the normal path. |
  | `Vector.at(T, i)` | Always works for a flat run of `T`: bounds-checks `i`, then performs an explicit little-endian load. Alignment is irrelevant. |
  | `Vector.copySlice(T, out)` | Bulk alternative when alignment does not cooperate; one pass into caller-owned memory. |

  `asSlice` returning null is a *feature*. The mutation catalogue contains
  `vector/asslice-alignment`, which removes that alignment test — and the suite
  catches it.
- **Neither accessor consults the validity mask.** `asSlice` and `at` return raw
  stored values; a NULL row has *some* value in the payload. Check
  `vector.validity` alongside them. This is documented at both call sites and is
  a correctness trap rather than a memory-safety one.
- **Error paths free their memory.** The fuzz suite runs every decode under
  `std.testing.allocator` and frees on both the success and failure paths, so a
  leak on a malformed-input path is a test failure. Leaks on nested-type error
  paths were a real defect found this way (see
  [Verification](#verification)).

## Resource limits

Length and count prefixes are validated against **both** a configurable limit
**and** the bytes actually remaining, **before any allocation**. Both halves are
necessary: the configurable limit stops a large-but-plausible claim, and the
remaining-bytes check stops a claim that is arithmetically impossible for the
buffer in hand. A hostile length field therefore cannot drive a large
allocation.

| Guard | Where | Default | Attack it stops | How to tune |
|---|---|---|---|---|
| `Limits.max_byte_length` | `Reader.readLength` | **256 MiB** (`256 * 1024 * 1024`) | A single string/blob length prefix claiming an absurd size | `Reader.initWithLimits`. `Client` derives it from `max_response_bytes`, so lowering that lowers this too |
| length vs `remaining()` | `Reader.readLength` | n/a — always on | A length prefix larger than the bytes actually present; rejected before allocating | not tunable, by design |
| `Limits.max_list_length` | `Reader.readListLength` | **64 Mi elements** (`64 * 1024 * 1024`) | A list/element count claiming 2^32 entries so the allocation is huge even though each element is small | `Reader.initWithLimits` |
| count vs `remaining()` | `Reader.readListLength` | n/a — always on | Same, from the other side: every element costs ≥ 1 byte, so a count exceeding the bytes left is guaranteed-truncated input | not tunable, by design |
| `Limits.max_depth` | `Reader.enterObject` | **64** | A deeply nested message exhausting the stack through the recursive type/vector decoders | `Reader.initWithLimits` |
| `Reader.take` bounds | every primitive read | n/a — always on | Any read walking off the end of the buffer | not tunable, by design |
| `ClientOptions.max_response_bytes` | `Client.roundTrip` | **256 MiB** | An oversized response body being decoded at all; also propagated into the reader's `max_byte_length` | `ClientOptions` |
| `NativeTransport.Options.max_response_bytes` | `native.sendFn` | **256 MiB** | The same cap one layer lower, so the transport refuses before the body reaches the client | `NativeTransport.init` |
| `Result.max_fetches` | `Result.fetchNextBatch` | **5,000,000** | A peer that never signals end-of-stream keeping the client in a FETCH loop forever | assign to the field on a `Result` |
| `standard_vector_size` row cap | `decoder.zig` | **2048** | A chunk claiming more rows than a DuckDB vector can hold | fixed by the format |
| `PoolOptions.max_connections` | `Pool.acquire` | **8** | Unbounded connection growth under load; with `wait_policy = .fail`, sheds load instead of queueing | `PoolOptions` |

On `max_fetches`, from [`../../src/result.zig`](../../src/result.zig):

> End-of-stream is signalled by the *server* sending an empty batch, so a server
> that never does would otherwise loop forever. At the documented batch size
> (12 chunks × 2048 rows) this ceiling still allows well over 10^11 rows, so it
> cannot be reached by legitimate use — it exists purely to keep a broken or
> hostile peer from hanging the caller.

Exceeding it yields `error.FetchLimitExceeded` and marks the result finished.

If you are decoding responses from a server you do not fully trust, tighten
rather than accept the defaults. The fuzz suite's own settings are a reasonable
model for a hostile environment: `max_byte_length` 1 MiB, `max_list_length`
65536, `max_depth` 32.

## SQL injection boundary

**Quack protocol version 1 has no wire representation for parameters.**
`PREPARE_REQUEST` carries exactly one field — the SQL string — and the server
calls `SendQuery(sql)` with it directly. Two facts were verified against a live
server and recorded in
[`../../src/params.zig`](../../src/params.zig):

- `SELECT ?` returns *"Expected 1 parameters, but none were supplied"* — there is
  no channel to supply them.
- Adding an extra field to `PREPARE_REQUEST` makes the server return HTTP 500 —
  unknown fields are rejected, so we cannot invent one.

So parameters are rendered into the SQL text **client-side**, and the entire
safety burden falls on that one file. It is written accordingly: anything that
cannot be encoded unambiguously is rejected rather than approximated.

Callers who want genuine server-side prepared statements can use SQL-level
`PREPARE` / `EXECUTE`, which the protocol handles fine.

### What `bind()` enforces

| Rule | Detail |
|---|---|
| Quote escaping | A `'` inside a text parameter is doubled (`''`). `"o'brien"` renders as `'o''brien'`. |
| String literals skipped | A `?` inside a `'...'` literal is data, not a placeholder. `copyQuoted` copies the region verbatim, honouring doubled-quote escapes. |
| Quoted identifiers skipped | The same treatment for `"..."`. |
| Dollar-quoted strings skipped | `$tag$ ... $tag$` regions are copied through. The tag may contain only alphanumerics and `_`; anything else means it was not a dollar quote and the `$` is copied literally. |
| Line comments skipped | `--` to the next newline (or end of input) is copied verbatim. |
| Block comments skipped | `/*` to the matching `*/` (or end of input) is copied verbatim. Note: not nested. |
| Count matching, both directions | Too many placeholders raises `error.ParameterCountMismatch` on the overrun; too few raises the same error at the end. The caller and the query must agree about the shape of the statement. |
| UTF-8 validation | `std.unicode.utf8ValidateSlice`; a malformed sequence raises `error.InvalidUtf8`, so a bad byte sequence cannot produce a surprising parse on the server. |
| NUL rejection | An embedded `0x00` in a text parameter raises `error.UnsupportedParameter` — DuckDB cannot carry it inside a string literal. |
| Restricted parameter set | `Param` is deliberately smaller than `Value`: only variants with an exact, unambiguous SQL literal form. Lossy or dialect-dependent types are omitted rather than guessed at. |
| Blobs fully hex-escaped | Every byte becomes `\xHH` inside `'...'::BLOB` — unambiguous and immune to quoting issues in binary data. |
| Non-finite doubles handled | NaN/±Inf have no plain literal form, so they render as `'NaN'::DOUBLE` etc.; finite doubles use the shortest round-trip form with a `::DOUBLE` cast so DuckDB does not read them as DECIMAL. |
| Errors raised before I/O | A parameter error is returned before anything is sent. There is a client test asserting exactly that. |

Failure modes are checked before sending, so an injection attempt becomes a
literal rather than a statement: `"'; DROP TABLE users; --"` renders as a single
quoted string. There are unit tests for that case in `src/params.zig` and a live
`integration: parameter binding resists SQL injection` test.

### ⚠️ WARNING: `.raw_sql`

`Param{ .raw_sql = "..." }` is inserted **verbatim, with no escaping of any
kind**. It exists so an expression can be used where a value would go —
`now()`, a column reference, a function call.

**Never construct a `.raw_sql` value from untrusted input.** Doing so is a
direct SQL injection, and no other check in this library will catch it: the
count check still counts it, the UTF-8 and NUL checks do not apply to it, and
the escaping rules above are specifically the code path it bypasses. If the
string came from a request parameter, a config file you do not control, a
database column, or a filename, it must not become `.raw_sql`.

If you need a dynamic identifier (a table or column name), validate it against
an allow-list of names you control before it goes anywhere near `.raw_sql`.

## Endpoint validation

[`../../src/uri.zig`](../../src/uri.zig) accepts `quack:host[:port]` (DuckDB's
own form), `quack://host[:port]`, and plain `http://` / `https://` URLs.
Validation is deliberately strict.

| Rejected | Error | Why |
|---|---|---|
| Embedded credentials (`@` anywhere in the authority) | `error.InvalidUrl` | They would be silently dropped — Quack authenticates in the body, not the URL. A URL that *looks* authenticated but is not is worse than an error. |
| Control characters and space in the host (`c <= 0x20 or c == 0x7F`) | `error.InvalidUrl` | Prevents header/request smuggling and unreadable hosts from being pasted into a URL. |
| Port `0` | `error.InvalidPort` | Never a real destination; usually a parse accident. |
| Empty host | `error.EmptyHost` | |
| Unparseable / out-of-range port | `error.InvalidPort` | `parseInt(u16)`, so `70000` is rejected rather than truncated. |

Path, query and fragment are dropped: the endpoint path is fixed by the protocol
(`/quack`). IPv6 literals are handled explicitly — bracketed form is parsed and
re-bracketed when the URL is built, and a bare IPv6 address (more than one colon
and no brackets) is treated as a host without a port rather than having its last
group misread as one.

Validation happens in `Client.init`, so a bad endpoint fails before any I/O.
There is a client test asserting that (*"an invalid endpoint fails at init,
before any I/O"*), and three mutants (`uri/embedded-credentials`,
`uri/control-characters`, `uri/zero-port`) confirming each rejection is
load-bearing.

## Protocol version negotiation

The client advertises Quack version 1 and refuses a server outside the supported
range rather than guessing. From
[`../../src/protocol/compat.zig`](../../src/protocol/compat.zig):

```zig
pub const min_supported_version: u64 = 1;
pub const max_supported_version: u64 = 1;
```

In `Client.connect`, after decoding `CONNECTION_RESPONSE`:

```zig
if (body.quack_version < compat.min_supported_version or
    body.quack_version > compat.max_supported_version)
{
    return errors.ProtocolError.UnsupportedProtocolVersion;
}
```

Both bounds are checked. The lower bound is not cosmetic — a missing lower-bound
check was a real defect found by mutation testing, and both directions now have
their own mutant (`client/protocol-version-min`,
`client/protocol-version-max`). Quack is beta and upstream expects breaking
changes; misreading a version 2 chunk as version 1 is exactly the failure this
check exists to prevent.

The handshake also requires a session id: `CONNECTION_RESPONSE` carries it in
the *header*, and an empty one is rejected with
`error.UnexpectedMessageType` rather than producing a client that believes it is
connected.

Error classification across the whole exchange:

| Situation | Error |
|---|---|
| Server version outside `[min, max]` | `error.UnsupportedProtocolVersion` |
| Handshake response with no session id | `error.UnexpectedMessageType` |
| Handshake `ERROR_RESPONSE` whose text looks like auth | `error.AuthenticationFailed` |
| Handshake `ERROR_RESPONSE`, any other text | `error.ServerError` |
| Any other message type where a handshake response was due | `error.UnexpectedMessageType` |
| HTTP status outside 2xx | `error.HttpError` (no decode attempted) |
| Body larger than `max_response_bytes` | `error.ResponseTooLarge` |
| Malformed bytes | a `SerializationError` — `UnexpectedEndOfBuffer`, `VarIntOverflow`, `LengthLimitExceeded`, `UnexpectedFieldId`, `UnexpectedField`, `MalformedVector`, `RowCountTooLarge` |
| A type or vector encoding we do not implement | `error.UnsupportedType` / `error.UnsupportedVectorType` — never a guess |

The error sets in [`../../src/error.zig`](../../src/error.zig) are grouped by
*cause* precisely so a caller can distinguish "the network broke" from "the
server rejected my SQL" from "this response is not valid Quack" without parsing
strings.

## Denial of service

| Attack | Guard |
|---|---|
| Peer never signals end-of-stream (never sends the empty batch) | `Result.max_fetches` (5,000,000) → `error.FetchLimitExceeded`. There is a client test named *"a server that never signals end-of-stream cannot hang the client"*, and the mutant `result/fetch-ceiling` is caught **by hanging** — which is how the original unbounded loop was found. |
| Hostile length field claiming a huge string/blob | `max_byte_length` **and** length-vs-`remaining()` in `readLength`, both before any allocation |
| Hostile count field claiming a huge element count | `max_list_length` **and** count-vs-`remaining()` in `readListLength`; each element costs ≥ 1 byte, so an impossible count is rejected immediately |
| Deeply nested message exhausting the stack | `max_depth` (64) enforced by `enterObject`; the fuzz suite drives 200 nested `LogicalType` objects against a limit of 16 and requires an error, not a stack death |
| Oversized response body | `max_response_bytes` (256 MiB) at both the transport and client layers → `error.ResponseTooLarge` |
| Row count beyond a DuckDB vector | `rc > standard_vector_size` (2048) → `error.RowCountTooLarge` |
| Varint that never terminates / overflows | `VarIntOverflow` on shift ≥ 64 and on a payload exceeding the target width; two separate mutants cover the two halves |
| Unbounded memory growth while streaming a large result | Only one FETCH batch is resident at a time — the previous batch is released before the next is requested. Measured peak RSS: 100 k rows → 2.6 MB, 1 M rows → 2.7 MB, 5 M rows → 2.9 MB. An integration test asserts this bound. |
| Connection exhaustion under load | `PoolOptions.max_connections` (8) with `wait_policy` — `.wait` queues, `.fail` returns `error.PoolExhausted` immediately so a request handler can shed load |
| Slow/stalled peer | `ClientOptions.timeout_ms` is passed to the transport, and a `CancelToken` can abort a query before it is sent or mid-stream. **Caveat:** `NativeTransport` currently documents `timeout_ms` as reserved — `std.http.Client` does not expose a granular timeout hook yet, so cancellation via `CancelToken` is the mechanism that actually works today. |

What is *not* guarded: a peer that responds slowly but within limits, and a
server that returns a legitimately enormous result. Both are policy decisions for
the caller — set `max_response_bytes`, `max_fetches` and a cancel token
according to what your application considers reasonable.

## Verification

Every property above is either fuzzed, mutation-tested, or both. See
[TESTING.md](./TESTING.md) for the full strategy; the security-relevant summary:

**Fuzzing** ([`../../tests/fuzz_test.zig`](../../tests/fuzz_test.zig)) — ~25,000
decodes per run across three strategies: every prefix of every fixture in a
17-fixture corpus; every byte of every fixture set to each of
`0x00/0x01/0x7F/0x80/0xFF`; 4000 pseudo-random buffers plus hand-built hostile
bodies (a list claiming 2^32 elements, a string claiming 2^40 bytes, a
never-terminating varint, 40 nested objects). Every decode runs under the
testing allocator and frees on both paths, so error-path leaks fail the run.
`zig build test --fuzz` hands the same entry point to Zig's coverage-guided
fuzzer.

**Mutation testing**
([`../../scripts/mutation_test.py`](../../scripts/mutation_test.py)) — removes
each guard one at a time and requires the suite to fail. The rationale, from its
docstring: *a passing test suite only proves the tests run; it does not prove
they would notice if a bounds check disappeared.* The catalogue is **51
mutants** and covers every item in the [Resource limits](#resource-limits)
table, every rule in the [SQL injection boundary](#sql-injection-boundary), all
three [endpoint](#endpoint-validation) rejections, both
[version](#protocol-version-negotiation) bounds, the FETCH ceiling, the
empty-batch stream terminator, the response-size cap, the HTTP status check, the
session-id requirement, the validity-mask semantics and bounds, `asSlice`'s
alignment and length tests, and the pool's locking. A hang counts as CAUGHT,
because a guard whose removal makes the suite spin forever is unambiguously
load-bearing. Current state: **50/50 mutants caught**, plus one documented
`EXPECTED_SURVIVORS` entry (`pool/deinit-waits-for-leases`) whose removal cannot
be observed without relying on undefined behaviour or a race — the reasoning is
recorded in the script rather than left as a silent pass. It runs in CI and fails
the build on any unexpected survivor.

That process found real defects that a green test run had hidden:

| Defect | How it would have failed in production |
|---|---|
| Unbounded FETCH loop | A server that never sends an empty batch hangs the client forever |
| Pool use-after-free | Closing a pool with leases outstanding freed connections still in use |
| Result not invalidated by a new query | A stale result silently streamed the *next* query's rows |
| Varint shift overflow | A malformed length prefix panicked instead of erroring |
| Leaks on nested-type error paths | Malformed STRUCT/LIST responses leaked memory |
| Missing lower-bound version check | A server below the supported range was accepted |

A note on the fuzz build, since it bears on what the fuzzing actually verifies:
the suite is built **ReleaseSafe**, not Debug, because in Debug it costs ~14 s
versus ~0.2 s optimised (~680×, driven by allocator bookkeeping and the absence
of inlining, not by the amount of work). ReleaseSafe keeps every check the
fuzzing relies on — bounds, overflow, `unreachable` — which was verified by
reintroducing the original varint overflow bug and confirming it still panics.
`-Dfuzz-optimize=debug` overrides for a Debug-level investigation.

The WASM FFI boundary is treated as a second untrusted surface, since JavaScript
hands raw indices and lengths straight to the exports:
[`../../tests/wasm/boundary_test.mjs`](../../tests/wasm/boundary_test.mjs) calls
every export with out-of-range and hostile arguments, both before any query and
— the important case — with a real result loaded, and requires that nothing
traps, nothing reads out of bounds, and any returned pointer lands inside linear
memory.

## Not covered / out of scope

Stated plainly, because a security document that only lists strengths is not
useful.

- **TLS is not exercised by the test suite.** Every test, golden capture and
  integration run in this repository went over plain HTTP against loopback. The
  `https` scheme is parsed and passed through to `std.http.Client`, and
  `error.TlsError` exists for `TlsInitializationFailed`, but there is no test
  that establishes a TLS connection. If you deploy behind a TLS-terminating
  proxy — which you should — you are relying on `std.http.Client`'s TLS, not on
  anything this project has verified.
- **Certificate-verification behaviour is neither documented nor tested.** The
  client does not expose knobs for a custom trust store, certificate pinning,
  hostname-verification policy, or client certificates. Whatever
  `std.http.Client` does by default is what happens. If your threat model depends
  on certificate validation specifics, verify them yourself against the Zig
  version you are building with; do not assume this document covers them.
- **Redirects are not handled explicitly.** Redirect following is
  `std.http.Client`'s default behaviour, not a policy this project sets. A
  redirect to a different host would carry the request — including the token in
  the body — somewhere the caller did not name. If that matters to you, front the
  server with a proxy that does not redirect.
- **Real concurrent-load races are hard to test deterministically.** The pool has
  a multi-threaded contention test, a "never leased to two holders at once" test,
  and concurrent acquire/release/discard tests, plus mutants for the mutex and
  the capacity limit. That is not the same as proving absence of races under
  production load. `pool/deinit-waits-for-leases` is in `EXPECTED_SURVIVORS`
  precisely because the failure it prevents can only be observed via undefined
  behaviour or a race — which is an honest admission that this class of bug sits
  at the edge of what a deterministic suite can reach.
- **Integration tests are off the default `test` step, and they skip rather than
  fail when no server is reachable.** A serverless CI run of
  `zig build test-integration` is green and proves nothing about live-server
  conformance. Only the `integration` CI job, which starts a real DuckDB, does.
  If you fork this project and drop that job, you lose the layer that catches an
  upstream wire-format change.
- **The golden fixtures are a snapshot.** They were captured from DuckDB v1.5.5.
  Quack is beta; a newer server may differ in ways no committed byte can reveal
  until someone re-captures (see
  [Regenerating the golden fixtures](./TESTING.md#regenerating-the-golden-fixtures)).
- **No timing-attack hardening.** Token comparison happens on the server, and
  nothing in the client is constant-time.
- **The token is not scrubbed from memory.** It lives in `ClientOptions` for the
  client's lifetime and is not zeroed on `deinit`. A core dump or a process
  memory read exposes it.
- **`NativeTransport.timeout_ms` is currently a no-op**, documented as reserved
  because `std.http.Client` does not expose a granular timeout hook. Do not rely
  on it as a DoS control; use `CancelToken`.
- **No authorisation model.** Quack has one shared token and no notion of users,
  roles or per-statement permissions. Anyone who can present the token can run
  any SQL the server can run. Restrict what the server itself is allowed to do.
- **`.raw_sql` is an unguarded hole by design.** See the warning in
  [SQL injection boundary](#sql-injection-boundary).

## Reporting a vulnerability

There is no dedicated security mailing list or published disclosure policy for
this project. If you find a vulnerability:

- Open an issue in the project's GitHub repository, or contact the maintainer
  through the contact details on the repository page.
- For an issue you consider sensitive, please say so up front and keep the
  initial report brief — enough to establish impact — rather than publishing a
  full exploit immediately.
- A reproducer helps enormously. The most useful form is the byte string that
  triggers it, since the fuzz and decoder-guard layers can absorb it directly as
  a permanent regression test.
