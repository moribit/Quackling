//! Client and Result tests driven by a mock transport.
//!
//! These cover the layers that were previously exercised *only* by the
//! integration suite: the handshake, error classification, the FETCH streaming
//! state machine, cancellation, and statistics. Because a mock stands in for
//! the server, they run everywhere - including CI with no DuckDB - and they can
//! reproduce responses a real server would rarely or never produce
//! (truncated bodies, wrong message types, empty batches, HTTP failures).

const std = @import("std");
const quackling = @import("quackling");

const testing = std.testing;
const message = quackling.protocol.message;
const MessageType = message.MessageType;
const Writer = quackling.serialization.Writer;

// -- synthetic server responses ----------------------------------------------
//
// Built with the library's own encoder. That is sound here because the encoder
// is independently pinned to real bytes by `message.zig`'s
// "connection request encodes the exact bytes the server accepted" test and by
// the golden fixtures; using it lets these tests construct responses a live
// server will not readily produce.

const Buf = std.ArrayList(u8);

fn header(w: *Writer, t: MessageType, conn: []const u8) !void {
    try (message.MessageHeader{ .type = t, .connection_id = conn }).encode(w);
}

/// CONNECTION_RESPONSE with the given session id.
fn connectResponse(a: std.mem.Allocator, conn: []const u8, version: u64) ![]u8 {
    var buf: Buf = .empty;
    errdefer buf.deinit(a);
    var w = Writer.init(a, &buf);
    try header(&w, .connection_response, conn);
    try w.writePropertyStringWithDefault(1, "v1.5.5");
    try w.writePropertyStringWithDefault(2, "test_platform");
    try w.writePropertyUVarIntWithDefault(3, version);
    try w.writeTerminator();
    return buf.toOwnedSlice(a);
}

fn errorResponse(a: std.mem.Allocator, msg: []const u8) ![]u8 {
    var buf: Buf = .empty;
    errdefer buf.deinit(a);
    var w = Writer.init(a, &buf);
    try header(&w, .error_response, "");
    try w.writePropertyStringWithDefault(1, msg);
    try w.writeTerminator();
    return buf.toOwnedSlice(a);
}

/// One INTEGER column named `name`, with `values` as its rows, split into
/// chunks of at most `chunk_rows`.
const ResultSpec = struct {
    name: []const u8 = "v",
    values: []const i32,
    chunk_rows: usize = 2048,
    needs_more_fetch: bool = false,
    uuid: i128 = 0x1234,
};

fn writeIntChunk(a: std.mem.Allocator, w: *Writer, values: []const i32) !void {
    _ = a;
    // unique_ptr present byte
    try w.writeBool(true);
    // DataChunkWrapper { 300: DataChunk }
    try w.writeFieldId(300);
    // DataChunk
    try w.writePropertyUVarIntWithDefault(100, @as(u32, @intCast(values.len))); // rows
    try w.writeFieldId(101); // types
    try w.writeUVarInt(@as(u64, 1));
    try w.writePropertyUVarInt(100, @backingInt(quackling.LogicalTypeId.integer));
    try w.writeTerminator(); // end LogicalType
    try w.writeFieldId(102); // columns
    try w.writeUVarInt(@as(u64, 1));
    // Vector
    try w.writePropertyBool(100, false); // has_validity_mask = false
    try w.writeFieldId(102); // data
    try w.writeUVarInt(@as(u64, values.len * 4));
    for (values) |v| {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(i32, &tmp, v, .little);
        try w.writeRaw(&tmp);
    }
    try w.writeTerminator(); // end Vector
    try w.writeTerminator(); // end DataChunk
    try w.writeTerminator(); // end DataChunkWrapper
}

fn prepareResponse(a: std.mem.Allocator, spec: ResultSpec) ![]u8 {
    var buf: Buf = .empty;
    errdefer buf.deinit(a);
    var w = Writer.init(a, &buf);
    try header(&w, .prepare_response, "");

    // 1: result_types
    try w.writeFieldId(1);
    try w.writeUVarInt(@as(u64, 1));
    try w.writePropertyUVarInt(100, @backingInt(quackling.LogicalTypeId.integer));
    try w.writeTerminator();
    // 2: result_names
    try w.writeFieldId(2);
    try w.writeUVarInt(@as(u64, 1));
    try w.writeString(spec.name);
    // 3: needs_more_fetch
    try w.writePropertyBoolWithDefault(3, spec.needs_more_fetch);
    // 4: chunks
    const nchunks = if (spec.values.len == 0) 0 else (spec.values.len + spec.chunk_rows - 1) / spec.chunk_rows;
    try w.writeFieldId(4);
    try w.writeUVarInt(@as(u64, nchunks));
    var i: usize = 0;
    while (i < spec.values.len) : (i += spec.chunk_rows) {
        const end = @min(i + spec.chunk_rows, spec.values.len);
        try writeIntChunk(a, &w, spec.values[i..end]);
    }
    // 5: result_uuid
    if (spec.uuid != 0) try w.writePropertyHugeInt(5, spec.uuid);
    try w.writeTerminator();
    return buf.toOwnedSlice(a);
}

/// FETCH_RESPONSE carrying `values` (empty slice = end of stream).
fn fetchResponse(a: std.mem.Allocator, values: []const i32, chunk_rows: usize) ![]u8 {
    var buf: Buf = .empty;
    errdefer buf.deinit(a);
    var w = Writer.init(a, &buf);
    try header(&w, .fetch_response, "");
    const nchunks = if (values.len == 0) 0 else (values.len + chunk_rows - 1) / chunk_rows;
    try w.writeFieldId(1);
    try w.writeUVarInt(@as(u64, nchunks));
    var i: usize = 0;
    while (i < values.len) : (i += chunk_rows) {
        const end = @min(i + chunk_rows, values.len);
        try writeIntChunk(a, &w, values[i..end]);
    }
    try w.writeTerminator();
    return buf.toOwnedSlice(a);
}

fn successResponse(a: std.mem.Allocator) ![]u8 {
    var buf: Buf = .empty;
    errdefer buf.deinit(a);
    var w = Writer.init(a, &buf);
    try header(&w, .success_response, "");
    try w.writeTerminator();
    return buf.toOwnedSlice(a);
}

/// Owns a script of responses and frees them all at once.
const Script = struct {
    a: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,

    fn init(a: std.mem.Allocator) Script {
        return .{ .a = a };
    }
    fn deinit(self: *Script) void {
        for (self.items.items) |b| self.a.free(b);
        self.items.deinit(self.a);
    }
    fn add(self: *Script, bytes: []u8) !void {
        try self.items.append(self.a, bytes);
    }
    /// The scripted responses, in order.
    fn slice(self: *Script) [][]u8 {
        return self.items.items;
    }
};

/// A connected client backed by a mock, for tests that start post-handshake.
const Fixture = struct {
    script: Script,
    mock: quackling.MockTransport,
    client: quackling.Client,

    fn deinit(self: *Fixture) void {
        self.client.deinit();
        self.mock.deinit();
        self.script.deinit();
    }
};

// -- handshake ----------------------------------------------------------------

test "connect stores the session id and server identity" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "ABC0123456789DEF0123456789ABCDEF", 1));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();

    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:localhost:9494",
        .token = "t",
        .transport = mock.transport(),
    });
    defer client.deinit();

    try testing.expect(!client.isConnected());
    try client.connect(null);
    try testing.expect(client.isConnected());
    try testing.expectEqualStrings("ABC0123456789DEF0123456789ABCDEF", client.connection_id);
    try testing.expectEqualStrings("v1.5.5", client.server_version);
    try testing.expectEqual(@as(u64, 1), client.quack_version);
    try testing.expectEqual(@as(u64, 1), client.stats.connects);
}

test "connect is idempotent" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "AAAA", 1));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    try client.connect(null);
    // A second connect must not consume another scripted response.
    try client.connect(null);
    try testing.expectEqual(@as(usize, 1), mock.index);
}

test "a server speaking an unsupported protocol version is refused" {
    // Both ends of the accepted range must be enforced. Testing only the upper
    // bound would leave the lower-bound comparison uncovered.
    const rejected = [_]u64{
        0, // below min_supported_version
        99, // above max_supported_version
        std.math.maxInt(u64),
    };
    for (rejected) |version| {
        var script = Script.init(testing.allocator);
        defer script.deinit();
        try script.add(try connectResponse(testing.allocator, "AAAA", version));

        var mock = quackling.MockTransport{ .responses = script.slice() };
        defer mock.deinit();
        var client = try quackling.Client.init(.{
            .allocator = testing.allocator,
            .endpoint = "quack:h",
            .transport = mock.transport(),
        });
        defer client.deinit();

        try testing.expectError(error.UnsupportedProtocolVersion, client.connect(null));
        try testing.expect(!client.isConnected());
    }
}

test "the advertised protocol version is accepted" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "AAAA", quackling.protocol.compat.quack_version));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    try client.connect(null);
    try testing.expect(client.isConnected());
}

test "a connection response without a session id is rejected" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    // connection_id omitted (it is default-skipped when empty).
    try script.add(try connectResponse(testing.allocator, "", 1));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    try testing.expectError(error.UnexpectedMessageType, client.connect(null));
    try testing.expect(!client.isConnected());
}

test "auth failures are classified apart from other server errors" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try errorResponse(testing.allocator, "Authentication failed"));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .token = "wrong",
        .transport = mock.transport(),
    });
    defer client.deinit();

    try testing.expectError(error.AuthenticationFailed, client.connect(null));
    // The server's own wording must survive.
    try testing.expectEqualStrings("Authentication failed", client.lastError());
}

test "a non-auth error during handshake is a plain server error" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try errorResponse(testing.allocator, "Database is shutting down"));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    try testing.expectError(error.ServerError, client.connect(null));
}

test "an unexpected message type during handshake is a protocol error" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    // A PREPARE_RESPONSE has no business arriving here.
    try script.add(try prepareResponse(testing.allocator, .{ .values = &.{1} }));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    try testing.expectError(error.UnexpectedMessageType, client.connect(null));
}

// -- transport-level failures --------------------------------------------------

test "a transport failure surfaces and is counted" {
    var mock = quackling.MockTransport{ .responses = &.{}, .fail_with = error.ConnectionFailed };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    try testing.expectError(error.ConnectionFailed, client.connect(null));
    try testing.expectEqual(@as(u64, 1), client.stats.transport_errors);
}

test "a non-2xx HTTP status is an HttpError, not a decode attempt" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "AAAA", 1));

    var mock = quackling.MockTransport{ .responses = script.slice(), .status = 500 };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    try testing.expectError(error.HttpError, client.connect(null));
    try testing.expectEqual(@as(?u16, 500), client.last_error.http_status);
}

test "a truncated response body is a decode error, not a crash" {
    const full = try connectResponse(testing.allocator, "AAAA", 1);
    defer testing.allocator.free(full);

    // Every prefix must fail cleanly.
    var len: usize = 0;
    while (len < full.len) : (len += 1) {
        var mock = quackling.MockTransport{ .responses = &.{full[0..len]} };
        defer mock.deinit();
        var client = try quackling.Client.init(.{
            .allocator = testing.allocator,
            .endpoint = "quack:h",
            .transport = mock.transport(),
        });
        defer client.deinit();
        try testing.expectError(error.UnexpectedEndOfBuffer, client.connect(null));
    }
}

test "a response larger than the cap is refused" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "AAAA", 1));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
        .max_response_bytes = 4, // smaller than any real response
    });
    defer client.deinit();

    try testing.expectError(error.ResponseTooLarge, client.connect(null));
}

// -- queries -------------------------------------------------------------------

/// Build a connected client whose next responses are `rest`.
fn connectedFixture(script: *Script) !struct { mock: quackling.MockTransport, client: quackling.Client } {
    var mock = quackling.MockTransport{ .responses = script.slice() };
    const client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:localhost:9494",
        .token = "t",
        .transport = mock.transport(),
    });
    return .{ .mock = mock, .client = client };
}

test "query connects lazily on first use" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "SESSION1", 1));
    try script.add(try prepareResponse(testing.allocator, .{ .values = &.{42} }));

    var mock = quackling.MockTransport{ .responses = script.slice(), .record_allocator = testing.allocator };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT 42");
    defer result.deinit();
    try testing.expect(client.isConnected());
    try testing.expectEqual(@as(i64, 42), (try result.scalar()).?.asI64().?);

    // Two requests went out: the handshake, then the query.
    try testing.expectEqual(@as(usize, 2), mock.sent.items.len);
}

test "the query request carries the session id" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "SESSIONXYZ", 1));
    try script.add(try prepareResponse(testing.allocator, .{ .values = &.{1} }));

    var mock = quackling.MockTransport{ .responses = script.slice(), .record_allocator = testing.allocator };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT 1");
    defer result.deinit();

    // Decode the request we actually sent and check its header.
    var r = quackling.serialization.Reader.init(mock.sent.items[1]);
    const h = try message.MessageHeader.decode(&r);
    try testing.expectEqual(MessageType.prepare_request, h.type);
    try testing.expectEqualStrings("SESSIONXYZ", h.connection_id);
}

test "a query error leaves the connection usable" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try errorResponse(testing.allocator, "Catalog Error: no such table"));
    try script.add(try prepareResponse(testing.allocator, .{ .values = &.{7} }));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    try testing.expectError(error.ServerError, client.query("SELECT * FROM nope"));
    try testing.expectEqualStrings("Catalog Error: no such table", client.lastError());
    try testing.expectEqual(@as(u64, 1), client.stats.server_errors);
    try testing.expect(client.isConnected());

    // The next query still works.
    var ok = try client.query("SELECT 7");
    defer ok.deinit();
    try testing.expectEqual(@as(i64, 7), (try ok.scalar()).?.asI64().?);
}

test "column metadata is exposed by name and index" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{ .name = "answer", .values = &.{42} }));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT 42 AS answer");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.columnCount());
    try testing.expectEqualStrings("answer", result.columnName(0).?);
    try testing.expectEqual(@as(?usize, 0), result.columnIndex("answer"));
    try testing.expectEqual(@as(?usize, null), result.columnIndex("missing"));
    try testing.expectEqual(quackling.LogicalTypeId.integer, result.columnType(0).?.id);
    // Out-of-range accessors return null rather than trapping.
    try testing.expectEqual(@as(?[]const u8, null), result.columnName(5));
    try testing.expectEqual(@as(?quackling.LogicalType, null), result.columnType(5));

    const Answer = struct { answer: i64 };
    var rows = try quackling.typed.iterator(Answer, &result);
    try testing.expectEqual(@as(i64, 42), (try rows.next()).?.answer);
    try testing.expectEqual(@as(?Answer, null), try rows.next());
    try testing.expectError(error.MissingColumn, quackling.typed.Mapping(struct { missing: i64 }).init(&result));
}

// -- FETCH streaming -----------------------------------------------------------

test "streaming walks multiple FETCH batches to completion" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    // PREPARE carries rows 0..3 and says more is coming.
    try script.add(try prepareResponse(testing.allocator, .{
        .values = &.{ 0, 1, 2, 3 },
        .chunk_rows = 2,
        .needs_more_fetch = true,
    }));
    // Two FETCH batches, then an empty one to signal the end.
    try script.add(try fetchResponse(testing.allocator, &.{ 4, 5, 6, 7 }, 2));
    try script.add(try fetchResponse(testing.allocator, &.{ 8, 9 }, 2));
    try script.add(try fetchResponse(testing.allocator, &.{}, 2));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT i FROM range(10)");
    defer result.deinit();

    var seen: [10]i64 = undefined;
    var n: usize = 0;
    var stream = result.rows();
    while (try stream.next()) |row| : (n += 1) {
        try testing.expect(n < seen.len);
        seen[n] = (try row.get(0)).asI64().?;
    }
    try testing.expectEqual(@as(usize, 10), n);
    for (seen, 0..) |v, i| try testing.expectEqual(@as(i64, @intCast(i)), v);

    // Three FETCH round trips: two with data, one empty terminator.
    try testing.expectEqual(@as(u64, 3), client.stats.fetches);
    try testing.expectEqual(@as(u64, 10), client.stats.rows_received);
}

test "an empty first FETCH ends the stream immediately" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{
        .values = &.{1},
        .needs_more_fetch = true,
    }));
    try script.add(try fetchResponse(testing.allocator, &.{}, 2));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT 1");
    defer result.deinit();
    try testing.expectEqual(@as(u64, 1), try result.drain());
}

test "nextChunk keeps returning null after exhaustion" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{ .values = &.{1} }));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT 1");
    defer result.deinit();
    try testing.expect((try result.nextChunk()) != null);
    // Repeated calls past the end must stay null and must not re-fetch.
    try testing.expectEqual(@as(?*const quackling.DataChunk, null), try result.nextChunk());
    try testing.expectEqual(@as(?*const quackling.DataChunk, null), try result.nextChunk());
    try testing.expectEqual(@as(u64, 0), client.stats.fetches);
}

test "a transport failure mid-stream propagates" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{
        .values = &.{ 1, 2 },
        .chunk_rows = 1,
        .needs_more_fetch = true,
    }));
    // No FETCH response scripted: the mock reports a network error.

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT i");
    defer result.deinit();
    // The two buffered chunks arrive first.
    try testing.expect((try result.nextChunk()) != null);
    try testing.expect((try result.nextChunk()) != null);
    // Then the FETCH fails.
    try testing.expectError(error.NetworkError, result.nextChunk());
}

test "a server error mid-stream is reported with its message" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{
        .values = &.{1},
        .needs_more_fetch = true,
    }));
    try script.add(try errorResponse(testing.allocator, "Result set has been closed"));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT 1");
    defer result.deinit();
    _ = try result.nextChunk();
    try testing.expectError(error.ServerError, result.nextChunk());
    try testing.expectEqualStrings("Result set has been closed", client.lastError());
}

test "the FETCH request echoes the result uuid" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{
        .values = &.{1},
        .needs_more_fetch = true,
        .uuid = 0x0BADC0DE,
    }));
    try script.add(try fetchResponse(testing.allocator, &.{}, 2));

    var mock = quackling.MockTransport{ .responses = script.slice(), .record_allocator = testing.allocator };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT 1");
    defer result.deinit();
    _ = try result.drain();

    var r = quackling.serialization.Reader.init(mock.sent.items[2]);
    const h = try message.MessageHeader.decode(&r);
    try testing.expectEqual(MessageType.fetch_request, h.type);
    // Body: field 1 = uuid as a hugeint.
    try testing.expectEqual(@as(u16, 1), try r.readFieldId());
    try testing.expectEqual(@as(i128, 0x0BADC0DE), try r.readHugeInt());
}

test "a server that never signals end-of-stream cannot hang the client" {
    // End-of-stream is the server's decision (an empty FETCH batch). A peer
    // that keeps sending non-empty batches forever must not spin us forever.
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{
        .values = &.{1},
        .needs_more_fetch = true,
    }));

    // A transport that answers every FETCH with the same non-empty batch.
    const Endless = struct {
        body: []const u8,
        calls: usize = 0,

        fn send(ptr: *anyopaque, _: std.mem.Allocator, _: quackling.transport_mod.Request) quackling.transport_mod.Error!quackling.transport_mod.Response {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            return .{ .status = 200, .body = self.body, .owned = false };
        }
    };

    const fetch_body = try fetchResponse(testing.allocator, &.{9}, 1);
    defer testing.allocator.free(fetch_body);

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT 1");
    defer result.deinit();

    // Swap in the endless transport and lower the ceiling so the test is quick;
    // the production default is far too high to reach deliberately.
    var endless = Endless{ .body = fetch_body };
    client.transport = .{ .ptr = &endless, .vtable = &.{ .send = Endless.send } };
    result.max_fetches = 32;

    try testing.expectError(error.FetchLimitExceeded, result.drain());
    // It stopped at the ceiling rather than running away.
    try testing.expectEqual(@as(usize, 32), endless.calls);
}

test "a result superseded by a newer query is detected, not silently wrong" {
    // The server keeps one cursor per connection and resets it on each
    // PREPARE, so a second query invalidates the first result. Continuing to
    // stream the stale one would return the *new* query's rows.
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{
        .values = &.{ 1, 2 },
        .chunk_rows = 1,
        .needs_more_fetch = true,
    }));
    try script.add(try prepareResponse(testing.allocator, .{ .values = &.{99} }));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var first = try client.query("SELECT i FROM range(2)");
    defer first.deinit();
    // Drain the chunks already buffered from PREPARE.
    try testing.expect((try first.nextChunk()) != null);
    try testing.expect((try first.nextChunk()) != null);

    // Start a second query while the first still needs a FETCH.
    var second = try client.query("SELECT 99");
    defer second.deinit();

    // The stale result must refuse rather than fetch the new query's rows.
    try testing.expectError(error.ResultSuperseded, first.nextChunk());
    // The new result is unaffected.
    try testing.expectEqual(@as(i64, 99), (try second.scalar()).?.asI64().?);
}

test "even a FAILED query supersedes an outstanding result" {
    // The server resets its cursor when it accepts the PREPARE, before running
    // the SQL. So a query that then errors still destroyed the previous
    // cursor - the stale result must not look valid just because the new query
    // did not succeed.
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{
        .values = &.{1},
        .needs_more_fetch = true,
    }));
    try script.add(try errorResponse(testing.allocator, "Catalog Error: nope"));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var first = try client.query("SELECT 1");
    defer first.deinit();
    try testing.expect((try first.nextChunk()) != null);

    // This query fails, but the server already discarded the first cursor.
    try testing.expectError(error.ServerError, client.query("SELECT * FROM nope"));

    try testing.expectError(error.ResultSuperseded, first.nextChunk());
}

test "a fully drained result is unaffected by a later query" {
    // Only results that still need a FETCH can be superseded; one that already
    // finished holds all its data locally and stays readable.
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{ .values = &.{ 1, 2 } }));
    try script.add(try prepareResponse(testing.allocator, .{ .values = &.{7} }));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var first = try client.query("SELECT i");
    defer first.deinit();
    try testing.expectEqual(@as(u64, 2), try first.drain());

    var second = try client.query("SELECT 7");
    defer second.deinit();
    try testing.expectEqual(@as(i64, 7), (try second.scalar()).?.asI64().?);

    // The drained result still reports its schema and stays exhausted.
    try testing.expectEqual(@as(usize, 1), first.columnCount());
    try testing.expectEqual(@as(?*const quackling.DataChunk, null), try first.nextChunk());
}

// -- cancellation ---------------------------------------------------------------

test "a cancelled token stops a query before it is sent" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();
    try client.connect(null);

    var cancel = quackling.CancelToken{};
    cancel.cancel();
    try testing.expectError(error.Cancelled, client.queryWithCancel("SELECT 1", &cancel));
}

test "cancelling mid-stream stops further chunks" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{
        .values = &.{ 1, 2, 3, 4 },
        .chunk_rows = 1,
        .needs_more_fetch = true,
    }));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var cancel = quackling.CancelToken{};
    var result = try client.queryWithCancel("SELECT i", &cancel);
    defer result.deinit();

    try testing.expect((try result.nextChunk()) != null);
    cancel.cancel();
    try testing.expectError(error.Cancelled, result.nextChunk());
}

// -- disconnect / lifecycle -----------------------------------------------------

test "disconnect clears the session" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try successResponse(testing.allocator));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    try client.connect(null);
    try client.disconnect();
    try testing.expect(!client.isConnected());
    // A second disconnect is a no-op, not an error.
    try client.disconnect();
}

test "disconnect drops the session even when the request fails" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    // No response scripted for the DISCONNECT.

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    try client.connect(null);
    try testing.expectError(error.NetworkError, client.disconnect());
    // Local state must still be cleared; the session is gone either way.
    try testing.expect(!client.isConnected());
}

test "an invalid endpoint fails at init, before any I/O" {
    var mock = quackling.MockTransport{ .responses = &.{} };
    defer mock.deinit();
    try testing.expectError(error.EmptyHost, quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "",
        .transport = mock.transport(),
    }));
    try testing.expectError(error.InvalidPort, quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:host:0",
        .transport = mock.transport(),
    }));
}

// -- observability ---------------------------------------------------------------

test "the observer sees request and chunk events" {
    const Counter = struct {
        var starts: usize = 0;
        var ends: usize = 0;
        var chunks: usize = 0;
        var bytes_out: usize = 0;
        fn onStart(_: ?*anyopaque, n: usize) void {
            starts += 1;
            bytes_out += n;
        }
        fn onEnd(_: ?*anyopaque, _: usize, _: bool) void {
            ends += 1;
        }
        fn onChunk(_: ?*anyopaque, _: usize) void {
            chunks += 1;
        }
    };
    Counter.starts = 0;
    Counter.ends = 0;
    Counter.chunks = 0;
    Counter.bytes_out = 0;

    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{ .values = &.{ 1, 2, 3 }, .chunk_rows = 1 }));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
        .observer = .{
            .on_request_start = Counter.onStart,
            .on_request_end = Counter.onEnd,
            .on_chunk = Counter.onChunk,
        },
    });
    defer client.deinit();

    var result = try client.query("SELECT i");
    defer result.deinit();
    _ = try result.drain();

    try testing.expectEqual(@as(usize, 2), Counter.starts); // connect + query
    try testing.expectEqual(@as(usize, 2), Counter.ends);
    try testing.expectEqual(@as(usize, 3), Counter.chunks);
    try testing.expect(Counter.bytes_out > 0);
}

test "byte counters track both directions" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{ .values = &.{1} }));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT 1");
    defer result.deinit();
    _ = try result.drain();

    try testing.expectEqual(@as(u64, 2), client.stats.requests);
    try testing.expectEqual(@as(u64, 1), client.stats.queries);
    try testing.expect(client.stats.bytes_sent > 0);
    try testing.expect(client.stats.bytes_received > 0);
}

// -- secrecy of the auth token --------------------------------------------------

test "the auth token never leaks into errors, stats or debug output" {
    // The README promises the token is never logged or surfaced. That is a
    // security property, so it gets a test that fails if someone later folds
    // the token into an error message or a formatted struct.
    const secret = "sup3r-s3cret-token-do-not-leak";

    var script = Script.init(testing.allocator);
    defer script.deinit();
    // Force every interesting failure path: bad auth, then a server error.
    try script.add(try errorResponse(testing.allocator, "Authentication failed"));

    var mock = quackling.MockTransport{ .responses = script.slice(), .record_allocator = testing.allocator };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:localhost:9494",
        .token = secret,
        .transport = mock.transport(),
    });
    defer client.deinit();

    try testing.expectError(error.AuthenticationFailed, client.connect(null));

    // 1. Not in the surfaced error text.
    try testing.expect(std.mem.indexOf(u8, client.lastError(), secret) == null);

    // 2. Not in the connection URL.
    try testing.expect(std.mem.indexOf(u8, client.url, secret) == null);

    // 3. Not in the formatted statistics.
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try client.stats.format(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), secret) == null);

    // 4. It *is* in the handshake body - that is the one place it belongs,
    //    which is also why the transport must be TLS-protected in production.
    try testing.expect(std.mem.indexOf(u8, mock.sent.items[0], secret) != null);
}

test "a query error message cannot echo the token" {
    const secret = "tok3n-value";
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    // A hostile/broken server that reflects the token back at us must not
    // cause us to treat it as anything other than opaque error text.
    try script.add(try errorResponse(testing.allocator, "failed near tok3n-value"));

    var mock = quackling.MockTransport{ .responses = script.slice() };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .token = secret,
        .transport = mock.transport(),
    });
    defer client.deinit();

    try testing.expectError(error.ServerError, client.query("SELECT 1"));
    // We preserve the server's message verbatim (todo.md §20). The guarantee
    // is that *we* never add the token, not that we censor the server.
    try testing.expectEqualStrings("failed near tok3n-value", client.lastError());
}

// -- parameters over the wire ------------------------------------------------------

test "bound parameters reach the server already substituted" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));
    try script.add(try prepareResponse(testing.allocator, .{ .values = &.{1} }));

    var mock = quackling.MockTransport{ .responses = script.slice(), .record_allocator = testing.allocator };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();

    var result = try client.queryParams(
        "SELECT * FROM t WHERE n = ?",
        &.{.{ .text = "o'brien" }},
    );
    defer result.deinit();

    // Inspect the SQL actually transmitted.
    var r = quackling.serialization.Reader.init(mock.sent.items[1]);
    _ = try message.MessageHeader.decode(&r);
    try testing.expectEqual(@as(u16, 1), try r.readFieldId());
    try testing.expectEqualStrings(
        "SELECT * FROM t WHERE n = 'o''brien'",
        try r.readString(),
    );
}

test "a parameter error is raised before anything is sent" {
    var script = Script.init(testing.allocator);
    defer script.deinit();
    try script.add(try connectResponse(testing.allocator, "S", 1));

    var mock = quackling.MockTransport{ .responses = script.slice(), .record_allocator = testing.allocator };
    defer mock.deinit();
    var client = try quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = "quack:h",
        .transport = mock.transport(),
    });
    defer client.deinit();
    try client.connect(null);

    try testing.expectError(
        error.ParameterCountMismatch,
        client.queryParams("SELECT ?, ?", &.{.{ .integer = 1 }}),
    );
    // Only the handshake went out; no malformed query was transmitted.
    try testing.expectEqual(@as(usize, 1), mock.sent.items.len);
}
