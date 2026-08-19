//! A `DataChunk`: up to STANDARD_VECTOR_SIZE rows across N columns.
//!
//! This is the first-class unit of the API (todo.md §7). A chunk owns its
//! decoded vectors but the bulk payload inside them still borrows the response
//! buffer, so `deinit` is cheap and no row-sized copies happen.

const std = @import("std");
const vector_mod = @import("vector.zig");
const value_mod = @import("value.zig");
const lt = @import("logical_type.zig");

const Vector = vector_mod.Vector;
const Value = value_mod.Value;

/// DuckDB's STANDARD_VECTOR_SIZE. Chunks never exceed this.
pub const standard_vector_size: usize = 2048;

pub const DataChunk = struct {
    allocator: std.mem.Allocator,
    columns: []Vector,
    row_count: usize,
    /// The chunk owns the column type tree; every `Vector` (including the
    /// children of nested types) only borrows into it. Keeping ownership in one
    /// place is what makes nested types safe to free exactly once.
    types: []lt.LogicalType = &.{},

    pub fn deinit(self: *DataChunk) void {
        for (self.columns) |*c| c.deinit();
        if (self.columns.len > 0) self.allocator.free(self.columns);
        for (self.types) |*t| t.deinit(self.allocator);
        if (self.types.len > 0) self.allocator.free(self.types);
        self.columns = &.{};
        self.types = &.{};
        self.row_count = 0;
    }

    /// The declared type of column `i`.
    pub fn columnType(self: *const DataChunk, i: usize) ?lt.LogicalType {
        if (i >= self.types.len) return null;
        return self.types[i];
    }

    pub fn columnCount(self: *const DataChunk) usize {
        return self.columns.len;
    }

    pub fn rowCount(self: *const DataChunk) usize {
        return self.row_count;
    }

    pub fn column(self: *const DataChunk, i: usize) ?*const Vector {
        if (i >= self.columns.len) return null;
        return &self.columns[i];
    }

    pub fn getValue(self: *const DataChunk, col: usize, row: usize) !Value {
        if (col >= self.columns.len) return error.ColumnOutOfRange;
        return self.columns[col].getValue(row);
    }

    pub fn isNull(self: *const DataChunk, col: usize, row: usize) bool {
        if (col >= self.columns.len) return true;
        return self.columns[col].isNull(row);
    }

    /// Iterate rows without materialising them.
    pub fn rows(self: *const DataChunk) RowIterator {
        return .{ .chunk = self, .index = 0 };
    }
};

/// A lightweight cursor over a chunk. Holds no allocation of its own.
pub const RowIterator = struct {
    chunk: *const DataChunk,
    index: usize,

    pub fn next(self: *RowIterator) ?Row {
        if (self.index >= self.chunk.row_count) return null;
        const r = Row{ .chunk = self.chunk, .index = self.index };
        self.index += 1;
        return r;
    }
};

/// A view onto one row. Copies nothing; resolves values on demand.
pub const Row = struct {
    chunk: *const DataChunk,
    index: usize,

    pub fn get(self: Row, col: usize) !Value {
        return self.chunk.getValue(col, self.index);
    }

    pub fn isNull(self: Row, col: usize) bool {
        return self.chunk.isNull(col, self.index);
    }

    pub fn columnCount(self: Row) usize {
        return self.chunk.columnCount();
    }
};

const testing = std.testing;

test "chunk row iteration walks every row once" {
    const data align(4) = [_]u8{ 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0 };
    var cols = try testing.allocator.alloc(Vector, 1);
    cols[0] = .{ .type = .{ .id = .integer }, .count = 3, .storage = .{ .fixed = &data } };
    var chunk = DataChunk{ .allocator = testing.allocator, .columns = cols, .row_count = 3 };
    defer chunk.deinit();

    var it = chunk.rows();
    var seen: [3]i32 = undefined;
    var n: usize = 0;
    while (it.next()) |row| : (n += 1) {
        seen[n] = (try row.get(0)).integer;
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, &seen);
}

test "out of range column access is an error" {
    var cols = try testing.allocator.alloc(Vector, 0);
    var chunk = DataChunk{ .allocator = testing.allocator, .columns = cols[0..0], .row_count = 0 };
    defer chunk.deinit();
    try testing.expectError(error.ColumnOutOfRange, chunk.getValue(0, 0));
    try testing.expect(chunk.isNull(5, 0));
}
