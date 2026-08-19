//! Browser/WASM bridge.
//!
//! The protocol core is transport-agnostic, so the browser build supplies a
//! `Transport` whose `send` is fulfilled by JavaScript `fetch()` instead of a
//! socket. The FFI boundary is deliberately tiny (todo.md §16): JS hands raw
//! response bytes into linear memory, and reads decoded columns back out as
//! `TypedArray` views. Nothing crosses the boundary as JSON.
//!
//! The flow is asynchronous on the JS side but synchronous here:
//!
//! ```
//!   JS: quack_request_ptr()/quack_request_len()  -> bytes to POST
//!   JS: await fetch(url, {body})
//!   JS: copy the reply into quack_response_buffer(len)
//!   JS: quack_on_response(len)  -> Zig decodes
//!   JS: quack_column_ptr(col)   -> TypedArray over WASM memory, no copy
//! ```
//!
//! Freestanding wasm has no libc and no allocator of its own, so this module
//! uses a fixed-size arena carved out of linear memory. There is no OS
//! dependency, no threads and no filesystem here.

const std = @import("std");
const quackling = @import("quackling");

const message = quackling.protocol.message;
const Reader = quackling.serialization.Reader;

// -- allocator ----------------------------------------------------------------

/// Backing store for all decoding. Sized once at compile time so the module has
/// a predictable memory footprint and cannot grow without bound in a tab.
var heap_buf: [16 * 1024 * 1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&heap_buf);

/// Buffers exchanged with JavaScript.
var request_buf: [1 * 1024 * 1024]u8 = undefined;
var request_len: usize = 0;
/// Static scratch for message encoding. Static, not stack: the wasm stack is
/// small (64 KiB by default) and a large local array traps on entry.
var encode_buf: [1 * 1024 * 1024]u8 = undefined;
/// Where JS stages input strings (SQL, token). Kept separate from the response
/// buffer so an in-flight encode never reads memory it is also writing.
var input_buf: [256 * 1024]u8 = undefined;
var response_buf: [16 * 1024 * 1024]u8 = undefined;
var response_len: usize = 0;

/// Decoded state from the most recent response.
///
/// A query's column metadata lives in `current` (the PREPARE response) for the
/// whole result, because the type and name slices borrow its buffer. Subsequent
/// FETCH batches replace `fetched` only, so the schema stays valid while chunks
/// stream past.
var current: ?message.PrepareResponse = null;
var fetched: ?message.FetchResponse = null;
/// Arena for FETCH batches, reset per batch so memory tracks one batch rather
/// than the whole result.
var fetch_heap: [16 * 1024 * 1024]u8 = undefined;
var fetch_fba = std.heap.FixedBufferAllocator.init(&fetch_heap);
/// Whether the server said more rows are available.
var needs_more: bool = false;
/// The result cursor id to pass back in FETCH_REQUEST.
var result_uuid: i128 = 0;
var current_chunk: usize = 0;
var last_error_buf: [512]u8 = undefined;
var last_error_len: usize = 0;

/// Session id assigned by the server.
var connection_id_buf: [64]u8 = undefined;
var connection_id_len: usize = 0;

fn setError(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&last_error_buf, fmt, args) catch "error";
    last_error_len = s.len;
}

fn clearError() void {
    last_error_len = 0;
}

// -- request construction -----------------------------------------------------

/// Build a CONNECTION_REQUEST. `token_ptr/len` point into linear memory that JS
/// has already written. Returns the request length, or -1 on failure.
export fn quack_build_connect(token_ptr: [*]const u8, token_len: usize) i32 {
    clearError();
    if (token_len > input_buf.len) {
        setError("token too large", .{});
        return -1;
    }
    var alloc_state = std.heap.FixedBufferAllocator.init(&encode_buf);
    var buf: std.ArrayList(u8) = .empty;

    message.encodeMessage(alloc_state.allocator(), &buf, .{
        .type = .connection_request,
    }, message.ConnectionRequest{
        .auth_string = token_ptr[0..token_len],
    }) catch {
        setError("failed to encode connect request", .{});
        return -1;
    };
    return publishRequest(buf.items);
}

/// Copy an encoded message into the request buffer JS reads from.
fn publishRequest(bytes: []const u8) i32 {
    if (bytes.len > request_buf.len) {
        setError("request too large", .{});
        return -1;
    }
    @memcpy(request_buf[0..bytes.len], bytes);
    request_len = bytes.len;
    return @intCast(request_len);
}

/// Build a PREPARE_REQUEST for the SQL in linear memory.
export fn quack_build_query(sql_ptr: [*]const u8, sql_len: usize) i32 {
    clearError();
    if (connection_id_len == 0) {
        setError("not connected", .{});
        return -1;
    }
    if (sql_len > input_buf.len) {
        setError("query too large", .{});
        return -1;
    }
    var alloc_state = std.heap.FixedBufferAllocator.init(&encode_buf);
    var buf: std.ArrayList(u8) = .empty;

    message.encodeMessage(alloc_state.allocator(), &buf, .{
        .type = .prepare_request,
        .connection_id = connection_id_buf[0..connection_id_len],
    }, message.PrepareRequest{ .sql = sql_ptr[0..sql_len] }) catch {
        setError("failed to encode query", .{});
        return -1;
    };
    return publishRequest(buf.items);
}

/// Where JS writes input strings (token, SQL) before calling a build function.
export fn quack_input_buffer() [*]u8 {
    return &input_buf;
}

export fn quack_input_capacity() usize {
    return input_buf.len;
}

export fn quack_request_ptr() [*]const u8 {
    return &request_buf;
}

export fn quack_request_len() usize {
    return request_len;
}

/// Pointer JS writes the HTTP response into. JS must not exceed `quack_response_capacity`.
export fn quack_response_buffer() [*]u8 {
    return &response_buf;
}

export fn quack_response_capacity() usize {
    return response_buf.len;
}

// -- response handling --------------------------------------------------------

/// Decode a CONNECTION_RESPONSE that JS placed in the response buffer.
/// Returns 0 on success, -1 on error (see `quack_last_error_*`).
export fn quack_on_connect_response(len: usize) i32 {
    clearError();
    if (len > response_buf.len) {
        setError("response exceeds buffer", .{});
        return -1;
    }
    response_len = len;

    var r = Reader.init(response_buf[0..len]);
    const header = message.MessageHeader.decode(&r) catch {
        setError("malformed response header", .{});
        return -1;
    };

    switch (header.type) {
        .connection_response => {},
        .error_response => {
            const e = message.ErrorResponse.decode(&r) catch {
                setError("malformed error response", .{});
                return -1;
            };
            setError("{s}", .{e.message});
            return -1;
        },
        else => {
            setError("unexpected message type {d}", .{@intFromEnum(header.type)});
            return -1;
        },
    }

    if (header.connection_id.len == 0 or header.connection_id.len > connection_id_buf.len) {
        setError("server did not supply a connection id", .{});
        return -1;
    }
    @memcpy(connection_id_buf[0..header.connection_id.len], header.connection_id);
    connection_id_len = header.connection_id.len;
    return 0;
}

/// Decode a PREPARE_RESPONSE that JS placed in the response buffer.
/// Returns the number of columns, or -1 on error.
export fn quack_on_query_response(len: usize) i32 {
    clearError();
    if (len > response_buf.len) {
        setError("response exceeds buffer", .{});
        return -1;
    }
    response_len = len;

    // Release whatever the previous query held.
    handlesClear();
    if (fetched) |*f| f.deinit();
    fetched = null;
    if (current) |*c| c.deinit();
    current = null;
    current_chunk = 0;
    needs_more = false;
    result_uuid = 0;
    fba.reset();
    fetch_fba.reset();

    var r = Reader.init(response_buf[0..len]);
    const header = message.MessageHeader.decode(&r) catch {
        setError("malformed response header", .{});
        return -1;
    };

    switch (header.type) {
        .prepare_response => {},
        .error_response => {
            const e = message.ErrorResponse.decode(&r) catch {
                setError("malformed error response", .{});
                return -1;
            };
            setError("{s}", .{e.message});
            return -1;
        },
        else => {
            setError("unexpected message type {d}", .{@intFromEnum(header.type)});
            return -1;
        },
    }

    current = message.PrepareResponse.decode(&r, fba.allocator()) catch {
        setError("failed to decode result", .{});
        return -1;
    };
    needs_more = current.?.needs_more_fetch;
    result_uuid = current.?.result_uuid;
    return @intCast(current.?.types.len);
}

/// Build a FETCH_REQUEST for the result currently being streamed.
///
/// Returns the request length, 0 when there is nothing more to fetch, or -1 on
/// error. Callers loop: while `quack_needs_more()`, build a fetch, POST it, and
/// hand the reply to `quack_on_fetch_response`.
export fn quack_build_fetch() i32 {
    clearError();
    if (connection_id_len == 0) {
        setError("not connected", .{});
        return -1;
    }
    if (!needs_more) return 0;

    var alloc_state = std.heap.FixedBufferAllocator.init(&encode_buf);
    var buf: std.ArrayList(u8) = .empty;

    message.encodeMessage(alloc_state.allocator(), &buf, .{
        .type = .fetch_request,
        .connection_id = connection_id_buf[0..connection_id_len],
    }, message.FetchRequest{ .uuid = result_uuid }) catch {
        setError("failed to encode fetch request", .{});
        return -1;
    };
    return publishRequest(buf.items);
}

/// Decode a FETCH_RESPONSE placed in the response buffer.
///
/// Returns the number of chunks in this batch, or -1 on error. A batch of zero
/// chunks is the server's end-of-stream signal, after which `quack_needs_more`
/// reports 0.
export fn quack_on_fetch_response(len: usize) i32 {
    clearError();
    if (len > response_buf.len) {
        setError("response exceeds buffer", .{});
        return -1;
    }
    if (current == null) {
        setError("no active result", .{});
        return -1;
    }
    response_len = len;

    // Handles point into the batch we are about to free.
    handlesClear();

    // Release the previous batch before decoding the next, so resident memory
    // tracks one batch rather than the whole result.
    if (fetched) |*f| f.deinit();
    fetched = null;
    fetch_fba.reset();

    var r = Reader.init(response_buf[0..len]);
    const header = message.MessageHeader.decode(&r) catch {
        setError("malformed response header", .{});
        return -1;
    };

    switch (header.type) {
        .fetch_response => {},
        .error_response => {
            const e = message.ErrorResponse.decode(&r) catch {
                setError("malformed error response", .{});
                return -1;
            };
            setError("{s}", .{e.message});
            needs_more = false;
            return -1;
        },
        else => {
            setError("unexpected message type {d}", .{@intFromEnum(header.type)});
            return -1;
        },
    }

    const body = message.FetchResponse.decode(&r, fetch_fba.allocator()) catch {
        setError("failed to decode fetch batch", .{});
        return -1;
    };
    fetched = body;

    // FETCH_RESPONSE carries no `needs_more_fetch`; an empty batch ends the
    // stream (docs/PROTOCOL.md §8).
    if (body.chunks.len == 0) needs_more = false;
    return @intCast(body.chunks.len);
}

// -- parameter binding ---------------------------------------------------------
//
// Quack v1 has no wire format for parameters (see `src/params.zig`), so they are
// rendered into the SQL text. That escaping is security-critical, so JS does NOT
// reimplement it: the module exposes the same `params.bind` the native client
// uses, which is covered by the mutation suite.
//
// JS stages one parameter at a time (`quack_param_*`), then calls
// `quack_build_query_bound`.

const max_params = 128;
var param_list: [max_params]quackling.Param = undefined;
var param_count: usize = 0;
/// Backing store for text/blob parameter bytes, which must outlive the calls
/// that stage them.
var param_bytes: [256 * 1024]u8 = undefined;
var param_bytes_used: usize = 0;
/// Separate arena for the message encode, so it cannot collide with the staged
/// parameter bytes it reads from.
var bound_encode_buf: [1 * 1024 * 1024]u8 = undefined;

/// Discard any staged parameters. Call before staging a new set.
export fn quack_params_reset() void {
    param_count = 0;
    param_bytes_used = 0;
}

fn stage(p: quackling.Param) i32 {
    if (param_count >= max_params) {
        setError("too many parameters (max {d})", .{max_params});
        return -1;
    }
    param_list[param_count] = p;
    param_count += 1;
    return @intCast(param_count);
}

/// Copy caller bytes into module-owned storage, so the slice stays valid until
/// `quack_params_reset`.
fn stageBytes(ptr: [*]const u8, len: usize) ?[]const u8 {
    if (param_bytes_used + len > param_bytes.len) {
        setError("parameter storage exhausted", .{});
        return null;
    }
    const dst = param_bytes[param_bytes_used..][0..len];
    @memcpy(dst, ptr[0..len]);
    param_bytes_used += len;
    return dst;
}

export fn quack_param_null() i32 {
    return stage(.null);
}

export fn quack_param_bool(v: i32) i32 {
    return stage(.{ .boolean = v != 0 });
}

export fn quack_param_i64(v: i64) i32 {
    return stage(.{ .integer = v });
}

export fn quack_param_f64(v: f64) i32 {
    return stage(.{ .double = v });
}

export fn quack_param_text(ptr: [*]const u8, len: usize) i32 {
    const owned = stageBytes(ptr, len) orelse return -1;
    return stage(.{ .text = owned });
}

export fn quack_param_blob(ptr: [*]const u8, len: usize) i32 {
    const owned = stageBytes(ptr, len) orelse return -1;
    return stage(.{ .blob = owned });
}

/// A number too wide for f64/i64 (HUGEINT, DECIMAL), given as decimal text.
///
/// Passed through as a literal so no precision is lost on the way in, matching
/// how such values are read back out.
export fn quack_param_exact(ptr: [*]const u8, len: usize) i32 {
    const owned = stageBytes(ptr, len) orelse return -1;
    // Validate: only digits, a single optional sign and a single optional point.
    var seen_dot = false;
    for (owned, 0..) |c, i| {
        if (c == '-' or c == '+') {
            if (i != 0) {
                setError("malformed exact number", .{});
                return -1;
            }
        } else if (c == '.') {
            if (seen_dot) {
                setError("malformed exact number", .{});
                return -1;
            }
            seen_dot = true;
        } else if (c < '0' or c > '9') {
            setError("malformed exact number", .{});
            return -1;
        }
    }
    if (owned.len == 0) {
        setError("empty exact number", .{});
        return -1;
    }
    return stage(.{ .raw_sql = owned });
}

/// Build a PREPARE_REQUEST with the staged parameters substituted into `sql`.
///
/// Returns the request length, or -1 on error (including a placeholder/argument
/// count mismatch, which is caught here rather than by the server).
export fn quack_build_query_bound(sql_ptr: [*]const u8, sql_len: usize) i32 {
    clearError();
    if (connection_id_len == 0) {
        setError("not connected", .{});
        return -1;
    }
    if (sql_len > input_buf.len) {
        setError("query too large", .{});
        return -1;
    }

    var bind_state = std.heap.FixedBufferAllocator.init(&encode_buf);
    const bound = quackling.params.bind(
        bind_state.allocator(),
        sql_ptr[0..sql_len],
        param_list[0..param_count],
    ) catch |e| {
        setError("parameter binding failed: {s}", .{@errorName(e)});
        return -1;
    };

    // A second arena, because `bound` lives in the first one.
    var enc_state = std.heap.FixedBufferAllocator.init(&bound_encode_buf);
    var buf: std.ArrayList(u8) = .empty;
    message.encodeMessage(enc_state.allocator(), &buf, .{
        .type = .prepare_request,
        .connection_id = connection_id_buf[0..connection_id_len],
    }, message.PrepareRequest{ .sql = bound }) catch {
        setError("failed to encode query", .{});
        return -1;
    };
    return publishRequest(buf.items);
}

// -- append (bulk insert) ------------------------------------------------------
//
// `APPEND_REQUEST` hands DuckDB a whole DataChunk rather than an INSERT
// statement: measured at ~370x the throughput of one parameterised INSERT per
// row, because the data is already typed and no SQL is re-parsed.
//
// JS builds the chunk column by column, then sends it:
//
//   quack_append_reset()
//   quack_append_column(typeId, rows)     // begin a column
//   quack_append_<kind>(...)              // one call per value, in order
//   quack_build_append(schema, table)     // -> request bytes

const max_append_cols = 64;
var append_types: [max_append_cols]quackling.LogicalType = undefined;
var append_values: [max_append_cols][]quackling.Value = undefined;
var append_filled: [max_append_cols]usize = @splat(0);
var append_cols: usize = 0;
var append_rows: usize = 0;

/// Backing store for append values and their byte payloads.
var append_value_buf: [64 * 1024]quackling.Value = undefined;
var append_value_used: usize = 0;
var append_bytes: [4 * 1024 * 1024]u8 = undefined;
var append_bytes_used: usize = 0;

export fn quack_append_reset() void {
    append_cols = 0;
    append_rows = 0;
    append_value_used = 0;
    append_bytes_used = 0;
    append_filled = @splat(0);
}

/// Begin a column of `rows` values with DuckDB type `type_id`.
///
/// Every column must declare the same row count; the encoder refuses ragged
/// input rather than sending a chunk the server would reject.
export fn quack_append_column(type_id: i32, rows: usize) i32 {
    clearError();
    if (append_cols >= max_append_cols) {
        setError("too many append columns (max {d})", .{max_append_cols});
        return -1;
    }
    if (rows > quackling.serialization.encoder.max_rows) {
        setError("append chunk limited to {d} rows", .{quackling.serialization.encoder.max_rows});
        return -1;
    }
    if (append_cols == 0) {
        append_rows = rows;
    } else if (rows != append_rows) {
        setError("column row counts differ ({d} vs {d})", .{ rows, append_rows });
        return -1;
    }
    if (append_value_used + rows > append_value_buf.len) {
        setError("append value storage exhausted", .{});
        return -1;
    }

    append_types[append_cols] = .{ .id = @enumFromInt(@as(u8, @intCast(type_id))) };
    append_values[append_cols] = append_value_buf[append_value_used..][0..rows];
    append_value_used += rows;
    append_filled[append_cols] = 0;
    append_cols += 1;
    return @intCast(append_cols - 1);
}

/// Set DECIMAL width/scale on the column just opened, which the wire format
/// needs in order to pick a storage width.
export fn quack_append_decimal_info(col: usize, width: u8, scale: u8) i32 {
    if (col >= append_cols) {
        setError("column index out of range", .{});
        return -1;
    }
    append_types[col].decimal = .{ .width = width, .scale = scale };
    return 0;
}

fn appendValue(v: quackling.Value) i32 {
    if (append_cols == 0) {
        setError("no append column open", .{});
        return -1;
    }
    const col = append_cols - 1;
    if (append_filled[col] >= append_values[col].len) {
        setError("more values than the column's declared row count", .{});
        return -1;
    }
    append_values[col][append_filled[col]] = v;
    append_filled[col] += 1;
    return 0;
}

export fn quack_append_null() i32 {
    return appendValue(.null);
}
export fn quack_append_bool(v: i32) i32 {
    return appendValue(.{ .boolean = v != 0 });
}
export fn quack_append_i64(v: i64) i32 {
    return appendValue(.{ .bigint = v });
}
export fn quack_append_f64(v: f64) i32 {
    return appendValue(.{ .double = v });
}

export fn quack_append_text(ptr: [*]const u8, len: usize) i32 {
    const owned = appendBytes(ptr, len) orelse return -1;
    return appendValue(.{ .varchar = owned });
}

export fn quack_append_blob(ptr: [*]const u8, len: usize) i32 {
    const owned = appendBytes(ptr, len) orelse return -1;
    return appendValue(.{ .blob = owned });
}

/// A 128-bit integer, given as two halves so it survives the JS boundary
/// (wasm32 has no i128 ABI).
export fn quack_append_hugeint(hi: i64, lo: u64) i32 {
    const v: i128 = (@as(i128, hi) << 64) | @as(i128, lo);
    return appendValue(.{ .hugeint = v });
}

/// A DECIMAL's unscaled value, likewise split into halves.
export fn quack_append_decimal(hi: i64, lo: u64, width: u8, scale: u8) i32 {
    const raw: i128 = (@as(i128, hi) << 64) | @as(i128, lo);
    return appendValue(.{ .decimal = .{ .value = raw, .width = width, .scale = scale } });
}

fn appendBytes(ptr: [*]const u8, len: usize) ?[]const u8 {
    if (append_bytes_used + len > append_bytes.len) {
        setError("append byte storage exhausted", .{});
        return null;
    }
    const dst = append_bytes[append_bytes_used..][0..len];
    @memcpy(dst, ptr[0..len]);
    append_bytes_used += len;
    return dst;
}

/// Build the APPEND_REQUEST. Returns its length, or -1 on error.
export fn quack_build_append(
    schema_ptr: [*]const u8,
    schema_len: usize,
    table_ptr: [*]const u8,
    table_len: usize,
) i32 {
    clearError();
    if (connection_id_len == 0) {
        setError("not connected", .{});
        return -1;
    }
    if (append_cols == 0) {
        setError("no columns staged", .{});
        return -1;
    }
    // Every column must be fully populated, or the chunk would carry undefined
    // values into the database.
    var cols_buf: [max_append_cols]quackling.serialization.encoder.Column = undefined;
    for (0..append_cols) |i| {
        if (append_filled[i] != append_values[i].len) {
            setError("column {d} has {d} of {d} values", .{ i, append_filled[i], append_values[i].len });
            return -1;
        }
        cols_buf[i] = .{ .type = append_types[i], .values = append_values[i] };
    }

    var enc_state = std.heap.FixedBufferAllocator.init(&bound_encode_buf);
    var buf: std.ArrayList(u8) = .empty;
    message.encodeMessage(enc_state.allocator(), &buf, .{
        .type = .append_request,
        .connection_id = connection_id_buf[0..connection_id_len],
    }, message.AppendRequest{
        .schema_name = schema_ptr[0..schema_len],
        .table_name = table_ptr[0..table_len],
        .columns = cols_buf[0..append_cols],
        .allocator = enc_state.allocator(),
    }) catch |e| {
        setError("failed to encode append: {s}", .{@errorName(e)});
        return -1;
    };
    return publishRequest(buf.items);
}

/// Decode the SUCCESS_RESPONSE (or ERROR_RESPONSE) to an append.
export fn quack_on_append_response(len: usize) i32 {
    clearError();
    if (len > response_buf.len) {
        setError("response exceeds buffer", .{});
        return -1;
    }
    var r = Reader.init(response_buf[0..len]);
    const header = message.MessageHeader.decode(&r) catch {
        setError("malformed response header", .{});
        return -1;
    };
    switch (header.type) {
        .success_response => return 0,
        .error_response => {
            const e = message.ErrorResponse.decode(&r) catch {
                setError("malformed error response", .{});
                return -1;
            };
            setError("{s}", .{e.message});
            return -1;
        },
        else => {
            setError("unexpected message type {d}", .{@intFromEnum(header.type)});
            return -1;
        },
    }
}

// -- nested value navigation ---------------------------------------------------
//
// A nested value cannot be addressed by `(chunk, col, row)` alone: a STRUCT
// field or a LIST element lives in a *child* vector, at a row index that only
// the parent knows. Flattening nested data into JS objects inside the module
// would mean copying it, which defeats the point of decoding in WASM.
//
// Instead JS gets an opaque handle per vector and walks the tree itself:
//
//   h = quack_vector_open(chunk, col)      // the column's vector
//   quack_vector_kind(h)                   // struct / list / array / map / ...
//   c = quack_vector_child(h, i)           // descend
//   quack_vector_list_offset(h, row)       // where row's elements start
//   quack_vector_value_kind(h, row)        // then the usual value accessors
//   quack_vector_close(h)
//
// Handles are indices into a fixed table, so an invalid one is rejected rather
// than dereferenced. They are invalidated by the next batch, like every other
// pointer this module hands out.

const max_handles = 64;
var handles: [max_handles]?*const quackling.Vector = @splat(null);

fn handleGet(h: i32) ?*const quackling.Vector {
    if (h < 0 or h >= max_handles) return null;
    return handles[@intCast(h)];
}

fn handlePut(v: *const quackling.Vector) i32 {
    for (&handles, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = v;
            return @intCast(i);
        }
    }
    return -1; // table full; caller must close some
}

fn handlesClear() void {
    handles = @splat(null);
}

/// How a vector is shaped, so JS knows which navigation calls apply.
pub const VectorShape = enum(i32) {
    /// Scalar column: use `quack_vector_value_kind` + the value accessors.
    flat = 0,
    /// Fields are children; every field shares the parent's row index.
    @"struct" = 1,
    /// One child; `list_offset`/`list_length` give each row's window.
    list = 2,
    /// One child; fixed `array_size` elements per row.
    array = 3,
    /// Physically a list of struct(key,value); children 0/1 of the list child.
    map = 4,
    /// Physically a struct whose child 0 is a UTINYINT tag.
    @"union" = 5,
    invalid = -1,
};

/// Open a handle on column `col` of `chunk`. Returns -1 on failure.
export fn quack_vector_open(chunk: usize, col: usize) i32 {
    clearError();
    const chunks = activeChunks();
    if (chunk >= chunks.len) {
        setError("chunk index out of range", .{});
        return -1;
    }
    const v = chunks[chunk].column(col) orelse {
        setError("column index out of range", .{});
        return -1;
    };
    const h = handlePut(v);
    if (h < 0) setError("too many open vector handles", .{});
    return h;
}

export fn quack_vector_close(h: i32) void {
    if (h < 0 or h >= max_handles) return;
    handles[@intCast(h)] = null;
}

/// Classify a vector so JS picks the right navigation.
export fn quack_vector_kind(h: i32) i32 {
    const v = handleGet(h) orelse return @intFromEnum(VectorShape.invalid);
    return @intFromEnum(switch (v.type.id) {
        .@"struct", .variant => VectorShape.@"struct",
        .list => VectorShape.list,
        .array => VectorShape.array,
        .map => VectorShape.map,
        .@"union" => VectorShape.@"union",
        else => VectorShape.flat,
    });
}

/// Number of children (STRUCT/VARIANT fields, or 1 for LIST/ARRAY/MAP).
export fn quack_vector_child_count(h: i32) i32 {
    const v = handleGet(h) orelse return -1;
    if (v.children()) |kids| return @intCast(kids.len);
    if (v.listChild() != null) return 1;
    return 0;
}

/// A child's declared field name, for STRUCT. Empty for positional children.
export fn quack_vector_child_name_ptr(h: i32, i: usize) [*]const u8 {
    const v = handleGet(h) orelse return "";
    if (i >= v.type.children.len) return "";
    return v.type.children[i].name.ptr;
}

export fn quack_vector_child_name_len(h: i32, i: usize) usize {
    const v = handleGet(h) orelse return 0;
    if (i >= v.type.children.len) return 0;
    return v.type.children[i].name.len;
}

/// Open a handle on child `i`. For LIST/ARRAY/MAP, `i` is ignored (one child).
export fn quack_vector_child(h: i32, i: usize) i32 {
    clearError();
    const v = handleGet(h) orelse {
        setError("invalid vector handle", .{});
        return -1;
    };
    if (v.children()) |kids| {
        if (i >= kids.len) {
            setError("child index out of range", .{});
            return -1;
        }
        return handlePut(&kids[i]);
    }
    if (v.listChild()) |child| return handlePut(child);
    setError("vector has no children", .{});
    return -1;
}

/// The declared LogicalTypeId of a vector, so JS can label values.
export fn quack_vector_type(h: i32) i32 {
    const v = handleGet(h) orelse return -1;
    return @intFromEnum(v.type.id);
}

/// For LIST/MAP: where row `row`'s elements begin in the child vector.
export fn quack_vector_list_offset(h: i32, row: usize) i64 {
    const v = handleGet(h) orelse return -1;
    const e = v.listEntry(row) orelse return -1;
    return @intCast(e.offset);
}

/// For LIST/MAP: how many elements row `row` has.
export fn quack_vector_list_length(h: i32, row: usize) i64 {
    const v = handleGet(h) orelse return -1;
    const e = v.listEntry(row) orelse return -1;
    return @intCast(e.length);
}

/// For ARRAY: the fixed element count per row.
export fn quack_vector_array_size(h: i32) i64 {
    const v = handleGet(h) orelse return -1;
    const n = v.arraySize() orelse return -1;
    return @intCast(n);
}

/// For UNION: which member is active in row `row`, or -1.
export fn quack_vector_union_tag(h: i32, row: usize) i32 {
    const v = handleGet(h) orelse return -1;
    const u = v.unionValue(row) orelse return -1;
    return u.tag;
}

/// Rows in this vector (the child of a list holds all rows of all lists).
export fn quack_vector_row_count(h: i32) usize {
    const v = handleGet(h) orelse return 0;
    return v.count;
}

export fn quack_vector_is_null(h: i32, row: usize) i32 {
    const v = handleGet(h) orelse return 1;
    return if (v.isNull(row)) 1 else 0;
}

/// `quack_value_kind`, but for a handle rather than a (chunk,col).
export fn quack_vector_value_kind(h: i32, row: usize) i32 {
    const v = handleGet(h) orelse return @intFromEnum(ValueKind.unsupported);
    if (v.isNull(row)) return @intFromEnum(ValueKind.is_null);
    const val = v.getValue(row) catch return @intFromEnum(ValueKind.unsupported);
    return @intFromEnum(classify(val));
}

export fn quack_vector_get_i64(h: i32, row: usize) i64 {
    const v = handleGet(h) orelse return 0;
    const val = v.getValue(row) catch return 0;
    return val.asI64() orelse 0;
}

export fn quack_vector_get_f64(h: i32, row: usize) f64 {
    const v = handleGet(h) orelse return 0;
    const val = v.getValue(row) catch return 0;
    return val.asF64() orelse 0;
}

export fn quack_vector_get_bytes_ptr(h: i32, row: usize) ?[*]const u8 {
    const s = vectorBytes(h, row) orelse return null;
    return s.ptr;
}

export fn quack_vector_get_bytes_len(h: i32, row: usize) usize {
    const s = vectorBytes(h, row) orelse return 0;
    return s.len;
}

fn vectorBytes(h: i32, row: usize) ?[]const u8 {
    const v = handleGet(h) orelse return null;
    const val = v.getValue(row) catch return null;
    return renderBytes(val);
}

/// The fixed-width payload of a flat child vector, for the zero-copy path.
export fn quack_vector_data_ptr(h: i32) ?[*]const u8 {
    const v = handleGet(h) orelse return null;
    return switch (v.storage) {
        .fixed => |b| b.ptr,
        else => null,
    };
}

export fn quack_vector_data_len(h: i32) usize {
    const v = handleGet(h) orelse return 0;
    return switch (v.storage) {
        .fixed => |b| b.len,
        else => 0,
    };
}

// -- result inspection --------------------------------------------------------

export fn quack_column_count() usize {
    const c = current orelse return 0;
    return c.types.len;
}

export fn quack_column_name_ptr(i: usize) [*]const u8 {
    const c = current orelse return "";
    if (i >= c.names.len) return "";
    return c.names[i].ptr;
}

export fn quack_column_name_len(i: usize) usize {
    const c = current orelse return 0;
    if (i >= c.names.len) return 0;
    return c.names[i].len;
}

/// The DuckDB `LogicalTypeId` of column `i`, so JS can pick the right
/// TypedArray (Int32Array, Float64Array, ...).
export fn quack_column_type(i: usize) i32 {
    const c = current orelse return -1;
    if (i >= c.types.len) return -1;
    return @intFromEnum(c.types[i].id);
}

/// The chunks of the batch currently in hand: the PREPARE batch until the first
/// FETCH, then each FETCH batch in turn.
fn activeChunks() []const quackling.DataChunk {
    if (fetched) |f| return f.chunks;
    const c = current orelse return &.{};
    return c.chunks;
}

export fn quack_chunk_count() usize {
    return activeChunks().len;
}

/// 1 when the server has more rows for this result, i.e. JS should build a
/// FETCH request and keep going.
///
/// Without consulting this, a caller silently sees only the first batch - which
/// for `SELECT ... FROM range(1000000)` is about 2% of the rows.
export fn quack_needs_more() i32 {
    return if (needs_more) 1 else 0;
}

export fn quack_chunk_rows(chunk: usize) usize {
    const chunks = activeChunks();
    if (chunk >= chunks.len) return 0;
    return chunks[chunk].row_count;
}

/// Pointer to a fixed-width column's raw payload **inside WASM linear memory**.
///
/// This is the low-copy path (todo.md §16): JS wraps it in a TypedArray and
/// reads the values with no marshalling at all. Returns null when the column is
/// not a flat fixed-width vector, in which case JS must fall back to the
/// per-value accessors.
export fn quack_column_data_ptr(chunk: usize, col: usize) ?[*]const u8 {
    const chunks = activeChunks();
    if (chunk >= chunks.len) return null;
    const v = chunks[chunk].column(col) orelse return null;
    return switch (v.storage) {
        .fixed => |b| b.ptr,
        else => null,
    };
}

export fn quack_column_data_len(chunk: usize, col: usize) usize {
    const chunks = activeChunks();
    if (chunk >= chunks.len) return 0;
    const v = chunks[chunk].column(col) orelse return 0;
    return switch (v.storage) {
        .fixed => |b| b.len,
        else => 0,
    };
}

/// 1 when row `row` of column `col` is NULL.
export fn quack_is_null(chunk: usize, col: usize, row: usize) i32 {
    const chunks = activeChunks();
    if (chunk >= chunks.len) return 1;
    return if (chunks[chunk].isNull(col, row)) 1 else 0;
}

/// Integer value of a cell, for the row-at-a-time path.
export fn quack_get_i64(chunk: usize, col: usize, row: usize) i64 {
    const chunks = activeChunks();
    if (chunk >= chunks.len) return 0;
    const v = chunks[chunk].getValue(col, row) catch return 0;
    return v.asI64() orelse 0;
}

/// How a cell can be read, so JS picks the right accessor instead of guessing
/// from the logical type.
///
/// Returning a kind rather than a bare value is what stops a nested column from
/// silently reading as `0`: JS sees `unsupported` and can surface it.
pub const ValueKind = enum(i32) {
    is_null = 0,
    integer = 1,
    float = 2,
    /// Read with `quack_get_bytes_ptr`/`_len` and decode as UTF-8.
    text = 3,
    /// Read with `quack_get_bytes_ptr`/`_len` and keep as bytes.
    bytes = 4,
    /// A number too wide for f64/i64 (HUGEINT, UHUGEINT, DECIMAL). Read with
    /// `quack_get_bytes_ptr`/`_len` and parse the exact decimal text.
    exact_number = 6,
    /// A value this build cannot represent as a scalar (STRUCT, LIST, MAP,
    /// UNION, ARRAY, VARIANT). Not an error - just not a scalar.
    unsupported = 5,
};

/// Classify a cell. JS calls this once per value and then reads accordingly.
export fn quack_value_kind(chunk: usize, col: usize, row: usize) i32 {
    const chunks = activeChunks();
    if (chunk >= chunks.len) return @intFromEnum(ValueKind.unsupported);
    const c = &chunks[chunk];
    if (c.isNull(col, row)) return @intFromEnum(ValueKind.is_null);

    const v = c.getValue(col, row) catch |e| switch (e) {
        // A nested type is reachable through the vector handle API, not through
        // the flat Value union; report that rather than a wrong scalar.
        error.UnsupportedType => return @intFromEnum(ValueKind.unsupported),
        else => return @intFromEnum(ValueKind.unsupported),
    };
    return @intFromEnum(classify(v));
}

/// Map a decoded value onto the kind JS should read it as.
///
/// Shared by the `(chunk, col, row)` and vector-handle paths so the two can
/// never disagree about how a type is read.
fn classify(v: quackling.Value) ValueKind {
    return switch (v) {
        .null => ValueKind.is_null,
        .boolean, .tinyint, .smallint, .integer, .bigint, .utinyint, .usmallint, .uinteger, .ubigint => ValueKind.integer,
        .float, .double => ValueKind.float,
        // 128-bit integers and DECIMAL cannot survive `i64`/`f64`: HUGEINT max
        // overflows `asI64` (which used to yield 0) and DECIMAL(30,2) loses
        // digits through a double. Render them exactly and let JS build a
        // BigInt or a decimal string from the text.
        .hugeint, .uhugeint, .decimal => ValueKind.exact_number,
        // Temporal and identifier types read as their canonical text form. A
        // raw day/microsecond count would push calendar arithmetic onto every
        // caller; the formatted value is what a JS consumer actually wants.
        .varchar, .@"enum", .uuid, .interval, .date, .time, .timestamp => ValueKind.text,
        .blob => ValueKind.bytes,
    };
}

export fn quack_get_f64(chunk: usize, col: usize, row: usize) f64 {
    const chunks = activeChunks();
    if (chunk >= chunks.len) return 0;
    const v = chunks[chunk].getValue(col, row) catch return 0;
    return v.asF64() orelse 0;
}

/// Scratch for values that have no byte run of their own on the wire (UUID,
/// INTERVAL, DATE/TIME/TIMESTAMP when rendered as text) and must be formatted.
var text_scratch: [256]u8 = undefined;
var text_len: usize = 0;

/// Resolve a cell to bytes, formatting into `text_scratch` when the value has no
/// borrowable slice. Returns null when the cell is not byte-readable.
fn cellBytes(chunk: usize, col: usize, row: usize) ?[]const u8 {
    const chunks = activeChunks();
    if (chunk >= chunks.len) return null;
    const v = chunks[chunk].getValue(col, row) catch return null;
    return renderBytes(v);
}

/// Resolve a value to bytes JS can read: borrowed when the wire already holds a
/// byte run, formatted into scratch otherwise.
fn renderBytes(v: quackling.Value) ?[]const u8 {
    if (v.asSlice()) |s| return s; // VARCHAR/BLOB/ENUM borrow the chunk buffer
    switch (v) {
        .uuid, .interval, .date, .time, .timestamp, .hugeint, .uhugeint, .decimal => {
            var w = std.Io.Writer.fixed(&text_scratch);
            v.format(&w) catch return null;
            text_len = w.buffered().len;
            return text_scratch[0..text_len];
        },
        else => return null,
    }
}

/// VARCHAR/BLOB/ENUM cell as a pointer into linear memory. JS decodes with
/// TextDecoder (or keeps the bytes, per `quack_value_kind`).
export fn quack_get_bytes_ptr(chunk: usize, col: usize, row: usize) ?[*]const u8 {
    const s = cellBytes(chunk, col, row) orelse return null;
    return s.ptr;
}

export fn quack_get_bytes_len(chunk: usize, col: usize, row: usize) usize {
    const s = cellBytes(chunk, col, row) orelse return 0;
    return s.len;
}

// -- errors -------------------------------------------------------------------

export fn quack_last_error_ptr() [*]const u8 {
    return &last_error_buf;
}

export fn quack_last_error_len() usize {
    return last_error_len;
}

export fn quack_reset() void {
    handlesClear();
    if (fetched) |*f| f.deinit();
    fetched = null;
    if (current) |*c| c.deinit();
    current = null;
    current_chunk = 0;
    needs_more = false;
    result_uuid = 0;
    fetch_fba.reset();
    connection_id_len = 0;
    request_len = 0;
    response_len = 0;
    clearError();
    fba.reset();
}

/// Freestanding wasm has no default panic handler that can do anything useful;
/// trap instead of trying to format a message into nowhere.
pub const panic = std.debug.FullPanic(struct {
    fn panicFn(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.panicFn);
