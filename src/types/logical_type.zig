//! DuckDB logical types.
//!
//! `LogicalTypeId` values are the on-wire enum from
//! `duckdb/common/types.hpp`. They are protocol constants and live here rather
//! than being sprinkled through the decoder (todo.md §23).

const std = @import("std");
const reader = @import("../serialization/reader.zig");

pub const Error = error{
    UnsupportedType,
    UnknownTypeId,
} || reader.Error || std.mem.Allocator.Error;

/// Wire values for `LogicalTypeId` (DuckDB v1.4.x / v1.5.x).
pub const LogicalTypeId = enum(u8) {
    invalid = 0,
    sqlnull = 1,
    unknown = 2,
    any = 3,
    user = 4,
    template = 5,

    boolean = 10,
    tinyint = 11,
    smallint = 12,
    integer = 13,
    bigint = 14,
    date = 15,
    time = 16,
    timestamp_sec = 17,
    timestamp_ms = 18,
    timestamp = 19, // microseconds
    timestamp_ns = 20,
    decimal = 21,
    float = 22,
    double = 23,
    char = 24,
    varchar = 25,
    blob = 26,
    interval = 27,
    utinyint = 28,
    usmallint = 29,
    uinteger = 30,
    ubigint = 31,
    timestamp_tz = 32,
    time_tz = 34,
    time_ns = 35,
    bit = 36,
    string_literal = 37,
    integer_literal = 38,
    bignum = 39,
    uhugeint = 49,
    hugeint = 50,
    pointer = 51,
    validity = 53,
    uuid = 54,

    @"struct" = 100,
    list = 101,
    map = 102,
    table = 103,
    @"enum" = 104,
    aggregate_state = 105,
    lambda = 106,
    @"union" = 107,
    array = 108,
    variant = 109,
    _,

    pub fn name(self: LogicalTypeId) []const u8 {
        return switch (self) {
            .boolean => "BOOLEAN",
            .tinyint => "TINYINT",
            .smallint => "SMALLINT",
            .integer => "INTEGER",
            .bigint => "BIGINT",
            .hugeint => "HUGEINT",
            .utinyint => "UTINYINT",
            .usmallint => "USMALLINT",
            .uinteger => "UINTEGER",
            .ubigint => "UBIGINT",
            .uhugeint => "UHUGEINT",
            .float => "FLOAT",
            .double => "DOUBLE",
            .varchar, .string_literal => "VARCHAR",
            .blob => "BLOB",
            .date => "DATE",
            .time => "TIME",
            .timestamp => "TIMESTAMP",
            .timestamp_sec => "TIMESTAMP_S",
            .timestamp_ms => "TIMESTAMP_MS",
            .timestamp_ns => "TIMESTAMP_NS",
            .timestamp_tz => "TIMESTAMP WITH TIME ZONE",
            .time_tz => "TIME WITH TIME ZONE",
            .interval => "INTERVAL",
            .decimal => "DECIMAL",
            .uuid => "UUID",
            .sqlnull => "NULL",
            .@"struct" => "STRUCT",
            .list => "LIST",
            .map => "MAP",
            .@"enum" => "ENUM",
            .@"union" => "UNION",
            .array => "ARRAY",
            .variant => "VARIANT",
            .bit => "BIT",
            .bignum => "BIGNUM",
            else => "UNKNOWN",
        };
    }

    /// The physical storage width in bytes for fixed-width types, mirroring
    /// `GetTypeIdSize(PhysicalType)`. `null` means variable width (or a type we
    /// do not decode), which the vector decoder handles separately.
    ///
    /// This is the single source of truth for how many bytes a flat vector
    /// payload occupies, so a wrong value here surfaces as a decode error
    /// rather than as silently misread data.
    pub fn fixedWidth(self: LogicalTypeId) ?usize {
        return switch (self) {
            .boolean, .tinyint, .utinyint => 1,
            .smallint, .usmallint => 2,
            .integer, .uinteger, .float, .date, .time_tz => 4,
            .bigint, .ubigint, .double, .timestamp, .timestamp_sec, .timestamp_ms, .timestamp_ns, .timestamp_tz, .time => 8,
            .hugeint, .uhugeint, .uuid => 16,
            .interval => 16,
            // DECIMAL width depends on precision; resolved via DecimalInfo.
            else => null,
        };
    }
};

/// Extra type info carried alongside the id (`ExtraTypeInfoType` in DuckDB).
pub const ExtraTypeInfoType = enum(u8) {
    invalid = 0,
    generic = 1,
    decimal = 2,
    string = 3,
    list = 4,
    @"struct" = 5,
    enum_ = 6,
    user = 7,
    aggregate_state = 8,
    array = 9,
    any = 10,
    integer_literal = 11,
    template = 12,
    _,
};

/// A decoded logical type.
///
/// Only the information the client needs to interpret values is retained. For
/// nested types the children are owned by this struct and freed by `deinit`.
pub const LogicalType = struct {
    id: LogicalTypeId,
    /// Set for DECIMAL.
    decimal: ?Decimal = null,
    /// Type alias, if the server sent one. Borrowed from the response buffer.
    alias: ?[]const u8 = null,
    /// Children for STRUCT/LIST/MAP/ARRAY/UNION. Owned.
    ///
    /// MAP is physically `LIST(STRUCT(key, value))`, so `children[0]` is that
    /// struct. UNION is physically a STRUCT whose first child is a hidden
    /// `UTINYINT` tag; `unionMembers()` skips it.
    children: []Child = &.{},
    /// Fixed length for ARRAY.
    array_size: ?u64 = null,
    /// ENUM dictionary, in declaration order. The label bytes are borrowed
    /// from the response buffer; the slice array itself is owned.
    enum_values: []const []const u8 = &.{},
    /// `values_count` as declared by the server, recorded during decode so it
    /// can be cross-checked against the label list that follows.
    enum_count_hint: ?u64 = null,

    pub const Decimal = struct { width: u8, scale: u8 };

    pub const Child = struct {
        name: []const u8,
        type: LogicalType,
    };

    pub fn deinit(self: *LogicalType, allocator: std.mem.Allocator) void {
        for (self.children) |*c| c.type.deinit(allocator);
        if (self.children.len > 0) allocator.free(self.children);
        self.children = &.{};
        if (self.enum_values.len > 0) allocator.free(self.enum_values);
        self.enum_values = &.{};
    }

    pub fn name(self: LogicalType) []const u8 {
        return self.alias orelse self.id.name();
    }

    /// Physical width for this specific type, accounting for DECIMAL precision
    /// and ENUM dictionary size.
    pub fn fixedWidth(self: LogicalType) ?usize {
        switch (self.id) {
            .decimal => {
                const d = self.decimal orelse return null;
                // DECIMAL is stored in the narrowest integer that fits its width.
                return if (d.width <= 4) 2 else if (d.width <= 9) 4 else if (d.width <= 18) 8 else 16;
            },
            // An ENUM value is an index into the dictionary, stored in the
            // narrowest unsigned integer that can address it
            // (`EnumTypeInfo::DictType`).
            .@"enum" => return enumDictWidth(self.enum_values.len),
            else => return self.id.fixedWidth(),
        }
    }

    /// The members of a UNION, excluding the hidden tag child that DuckDB
    /// prepends. Returns an empty slice for non-unions.
    pub fn unionMembers(self: LogicalType) []Child {
        if (self.id != .@"union" or self.children.len == 0) return &.{};
        return self.children[1..];
    }

    /// For a MAP, the `STRUCT(key, value)` element type of its backing list.
    pub fn mapEntryType(self: LogicalType) ?LogicalType {
        if (self.id != .map or self.children.len == 0) return null;
        return self.children[0].type;
    }

    /// For a MAP, the key and value types.
    pub fn mapKeyValue(self: LogicalType) ?struct { key: LogicalType, value: LogicalType } {
        const entry = self.mapEntryType() orelse return null;
        if (entry.children.len < 2) return null;
        return .{ .key = entry.children[0].type, .value = entry.children[1].type };
    }

    /// The physical layout the vector decoder must use for this type.
    ///
    /// This is where MAP and UNION stop being special: MAP is laid out exactly
    /// like a LIST, and UNION exactly like a STRUCT, so they reuse those paths
    /// rather than needing their own.
    pub fn physicalShape(self: LogicalType) PhysicalShape {
        if (self.fixedWidth() != null) return .fixed;
        return switch (self.id) {
            // BIGNUM is stored as a length-prefixed byte run, like a string.
            .varchar, .string_literal, .char, .blob, .bit, .bignum => .variable,
            // VARIANT is physically a STRUCT of keys/children/values.
            .@"struct", .@"union", .variant => .@"struct",
            .list, .map => .list,
            .array => .array,
            else => .unsupported,
        };
    }
};

/// How a logical type is physically laid out in a vector. Several logical
/// types share a physical representation - this is DuckDB's
/// `LogicalType::InternalType()`, reduced to the cases the decoder branches on.
pub const PhysicalShape = enum {
    /// Packed fixed-width values.
    fixed,
    /// A list of length-prefixed byte runs.
    variable,
    /// Child vectors, one per field (STRUCT, and UNION via its tag+members).
    @"struct",
    /// offset/length entries plus a flattened child (LIST, and MAP).
    list,
    /// Fixed-size runs of a child vector.
    array,
    /// Known type we cannot lay out.
    unsupported,
};

/// `EnumTypeInfo::DictType`: the physical width used to index a dictionary of
/// `count` entries. A count of zero has no valid width.
pub fn enumDictWidth(count: usize) ?usize {
    if (count == 0) return null;
    if (count <= std.math.maxInt(u8)) return 1;
    if (count <= std.math.maxInt(u16)) return 2;
    if (count <= std.math.maxInt(u32)) return 4;
    return null;
}

const testing = std.testing;

test "wire enum values match DuckDB types.hpp" {
    try testing.expectEqual(@as(u8, 13), @intFromEnum(LogicalTypeId.integer));
    try testing.expectEqual(@as(u8, 14), @intFromEnum(LogicalTypeId.bigint));
    try testing.expectEqual(@as(u8, 25), @intFromEnum(LogicalTypeId.varchar));
    try testing.expectEqual(@as(u8, 10), @intFromEnum(LogicalTypeId.boolean));
    try testing.expectEqual(@as(u8, 50), @intFromEnum(LogicalTypeId.hugeint));
    try testing.expectEqual(@as(u8, 100), @intFromEnum(LogicalTypeId.@"struct"));
}

test "fixed widths match physical storage sizes" {
    try testing.expectEqual(@as(?usize, 1), LogicalTypeId.boolean.fixedWidth());
    try testing.expectEqual(@as(?usize, 4), LogicalTypeId.integer.fixedWidth());
    try testing.expectEqual(@as(?usize, 8), LogicalTypeId.bigint.fixedWidth());
    try testing.expectEqual(@as(?usize, 16), LogicalTypeId.hugeint.fixedWidth());
    try testing.expectEqual(@as(?usize, null), LogicalTypeId.varchar.fixedWidth());
}

test "decimal width follows precision" {
    const t2 = LogicalType{ .id = .decimal, .decimal = .{ .width = 4, .scale = 2 } };
    try testing.expectEqual(@as(?usize, 2), t2.fixedWidth());
    const t16 = LogicalType{ .id = .decimal, .decimal = .{ .width = 30, .scale = 2 } };
    try testing.expectEqual(@as(?usize, 16), t16.fixedWidth());
}

test "unknown type ids do not crash the enum" {
    const t: LogicalTypeId = @enumFromInt(200);
    try testing.expectEqualStrings("UNKNOWN", t.name());
}
