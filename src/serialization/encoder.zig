//! Encodes DuckDB `LogicalType`, `Vector` and `DataChunk` objects onto the wire.
//!
//! The exact mirror of `decoder.zig`, used to build `APPEND_REQUEST` payloads.
//! Field ids and the default-skipping rules come from the same place
//! (`docs/PROTOCOL.md` §7), and the round-trip tests at the bottom of this file
//! assert that anything encoded here decodes back identically - which is what
//! keeps the two halves from drifting.
//!
//! Only what a client needs to *send* is implemented: flat vectors of the
//! supported scalar types, with validity. Compressed encodings (CONSTANT,
//! DICTIONARY, SEQUENCE) are decode-only - emitting them would be pointless
//! extra machinery, since a flat vector is always a legal representation.

const std = @import("std");
const writer_mod = @import("writer.zig");
const lt = @import("../types/logical_type.zig");
const vector_mod = @import("../types/vector.zig");
const validity_mod = @import("../types/validity.zig");
const value_mod = @import("../types/value.zig");

const Writer = writer_mod.Writer;
const LogicalType = lt.LogicalType;
const Value = value_mod.Value;

/// `UnsupportedType` - a type this encoder cannot emit.
/// `TypeMismatch`    - a value does not match its column, or columns are ragged.
/// `TooManyRows`     - more rows than a single chunk holds.
pub const Error = @import("../error.zig").AppendError ||
    error{UnsupportedType} || std.mem.Allocator.Error;

/// Field ids, kept beside the decoder's copies (protocol constants, §23).
const ty_id: u16 = 100;
const ty_info: u16 = 101;
const eti_type: u16 = 100;
const eti_decimal_width: u16 = 200;
const eti_decimal_scale: u16 = 201;

const vec_has_validity: u16 = 100;
const vec_validity: u16 = 101;
const vec_data: u16 = 102;

const chunk_rows: u16 = 100;
const chunk_types: u16 = 101;
const chunk_columns: u16 = 102;
const chunk_wrapper_field: u16 = 300;

/// DuckDB's STANDARD_VECTOR_SIZE; a chunk may not exceed it.
pub const max_rows: usize = 2048;

/// One column of a chunk to be sent: a declared type plus the values.
///
/// Values are borrowed - the caller owns them for the duration of the encode.
pub const Column = struct {
    type: LogicalType,
    values: []const Value,
};

// -- LogicalType ---------------------------------------------------------------

pub fn encodeLogicalType(w: *Writer, t: LogicalType) Error!void {
    try w.writePropertyUVarInt(ty_id, @intFromEnum(t.id));

    // Only DECIMAL needs extra info among the types we can send; everything
    // else is fully described by its id.
    if (t.id == .decimal) {
        const d = t.decimal orelse return Error.UnsupportedType;
        try w.writeFieldId(ty_info);
        try w.writeBool(true); // unique_ptr present
        try w.writePropertyUVarInt(eti_type, @intFromEnum(lt.ExtraTypeInfoType.decimal));
        try w.writePropertyUVarInt(eti_decimal_width, d.width);
        try w.writePropertyUVarInt(eti_decimal_scale, d.scale);
        try w.writeTerminator(); // end ExtraTypeInfo
    }
    try w.writeTerminator(); // end LogicalType
}

// -- Vector --------------------------------------------------------------------

/// Bytes a validity mask occupies for `count` rows, matching
/// `ValidityMask::ValidityMaskSize`.
fn maskSize(count: usize) usize {
    return ((count + 63) / 64) * 8;
}

/// Write a flat vector for `column`.
fn encodeVector(allocator: std.mem.Allocator, w: *Writer, column: Column) Error!void {
    const count = column.values.len;

    // Validity: only emitted when at least one row is NULL, matching what the
    // server does (and what the decoder expects).
    var any_null = false;
    for (column.values) |v| {
        if (v.isNull()) {
            any_null = true;
            break;
        }
    }
    try w.writePropertyBool(vec_has_validity, any_null);
    if (any_null) {
        const bytes = try allocator.alloc(u8, maskSize(count));
        defer allocator.free(bytes);
        // A set bit means VALID, so start all-valid and clear the NULLs.
        @memset(bytes, 0xFF);
        for (column.values, 0..) |v, i| {
            if (v.isNull()) bytes[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
        }
        try w.writeFieldId(vec_validity);
        try w.writeUVarInt(@as(u64, bytes.len));
        try w.writeRaw(bytes);
    }

    // Payload.
    if (column.type.fixedWidth()) |width| {
        const total = std.math.mul(usize, width, count) catch return Error.TooManyRows;
        const buf = try allocator.alloc(u8, total);
        defer allocator.free(buf);
        @memset(buf, 0); // NULL slots still occupy their width
        for (column.values, 0..) |v, i| {
            if (v.isNull()) continue;
            try writeFixed(buf[i * width ..][0..width], column.type, v);
        }
        try w.writeFieldId(vec_data);
        try w.writeUVarInt(@as(u64, buf.len));
        try w.writeRaw(buf);
    } else switch (column.type.id) {
        .varchar, .string_literal, .char, .blob, .bit, .bignum => {
            try w.writeFieldId(vec_data);
            try w.writeUVarInt(@as(u64, count));
            for (column.values) |v| {
                // A NULL still needs a (zero-length) entry to keep the list
                // aligned with the row count.
                const s = if (v.isNull()) "" else (v.asSlice() orelse return Error.TypeMismatch);
                try w.writeString(s);
            }
        },
        else => return Error.UnsupportedType,
    }
    try w.writeTerminator(); // end Vector
}

/// Store one fixed-width value little-endian, as `VectorOperations::WriteToStorage`
/// would. Never a raw struct copy - the layout is explicit.
fn writeFixed(dst: []u8, t: LogicalType, v: Value) Error!void {
    switch (t.id) {
        .boolean => dst[0] = switch (v) {
            .boolean => |b| @intFromBool(b),
            else => return Error.TypeMismatch,
        },
        .tinyint => try putInt(i8, dst, v),
        .smallint => try putInt(i16, dst, v),
        .integer => try putInt(i32, dst, v),
        .bigint => try putInt(i64, dst, v),
        .hugeint => std.mem.writeInt(i128, dst[0..16], switch (v) {
            .hugeint => |x| x,
            .integer => |x| x,
            .bigint => |x| x,
            else => return Error.TypeMismatch,
        }, .little),
        .utinyint => try putInt(u8, dst, v),
        .usmallint => try putInt(u16, dst, v),
        .uinteger => try putInt(u32, dst, v),
        .ubigint => try putInt(u64, dst, v),
        .uhugeint => std.mem.writeInt(u128, dst[0..16], switch (v) {
            .uhugeint => |x| x,
            .ubigint => |x| x,
            else => return Error.TypeMismatch,
        }, .little),
        // Integers widen into float columns: a JS caller cannot express the
        // difference between `0` and `0.0`, so refusing an exact integer here
        // would make FLOAT/DOUBLE columns unusable from the browser.
        .float => std.mem.writeInt(u32, dst[0..4], @bitCast(try asFloat(f32, v)), .little),
        .double => std.mem.writeInt(u64, dst[0..8], @bitCast(try asFloat(f64, v)), .little),
        .date => std.mem.writeInt(i32, dst[0..4], switch (v) {
            .date => |x| x,
            .integer => |x| x,
            else => return Error.TypeMismatch,
        }, .little),
        .time, .time_tz => std.mem.writeInt(i64, dst[0..8], switch (v) {
            .time => |x| x,
            .bigint => |x| x,
            else => return Error.TypeMismatch,
        }, .little),
        .timestamp, .timestamp_sec, .timestamp_ms, .timestamp_ns, .timestamp_tz => {
            std.mem.writeInt(i64, dst[0..8], switch (v) {
                .timestamp => |x| x,
                .bigint => |x| x,
                else => return Error.TypeMismatch,
            }, .little);
        },
        .uuid => std.mem.writeInt(u128, dst[0..16], switch (v) {
            .uuid => |x| x,
            else => return Error.TypeMismatch,
        }, .little),
        .interval => {
            const iv = switch (v) {
                .interval => |x| x,
                else => return Error.TypeMismatch,
            };
            std.mem.writeInt(i32, dst[0..4], iv.months, .little);
            std.mem.writeInt(i32, dst[4..8], iv.days, .little);
            std.mem.writeInt(i64, dst[8..16], iv.micros, .little);
        },
        .decimal => {
            const raw: i128 = switch (v) {
                .decimal => |d| d.value,
                .integer => |x| x,
                .bigint => |x| x,
                .hugeint => |x| x,
                else => return Error.TypeMismatch,
            };
            switch (dst.len) {
                2 => std.mem.writeInt(i16, dst[0..2], std.math.cast(i16, raw) orelse
                    return Error.TypeMismatch, .little),
                4 => std.mem.writeInt(i32, dst[0..4], std.math.cast(i32, raw) orelse
                    return Error.TypeMismatch, .little),
                8 => std.mem.writeInt(i64, dst[0..8], std.math.cast(i64, raw) orelse
                    return Error.TypeMismatch, .little),
                16 => std.mem.writeInt(i128, dst[0..16], raw, .little),
                else => return Error.UnsupportedType,
            }
        },
        else => return Error.UnsupportedType,
    }
}

/// Coerce a numeric `Value` into a float type.
///
/// Integers are accepted only when they are exactly representable, so a value
/// that would silently lose precision is refused rather than rounded.
fn asFloat(comptime T: type, v: Value) Error!T {
    switch (v) {
        .float => |x| return @floatCast(x),
        .double => |x| return @floatCast(x),
        else => {},
    }
    const n = v.asI64() orelse switch (v) {
        .hugeint => |x| return exactFromInt(T, x),
        .uhugeint => |x| return exactFromInt(T, x),
        else => return Error.TypeMismatch,
    };
    return exactFromInt(T, n);
}

fn exactFromInt(comptime T: type, n: anytype) Error!T {
    const f: T = @floatFromInt(n);
    // Round-trip check: reject anything the float cannot hold exactly.
    if (@as(@TypeOf(n), @intFromFloat(f)) != n) return Error.TypeMismatch;
    return f;
}

/// Coerce an integer-ish `Value` into `T`, refusing anything that would not
/// round-trip rather than truncating.
fn putInt(comptime T: type, dst: []u8, v: Value) Error!void {
    const n: i128 = switch (v) {
        .boolean => |b| @intFromBool(b),
        .tinyint => |x| x,
        .smallint => |x| x,
        .integer => |x| x,
        .bigint => |x| x,
        .hugeint => |x| x,
        .utinyint => |x| x,
        .usmallint => |x| x,
        .uinteger => |x| x,
        .ubigint => |x| x,
        .uhugeint => |x| std.math.cast(i128, x) orelse return Error.TypeMismatch,
        .date => |x| x,
        .time, .timestamp => |x| x,
        else => return Error.TypeMismatch,
    };
    const narrowed = std.math.cast(T, n) orelse return Error.TypeMismatch;
    std.mem.writeInt(T, dst[0..@sizeOf(T)], narrowed, .little);
}

// -- DataChunk -----------------------------------------------------------------

/// Write a `DataChunk` object: rows, types, then one vector per column.
pub fn encodeDataChunk(
    allocator: std.mem.Allocator,
    w: *Writer,
    columns: []const Column,
) Error!void {
    if (columns.len == 0) return Error.TypeMismatch;
    const rows = columns[0].values.len;
    if (rows > max_rows) return Error.TooManyRows;
    for (columns) |c| {
        if (c.values.len != rows) return Error.TypeMismatch; // ragged input
    }

    // `rows` is default-skipped when zero, like every other WithDefault field.
    try w.writePropertyUVarIntWithDefault(chunk_rows, @as(u32, @intCast(rows)));

    try w.writeFieldId(chunk_types);
    try w.writeUVarInt(@as(u64, columns.len));
    for (columns) |c| try encodeLogicalType(w, c.type);

    try w.writeFieldId(chunk_columns);
    try w.writeUVarInt(@as(u64, columns.len));
    for (columns) |c| try encodeVector(allocator, w, c);

    try w.writeTerminator(); // end DataChunk
}

/// Write a `DataChunkWrapper`: `{300: DataChunk}`.
pub fn encodeChunkWrapper(
    allocator: std.mem.Allocator,
    w: *Writer,
    columns: []const Column,
) Error!void {
    try w.writeFieldId(chunk_wrapper_field);
    try encodeDataChunk(allocator, w, columns);
    try w.writeTerminator(); // end wrapper
}

const testing = std.testing;
const Reader = @import("reader.zig").Reader;
const decoder = @import("decoder.zig");

/// Encode then decode, and hand back the chunk for assertions. This is the
/// property that matters: the encoder must produce exactly what the decoder
/// (verified byte-for-byte against a real server) accepts.
///
/// The encoded bytes are returned alongside the chunk because a decoded chunk
/// *borrows* them (that is the whole point of the zero-copy decode). Freeing the
/// buffer while the chunk is alive is a use-after-free.
const RoundTrip = struct {
    bytes: std.ArrayList(u8),
    chunk: @import("../types/data_chunk.zig").DataChunk,

    fn deinit(self: *RoundTrip) void {
        self.chunk.deinit();
        self.bytes.deinit(testing.allocator);
    }
};

fn roundTrip(columns: []const Column) !RoundTrip {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    try encodeDataChunk(testing.allocator, &w, columns);

    var r = Reader.init(buf.items);
    const chunk = try decoder.decodeDataChunk(&r, testing.allocator);
    return .{ .bytes = buf, .chunk = chunk };
}

test "integers round-trip through encode and decode" {
    const vals = [_]Value{ .{ .integer = -1 }, .{ .integer = 0 }, .{ .integer = 2147483647 } };
    var rt = try roundTrip(&.{.{ .type = .{ .id = .integer }, .values = &vals }});
    defer rt.deinit();
    const chunk = rt.chunk;

    try testing.expectEqual(@as(usize, 3), chunk.row_count);
    try testing.expectEqual(@as(i32, -1), (try chunk.getValue(0, 0)).integer);
    try testing.expectEqual(@as(i32, 0), (try chunk.getValue(0, 1)).integer);
    try testing.expectEqual(@as(i32, 2147483647), (try chunk.getValue(0, 2)).integer);
}

test "NULLs round-trip via the validity mask" {
    const vals = [_]Value{ .{ .integer = 10 }, .null, .{ .integer = 30 } };
    var rt = try roundTrip(&.{.{ .type = .{ .id = .integer }, .values = &vals }});
    defer rt.deinit();
    const chunk = rt.chunk;

    try testing.expect(!chunk.isNull(0, 0));
    try testing.expect(chunk.isNull(0, 1));
    try testing.expect(!chunk.isNull(0, 2));
    try testing.expectEqual(@as(i32, 30), (try chunk.getValue(0, 2)).integer);
}

test "an all-valid column omits the validity mask" {
    const vals = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    try encodeDataChunk(testing.allocator, &w, &.{.{ .type = .{ .id = .integer }, .values = &vals }});
    // Field 101 (validity) must not appear when nothing is NULL.
    var r = Reader.init(buf.items);
    var chunk = try decoder.decodeDataChunk(&r, testing.allocator);
    defer chunk.deinit();
    try testing.expect(chunk.column(0).?.validity.allValid());
}

test "strings round-trip including empty and multi-byte" {
    const vals = [_]Value{
        .{ .varchar = "hello" },
        .{ .varchar = "" },
        .{ .varchar = "wörld🦆" },
        .null,
    };
    var rt = try roundTrip(&.{.{ .type = .{ .id = .varchar }, .values = &vals }});
    defer rt.deinit();
    const chunk = rt.chunk;

    try testing.expectEqualStrings("hello", (try chunk.getValue(0, 0)).varchar);
    try testing.expectEqualStrings("", (try chunk.getValue(0, 1)).varchar);
    try testing.expectEqualStrings("wörld🦆", (try chunk.getValue(0, 2)).varchar);
    try testing.expect(chunk.isNull(0, 3));
}

test "every fixed-width scalar type round-trips" {
    const b = [_]Value{.{ .boolean = true }};
    const i8v = [_]Value{.{ .tinyint = -128 }};
    const i16v = [_]Value{.{ .smallint = -32768 }};
    const i64v = [_]Value{.{ .bigint = std.math.minInt(i64) }};
    const u64v = [_]Value{.{ .ubigint = std.math.maxInt(u64) }};
    const h = [_]Value{.{ .hugeint = std.math.maxInt(i128) }};
    const f = [_]Value{.{ .float = 1.5 }};
    const d = [_]Value{.{ .double = -2.25 }};
    const dt = [_]Value{.{ .date = 19797 }};
    const ts = [_]Value{.{ .timestamp = 1710506096000000 }};

    var rt = try roundTrip(&.{
        .{ .type = .{ .id = .boolean }, .values = &b },
        .{ .type = .{ .id = .tinyint }, .values = &i8v },
        .{ .type = .{ .id = .smallint }, .values = &i16v },
        .{ .type = .{ .id = .bigint }, .values = &i64v },
        .{ .type = .{ .id = .ubigint }, .values = &u64v },
        .{ .type = .{ .id = .hugeint }, .values = &h },
        .{ .type = .{ .id = .float }, .values = &f },
        .{ .type = .{ .id = .double }, .values = &d },
        .{ .type = .{ .id = .date }, .values = &dt },
        .{ .type = .{ .id = .timestamp }, .values = &ts },
    });
    defer rt.deinit();
    const chunk = rt.chunk;

    try testing.expectEqual(true, (try chunk.getValue(0, 0)).boolean);
    try testing.expectEqual(@as(i8, -128), (try chunk.getValue(1, 0)).tinyint);
    try testing.expectEqual(@as(i16, -32768), (try chunk.getValue(2, 0)).smallint);
    try testing.expectEqual(std.math.minInt(i64), (try chunk.getValue(3, 0)).bigint);
    try testing.expectEqual(std.math.maxInt(u64), (try chunk.getValue(4, 0)).ubigint);
    try testing.expectEqual(std.math.maxInt(i128), (try chunk.getValue(5, 0)).hugeint);
    try testing.expectEqual(@as(f32, 1.5), (try chunk.getValue(6, 0)).float);
    try testing.expectEqual(@as(f64, -2.25), (try chunk.getValue(7, 0)).double);
    try testing.expectEqual(@as(i32, 19797), (try chunk.getValue(8, 0)).date);
    try testing.expectEqual(@as(i64, 1710506096000000), (try chunk.getValue(9, 0)).timestamp);
}

test "DECIMAL round-trips with its width and scale" {
    const vals = [_]Value{.{ .decimal = .{ .value = 1234, .width = 10, .scale = 2 } }};
    var rt = try roundTrip(&.{.{
        .type = .{ .id = .decimal, .decimal = .{ .width = 10, .scale = 2 } },
        .values = &vals,
    }});
    defer rt.deinit();
    const chunk = rt.chunk;
    const d = (try chunk.getValue(0, 0)).decimal;
    try testing.expectEqual(@as(i128, 1234), d.value);
    try testing.expectEqual(@as(u8, 2), d.scale);
}

test "BLOB round-trips arbitrary bytes" {
    const raw = [_]u8{ 0x00, 0x01, 0xFF, 0x7F };
    const vals = [_]Value{.{ .blob = &raw }};
    var rt = try roundTrip(&.{.{ .type = .{ .id = .blob }, .values = &vals }});
    defer rt.deinit();
    const chunk = rt.chunk;
    try testing.expectEqualSlices(u8, &raw, (try chunk.getValue(0, 0)).blob);
}

test "a value that does not fit its column is refused, not truncated" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    // 300 does not fit a TINYINT.
    const vals = [_]Value{.{ .integer = 300 }};
    try testing.expectError(Error.TypeMismatch, encodeDataChunk(
        testing.allocator,
        &w,
        &.{.{ .type = .{ .id = .tinyint }, .values = &vals }},
    ));
}

test "a string value in a numeric column is refused" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    const vals = [_]Value{.{ .varchar = "nope" }};
    try testing.expectError(Error.TypeMismatch, encodeDataChunk(
        testing.allocator,
        &w,
        &.{.{ .type = .{ .id = .integer }, .values = &vals }},
    ));
}

test "ragged columns are refused" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    const two = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const one = [_]Value{.{ .integer = 3 }};
    try testing.expectError(Error.TypeMismatch, encodeDataChunk(testing.allocator, &w, &.{
        .{ .type = .{ .id = .integer }, .values = &two },
        .{ .type = .{ .id = .integer }, .values = &one },
    }));
}

test "more rows than a chunk holds is refused" {
    const vals = try testing.allocator.alloc(Value, max_rows + 1);
    defer testing.allocator.free(vals);
    @memset(vals, Value{ .integer = 1 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    try testing.expectError(Error.TooManyRows, encodeDataChunk(
        testing.allocator,
        &w,
        &.{.{ .type = .{ .id = .integer }, .values = vals }},
    ));
}

test "a full 2048-row chunk round-trips" {
    const vals = try testing.allocator.alloc(Value, max_rows);
    defer testing.allocator.free(vals);
    for (vals, 0..) |*v, i| v.* = .{ .integer = @intCast(i) };

    var rt = try roundTrip(&.{.{ .type = .{ .id = .integer }, .values = vals }});
    defer rt.deinit();
    const chunk = rt.chunk;
    try testing.expectEqual(max_rows, chunk.row_count);
    try testing.expectEqual(@as(i32, 0), (try chunk.getValue(0, 0)).integer);
    try testing.expectEqual(@as(i32, max_rows - 1), (try chunk.getValue(0, max_rows - 1)).integer);
}

test "the wrapper wraps the chunk in field 300" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    const vals = [_]Value{.{ .integer = 42 }};
    try encodeChunkWrapper(testing.allocator, &w, &.{.{ .type = .{ .id = .integer }, .values = &vals }});

    var r = Reader.init(buf.items);
    var chunk = try decoder.decodeChunkWrapper(&r, testing.allocator);
    defer chunk.deinit();
    try testing.expectEqual(@as(i32, 42), (try chunk.getValue(0, 0)).integer);
}
