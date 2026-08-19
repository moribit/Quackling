# quackling — Command Line Reference

**English** · [日本語](../ja/CLI.md)

→ [Documentation index](./README.md)

`quackling` is a thin consumer of the Quackling library: it parses arguments,
opens one connection, runs one query, and formats the result. All of its
behaviour lives in [`../../src/cli/main.zig`](../../src/cli/main.zig).

```sh
zig build                       # -> zig-out/bin/quackling
zig build run -- --help         # or run it through the build system
```

---

## 1. Synopsis

```
quackling [options] "<SQL>"
quackling [options] < query.sql
```

The installer also puts `qkl` on your PATH as an alias for the same binary, so
every example here works with either name:

```sh
qkl "SELECT 42"                 # identical to `quackling "SELECT 42"`
```

On Unix the alias is a symlink; on Windows it is a copy, because a symlink there
needs developer mode or elevation. `--version` always prints the canonical name
(`quackling 0.1.0`) so scripts can parse one string regardless of how it was
invoked. Pass `--no-alias` to the installer to skip it.

The SQL is the first non-`--` argument. If several are given, the last one wins
(the parser assigns `args.sql = a` on each bare argument). If none is given,
the CLI reads stdin.

---

## 2. Flag reference

Every flag below is parsed in `parseArgs` in
[`../../src/cli/main.zig`](../../src/cli/main.zig). There are no short forms
other than `-h`, no `--flag=value` syntax (the value is always the *next*
argv entry), and no negative forms.

| Flag | Argument | Default | Meaning |
|---|---|---|---|
| `--url <endpoint>` | required | `quack:localhost:9494` | Server endpoint. Accepts `quack:host[:port]`, `quack://host`, `http://host[:port]`, `https://host[:port]`. |
| `--token <token>` | required | `""` (empty) | Authentication token, sent inside the protocol body. |
| `--format <fmt>` | required | `table` | One of `table`, `csv`, `json`, `ndjson`, `markdown`. Anything else is `error.UnknownFormat`. |
| `--max-rows <n>` | required | unset (all rows) | Stop after `n` rows. Parsed as `u64` base 10; a non-number is a parse error. |
| `--timing` | none | off | Print row count and elapsed wall-clock time after the result. |
| `--stats` | none | off | Print the connection's `Stats` counters after the result. |
| `-h`, `--help` | none | off | Print usage to **stdout** and exit `0`. |

Defaults come from the `Args` struct:

```zig
const Args = struct {
    url: []const u8 = "quack:localhost:9494",
    token: []const u8 = "",
    sql: ?[]const u8 = null,
    format: Format = .table,
    timing: bool = false,
    stats: bool = false,
    help: bool = false,
    max_rows: ?u64 = null,
};
```

Any unrecognised argument starting with `--` is rejected with
`error.UnknownOption` rather than ignored. A flag that needs a value but sits
at the end of argv yields `error.MissingValue`. Both are covered by the inline
test `"unknown format and option are rejected"`.

### Endpoint forms

Parsing lives in [`../../src/uri.zig`](../../src/uri.zig); the protocol
constants are in [`../../src/protocol/compat.zig`](../../src/protocol/compat.zig)
(`default_port = 9494`, `http_path = "/quack"`,
`content_type = "application/vnd.duckdb"`).

| `--url` value | Resolves to |
|---|---|
| `quack:localhost` | `http://localhost:9494/quack` |
| `quack:localhost:9494` | `http://localhost:9494/quack` |
| `quack:myhost:9000` | `http://myhost:9000/quack` |
| `quack://localhost` | `http://localhost:9494/quack` |
| `http://localhost:9494` | `http://localhost:9494/quack` |
| `https://db.example.com` | `https://db.example.com:9494/quack` |

Any path, query or fragment you supply is discarded — the protocol fixes the
path at `/quack`. An endpoint containing embedded credentials (`user@host`) or
control characters is rejected rather than silently rewritten.

---

## 3. `QUACK_TOKEN` environment variable

> **Unverified / not implemented.** The usage text printed by `--help` states:
>
> ```
> The token may also be supplied via the QUACK_TOKEN environment variable.
> ```
>
> **No code reads that variable.** `parseArgs` never consults the environment,
> and there is no other reference to `QUACK_TOKEN` anywhere in the repository
> (the string appears only inside the usage literal itself). Observed against a
> live server:
>
> ```console
> $ QUACK_TOKEN=super_secret quackling "SELECT 42 AS answer"
> connection failed: Authentication failed
> $ echo $?
> 1
> ```
>
> Treat the help text as an aspiration, not a feature. Until it is implemented,
> `--token` is the only way to supply a token.

The motivation behind the documented-but-absent feature is still worth stating,
because it governs how you should pass the token today: a token on the command
line is visible in shell history, in `ps` output, and in CI job logs that echo
their commands. Until `QUACK_TOKEN` works, prefer indirection that keeps the
literal out of history:

```sh
# Read from a file that is not world-readable; the shell expands it, so the
# token still reaches argv - but it is not stored in history.
quackling --token "$(cat ~/.quack-token)" "SELECT 42"
```

```sh
# In CI, expand a masked secret at call time rather than hardcoding it.
quackling --token "$QUACK_SECRET" --format ndjson "SELECT * FROM metrics"
```

Note that even with this pattern the token appears in the process's argv and is
therefore visible to other processes on the same host via `ps`. The token also
travels *inside* the protocol body rather than in an HTTP header, so it is only
protected in transit if you terminate TLS in front of the server — see
[`SERVER_SETUP.md`](./SERVER_SETUP.md).

---

## 4. Output formats

All examples below are real output captured from a live DuckDB v1.5.5 server
running `quack_serve`.

### `table` (default)

Box-drawing output, columns padded to the widest cell.

```console
$ quackling --token super_secret "SELECT 42 AS answer"
┌────────┐
│ answer │
├────────┤
│ 42     │
└────────┘
```

The table formatter buffers up to **1000** rows (`max_buffered`) as rendered
strings to compute column widths. Past that cap it keeps streaming with the
widths already established, so memory stays bounded on a large result — but a
row wider than anything in the first 1000 will overflow its column and the
closing rule will not line up. Observed on a 50 000-row result:

```
│ 49998 │
│ 49999 │
└─────┘
```

If you need aligned output for a large result, cap it with `--max-rows 1000` or
use a machine-readable format.

Column padding counts UTF-8 *codepoints*, not display cells (`displayWidth`
counts non-continuation bytes). Wide and emoji characters therefore render one
cell narrow:

```console
$ quackling --token super_secret "SELECT 'wörld🦆' AS uni"
┌────────┐
│ uni    │
├────────┤
│ wörld🦆 │
└────────┘
```

A result with no columns prints `(no columns)`.

### `csv`

RFC 4180 quoting: a field is quoted only if it contains the separator, a double
quote, `\n` or `\r`; embedded quotes are doubled. **NULL renders as an empty
field.**

```console
$ quackling --token super_secret --format csv \
    "SELECT i, i*1.5 AS d, 'text ,quoted' AS s, NULL AS n FROM range(3) t(i)"
i,d,s,n
0,0.0,"text ,quoted",
1,1.5,"text ,quoted",
2,3.0,"text ,quoted",
```

### `json`

A single JSON array of objects. Numeric types emit bare JSON numbers; 64-bit
and 128-bit integers (`UBIGINT`, `HUGEINT`, `UHUGEINT`) are emitted as
**strings**, because JSON cannot represent them exactly. Everything else —
dates, timestamps, decimals, and all nested types — is emitted as a quoted
string. NULL becomes `null`.

```console
$ quackling --token super_secret --format json \
    "SELECT i, i::VARCHAR AS s, NULL AS n FROM range(2) t(i)"
[
{"i":0,"s":"0","n":null},
{"i":1,"s":"1","n":null}
]
```

```console
$ quackling --token super_secret --format json \
    "SELECT {'a':1} AS s, [1,2] AS l, 9223372036854775807::BIGINT AS big, 18446744073709551615::UBIGINT AS ub"
[
{"s":"{'a': 1}","l":"[1, 2]","big":9223372036854775807,"ub":"18446744073709551615"}
]
```

Keys and string values are escaped (`"`, `\`, `\n`, `\r`, `\t`, and `\u00XX`
for other control bytes), so a value that looks like JSON cannot break the
document. This is covered by the inline tests
`"json output survives a string that looks like json"` and
`"json strings escape control characters and quotes"`.

### `ndjson`

One object per line, no enclosing array and no commas — suitable for streaming
into `jq`, DuckDB's `read_json`, or a log pipeline.

```console
$ quackling --token super_secret --format ndjson \
    "SELECT i, i::DOUBLE AS d FROM range(3) t(i)"
{"i":0,"d":0}
{"i":1,"d":1}
{"i":2,"d":2}
```

### `markdown`

A GitHub-style pipe table. The cell separator `|` is escaped as `\|` so a value
cannot break the table structure.

```console
$ quackling --token super_secret --format markdown \
    "SELECT i, 'a|b' AS piped FROM range(2) t(i)"
| i | piped |
| --- | --- |
| 0 | a\|b |
| 1 | a\|b |
```

---

## 5. How values render

NULL, nested types and ENUMs are rendered by `renderCell` / `writeNested` in
[`../../src/cli/main.zig`](../../src/cli/main.zig), mirroring DuckDB's own text
form. All output below is real.

```console
$ quackling --token super_secret \
    "SELECT {'a': 1, 'b': 2} AS s, [10,20,30] AS l, MAP{'a':1,'b':2} AS m, NULL AS n"
┌──────────────────┬──────────────┬────────────┬──────┐
│ s                │ l            │ m          │ n    │
├──────────────────┼──────────────┼────────────┼──────┤
│ {'a': 1, 'b': 2} │ [10, 20, 30] │ {a=1, b=2} │ NULL │
└──────────────────┴──────────────┴────────────┴──────┘
```

| Type | Rendering | Note |
|---|---|---|
| NULL | `NULL` in `table`/`json`-as-`null`; **empty** in `csv`/`markdown` | |
| `STRUCT` | `{'a': 1, 'b': 2}` | Field names quoted, `: ` separator |
| `LIST` / `ARRAY` | `[10, 20, 30]` | Empty list prints `[]` |
| `MAP` | `{a=1, b=2}` | `=` separator, keys **not** quoted — deliberately different from STRUCT |
| `UNION` | the active member's rendering | Resolved before the STRUCT branch |
| `ENUM` | the label, e.g. `happy` | Not the underlying integer |

MAP and UNION are checked *before* STRUCT and LIST, because both are physically
a LIST/STRUCT on the wire; without that ordering they would render their
internal shape instead of the type the user asked for.

Nesting composes to any depth:

```console
$ quackling --token super_secret "SELECT [[1,2],[3]] AS nested, {'x': [1,2]} AS sl"
┌───────────────┬───────────────┐
│ nested        │ sl            │
├───────────────┼───────────────┤
│ [[1, 2], [3]] │ {'x': [1, 2]} │
└───────────────┴───────────────┘
```

ENUM labels resolve correctly:

```console
$ quackling --token super_secret \
    "SELECT 'happy'::ENUM('happy','sad') AS mood, 'sad'::ENUM('happy','sad') AS m2"
┌───────┬─────┐
│ mood  │ m2  │
├───────┼─────┤
│ happy │ sad │
└───────┴─────┘
```

Other scalars:

```console
$ quackling --token super_secret \
    "SELECT NULL::INT AS a, '' AS empty_str, TRUE AS b, DATE '2024-01-15' AS d, 1.25::DECIMAL(10,4) AS dec"
┌──────┬───────────┬──────┬────────────┬────────┐
│ a    │ empty_str │ b    │ d          │ dec    │
├──────┼───────────┼──────┼────────────┼────────┤
│ NULL │           │ true │ 2024-01-15 │ 1.2500 │
└──────┴───────────┴──────┴────────────┴────────┘
```

In `csv` and `markdown`, a nested value is rendered structurally and then
escaped as a normal field, so it may be quoted:

```console
$ quackling --token super_secret --format csv "SELECT {'a':1} AS s, [1,2] AS l"
s,l
{'a': 1},"[1, 2]"
```

A scalar type that neither `Value` nor the structural renderer can model prints
`<unsupported>` rather than failing the whole query.

---

## 6. SQL from stdin and from a file

When no SQL argument is present, the CLI reads stdin, trims surrounding
whitespace, and uses the result if non-empty. Input is capped at **1 MiB**.

```console
$ echo "SELECT 42 AS from_stdin" | quackling --token super_secret
┌────────────┐
│ from_stdin │
├────────────┤
│ 42         │
└────────────┘
```

A file works the same way, and multi-line SQL is fine:

```console
$ cat query.sql
SELECT i, i*i AS sq
FROM range(3) t(i)

$ quackling --token super_secret < query.sql
┌───┬────┐
│ i │ sq │
├───┼────┤
│ 0 │ 0  │
│ 1 │ 1  │
│ 2 │ 4  │
└───┴────┘
```

Because stdin is only consulted when the SQL argument is absent, an explicit
argument always takes precedence — piping into a command that already has SQL
silently ignores the pipe. Only one statement is sent per invocation; the SQL
text is passed to the server verbatim.

---

## 7. `--timing` and `--stats`

```console
$ quackling --token super_secret --stats "SELECT 42"
┌────┐
│ 42 │
├────┤
│ 42 │
└────┘

requests=2 queries=1 fetches=0 chunks=1 rows=1 sent=127B recv=168B errors=0/0/0
```

`--timing` measures from just before `connect()` to just after the last row is
formatted, so it **includes** the connection handshake:

```
49999 row(s) in 7777.620 ms
```

The counter line is produced by `Stats.format` in
[`../../src/stats.zig`](../../src/stats.zig).

| Counter | Struct field | Meaning |
|---|---|---|
| `requests` | `requests` | HTTP round trips, including the CONNECTION handshake. `2` for a one-query session (connect + prepare). |
| `queries` | `queries` | `PREPARE_REQUEST` messages sent — one per `query()` call. |
| `fetches` | `fetches` | `FETCH_REQUEST` round trips needed beyond the first response. `0` when the whole result fit in `PREPARE_RESPONSE`. |
| `chunks` | `chunks_received` | DataChunks decoded. The server batches up to `quack_fetch_batch_chunks` (default 12) per response. |
| `rows` | `rows_received` | Rows across all decoded chunks. May exceed the rows you printed if `--max-rows` stopped the output early. |
| `sent` | `bytes_sent` | Request body bytes, all messages summed. |
| `recv` | `bytes_received` | Response body bytes, all messages summed. |
| `errors=a/b/c` | `server_errors` / `transport_errors` / `protocol_errors` | The error triple, in that order. |

The error triple distinguishes *who* failed:

- **`server_errors`** — the server replied with `ERROR_RESPONSE`. The request
  was understood and refused: bad SQL, missing table, failed authentication.
- **`transport_errors`** — the HTTP round trip itself failed: connection
  refused, timeout, non-2xx status.
- **`protocol_errors`** — a reply arrived but could not be decoded, or was not
  the message type expected. This is the one that indicates a genuine
  client/server mismatch and is worth reporting.

A healthy run reads `errors=0/0/0`. Note that the counters are printed *after*
the result, so a failed query exits before reaching them — `--stats` shows you
the state of a session that got far enough to produce output.

Reading the 50 000-row example: `requests=5` = 1 connect + 1 prepare + 3
fetches; `chunks=25` over 50 000 rows means the server sent 12 chunks in
`PREPARE_RESPONSE` and the rest across 3 FETCH batches.

---

## 8. Exit codes and error output

All diagnostics go to **stderr**; only results go to stdout, so redirecting
stdout gives you clean data.

| Code | Condition | Message |
|---|---|---|
| `0` | Success, or `--help` | — |
| `1` | Connection failed, query failed, or a formatting/IO error | `connection failed: …`, the server's own text, or `error: <Name>` |
| `2` | Argument parsing failed, or no SQL was supplied | `error: <ErrorName>` followed by the full usage text |

Verified behaviour:

```console
$ quackling --token wrong "SELECT 42"
connection failed: Authentication failed
$ echo $?
1
```

```console
$ quackling --token super_secret --url quack:localhost:9999 "SELECT 42"
connection failed: ConnectionFailed (quack:localhost:9999)
$ echo $?
1
```

```console
$ quackling --token super_secret "SELECT * FROM no_such_table"
Table with name no_such_table does not exist!
Did you mean "pg_tables"?

LINE 1: SELECT * FROM no_such_table
                      ^
$ echo $?
1
```

```console
$ quackling --format xml "SELECT 1"
error: UnknownFormat

quackling - query a remote DuckDB over the Quack protocol
… (full usage)
$ echo $?
2
```

```console
$ quackling --token super_secret < /dev/null
error: no SQL provided

… (full usage)
$ echo $?
2
```

Note the shape of the two failure paths. When the server supplied a message,
the CLI prints *the server's own words* and nothing else — a query failure
prints the DuckDB error verbatim, with no `error:` prefix, so it reads like a
`duckdb` CLI error. Only when the server said nothing does the CLI fall back to
the Zig error name, adding the endpoint for a connection failure so you can see
which URL was actually tried. The token is never echoed in any of these paths.

`--help` writes to stdout and exits `0`, so `quackling --help | less` works;
usage printed as part of an *error* goes to stderr with exit `2`.

---

## 9. Layering

The module docstring of [`../../src/cli/main.zig`](../../src/cli/main.zig) states
the rule this file follows:

> Everything here is presentation and argument handling. No protocol logic
> lives in this file, and nothing in the core library knows the CLI exists.

Concretely, CLI-specific behaviour lives **entirely** in `src/cli/` and none of
it leaks into the library:

- Formatting (`table`, `csv`, `json`, `ndjson`, `markdown`), escaping, column
  width calculation and nested-type text rendering exist only in
  `src/cli/main.zig`. The library exposes `DataChunk`, `Vector` and `Value`;
  turning those into text is the CLI's job.
- [`../../build.zig`](../../build.zig) builds `quackling` as a separate
  executable that *imports* the `quackling` module. The library never imports
  the CLI. The CLI target is also skipped entirely for wasm targets, because it
  needs `NativeTransport`; the library still builds there (`zig build check`).
- The CLI's own tests are registered as a separate test artifact on the `test`
  step, so they run without being compiled into the library.

The practical consequence: anything you can do with `quackling` you can do from
Zig with a few lines against the same API, and adding an output format to the
CLI cannot affect a library consumer. See
[`../../examples/query.zig`](../../examples/query.zig) for the smallest
equivalent program, [`../../examples/streaming.zig`](../../examples/streaming.zig)
for chunk-at-a-time consumption of a large result,
[`../../examples/typed_result.zig`](../../examples/typed_result.zig) for mapping
rows onto a Zig struct, and
[`../../examples/pooled.zig`](../../examples/pooled.zig) for connection pooling
with bound parameters.

---

## 10. Cross-compilation

`quackling` builds for any target with sockets via the standard Zig target
flag:

```sh
zig build -Dtarget=x86_64-windows          # -> zig-out/bin/quackling.exe
zig build -Dtarget=aarch64-linux-musl      # static, no libc dependency
zig build -Dtarget=x86_64-macos
```

For wasm targets the CLI is skipped by design (`target_is_wasm` in
[`../../build.zig`](../../build.zig)) because there is no native HTTP
transport there. To prove the protocol core still compiles for such a target:

```sh
zig build check -Dtarget=wasm32-wasi       # library only
zig build wasm                             # the browser module
```

See [`WASM.md`](./WASM.md) for the browser build, and
[`SERVER_SETUP.md`](./SERVER_SETUP.md) for standing up a server to point
`--url` at.
