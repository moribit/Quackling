//! A decoded DuckDB `Vector`: one column's worth of a `DataChunk`.
//!
//! Fixed-width data is kept as a **borrowed slice of the response buffer** - no
//! per-value copy, no per-value allocation (todo.md §11). `asSlice(i32)` hands
//! that memory back as a typed slice when the layout permits, which is the
//! zero-copy fast path.
//!
//! Compressed encodings (CONSTANT / DICTIONARY / SEQUENCE) are decoded into an
//! index indirection rather than being expanded, so a 2048-row constant vector
//! still costs one value.

const std = @import("std");
const lt = @import("logical_type.zig");
const validity_mod = @import("validity.zig");
const value_mod = @import("value.zig");

const ValidityMask = validity_mod.ValidityMask;
const LogicalType = lt.LogicalType;
const Value = value_mod.Value;

pub const Error = error{
    UnsupportedType,
    UnsupportedVectorType,
    /// The payload length did not match what the type and row count imply.
    MalformedVector,
} || std.mem.Allocator.Error;

/// `VectorType` from DuckDB. Field 90 on the wire; absent means FLAT.
pub const VectorType = enum(u8) {
    flat = 0,
    /// Never appears on the wire - DuckDB flattens FSST vectors before
    /// serializing. Listed so the enum matches upstream and so an unexpected
    /// one is reported rather than misread.
    fsst = 1,
    constant = 2,
    dictionary = 3,
    sequence = 4,
    _,
};

/// How a vector's values are physically laid out after decoding.
pub const Storage = union(enum) {
    /// Fixed-width values packed back to back, borrowed from the wire buffer.
    fixed: []const u8,
    /// One string slice per row, borrowed from the wire buffer.
    strings: []const []const u8,
    /// A single value repeated for every row.
    constant: *Vector,
    /// `indices[i]` selects from `child`.
    dictionary: struct { indices: []const u32, child: *Vector },
    /// Arithmetic sequence; no payload on the wire.
    sequence: struct { start: i64, increment: i64 },
    /// STRUCT: one child vector per field.
    children: []Vector,
    /// LIST: offsets/lengths into a flattened child vector.
    list: struct { entries: []const ListEntry, child: *Vector },
    /// ARRAY: fixed-size runs of `child`.
    array: struct { size: u64, child: *Vector },
    /// Type is known but not decodable by this client version.
    unsupported,
};

pub const ListEntry = struct { offset: u64, length: u64 };

/// One row of a MAP: a window into parallel key and value child vectors.
pub const MapEntry = struct {
    offset: u64,
    length: u64,
    keys: *Vector,
    values: *Vector,
};

/// The active member of one UNION row.
pub const UnionMember = struct {
    tag: u8,
    name: []const u8,
    vector: *Vector,
};

pub const Vector = struct {
    /// **Borrowed**, not owned. The `DataChunk` owns the type tree; child
    /// vectors of a nested type share sub-trees of it. A vector must therefore
    /// never free its own type - doing so double-frees the shared children.
    type: LogicalType,
    count: usize,
    validity: ValidityMask = ValidityMask.all_valid,
    storage: Storage,
    /// Allocations owned by this vector (children, index arrays, string tables).
    /// Freed by `deinit`; the wire-borrowed slices inside are not.
    allocator: ?std.mem.Allocator = null,

    // -- decode-time scratch --------------------------------------------------
    // LIST and ARRAY spread their state across several fields that arrive in a
    // fixed order (size, then entries, then child). These hold the earlier parts
    // until the child vector shows up and `storage` can be built. They are not
    // part of the public surface.

    /// ARRAY element count, from field 103.
    array_size_hint: ?u64 = null,
    /// LIST flattened child length, from field 104.
    list_size_hint: ?u64 = null,
    /// LIST offset/length pairs, from field 105, owned until moved into storage.
    pending_entries: ?[]ListEntry = null,

    pub fn deinit(self: *Vector) void {
        const a = self.allocator orelse return;
        if (self.pending_entries) |e| {
            a.free(e);
            self.pending_entries = null;
        }
        switch (self.storage) {
            .strings => |s| a.free(s),
            .constant => |c| {
                c.deinit();
                a.destroy(c);
            },
            .dictionary => |d| {
                a.free(d.indices);
                d.child.deinit();
                a.destroy(d.child);
            },
            .children => |cs| {
                for (cs) |*c| c.deinit();
                a.free(cs);
            },
            .list => |l| {
                a.free(l.entries);
                l.child.deinit();
                a.destroy(l.child);
            },
            .array => |ar| {
                ar.child.deinit();
                a.destroy(ar.child);
            },
            .fixed, .sequence, .unsupported => {},
        }
        self.storage = .unsupported;
    }

    /// Resolve row `i` to the physical index inside the underlying storage.
    /// Handles the constant/dictionary indirection uniformly.
    fn physicalIndex(self: *const Vector, i: usize) ?usize {
        return switch (self.storage) {
            .constant => 0,
            .dictionary => |d| if (i < d.indices.len) @intCast(d.indices[i]) else null,
            else => i,
        };
    }

    pub fn isNull(self: *const Vector, i: usize) bool {
        if (i >= self.count) return true;
        switch (self.storage) {
            // For compressed forms the validity lives on the decoded child.
            .constant => |c| return c.isNull(0),
            .dictionary => |d| {
                const idx = self.physicalIndex(i) orelse return true;
                return d.child.isNull(idx);
            },
            else => return !self.validity.isValid(i),
        }
    }

    /// True when this vector is a flat run of `T` and can be read elementwise
    /// with no per-value decoding.
    ///
    /// Note the wire format offers no alignment guarantee: a payload's position
    /// depends on the varint-encoded lengths before it, so a fixed-width run
    /// lands at an arbitrary offset. `isFlat` therefore ignores alignment;
    /// use `at()` (always safe) or `asSlice()` (only when naturally aligned).
    pub fn isFlat(self: *const Vector, comptime T: type) bool {
        const bytes = switch (self.storage) {
            .fixed => |b| b,
            else => return false,
        };
        const width = self.type.fixedWidth() orelse return false;
        return width == @sizeOf(T) and bytes.len >= self.count * @sizeOf(T);
    }

    /// Zero-copy typed view of a fixed-width vector.
    ///
    /// Returns null unless the vector is a flat run of `T` **and** the borrowed
    /// buffer happens to be correctly aligned for it. Because Quack payloads
    /// are not aligned in general, treat a non-null result as an optimisation,
    /// not the normal path - `copySlice` or `at` work regardless.
    ///
    /// NOTE: this does not filter NULLs. Check `validity` alongside it.
    pub fn asSlice(self: *const Vector, comptime T: type) ?[]const T {
        if (!self.isFlat(T)) return null;
        const bytes = switch (self.storage) {
            .fixed => |b| b,
            else => return null,
        };
        if (@intFromPtr(bytes.ptr) % @alignOf(T) != 0) return null;
        const ptr: [*]const T = @ptrCast(@alignCast(bytes.ptr));
        return ptr[0..self.count];
    }

    /// Element `i` of a flat fixed-width vector, with no allocation and no
    /// `Value` boxing. This is the low-overhead path that always works: it
    /// performs an explicit little-endian load, so alignment is irrelevant.
    ///
    /// Returns null if this vector is not a flat run of `T`, or `i` is out of
    /// range. Does not consult the validity mask.
    pub fn at(self: *const Vector, comptime T: type, i: usize) ?T {
        if (i >= self.count) return null;
        if (!self.isFlat(T)) return null;
        return self.readFixed(T, i);
    }

    /// Copy a fixed-width column into caller-provided memory as `[]T`.
    ///
    /// The bulk alternative to `asSlice` when alignment does not cooperate:
    /// still one pass, no per-value branching, and the caller owns the buffer.
    /// Returns the number of elements written.
    pub fn copySlice(self: *const Vector, comptime T: type, out: []T) ?usize {
        if (!self.isFlat(T)) return null;
        const bytes = switch (self.storage) {
            .fixed => |b| b,
            else => return null,
        };
        const n = @min(self.count, out.len);
        if (@import("builtin").cpu.arch.endian() == .little) {
            // Wire order already matches memory order: one bulk copy, which
            // stays correct whether or not the source is aligned.
            @memcpy(std.mem.sliceAsBytes(out[0..n]), bytes[0 .. n * @sizeOf(T)]);
        } else {
            // Big-endian hosts must byte-swap each element.
            for (out[0..n], 0..) |*o, i| o.* = self.readFixed(T, i) orelse return null;
        }
        return n;
    }

    /// Read one element of a fixed-width vector, with bounds checking.
    fn readFixed(self: *const Vector, comptime T: type, idx: usize) ?T {
        const bytes = switch (self.storage) {
            .fixed => |b| b,
            else => return null,
        };
        const off = idx * @sizeOf(T);
        if (off + @sizeOf(T) > bytes.len) return null;
        // Explicit little-endian read - never a raw reinterpret of wire bytes
        // (todo.md §21).
        return switch (@typeInfo(T)) {
            .int => std.mem.readInt(T, bytes[off..][0..@sizeOf(T)], .little),
            .float => @bitCast(std.mem.readInt(
                std.meta.Int(.unsigned, @bitSizeOf(T)),
                bytes[off..][0..@sizeOf(T)],
                .little,
            )),
            else => @compileError("readFixed expects an int or float"),
        };
    }

    /// Decode row `i` into an owning-free `Value`.
    ///
    /// Slice-typed results borrow the chunk buffer.
    pub fn getValue(self: *const Vector, i: usize) Error!Value {
        if (i >= self.count) return Error.MalformedVector;

        switch (self.storage) {
            .constant => |c| return c.getValue(0),
            .dictionary => |d| {
                const idx = self.physicalIndex(i) orelse return Error.MalformedVector;
                return d.child.getValue(idx);
            },
            .sequence => |s| {
                if (self.isNull(i)) return .null;
                const off = std.math.mul(i64, s.increment, @as(i64, @intCast(i))) catch
                    return Error.MalformedVector;
                const v = std.math.add(i64, s.start, off) catch return Error.MalformedVector;
                return self.intValueFromI64(v);
            },
            .unsupported => return Error.UnsupportedType,
            else => {},
        }

        if (self.isNull(i)) return .null;

        return switch (self.type.id) {
            .boolean => .{ .boolean = (self.readFixed(u8, i) orelse return Error.MalformedVector) != 0 },
            .tinyint => .{ .tinyint = self.readFixed(i8, i) orelse return Error.MalformedVector },
            .smallint => .{ .smallint = self.readFixed(i16, i) orelse return Error.MalformedVector },
            .integer => .{ .integer = self.readFixed(i32, i) orelse return Error.MalformedVector },
            .bigint => .{ .bigint = self.readFixed(i64, i) orelse return Error.MalformedVector },
            .hugeint => .{ .hugeint = self.readFixed(i128, i) orelse return Error.MalformedVector },
            .utinyint => .{ .utinyint = self.readFixed(u8, i) orelse return Error.MalformedVector },
            .usmallint => .{ .usmallint = self.readFixed(u16, i) orelse return Error.MalformedVector },
            .uinteger => .{ .uinteger = self.readFixed(u32, i) orelse return Error.MalformedVector },
            .ubigint => .{ .ubigint = self.readFixed(u64, i) orelse return Error.MalformedVector },
            .uhugeint => .{ .uhugeint = self.readFixed(u128, i) orelse return Error.MalformedVector },
            .float => .{ .float = self.readFixed(f32, i) orelse return Error.MalformedVector },
            .double => .{ .double = self.readFixed(f64, i) orelse return Error.MalformedVector },
            .date => .{ .date = self.readFixed(i32, i) orelse return Error.MalformedVector },
            .time, .time_tz => .{ .time = self.readFixed(i64, i) orelse return Error.MalformedVector },
            .timestamp, .timestamp_sec, .timestamp_ms, .timestamp_ns, .timestamp_tz => .{
                .timestamp = self.readFixed(i64, i) orelse return Error.MalformedVector,
            },
            .uuid => .{ .uuid = @bitCast(self.readFixed(i128, i) orelse return Error.MalformedVector) },
            .interval => blk: {
                const bytes = switch (self.storage) {
                    .fixed => |b| b,
                    else => return Error.MalformedVector,
                };
                const off = i * 16;
                if (off + 16 > bytes.len) return Error.MalformedVector;
                break :blk .{ .interval = .{
                    .months = std.mem.readInt(i32, bytes[off..][0..4], .little),
                    .days = std.mem.readInt(i32, bytes[off + 4 ..][0..4], .little),
                    .micros = std.mem.readInt(i64, bytes[off + 8 ..][0..8], .little),
                } };
            },
            .decimal => blk: {
                const d = self.type.decimal orelse return Error.MalformedVector;
                const raw: i128 = switch (self.type.fixedWidth() orelse return Error.MalformedVector) {
                    2 => self.readFixed(i16, i) orelse return Error.MalformedVector,
                    4 => self.readFixed(i32, i) orelse return Error.MalformedVector,
                    8 => self.readFixed(i64, i) orelse return Error.MalformedVector,
                    16 => self.readFixed(i128, i) orelse return Error.MalformedVector,
                    else => return Error.MalformedVector,
                };
                break :blk .{ .decimal = .{ .value = raw, .width = d.width, .scale = d.scale } };
            },
            .varchar, .string_literal, .char => blk: {
                const s = switch (self.storage) {
                    .strings => |ss| ss,
                    else => return Error.MalformedVector,
                };
                if (i >= s.len) return Error.MalformedVector;
                break :blk .{ .varchar = s[i] };
            },
            .blob, .bit, .bignum => blk: {
                const s = switch (self.storage) {
                    .strings => |ss| ss,
                    else => return Error.MalformedVector,
                };
                if (i >= s.len) return Error.MalformedVector;
                break :blk .{ .blob = s[i] };
            },
            // An ENUM cell stores a dictionary index; surface the label so
            // callers see the value rather than an opaque number.
            .@"enum" => blk: {
                const width = self.type.fixedWidth() orelse return Error.MalformedVector;
                const idx: usize = switch (width) {
                    1 => self.readFixed(u8, i) orelse return Error.MalformedVector,
                    2 => self.readFixed(u16, i) orelse return Error.MalformedVector,
                    4 => self.readFixed(u32, i) orelse return Error.MalformedVector,
                    else => return Error.MalformedVector,
                };
                if (idx >= self.type.enum_values.len) return Error.MalformedVector;
                break :blk .{ .@"enum" = .{
                    .index = @intCast(idx),
                    .label = self.type.enum_values[idx],
                } };
            },
            .sqlnull => .null,
            // Nested types are reachable through `children()` / `listSlice()`
            // rather than through the flat `Value` union, which cannot own the
            // nested storage. Returning an explicit error beats inventing a
            // lossy scalar representation (todo.md §10).
            else => Error.UnsupportedType,
        };
    }

    /// STRUCT field vectors, or null if this is not a struct.
    pub fn children(self: *const Vector) ?[]Vector {
        return switch (self.storage) {
            .children => |c| c,
            else => null,
        };
    }

    /// For a LIST vector, the (offset, length) window of row `i` into the child
    /// vector returned by `listChild`.
    pub fn listEntry(self: *const Vector, i: usize) ?ListEntry {
        const l = switch (self.storage) {
            .list => |l| l,
            else => return null,
        };
        if (i >= l.entries.len) return null;
        return l.entries[i];
    }

    pub fn listChild(self: *const Vector) ?*Vector {
        return switch (self.storage) {
            .list => |l| l.child,
            .array => |a| a.child,
            else => null,
        };
    }

    /// For an ARRAY vector, the fixed element count per row.
    pub fn arraySize(self: *const Vector) ?u64 {
        return switch (self.storage) {
            .array => |a| a.size,
            else => null,
        };
    }

    /// For a MAP vector, the key/value child vectors and row `i`'s window into
    /// them. MAP is physically `LIST(STRUCT(key, value))`, so this just unwraps
    /// that shape into something callers can use directly.
    pub fn mapEntry(self: *const Vector, i: usize) ?MapEntry {
        if (self.type.id != .map) return null;
        const window = self.listEntry(i) orelse return null;
        const entries = self.listChild() orelse return null;
        const kv = entries.children() orelse return null;
        if (kv.len < 2) return null;
        return .{
            .offset = window.offset,
            .length = window.length,
            .keys = &kv[0],
            .values = &kv[1],
        };
    }

    /// For a UNION vector, the active member of row `i`.
    ///
    /// DuckDB stores a UNION as a STRUCT whose child 0 is a UTINYINT tag and
    /// whose remaining children are the members; only the tagged one is valid.
    pub fn unionValue(self: *const Vector, i: usize) ?UnionMember {
        if (self.type.id != .@"union") return null;
        const kids = self.children() orelse return null;
        if (kids.len < 2) return null;
        const tag = kids[0].at(u8, i) orelse return null;
        const member_index: usize = tag;
        if (member_index + 1 >= kids.len) return null;
        const members = self.type.unionMembers();
        return .{
            .tag = tag,
            .name = if (member_index < members.len) members[member_index].name else "",
            .vector = &kids[member_index + 1],
        };
    }

    /// Sequence vectors carry no type tag of their own; map the i64 back onto
    /// the column's declared integer type.
    fn intValueFromI64(self: *const Vector, v: i64) Value {
        return switch (self.type.id) {
            .tinyint => .{ .tinyint = @truncate(v) },
            .smallint => .{ .smallint = @truncate(v) },
            .integer => .{ .integer = @truncate(v) },
            .utinyint => .{ .utinyint = @truncate(@as(u64, @bitCast(v))) },
            .usmallint => .{ .usmallint = @truncate(@as(u64, @bitCast(v))) },
            .uinteger => .{ .uinteger = @truncate(@as(u64, @bitCast(v))) },
            .ubigint => .{ .ubigint = @bitCast(v) },
            .date => .{ .date = @truncate(v) },
            .timestamp => .{ .timestamp = v },
            else => .{ .bigint = v },
        };
    }
};

const testing = std.testing;

test "flat integer vector exposes a zero-copy typed slice" {
    // Four i32 values: 1, 2, 3, 4 (little-endian), 4-byte aligned.
    const data align(4) = [_]u8{
        1, 0, 0, 0,
        2, 0, 0, 0,
        3, 0, 0, 0,
        4, 0, 0, 0,
    };
    var v = Vector{
        .type = .{ .id = .integer },
        .count = 4,
        .storage = .{ .fixed = &data },
    };
    const s = v.asSlice(i32) orelse return error.TestExpectedSlice;
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 4 }, s);
    // The slice must alias the input, not a copy.
    try testing.expectEqual(@intFromPtr(&data), @intFromPtr(s.ptr));
}

test "asSlice refuses a width mismatch instead of misreading" {
    const data align(8) = [_]u8{ 1, 0, 0, 0, 2, 0, 0, 0 };
    var v = Vector{ .type = .{ .id = .integer }, .count = 2, .storage = .{ .fixed = &data } };
    try testing.expectEqual(@as(?[]const i64, null), v.asSlice(i64));
    try testing.expect(v.asSlice(i32) != null);
}

test "getValue honours the validity mask" {
    const data align(4) = [_]u8{ 10, 0, 0, 0, 20, 0, 0, 0 };
    const mask = [_]u8{0b0000_0010}; // row 0 null, row 1 valid
    var v = Vector{
        .type = .{ .id = .integer },
        .count = 2,
        .validity = ValidityMask.init(&mask, 2),
        .storage = .{ .fixed = &data },
    };
    try testing.expect((try v.getValue(0)).isNull());
    try testing.expectEqual(@as(i32, 20), (try v.getValue(1)).integer);
}

test "constant vector repeats one value without expanding" {
    const data align(4) = [_]u8{ 42, 0, 0, 0 };
    var child = Vector{ .type = .{ .id = .integer }, .count = 1, .storage = .{ .fixed = &data } };
    var v = Vector{
        .type = .{ .id = .integer },
        .count = 1000,
        .storage = .{ .constant = &child },
    };
    try testing.expectEqual(@as(i32, 42), (try v.getValue(0)).integer);
    try testing.expectEqual(@as(i32, 42), (try v.getValue(999)).integer);
    try testing.expectError(Error.MalformedVector, v.getValue(1000));
}

test "sequence vector computes values arithmetically" {
    var v = Vector{
        .type = .{ .id = .bigint },
        .count = 100,
        .storage = .{ .sequence = .{ .start = 10, .increment = 5 } },
    };
    try testing.expectEqual(@as(i64, 10), (try v.getValue(0)).bigint);
    try testing.expectEqual(@as(i64, 15), (try v.getValue(1)).bigint);
    try testing.expectEqual(@as(i64, 505), (try v.getValue(99)).bigint);
}

test "dictionary vector resolves through its index array" {
    const data align(4) = [_]u8{ 7, 0, 0, 0, 9, 0, 0, 0 };
    var child = Vector{ .type = .{ .id = .integer }, .count = 2, .storage = .{ .fixed = &data } };
    const idx = [_]u32{ 1, 0, 1 };
    var v = Vector{
        .type = .{ .id = .integer },
        .count = 3,
        .storage = .{ .dictionary = .{ .indices = &idx, .child = &child } },
    };
    try testing.expectEqual(@as(i32, 9), (try v.getValue(0)).integer);
    try testing.expectEqual(@as(i32, 7), (try v.getValue(1)).integer);
    try testing.expectEqual(@as(i32, 9), (try v.getValue(2)).integer);
}

test "truncated fixed payload errors rather than reading past the end" {
    const data align(4) = [_]u8{ 1, 0, 0 }; // 3 bytes but claims one i32
    var v = Vector{ .type = .{ .id = .integer }, .count = 1, .storage = .{ .fixed = &data } };
    try testing.expectError(Error.MalformedVector, v.getValue(0));
}

test "a payload too short for the row count is not treated as flat" {
    // `at` and `asSlice` trust `isFlat` to have checked the payload length.
    // If a short buffer passed that check, both would read past its end.
    const data align(8) = [_]u8{ 1, 0, 0, 0 }; // 4 bytes = one i32
    var v = Vector{ .type = .{ .id = .integer }, .count = 4, .storage = .{ .fixed = &data } };

    try testing.expect(!v.isFlat(i32));
    try testing.expectEqual(@as(?[]const i32, null), v.asSlice(i32));
    try testing.expectEqual(@as(?i32, null), v.at(i32, 0));
    var out: [4]i32 = undefined;
    try testing.expectEqual(@as(?usize, null), v.copySlice(i32, &out));

    // With a payload that does cover the rows, all three work.
    const full align(8) = [_]u8{ 1, 0, 0, 0, 2, 0, 0, 0 };
    var ok = Vector{ .type = .{ .id = .integer }, .count = 2, .storage = .{ .fixed = &full } };
    try testing.expect(ok.isFlat(i32));
    try testing.expectEqual(@as(?i32, 2), ok.at(i32, 1));
}

test "at() reads flat values regardless of buffer alignment" {
    // Deliberately offset by one byte so the i32 run is misaligned, which is
    // the normal case on the wire.
    const backing align(8) = [_]u8{ 0xAA, 1, 0, 0, 0, 2, 0, 0, 0 };
    const data = backing[1..];
    var v = Vector{ .type = .{ .id = .integer }, .count = 2, .storage = .{ .fixed = data } };
    // asSlice must refuse this buffer...
    try testing.expectEqual(@as(?[]const i32, null), v.asSlice(i32));
    // ...but at() still reads it correctly.
    try testing.expectEqual(@as(?i32, 1), v.at(i32, 0));
    try testing.expectEqual(@as(?i32, 2), v.at(i32, 1));
    try testing.expectEqual(@as(?i32, null), v.at(i32, 2));
    try testing.expect(v.isFlat(i32));
}

test "copySlice bulk-copies an unaligned column" {
    const backing align(8) = [_]u8{ 0xAA, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0 };
    const data = backing[1..];
    var v = Vector{ .type = .{ .id = .integer }, .count = 3, .storage = .{ .fixed = data } };
    var out: [3]i32 = undefined;
    const n = v.copySlice(i32, &out) orelse return error.TestExpectedCopy;
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, &out);
}

test "copySlice and at reject a width mismatch" {
    const data align(8) = [_]u8{ 1, 0, 0, 0 };
    var v = Vector{ .type = .{ .id = .integer }, .count = 1, .storage = .{ .fixed = &data } };
    var out: [1]i64 = undefined;
    try testing.expectEqual(@as(?usize, null), v.copySlice(i64, &out));
    try testing.expectEqual(@as(?i64, null), v.at(i64, 0));
}

test "out of range row index is an error, not a panic" {
    const data align(4) = [_]u8{ 1, 0, 0, 0 };
    var v = Vector{ .type = .{ .id = .integer }, .count = 1, .storage = .{ .fixed = &data } };
    try testing.expectError(Error.MalformedVector, v.getValue(5));
    try testing.expect(v.isNull(5));
}
