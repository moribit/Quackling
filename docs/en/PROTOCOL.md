# Quack Remote Protocol — Wire Format Reference

**English** · [日本語](../ja/PROTOCOL.md)

→ [Documentation index](./README.md)

> Derived from DuckDB source (`duckdb/duckdb-quack` @ main, `duckdb/duckdb` v1.4.1) and
> **verified byte-for-byte against a live `quack_serve()` server** (DuckDB v1.5.5, quack v1).
> Quack is beta; breaking changes are expected. See `src/protocol/compat.zig`.

## 1. Transport

| Property      | Value                                            |
|---------------|--------------------------------------------------|
| Method        | `POST`                                           |
| Path          | `/quack`                                         |
| Request type  | `application/vnd.duckdb`                         |
| Response type | `application/vnd.duckdb`                         |
| Default port  | `9494`                                           |
| URI scheme    | `quack:host[:port]` → `http://host:port`          |
| TLS           | Not in server; terminate at a reverse proxy      |
| CORS          | Server sends `Access-Control-Allow-Origin: *`    |

`GET /` returns a human-readable banner. `OPTIONS /quack` returns 204 for CORS preflight.
Every request is a full round trip: one request message in, one response message out.
The protocol is strictly client-driven — the server never pushes.

## 2. Message framing

The HTTP body is **two consecutive top-level objects**, back to back:

```
body := <MessageHeader object> <Message body object>
```

Both are encoded with DuckDB's `BinarySerializer` at
`SerializationCompatibility::FromIndex(7)` (DuckDB 1.4.0-era rules — this is what
sets `serialize_default_values = false` and enables compressed vectors).

### Object encoding

An object is a flat sequence of fields terminated by a sentinel field id:

```
object := { field_id:u16le  value }*  0xFFFF
```

* `field_id` is `uint16` **little-endian** (`field_id_t`).
* `0xFFFF` (`MESSAGE_TERMINATOR_FIELD_ID`) ends the object.
* Fields are written in ascending id order; readers must tolerate **absent** fields.
* Fields written with `WritePropertyWithDefault` are **omitted entirely when equal to
  the type default** (`""`, `0`, `false`, `nullptr`). This is the single most common
  source of decoder desync — never assume a field is present.

## 3. Primitive encoding

| Type                     | Encoding                                              |
|--------------------------|-------------------------------------------------------|
| `bool`                   | 1 raw byte (`0`/`1`) — **not** varint                  |
| `char`                   | 1 raw byte                                            |
| `int8/16/32/64`          | **signed** LEB128 (sign-extended, *not* zigzag)        |
| `uint8/16/32/64`, `idx_t`| **unsigned** LEB128                                    |
| `float`                  | 4 raw bytes, IEEE-754 little-endian                    |
| `double`                 | 8 raw bytes, IEEE-754 little-endian                    |
| `hugeint_t` (i128)       | signed LEB128 `upper:i64`, then unsigned LEB128 `lower:u64` |
| `uhugeint_t` (u128)      | unsigned LEB128 `upper`, then unsigned LEB128 `lower`  |
| `string`                 | unsigned LEB128 byte length, then raw UTF-8 bytes      |
| blob / `WriteDataPtr`    | unsigned LEB128 byte count, then raw bytes             |
| enum                     | as its underlying integer (varint); `serialize_enum_as_string` is forced off |
| `optional_idx`           | unsigned LEB128; `UINT64_MAX` means "not set"          |
| list / `vector<T>`       | unsigned LEB128 count, then `count` encoded elements   |
| pointer / `unique_ptr<T>`| 1 "present" byte; if `1`, the pointee follows          |

Note the asymmetry that trips up hand-rolled decoders: a `bool` **value** is a raw
byte, but a `uint8_t` **value** is a varint.

## 4. MessageHeader

```
field 1  type              MessageType enum (varint)          [always present]
field 2  connection_id     string   [omitted when empty]
field 3  client_query_id   optional_idx (varint, u64 max = unset)  [always present]
```

## 5. MessageType

| Value | Name                 | Direction |
|-------|----------------------|-----------|
| 0     | `INVALID`            | —         |
| 1     | `CONNECTION_REQUEST` | C → S     |
| 2     | `CONNECTION_RESPONSE`| S → C     |
| 3     | `PREPARE_REQUEST`    | C → S     |
| 4     | `PREPARE_RESPONSE`   | S → C     |
| 7     | `FETCH_REQUEST`      | C → S     |
| 8     | `FETCH_RESPONSE`     | S → C     |
| 9     | `APPEND_REQUEST`     | C → S     |
| 10    | `SUCCESS_RESPONSE`   | S → C     |
| 11    | `DISCONNECT_MESSAGE` | C → S     |
| 100   | `ERROR_RESPONSE`     | S → C     |

Note 5 and 6 are unused (removed during development).

## 6. Message bodies

All body fields below use `WritePropertyWithDefault` → **omitted when default**.

### `CONNECTION_REQUEST` (1)
```
1 auth_string                 string
2 client_duckdb_version       string
3 client_platform             string
4 min_supported_quack_version idx_t
5 max_supported_quack_version idx_t
```

### `CONNECTION_RESPONSE` (2)
```
1 server_duckdb_version string
2 server_platform       string
3 quack_version         idx_t
```
The assigned session id arrives in the **header**'s `connection_id`
(a 32-char uppercase hex string), not in the body.

### `PREPARE_REQUEST` (3)
```
1 sql_query string
```
Header `connection_id` must carry the session id.

### `PREPARE_RESPONSE` (4)
```
1 result_types     vector<LogicalType>
2 result_names     vector<string>
3 needs_more_fetch bool
4 results          vector<unique_ptr<DataChunkWrapper>>
5 result_uuid      hugeint_t
```

### `FETCH_REQUEST` (7)
```
1 uuid hugeint_t     -- the result_uuid from PREPARE_RESPONSE
```

### `FETCH_RESPONSE` (8)
```
1 results     vector<unique_ptr<DataChunkWrapper>>
2 batch_index optional_idx
```
`FETCH_RESPONSE` carries **no** `needs_more_fetch`. Streaming terminates when a
response returns zero chunks.

### `APPEND_REQUEST` (9)
```
1 schema_name  string
2 table_name   string
3 append_chunk unique_ptr<DataChunkWrapper>
```

### `SUCCESS_RESPONSE` (10) / `DISCONNECT_MESSAGE` (11)
Empty bodies (just the `0xFFFF` terminator).

### `ERROR_RESPONSE` (100)
```
1 message string   -- ErrorData::RawMessage()
```

## 7. DataChunkWrapper

A wrapper exists only to work around a serialization-signature bug; it is one
object holding one field:

```
field 300 "chunk" -> DataChunk object
```

### DataChunk
```
field 100 rows     sel_t (uint32 varint)
field 101 types    vector<LogicalType>
field 102 columns  list of objects, one per column, each a Vector
```
`rows` is omitted when 0 (default-skipping), so an empty chunk is legal.

### Vector
```
field 90  vector_type        VectorType enum  [absent => FLAT_VECTOR]
field 100 has_validity_mask  bool
field 101 validity           blob, ceil(count/64)*8 bytes, bit=1 means VALID
field 102 data               fixed-width: blob of GetTypeIdSize(type)*count
                             VARCHAR:     list<string> of length count
field 103 children           STRUCT: list of child Vector objects
field 103 array_size         ARRAY: uint64
field 104 child              ARRAY: child Vector object
field 104 list_size          LIST: uint64
field 105 entries            LIST: list of {100:offset u64, 101:length u64}
field 106 child              LIST: child Vector object
```

**Validity semantics:** the mask is a bitset of `uint64` words, LSB-first; a set
bit means the row is **valid** (non-NULL). When `has_validity_mask` is `false`
(or the field is absent) every row is valid.

### VectorType (field 90) — compressed encodings
```
0 FLAT_VECTOR       (default when field 90 absent)
1 FSST_VECTOR
2 CONSTANT_VECTOR   one value follows, logically repeated for all rows
3 DICTIONARY_VECTOR 91:sel_vector blob (sel_t*count), 92:dict_count, then child vector
4 SEQUENCE_VECTOR   91:seq_start i64, 92:seq_increment i64 — no data follows
```
In the fixtures captured from DuckDB v1.5.5, field 90 was **never** emitted — every
vector arrived flat. But the encoder chooses these representations dynamically based
on the data, and `serialization_compatibility` index 7 enables compressed vectors,
so a client that ignores field 90 is one query away from mis-decoding. `Quackling`
decodes FLAT, CONSTANT, DICTIONARY and SEQUENCE, and returns
`error.UnsupportedVectorType` for FSST rather than guessing.

### LogicalType
```
field 100 id             LogicalTypeId enum (varint)
field 101 type_info      unique_ptr<ExtraTypeInfo>  (present byte, then object)
```

`ExtraTypeInfo` begins with `100:type` (`ExtraTypeInfoType`) and `101:alias`
(string, default-skipped), then `103:extension_info` (nullable), then
subtype-specific fields. **Fields 200/201 are overloaded** — their meaning
depends on the `ExtraTypeInfoType` in field 100, which always precedes them:

| `ExtraTypeInfoType` | value | field 200            | field 201      |
|---------------------|-------|----------------------|----------------|
| `DECIMAL`           | 2     | `width` (u8)         | `scale` (u8)   |
| `STRING`            | 3     | —                    | —              |
| `LIST`              | 4     | child `LogicalType`  | —              |
| `STRUCT`            | 5     | `child_list_t` (list of `{0:name, 1:LogicalType}` pairs) | — |
| `ENUM`              | 6     | `values_count` (idx_t) | `values` (list of strings) |
| `ARRAY`             | 9     | child `LogicalType`  | `array_size` (u64) |

### Types that reuse another type's representation

Three logical types have no encoding of their own — recognising this is what
keeps the decoder small:

* **MAP** (`102`) uses `ListTypeInfo`, wrapping a `STRUCT(key, value)`. It is
  laid out exactly like a `LIST`.
* **UNION** (`107`) uses `StructTypeInfo`, whose **first child is a hidden
  `UTINYINT` tag** followed by the members. It is laid out exactly like a
  `STRUCT`; the tag selects which member is valid for a given row.
* **VARIANT** (`109`) is also a `STRUCT`, of `keys` / `children` / `values`.

### ENUM physical storage

An ENUM cell stores an index into the dictionary, in the narrowest unsigned
integer that can address it (`EnumTypeInfo::DictType`):

| dictionary size | storage  |
|-----------------|----------|
| ≤ 255           | `uint8`  |
| ≤ 65 535        | `uint16` |
| ≤ 4 294 967 295 | `uint32` |

### BIGNUM

`BIGNUM` (`39`) carries no extra type info and is stored like a string: field
102 is a list of length-prefixed byte runs.

## 8. Connection lifecycle

```
CONNECTION_REQUEST  ──▶  CONNECTION_RESPONSE   (header carries connection_id)
PREPARE_REQUEST     ──▶  PREPARE_RESPONSE      (types + names + first chunks + uuid)
FETCH_REQUEST(uuid) ──▶  FETCH_RESPONSE        (more chunks; repeat while non-empty)
DISCONNECT_MESSAGE  ──▶  SUCCESS_RESPONSE
```

Any request may instead yield `ERROR_RESPONSE`. The server batches up to
`quack_fetch_batch_chunks` chunks per response (default **12**), so a large result
arrives as repeated FETCH round trips. `PREPARE_RESPONSE.needs_more_fetch` tells you
whether to start fetching; from then on an empty `results` list signals the end.

## 9. Authentication

Token-based. The client puts the token in `CONNECTION_REQUEST.auth_string`; the
server compares it against `quack_serve(token := ...)` (or a generated random
128-bit hex token) via the pluggable `quack_authentication_function`. There is **no**
HTTP auth header — the token travels inside the protocol message body, which is why
transport-level TLS matters. Extra HTTP headers (for proxies) are supported
out-of-band via the `quack` secret's `EXTRA_HTTP_HEADERS`.

Tokens must be >= 4 chars. A failed handshake yields `ERROR_RESPONSE`.

## 10. Parameters

There is **no wire representation for query parameters** in protocol version 1.
`PrepareRequestMessage` has exactly one field (the SQL string) and the server
passes it directly to `SendQuery`. Verified against a live server:

* `SELECT ?` → `ERROR_RESPONSE`: *"Expected 1 parameters, but none were supplied"*.
* Adding an unknown field to `PREPARE_REQUEST` → **HTTP 500**. The server
  rejects fields it does not expect, so a client cannot introduce one.

Clients must therefore either render parameters into the SQL text (what
`src/params.zig` does, with strict escaping) or use SQL-level
`PREPARE` / `EXECUTE`, which works normally over the protocol.

## 11. Result cursor lifetime

Each connection holds **one** result cursor. `PREPARE_REQUEST` handling calls
`connection.duckdb_query_result.reset()` *before* executing the SQL
(`quack_server.cpp`), so:

* a new PREPARE always destroys the previous result, and
* it does so even when the new query then fails — the reset happens first.

A client that streams one result while issuing another query on the same
connection will therefore FETCH against a discarded cursor. Concurrent queries
require separate connections.

## 12. Verified observations

Captured from a live server (`quack_serve('quack:localhost:9494', token=>'super_secret')`):

* `SELECT 42 AS answer` → 94-byte `PREPARE_RESPONSE`, fully consumed, INTEGER(13),
  one chunk, one CONSTANT vector, payload `2a 00 00 00`.
* `connection_id` is a 32-char uppercase hex string.
* `client_query_id` is present-but-`UINT64_MAX` when there is no active transaction.
* `SELECT i FROM range(100000)` → 12 chunks in `PREPARE_RESPONSE`,
  `needs_more_fetch = 1`, plus a `result_uuid`, then FETCH round trips.
* An empty result (`WHERE false`) still returns types and names, with the `rows`
  field omitted.
* Nested types round-trip losslessly: `STRUCT`, `LIST`, `ARRAY`, `MAP`,
  `UNION`, `ENUM`, `VARIANT` and `BIGNUM` were each captured and decoded with
  every byte accounted for (see `tests/fixtures/`).
* **FSST vectors never appear on the wire.** `Vector::Serialize` has no FSST
  branch; such a vector falls through to `ToUnifiedFormat` and is flattened
  before sending (the `// TODO: other compressed vector types (FSST)`
  fallthrough in `duckdb/src/common/types/vector.cpp`).
