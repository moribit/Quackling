//! A streaming query result.
//!
//! Chunks are surfaced as they arrive and released as soon as the consumer
//! moves on, so peak memory tracks the batch size rather than the result size
//! (todo.md §12). The loop is:
//!
//! ```zig
//! while (try result.nextChunk()) |chunk| { ... }
//! ```
//!
//! Each `chunk` stays valid until the next `nextChunk` call, which is what
//! keeps the decode zero-copy: the chunk's payload points into the HTTP
//! response buffer that `Result` is holding.

const std = @import("std");
const msg = @import("protocol/message.zig");
const transport_mod = @import("transport/transport.zig");
const data_chunk_mod = @import("types/data_chunk.zig");
const lt = @import("types/logical_type.zig");
const value_mod = @import("types/value.zig");
const errors = @import("error.zig");

const DataChunk = data_chunk_mod.DataChunk;
const LogicalType = lt.LogicalType;
const Value = value_mod.Value;
const CancelToken = transport_mod.CancelToken;

pub const Error = errors.QueryError;

/// One batch of chunks plus the response buffer they borrow from.
const Batch = struct {
    response: transport_mod.Response,
    chunks: []DataChunk,
    /// Set when the chunks came from a FETCH (vs the initial PREPARE).
    fetch: ?msg.FetchResponse = null,
    prepare: ?msg.PrepareResponse = null,
};

pub const Result = struct {
    client: *@import("client.zig").Client,
    allocator: std.mem.Allocator,

    /// Column metadata. Borrowed from the PREPARE response buffer, which this
    /// Result keeps alive for its whole lifetime.
    types: []LogicalType,
    names: [][]const u8,

    /// The PREPARE response: held because `types`/`names` point into it.
    prepare_response: transport_mod.Response,
    prepared: msg.PrepareResponse,

    /// Chunks not yet handed to the caller, from the current batch.
    pending: []DataChunk,
    pending_index: usize = 0,

    /// A FETCH batch currently being drained. Freed when exhausted.
    current_fetch: ?struct {
        response: transport_mod.Response,
        body: msg.FetchResponse,
    } = null,

    result_uuid: i128,
    /// The client's query generation when this result was created. A newer
    /// query on the same client makes this result stale, because the server
    /// only tracks one cursor per connection.
    generation: u64,
    needs_more_fetch: bool,
    cancel: ?*CancelToken,
    finished: bool = false,

    rows_seen: u64 = 0,
    chunks_seen: u64 = 0,
    fetches: u64 = 0,

    /// Upper bound on FETCH round trips for a single result.
    ///
    /// End-of-stream is signalled by the *server* sending an empty batch, so a
    /// server that never does would otherwise loop forever. At the documented
    /// batch size (12 chunks x 2048 rows) this ceiling still allows well over
    /// 10^11 rows, so it cannot be reached by legitimate use - it exists purely
    /// to keep a broken or hostile peer from hanging the caller (todo.md §21).
    max_fetches: u64 = 5_000_000,

    pub fn init(
        client: *@import("client.zig").Client,
        response: transport_mod.Response,
        prepared: msg.PrepareResponse,
        cancel: ?*CancelToken,
    ) Result {
        return .{
            .client = client,
            .allocator = client.allocator,
            .types = prepared.types,
            .names = prepared.names,
            .prepare_response = response,
            .prepared = prepared,
            .pending = prepared.chunks,
            .result_uuid = prepared.result_uuid,
            .generation = client.query_generation,
            .needs_more_fetch = prepared.needs_more_fetch,
            .cancel = cancel,
        };
    }

    pub fn deinit(self: *Result) void {
        self.releaseFetch();
        self.prepared.deinit();
        self.prepare_response.deinit(self.allocator);
        self.types = &.{};
        self.names = &.{};
        self.pending = &.{};
        self.finished = true;
    }

    fn releaseFetch(self: *Result) void {
        if (self.current_fetch) |*f| {
            f.body.deinit();
            f.response.deinit(self.allocator);
            self.current_fetch = null;
        }
    }

    pub fn columnCount(self: *const Result) usize {
        return self.types.len;
    }

    pub fn columnName(self: *const Result, i: usize) ?[]const u8 {
        if (i >= self.names.len) return null;
        return self.names[i];
    }

    pub fn columnType(self: *const Result, i: usize) ?LogicalType {
        if (i >= self.types.len) return null;
        return self.types[i];
    }

    /// Index of the column called `name`, or null.
    pub fn columnIndex(self: *const Result, name: []const u8) ?usize {
        for (self.names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return i;
        }
        return null;
    }

    /// The next chunk, or null when the result is exhausted.
    ///
    /// The returned pointer is invalidated by the following `nextChunk` call.
    pub fn nextChunk(self: *Result) Error!?*const DataChunk {
        if (self.finished) return null;

        while (true) {
            if (self.cancel) |c| if (c.isCancelled()) return errors.TransportError.Cancelled;

            if (self.pending_index < self.pending.len) {
                const chunk = &self.pending[self.pending_index];
                self.pending_index += 1;
                self.rows_seen += chunk.row_count;
                self.chunks_seen += 1;
                self.client.stats.chunks_received += 1;
                self.client.stats.rows_received += chunk.row_count;
                if (self.client.options.observer) |o| o.onChunk(chunk.row_count);
                return chunk;
            }

            // Current batch drained.
            if (!self.needs_more_fetch) {
                self.finished = true;
                return null;
            }
            try self.fetchNextBatch();
        }
    }

    fn fetchNextBatch(self: *Result) Error!void {
        // A newer query on this client has already reset the server-side
        // cursor, so anything we fetched now would belong to that query.
        if (self.generation != self.client.query_generation) {
            self.finished = true;
            return errors.ProtocolError.ResultSuperseded;
        }
        if (self.fetches >= self.max_fetches) {
            self.finished = true;
            return errors.ProtocolError.FetchLimitExceeded;
        }
        self.fetches += 1;

        // Release the previous FETCH batch before asking for another, so only
        // one batch is resident at a time.
        self.releaseFetch();

        const got = try self.client.fetch(self.result_uuid, self.cancel);
        self.current_fetch = .{ .response = got.response, .body = got.body };
        self.pending = got.body.chunks;
        self.pending_index = 0;

        // FETCH_RESPONSE carries no `needs_more_fetch`; an empty batch is the
        // end-of-stream signal (docs/PROTOCOL.md §8).
        if (got.body.chunks.len == 0) {
            self.needs_more_fetch = false;
            self.finished = true;
        }
    }

    /// Row-at-a-time convenience over the chunk stream.
    pub fn rows(self: *Result) RowStream {
        return .{ .result = self };
    }

    /// Drain the whole result, counting rows. Useful for DDL/DML statements.
    pub fn drain(self: *Result) Error!u64 {
        while (try self.nextChunk()) |_| {}
        return self.rows_seen;
    }

    /// Fetch exactly one value from the first row/column. Convenience for
    /// scalar queries like `SELECT 42`.
    pub fn scalar(self: *Result) Error!?Value {
        const chunk = try self.nextChunk() orelse return null;
        if (chunk.row_count == 0 or chunk.columnCount() == 0) return null;
        return try chunk.getValue(0, 0);
    }
};

/// Row cursor that transparently walks chunk boundaries.
pub const RowStream = struct {
    result: *Result,
    chunk: ?*const DataChunk = null,
    index: usize = 0,

    pub fn next(self: *RowStream) Error!?data_chunk_mod.Row {
        while (true) {
            if (self.chunk) |c| {
                if (self.index < c.row_count) {
                    const row = data_chunk_mod.Row{ .chunk = c, .index = self.index };
                    self.index += 1;
                    return row;
                }
            }
            self.chunk = try self.result.nextChunk() orelse return null;
            self.index = 0;
        }
    }
};
