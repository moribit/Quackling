//! Encoder for DuckDB's `BinarySerializer` wire format.
//!
//! Mirrors `reader.zig`. Writes into a caller-supplied `std.ArrayList(u8)` so the
//! caller controls the allocator and can reuse the buffer across requests
//! (todo.md §14: reusable send buffer, no per-message allocator churn).

const std = @import("std");
const reader = @import("reader.zig");

pub const FieldId = reader.FieldId;
pub const message_terminator = reader.message_terminator;

pub const Error = std.mem.Allocator.Error;

pub const Writer = struct {
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) Writer {
        return .{ .buf = buf, .allocator = allocator };
    }

    pub fn bytesWritten(self: *const Writer) usize {
        return self.buf.items.len;
    }

    pub fn writeByte(self: *Writer, b: u8) Error!void {
        try self.buf.append(self.allocator, b);
    }

    pub fn writeRaw(self: *Writer, bytes: []const u8) Error!void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    /// `bool` is one raw byte, not a varint.
    pub fn writeBool(self: *Writer, v: bool) Error!void {
        try self.writeByte(@intFromBool(v));
    }

    pub fn writeFieldId(self: *Writer, id: FieldId) Error!void {
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(u16, &tmp, id, .little);
        try self.writeRaw(&tmp);
    }

    pub fn writeTerminator(self: *Writer) Error!void {
        try self.writeFieldId(message_terminator);
    }

    pub fn writeUVarInt(self: *Writer, value: anytype) Error!void {
        var v: u64 = @intCast(value);
        while (true) {
            var byte: u8 = @intCast(v & 0x7F);
            v >>= 7;
            if (v != 0) byte |= 0x80;
            try self.writeByte(byte);
            if (v == 0) break;
        }
    }

    /// Signed LEB128, sign-extended (matches `EncodingUtil::EncodeSignedLEB128`).
    pub fn writeIVarInt(self: *Writer, value: anytype) Error!void {
        var v: i64 = @intCast(value);
        while (true) {
            const byte: u8 = @intCast(@as(u64, @bitCast(v)) & 0x7F);
            v >>= 7; // arithmetic shift
            const sign_bit_set = (byte & 0x40) != 0;
            if ((v == 0 and !sign_bit_set) or (v == -1 and sign_bit_set)) {
                try self.writeByte(byte);
                return;
            }
            try self.writeByte(byte | 0x80);
        }
    }

    pub fn writeF32(self: *Writer, v: f32) Error!void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, @bitCast(v), .little);
        try self.writeRaw(&tmp);
    }

    pub fn writeF64(self: *Writer, v: f64) Error!void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(u64, &tmp, @bitCast(v), .little);
        try self.writeRaw(&tmp);
    }

    pub fn writeHugeInt(self: *Writer, v: i128) Error!void {
        const upper: i64 = @intCast(v >> 64);
        const lower: u64 = @truncate(@as(u128, @bitCast(v)));
        try self.writeIVarInt(upper);
        try self.writeUVarInt(lower);
    }

    pub fn writeUHugeInt(self: *Writer, v: u128) Error!void {
        const upper: u64 = @intCast(v >> 64);
        const lower: u64 = @truncate(v);
        try self.writeUVarInt(upper);
        try self.writeUVarInt(lower);
    }

    pub fn writeString(self: *Writer, s: []const u8) Error!void {
        try self.writeUVarInt(@as(u64, s.len));
        try self.writeRaw(s);
    }

    pub fn writeOptionalIdx(self: *Writer, v: ?u64) Error!void {
        try self.writeUVarInt(v orelse std.math.maxInt(u64));
    }

    // -- property helpers -----------------------------------------------------
    //
    // `writeProperty*` mirrors DuckDB's `WriteProperty` (always emitted) vs
    // `WritePropertyWithDefault` (omitted when equal to the type default). Getting
    // this distinction wrong is the main way an encoder desyncs a DuckDB decoder,
    // so the two are separate, explicitly-named calls.

    pub fn writePropertyString(self: *Writer, id: FieldId, s: []const u8) Error!void {
        try self.writeFieldId(id);
        try self.writeString(s);
    }

    /// Omits the field entirely when the string is empty.
    pub fn writePropertyStringWithDefault(self: *Writer, id: FieldId, s: []const u8) Error!void {
        if (s.len == 0) return;
        try self.writePropertyString(id, s);
    }

    pub fn writePropertyUVarInt(self: *Writer, id: FieldId, v: anytype) Error!void {
        try self.writeFieldId(id);
        try self.writeUVarInt(v);
    }

    /// Omits the field entirely when the value is zero.
    pub fn writePropertyUVarIntWithDefault(self: *Writer, id: FieldId, v: anytype) Error!void {
        if (v == 0) return;
        try self.writePropertyUVarInt(id, v);
    }

    pub fn writePropertyBool(self: *Writer, id: FieldId, v: bool) Error!void {
        try self.writeFieldId(id);
        try self.writeBool(v);
    }

    pub fn writePropertyBoolWithDefault(self: *Writer, id: FieldId, v: bool) Error!void {
        if (!v) return;
        try self.writePropertyBool(id, v);
    }

    pub fn writePropertyHugeInt(self: *Writer, id: FieldId, v: i128) Error!void {
        try self.writeFieldId(id);
        try self.writeHugeInt(v);
    }

    pub fn writePropertyOptionalIdx(self: *Writer, id: FieldId, v: ?u64) Error!void {
        try self.writeFieldId(id);
        try self.writeOptionalIdx(v);
    }
};

const testing = std.testing;

fn encodeToHex(comptime f: fn (*Writer) anyerror!void) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    try f(&w);
    return testing.allocator.dupe(u8, buf.items);
}

test "writer/reader roundtrip for unsigned varint" {
    const cases = [_]u64{ 0, 1, 127, 128, 300, 65535, std.math.maxInt(u32), std.math.maxInt(u64) };
    for (cases) |c| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var w = Writer.init(testing.allocator, &buf);
        try w.writeUVarInt(c);
        var r = reader.Reader.init(buf.items);
        try testing.expectEqual(c, try r.readUVarInt(u64));
        try testing.expect(r.isAtEnd());
    }
}

test "writer/reader roundtrip for signed varint" {
    const cases = [_]i64{ 0, 1, -1, 63, -64, 64, -65, 1000, -1000, std.math.maxInt(i64), std.math.minInt(i64) };
    for (cases) |c| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var w = Writer.init(testing.allocator, &buf);
        try w.writeIVarInt(c);
        var r = reader.Reader.init(buf.items);
        try testing.expectEqual(c, try r.readIVarInt(i64));
        try testing.expect(r.isAtEnd());
    }
}

test "signed encoding matches DuckDB reference bytes" {
    // Verified against EncodingUtil::EncodeSignedLEB128.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    try w.writeIVarInt(@as(i64, -1));
    try testing.expectEqualSlices(u8, &[_]u8{0x7F}, buf.items);
}

test "hugeint roundtrip including negatives" {
    const cases = [_]i128{ 0, 42, -42, std.math.maxInt(i64), std.math.maxInt(i128), std.math.minInt(i128) };
    for (cases) |c| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var w = Writer.init(testing.allocator, &buf);
        try w.writeHugeInt(c);
        var r = reader.Reader.init(buf.items);
        try testing.expectEqual(c, try r.readHugeInt());
    }
}

test "string roundtrip preserves utf8 and empty" {
    const cases = [_][]const u8{ "", "hello", "wörld🦆", "SELECT 42 AS answer" };
    for (cases) |c| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var w = Writer.init(testing.allocator, &buf);
        try w.writeString(c);
        var r = reader.Reader.init(buf.items);
        try testing.expectEqualStrings(c, try r.readString());
    }
}

test "default-skipping omits empty and zero fields" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    try w.writePropertyStringWithDefault(2, "");
    try w.writePropertyUVarIntWithDefault(4, @as(u64, 0));
    try w.writePropertyBoolWithDefault(3, false);
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "float roundtrip" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    try w.writeF32(42.5);
    try w.writeF64(-1.25);
    var r = reader.Reader.init(buf.items);
    try testing.expectEqual(@as(f32, 42.5), try r.readF32());
    try testing.expectEqual(@as(f64, -1.25), try r.readF64());
}
