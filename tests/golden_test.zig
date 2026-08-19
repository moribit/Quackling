//! Golden tests: decode wire payloads captured from a real DuckDB Quack server.
//!
//! The `.bin` fixtures in `tests/fixtures/` were produced by a live
//! `CALL quack_serve('quack:localhost:9494', token => 'super_secret')` running
//! DuckDB v1.5.5 with the `quack` extension, driven over plain HTTP. They are
//! the ground truth for protocol compatibility (todo.md §24): if DuckDB changes
//! the format, these fail.
//!
//! Regenerate with `scripts/capture_fixtures.py`.

const std = @import("std");
const quackling = @import("quackling");

const Reader = quackling.serialization.Reader;
const message = quackling.protocol.message;
const testing = std.testing;

/// Fixtures are embedded so the tests need no filesystem at runtime - which
/// also means they run unchanged on wasm.
const fixtures = struct {
    const connection_response = @embedFile("fixtures/connection_response.bin");
    const select42 = @embedFile("fixtures/select42.bin");
    const boolean = @embedFile("fixtures/bool.bin");
    const nulls = @embedFile("fixtures/nulls.bin");
    const varchar = @embedFile("fixtures/varchar.bin");
    const mixed = @embedFile("fixtures/mixed.bin");
    const multirow = @embedFile("fixtures/multirow.bin");
    const unsigned = @embedFile("fixtures/unsigned.bin");
    const hugeint = @embedFile("fixtures/hugeint.bin");
    const largeresult = @embedFile("fixtures/largeresult.bin");
    const nullmix = @embedFile("fixtures/nullmix.bin");
    const err = @embedFile("fixtures/error.bin");
    const emptyresult = @embedFile("fixtures/emptyresult.bin");
    // Nested and extended types.
    const @"struct" = @embedFile("fixtures/struct.bin");
    const list = @embedFile("fixtures/list.bin");
    const list_nulls = @embedFile("fixtures/list_nulls.bin");
    const array = @embedFile("fixtures/array.bin");
    const map = @embedFile("fixtures/map.bin");
    const map_nested = @embedFile("fixtures/map_nested.bin");
    const @"enum" = @embedFile("fixtures/enum.bin");
    const @"union" = @embedFile("fixtures/union.bin");
    const union_multi = @embedFile("fixtures/union_multi.bin");
    const nested_deep = @embedFile("fixtures/nested_deep.bin");
    const temporal = @embedFile("fixtures/temporal.bin");
    const decimal = @embedFile("fixtures/decimal.bin");
    const uuid = @embedFile("fixtures/uuid.bin");
    const blob = @embedFile("fixtures/blob.bin");
    const variant = @embedFile("fixtures/variant.bin");
    const bignum = @embedFile("fixtures/bignum.bin");
};

/// Render a value to text, for the cases where the readable form is the check.
fn render(buf: []u8, v: quackling.Value) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try v.format(&w);
    return w.buffered();
}

/// Decode a full response: header, then the PREPARE_RESPONSE body.
fn decodePrepare(allocator: std.mem.Allocator, bytes: []const u8) !struct {
    header: message.MessageHeader,
    body: message.PrepareResponse,
    consumed: usize,
} {
    var r = Reader.init(bytes);
    const header = try message.MessageHeader.decode(&r);
    const body = try message.PrepareResponse.decode(&r, allocator);
    return .{ .header = header, .body = body, .consumed = r.pos };
}

test "golden: CONNECTION_RESPONSE yields a session id and server identity" {
    var r = Reader.init(fixtures.connection_response);
    const header = try message.MessageHeader.decode(&r);
    try testing.expectEqual(message.MessageType.connection_response, header.type);
    // The server assigns a 32-char uppercase hex session id.
    try testing.expectEqual(@as(usize, 32), header.connection_id.len);
    for (header.connection_id) |c| {
        try testing.expect(std.ascii.isHex(c));
    }

    const body = try message.ConnectionResponse.decode(&r);
    try testing.expect(std.mem.startsWith(u8, body.server_duckdb_version, "v"));
    try testing.expect(body.server_platform.len > 0);
    try testing.expectEqual(@as(u64, 1), body.quack_version);
    // Every byte must be accounted for.
    try testing.expectEqual(fixtures.connection_response.len, r.pos);
}

test "golden: SELECT 42 decodes to the integer 42" {
    const got = try decodePrepare(testing.allocator, fixtures.select42);
    var body = got.body;
    defer body.deinit();

    try testing.expectEqual(message.MessageType.prepare_response, got.header.type);
    try testing.expectEqual(@as(usize, 1), body.types.len);
    try testing.expectEqual(quackling.LogicalTypeId.integer, body.types[0].id);
    try testing.expectEqualStrings("answer", body.names[0]);
    try testing.expectEqual(@as(usize, 1), body.chunks.len);

    const chunk = body.chunks[0];
    try testing.expectEqual(@as(usize, 1), chunk.row_count);
    try testing.expectEqual(@as(usize, 1), chunk.columnCount());
    const v = try chunk.getValue(0, 0);
    try testing.expectEqual(@as(i32, 42), v.integer);

    // No trailing garbage, no truncation.
    try testing.expectEqual(fixtures.select42.len, got.consumed);
}

test "golden: booleans decode as true and false" {
    const got = try decodePrepare(testing.allocator, fixtures.boolean);
    var body = got.body;
    defer body.deinit();

    try testing.expectEqual(@as(usize, 2), body.types.len);
    try testing.expectEqual(quackling.LogicalTypeId.boolean, body.types[0].id);
    const chunk = body.chunks[0];
    try testing.expectEqual(true, (try chunk.getValue(0, 0)).boolean);
    try testing.expectEqual(false, (try chunk.getValue(1, 0)).boolean);
    try testing.expectEqual(fixtures.boolean.len, got.consumed);
}

test "golden: NULL and non-NULL in the same row" {
    const got = try decodePrepare(testing.allocator, fixtures.nulls);
    var body = got.body;
    defer body.deinit();

    const chunk = body.chunks[0];
    try testing.expect(chunk.isNull(0, 0));
    try testing.expect((try chunk.getValue(0, 0)).isNull());
    try testing.expect(!chunk.isNull(1, 0));
    try testing.expectEqual(@as(i32, 1), (try chunk.getValue(1, 0)).integer);
    try testing.expectEqual(fixtures.nulls.len, got.consumed);
}

test "golden: VARCHAR including multi-byte UTF-8" {
    const got = try decodePrepare(testing.allocator, fixtures.varchar);
    var body = got.body;
    defer body.deinit();

    try testing.expectEqual(quackling.LogicalTypeId.varchar, body.types[0].id);
    const chunk = body.chunks[0];
    try testing.expectEqualStrings("hello", (try chunk.getValue(0, 0)).varchar);
    try testing.expectEqualStrings("wörld🦆", (try chunk.getValue(1, 0)).varchar);
    try testing.expectEqual(fixtures.varchar.len, got.consumed);
}

test "golden: every primitive width decodes to the right value" {
    const got = try decodePrepare(testing.allocator, fixtures.mixed);
    var body = got.body;
    defer body.deinit();

    const chunk = body.chunks[0];
    try testing.expectEqual(@as(i8, 1), (try chunk.getValue(0, 0)).tinyint);
    try testing.expectEqual(@as(i16, 2), (try chunk.getValue(1, 0)).smallint);
    try testing.expectEqual(@as(i32, 3), (try chunk.getValue(2, 0)).integer);
    try testing.expectEqual(@as(i64, 4), (try chunk.getValue(3, 0)).bigint);
    try testing.expectEqual(@as(f32, 5.5), (try chunk.getValue(4, 0)).float);
    try testing.expectEqual(@as(f64, 6.25), (try chunk.getValue(5, 0)).double);
    try testing.expectEqualStrings("x", (try chunk.getValue(6, 0)).varchar);
    try testing.expectEqual(fixtures.mixed.len, got.consumed);
}

test "golden: unsigned integer types" {
    const got = try decodePrepare(testing.allocator, fixtures.unsigned);
    var body = got.body;
    defer body.deinit();

    const chunk = body.chunks[0];
    try testing.expectEqual(@as(u8, 1), (try chunk.getValue(0, 0)).utinyint);
    try testing.expectEqual(@as(u16, 2), (try chunk.getValue(1, 0)).usmallint);
    try testing.expectEqual(@as(u32, 3), (try chunk.getValue(2, 0)).uinteger);
    try testing.expectEqual(@as(u64, 4), (try chunk.getValue(3, 0)).ubigint);
    try testing.expectEqual(fixtures.unsigned.len, got.consumed);
}

test "golden: HUGEINT carries full 128-bit range" {
    const got = try decodePrepare(testing.allocator, fixtures.hugeint);
    var body = got.body;
    defer body.deinit();

    try testing.expectEqual(quackling.LogicalTypeId.hugeint, body.types[0].id);
    const chunk = body.chunks[0];
    try testing.expectEqual(
        @as(i128, std.math.maxInt(i128)),
        (try chunk.getValue(0, 0)).hugeint,
    );
    try testing.expectEqual(fixtures.hugeint.len, got.consumed);
}

test "golden: multiple rows and columns" {
    const got = try decodePrepare(testing.allocator, fixtures.multirow);
    var body = got.body;
    defer body.deinit();

    const chunk = body.chunks[0];
    try testing.expectEqual(@as(usize, 5), chunk.row_count);
    try testing.expectEqual(@as(usize, 2), chunk.columnCount());
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const a = (try chunk.getValue(0, i)).asI64().?;
        const b = (try chunk.getValue(1, i)).asI64().?;
        try testing.expectEqual(@as(i64, @intCast(i)), a);
        try testing.expectEqual(a * 2, b);
    }
    try testing.expectEqual(fixtures.multirow.len, got.consumed);
}

test "golden: alternating NULLs follow the validity mask" {
    const got = try decodePrepare(testing.allocator, fixtures.nullmix);
    var body = got.body;
    defer body.deinit();

    const chunk = body.chunks[0];
    try testing.expectEqual(@as(usize, 10), chunk.row_count);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        // SQL: CASE WHEN i%2=0 THEN NULL ELSE i END
        if (i % 2 == 0) {
            try testing.expect(chunk.isNull(0, i));
        } else {
            try testing.expectEqual(@as(i32, @intCast(i)), (try chunk.getValue(0, i)).integer);
        }
    }
    try testing.expectEqual(fixtures.nullmix.len, got.consumed);
}

test "golden: a large result arrives as multiple chunks needing FETCH" {
    const got = try decodePrepare(testing.allocator, fixtures.largeresult);
    var body = got.body;
    defer body.deinit();

    // 5000 rows exceeds one 2048-row chunk.
    try testing.expect(body.chunks.len > 1);
    var total: usize = 0;
    for (body.chunks) |c| {
        try testing.expect(c.row_count <= 2048);
        total += c.row_count;
    }
    try testing.expectEqual(@as(usize, 5000), total);
    // Fully contained in the PREPARE response, so no further FETCH needed.
    try testing.expect(!body.needs_more_fetch);

    // Values must be the sequence 0..4999 across chunk boundaries.
    var expect: i64 = 0;
    for (body.chunks) |c| {
        var i: usize = 0;
        while (i < c.row_count) : (i += 1) {
            try testing.expectEqual(expect, (try c.getValue(0, i)).asI64().?);
            expect += 1;
        }
    }
    try testing.expectEqual(fixtures.largeresult.len, got.consumed);
}

test "golden: an empty result still reports its schema" {
    const got = try decodePrepare(testing.allocator, fixtures.emptyresult);
    var body = got.body;
    defer body.deinit();

    try testing.expectEqual(@as(usize, 1), body.types.len);
    try testing.expectEqualStrings("a", body.names[0]);
    var rows: usize = 0;
    for (body.chunks) |c| rows += c.row_count;
    try testing.expectEqual(@as(usize, 0), rows);
    try testing.expectEqual(fixtures.emptyresult.len, got.consumed);
}

test "golden: ERROR_RESPONSE preserves the DuckDB message" {
    var r = Reader.init(fixtures.err);
    const header = try message.MessageHeader.decode(&r);
    try testing.expectEqual(message.MessageType.error_response, header.type);

    const body = try message.ErrorResponse.decode(&r);
    // The real server text names the missing table.
    try testing.expect(body.message.len > 0);
    try testing.expect(std.mem.indexOf(u8, body.message, "nonexistent_table_xyz") != null);
    try testing.expectEqual(fixtures.err.len, r.pos);
}

test "golden: zero-copy slice access matches value-by-value decoding" {
    const got = try decodePrepare(testing.allocator, fixtures.multirow);
    var body = got.body;
    defer body.deinit();

    const chunk = body.chunks[0];
    const col = chunk.column(0).?;
    // range() produces BIGINT, so the flat fast path is i64.
    try testing.expect(col.isFlat(i64));

    // `at()` works whatever the wire alignment happens to be.
    var i: usize = 0;
    while (i < chunk.row_count) : (i += 1) {
        try testing.expectEqual(
            (try chunk.getValue(0, i)).asI64().?,
            col.at(i64, i).?,
        );
    }

    // Bulk copy must agree too.
    var buf: [8]i64 = undefined;
    const n = col.copySlice(i64, &buf).?;
    try testing.expectEqual(chunk.row_count, n);
    for (buf[0..n], 0..) |v, j| {
        try testing.expectEqual((try chunk.getValue(0, j)).asI64().?, v);
    }

    // asSlice is the aligned-only optimisation; when it fires it must match.
    if (col.asSlice(i64)) |slice| {
        try testing.expectEqualSlices(i64, buf[0..n], slice);
    }
}

// -- nested and extended types ------------------------------------------------

test "golden: STRUCT exposes its fields" {
    const got = try decodePrepare(testing.allocator, fixtures.@"struct");
    var body = got.body;
    defer body.deinit();

    try testing.expectEqual(quackling.LogicalTypeId.@"struct", body.types[0].id);
    try testing.expectEqual(@as(usize, 2), body.types[0].children.len);
    try testing.expectEqualStrings("a", body.types[0].children[0].name);
    try testing.expectEqualStrings("b", body.types[0].children[1].name);

    const kids = body.chunks[0].column(0).?.children().?;
    try testing.expectEqual(@as(usize, 2), kids.len);
    try testing.expectEqual(@as(i32, 1), (try kids[0].getValue(0)).integer);
    try testing.expectEqualStrings("x", (try kids[1].getValue(0)).varchar);
    try testing.expectEqual(fixtures.@"struct".len, got.consumed);
}

test "golden: LIST exposes its elements" {
    const got = try decodePrepare(testing.allocator, fixtures.list);
    var body = got.body;
    defer body.deinit();

    try testing.expectEqual(quackling.LogicalTypeId.list, body.types[0].id);
    const v = body.chunks[0].column(0).?;
    const e = v.listEntry(0).?;
    try testing.expectEqual(@as(u64, 3), e.length);
    const child = v.listChild().?;
    const expect = [_]i64{ 10, 20, 30 };
    for (expect, 0..) |want, i| {
        try testing.expectEqual(want, (try child.getValue(@intCast(e.offset + i))).asI64().?);
    }
    try testing.expectEqual(fixtures.list.len, got.consumed);
}

test "golden: NULLs inside a LIST are preserved" {
    const got = try decodePrepare(testing.allocator, fixtures.list_nulls);
    var body = got.body;
    defer body.deinit();

    const v = body.chunks[0].column(0).?;
    const e = v.listEntry(0).?;
    const child = v.listChild().?;
    try testing.expectEqual(@as(u64, 3), e.length);
    try testing.expect(!child.isNull(@intCast(e.offset)));
    try testing.expect(child.isNull(@intCast(e.offset + 1)));
    try testing.expect(!child.isNull(@intCast(e.offset + 2)));
    try testing.expectEqual(fixtures.list_nulls.len, got.consumed);
}

test "golden: ARRAY has a fixed element count" {
    const got = try decodePrepare(testing.allocator, fixtures.array);
    var body = got.body;
    defer body.deinit();

    try testing.expectEqual(quackling.LogicalTypeId.array, body.types[0].id);
    const v = body.chunks[0].column(0).?;
    try testing.expectEqual(@as(u64, 3), v.arraySize().?);
    const child = v.listChild().?;
    for ([_]i64{ 1, 2, 3 }, 0..) |want, i| {
        try testing.expectEqual(want, (try child.getValue(i)).asI64().?);
    }
    try testing.expectEqual(fixtures.array.len, got.consumed);
}

test "golden: MAP decodes as key/value pairs" {
    const got = try decodePrepare(testing.allocator, fixtures.map);
    var body = got.body;
    defer body.deinit();

    try testing.expectEqual(quackling.LogicalTypeId.map, body.types[0].id);
    // The declared key/value types are reachable without knowing the physical
    // LIST(STRUCT(..)) representation.
    const kv = body.types[0].mapKeyValue().?;
    try testing.expectEqual(quackling.LogicalTypeId.varchar, kv.key.id);
    try testing.expectEqual(quackling.LogicalTypeId.integer, kv.value.id);

    const m = body.chunks[0].column(0).?.mapEntry(0).?;
    try testing.expectEqual(@as(u64, 2), m.length);
    try testing.expectEqualStrings("a", (try m.keys.getValue(@intCast(m.offset))).varchar);
    try testing.expectEqual(@as(i32, 1), (try m.values.getValue(@intCast(m.offset))).integer);
    try testing.expectEqualStrings("b", (try m.keys.getValue(@intCast(m.offset + 1))).varchar);
    try testing.expectEqual(@as(i32, 2), (try m.values.getValue(@intCast(m.offset + 1))).integer);
    try testing.expectEqual(fixtures.map.len, got.consumed);
}

test "golden: MAP with a nested LIST value" {
    const got = try decodePrepare(testing.allocator, fixtures.map_nested);
    var body = got.body;
    defer body.deinit();

    const m = body.chunks[0].column(0).?.mapEntry(0).?;
    try testing.expectEqualStrings("k", (try m.keys.getValue(@intCast(m.offset))).varchar);
    // The value is itself a LIST.
    const inner = m.values.listEntry(@intCast(m.offset)).?;
    const inner_child = m.values.listChild().?;
    try testing.expectEqual(@as(u64, 2), inner.length);
    try testing.expectEqual(@as(i64, 1), (try inner_child.getValue(@intCast(inner.offset))).asI64().?);
    try testing.expectEqual(@as(i64, 2), (try inner_child.getValue(@intCast(inner.offset + 1))).asI64().?);
    try testing.expectEqual(fixtures.map_nested.len, got.consumed);
}

test "golden: ENUM resolves to its label" {
    const got = try decodePrepare(testing.allocator, fixtures.@"enum");
    var body = got.body;
    defer body.deinit();

    try testing.expectEqual(quackling.LogicalTypeId.@"enum", body.types[0].id);
    try testing.expectEqual(@as(usize, 3), body.types[0].enum_values.len);
    try testing.expectEqualStrings("sad", body.types[0].enum_values[0]);
    try testing.expectEqualStrings("happy", body.types[0].enum_values[2]);
    // A 3-entry dictionary indexes into one byte.
    try testing.expectEqual(@as(?usize, 1), body.types[0].fixedWidth());

    const v = try body.chunks[0].getValue(0, 0);
    try testing.expectEqualStrings("happy", v.@"enum".label);
    try testing.expectEqual(@as(u32, 2), v.@"enum".index);
    try testing.expectEqualStrings("happy", v.asSlice().?);
    try testing.expectEqual(fixtures.@"enum".len, got.consumed);
}

test "golden: UNION reports its active member" {
    const got = try decodePrepare(testing.allocator, fixtures.@"union");
    var body = got.body;
    defer body.deinit();

    try testing.expectEqual(quackling.LogicalTypeId.@"union", body.types[0].id);
    // The hidden tag child is not a member.
    const members = body.types[0].unionMembers();
    try testing.expectEqual(@as(usize, 1), members.len);
    try testing.expectEqualStrings("num", members[0].name);

    const u = body.chunks[0].column(0).?.unionValue(0).?;
    try testing.expectEqual(@as(u8, 0), u.tag);
    try testing.expectEqualStrings("num", u.name);
    try testing.expectEqual(@as(i32, 2), (try u.vector.getValue(0)).integer);
    try testing.expectEqual(fixtures.@"union".len, got.consumed);
}

test "golden: UNION with a VARCHAR member" {
    const got = try decodePrepare(testing.allocator, fixtures.union_multi);
    var body = got.body;
    defer body.deinit();
    const u = body.chunks[0].column(0).?.unionValue(0).?;
    try testing.expectEqualStrings("s", u.name);
    try testing.expectEqualStrings("txt", (try u.vector.getValue(0)).varchar);
    try testing.expectEqual(fixtures.union_multi.len, got.consumed);
}

test "golden: a struct containing a list decodes recursively" {
    const got = try decodePrepare(testing.allocator, fixtures.nested_deep);
    var body = got.body;
    defer body.deinit();

    const kids = body.chunks[0].column(0).?.children().?;
    try testing.expectEqual(@as(usize, 2), kids.len);
    // kids[0] is the inner LIST.
    const e = kids[0].listEntry(0).?;
    const inner = kids[0].listChild().?;
    try testing.expectEqual(@as(u64, 2), e.length);
    try testing.expectEqual(@as(i64, 1), (try inner.getValue(@intCast(e.offset))).asI64().?);
    try testing.expectEqualStrings("x", (try kids[1].getValue(0)).varchar);
    try testing.expectEqual(fixtures.nested_deep.len, got.consumed);
}

test "golden: temporal types" {
    const got = try decodePrepare(testing.allocator, fixtures.temporal);
    var body = got.body;
    defer body.deinit();

    var buf: [64]u8 = undefined;
    const chunk = body.chunks[0];
    try testing.expectEqualStrings("2024-03-15", try render(&buf, try chunk.getValue(0, 0)));
    try testing.expectEqualStrings("12:34:56", try render(&buf, try chunk.getValue(1, 0)));
    try testing.expectEqualStrings("2024-03-15 12:34:56", try render(&buf, try chunk.getValue(2, 0)));
    const iv = (try chunk.getValue(3, 0)).interval;
    try testing.expectEqual(@as(i32, 3), iv.days);
    try testing.expectEqual(fixtures.temporal.len, got.consumed);
}

test "golden: DECIMAL keeps its scale across storage widths" {
    const got = try decodePrepare(testing.allocator, fixtures.decimal);
    var body = got.body;
    defer body.deinit();

    var buf: [64]u8 = undefined;
    const chunk = body.chunks[0];
    try testing.expectEqualStrings("12.34", try render(&buf, try chunk.getValue(0, 0)));
    try testing.expectEqualStrings("1.5", try render(&buf, try chunk.getValue(1, 0)));
    // DECIMAL(30,2) exceeds 64 bits, so it is stored as a hugeint.
    try testing.expectEqualStrings("123456789012345678.99", try render(&buf, try chunk.getValue(2, 0)));
    try testing.expectEqual(@as(?usize, 16), body.types[2].fixedWidth());
    try testing.expectEqual(fixtures.decimal.len, got.consumed);
}

test "golden: UUID round trips its canonical text form" {
    const got = try decodePrepare(testing.allocator, fixtures.uuid);
    var body = got.body;
    defer body.deinit();
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "0cc7435c-7cc0-4836-b03d-53aed12d1006",
        try render(&buf, try body.chunks[0].getValue(0, 0)),
    );
    try testing.expectEqual(fixtures.uuid.len, got.consumed);
}

test "golden: BLOB carries raw bytes" {
    const got = try decodePrepare(testing.allocator, fixtures.blob);
    var body = got.body;
    defer body.deinit();
    try testing.expectEqualStrings("abc", (try body.chunks[0].getValue(0, 0)).blob);
    try testing.expectEqualStrings("hi", (try body.chunks[0].getValue(1, 0)).blob);
    try testing.expectEqual(fixtures.blob.len, got.consumed);
}

test "golden: VARIANT decodes via its struct representation" {
    const got = try decodePrepare(testing.allocator, fixtures.variant);
    var body = got.body;
    defer body.deinit();
    try testing.expectEqual(quackling.LogicalTypeId.variant, body.types[0].id);
    // Physically a STRUCT of keys/children/values.
    try testing.expect(body.chunks[0].column(0).?.children() != null);
    try testing.expectEqual(fixtures.variant.len, got.consumed);
}

test "golden: BIGNUM arrives as a byte run" {
    const got = try decodePrepare(testing.allocator, fixtures.bignum);
    var body = got.body;
    defer body.deinit();
    try testing.expectEqual(quackling.LogicalTypeId.bignum, body.types[0].id);
    try testing.expect((try body.chunks[0].getValue(0, 0)).blob.len > 0);
    try testing.expectEqual(fixtures.bignum.len, got.consumed);
}

test "golden: every fixture decodes without leaking" {
    // testing.allocator fails the test on leak, so simply decoding each fixture
    // under it is the assertion.
    const all = [_][]const u8{
        fixtures.select42, fixtures.boolean,     fixtures.nulls,
        fixtures.varchar,  fixtures.mixed,       fixtures.multirow,
        fixtures.unsigned, fixtures.hugeint,     fixtures.largeresult,
        fixtures.nullmix,  fixtures.emptyresult,
    };
    for (all) |bytes| {
        const got = try decodePrepare(testing.allocator, bytes);
        var body = got.body;
        body.deinit();
    }
}
