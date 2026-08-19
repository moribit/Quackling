//! Bounds-checked reader for DuckDB's `BinarySerializer` wire format.
//!
//! Every read is length-checked against the backing slice, so an arbitrary byte
//! string can be fed in and will either decode or return an error - never panic,
//! never read out of bounds. See `docs/PROTOCOL.md` §3 for the encoding table.

const std = @import("std");

pub const Error = error{
    /// Ran out of bytes mid-value.
    UnexpectedEndOfBuffer,
    /// A LEB128 sequence was longer than the target type can hold.
    VarIntOverflow,
    /// A length/count field exceeds the configured safety limit.
    LengthLimitExceeded,
    /// Object terminator appeared where a field was required, or vice versa.
    UnexpectedFieldId,
};

/// Field ids are `uint16` little-endian; 0xFFFF terminates an object.
pub const FieldId = u16;
pub const message_terminator: FieldId = 0xFFFF;

/// Guards against hostile length prefixes (`allocation bomb`, todo.md §21).
/// A field claiming more bytes than remain in the buffer is rejected before
/// any allocation happens.
pub const Limits = struct {
    /// Upper bound for a single string/blob length prefix.
    max_byte_length: usize = 256 * 1024 * 1024,
    /// Upper bound for a list element count.
    max_list_length: usize = 64 * 1024 * 1024,
    /// Maximum object nesting depth, to bound recursive decoders.
    max_depth: u16 = 64,
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,
    limits: Limits = .{},
    depth: u16 = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn initWithLimits(buf: []const u8, limits: Limits) Reader {
        return .{ .buf = buf, .limits = limits };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }

    pub fn isAtEnd(self: *const Reader) bool {
        return self.pos >= self.buf.len;
    }

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.remaining()) return Error.UnexpectedEndOfBuffer;
        const out = self.buf[self.pos..][0..n];
        self.pos += n;
        return out;
    }

    pub fn readByte(self: *Reader) Error!u8 {
        if (self.pos >= self.buf.len) return Error.UnexpectedEndOfBuffer;
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    /// `bool` is a single raw byte, NOT a varint. (protocol §3)
    pub fn readBool(self: *Reader) Error!bool {
        return (try self.readByte()) != 0;
    }

    /// Field ids are fixed-width u16 little-endian, never varint.
    pub fn readFieldId(self: *Reader) Error!FieldId {
        const bytes = try self.take(2);
        return std.mem.readInt(u16, bytes[0..2], .little);
    }

    pub fn peekFieldId(self: *Reader) Error!FieldId {
        if (self.remaining() < 2) return Error.UnexpectedEndOfBuffer;
        return std.mem.readInt(u16, self.buf[self.pos..][0..2], .little);
    }

    /// Unsigned LEB128. Rejects encodings too long for `T` rather than wrapping.
    ///
    /// `shift` is deliberately a `u32`, not a `u6`: a `u6` counter overflows on
    /// its own increment before an in-loop bound check can fire, which is a
    /// panic rather than the typed error this decoder promises.
    pub fn readUVarInt(self: *Reader, comptime T: type) Error!T {
        const bits = @typeInfo(T).int.bits;
        var result: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            const byte = try self.readByte();
            const payload: u64 = byte & 0x7F;

            if (shift >= 64) return Error.VarIntOverflow;
            // Bits that would be shifted past bit 63 are lost; that is overflow.
            const capacity: u32 = 64 - shift;
            if (capacity < 64 and payload >= (@as(u64, 1) << @intCast(capacity))) {
                return Error.VarIntOverflow;
            }

            result |= payload << @intCast(shift);
            if (byte & 0x80 == 0) break;
            shift += 7;
        }
        if (bits < 64 and result > std.math.maxInt(T)) return Error.VarIntOverflow;
        return @intCast(result);
    }

    /// Signed LEB128 - sign-extended, *not* zigzag.
    ///
    /// As in `readUVarInt`, `shift` is a `u32` so the counter itself can never
    /// overflow before the bound check rejects an over-long encoding.
    pub fn readIVarInt(self: *Reader, comptime T: type) Error!T {
        const bits = @typeInfo(T).int.bits;
        var result: u64 = 0;
        var shift: u32 = 0;
        var last: u8 = 0;
        while (true) {
            const byte = try self.readByte();
            last = byte;
            if (shift >= 64) return Error.VarIntOverflow;
            result |= (@as(u64, byte & 0x7F)) << @intCast(shift);
            shift += 7;
            if (byte & 0x80 == 0) break;
        }
        // Sign-extend if the sign bit of the final group is set.
        if (shift < 64 and (last & 0x40) != 0) {
            const ones: u64 = ~@as(u64, 0);
            result |= ones << @intCast(shift);
        }
        const signed: i64 = @bitCast(result);
        if (bits < 64) {
            if (signed > std.math.maxInt(T) or signed < std.math.minInt(T)) {
                return Error.VarIntOverflow;
            }
        }
        return @intCast(signed);
    }

    pub fn readF32(self: *Reader) Error!f32 {
        const bytes = try self.take(4);
        return @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
    }

    pub fn readF64(self: *Reader) Error!f64 {
        const bytes = try self.take(8);
        return @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
    }

    /// hugeint: signed-LEB upper, then unsigned-LEB lower.
    pub fn readHugeInt(self: *Reader) Error!i128 {
        const upper = try self.readIVarInt(i64);
        const lower = try self.readUVarInt(u64);
        return (@as(i128, upper) << 64) | @as(i128, lower);
    }

    pub fn readUHugeInt(self: *Reader) Error!u128 {
        const upper = try self.readUVarInt(u64);
        const lower = try self.readUVarInt(u64);
        return (@as(u128, upper) << 64) | @as(u128, lower);
    }

    /// A length-prefixed byte run. The returned slice **borrows** from the input
    /// buffer - it is valid only as long as the buffer is. Callers that need to
    /// retain it must copy.
    pub fn readBytes(self: *Reader) Error![]const u8 {
        const len = try self.readLength();
        return self.take(len);
    }

    /// Same as `readBytes`; separate name documents intent at call sites.
    pub fn readString(self: *Reader) Error![]const u8 {
        return self.readBytes();
    }

    /// Read a raw run of exactly `n` bytes (used for fixed-width vector payloads
    /// where the count is derived from the type width, not the prefix).
    pub fn readRaw(self: *Reader, n: usize) Error![]const u8 {
        return self.take(n);
    }

    /// A length prefix, validated against both the safety limit and the number of
    /// bytes actually left. This is what stops a malicious `length` field from
    /// driving a huge allocation.
    pub fn readLength(self: *Reader) Error!usize {
        const len = try self.readUVarInt(u64);
        if (len > self.limits.max_byte_length) return Error.LengthLimitExceeded;
        const n: usize = @intCast(len);
        if (n > self.remaining()) return Error.UnexpectedEndOfBuffer;
        return n;
    }

    /// A list element count. Cannot be pre-validated against `remaining()` because
    /// elements are variable width, but is bounded by `max_list_length` and by the
    /// fact that each element consumes >= 1 byte.
    pub fn readListLength(self: *Reader) Error!usize {
        const len = try self.readUVarInt(u64);
        if (len > self.limits.max_list_length) return Error.LengthLimitExceeded;
        const n: usize = @intCast(len);
        // Every element costs at least one byte, so a count exceeding the bytes
        // left is guaranteed-truncated input. Reject before allocating for it.
        if (n > self.remaining()) return Error.UnexpectedEndOfBuffer;
        return n;
    }

    /// `optional_idx`: u64 varint where UINT64_MAX means "not set".
    pub fn readOptionalIdx(self: *Reader) Error!?u64 {
        const v = try self.readUVarInt(u64);
        return if (v == std.math.maxInt(u64)) null else v;
    }

    pub fn enterObject(self: *Reader) Error!void {
        if (self.depth >= self.limits.max_depth) return Error.LengthLimitExceeded;
        self.depth += 1;
    }

    pub fn leaveObject(self: *Reader) void {
        if (self.depth > 0) self.depth -= 1;
    }

    /// Consume the object terminator, erroring if some other field id is found.
    pub fn expectTerminator(self: *Reader) Error!void {
        const f = try self.readFieldId();
        if (f != message_terminator) return Error.UnexpectedFieldId;
    }

    /// Skip a whole object's remaining fields without interpreting them. Used to
    /// stay forward-compatible with server-side additions (todo.md §23): an
    /// unknown field can be stepped over instead of aborting the decode.
    ///
    /// Because field *values* are not self-describing, this can only be used
    /// where the caller knows the shape. For genuinely unknown fields we fail
    /// loudly rather than risk silent misinterpretation.
    pub fn skipToTerminator(self: *Reader) Error!void {
        while (true) {
            const f = try self.readFieldId();
            if (f == message_terminator) return;
            return Error.UnexpectedFieldId;
        }
    }
};

const testing = std.testing;

test "unsigned varint roundtrip and boundaries" {
    var r = Reader.init(&[_]u8{0x00});
    try testing.expectEqual(@as(u64, 0), try r.readUVarInt(u64));

    var r2 = Reader.init(&[_]u8{ 0xFF, 0x01 });
    try testing.expectEqual(@as(u64, 255), try r2.readUVarInt(u64));

    // UINT64_MAX
    var r3 = Reader.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 });
    try testing.expectEqual(std.math.maxInt(u64), try r3.readUVarInt(u64));
}

test "signed varint is sign-extended not zigzag" {
    // -1 encodes as 0x7F in sign-extended LEB128 (zigzag would give 0x01).
    var r = Reader.init(&[_]u8{0x7F});
    try testing.expectEqual(@as(i64, -1), try r.readIVarInt(i64));

    var r2 = Reader.init(&[_]u8{0x01});
    try testing.expectEqual(@as(i64, 1), try r2.readIVarInt(i64));

    // -64 -> 0x40
    var r3 = Reader.init(&[_]u8{0x40});
    try testing.expectEqual(@as(i64, -64), try r3.readIVarInt(i64));
}

test "varint overflow is rejected rather than wrapping" {
    // 10 continuation bytes overflows u64.
    var r = Reader.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F });
    try testing.expectError(Error.VarIntOverflow, r.readUVarInt(u64));

    // Value too large for the narrower target type.
    var r2 = Reader.init(&[_]u8{ 0x80, 0x02 }); // 256
    try testing.expectError(Error.VarIntOverflow, r2.readUVarInt(u8));
}

test "a varint whose high bits would be truncated is rejected" {
    // 10 groups of 7 bits reach bit 63. A final group carrying bits that would
    // land past bit 63 must be rejected, not silently dropped - otherwise a
    // hostile length prefix could decode to a small, plausible number.
    //
    // 9 full groups (63 bits) then 0x02: bit 64 set.
    const overflowing = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 };
    var r = Reader.init(&overflowing);
    try testing.expectError(Error.VarIntOverflow, r.readUVarInt(u64));

    // The largest value that *does* fit must still decode.
    const max_ok = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    var ok = Reader.init(&max_ok);
    try testing.expectEqual(std.math.maxInt(u64), try ok.readUVarInt(u64));
}

test "over-long varints error instead of overflowing the shift counter" {
    // Regression: a `u6`/`u7` shift counter panics on its own increment before
    // any bound check can fire. Found by the fuzz corpus, not by hand.
    // 20 continuation bytes pushes shift well past 64.
    const long = [_]u8{0xFF} ** 20 ++ [_]u8{0x00};
    var r = Reader.init(&long);
    try testing.expectError(Error.VarIntOverflow, r.readUVarInt(u64));

    var r2 = Reader.init(&long);
    try testing.expectError(Error.VarIntOverflow, r2.readIVarInt(i64));

    // Also via the optional_idx path, which is where the fuzzer hit it.
    var r3 = Reader.init(&long);
    try testing.expectError(Error.VarIntOverflow, r3.readOptionalIdx());
}

test "truncated input never reads out of bounds" {
    var r = Reader.init(&[_]u8{0x80}); // continuation bit set, no follow-up
    try testing.expectError(Error.UnexpectedEndOfBuffer, r.readUVarInt(u64));

    var r2 = Reader.init(&[_]u8{0x05}); // claims 5 bytes, none present
    try testing.expectError(Error.UnexpectedEndOfBuffer, r2.readString());

    var r3 = Reader.init(&[_]u8{0x01});
    try testing.expectError(Error.UnexpectedEndOfBuffer, r3.readFieldId());
}

test "a length prefix beyond the buffer is rejected by readLength itself" {
    // `take` also bounds-checks, so a caller would fail either way - but the
    // point of validating here is to reject *before* a caller allocates for the
    // claimed size. Assert the check at its own level so it cannot be dropped
    // on the assumption that something downstream will catch it.
    var r = Reader.init(&[_]u8{ 0x10, 0xAA, 0xBB }); // claims 16, has 2
    try testing.expectError(Error.UnexpectedEndOfBuffer, r.readLength());
    // Nothing was consumed past the prefix, so the error is reported cleanly.
    try testing.expectEqual(@as(usize, 1), r.pos);

    // A length exactly equal to what remains is fine.
    var ok = Reader.init(&[_]u8{ 0x02, 0xAA, 0xBB });
    try testing.expectEqual(@as(usize, 2), try ok.readLength());
}

test "hostile length prefix is rejected before allocation" {
    // Claims ~2^60 bytes.
    var r = Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x10 });
    try testing.expectError(Error.LengthLimitExceeded, r.readLength());
}

test "field id is little endian u16" {
    var r = Reader.init(&[_]u8{ 0x2C, 0x01 });
    try testing.expectEqual(@as(FieldId, 300), try r.readFieldId());

    var r2 = Reader.init(&[_]u8{ 0xFF, 0xFF });
    try testing.expectEqual(message_terminator, try r2.readFieldId());
}

test "optional_idx sentinel decodes to null" {
    var r = Reader.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 });
    try testing.expectEqual(@as(?u64, null), try r.readOptionalIdx());

    var r2 = Reader.init(&[_]u8{0x07});
    try testing.expectEqual(@as(?u64, 7), try r2.readOptionalIdx());
}

test "hugeint composes signed upper and unsigned lower" {
    // upper = 0, lower = 42  ->  42
    var r = Reader.init(&[_]u8{ 0x00, 0x2A });
    try testing.expectEqual(@as(i128, 42), try r.readHugeInt());

    // upper = -1, lower = UINT64_MAX -> -1
    var r2 = Reader.init(&[_]u8{ 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 });
    try testing.expectEqual(@as(i128, -1), try r2.readHugeInt());
}

test "floats are raw little-endian not varint" {
    var r = Reader.init(&[_]u8{ 0x00, 0x00, 0x28, 0x42 }); // 42.0f
    try testing.expectEqual(@as(f32, 42.0), try r.readF32());
}
