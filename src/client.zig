//! The public Quack client.
//!
//! Owns a connection's identity and the buffers reused across requests. One
//! `Client` is one logical Quack connection; it holds no global state, so many
//! can coexist in one process (todo.md §17).

const std = @import("std");
const msg = @import("protocol/message.zig");
const compat = @import("protocol/compat.zig");
const transport_mod = @import("transport/transport.zig");
const reader_mod = @import("serialization/reader.zig");
const uri_mod = @import("uri.zig");
const errors = @import("error.zig");
const result_mod = @import("result.zig");
const stats_mod = @import("stats.zig");
const params_mod = @import("params.zig");
const encoder_mod = @import("serialization/encoder.zig");

const Reader = reader_mod.Reader;
const Transport = transport_mod.Transport;
const CancelToken = transport_mod.CancelToken;

pub const Error = errors.QueryError;
pub const Param = params_mod.Param;
pub const Result = result_mod.Result;
pub const Stats = stats_mod.Stats;

pub const Options = struct {
    allocator: std.mem.Allocator,
    /// `quack:host[:port]`, or a plain `http://host:port` URL.
    endpoint: []const u8,
    /// Auth token. Sent inside the protocol message, never logged.
    token: []const u8 = "",
    /// Transport to use. Required: the core library does not pick one for you,
    /// which is what keeps it usable from wasm (todo.md §5).
    transport: Transport,
    /// Extra HTTP headers, e.g. for an authenticating proxy.
    headers: []const transport_mod.Header = &.{},
    /// Per-request deadline handed to the transport.
    timeout_ms: ?u32 = null,
    /// Refuse to decode a response larger than this.
    max_response_bytes: usize = 256 * 1024 * 1024,
    /// Observability hook; see `stats.zig`.
    observer: ?stats_mod.Observer = null,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    options: Options,

    /// Full request URL, e.g. `http://localhost:9494/quack`. Owned.
    url: []const u8,
    /// Session id from the handshake. Owned; empty until connected.
    connection_id: []const u8 = "",
    /// Server identity, learned at handshake. Owned.
    server_version: []const u8 = "",
    server_platform: []const u8 = "",
    quack_version: u64 = 0,

    /// Reused across requests so steady-state querying does not allocate a new
    /// send buffer each time (todo.md §14).
    send_buf: std.ArrayList(u8) = .empty,

    last_error: errors.ErrorInfo = .{},
    stats: Stats = .{},

    /// Incremented on every PREPARE. A `Result` records the value it was
    /// created with and refuses to FETCH once it changes.
    ///
    /// The server keeps exactly one result cursor per connection and resets it
    /// on each PREPARE (`quack_server.cpp`), so starting a second query
    /// silently invalidates the first result. Without this counter the stale
    /// result would FETCH against a discarded cursor and surface a confusing
    /// server error instead of the caller's actual mistake.
    query_generation: u64 = 0,

    pub fn init(options: Options) Error!Client {
        const parsed = try uri_mod.parse(options.endpoint);
        const url = try parsed.toHttpUrl(options.allocator);
        errdefer options.allocator.free(url);

        return .{
            .allocator = options.allocator,
            .transport = options.transport,
            .options = options,
            .url = url,
        };
    }

    pub fn deinit(self: *Client) void {
        // Best-effort DISCONNECT so the server can retire the session promptly.
        if (self.connection_id.len > 0) {
            self.disconnect() catch {};
        }
        self.allocator.free(self.url);
        if (self.connection_id.len > 0) self.allocator.free(self.connection_id);
        if (self.server_version.len > 0) self.allocator.free(self.server_version);
        if (self.server_platform.len > 0) self.allocator.free(self.server_platform);
        self.send_buf.deinit(self.allocator);
        self.last_error.deinit();
        self.connection_id = "";
    }

    pub fn isConnected(self: *const Client) bool {
        return self.connection_id.len > 0;
    }

    /// Last server-provided error text. Empty when there was none.
    pub fn lastError(self: *const Client) []const u8 {
        return self.last_error.message;
    }

    // -- handshake ------------------------------------------------------------

    pub fn connect(self: *Client, cancel: ?*CancelToken) Error!void {
        if (self.isConnected()) return;

        try msg.encodeMessage(self.allocator, &self.send_buf, .{
            .type = .connection_request,
        }, msg.ConnectionRequest{ .auth_string = self.options.token });

        var response = try self.roundTrip(cancel);
        defer response.deinit(self.allocator);

        var r = self.makeReader(response.body);
        const header = try msg.MessageHeader.decode(&r);

        switch (header.type) {
            .connection_response => {},
            .error_response => {
                const e = try msg.ErrorResponse.decode(&r);
                try self.last_error.set(self.allocator, e.message);
                // The server reports a bad token as a normal error response;
                // classify it so callers can distinguish auth from bad SQL.
                return if (isAuthMessage(e.message))
                    errors.AuthenticationError.AuthenticationFailed
                else
                    errors.ServerError.ServerError;
            },
            else => return errors.ProtocolError.UnexpectedMessageType,
        }

        const body = try msg.ConnectionResponse.decode(&r);

        if (body.quack_version < compat.min_supported_version or
            body.quack_version > compat.max_supported_version)
        {
            return errors.ProtocolError.UnsupportedProtocolVersion;
        }

        // The session id lives in the header, not the body.
        if (header.connection_id.len == 0) return errors.ProtocolError.UnexpectedMessageType;

        self.connection_id = try self.allocator.dupe(u8, header.connection_id);
        self.server_version = try self.allocator.dupe(u8, body.server_duckdb_version);
        self.server_platform = try self.allocator.dupe(u8, body.server_platform);
        self.quack_version = body.quack_version;
        self.stats.connects += 1;
    }

    pub fn disconnect(self: *Client) Error!void {
        if (!self.isConnected()) return;
        try msg.encodeMessage(self.allocator, &self.send_buf, .{
            .type = .disconnect_message,
            .connection_id = self.connection_id,
        }, msg.DisconnectRequest{});
        var response = self.roundTrip(null) catch |e| {
            // Teardown is best-effort; drop the session either way.
            self.allocator.free(self.connection_id);
            self.connection_id = "";
            return e;
        };
        response.deinit(self.allocator);
        self.allocator.free(self.connection_id);
        self.connection_id = "";
    }

    // -- queries --------------------------------------------------------------

    /// Run `sql` and return a streaming result.
    ///
    /// The result borrows this client; it must be `deinit`ed before the client
    /// is, and only one result may be open at a time (the protocol is a single
    /// request/response channel per connection).
    pub fn query(self: *Client, sql: []const u8) Error!Result {
        return self.queryWithCancel(sql, null);
    }

    pub fn queryWithCancel(self: *Client, sql: []const u8, cancel: ?*CancelToken) Error!Result {
        if (!self.isConnected()) try self.connect(cancel);

        try msg.encodeMessage(self.allocator, &self.send_buf, .{
            .type = .prepare_request,
            .connection_id = self.connection_id,
        }, msg.PrepareRequest{ .sql = sql });

        // The server calls `duckdb_query_result.reset()` as soon as it accepts a
        // PREPARE - *before* running the SQL (quack_server.cpp). So the previous
        // cursor is gone even when the new query then fails. Bump the generation
        // here, not on success, or a failed query would leave an older result
        // looking valid while its cursor no longer exists.
        self.query_generation += 1;

        var response = try self.roundTrip(cancel);
        errdefer response.deinit(self.allocator);

        var r = self.makeReader(response.body);
        const header = try msg.MessageHeader.decode(&r);

        switch (header.type) {
            .prepare_response => {},
            .error_response => {
                const e = try msg.ErrorResponse.decode(&r);
                try self.last_error.set(self.allocator, e.message);
                self.stats.server_errors += 1;
                response.deinit(self.allocator);
                return errors.ServerError.ServerError;
            },
            else => {
                response.deinit(self.allocator);
                return errors.ProtocolError.UnexpectedMessageType;
            },
        }

        const prepared = try msg.PrepareResponse.decode(&r, self.allocator);
        self.stats.queries += 1;

        return Result.init(self, response, prepared, cancel);
    }

    /// Run `sql` with `?` placeholders substituted from `params`.
    ///
    /// Quack v1 has no wire format for parameters (see `params.zig`), so the
    /// values are rendered into the SQL text with strict escaping before it is
    /// sent. This is safe against injection for every `Param` variant except
    /// `.raw_sql`, which is inserted verbatim by definition.
    pub fn queryParams(self: *Client, sql: []const u8, args: []const Param) Error!Result {
        return self.queryParamsWithCancel(sql, args, null);
    }

    pub fn queryParamsWithCancel(
        self: *Client,
        sql: []const u8,
        args: []const Param,
        cancel: ?*CancelToken,
    ) Error!Result {
        // No parameters means no rewriting - send the caller's SQL untouched.
        if (args.len == 0) return self.queryWithCancel(sql, cancel);
        const bound = try params_mod.bind(self.allocator, sql, args);
        defer self.allocator.free(bound);
        return self.queryWithCancel(bound, cancel);
    }

    /// Convenience: run a statement and discard any result rows.
    pub fn exec(self: *Client, sql: []const u8) Error!void {
        var res = try self.query(sql);
        defer res.deinit();
        while (try res.nextChunk()) |_| {}
    }

    /// Bulk-insert rows into an existing table.
    ///
    /// This is the `APPEND_REQUEST` path, which hands DuckDB a whole DataChunk
    /// instead of an INSERT statement - far cheaper than a statement per row,
    /// and it avoids re-parsing SQL for data that is already typed.
    ///
    /// The table must exist and `columns` must match its schema in order and
    /// type; the server rejects a mismatch. At most
    /// `serialization.encoder.max_rows` (2048) rows per call.
    pub fn append(
        self: *Client,
        table: []const u8,
        columns: []const encoder_mod.Column,
    ) Error!void {
        return self.appendToSchema("main", table, columns, null);
    }

    pub fn appendToSchema(
        self: *Client,
        schema: []const u8,
        table: []const u8,
        columns: []const encoder_mod.Column,
        cancel: ?*CancelToken,
    ) Error!void {
        if (!self.isConnected()) try self.connect(cancel);

        try msg.encodeMessage(self.allocator, &self.send_buf, .{
            .type = .append_request,
            .connection_id = self.connection_id,
        }, msg.AppendRequest{
            .schema_name = schema,
            .table_name = table,
            .columns = columns,
            .allocator = self.allocator,
        });

        var response = try self.roundTrip(cancel);
        defer response.deinit(self.allocator);

        var r = self.makeReader(response.body);
        const header = try msg.MessageHeader.decode(&r);
        switch (header.type) {
            .success_response => {},
            .error_response => {
                const e = try msg.ErrorResponse.decode(&r);
                try self.last_error.set(self.allocator, e.message);
                self.stats.server_errors += 1;
                return errors.ServerError.ServerError;
            },
            else => return errors.ProtocolError.UnexpectedMessageType,
        }
        self.stats.appends += 1;
    }

    /// `exec` with bound parameters.
    pub fn execParams(self: *Client, sql: []const u8, args: []const Param) Error!void {
        var res = try self.queryParams(sql, args);
        defer res.deinit();
        while (try res.nextChunk()) |_| {}
    }

    // -- internals used by Result --------------------------------------------

    /// Issue a FETCH for `uuid`. Returns the raw response plus the decoded body;
    /// the caller owns both.
    pub fn fetch(
        self: *Client,
        uuid: i128,
        cancel: ?*CancelToken,
    ) Error!struct { response: transport_mod.Response, body: msg.FetchResponse } {
        try msg.encodeMessage(self.allocator, &self.send_buf, .{
            .type = .fetch_request,
            .connection_id = self.connection_id,
        }, msg.FetchRequest{ .uuid = uuid });

        var response = try self.roundTrip(cancel);
        errdefer response.deinit(self.allocator);

        var r = self.makeReader(response.body);
        const header = try msg.MessageHeader.decode(&r);

        switch (header.type) {
            .fetch_response => {},
            .error_response => {
                const e = try msg.ErrorResponse.decode(&r);
                try self.last_error.set(self.allocator, e.message);
                self.stats.server_errors += 1;
                return errors.ServerError.ServerError;
            },
            else => return errors.ProtocolError.UnexpectedMessageType,
        }

        const body = try msg.FetchResponse.decode(&r, self.allocator);
        self.stats.fetches += 1;
        return .{ .response = response, .body = body };
    }

    fn makeReader(self: *const Client, body: []const u8) Reader {
        return Reader.initWithLimits(body, .{
            .max_byte_length = self.options.max_response_bytes,
        });
    }

    fn roundTrip(self: *Client, cancel: ?*CancelToken) Error!transport_mod.Response {
        const req = transport_mod.Request{
            .url = self.url,
            .body = self.send_buf.items,
            .content_type = compat.content_type,
            .headers = self.options.headers,
            .timeout_ms = self.options.timeout_ms,
            .cancel = cancel,
        };

        if (self.options.observer) |obs| obs.onRequestStart(self.send_buf.items.len);

        const response = self.transport.send(self.allocator, req) catch |e| {
            self.stats.transport_errors += 1;
            if (self.options.observer) |obs| obs.onRequestEnd(0, true);
            return e;
        };

        self.stats.bytes_sent += self.send_buf.items.len;
        self.stats.bytes_received += response.body.len;
        self.stats.requests += 1;

        if (self.options.observer) |obs| obs.onRequestEnd(response.body.len, false);

        if (response.status < 200 or response.status >= 300) {
            var r = response;
            self.last_error.http_status = response.status;
            r.deinit(self.allocator);
            self.stats.transport_errors += 1;
            return errors.TransportError.HttpError;
        }
        if (response.body.len > self.options.max_response_bytes) {
            var r = response;
            r.deinit(self.allocator);
            return errors.TransportError.ResponseTooLarge;
        }
        return response;
    }
};

/// The server sends auth failures as ordinary error responses, so the only
/// signal available is the text. Matching is deliberately narrow: a false
/// negative just reports `ServerError`, which is still accurate.
fn isAuthMessage(m: []const u8) bool {
    return std.ascii.findIgnoreCase(m, "authenticat") != null or
        std.ascii.findIgnoreCase(m, "invalid token") != null or
        std.ascii.findIgnoreCase(m, "unauthorized") != null;
}

const testing = std.testing;

test "auth failure text is classified separately from other server errors" {
    try testing.expect(isAuthMessage("Authentication failed"));
    try testing.expect(isAuthMessage("invalid token supplied"));
    try testing.expect(!isAuthMessage("Catalog Error: Table with name foo does not exist"));
}
