# Type System Reference

**English** · [日本語](../ja/TYPES.md)

→ [Documentation index](./README.md)

How Quackling decodes DuckDB values off the Quack wire, and which Zig accessor to
use for each type.

Sources: [`../../src/types/logical_type.zig`](../../src/types/logical_type.zig),
[`../../src/types/value.zig`](../../src/types/value.zig),
[`../../src/types/vector.zig`](../../src/types/vector.zig),
[`../../src/types/validity.zig`](../../src/types/validity.zig),
[`../../src/types/data_chunk.zig`](../../src/types/data_chunk.zig),
[`../../src/serialization/decoder.zig`](../../src/serialization/decoder.zig).

---

## 1. The three layers

| Layer | Type | Owns | Purpose |
|-------|------|------|---------|
| Chunk | `DataChunk` | its `Vector` array and the whole column type tree | up to 2048 rows × N columns |
| Column | `Vector` | its own child vectors / index arrays / string tables | one column of a chunk |
| Cell | `Value` | nothing (slices borrow) | one decoded scalar |

`DataChunk.types` is the single owner of the `LogicalType` tree. Every `Vector`,
including the children of nested types, only *borrows* into it — a vector never
frees its own type, because nested vectors share sub-trees.

Bulk payloads inside a vector borrow the HTTP response buffer that the `Result`
holds, so `DataChunk.deinit` is cheap and no row-sized copies happen.

```zig
while (try result.nextChunk()) |chunk| {
    const col = chunk.column(0).?;        // ?*const Vector
    const v = try chunk.getValue(0, 0);   // Value
}
```

---

## 2. Type identity: `LogicalType` and `LogicalTypeId`

`LogicalTypeId` is the on-wire enum from DuckDB's `common/types.hpp`, declared as
`enum(u8)` with an explicit `_` non-exhaustive tail, so an unknown id from a
future server does not crash the enum — it just reports `"UNKNOWN"` from
`name()`.

```zig
pub const LogicalType = struct {
    id: LogicalTypeId,
    decimal: ?Decimal = null,              // width + scale, DECIMAL only
    alias: ?[]const u8 = null,             // borrowed from the response buffer
    children: []Child = &.{},              // STRUCT/LIST/MAP/ARRAY/UNION, owned
    array_size: ?u64 = null,               // ARRAY declared length
    enum_values: []const []const u8 = &.{},// ENUM dictionary, declaration order
    enum_count_hint: ?u64 = null,          // server-declared count, cross-checked
};
```

Useful methods:

| Method | Returns | Notes |
|--------|---------|-------|
| `id.name()` | `[]const u8` | SQL-ish name, `"UNKNOWN"` for unmodelled ids |
| `id.fixedWidth()` | `?usize` | physical width for fixed-width ids; `null` = variable or unmodelled |
| `name()` | `[]const u8` | `alias` if the server sent one, else `id.name()` |
| `fixedWidth()` | `?usize` | as above, but resolves DECIMAL precision and ENUM dictionary width |
| `unionMembers()` | `[]Child` | `children[1..]` — skips the hidden tag; empty for non-unions |
| `mapEntryType()` | `?LogicalType` | the `STRUCT(key, value)` element type of a MAP's backing list |
| `mapKeyValue()` | `?struct { key, value }` | the declared MAP key/value types |
| `physicalShape()` | `PhysicalShape` | `.fixed`/`.variable`/`.@"struct"`/`.list`/`.array`/`.unsupported` |

`PhysicalShape` is where MAP and UNION stop being special: MAP is laid out
exactly like a LIST, UNION exactly like a STRUCT, so the decoder reuses those
paths instead of having its own.

---

## 3. Full type table

`Value` variants are the members of the `Value` union in
[`../../src/types/value.zig`](../../src/types/value.zig). "Fast path" is the
zero-boxing accessor on `Vector` where one exists.

### Scalars

| DuckDB type | `LogicalTypeId` | Wire width | Decoded as | `Value` variant | Fast path |
|-------------|-----------------|-----------|------------|-----------------|-----------|
| `BOOLEAN` | `.boolean` | 1 | byte `!= 0` | `.boolean: bool` | `at(u8, i) != 0` |
| `TINYINT` | `.tinyint` | 1 | LE i8 | `.tinyint: i8` | `at(i8, i)` |
| `SMALLINT` | `.smallint` | 2 | LE i16 | `.smallint: i16` | `at(i16, i)` |
| `INTEGER` | `.integer` | 4 | LE i32 | `.integer: i32` | `at(i32, i)` |
| `BIGINT` | `.bigint` | 8 | LE i64 | `.bigint: i64` | `at(i64, i)` |
| `HUGEINT` | `.hugeint` | 16 | LE i128 | `.hugeint: i128` | `at(i128, i)` |
| `UTINYINT` | `.utinyint` | 1 | LE u8 | `.utinyint: u8` | `at(u8, i)` |
| `USMALLINT` | `.usmallint` | 2 | LE u16 | `.usmallint: u16` | `at(u16, i)` |
| `UINTEGER` | `.uinteger` | 4 | LE u32 | `.uinteger: u32` | `at(u32, i)` |
| `UBIGINT` | `.ubigint` | 8 | LE u64 | `.ubigint: u64` | `at(u64, i)` |
| `UHUGEINT` | `.uhugeint` | 16 | LE u128 | `.uhugeint: u128` | `at(u128, i)` |
| `FLOAT` | `.float` | 4 | LE u32 bit pattern → `@bitCast` | `.float: f32` | `at(f32, i)` |
| `DOUBLE` | `.double` | 8 | LE u64 bit pattern → `@bitCast` | `.double: f64` | `at(f64, i)` |
| `DECIMAL(w,s)` | `.decimal` | 2/4/8/16 by `w` | narrowest signed int that fits `w`, plus `w`/`s` from the type | `.decimal: Value.Decimal` | `at(i16/i32/i64/i128, i)` |
| `VARCHAR` | `.varchar` | variable | length-prefixed byte run, slice borrowed | `.varchar: []const u8` | — (`.strings` storage) |
| *(string literal)* | `.string_literal` | variable | same as VARCHAR | `.varchar` | — |
| `CHAR` | `.char` | variable | same as VARCHAR | `.varchar` | — |
| `BLOB` | `.blob` | variable | length-prefixed byte run | `.blob: []const u8` | — |
| `BIT` | `.bit` | variable | length-prefixed byte run, **raw bytes, not expanded** | `.blob` | — |
| `BIGNUM` | `.bignum` | variable | length-prefixed byte run, **raw DuckDB encoding** | `.blob` | — |
| `DATE` | `.date` | 4 | LE i32 | `.date: i32` | `at(i32, i)` |
| `TIME` | `.time` | 8 | LE i64 | `.time: i64` | `at(i64, i)` |
| `TIME WITH TIME ZONE` | `.time_tz` | 4 | LE i64 read → `.time` (see caveat) | `.time: i64` | — |
| `TIMESTAMP` (µs) | `.timestamp` | 8 | LE i64 | `.timestamp: i64` | `at(i64, i)` |
| `TIMESTAMP_S` | `.timestamp_sec` | 8 | LE i64 | `.timestamp: i64` | `at(i64, i)` |
| `TIMESTAMP_MS` | `.timestamp_ms` | 8 | LE i64 | `.timestamp: i64` | `at(i64, i)` |
| `TIMESTAMP_NS` | `.timestamp_ns` | 8 | LE i64 | `.timestamp: i64` | `at(i64, i)` |
| `TIMESTAMP WITH TIME ZONE` | `.timestamp_tz` | 8 | LE i64 | `.timestamp: i64` | `at(i64, i)` |
| `INTERVAL` | `.interval` | 16 | i32 months, i32 days, i64 micros | `.interval: Interval` | — |
| `UUID` | `.uuid` | 16 | LE i128 → `@bitCast` to u128 | `.uuid: u128` | `at(i128, i)` |
| `ENUM` | `.@"enum"` | 1/2/4 by dictionary size | dictionary index → resolved label | `.@"enum": Value.Enum` | — |
| `NULL` | `.sqlnull` | — | always `.null` | `.null` | — |

**`TIME_TZ` caveat (verified in source).** `LogicalTypeId.time_tz.fixedWidth()`
returns `4`, while `Vector.getValue` decodes `.time_tz` with `readFixed(i64, i)`.
Because `readFixed` indexes by `@sizeOf(T)` and only bounds-checks against the
payload, an 8-byte read at stride 8 over a 4-byte-per-row payload will either
return `error.MalformedVector` (short payload) or read across row boundaries.

**Confirmed against a live server:** `SELECT TIMETZ '12:34:56+09'` fails with
`error.MalformedVector`, while plain `TIME` decodes correctly. DuckDB stores
`TIME_TZ` in 64 bits (micros packed with a UTC offset), so the `readFixed(i64, …)`
in the decoder is right and the `4` in `fixedWidth()` is the defect.

Until that is fixed, cast `TIME_TZ` to `VARCHAR` or `TIME` server-side:

```sql
SELECT my_timetz::VARCHAR FROM t;
```

This is the one inconsistency found in the type tables; everything else in this
document is consistent with the decoder.

### Nested types

| DuckDB type | `LogicalTypeId` | `physicalShape()` | `Vector.storage` | Access via |
|-------------|-----------------|-------------------|------------------|-----------|
| `STRUCT` | `.@"struct"` | `.@"struct"` | `.children: []Vector` | `children()` |
| `LIST` | `.list` | `.list` | `.list{ entries, child }` | `listEntry(row)` + `listChild()` |
| `ARRAY` | `.array` | `.array` | `.array{ size, child }` | `arraySize()` + `listChild()` |
| `MAP` | `.map` | `.list` | `.list{ entries, child }` where child is `STRUCT(key,value)` | `mapEntry(row)` |
| `UNION` | `.@"union"` | `.@"struct"` | `.children` — child 0 is the hidden `UTINYINT` tag | `unionValue(row)` |
| `VARIANT` | `.variant` | `.@"struct"` | `.children` (keys / children / values struct) | `children()` |

Anything else this client does not model returns `error.UnsupportedType` from
`getValue`. Nothing is ever silently mis-decoded.

---

## 4. NULL and the validity mask

A validity mask is a bitset of `u64` words, LSB-first, borrowed straight from the
response buffer.

> **A SET bit means the row is VALID (non-NULL).** A clear bit means NULL. This
> is the opposite of the "null bitmap" convention some formats use, and getting
> it backwards silently inverts your entire result.

When a vector carries no mask at all, every row is valid — `ValidityMask.bytes`
is `null` and `allValid()` returns `true`. `ValidityMask.maskSizeFor(count)`
rounds up to whole `u64` words, matching `ValidityMask::ValidityMaskSize`.

```zig
const m = quackling.ValidityMask.init(bytes, row_count);
m.isValid(3);   // true  = non-NULL
m.isNull(3);    // convenience inverse
m.allValid();   // true when no mask was sent
m.nullCount();  // linear scan over the first `count` rows
```

An index past the end of the mask buffer reports *invalid* rather than reading
out of bounds — a truncated mask degrades to NULLs, never to a buffer overrun.

Prefer the vector-level and chunk-level helpers, because they also handle the
compressed encodings where validity lives on the decoded child rather than on the
outer vector:

```zig
vec.isNull(row);              // handles FLAT / CONSTANT / DICTIONARY / SEQUENCE
chunk.isNull(col, row);       // out-of-range column reports null, not an error
row_view.isNull(col);         // Row helper
```

`Vector.isNull(i)` also reports `true` for `i >= count`, so an out-of-range row
never reads memory.

`getValue` consults validity for you and returns `.null`:

```zig
const v = try chunk.getValue(0, row);
if (v.isNull()) { ... }       // Value.isNull(): `self == .null`
```

Note what the raw fast paths do **not** do: `asSlice`, `at` and `copySlice`
ignore validity entirely. They hand you the physical payload. Check `isNull`
alongside them.

---

## 5. `Value`: the flat scalar view

`Value` is a convenience layer over `Vector`; the vectorized path never
materialises one. Slice payloads (`.varchar`, `.blob`, and an ENUM's `.label`)
**borrow** the chunk's buffer and stay valid exactly as long as the `DataChunk`
they came from.

Coercion helpers:

| Method | Returns | Behaviour |
|--------|---------|-----------|
| `isNull()` | `bool` | `self == .null` |
| `asI64()` | `?i64` | bool → 0/1; all integer widths; `date`/`time`/`timestamp` raw units. `ubigint`/`hugeint`/`uhugeint` go through `std.math.cast`, so out-of-range returns `null` rather than wrapping. Non-numeric (and NULL) → `null` |
| `asF64()` | `?f64` | `float`/`double` directly, `decimal` via `toFloat()`, otherwise whatever `asI64()` yields, `@floatFromInt`ed |
| `asSlice()` | `?[]const u8` | `varchar`/`blob` payload, or an ENUM's `label` (an ENUM reads naturally as its label) |
| `format(w)` | — | SQL-ish text for CLI/debugging |

`Value.Decimal` keeps the unscaled integer plus the type's width and scale; the
real number is `value / 10^scale`. `toFloat()` does that division in `f64` (and
therefore loses precision beyond 15–17 significant digits — use `value` and
`scale` directly when exactness matters).

```zig
pub const Decimal = struct { value: i128, width: u8, scale: u8 };
pub const Interval = struct { months: i32, days: i32, micros: i64 };
pub const Enum = struct { index: u32, label: []const u8 };
```

---

## 6. ENUM resolves to its label

An ENUM cell on the wire is only a dictionary index, stored in the narrowest
unsigned integer that can address the dictionary (`EnumTypeInfo::DictType`):
1 byte up to 255 entries, 2 up to 65535, 4 beyond that — see
`enumDictWidth(count)`. `LogicalType.fixedWidth()` applies that rule for you.

`getValue` reads the index, bounds-checks it against `type.enum_values`
(an out-of-range index is `error.MalformedVector`, never a wild read) and hands
back **both** the index and the resolved label:

```zig
const v = try chunk.getValue(0, row);
switch (v) {
    .@"enum" => |e| {
        std.debug.print("{s} (#{d})\n", .{ e.label, e.index });
    },
    else => {},
}

// Or, since an ENUM reads naturally as its label:
const label = v.asSlice().?;   // "happy"
```

The label bytes borrow the response buffer, via `LogicalType.enum_values`, which
borrows it too. The decoder cross-checks the server's declared `values_count`
(field 200) against the label list it actually read (field 201) and rejects a
mismatch with `error.MalformedVector`, because the physical index width is
derived from that count.

---

## 7. Nested types

The flat `Value` union cannot own nested storage, so `getValue` on a STRUCT /
LIST / ARRAY / MAP / UNION / VARIANT column returns `error.UnsupportedType` by
design. Returning an explicit error beats inventing a lossy scalar
representation. Reach nested data through the vector accessors instead.

| Accessor | Signature | Valid for |
|----------|-----------|-----------|
| `children()` | `?[]Vector` | STRUCT, UNION, VARIANT (any `.children` storage) |
| `listEntry(i)` | `?ListEntry` = `{ offset: u64, length: u64 }` | LIST, MAP (`.list` storage) |
| `listChild()` | `?*Vector` | LIST, MAP **and** ARRAY (`.list` or `.array` storage) |
| `arraySize()` | `?u64` | ARRAY only |
| `mapEntry(i)` | `?MapEntry` = `{ offset, length, keys: *Vector, values: *Vector }` | MAP only (checks `type.id == .map`) |
| `unionValue(i)` | `?UnionMember` = `{ tag: u8, name: []const u8, vector: *Vector }` | UNION only (checks `type.id == .@"union"`) |

Note the ordering hazard: MAP is physically a LIST and UNION is physically a
STRUCT, so `listEntry`/`listChild` succeed on a MAP and `children()` succeeds on
a UNION. **Check `mapEntry` and `unionValue` first** if you dispatch generically,
exactly as the CLI renderer in
[`../../src/cli/main.zig`](../../src/cli/main.zig) does, or you will render the
internal shape instead of the declared type.

### STRUCT

```zig
const vec = chunk.column(0).?;
if (vec.children()) |fields| {
    for (fields, 0..) |*f, i| {
        const name = if (i < vec.type.children.len) vec.type.children[i].name else "";
        const v = try f.getValue(row);           // same row index as the parent
        std.debug.print("{s} = {f}\n", .{ name, v });
    }
}
```

Child vectors are indexed by the **parent's** row index: a STRUCT stores one
child vector per field, each with the same row count as the struct.

### LIST

```zig
if (vec.listEntry(row)) |e| {
    const child = vec.listChild().?;
    for (0..e.length) |k| {
        const v = try child.getValue(@intCast(e.offset + k));
        use(v);
    }
}
```

The child is a single flattened vector shared by every row; each row's window is
the `(offset, length)` pair from `listEntry`.

### ARRAY

An ARRAY has no per-row entries — the length is fixed, so the window is computed:

```zig
if (vec.arraySize()) |size| {
    const child = vec.listChild().?;
    for (0..size) |k| {
        const v = try child.getValue(row * @as(usize, @intCast(size)) + k);
        use(v);
    }
}
```

The child vector's row count is `array_size * parent_count`, which is how the
decoder allocates it.

### MAP

```zig
if (vec.mapEntry(row)) |m| {
    for (0..m.length) |k| {
        const key = try m.keys.getValue(@intCast(m.offset + k));
        const val = try m.values.getValue(@intCast(m.offset + k));
        use(key, val);
    }
}

// Declared key/value types, without the physical STRUCT in the way:
if (vec.type.mapKeyValue()) |kv| {
    std.debug.print("MAP({s} -> {s})\n", .{ kv.key.name(), kv.value.name() });
}
```

### UNION

```zig
if (vec.unionValue(row)) |u| {
    // u.tag    - the UTINYINT tag byte for this row
    // u.name   - the member's declared name ("" if the type tree is short)
    // u.vector - the member's vector; only the tagged member is valid
    const v = try u.vector.getValue(row);
    use(u.name, v);
}

for (vec.type.unionMembers()) |m| {
    std.debug.print("member {s}: {s}\n", .{ m.name, m.type.name() });
}
```

`unionValue` reads the tag via `kids[0].at(u8, i)` and maps it to `kids[tag + 1]`,
returning `null` if the tag is out of range — a corrupt tag never indexes past
the child array.

### VARIANT

VARIANT is physically a STRUCT (of keys / children / values), so it decodes
through the struct path and is reached with `children()`. Quackling exposes that
structure faithfully; it does **not** interpret the VARIANT encoding into a typed
value. If you want VARIANT as a scalar, cast it server-side (e.g.
`CAST(v AS VARCHAR)`).

### The representation insight

DuckDB stores:

- **MAP** as `LIST(STRUCT(key, value))` — `LogicalType.children[0]` is that
  entry struct; `mapEntryType()` returns it and `mapKeyValue()` unwraps it into
  the declared key/value types.
- **UNION** as a STRUCT whose child 0 is a hidden `UTINYINT` tag and whose
  remaining children are the members — `unionMembers()` returns `children[1..]`,
  skipping the tag.

So neither needs its own decode path: `physicalShape()` maps MAP → `.list` and
UNION → `.@"struct"`, reusing the LIST and STRUCT machinery, and the accessors
above hide the representation from callers.

---

## 8. Vector encodings

`VectorType` mirrors DuckDB's enum. It arrives as field 90; **absent means
FLAT**.

| Encoding | Value | `Vector.storage` after decode | Cost |
|----------|-------|------------------------------|------|
| `flat` | 0 | `.fixed: []const u8` / `.strings` / `.children` / `.list` / `.array` | one payload |
| `fsst` | 1 | — | rejected, see below |
| `constant` | 2 | `.constant: *Vector` (a single-row child) | one value, whatever the row count |
| `dictionary` | 3 | `.dictionary { indices: []const u32, child: *Vector }` | dictionary + one u32 per row |
| `sequence` | 4 | `.sequence { start: i64, increment: i64 }` | no payload at all |

**Compressed forms are decoded without being expanded.** A 2048-row CONSTANT
vector still costs one value; a SEQUENCE vector allocates nothing and computes
`start + increment * i` on demand.

What that means for you as a reader:

- `getValue(i)` and `isNull(i)` work uniformly across all four encodings —
  `physicalIndex` resolves the CONSTANT/DICTIONARY indirection internally, and
  validity for those forms is read off the decoded child.
- `isFlat`, `asSlice`, `at` and `copySlice` only ever succeed on `.fixed`
  storage. On a CONSTANT / DICTIONARY / SEQUENCE column they return `null`. So a
  bulk loop must always have a `getValue` fallback, or it will silently process
  zero rows:

  ```zig
  if (col.asSlice(i64)) |slice| {
      for (slice) |v| consume(v);              // zero-copy
  } else if (col.isFlat(i64)) {
      for (0..chunk.row_count) |i| consume(col.at(i64, i).?);
  } else {
      for (0..chunk.row_count) |i| {           // compressed or non-fixed
          consume((try col.getValue(i)).asI64().?);
      }
  }
  ```
- For a SEQUENCE vector, `getValue` maps the computed `i64` back onto the
  column's declared integer type (`intValueFromI64`), so you get `.integer`,
  `.date`, `.ubigint`, … as appropriate, defaulting to `.bigint`. Arithmetic
  overflow while computing the element is `error.MalformedVector`, not a wrap.
- DICTIONARY indices are validated at decode time: every selection index must be
  `< dict_count`, else `error.MalformedVector`.

### Why FSST is deliberately unimplemented

`Vector::Serialize` in DuckDB has **no FSST branch** — an FSST-encoded vector
falls through to `ToUnifiedFormat` and is flattened before it reaches the wire
(`duckdb/src/common/types/vector.cpp`, at the *"TODO: other compressed vector
types (FSST)"* fallthrough). So an FSST vector cannot legitimately arrive.

Rather than guess at an undocumented symbol-table format, the decoder returns
`error.UnsupportedVectorType` if one ever does. The `fsst = 1` member is kept in
the enum so that the values match upstream and an unexpected encoding is
*reported* rather than misread. If a future DuckDB starts emitting FSST, you get
a loud error at exactly the right place.

---

## 9. Zero-copy access rules

Fixed-width data is kept as a **borrowed slice of the response buffer** — no
per-value copy, no per-value allocation. Four accessors expose it, with different
guarantees.

| Accessor | Signature | Succeeds when | Copies |
|----------|-----------|---------------|--------|
| `isFlat(T)` | `bool` | `.fixed` storage, `type.fixedWidth() == @sizeOf(T)`, and payload covers `count * @sizeOf(T)` | — |
| `asSlice(T)` | `?[]const T` | `isFlat(T)` **and** the borrowed pointer is naturally aligned for `T` | none — aliases the wire buffer |
| `at(T, i)` | `?T` | `isFlat(T)` and `i < count` | one element, explicit little-endian load |
| `copySlice(T, out)` | `?usize` | `isFlat(T)` | bulk `@memcpy` on little-endian hosts; element-wise byte-swap on big-endian |

Three rules follow:

1. **`asSlice` is an optimisation, not the normal path.** The wire format offers
   no alignment guarantee: a payload's position depends on the varint-encoded
   lengths before it, so a fixed-width run lands at an arbitrary offset.
   `asSlice` therefore checks `@intFromPtr(ptr) % @alignOf(T)` and returns `null`
   when it does not cooperate. It also returns `null` on a width mismatch — asking
   for `i64` on an `INTEGER` column gives `null`, never a misread. Treat a
   non-null result as a bonus.

2. **`at` always works.** It performs an explicit `std.mem.readInt` /
   `@bitCast` little-endian load, so alignment is irrelevant and the wire bytes
   are never `@ptrCast` into a struct. `copySlice` is the bulk equivalent when
   alignment does not cooperate: still one pass, no per-value branching, and the
   caller owns the destination buffer.

3. **None of the three consults validity.** They hand you the physical payload.
   Check `isNull(i)` alongside them.

`isFlat` is what makes the others safe: it verifies `bytes.len >= count *
@sizeOf(T)` before any of them index the buffer, so a truncated payload is
rejected up front rather than read past.

### The lifetime hazard

> Borrowed data dies at the next `nextChunk()`.

Everything that borrows — `asSlice` results, `Value.varchar` / `Value.blob`
slices, an ENUM's `.label`, `LogicalType.alias`, and `[]const u8` fields produced
by `typed.iterator` — points into the HTTP response buffer that the current batch
owns. `Result` releases the previous FETCH batch before requesting the next, so
exactly one batch is resident at a time and the chunk pointer returned by
`nextChunk` is **invalidated by the following `nextChunk` call**.

```zig
// WRONG: `names` dangles as soon as the loop advances.
var names: std.ArrayList([]const u8) = .empty;
while (try result.nextChunk()) |chunk| {
    var it = chunk.rows();
    while (it.next()) |row| try names.append(alloc, (try row.get(1)).asSlice().?);
}

// RIGHT: copy out what must outlive the chunk.
while (try result.nextChunk()) |chunk| {
    var it = chunk.rows();
    while (it.next()) |row| {
        const s = (try row.get(1)).asSlice().?;
        try names.append(alloc, try alloc.dupe(u8, s));
    }
}
```

The same applies to `copySlice`: use it precisely when you need the numbers to
outlive the chunk.

---

## 10. Temporal and interval conventions

Units are exactly what DuckDB stores; Quackling does no conversion.

| Type | `Value` variant | Unit and epoch |
|------|-----------------|----------------|
| `DATE` | `.date: i32` | **days** since 1970-01-01 (negative before it) |
| `TIME` | `.time: i64` | **microseconds** since midnight |
| `TIMESTAMP` | `.timestamp: i64` | **microseconds** since 1970-01-01 |
| `TIMESTAMP_S` | `.timestamp: i64` | **seconds** since 1970-01-01 |
| `TIMESTAMP_MS` | `.timestamp: i64` | **milliseconds** since 1970-01-01 |
| `TIMESTAMP_NS` | `.timestamp: i64` | **nanoseconds** since 1970-01-01 |
| `TIMESTAMP_TZ` | `.timestamp: i64` | **microseconds** since 1970-01-01, UTC instant |
| `INTERVAL` | `.interval: Interval` | `months: i32`, `days: i32`, `micros: i64`, kept separate |

> **The `Value` variant does not record which unit it holds.** All five
> timestamp ids decode into `.timestamp: i64`. To interpret the number you must
> consult `result.columnType(i).?.id` (or `chunk.columnType(i)`). And note that
> `Value.format` — and therefore the CLI — always renders a `.timestamp` as
> microseconds, so a `TIMESTAMP_S` or `TIMESTAMP_NS` column prints with the wrong
> magnitude. Read the raw integer and scale it yourself, or cast to `TIMESTAMP`
> server-side.

`INTERVAL` keeps its three components separate rather than normalising, because
months and days are not fixed-length: DuckDB's own arithmetic depends on the
calendar. The 16-byte payload is decoded field-by-field with explicit
little-endian reads at offsets 0 / 4 / 8.

`UUID` is stored by DuckDB as a `hugeint` with the sign bit flipped.
`getValue` returns the raw `u128` via `@bitCast`; `value.writeUuid` undoes the
flip (`v ^ (1 << 127)`) when rendering the canonical `8-4-4-4-12` hex form. If
you compare UUIDs numerically, either compare the raw `u128` consistently or
un-flip it first.

Formatting helpers, exported so parameter encoding and value rendering cannot
drift apart (see [`../../src/params.zig`](../../src/params.zig)):

```zig
pub fn writeDate(w: anytype, days: i32) !void;      // YYYY-MM-DD, civil-from-days
pub fn writeTime(w: anytype, micros: i64) !void;    // HH:MM:SS[.ffffff]
pub fn writeTimestamp(w: anytype, micros: i64) !void;
pub fn writeDecimal(w: anytype, d: Value.Decimal) !void;
pub fn writeUuid(w: anytype, v: u128) !void;
```

`writeDate` uses Howard Hinnant's `civil_from_days`, handles years before 1 CE
(printing a leading `-` rather than `+0000`), and `writeTime` normalises into
`[0, 1 day)` so negative values still render sensibly.

---

## 11. Errors from the type layer

| Error | Raised by | Meaning |
|-------|-----------|---------|
| `error.UnsupportedType` | `Vector.getValue` | a nested type (reach it via the accessors), or a type id this client does not model |
| `error.UnsupportedVectorType` | decoder | `VectorType.fsst`, or an unknown encoding |
| `error.MalformedVector` | `Vector.getValue`, decoder | payload shorter than the type and row count imply, row index out of range, ENUM index past the dictionary, DICTIONARY index past the dictionary count, SEQUENCE arithmetic overflow, declared ENUM count disagreeing with the label list |
| `error.ColumnOutOfRange` | `DataChunk.getValue` | `col >= columns.len` |
| `error.RowCountTooLarge` | decoder | `width * count` or `array_size * count` overflowed `usize` |

The decoder touches untrusted bytes, so it follows two rules without exception:
every read goes through the bounds-checked `Reader`, and nothing is `@ptrCast`
from wire data into a struct — fixed-width payloads stay byte slices and are read
with explicit little-endian loads.

---

## 12. Quick reference

```zig
// Type identity
const t = result.columnType(0).?;         // LogicalType
t.id;                                     // LogicalTypeId
t.name();                                 // alias, or SQL name
t.fixedWidth();                           // ?usize, DECIMAL/ENUM aware

// Column
const col = chunk.column(0).?;            // ?*const Vector
col.isNull(row);                          // SET validity bit = valid
col.isFlat(i32);                          // can at()/copySlice() work?
col.asSlice(i32);                         // ?[]const i32, aliases the wire buffer
col.at(i32, row);                         // ?i32, always safe
col.copySlice(i32, &out);                 // ?usize written

// Cell
const v = try col.getValue(row);          // Value, or error.UnsupportedType if nested
v.isNull(); v.asI64(); v.asF64(); v.asSlice();

// Nested
col.children();                           // STRUCT / UNION / VARIANT
col.listEntry(row); col.listChild();      // LIST / MAP
col.arraySize();                          // ARRAY
col.mapEntry(row);                        // MAP  (check before listEntry)
col.unionValue(row);                      // UNION (check before children)
```
