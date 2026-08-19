//! A single decoded DuckDB value.
//!
//! `Value` is a convenience layer over `Vector`. The vectorized path never
//! materialises one: it hands out typed slices instead. Use `Value` when
//! ergonomics matter more than throughput (todo.md §7).
//!
//! Slice payloads (`varchar`, `blob`) **borrow** the chunk's buffer; they stay
//! valid exactly as long as the `DataChunk` they came from.

const std = @import("std");
const lt = @import("logical_type.zig");

pub const Interval = struct {
    months: i32,
    days: i32,
    micros: i64,
};

pub const Value = union(enum) {
    null,
    boolean: bool,
    tinyint: i8,
    smallint: i16,
    integer: i32,
    bigint: i64,
    hugeint: i128,
    utinyint: u8,
    usmallint: u16,
    uinteger: u32,
    ubigint: u64,
    uhugeint: u128,
    float: f32,
    double: f64,
    /// Borrowed from the owning chunk.
    varchar: []const u8,
    /// Borrowed from the owning chunk.
    blob: []const u8,
    /// Days since 1970-01-01.
    date: i32,
    /// Microseconds since midnight.
    time: i64,
    /// Microseconds since 1970-01-01 (or the unit named by the source type).
    timestamp: i64,
    interval: Interval,
    uuid: u128,
    decimal: Decimal,
    /// An ENUM cell: the dictionary index plus its label. The label borrows the
    /// owning chunk.
    @"enum": Enum,

    pub const Enum = struct {
        index: u32,
        label: []const u8,
    };

    pub const Decimal = struct {
        /// Unscaled value; the real number is `value / 10^scale`.
        value: i128,
        width: u8,
        scale: u8,

        pub fn toFloat(self: Decimal) f64 {
            var div: f64 = 1.0;
            var i: u8 = 0;
            while (i < self.scale) : (i += 1) div *= 10.0;
            return @as(f64, @floatFromInt(self.value)) / div;
        }
    };

    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    /// Best-effort numeric coercion, for callers that just want a number.
    /// Returns null for non-numeric values (including NULL).
    pub fn asI64(self: Value) ?i64 {
        return switch (self) {
            .boolean => |v| @intFromBool(v),
            .tinyint => |v| v,
            .smallint => |v| v,
            .integer => |v| v,
            .bigint => |v| v,
            .utinyint => |v| v,
            .usmallint => |v| v,
            .uinteger => |v| v,
            .ubigint => |v| std.math.cast(i64, v),
            .hugeint => |v| std.math.cast(i64, v),
            .uhugeint => |v| std.math.cast(i64, v),
            .date => |v| v,
            .time, .timestamp => |v| v,
            else => null,
        };
    }

    pub fn asF64(self: Value) ?f64 {
        return switch (self) {
            .float => |v| v,
            .double => |v| v,
            .decimal => |d| d.toFloat(),
            else => if (self.asI64()) |i| @floatFromInt(i) else null,
        };
    }

    pub fn asSlice(self: Value) ?[]const u8 {
        return switch (self) {
            .varchar, .blob => |v| v,
            // An ENUM reads naturally as its label.
            .@"enum" => |e| e.label,
            else => null,
        };
    }

    /// Render for display (CLI, debugging). Writes SQL-ish text.
    pub fn format(self: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .null => try w.writeAll("NULL"),
            .boolean => |v| try w.writeAll(if (v) "true" else "false"),
            .tinyint => |v| try w.print("{d}", .{v}),
            .smallint => |v| try w.print("{d}", .{v}),
            .integer => |v| try w.print("{d}", .{v}),
            .bigint => |v| try w.print("{d}", .{v}),
            .hugeint => |v| try w.print("{d}", .{v}),
            .utinyint => |v| try w.print("{d}", .{v}),
            .usmallint => |v| try w.print("{d}", .{v}),
            .uinteger => |v| try w.print("{d}", .{v}),
            .ubigint => |v| try w.print("{d}", .{v}),
            .uhugeint => |v| try w.print("{d}", .{v}),
            .float => |v| try w.print("{d}", .{v}),
            .double => |v| try w.print("{d}", .{v}),
            .varchar => |v| try w.writeAll(v),
            .blob => |v| try w.print("\\x{x}", .{v}),
            .date => |v| try writeDate(w, v),
            .time => |v| try writeTime(w, v),
            .timestamp => |v| try writeTimestamp(w, v),
            .interval => |v| try w.print("{d} months {d} days {d} us", .{ v.months, v.days, v.micros }),
            .uuid => |v| try writeUuid(w, v),
            .decimal => |d| try writeDecimal(w, d),
            .@"enum" => |e| try w.writeAll(e.label),
        }
    }
};

/// Exposed so query-parameter encoding can render the same textual forms the
/// value formatter produces - one implementation, no drift between them.
pub fn writeDecimal(w: anytype, d: Value.Decimal) !void {
    if (d.scale == 0) return w.print("{d}", .{d.value});
    const neg = d.value < 0;
    // Use u128 magnitude so i128 minimum does not overflow on negation.
    const mag: u128 = if (neg) @as(u128, @intCast(-(d.value + 1))) + 1 else @intCast(d.value);
    var divisor: u128 = 1;
    var i: u8 = 0;
    while (i < d.scale) : (i += 1) divisor *= 10;
    const int_part = mag / divisor;
    const frac_part = mag % divisor;
    if (neg) try w.writeAll("-");
    try w.print("{d}.", .{int_part});
    // Left-pad the fraction to `scale` digits without a runtime format spec.
    var pad = divisor / 10;
    while (pad > 1 and frac_part < pad) : (pad /= 10) try w.writeAll("0");
    try w.print("{d}", .{frac_part});
}

/// Days since the Unix epoch -> `YYYY-MM-DD`, via the civil-from-days algorithm.
pub fn writeDate(w: anytype, days: i32) !void {
    const ymd = civilFromDays(days);
    // Years before 1 CE are rare in practice but must not print as "+0000".
    if (ymd.year < 0) {
        try w.print("-{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(-ymd.year)), ymd.month, ymd.day });
        return;
    }
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(ymd.year)), ymd.month, ymd.day });
}

pub fn writeTime(w: anytype, micros: i64) !void {
    // Normalise into [0, 1 day) so negative timestamps still render sensibly.
    const total_us: u64 = @intCast(@mod(micros, 86_400_000_000));
    const us: u64 = total_us % 1_000_000;
    const total_s: u64 = total_us / 1_000_000;
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{
        total_s / 3600,
        (total_s / 60) % 60,
        total_s % 60,
    });
    if (us != 0) try w.print(".{d:0>6}", .{us});
}

pub fn writeTimestamp(w: anytype, micros: i64) !void {
    const days = @divFloor(micros, 86_400_000_000);
    const rem = micros - days * 86_400_000_000;
    try writeDate(w, @intCast(days));
    try w.writeAll(" ");
    try writeTime(w, rem);
}

pub fn writeUuid(w: anytype, v: u128) !void {
    // DuckDB flips the sign bit when storing UUIDs as hugeint; undo that.
    const u = v ^ (@as(u128, 1) << 127);
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const shift: u7 = @intCast((31 - i) * 4);
        const nibble: u4 = @truncate(u >> shift);
        buf[i] = "0123456789abcdef"[nibble];
    }
    try w.print("{s}-{s}-{s}-{s}-{s}", .{ buf[0..8], buf[8..12], buf[12..16], buf[16..20], buf[20..32] });
}

const YMD = struct { year: i32, month: u32, day: u32 };

/// Howard Hinnant's `civil_from_days`.
fn civilFromDays(z_in: i32) YMD {
    var z: i64 = z_in;
    z += 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = @intCast(if (m <= 2) y + 1 else y),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

const testing = std.testing;

fn fmtValue(buf: []u8, v: Value) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try v.format(&w);
    return w.buffered();
}

test "numeric coercion across integer widths" {
    try testing.expectEqual(@as(?i64, 42), (Value{ .integer = 42 }).asI64());
    try testing.expectEqual(@as(?i64, -7), (Value{ .tinyint = -7 }).asI64());
    try testing.expectEqual(@as(?i64, null), (Value{ .varchar = "x" }).asI64());
    try testing.expectEqual(@as(?i64, null), (Value{ .null = {} }).asI64());
    // ubigint beyond i64 range does not silently wrap
    try testing.expectEqual(@as(?i64, null), (Value{ .ubigint = std.math.maxInt(u64) }).asI64());
}

test "date formatting matches the civil calendar" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01", try fmtValue(&buf, .{ .date = 0 }));
    try testing.expectEqualStrings("2000-01-01", try fmtValue(&buf, .{ .date = 10957 }));
    try testing.expectEqualStrings("1969-12-31", try fmtValue(&buf, .{ .date = -1 }));
}

test "timestamp formatting includes time of day" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01 00:00:00", try fmtValue(&buf, .{ .timestamp = 0 }));
    try testing.expectEqualStrings("1970-01-02 03:04:05", try fmtValue(&buf, .{ .timestamp = 97_445_000_000 }));
}

test "decimal renders with its scale" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("12.34", try fmtValue(&buf, .{ .decimal = .{ .value = 1234, .width = 5, .scale = 2 } }));
    try testing.expectEqualStrings("-0.05", try fmtValue(&buf, .{ .decimal = .{ .value = -5, .width = 5, .scale = 2 } }));
    try testing.expectEqualStrings("7", try fmtValue(&buf, .{ .decimal = .{ .value = 7, .width = 5, .scale = 0 } }));
}

test "null renders as NULL and reports isNull" {
    var buf: [16]u8 = undefined;
    try testing.expect((Value{ .null = {} }).isNull());
    try testing.expectEqualStrings("NULL", try fmtValue(&buf, .null));
}
