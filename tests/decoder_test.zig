//! Decoder guard tests.
//!
//! `decoder.zig` is the component that consumes untrusted bytes, and several of
//! its bounds checks were reachable only by inputs a real server never sends —
//! so the golden fixtures could not exercise them. Mutation testing confirmed
//! four guards had no covering test: the validity mask, the list-length
//! remaining-bytes check, the dictionary index bound, and the ENUM index bound.
//!
//! Each test here builds the precise malformed message that trips one guard, so
//! removing the guard fails a test instead of silently permitting an
//! out-of-bounds read.

const std = @import("std");
const quackling = @import("quackling");

const testing = std.testing;
const Reader = quackling.serialization.Reader;
const decoder = quackling.serialization.decoder;
const Writer = quackling.serialization.Writer;
const LogicalTypeId = quackling.LogicalTypeId;

const Buf = std.ArrayList(u8);

/// Build a byte string with a small DSL, so each test reads as the message it
/// is describing rather than as a pile of hex.
const B = struct {
    buf: Buf = .empty,
    a: std.mem.Allocator,

    fn init(a: std.mem.Allocator) B {
        return .{ .a = a };
    }
    fn deinit(self: *B) void {
        self.buf.deinit(self.a);
    }
    fn w(self: *B) Writer {
        return Writer.init(self.a, &self.buf);
    }
    fn field(self: *B, id: u16) !void {
        var x = self.w();
        try x.writeFieldId(id);
    }
    fn end(self: *B) !void {
        var x = self.w();
        try x.writeTerminator();
    }
    fn uvar(self: *B, v: u64) !void {
        var x = self.w();
        try x.writeUVarInt(v);
    }
    fn ivar(self: *B, v: i64) !void {
        var x = self.w();
        try x.writeIVarInt(v);
    }
    fn boolean(self: *B, v: bool) !void {
        var x = self.w();
        try x.writeBool(v);
    }
    fn str(self: *B, s: []const u8) !void {
        var x = self.w();
        try x.writeString(s);
    }
    fn blob(self: *B, bytes: []const u8) !void {
        var x = self.w();
        try x.writeUVarInt(@as(u64, bytes.len));
        try x.writeRaw(bytes);
    }
    fn raw(self: *B, bytes: []const u8) !void {
        var x = self.w();
        try x.writeRaw(bytes);
    }
    fn items(self: *B) []const u8 {
        return self.buf.items;
    }
};

/// A minimal LogicalType object: `{100: id}`.
fn writeType(b: *B, id: LogicalTypeId) !void {
    try b.field(100);
    try b.uvar(@intFromEnum(id));
    try b.end();
}

/// Decode a standalone DataChunk and return it (caller deinits).
fn decodeChunk(a: std.mem.Allocator, bytes: []const u8) !quackling.DataChunk {
    var r = Reader.init(bytes);
    return decoder.decodeDataChunk(&r, a);
}

// -- validity mask -------------------------------------------------------------

test "a validity mask marks the right rows NULL" {
    // Two INTEGER rows with a mask that makes row 0 NULL and row 1 valid.
    // Without the `has_validity_mask` handling this decodes as all-valid.
    var b = B.init(testing.allocator);
    defer b.deinit();

    try b.field(100); // rows
    try b.uvar(2);
    try b.field(101); // types
    try b.uvar(1);
    try writeType(&b, .integer);
    try b.field(102); // columns
    try b.uvar(1);
    // Vector
    try b.field(100); // has_validity_mask
    try b.boolean(true);
    try b.field(101); // validity: 8 bytes, bit0=0 (null), bit1=1 (valid)
    try b.blob(&[_]u8{ 0b0000_0010, 0, 0, 0, 0, 0, 0, 0 });
    try b.field(102); // data
    try b.blob(&[_]u8{ 11, 0, 0, 0, 22, 0, 0, 0 });
    try b.end(); // vector
    try b.end(); // chunk

    var chunk = try decodeChunk(testing.allocator, b.items());
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 2), chunk.row_count);
    try testing.expect(chunk.isNull(0, 0));
    try testing.expect((try chunk.getValue(0, 0)).isNull());
    try testing.expect(!chunk.isNull(0, 1));
    try testing.expectEqual(@as(i32, 22), (try chunk.getValue(0, 1)).integer);
}

test "has_validity_mask = false means every row is valid" {
    var b = B.init(testing.allocator);
    defer b.deinit();

    try b.field(100);
    try b.uvar(2);
    try b.field(101);
    try b.uvar(1);
    try writeType(&b, .integer);
    try b.field(102);
    try b.uvar(1);
    try b.field(100);
    try b.boolean(false); // no mask follows
    try b.field(102);
    try b.blob(&[_]u8{ 1, 0, 0, 0, 2, 0, 0, 0 });
    try b.end();
    try b.end();

    var chunk = try decodeChunk(testing.allocator, b.items());
    defer chunk.deinit();
    try testing.expect(!chunk.isNull(0, 0));
    try testing.expect(!chunk.isNull(0, 1));
    try testing.expect(chunk.column(0).?.validity.allValid());
}

test "a truncated validity mask is rejected" {
    var b = B.init(testing.allocator);
    defer b.deinit();

    try b.field(100);
    try b.uvar(2);
    try b.field(101);
    try b.uvar(1);
    try writeType(&b, .integer);
    try b.field(102);
    try b.uvar(1);
    try b.field(100);
    try b.boolean(true);
    try b.field(101);
    // Claims 8 mask bytes but the buffer ends here.
    try b.raw(&[_]u8{0x08});
    const bytes = b.items();

    var r = Reader.init(bytes);
    try testing.expectError(error.UnexpectedEndOfBuffer, decoder.decodeDataChunk(&r, testing.allocator));
}

// -- list length guard -----------------------------------------------------------

test "a list count larger than the remaining bytes is rejected before allocating" {
    // Each element costs at least one byte, so a count beyond the buffer is
    // provably truncated. Without this check the decoder would allocate for
    // far more elements than it can ever read.
    //
    // The count is chosen to sit *below* `max_list_length` so that the
    // remaining-bytes check is what rejects it, not the absolute cap - the two
    // guards are separate and each needs its own coverage.
    var r = Reader.init(&[_]u8{ 0x80, 0x02, 0xAA }); // 256 elements, 1 byte left
    try testing.expectError(error.UnexpectedEndOfBuffer, r.readListLength());

    // And the absolute cap catches counts beyond even that.
    var r2 = Reader.initWithLimits(&[_]u8{ 0xFF, 0xFF, 0xFF, 0x7F }, .{ .max_list_length = 16 });
    try testing.expectError(error.LengthLimitExceeded, r2.readListLength());
}

test "an honest list count within the buffer is accepted" {
    // 3 elements, 3 bytes of payload available.
    var r = Reader.init(&[_]u8{ 0x03, 0xAA, 0xBB, 0xCC });
    try testing.expectEqual(@as(usize, 3), try r.readListLength());
}

test "a chunk claiming more columns than bytes is rejected" {
    var b = B.init(testing.allocator);
    defer b.deinit();
    try b.field(100);
    try b.uvar(1);
    try b.field(101);
    try b.uvar(1);
    try writeType(&b, .integer);
    try b.field(102);
    // Claim more columns than there are bytes left to describe them.
    try b.raw(&[_]u8{ 0x80, 0x02 }); // 256 columns, nothing following

    var r = Reader.init(b.items());
    const res = decoder.decodeDataChunk(&r, testing.allocator);
    try testing.expectError(error.UnexpectedEndOfBuffer, res);
}

// -- dictionary vector bounds ------------------------------------------------------

/// A DICTIONARY-encoded INTEGER vector whose selection vector holds `sel`,
/// over a dictionary of `dict` values.
fn writeDictChunk(b: *B, sel: []const u32, dict: []const i32) !void {
    try b.field(100); // rows
    try b.uvar(sel.len);
    try b.field(101); // types
    try b.uvar(1);
    try writeType(b, .integer);
    try b.field(102); // columns
    try b.uvar(1);

    // Vector: field 90 = DICTIONARY
    try b.field(90);
    try b.uvar(@intFromEnum(quackling.VectorType.dictionary));
    try b.field(91); // sel_vector blob
    var sel_bytes: [64]u8 = undefined;
    for (sel, 0..) |v, i| std.mem.writeInt(u32, sel_bytes[i * 4 ..][0..4], v, .little);
    try b.blob(sel_bytes[0 .. sel.len * 4]);
    try b.field(92); // dict_count
    try b.uvar(dict.len);
    // The dictionary itself is a nested vector of `dict.len` values.
    try b.field(100);
    try b.boolean(false);
    try b.field(102);
    var data: [64]u8 = undefined;
    for (dict, 0..) |v, i| std.mem.writeInt(i32, data[i * 4 ..][0..4], v, .little);
    try b.blob(data[0 .. dict.len * 4]);
    try b.end(); // end dictionary child vector
    try b.end(); // end outer vector
    try b.end(); // end chunk
}

test "a valid dictionary vector resolves through its indices" {
    var b = B.init(testing.allocator);
    defer b.deinit();
    try writeDictChunk(&b, &[_]u32{ 1, 0, 1 }, &[_]i32{ 70, 90 });

    var chunk = try decodeChunk(testing.allocator, b.items());
    defer chunk.deinit();
    try testing.expectEqual(@as(i32, 90), (try chunk.getValue(0, 0)).integer);
    try testing.expectEqual(@as(i32, 70), (try chunk.getValue(0, 1)).integer);
    try testing.expectEqual(@as(i32, 90), (try chunk.getValue(0, 2)).integer);
}

test "a dictionary index past the dictionary is rejected at decode time" {
    // Index 5 into a 2-entry dictionary. Accepting this would let `getValue`
    // read outside the dictionary payload.
    var b = B.init(testing.allocator);
    defer b.deinit();
    try writeDictChunk(&b, &[_]u32{ 0, 5 }, &[_]i32{ 70, 90 });

    var r = Reader.init(b.items());
    try testing.expectError(error.MalformedVector, decoder.decodeDataChunk(&r, testing.allocator));
}

test "a selection vector shorter than the row count is rejected" {
    var b = B.init(testing.allocator);
    defer b.deinit();

    try b.field(100);
    try b.uvar(4); // claims 4 rows
    try b.field(101);
    try b.uvar(1);
    try writeType(&b, .integer);
    try b.field(102);
    try b.uvar(1);
    try b.field(90);
    try b.uvar(@intFromEnum(quackling.VectorType.dictionary));
    try b.field(91);
    try b.blob(&[_]u8{ 0, 0, 0, 0 }); // only 1 index for 4 rows
    try b.field(92);
    try b.uvar(1);
    try b.field(100);
    try b.boolean(false);
    try b.field(102);
    try b.blob(&[_]u8{ 7, 0, 0, 0 });
    try b.end();
    try b.end();
    try b.end();

    var r = Reader.init(b.items());
    try testing.expectError(error.MalformedVector, decoder.decodeDataChunk(&r, testing.allocator));
}

// -- ENUM index bounds ---------------------------------------------------------------

/// An ENUM column with dictionary `labels` and stored indices `codes`.
fn writeEnumChunk(b: *B, labels: []const []const u8, codes: []const u8) !void {
    try b.field(100);
    try b.uvar(codes.len);
    try b.field(101); // types
    try b.uvar(1);
    // LogicalType { 100: ENUM, 101: ExtraTypeInfo{100: enum, 200: count, 201: values} }
    try b.field(100);
    try b.uvar(@intFromEnum(LogicalTypeId.@"enum"));
    try b.field(101);
    try b.boolean(true); // type_info present
    try b.field(100);
    try b.uvar(6); // ExtraTypeInfoType.enum_
    try b.field(200);
    try b.uvar(labels.len);
    try b.field(201);
    try b.uvar(labels.len);
    for (labels) |l| try b.str(l);
    try b.end(); // end ExtraTypeInfo
    try b.end(); // end LogicalType
    try b.field(102); // columns
    try b.uvar(1);
    try b.field(100);
    try b.boolean(false);
    try b.field(102);
    try b.blob(codes); // one byte per row for a small dictionary
    try b.end();
    try b.end();
}

test "a valid ENUM code resolves to its label" {
    var b = B.init(testing.allocator);
    defer b.deinit();
    try writeEnumChunk(&b, &.{ "sad", "ok", "happy" }, &[_]u8{ 2, 0 });

    var chunk = try decodeChunk(testing.allocator, b.items());
    defer chunk.deinit();
    try testing.expectEqualStrings("happy", (try chunk.getValue(0, 0)).@"enum".label);
    try testing.expectEqualStrings("sad", (try chunk.getValue(0, 1)).@"enum".label);
}

test "an ENUM code past the dictionary is an error, not an out-of-bounds read" {
    // Code 7 with a 3-entry dictionary. Without the bound this indexes past
    // `enum_values`.
    var b = B.init(testing.allocator);
    defer b.deinit();
    try writeEnumChunk(&b, &.{ "sad", "ok", "happy" }, &[_]u8{7});

    var chunk = try decodeChunk(testing.allocator, b.items());
    defer chunk.deinit();
    try testing.expectError(error.MalformedVector, chunk.getValue(0, 0));
}

test "an ENUM whose declared count disagrees with its label list is rejected" {
    // `values_count` says 5 but only 2 labels follow. The count determines the
    // physical width, so a mismatch would misread every value.
    var b = B.init(testing.allocator);
    defer b.deinit();

    try b.field(100);
    try b.uvar(1);
    try b.field(101);
    try b.uvar(1);
    try b.field(100);
    try b.uvar(@intFromEnum(LogicalTypeId.@"enum"));
    try b.field(101);
    try b.boolean(true);
    try b.field(100);
    try b.uvar(6);
    try b.field(200);
    try b.uvar(5); // declared
    try b.field(201);
    try b.uvar(2); // actual
    try b.str("a");
    try b.str("b");
    try b.end();
    try b.end();

    var r = Reader.init(b.items());
    try testing.expectError(error.MalformedVector, decoder.decodeDataChunk(&r, testing.allocator));
}

// -- other structural guards ----------------------------------------------------------

test "a fixed-width payload of the wrong length is rejected" {
    // 2 INTEGER rows need 8 bytes; the message supplies 4.
    var b = B.init(testing.allocator);
    defer b.deinit();
    try b.field(100);
    try b.uvar(2);
    try b.field(101);
    try b.uvar(1);
    try writeType(&b, .integer);
    try b.field(102);
    try b.uvar(1);
    try b.field(100);
    try b.boolean(false);
    try b.field(102);
    try b.blob(&[_]u8{ 1, 0, 0, 0 });
    try b.end();
    try b.end();

    var r = Reader.init(b.items());
    try testing.expectError(error.MalformedVector, decoder.decodeDataChunk(&r, testing.allocator));
}

test "a row count beyond STANDARD_VECTOR_SIZE is rejected" {
    var b = B.init(testing.allocator);
    defer b.deinit();
    try b.field(100);
    try b.uvar(100_000); // > 2048
    try b.end();

    var r = Reader.init(b.items());
    try testing.expectError(error.RowCountTooLarge, decoder.decodeDataChunk(&r, testing.allocator));
}

test "a column count that disagrees with the type count is rejected" {
    var b = B.init(testing.allocator);
    defer b.deinit();
    try b.field(100);
    try b.uvar(1);
    try b.field(101);
    try b.uvar(1); // one type
    try writeType(&b, .integer);
    try b.field(102);
    try b.uvar(2); // but two columns
    try b.end();

    var r = Reader.init(b.items());
    try testing.expectError(error.MalformedVector, decoder.decodeDataChunk(&r, testing.allocator));
}

test "a VARCHAR list whose count differs from the row count is rejected" {
    var b = B.init(testing.allocator);
    defer b.deinit();
    try b.field(100);
    try b.uvar(3); // 3 rows
    try b.field(101);
    try b.uvar(1);
    try writeType(&b, .varchar);
    try b.field(102);
    try b.uvar(1);
    try b.field(100);
    try b.boolean(false);
    try b.field(102);
    try b.uvar(2); // only 2 strings
    try b.str("a");
    try b.str("b");
    try b.end();
    try b.end();

    var r = Reader.init(b.items());
    try testing.expectError(error.MalformedVector, decoder.decodeDataChunk(&r, testing.allocator));
}

test "an unknown field id in a chunk is rejected rather than skipped" {
    // Silently skipping unknown fields would desync the stream, because field
    // values are not self-describing.
    var b = B.init(testing.allocator);
    defer b.deinit();
    try b.field(100);
    try b.uvar(1);
    try b.field(4242); // not a DataChunk field
    try b.uvar(1);
    try b.end();

    var r = Reader.init(b.items());
    try testing.expectError(error.UnexpectedField, decoder.decodeDataChunk(&r, testing.allocator));
}

test "an FSST vector is reported rather than guessed at" {
    var b = B.init(testing.allocator);
    defer b.deinit();
    try b.field(100);
    try b.uvar(1);
    try b.field(101);
    try b.uvar(1);
    try writeType(&b, .varchar);
    try b.field(102);
    try b.uvar(1);
    try b.field(90);
    try b.uvar(@intFromEnum(quackling.VectorType.fsst));
    try b.end();
    try b.end();

    var r = Reader.init(b.items());
    try testing.expectError(error.UnsupportedVectorType, decoder.decodeDataChunk(&r, testing.allocator));
}

test "nesting deeper than the depth limit is rejected" {
    // 200 nested LIST type_infos against a limit of 16.
    var b = B.init(testing.allocator);
    defer b.deinit();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try b.field(100);
        try b.uvar(@intFromEnum(LogicalTypeId.list));
        try b.field(101);
        try b.boolean(true);
        try b.field(100);
        try b.uvar(4); // ExtraTypeInfoType.list
        try b.field(200);
    }

    var r = Reader.initWithLimits(b.items(), .{ .max_depth = 16 });
    try testing.expectError(error.LengthLimitExceeded, decoder.decodeLogicalType(&r, testing.allocator));
}

test "a sequence vector computes values without a payload" {
    var b = B.init(testing.allocator);
    defer b.deinit();
    try b.field(100);
    try b.uvar(4);
    try b.field(101);
    try b.uvar(1);
    try writeType(&b, .bigint);
    try b.field(102);
    try b.uvar(1);
    try b.field(90);
    try b.uvar(@intFromEnum(quackling.VectorType.sequence));
    try b.field(91);
    try b.ivar(100); // start
    try b.field(92);
    try b.ivar(-5); // increment
    try b.end();
    try b.end();

    var chunk = try decodeChunk(testing.allocator, b.items());
    defer chunk.deinit();
    try testing.expectEqual(@as(i64, 100), (try chunk.getValue(0, 0)).bigint);
    try testing.expectEqual(@as(i64, 95), (try chunk.getValue(0, 1)).bigint);
    try testing.expectEqual(@as(i64, 85), (try chunk.getValue(0, 3)).bigint);
}

test "a constant vector repeats a single stored value" {
    var b = B.init(testing.allocator);
    defer b.deinit();
    try b.field(100);
    try b.uvar(1000);
    try b.field(101);
    try b.uvar(1);
    try writeType(&b, .integer);
    try b.field(102);
    try b.uvar(1);
    try b.field(90);
    try b.uvar(@intFromEnum(quackling.VectorType.constant));
    // The single value follows inline.
    try b.field(100);
    try b.boolean(false);
    try b.field(102);
    try b.blob(&[_]u8{ 42, 0, 0, 0 });
    try b.end();
    try b.end();

    var chunk = try decodeChunk(testing.allocator, b.items());
    defer chunk.deinit();
    try testing.expectEqual(@as(usize, 1000), chunk.row_count);
    try testing.expectEqual(@as(i32, 42), (try chunk.getValue(0, 0)).integer);
    try testing.expectEqual(@as(i32, 42), (try chunk.getValue(0, 999)).integer);
    try testing.expectError(error.MalformedVector, chunk.getValue(0, 1000));
}
