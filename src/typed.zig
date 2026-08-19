//! comptime struct mapping.
//!
//! Built strictly on top of the DataChunk API (todo.md §9) - the protocol core
//! has no idea this file exists. Field names are matched to column names at
//! runtime once per result; the per-field conversion is resolved at comptime.
//!
//! ```zig
//! const User = struct { id: i64, name: []const u8, score: f64 };
//! var it = try quackling.typed.iterator(User, &result);
//! while (try it.next()) |user| { ... }
//! ```
//!
//! Slice fields (`[]const u8`) borrow the chunk buffer and are only valid until
//! the next chunk is pulled. Optional fields (`?T`) accept NULL; a NULL landing
//! in a non-optional field is an error rather than a silent zero.

const std = @import("std");
const result_mod = @import("result.zig");
const data_chunk_mod = @import("types/data_chunk.zig");
const value_mod = @import("types/value.zig");

const Result = result_mod.Result;
const Row = data_chunk_mod.Row;
const Value = value_mod.Value;

pub const Error = error{
    /// The result has no column matching a struct field.
    MissingColumn,
    /// The column's type cannot be converted to the field's type.
    TypeMismatch,
    /// A NULL arrived for a non-optional field.
    UnexpectedNull,
} || result_mod.Error;

/// Maps struct fields to column indices once, then reuses the mapping.
pub fn Mapping(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("typed mapping requires a struct, got " ++ @typeName(T));
    const fields = info.@"struct".fields;

    return struct {
        const Self = @This();
        columns: [fields.len]usize,

        /// Resolve each field name to a column index.
        pub fn init(result: *const Result) Error!Self {
            var cols: [fields.len]usize = undefined;
            inline for (fields, 0..) |f, i| {
                cols[i] = result.columnIndex(f.name) orelse return Error.MissingColumn;
            }
            return .{ .columns = cols };
        }

        /// Build one `T` from a row.
        pub fn read(self: Self, row: Row) Error!T {
            var out: T = undefined;
            inline for (fields, 0..) |f, i| {
                const v = try row.get(self.columns[i]);
                @field(out, f.name) = try convert(f.type, v);
            }
            return out;
        }
    };
}

/// Convert a decoded `Value` into the requested Zig type.
///
/// Widening between integer types is allowed when the value actually fits;
/// anything lossy is an error rather than a silent truncation.
pub fn convert(comptime T: type, v: Value) Error!T {
    const info = @typeInfo(T);

    // Optionals absorb NULL; everything else rejects it.
    if (info == .optional) {
        if (v.isNull()) return null;
        return try convert(info.optional.child, v);
    }
    if (v.isNull()) return Error.UnexpectedNull;

    return switch (info) {
        .bool => switch (v) {
            .boolean => |b| b,
            else => Error.TypeMismatch,
        },
        .int => blk: {
            const n = v.asI64() orelse switch (v) {
                // u64/i128 values outside i64 still convert when T is wide.
                .ubigint => |x| break :blk std.math.cast(T, x) orelse Error.TypeMismatch,
                .hugeint => |x| break :blk std.math.cast(T, x) orelse Error.TypeMismatch,
                .uhugeint => |x| break :blk std.math.cast(T, x) orelse Error.TypeMismatch,
                else => break :blk Error.TypeMismatch,
            };
            break :blk std.math.cast(T, n) orelse Error.TypeMismatch;
        },
        .float => blk: {
            const f = v.asF64() orelse break :blk Error.TypeMismatch;
            break :blk @floatCast(f);
        },
        .pointer => |p| blk: {
            // Only []const u8 is supported; it borrows the chunk buffer.
            if (p.size != .slice or p.child != u8 or !p.is_const) {
                @compileError("typed mapping supports []const u8 slices only, got " ++ @typeName(T));
            }
            break :blk v.asSlice() orelse Error.TypeMismatch;
        },
        .@"enum" => blk: {
            const n = v.asI64() orelse break :blk Error.TypeMismatch;
            break :blk std.meta.intToEnum(T, n) catch Error.TypeMismatch;
        },
        else => @compileError("typed mapping cannot produce " ++ @typeName(T)),
    };
}

/// Iterate a result as `T` values.
pub fn Iterator(comptime T: type) type {
    return struct {
        const Self = @This();
        stream: result_mod.RowStream,
        mapping: Mapping(T),

        pub fn next(self: *Self) Error!?T {
            const row = try self.stream.next() orelse return null;
            return try self.mapping.read(row);
        }
    };
}

/// Build a typed iterator over `result`.
pub fn iterator(comptime T: type, result: *Result) Error!Iterator(T) {
    return .{
        .stream = result.rows(),
        .mapping = try Mapping(T).init(result),
    };
}

/// Collect an entire result into a slice of `T`. Caller owns the slice.
///
/// Note this defeats streaming, so it is for small results only; the docstring
/// says so because the type system cannot.
pub fn collect(
    comptime T: type,
    allocator: std.mem.Allocator,
    result: *Result,
) Error![]T {
    var out: std.ArrayList(T) = .empty;
    errdefer out.deinit(allocator);
    var it = try iterator(T, result);
    while (try it.next()) |item| {
        try out.append(allocator, item);
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "convert widens integers only when the value fits" {
    try testing.expectEqual(@as(i64, 42), try convert(i64, .{ .integer = 42 }));
    try testing.expectEqual(@as(i32, 42), try convert(i32, .{ .bigint = 42 }));
    try testing.expectError(Error.TypeMismatch, convert(i8, Value{ .integer = 1000 }));
}

test "convert rejects null for non-optional fields" {
    try testing.expectError(Error.UnexpectedNull, convert(i64, .null));
    try testing.expectEqual(@as(?i64, null), try convert(?i64, .null));
    try testing.expectEqual(@as(?i64, 5), try convert(?i64, .{ .integer = 5 }));
}

test "convert handles floats, bools and strings" {
    try testing.expectEqual(@as(f64, 1.5), try convert(f64, .{ .double = 1.5 }));
    try testing.expectEqual(@as(f32, 2.5), try convert(f32, .{ .float = 2.5 }));
    try testing.expectEqual(true, try convert(bool, .{ .boolean = true }));
    try testing.expectEqualStrings("hi", try convert([]const u8, .{ .varchar = "hi" }));
}

test "convert reports a mismatch instead of coercing nonsense" {
    try testing.expectError(Error.TypeMismatch, convert(bool, Value{ .varchar = "true" }));
    try testing.expectError(Error.TypeMismatch, convert([]const u8, Value{ .integer = 1 }));
}

test "integers wider than i64 round-trip through hugeint" {
    try testing.expectEqual(
        @as(u64, std.math.maxInt(u64)),
        try convert(u64, .{ .ubigint = std.math.maxInt(u64) }),
    );
    try testing.expectEqual(@as(i128, 1 << 100), try convert(i128, .{ .hugeint = 1 << 100 }));
}
