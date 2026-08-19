# Server Setup — Operator Guide

**English** · [日本語](../ja/SERVER_SETUP.md)

→ [Documentation index](./README.md)

How to stand up a DuckDB Quack server that Quackling can talk to: locally for
development, and behind a proxy for anything else. Everything here was verified
against DuckDB **v1.5.5** with the `quack` extension.

---

## 1. Prerequisites

You need DuckDB with the `quack` extension. That is the whole dependency list —
the server is the extension; there is no separate daemon to install.

### Version reality check

| Fact | Status |
|---|---|
| `quack` works on DuckDB **v1.5.5** | Verified here, today |
| `quack` is a pre-release / experimental extension | Yes — Quack is beta and upstream expects breaking changes |
| Does it require DuckDB 2.0? | **No.** It installs and runs on v1.5.x from the core repository |
| Default branch of `duckdb/duckdb-quack` | `v1.5-variegata` |
| DuckDB 2.0 ("Cyanoptera") | **Announced for Fall 2026 — not released.** Quack graduates to stable there |

To be unambiguous: DuckDB 2.0 does not exist as a release, so nothing here can
depend on it. The protocol is at version 1 and the extension is usable now on
v1.5.x, with the caveat that it is experimental and the wire format may change
between releases. Quackling pins protocol version 1 and refuses a server outside
that range rather than guessing — see
[`../../src/protocol/compat.zig`](../../src/protocol/compat.zig).

Observed locally:

```console
$ duckdb -c "SELECT version();"
┌─────────────┐
│ "version"() │
├─────────────┤
│ v1.5.5      │
└─────────────┘
```

```console
$ duckdb -c "SELECT extension_name, installed, extension_version, installed_from
             FROM duckdb_extensions() WHERE extension_name='quack';"
┌────────────────┬───────────┬───────────────────┬────────────────┐
│ extension_name │ installed │ extension_version │ installed_from │
├────────────────┼───────────┼───────────────────┼────────────────┤
│ quack          │ true      │ c154811           │ core           │
└────────────────┴───────────┴───────────────────┴────────────────┘
```

---

## 2. Install and load

```sql
INSTALL quack;
LOAD quack;
```

`INSTALL` is a one-time download into `~/.duckdb/extensions/<version>/<platform>/`;
`LOAD` is per-session. The extension also **autoinstalls and autoloads on first
use**, so calling `quack_serve(...)` in a fresh session generally works without
either statement. Being explicit is still better in scripts: it fails loudly at a
predictable point instead of during your first real call, and it does not depend
on autoloading being enabled.

Confirm what you have:

```sql
SELECT function_name, function_type FROM duckdb_functions()
WHERE function_name LIKE 'quack%' ORDER BY 1;
```

Real output on v1.5.5 with the extension loaded:

```
┌──────────────────────────┬───────────────┐
│      function_name       │ function_type │
├──────────────────────────┼───────────────┤
│ quack_active_connections │ table         │
│ quack_check_token        │ scalar        │
│ quack_clear_cache        │ table         │
│ quack_identify           │ table         │
│ quack_nop_authorization  │ scalar        │
│ quack_query              │ table         │
│ quack_query_by_name      │ table         │
│ quack_serve              │ table         │
│ quack_serve              │ table         │
│ quack_server_list        │ table         │
│ quack_stop               │ table         │
│ quack_uri_parser         │ scalar        │
└──────────────────────────┴───────────────┘
```

That list is the authoritative inventory for your build; run it rather than
trusting any document, including this one.

---

## 3. Starting a server

```sql
CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);
```

Returned row, observed live:

```
┌──────────────────────┬───────────────────────┬──────────────┐
│      listen_uri      │      listen_url       │  auth_token  │
├──────────────────────┼───────────────────────┼──────────────┤
│ quack:localhost:9599 │ http://localhost:9599 │ super_secret │
└──────────────────────┴───────────────────────┴──────────────┘
```

| Field | Meaning |
|---|---|
| `listen_uri` | The `quack:` URI to hand to a client — exactly what `quackling --url` wants |
| `listen_url` | The resolved HTTP URL. Check the scheme here to confirm `disable_ssl` took effect |
| `auth_token` | The token in force. **If you did not pass `token =>`, this is the generated one — copy it now**, since clients cannot connect without it |

### Arguments

Verified from `duckdb_functions()`:

```
quack_serve(col0 VARCHAR, token VARCHAR, allow_other_hostname BOOLEAN, disable_ssl BOOLEAN)
```

| Argument | Type | Meaning |
|---|---|---|
| first, positional | `VARCHAR` | Listen URI, e.g. `'quack:localhost:9494'`. Determines host, port and (with `disable_ssl`) the advertised scheme |
| `token` | `VARCHAR` | Shared secret compared against `CONNECTION_REQUEST.auth_string`. Omit and a random 128-bit hex token is generated. Minimum 4 characters |
| `allow_other_hostname` | `BOOLEAN` | Permit binding a hostname other than the local one. Needed when the URI names an address that is not obviously local |
| `disable_ssl` | `BOOLEAN` | Advertise `http://` instead of `https://` in `listen_url`. Set `true` for localhost development |

There is also an overload taking only named arguments
(`disable_ssl`, `allow_other_hostname`, `token`) with no URI, which uses
defaults for the listen address.

`disable_ssl => true` matters more than it looks: the URI parser defaults to
SSL. Verified:

```console
$ duckdb -c "LOAD quack; SELECT quack_uri_parser('quack:localhost', true);"
{'host': localhost, 'port': 9494, 'ipv6': false, 'ssl': true, 'url': 'https://localhost:9494'}
```

So a bare `quack:localhost` resolves to **`https://`**. The server itself does
not terminate TLS (§7), so without `disable_ssl => true` you get a server
advertising a scheme it cannot serve — and a client that trusts `listen_url`
fails to connect. Quackling's own parser
([`../../src/uri.zig`](../../src/uri.zig)) maps `quack:` to **http** and requires
an explicit `https://` for TLS, so `quackling --url quack:localhost:9494` talks
plain HTTP either way.

### URI format

| URI | Host | Port | Note |
|---|---|---|---|
| `quack:localhost` | `localhost` | **9494** | Default port from `compat.default_port` |
| `quack:localhost:9494` | `localhost` | 9494 | Explicit, equivalent to the above |
| `quack:myhost:9000` | `myhost` | 9000 | Non-default port |
| `quack:127.0.0.1` | `127.0.0.1` | 9494 | Loopback literal |
| `quack:[::1]:1234` | `::1` | 1234 | IPv6 — brackets are **required** to separate the port |
| `quack://localhost` | `localhost` | 9494 | `quack://` form, same result |

Verified against the extension's own parser:

```console
$ duckdb -c "LOAD quack; SELECT quack_uri_parser('quack:[::1]:1234', true);"
{'host': '::1', 'port': 1234, 'ipv6': true, 'ssl': true, 'url': 'https://[::1]:1234'}
```

Bind address matters: `quack:localhost` reaches only the local machine, which is
what you want for development. Binding a routable address exposes the server to
anything that can reach the port, and the only gate is the token — read §7 and
§8 before doing that.

---

## 4. Keeping a server alive

**`duckdb -c "..."` exits when the command finishes, and the server dies with
the process.** The listener is a thread inside that DuckDB process, not a
daemon, so there is nothing left behind to accept connections. This is the single
most common way to be confused by an apparently-successful `quack_serve` that
nothing can connect to.

The fix is to keep stdin open so the process stays alive.

### Interactive session (simplest)

```console
$ duckdb
v1.5.5
D LOAD quack;
D CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);
```

Leave the terminal open. The server runs until you `.exit` or close it. Queries
you type here share the process, so tables you create are visible to clients
immediately.

### Long-running local dev server

For a server that survives your terminal, keep stdin attached to something that
never closes:

```sh
# Persistent database, server stays up until you kill it.
duckdb dev.db <<'EOF' &
LOAD quack;
CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);
CREATE TABLE IF NOT EXISTS t AS SELECT i, i*i AS sq FROM range(1000) t(i);
EOF
```

This heredoc form is convenient but exits as soon as the heredoc is consumed. To
hold it open, use a FIFO — you also get a control channel for free:

```sh
mkfifo /tmp/quack.in
duckdb dev.db < /tmp/quack.in > /tmp/quack.log 2>&1 &
exec 3> /tmp/quack.in          # holds the FIFO open; the server stays up

# Configure the running server by writing SQL into the FIFO.
echo "LOAD quack; CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);" >&3
echo "CREATE TABLE t AS SELECT i, i*i AS sq FROM range(1000) t(i);" >&3

# Later, shut it down cleanly:
echo ".exit" >&3
exec 3>&-
rm /tmp/quack.in
```

Two properties make this the recipe worth remembering: the process outlives your
shell command, and you can still send it SQL — so you can create tables in the
*same process that is serving*, which matters for §5. Check `/tmp/quack.log` for
the `quack_serve` output, including a generated token.

Alternatively use `tail -f /dev/null | duckdb dev.db` for a session that stays
open with no control channel, or run it under a supervisor (`systemd`,
`launchd`, `tmux`) for anything long-lived.

Use a **persistent** database file (`duckdb dev.db`) rather than in-memory
unless you want your tables to vanish with the process.

---

## 5. Operational warning: one server per port

**If multiple DuckDB processes call `quack_serve` on the same port, they can all
end up listening, and which one accepts a given connection is not
deterministic.** No error is raised on the second `quack_serve`; the port is not
exclusively held in a way that rejects the newcomer.

This is not hypothetical. Observed on the machine this document was written on:

```console
$ lsof -nP -iTCP:9494
COMMAND   PID  USER  FD  TYPE  DEVICE   SIZE/OFF NODE NAME
duckdb   7837  ...   6u  IPv4  ...      0t0      TCP 127.0.0.1:9494 (LISTEN)
duckdb  25633  ...   5u  IPv4  ...      0t0      TCP 127.0.0.1:9494 (LISTEN)
duckdb  83309  ...   5u  IPv4  ...      0t0      TCP 127.0.0.1:9494 (LISTEN)
```

Three separate DuckDB processes, all listening on 9494.

The symptom this produces is genuinely baffling if you do not know the cause.
Each process has its **own catalog**. If you created a table in one of them, a
query for that table succeeds when that process happens to answer and fails with
*"table not found"* when a different one does — intermittently, for the same SQL,
against the same URL. The same mechanism produces stale or inconsistent data when
processes have different versions of a table.

### Check

```sh
lsof -nP -iTCP:9494
```

Expect **exactly one** line. On Linux, `ss -ltnp 'sport = :9494'` works too.

### Fix

```sh
# See who is listening, then stop the extras.
lsof -nP -iTCP:9494 -t | xargs -r kill

# Or, from inside a server session, stop just its own listener:
```
```sql
CALL quack_stop('quack:localhost:9494');
```

Then start exactly one server and create your tables **in that process** —
either interactively in the same session, or through the FIFO from §4. A table
created by a different `duckdb` invocation is in a different catalog and is
invisible to the server, even with the same database file (and a second writer to
the same file will be refused anyway).

Make the check part of your startup routine: `lsof -nP -iTCP:9494` before
`quack_serve` costs nothing and removes an entire class of debugging session.

---

## 6. Stopping a server and inspecting state

The functions below were verified live on v1.5.5 by calling them and reading
their output. Nothing in this section is inferred.

### `quack_stop(uri)`

```sql
CALL quack_stop('quack:localhost:9599');
```

```
┌───────────────────────────────────────────┐
│                  status                   │
├───────────────────────────────────────────┤
│ Stopped listening on quack:localhost:9599 │
└───────────────────────────────────────────┘
```

Signature: `quack_stop(col0 VARCHAR)` — one positional URI argument. It stops a
listener owned by **the calling process**; it is not a way to stop someone
else's server.

> The name is `quack_stop`. There is **no `rpc_stop`** function in this build —
> the full list in §2 is what exists. If you have seen `rpc_*` names elsewhere
> they belong to a different version or a different extension; verify with the
> `duckdb_functions()` query before using them.

### `quack_server_list()`

Which listeners this process owns:

```sql
SELECT * FROM quack_server_list();
```

```
┌──────────────────────┬───────────────────────┬───────────┬────────┬────────────────────┬───────────────┐
│      listen_uri      │      listen_url       │   host    │  port  │ active_connections │     info      │
├──────────────────────┼───────────────────────┼───────────┼────────┼────────────────────┼───────────────┤
│ quack:localhost:9599 │ http://localhost:9599 │ localhost │   9599 │                  0 │ {ipv6=false}  │
└──────────────────────┴───────────────────────┴───────────┴────────┴────────────────────┴───────────────┘
```

Columns: `listen_uri`, `listen_url`, `host`, `port` (`UINT16`),
`active_connections` (`UINT64`), `info` (`MAP(VARCHAR, VARCHAR)`). Returns zero
rows when the process has no listener — which is exactly how you distinguish
"my server died" from "someone else's server is on my port". Combine with `lsof`
from §5: `lsof` shows a listener but `quack_server_list()` is empty means the
listener belongs to another process.

After a successful `quack_stop`, `SELECT count(*) FROM quack_server_list()`
returns `0` (verified).

### `quack_active_connections()`

```sql
SELECT * FROM quack_active_connections();
```

```
┌───────────┬───────────────┬─────────┬─────────┬──────────────────┐
│ server_id │ connection_id │  query  │  state  │ query_started_at │
├───────────┼───────────────┼─────────┼─────────┼──────────────────┤
└───────────┴───────────────┴─────────┴─────────┴──────────────────┘
```

Columns: `server_id`, `connection_id`, `query`, `state` (all `VARCHAR`) and
`query_started_at` (`TIMESTAMP`). `connection_id` matches the id in the protocol
message header (a live server sends a 32-character uppercase hex string), so you
can correlate a client session with a server-side row. This is the tool for
"what is that client actually running".

### Other verified functions

Present in the function list and verified only as *existing* with the signatures
shown; their full semantics are **not verified here**:

| Function | Signature | Notes |
|---|---|---|
| `quack_uri_parser(uri, bool)` | scalar → `STRUCT(host VARCHAR, port USMALLINT, ipv6 BOOLEAN, ssl BOOLEAN, url VARCHAR)` | Verified by direct call; see §3 |
| `quack_check_token(a, b, c)` | scalar `(VARCHAR, VARCHAR, VARCHAR) → BOOLEAN` | Default authentication callback. Argument meanings unverified |
| `quack_nop_authorization(...)` | scalar | Name implies an authorization hook that permits everything. **Unverified** |
| `quack_clear_cache()` | table | **Unverified** |
| `quack_identify(name, hostname, region, provider, meta)` | table, all `VARCHAR` | Sets server identity metadata. Unverified beyond the signature |
| `quack_query(...)`, `quack_query_by_name(...)` | table | Client-side query functions. Unverified |

If a function you need is not listed here, get its real signature from
`duckdb_functions()` rather than assuming.

---

## 7. TLS

**The DuckDB Quack server does not terminate TLS.** There is no certificate
option on `quack_serve`; `disable_ssl` only changes the scheme it advertises in
`listen_url`. For anything beyond localhost you must put a reverse proxy in
front.

This is not optional hardening. The auth token travels **inside the protocol
message body** (`CONNECTION_REQUEST.auth_string`), not in an HTTP header — see
[`PROTOCOL.md`](./PROTOCOL.md) §9. Over plain HTTP the token is on the wire in
the clear on every new connection, and so is every query and every result row.
There is no protocol-level encryption to fall back on.

### Minimal nginx reverse proxy

```nginx
server {
    listen 443 ssl;
    server_name db.example.com;

    ssl_certificate     /etc/letsencrypt/live/db.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/db.example.com/privkey.pem;

    location /quack {
        proxy_pass http://127.0.0.1:9494/quack;
        proxy_http_version 1.1;

        # The body is a binary protocol message: pass it through untouched.
        proxy_set_header Content-Type $http_content_type;
        proxy_request_buffering off;
        proxy_buffering off;
        client_max_body_size 0;          # no cap on request size
        proxy_read_timeout 300s;         # long queries must not be cut off

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Why each of the non-obvious lines is there:

- **`proxy_set_header Content-Type $http_content_type`** — the client sends
  `application/vnd.duckdb`; the server requires it. Preserve it verbatim.
- **`proxy_request_buffering off`** and **`proxy_buffering off`** — bodies are
  binary and can be large; streaming avoids buffering a whole result to disk and
  keeps latency down.
- **`client_max_body_size 0`** — nginx's 1 MB default would reject a large
  `APPEND` or a long SQL statement with a 413.
- **`proxy_read_timeout 300s`** — the 60-second default kills a long-running
  analytical query mid-flight, which surfaces to the client as a truncated
  response rather than a clear error.
- **No content transformation** — do not enable `gzip` rewriting, `sub_filter`,
  or anything else that touches the body. A single mutated byte makes the
  message undecodable.

Point Quackling at the proxy with an explicit `https://`:

```sh
quackling --url https://db.example.com --token super_secret "SELECT 42"
```

`https://` with no port resolves to port **9494**
([`../../src/uri.zig`](../../src/uri.zig) applies `default_port` regardless of
scheme), so listening on 443 needs the port spelled out:

```sh
quackling --url https://db.example.com:443 --token super_secret "SELECT 42"
```

Bind the DuckDB server to loopback only (`quack:127.0.0.1:9494`) so the plain
HTTP port is unreachable from outside and the proxy is the only path in.

Caddy is a shorter equivalent:

```caddy
db.example.com {
    reverse_proxy /quack 127.0.0.1:9494 {
        flush_interval -1
    }
}
```

Caddy provisions certificates automatically and passes bodies through unmodified;
`flush_interval -1` disables response buffering.

---

## 8. Authentication

Token-based, and that is the entire access-control model: any client with the
token can run any SQL the server's DuckDB session can run. There are no users,
roles or per-table grants at the protocol level.

```sql
CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);
```

Rules verified against a live server and the protocol reference:

- The token is compared against `CONNECTION_REQUEST.auth_string` via the
  pluggable `quack_authentication_function`.
- Minimum length is **4 characters**.
- Omitting `token =>` generates a random 128-bit hex token, returned as
  `auth_token` — capture it or you cannot connect.
- A failed handshake yields `ERROR_RESPONSE`, which reaches the CLI as:

  ```console
  $ quackling --token wrong "SELECT 42"
  connection failed: Authentication failed
  $ echo $?
  1
  ```

Quackling never logs, prints or includes the token in error messages. On the
client side the exposure is your shell history and `ps` output — see
[`CLI.md`](./CLI.md) §3.

### Extra HTTP headers via the `quack` secret

There is **no HTTP auth header** in the protocol, so a proxy or load balancer
that wants its own header-based credential needs a separate channel. DuckDB
clients supply it out-of-band through the `quack` secret's `EXTRA_HTTP_HEADERS`:

```sql
CREATE SECRET my_quack (
    TYPE quack,
    TOKEN 'super_secret',
    EXTRA_HTTP_HEADERS MAP {'X-Api-Key': 'proxy-side-credential'}
);
```

Verified as accepted on v1.5.5:

```console
$ duckdb -c "CREATE SECRET tmpq (TYPE quack, TOKEN 'abc',
             EXTRA_HTTP_HEADERS MAP {'X-Api-Key':'k'});
             SELECT name, type FROM duckdb_secrets();"
┌─────────┬─────────┐
│  name   │  type   │
├─────────┼─────────┤
│ tmpq    │ quack   │
└─────────┴─────────┘
```

This is how a **DuckDB client** authenticates through a gateway — the headers
apply to outbound connections (e.g. `ATTACH 'quack:...'`), not to a server you
are hosting. Two consequences worth being clear about:

- Configuring this secret does not make *your server* require a header. Header
  enforcement belongs in the proxy.
- `quackling` has no equivalent flag: it sends only `Content-Type`, so it cannot
  currently authenticate to a proxy that demands a custom header. Use a DuckDB
  client for that path, or terminate the header check somewhere Quackling can
  reach.

A layered setup — nginx checking `X-Api-Key`, DuckDB checking the protocol token
— gives you a gate that can be rotated at the edge plus one that cannot be
bypassed by reaching the port directly.

---

## 9. Verifying the server works

Three checks, each isolating a different layer.

**1. Is anything listening, and is it a Quack endpoint?**

```console
$ curl -s http://localhost:9494/
This is a DuckDB Quack RPC endpoint. Use ATTACH 'quack:...' to connect here.
```

`GET /` returns a plain-text banner and needs no token. If you get this, the
process is up and reachable; if the connection is refused, see §4 and §5.

**2. Does CORS work (only if a browser will connect)?**

```console
$ curl -s -i -X OPTIONS http://localhost:9494/quack
HTTP/1.1 204 No Content
Access-Control-Allow-Headers: *
Access-Control-Allow-Origin: *
Content-Length: 0
Access-Control-Allow-Methods: GET, POST, OPTIONS
```

**3. Does the protocol and token work end to end?**

```console
$ quackling --token super_secret "SELECT 42"
┌────┐
│ 42 │
├────┤
│ 42 │
└────┘
```

With a named column:

```console
$ quackling --token super_secret "SELECT 42 AS answer"
┌────────┐
│ answer │
├────────┤
│ 42     │
└────────┘
```

Add `--stats` to see the round trips, which confirms the whole path:

```console
$ quackling --token super_secret --stats "SELECT 42"
┌────┐
│ 42 │
├────┤
│ 42 │
└────┘

requests=2 queries=1 fetches=0 chunks=1 rows=1 sent=127B recv=168B errors=0/0/0
```

`errors=0/0/0` and `requests=2` (connect + prepare) is a healthy session. See
[`CLI.md`](./CLI.md) §7 for the counters.

If step 1 works but step 3 says *"Authentication failed"*, the server is fine
and your token is wrong. If step 3 intermittently cannot find a table, go
straight to §5.

---

## 10. Integration tests

The integration suite needs a live server. It is deliberately **not** on the
default `test` step so that CI without DuckDB stays green
([`../../build.zig`](../../build.zig)).

```sh
zig build test-integration
```

Option names verified in `build.zig`:

| Option | Default | Meaning |
|---|---|---|
| `-Dquack-endpoint=<uri>` | `quack:localhost:9494` | Server endpoint |
| `-Dquack-token=<token>` | `super_secret` | Auth token |

```sh
zig build test-integration \
  -Dquack-endpoint=quack:localhost:9494 \
  -Dquack-token=super_secret
```

The defaults match the `quack_serve` invocation used throughout this document,
so with a local dev server from §4 a bare `zig build test-integration` works.
These are **build options, not environment variables** — a deliberate choice so
the same code works identically on every target, including Windows and WASI.
They are compiled in, so changing them re-runs the tests rather than hitting a
cached result.

**The tests skip when no server is reachable.** A connection that fails with
`ConnectionFailed` or `NetworkError` returns `error.SkipZigTest` rather than a
failure, so running the suite with nothing listening reports skips, not red.
That is convenient in CI and a trap locally: a "passing" run may have tested
nothing. Confirm with §9 first, and treat a suite that skips everything as a
setup problem.

### Regenerating golden fixtures

The fixtures in `tests/fixtures/` are captured wire bytes from a real server and
are the ground truth for protocol compatibility. Regenerating them **requires a
live server**:

```sh
# One terminal: a server on the default endpoint.
duckdb
```
```sql
LOAD quack;
CALL quack_serve('quack:localhost:9494', token => 'super_secret', disable_ssl => true);
```
```sh
# Another terminal:
python3 scripts/capture_fixtures.py
```

The script speaks the protocol directly, with no Quackling involved, so the
fixtures remain an *independent* check on the Zig implementation rather than a
recording of its own behaviour. Regenerate when validating against a new DuckDB
release; a diff in the committed fixtures is an upstream format change and
should be reviewed as one, not blindly committed.

---

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `connection failed: Authentication failed` | Wrong or missing token | Use the `auth_token` from `quack_serve`'s output. Remember `QUACK_TOKEN` is **not implemented** ([`CLI.md`](./CLI.md) §3) — pass `--token` |
| `connection failed: ConnectionFailed (quack:localhost:9494)` | Nothing listening: `duckdb -c` already exited, wrong port, or bound to a different interface | `lsof -nP -iTCP:9494`; if empty, start a server that keeps stdin open (§4). Check the port matches `--url` |
| `Table with name X does not exist!` — **intermittent** for the same query | Multiple DuckDB processes on one port; requests land on a process without the table | `lsof -nP -iTCP:9494` must show exactly **one** line. Kill the extras and create tables in the serving process (§5) |
| `Table with name X does not exist!` — consistent | Table lives in another process/catalog, or was created in-memory in a session that exited | Create it in the serving session (FIFO recipe, §4). Use a persistent database file |
| Works from `curl`, fails from a browser | Cross-origin preflight blocked by a proxy that drops `OPTIONS` | Server answers `OPTIONS /quack` with 204 and `Access-Control-Allow-Origin: *`; make the proxy forward `OPTIONS` unmodified ([`WASM.md`](./WASM.md) §8) |
| **HTTP 500** on an unexpected field | Protocol mismatch — the server rejects fields it does not expect (e.g. an unknown `PREPARE_REQUEST` field) | Match client and server versions. Quackling pins protocol version 1; regenerate fixtures and run the suite against the new DuckDB ([`PROTOCOL.md`](./PROTOCOL.md) §10) |
| `UnsupportedProtocolVersion` at connect | Server outside the supported protocol range | Quackling refuses rather than guessing. Check the extension version; see `compat.zig` |
| TLS/scheme confusion: client cannot connect although the server started | `disable_ssl` omitted, so `listen_url` advertises `https://` that the server cannot serve | Pass `disable_ssl => true` for plain HTTP, or put a real TLS proxy in front (§7). `quack:` maps to **http** in Quackling; use explicit `https://` for TLS |
| `https://host` connects to the wrong port | `https://` with no port defaults to **9494**, not 443 | Spell out the port: `--url https://host:443` |
| Client hangs, then a truncated response | Proxy read timeout cut a long query | Raise `proxy_read_timeout` (§7) |
| Large request rejected with 413 | nginx `client_max_body_size` default of 1 MB | `client_max_body_size 0` (§7) |
| Query fails only through the proxy | Proxy altered the body or dropped `Content-Type: application/vnd.duckdb` | Disable body transformation; forward the header verbatim (§7) |
| `zig build test-integration` passes suspiciously fast | Tests skipped because no server was reachable | Verify with §9. Skips are not passes |
| Server started but `quack_server_list()` is empty while `lsof` shows a listener | The listener belongs to a **different** process | You are looking at someone else's server; see §5 |

---

## See also

- [`CLI.md`](./CLI.md) — flags, output formats, exit codes, `--stats` counters
- [`WASM.md`](./WASM.md) — browser build, CORS, the FFI boundary
- [`PROTOCOL.md`](./PROTOCOL.md) — wire format, authentication, cursor lifetime
- [`../../examples/query.zig`](../../examples/query.zig) — smallest Zig client
- [`../../scripts/capture_fixtures.py`](../../scripts/capture_fixtures.py) — fixture capture
