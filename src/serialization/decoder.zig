//! Decodes DuckDB `LogicalType`, `Vector` and `DataChunk` objects from the wire.
//!
//! This is the part of the client that touches untrusted bytes, so it follows
//! two rules without exception (todo.md §21, §22):
//!
//!   1. Every read goes through `Reader`, which is bounds-checked.
//!   2. Nothing is `@ptrCast` from wire data into a struct. Fixed-width payloads
//!      are kept as byte slices and read with explicit little-endian loads.
//!
//! Unknown-but-plausible constructs produce a typed error rather than a guess.

const std = @import("std");
const reader_mod = @import("reader.zig");
const lt = @import("../types/logical_type.zig");
const vector_mod = @import("../types/vector.zig");
const validity_mod = @import("../types/validity.zig");
const data_chunk_mod = @import("../types/data_chunk.zig");

const Reader = reader_mod.Reader;
const LogicalType = lt.LogicalType;
const LogicalTypeId = lt.LogicalTypeId;
const Vector = vector_mod.Vector;
const VectorType = vector_mod.VectorType;
const ValidityMask = validity_mod.ValidityMask;
const DataChunk = data_chunk_mod.DataChunk;

pub const Error = reader_mod.Error || vector_mod.Error || std.mem.Allocator.Error || error{
    UnexpectedField,
    RowCountTooLarge,
};

// -- field ids (protocol constants, kept together for §23) -------------------

const ty_id: u16 = 100;
const ty_info: u16 = 101;

const eti_type: u16 = 100;
const eti_alias: u16 = 101;
const eti_extension: u16 = 103;
const eti_decimal_width: u16 = 200;
const eti_decimal_scale: u16 = 201;
const eti_child_type: u16 = 200;
const eti_child_types: u16 = 200;
const eti_array_size: u16 = 201;
const eti_enum_values_count: u16 = 200;
const eti_enum_values: u16 = 201;

const vec_type: u16 = 90;
const vec_sel: u16 = 91;
const vec_dict_count: u16 = 92;
const vec_seq_start: u16 = 91;
const vec_seq_increment: u16 = 92;
const vec_has_validity: u16 = 100;
const vec_validity: u16 = 101;
const vec_data: u16 = 102;
const vec_children: u16 = 103;
const vec_array_size: u16 = 103;
const vec_array_child: u16 = 104;
const vec_list_size: u16 = 104;
const vec_list_entries: u16 = 105;
const vec_list_child: u16 = 106;

const chunk_rows: u16 = 100;
const chunk_types: u16 = 101;
const chunk_columns: u16 = 102;

/// Wrapper field that boxes a DataChunk (`DataChunkWrapper`).
pub const chunk_wrapper_field: u16 = 300;

const term = reader_mod.message_terminator;

// -- LogicalType --------------------------------------------------------------

pub fn decodeLogicalType(r: *Reader, allocator: std.mem.Allocator) Error!LogicalType {
    try r.enterObject();
    defer r.leaveObject();

    var result = LogicalType{ .id = .invalid };
    errdefer result.deinit(allocator);

    while (true) {
        const f = try r.readFieldId();
        if (f == term) break;
        switch (f) {
            ty_id => result.id = @fromBackingInt(@intCast(try r.readUVarInt(u8))),
            ty_info => {
                // unique_ptr<ExtraTypeInfo>: present byte, then the object.
                const present = try r.readBool();
                if (present) try decodeExtraTypeInfo(r, allocator, &result);
            },
            else => return Error.UnexpectedField,
        }
    }
    return result;
}

fn decodeExtraTypeInfo(r: *Reader, allocator: std.mem.Allocator, out: *LogicalType) Error!void {
    try r.enterObject();
    defer r.leaveObject();

    var info_type: lt.ExtraTypeInfoType = .invalid;
    while (true) {
        const f = try r.readFieldId();
        if (f == term) break;
        switch (f) {
            eti_type => info_type = @fromBackingInt(@intCast(try r.readUVarInt(u8))),
            eti_alias => out.alias = try r.readString(),
            eti_extension => {
                // unique_ptr<ExtensionTypeInfo>; skip when absent.
                const present = try r.readBool();
                if (present) try skipObject(r);
            },
            // Subtype payloads. Field ids overlap between subtypes, so the
            // meaning is resolved via `info_type` (which always precedes them).
            // Field 200 is overloaded across subtypes; `info_type` (field 100,
            // always written first) selects the meaning.
            eti_decimal_width => switch (info_type) {
                .decimal => {
                    const width = try r.readUVarInt(u8);
                    out.decimal = .{ .width = width, .scale = 0 };
                },
                // LIST and MAP share ListTypeInfo. For MAP the child is the
                // STRUCT(key, value) entry type.
                .list, .array => try decodeSingleChild(r, allocator, out),
                // STRUCT and UNION share StructTypeInfo. A UNION's first child
                // is the hidden UTINYINT tag.
                .@"struct" => try decodeStructChildren(r, allocator, out),
                .enum_ => out.enum_count_hint = try r.readUVarInt(u64),
                // STRING/GENERIC/etc. carry no payload we need; anything else
                // is a construct this version does not model.
                else => return Error.UnsupportedType,
            },
            eti_decimal_scale => switch (info_type) {
                .decimal => {
                    const scale = try r.readUVarInt(u8);
                    if (out.decimal) |*d| d.scale = scale else out.decimal = .{ .width = 18, .scale = scale };
                },
                .array => out.array_size = try r.readUVarInt(u64),
                .enum_ => try decodeEnumValues(r, allocator, out),
                else => return Error.UnsupportedType,
            },
            else => return Error.UnexpectedField,
        }
    }
}

/// LIST / MAP / ARRAY all carry exactly one child type in field 200.
fn decodeSingleChild(r: *Reader, allocator: std.mem.Allocator, out: *LogicalType) Error!void {
    var child = try decodeLogicalType(r, allocator);
    errdefer child.deinit(allocator);
    const children = try allocator.alloc(LogicalType.Child, 1);
    // Malformed input can repeat a field; release anything already attached so
    // the second decode does not orphan the first.
    freeChildren(allocator, out);
    children[0] = .{ .name = "", .type = child };
    out.children = children;
}

/// Release any children already attached to `out`, leaving it empty.
fn freeChildren(allocator: std.mem.Allocator, out: *LogicalType) void {
    if (out.children.len == 0) return;
    for (out.children) |*c| c.type.deinit(allocator);
    allocator.free(out.children);
    out.children = &.{};
}

/// ENUM dictionary: a list of the labels, in declaration order. The strings
/// borrow the response buffer; only the slice array is allocated.
fn decodeEnumValues(r: *Reader, allocator: std.mem.Allocator, out: *LogicalType) Error!void {
    if (out.enum_values.len > 0) {
        allocator.free(out.enum_values);
        out.enum_values = &.{};
    }
    const n = try r.readListLength();
    const values = try allocator.alloc([]const u8, n);
    errdefer allocator.free(values);
    for (values) |*v| v.* = try r.readString();
    // The count in field 200 must agree with the list we actually read,
    // otherwise the physical width we derive from it would be wrong.
    if (out.enum_count_hint) |declared| {
        if (declared != n) return Error.MalformedVector;
    }
    out.enum_values = values;
}

fn decodeStructChildren(r: *Reader, allocator: std.mem.Allocator, out: *LogicalType) Error!void {
    freeChildren(allocator, out);
    const n = try r.readListLength();
    const children = try allocator.alloc(LogicalType.Child, n);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) children[i].type.deinit(allocator);
        allocator.free(children);
    }
    // child_list_t<LogicalType> is a list of pair<string, LogicalType>, and a
    // pair serialises as an object with fields 0 and 1.
    for (children) |*c| {
        try r.enterObject();
        defer r.leaveObject();
        var name: []const u8 = "";
        var child_type = LogicalType{ .id = .invalid };
        // The pair is only committed to `children` once fully read, so an
        // error mid-pair must free the child decoded so far. The outer errdefer
        // cannot see it yet - `filled` has not been bumped.
        errdefer child_type.deinit(allocator);
        while (true) {
            const f = try r.readFieldId();
            if (f == term) break;
            switch (f) {
                0 => name = try r.readString(),
                1 => {
                    // A duplicate field 1 would strand the first child.
                    child_type.deinit(allocator);
                    child_type = try decodeLogicalType(r, allocator);
                },
                else => return Error.UnexpectedField,
            }
        }
        c.* = .{ .name = name, .type = child_type };
        filled += 1;
    }
    out.children = children;
}

/// Step over an object we do not model, without interpreting its fields.
/// Only safe for objects known to be empty or terminator-only; anything else
/// is rejected so we never silently mis-parse.
fn skipObject(r: *Reader) Error!void {
    try r.enterObject();
    defer r.leaveObject();
    const f = try r.readFieldId();
    if (f != term) return Error.UnsupportedType;
}

// -- Vector -------------------------------------------------------------------

pub fn decodeVector(
    r: *Reader,
    allocator: std.mem.Allocator,
    vtype: LogicalType,
    count: usize,
) Error!Vector {
    try r.enterObject();
    defer r.leaveObject();
    var v = try decodeVectorFields(r, allocator, vtype, count);
    errdefer v.deinit();
    try r.expectTerminator();
    return v;
}

/// Decode a vector's fields up to (but not consuming) its terminator.
///
/// Split out from `decodeVector` because a CONSTANT vector nests a second
/// vector body inside the same object: field 90 says CONSTANT, and the single
/// value's fields follow directly, sharing the parent's terminator.
fn decodeVectorFields(
    r: *Reader,
    allocator: std.mem.Allocator,
    vtype: LogicalType,
    count: usize,
) Error!Vector {
    var result = Vector{
        .type = vtype,
        .count = count,
        .storage = .unsupported,
        .allocator = allocator,
    };
    errdefer result.deinit();

    var kind: VectorType = .flat;
    var sel_bytes: ?[]const u8 = null;
    var seq_start: i64 = 0;

    while (true) {
        const f = try r.peekFieldId();
        if (f == term) break;
        _ = try r.readFieldId();

        switch (f) {
            vec_type => {
                kind = @fromBackingInt(@intCast(try r.readUVarInt(u8)));
                switch (kind) {
                    // DuckDB never emits FSST on the wire: `Vector::Serialize`
                    // has no FSST branch, so such a vector falls through to
                    // `ToUnifiedFormat` and is flattened before sending
                    // (duckdb/src/common/types/vector.cpp, the
                    // "TODO: other compressed vector types (FSST)" fallthrough).
                    // If that ever changes we want a loud error, not a guess at
                    // an undocumented symbol table.
                    .fsst => return Error.UnsupportedVectorType,
                    .constant => {
                        // The one stored value follows inline, count = 1.
                        const child = try allocator.create(Vector);
                        errdefer allocator.destroy(child);
                        child.* = try decodeVectorFields(r, allocator, vtype, 1);
                        result.storage = .{ .constant = child };
                        return result;
                    },
                    else => {},
                }
            },

            // Field 91/92 are overloaded: dictionary selection vs sequence bounds.
            vec_sel => switch (kind) {
                .dictionary => sel_bytes = try r.readBytes(),
                .sequence => seq_start = try r.readIVarInt(i64),
                else => return Error.UnexpectedField,
            },
            vec_dict_count => switch (kind) {
                .dictionary => {
                    const dc = try r.readUVarInt(u64);
                    if (dc > r.limits.max_list_length) return Error.LengthLimitExceeded;
                    try finishDictionary(r, allocator, &result, sel_bytes, @intCast(dc), count);
                },
                .sequence => {
                    const inc = try r.readIVarInt(i64);
                    result.storage = .{ .sequence = .{ .start = seq_start, .increment = inc } };
                },
                else => return Error.UnexpectedField,
            },

            // Field 100 only announces whether field 101 follows. A vector
            // starts out all-valid, so there is nothing to do when it is
            // false - the mask itself is installed by `vec_validity`.
            vec_has_validity => _ = try r.readBool(),
            vec_validity => {
                const bytes = try r.readBytes();
                result.validity = ValidityMask.init(bytes, count);
            },
            vec_data => try decodeVectorData(r, allocator, &result, count),

            // 103 is STRUCT/UNION `children`, or ARRAY `array_size`.
            vec_children => {
                if (result.type.physicalShape() == .array) {
                    result.array_size_hint = try r.readUVarInt(u64);
                } else {
                    try decodeStructVector(r, allocator, &result, count);
                }
            },
            // 104 is ARRAY `child`, or LIST/MAP `list_size`.
            vec_array_child => {
                if (result.type.physicalShape() == .array) {
                    const asize = result.array_size_hint orelse return Error.MalformedVector;
                    const child_count = std.math.mul(usize, @intCast(asize), count) catch
                        return Error.RowCountTooLarge;
                    const child = try allocator.create(Vector);
                    errdefer allocator.destroy(child);
                    child.* = try decodeVector(r, allocator, elementType(result.type), child_count);
                    result.storage = .{ .array = .{ .size = asize, .child = child } };
                } else {
                    result.list_size_hint = try r.readUVarInt(u64);
                }
            },
            vec_list_entries => try decodeListEntries(r, allocator, &result, count),
            vec_list_child => {
                const lsize = result.list_size_hint orelse return Error.MalformedVector;
                if (lsize > r.limits.max_list_length) return Error.LengthLimitExceeded;
                const child = try allocator.create(Vector);
                errdefer allocator.destroy(child);
                child.* = try decodeVector(r, allocator, elementType(result.type), @intCast(lsize));
                const entries = result.pending_entries orelse return Error.MalformedVector;
                result.pending_entries = null;
                result.storage = .{ .list = .{ .entries = entries, .child = child } };
            },

            else => return Error.UnexpectedField,
        }
    }

    return result;
}

fn decodeVectorData(
    r: *Reader,
    allocator: std.mem.Allocator,
    result: *Vector,
    count: usize,
) Error!void {
    switch (result.type.physicalShape()) {
        .fixed => {
            const width = result.type.fixedWidth() orelse return Error.UnsupportedType;
            const declared = try r.readLength();
            const expected = std.math.mul(usize, width, count) catch return Error.RowCountTooLarge;
            if (declared != expected) return Error.MalformedVector;
            result.storage = .{ .fixed = try r.readRaw(declared) };
        },
        .variable => {
            const n = try r.readListLength();
            if (n != count) return Error.MalformedVector;
            const slices = try allocator.alloc([]const u8, n);
            errdefer allocator.free(slices);
            for (slices) |*s| s.* = try r.readString();
            result.storage = .{ .strings = slices };
        },
        else => return Error.UnsupportedType,
    }
}

/// The element type of a LIST/MAP/ARRAY child vector.
fn elementType(t: LogicalType) LogicalType {
    if (t.children.len > 0) return t.children[0].type;
    return .{ .id = .invalid };
}

fn decodeStructVector(
    r: *Reader,
    allocator: std.mem.Allocator,
    result: *Vector,
    count: usize,
) Error!void {
    const n = try r.readListLength();
    const kids = try allocator.alloc(Vector, n);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) kids[i].deinit();
        allocator.free(kids);
    }
    for (kids, 0..) |*kid, i| {
        const child_type = if (i < result.type.children.len)
            result.type.children[i].type
        else
            LogicalType{ .id = .invalid };
        kid.* = try decodeVector(r, allocator, child_type, count);
        filled += 1;
    }
    result.storage = .{ .children = kids };
}

fn decodeListEntries(
    r: *Reader,
    allocator: std.mem.Allocator,
    result: *Vector,
    count: usize,
) Error!void {
    const n = try r.readListLength();
    if (n != count) return Error.MalformedVector;
    const entries = try allocator.alloc(vector_mod.ListEntry, n);
    errdefer allocator.free(entries);
    for (entries) |*e| {
        try r.enterObject();
        defer r.leaveObject();
        var off: u64 = 0;
        var len: u64 = 0;
        while (true) {
            const f = try r.readFieldId();
            if (f == term) break;
            switch (f) {
                100 => off = try r.readUVarInt(u64),
                101 => len = try r.readUVarInt(u64),
                else => return Error.UnexpectedField,
            }
        }
        e.* = .{ .offset = off, .length = len };
    }
    result.pending_entries = entries;
}

fn finishDictionary(
    r: *Reader,
    allocator: std.mem.Allocator,
    result: *Vector,
    sel_bytes: ?[]const u8,
    dict_count: usize,
    count: usize,
) Error!void {
    const sel = sel_bytes orelse return Error.MalformedVector;
    // sel_t is uint32.
    if (sel.len < count * 4) return Error.MalformedVector;
    const indices = try allocator.alloc(u32, count);
    errdefer allocator.free(indices);
    for (indices, 0..) |*ix, i| {
        const v = std.mem.readInt(u32, sel[i * 4 ..][0..4], .little);
        if (v >= dict_count) return Error.MalformedVector;
        ix.* = v;
    }
    const child = try allocator.create(Vector);
    errdefer allocator.destroy(child);
    child.* = try decodeVector(r, allocator, result.type, dict_count);
    result.storage = .{ .dictionary = .{ .indices = indices, .child = child } };
}

// -- DataChunk ----------------------------------------------------------------

/// Decode a `DataChunkWrapper` (field 300 -> DataChunk object).
pub fn decodeChunkWrapper(r: *Reader, allocator: std.mem.Allocator) Error!DataChunk {
    try r.enterObject();
    defer r.leaveObject();

    var chunk: ?DataChunk = null;
    errdefer if (chunk) |*c| c.deinit();

    while (true) {
        const f = try r.readFieldId();
        if (f == term) break;
        switch (f) {
            chunk_wrapper_field => chunk = try decodeDataChunk(r, allocator),
            else => return Error.UnexpectedField,
        }
    }
    return chunk orelse Error.MalformedVector;
}

pub fn decodeDataChunk(r: *Reader, allocator: std.mem.Allocator) Error!DataChunk {
    try r.enterObject();
    defer r.leaveObject();

    var row_count: usize = 0;
    var types: []LogicalType = &.{};
    var types_filled: usize = 0;
    var columns: []Vector = &.{};
    var cols_filled: usize = 0;

    // The chunk takes ownership of `types` on success. Until then this scope
    // owns them, so an early return frees them exactly once.
    errdefer {
        var i: usize = 0;
        while (i < types_filled) : (i += 1) types[i].deinit(allocator);
        if (types.len > 0) allocator.free(types);
        var j: usize = 0;
        while (j < cols_filled) : (j += 1) columns[j].deinit();
        if (columns.len > 0) allocator.free(columns);
    }

    while (true) {
        const f = try r.readFieldId();
        if (f == term) break;
        switch (f) {
            // `rows` is a sel_t (uint32) and is omitted when zero.
            chunk_rows => {
                const rc = try r.readUVarInt(u32);
                if (rc > data_chunk_mod.standard_vector_size) return Error.RowCountTooLarge;
                row_count = rc;
            },
            chunk_types => {
                const n = try r.readListLength();
                types = try allocator.alloc(LogicalType, n);
                for (types) |*t| {
                    t.* = try decodeLogicalType(r, allocator);
                    types_filled += 1;
                }
            },
            chunk_columns => {
                const n = try r.readListLength();
                if (n != types_filled) return Error.MalformedVector;
                columns = try allocator.alloc(Vector, n);
                for (columns, 0..) |*c, i| {
                    c.* = try decodeVector(r, allocator, types[i], row_count);
                    cols_filled += 1;
                }
            },
            else => return Error.UnexpectedField,
        }
    }

    return DataChunk{
        .allocator = allocator,
        .columns = if (columns.len > 0) columns else &.{},
        .row_count = row_count,
        .types = types,
    };
}
