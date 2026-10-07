# Quackling documentation

**English** · [日本語](../ja/README.md)

← [Back to project README](../../README.md)

Quackling is a standalone DuckDB Quack protocol client written in pure Zig.
These documents describe how to run a server, how to use the library, and how
the implementation is structured and verified.

## Getting started

| Document | What it covers |
|----------|----------------|
| [Server setup](SERVER_SETUP.md) | Installing the `quack` extension, starting `quack_serve()`, URI forms, keeping a server alive, TLS via a reverse proxy, and a troubleshooting table |
| [CLI](CLI.md) | `quackling`: every flag, the five output formats, `QUACK_TOKEN`, reading SQL from stdin, and interpreting `--stats` |

## Using the library

| Document | What it covers |
|----------|----------------|
| [API reference](API.md) | `Client`, `Result`, `RowStream`, `typed.iterator`, the `Param` union, `Pool`, `Transport`, and the full error taxonomy |
| [Type support](TYPES.md) | Every DuckDB type and how to read it, NULL/validity semantics, nested-type access, vector encodings, and the zero-copy lifetime rules |
| [WASM](WASM.md) | Building for `wasm32-freestanding`, the complete FFI export surface, the JS call sequence, and TypedArray views over linear memory |
| [Performance](PERFORMANCE.md) | Codec benchmarks with method and reproduction commands, why allocations don't scale with rows, end-to-end streaming, memory bounds, and performance traps |
| [Akamata integration](AKAMATA.md) | A verified transport adapter onto a web framework's own HTTP client, the chunk-vs-row interface mismatch, and why a custom `State.db` beats the row shim |

## Understanding the implementation

| Document | What it covers |
|----------|----------------|
| [Architecture](ARCHITECTURE.md) | The layering rule, transport injection, the session state machine, the single-cursor constraint, memory ownership, and the streaming model |
| [Wire protocol](PROTOCOL.md) | Byte-level reference for the Quack wire format: framing, primitive encoding, every message body, and `DataChunkWrapper` |

## Verification

| Document | What it covers |
|----------|----------------|
| [Testing](TESTING.md) | The six test layers, what each proves and cannot prove, mutation testing as the meta-layer, and why the mutation run is slow |
| [Security](SECURITY.md) | Threat model, token handling, memory safety, resource limits, the SQL-injection boundary, and an explicit out-of-scope list |

## Quick reference

| Fact | Value |
|------|-------|
| Zig version | 0.17.0 |
| Verified against | DuckDB v1.5.5, `quack` extension, Quack protocol version 1 |
| Default port | 9494 |
| HTTP path | `/quack` |
| Content type | `application/vnd.duckdb` |
| URI scheme | `quack:host[:port]` |

Quack is a pre-release extension and upstream expects breaking changes. It works
today on DuckDB v1.5.5; it graduates to stable in DuckDB 2.0 ("Cyanoptera"),
announced for Fall 2026 and not yet released.
