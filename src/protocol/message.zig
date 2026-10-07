//! Quack message encoding and decoding.
//!
//! An HTTP body is two consecutive top-level objects: a `MessageHeader` and then
//! the body, whose shape is selected by `header.type`. See `docs/PROTOCOL.md` §2.

const std = @import("std");
const reader_mod = @import("../serialization/reader.zig");
const writer_mod = @import("../serialization/writer.zig");
const decoder = @import("../serialization/decoder.zig");
const encoder = @import("../serialization/encoder.zig");
const compat = @import("compat.zig");
const lt = @import("../types/logical_type.zig");
const data_chunk_mod = @import("../types/data_chunk.zig");

const Reader = reader_mod.Reader;
const Writer = writer_mod.Writer;
const LogicalType = lt.LogicalType;
const DataChunk = data_chunk_mod.DataChunk;
const term = reader_mod.message_terminator;

pub const Error = decoder.Error || error{
    UnknownMessageType,
    /// A response arrived whose type is not valid in this position.
    UnexpectedMessageType,
};

/// Wire values for `MessageType`. 5 and 6 are unused in the current protocol.
pub const MessageType = enum(u8) {
    invalid = 0,
    connection_request = 1,
    connection_response = 2,
    prepare_request = 3,
    prepare_response = 4,
    fetch_request = 7,
    fetch_response = 8,
    append_request = 9,
    success_response = 10,
    disconnect_message = 11,
    error_response = 100,
    _,

    pub fn name(self: MessageType) []const u8 {
        return switch (self) {
            .invalid => "INVALID",
            .connection_request => "CONNECTION_REQUEST",
            .connection_response => "CONNECTION_RESPONSE",
            .prepare_request => "PREPARE_REQUEST",
            .prepare_response => "PREPARE_RESPONSE",
            .fetch_request => "FETCH_REQUEST",
            .fetch_response => "FETCH_RESPONSE",
            .append_request => "APPEND_REQUEST",
            .success_response => "SUCCESS_RESPONSE",
            .disconnect_message => "DISCONNECT_MESSAGE",
            .error_response => "ERROR_RESPONSE",
            else => "UNKNOWN",
        };
    }
};

// -- header -------------------------------------------------------------------

const hdr_type: u16 = 1;
const hdr_connection_id: u16 = 2;
const hdr_client_query_id: u16 = 3;

pub const MessageHeader = struct {
    type: MessageType,
    /// Borrowed from the response buffer when decoded.
    connection_id: []const u8 = "",
    client_query_id: ?u64 = null,

    pub fn encode(self: MessageHeader, w: *Writer) !void {
        // field 1 is a plain WriteProperty: always emitted.
        try w.writePropertyUVarInt(hdr_type, @backingInt(self.type));
        // field 2 is WritePropertyWithDefault: omitted when empty.
        try w.writePropertyStringWithDefault(hdr_connection_id, self.connection_id);
        // field 3 is a plain WriteProperty of optional_idx: always emitted,
        // with UINT64_MAX standing in for "unset".
        try w.writePropertyOptionalIdx(hdr_client_query_id, self.client_query_id);
        try w.writeTerminator();
    }

    pub fn decode(r: *Reader) Error!MessageHeader {
        try r.enterObject();
        defer r.leaveObject();

        var h = MessageHeader{ .type = .invalid };
        while (true) {
            const f = try r.readFieldId();
            if (f == term) break;
            switch (f) {
                hdr_type => h.type = @fromBackingInt(@intCast(try r.readUVarInt(u8))),
                hdr_connection_id => h.connection_id = try r.readString(),
                hdr_client_query_id => h.client_query_id = try r.readOptionalIdx(),
                else => return Error.UnexpectedField,
            }
        }
        return h;
    }
};

// -- requests -----------------------------------------------------------------

pub const ConnectionRequest = struct {
    auth_string: []const u8,
    client_duckdb_version: []const u8 = compat.client_version_string,
    client_platform: []const u8 = compat.client_platform,
    min_version: u64 = compat.min_supported_version,
    max_version: u64 = compat.max_supported_version,

    pub fn encode(self: ConnectionRequest, w: *Writer) !void {
        try w.writePropertyStringWithDefault(1, self.auth_string);
        try w.writePropertyStringWithDefault(2, self.client_duckdb_version);
        try w.writePropertyStringWithDefault(3, self.client_platform);
        try w.writePropertyUVarIntWithDefault(4, self.min_version);
        try w.writePropertyUVarIntWithDefault(5, self.max_version);
        try w.writeTerminator();
    }
};

pub const PrepareRequest = struct {
    sql: []const u8,

    pub fn encode(self: PrepareRequest, w: *Writer) !void {
        try w.writePropertyStringWithDefault(1, self.sql);
        try w.writeTerminator();
    }
};

pub const FetchRequest = struct {
    uuid: i128,

    pub fn encode(self: FetchRequest, w: *Writer) !void {
        // hugeint_t is WritePropertyWithDefault; zero would be omitted.
        if (self.uuid != 0) try w.writePropertyHugeInt(1, self.uuid);
        try w.writeTerminator();
    }
};

/// Bulk-insert a chunk into an existing table.
///
/// The server requires the table to exist and the chunk's types to match its
/// columns; it appends via `ColumnDataCollection` and replies SUCCESS_RESPONSE
/// (`quack_server.cpp`).
pub const AppendRequest = struct {
    schema_name: []const u8 = "main",
    table_name: []const u8,
    columns: []const encoder.Column,
    allocator: std.mem.Allocator,

    pub fn encode(self: AppendRequest, w: *Writer) !void {
        try w.writePropertyStringWithDefault(1, self.schema_name);
        try w.writePropertyStringWithDefault(2, self.table_name);
        // field 3 is a unique_ptr<DataChunkWrapper>: present byte, then object.
        try w.writeFieldId(3);
        try w.writeBool(true);
        try encoder.encodeChunkWrapper(self.allocator, w, self.columns);
        try w.writeTerminator();
    }
};

pub const DisconnectRequest = struct {
    pub fn encode(_: DisconnectRequest, w: *Writer) !void {
        try w.writeTerminator();
    }
};

// -- responses ----------------------------------------------------------------

pub const ConnectionResponse = struct {
    server_duckdb_version: []const u8 = "",
    server_platform: []const u8 = "",
    quack_version: u64 = 0,

    pub fn decode(r: *Reader) Error!ConnectionResponse {
        try r.enterObject();
        defer r.leaveObject();
        var m = ConnectionResponse{};
        while (true) {
            const f = try r.readFieldId();
            if (f == term) break;
            switch (f) {
                1 => m.server_duckdb_version = try r.readString(),
                2 => m.server_platform = try r.readString(),
                3 => m.quack_version = try r.readUVarInt(u64),
                else => return Error.UnexpectedField,
            }
        }
        return m;
    }
};

pub const ErrorResponse = struct {
    message: []const u8 = "",

    pub fn decode(r: *Reader) Error!ErrorResponse {
        try r.enterObject();
        defer r.leaveObject();
        var m = ErrorResponse{};
        while (true) {
            const f = try r.readFieldId();
            if (f == term) break;
            switch (f) {
                1 => m.message = try r.readString(),
                else => return Error.UnexpectedField,
            }
        }
        return m;
    }
};

/// Column metadata plus the first batch of chunks.
///
/// Owns `types`, `names` and `chunks`; the string bytes inside borrow the
/// response buffer, so this must not outlive it.
pub const PrepareResponse = struct {
    allocator: std.mem.Allocator,
    types: []LogicalType = &.{},
    names: [][]const u8 = &.{},
    needs_more_fetch: bool = false,
    chunks: []DataChunk = &.{},
    result_uuid: i128 = 0,

    pub fn deinit(self: *PrepareResponse) void {
        for (self.types) |*t| t.deinit(self.allocator);
        if (self.types.len > 0) self.allocator.free(self.types);
        if (self.names.len > 0) self.allocator.free(self.names);
        for (self.chunks) |*c| c.deinit();
        if (self.chunks.len > 0) self.allocator.free(self.chunks);
        self.types = &.{};
        self.names = &.{};
        self.chunks = &.{};
    }

    pub fn decode(r: *Reader, allocator: std.mem.Allocator) Error!PrepareResponse {
        try r.enterObject();
        defer r.leaveObject();

        var m = PrepareResponse{ .allocator = allocator };
        errdefer m.deinit();

        while (true) {
            const f = try r.readFieldId();
            if (f == term) break;
            switch (f) {
                1 => m.types = try decodeTypeList(r, allocator),
                2 => {
                    const n = try r.readListLength();
                    const names = try allocator.alloc([]const u8, n);
                    errdefer allocator.free(names);
                    for (names) |*name| name.* = try r.readString();
                    m.names = names;
                },
                3 => m.needs_more_fetch = try r.readBool(),
                4 => m.chunks = try decodeChunkList(r, allocator),
                5 => m.result_uuid = try r.readHugeInt(),
                else => return Error.UnexpectedField,
            }
        }
        return m;
    }
};

pub const FetchResponse = struct {
    allocator: std.mem.Allocator,
    chunks: []DataChunk = &.{},
    batch_index: ?u64 = null,

    pub fn deinit(self: *FetchResponse) void {
        for (self.chunks) |*c| c.deinit();
        if (self.chunks.len > 0) self.allocator.free(self.chunks);
        self.chunks = &.{};
    }

    pub fn decode(r: *Reader, allocator: std.mem.Allocator) Error!FetchResponse {
        try r.enterObject();
        defer r.leaveObject();

        var m = FetchResponse{ .allocator = allocator };
        errdefer m.deinit();

        while (true) {
            const f = try r.readFieldId();
            if (f == term) break;
            switch (f) {
                1 => m.chunks = try decodeChunkList(r, allocator),
                2 => m.batch_index = try r.readOptionalIdx(),
                else => return Error.UnexpectedField,
            }
        }
        return m;
    }
};

// -- shared list decoding -----------------------------------------------------
//
// Both PREPARE_RESPONSE and FETCH_RESPONSE carry
// `vector<unique_ptr<DataChunkWrapper>>`. Decoding is factored out so the
// partial-failure cleanup lives in exactly one place.

fn decodeTypeList(r: *Reader, allocator: std.mem.Allocator) Error![]LogicalType {
    const n = try r.readListLength();
    const types = try allocator.alloc(LogicalType, n);
    var filled: usize = 0;
    errdefer {
        for (types[0..filled]) |*t| t.deinit(allocator);
        allocator.free(types);
    }
    for (types) |*t| {
        t.* = try decoder.decodeLogicalType(r, allocator);
        filled += 1;
    }
    return types;
}

fn decodeChunkList(r: *Reader, allocator: std.mem.Allocator) Error![]DataChunk {
    const n = try r.readListLength();
    const chunks = try allocator.alloc(DataChunk, n);
    var filled: usize = 0;
    errdefer {
        for (chunks[0..filled]) |*c| c.deinit();
        allocator.free(chunks);
    }
    for (0..n) |_| {
        // vector<unique_ptr<T>>: a present byte precedes each element.
        const present = try r.readBool();
        if (!present) continue;
        chunks[filled] = try decoder.decodeChunkWrapper(r, allocator);
        filled += 1;
    }
    // A null element leaves a shorter list than the wire count; shrink so the
    // caller never sees an uninitialised chunk.
    return allocator.realloc(chunks, filled) catch chunks[0..filled];
}

// -- framing ------------------------------------------------------------------

/// Encode `header` + `body` into `buf`, replacing its contents.
pub fn encodeMessage(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    header: MessageHeader,
    body: anytype,
) !void {
    buf.clearRetainingCapacity();
    var w = Writer.init(allocator, buf);
    try header.encode(&w);
    try body.encode(&w);
}

const testing = std.testing;

test "header roundtrips through encode and decode" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    const h = MessageHeader{
        .type = .prepare_request,
        .connection_id = "ABC123",
        .client_query_id = 7,
    };
    try h.encode(&w);

    var r = Reader.init(buf.items);
    const got = try MessageHeader.decode(&r);
    try testing.expectEqual(MessageType.prepare_request, got.type);
    try testing.expectEqualStrings("ABC123", got.connection_id);
    try testing.expectEqual(@as(?u64, 7), got.client_query_id);
}

test "empty connection id is omitted but decodes back to empty" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    try (MessageHeader{ .type = .connection_request }).encode(&w);

    // type(2+1) + client_query_id(2+10) + terminator(2) = 17 bytes, no conn id.
    try testing.expectEqual(@as(usize, 17), buf.items.len);

    var r = Reader.init(buf.items);
    const got = try MessageHeader.decode(&r);
    try testing.expectEqualStrings("", got.connection_id);
    try testing.expectEqual(@as(?u64, null), got.client_query_id);
}

test "message type wire values match DuckDB" {
    try testing.expectEqual(@as(u8, 1), @backingInt(MessageType.connection_request));
    try testing.expectEqual(@as(u8, 4), @backingInt(MessageType.prepare_response));
    try testing.expectEqual(@as(u8, 7), @backingInt(MessageType.fetch_request));
    try testing.expectEqual(@as(u8, 100), @backingInt(MessageType.error_response));
}

test "connection request encodes the exact bytes the server accepted" {
    // This byte sequence was verified against a live quack_serve() instance.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encodeMessage(testing.allocator, &buf, .{ .type = .connection_request }, ConnectionRequest{
        .auth_string = "super_secret",
        .client_duckdb_version = "v1.4.1",
        .client_platform = "osx_arm64",
        .min_version = 1,
        .max_version = 1,
    });
    const expected = [_]u8{
        // header: field 1 = 1, field 3 = UINT64_MAX, terminator
        0x01, 0x00, 0x01,
        0x03, 0x00, 0xFF,
        0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0x01,
        0xFF, 0xFF,
        // body
        0x01,
        0x00, 0x0C, 's',
        'u',  'p',  'e',
        'r',  '_',  's',
        'e',  'c',  'r',
        'e',  't',  0x02,
        0x00, 0x06, 'v',
        '1',  '.',  '4',
        '.',  '1',  0x03,
        0x00, 0x09, 'o',
        's',  'x',  '_',
        'a',  'r',  'm',
        '6',  '4',  0x04,
        0x00, 0x01, 0x05,
        0x00, 0x01, 0xFF,
        0xFF,
    };
    try testing.expectEqualSlices(u8, &expected, buf.items);
}

test "an unknown field in the header is rejected, not skipped" {
    // Field values are not self-describing, so skipping an unrecognised field
    // would desync the reader and misinterpret everything after it. Failing
    // loudly is the only safe response (and is what a real server's own
    // deserializer does).
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    try w.writePropertyUVarInt(hdr_type, @backingInt(MessageType.prepare_response));
    try w.writePropertyUVarInt(4242, @as(u64, 7)); // not a header field
    try w.writeTerminator();

    var r = Reader.init(buf.items);
    try testing.expectError(Error.UnexpectedField, MessageHeader.decode(&r));
}

test "an unknown field in a response body is rejected" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    try w.writePropertyStringWithDefault(1, "v1.5.5");
    try w.writePropertyUVarInt(999, @as(u64, 1));
    try w.writeTerminator();

    var r = Reader.init(buf.items);
    try testing.expectError(Error.UnexpectedField, ConnectionResponse.decode(&r));
}

test "unknown message type decodes without crashing" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &buf);
    try (MessageHeader{ .type = @fromBackingInt(@intCast(77)) }).encode(&w);
    var r = Reader.init(buf.items);
    const got = try MessageHeader.decode(&r);
    try testing.expectEqualStrings("UNKNOWN", got.type.name());
}
