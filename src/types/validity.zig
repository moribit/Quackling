//! DuckDB validity masks.
//!
//! A validity mask is a bitset of `u64` words, LSB-first, where a **set** bit
//! means the row is VALID (non-NULL). When a vector carries no mask, every row
//! is valid.
//!
//! The mask borrows the response buffer rather than copying: `entries` points
//! straight at the wire bytes (todo.md §11).

const std = @import("std");

pub const ValidityMask = struct {
    /// Raw mask bytes from the wire, or null when all rows are valid.
    bytes: ?[]const u8 = null,
    /// Number of rows the mask describes.
    count: usize = 0,

    pub const all_valid = ValidityMask{ .bytes = null, .count = 0 };

    /// Bytes required to hold `count` bits, rounded up to whole u64 words -
    /// matches `ValidityMask::ValidityMaskSize`.
    pub fn maskSizeFor(count: usize) usize {
        const entry_count = (count + 63) / 64;
        return entry_count * 8;
    }

    pub fn init(bytes: []const u8, count: usize) ValidityMask {
        return .{ .bytes = bytes, .count = count };
    }

    /// Is row `idx` non-NULL?
    ///
    /// Out-of-range indices report invalid rather than reading past the mask.
    pub fn isValid(self: ValidityMask, idx: usize) bool {
        const b = self.bytes orelse return true;
        const byte_idx = idx / 8;
        if (byte_idx >= b.len) return false;
        const bit: u3 = @intCast(idx % 8);
        return (b[byte_idx] >> bit) & 1 == 1;
    }

    pub fn isNull(self: ValidityMask, idx: usize) bool {
        return !self.isValid(idx);
    }

    pub fn allValid(self: ValidityMask) bool {
        return self.bytes == null;
    }

    /// Count of NULLs in the first `count` rows.
    pub fn nullCount(self: ValidityMask) usize {
        if (self.bytes == null) return 0;
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (!self.isValid(i)) n += 1;
        }
        return n;
    }
};

const testing = std.testing;

test "absent mask means every row is valid" {
    const m = ValidityMask.all_valid;
    try testing.expect(m.isValid(0));
    try testing.expect(m.isValid(9999));
    try testing.expectEqual(@as(usize, 0), m.nullCount());
}

test "set bit means valid, clear bit means null" {
    // 0b1010_0101 -> rows 0,2,5,7 valid
    const bytes = [_]u8{0b1010_0101};
    const m = ValidityMask.init(&bytes, 8);
    try testing.expect(m.isValid(0));
    try testing.expect(!m.isValid(1));
    try testing.expect(m.isValid(2));
    try testing.expect(!m.isValid(3));
    try testing.expect(!m.isValid(4));
    try testing.expect(m.isValid(5));
    try testing.expect(!m.isValid(6));
    try testing.expect(m.isValid(7));
    try testing.expectEqual(@as(usize, 4), m.nullCount());
}

test "mask size rounds up to u64 words" {
    try testing.expectEqual(@as(usize, 0), ValidityMask.maskSizeFor(0));
    try testing.expectEqual(@as(usize, 8), ValidityMask.maskSizeFor(1));
    try testing.expectEqual(@as(usize, 8), ValidityMask.maskSizeFor(64));
    try testing.expectEqual(@as(usize, 16), ValidityMask.maskSizeFor(65));
    try testing.expectEqual(@as(usize, 256), ValidityMask.maskSizeFor(2048));
}

test "index past the mask reports null instead of reading out of bounds" {
    const bytes = [_]u8{0xFF};
    const m = ValidityMask.init(&bytes, 8);
    try testing.expect(m.isValid(7));
    try testing.expect(!m.isValid(8)); // beyond the buffer
    try testing.expect(!m.isValid(1_000_000));
}
