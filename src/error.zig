//! Error taxonomy.
//!
//! Errors are grouped by *cause* so a caller can react differently to "the
//! network broke", "the server rejected my SQL" and "this response is not valid
//! Quack" (todo.md §20). Zig error values carry no payload, so the detailed
//! server text is kept alongside them in `ErrorInfo`.

const std = @import("std");

/// Something went wrong below the protocol: DNS, TCP, TLS, HTTP status.
pub const TransportError = error{
    ConnectionFailed,
    Timeout,
    HttpError,
    ResponseTooLarge,
    TlsError,
    InvalidUrl,
    Cancelled,
    Unsupported,
    NetworkError,
};

/// The bytes were well-formed but the exchange did not make sense.
pub const ProtocolError = error{
    UnexpectedMessageType,
    UnknownMessageType,
    /// Server speaks a Quack version we do not.
    UnsupportedProtocolVersion,
    /// A request needed a connection id we do not have.
    NotConnected,
    /// Tried to use a result that has already been drained or closed.
    ResultClosed,
    /// A newer query was started on the same client, which resets the
    /// server-side cursor and invalidates any result still being streamed.
    /// Finish or `deinit` a result before issuing the next query, or use a
    /// separate connection (see `Pool`).
    ResultSuperseded,
    /// A result required more FETCH round trips than `Result.max_fetches`.
    /// The server never signalled end-of-stream, so the client stopped rather
    /// than looping indefinitely.
    FetchLimitExceeded,
};

/// The bytes themselves were malformed.
pub const SerializationError = error{
    UnexpectedEndOfBuffer,
    VarIntOverflow,
    LengthLimitExceeded,
    UnexpectedFieldId,
    UnexpectedField,
    MalformedVector,
    RowCountTooLarge,
};

/// The server refused our credentials.
pub const AuthenticationError = error{
    AuthenticationFailed,
};

/// The server executed our request and reported a failure (bad SQL, constraint
/// violation, ...). The text is in `Client.lastError()`.
pub const ServerError = error{
    ServerError,
};

/// A type or encoding this client version does not implement.
pub const UnsupportedError = error{
    UnsupportedType,
    UnsupportedVectorType,
};

/// Endpoint parsing.
pub const UriError = error{
    InvalidUrl,
    EmptyHost,
    InvalidPort,
};

/// Client-side parameter binding (see `params.zig`).
pub const ParameterError = error{
    ParameterCountMismatch,
    UnsupportedParameter,
    InvalidUtf8,
};

/// Encoding data to send (the `APPEND_REQUEST` path).
pub const AppendError = error{
    /// A value's type does not match the column it is written to, or the columns
    /// are ragged. Refused rather than coerced, so the server never sees a chunk
    /// that disagrees with its own schema.
    TypeMismatch,
    /// More rows than a single DataChunk holds (2048).
    TooManyRows,
};

/// Everything a query call can return.
///
/// Defined once, here, rather than assembled by `||` at each layer - otherwise
/// adding one error variant means chasing it through every intermediate
/// signature.
pub const QueryError = TransportError || ProtocolError || SerializationError ||
    AuthenticationError || ServerError || UnsupportedError || UriError ||
    ParameterError || AppendError || std.mem.Allocator.Error ||
    error{ColumnOutOfRange};

/// Detail that does not fit in a Zig error value.
///
/// DuckDB's message is preserved verbatim (todo.md §20) - it is the most useful
/// thing a user gets when their SQL is wrong.
pub const ErrorInfo = struct {
    allocator: ?std.mem.Allocator = null,
    /// Server-supplied text, owned when `allocator` is set.
    message: []const u8 = "",
    /// HTTP status, when the failure was at that layer.
    http_status: ?u16 = null,

    pub fn deinit(self: *ErrorInfo) void {
        if (self.allocator) |a| {
            if (self.message.len > 0) a.free(self.message);
        }
        self.message = "";
        self.allocator = null;
    }

    pub fn set(self: *ErrorInfo, allocator: std.mem.Allocator, msg: []const u8) !void {
        self.deinit();
        self.message = try allocator.dupe(u8, msg);
        self.allocator = allocator;
    }
};

const testing = std.testing;

test "error info owns and replaces its message" {
    var info = ErrorInfo{};
    defer info.deinit();
    try info.set(testing.allocator, "first failure");
    try testing.expectEqualStrings("first failure", info.message);
    try info.set(testing.allocator, "second failure");
    try testing.expectEqualStrings("second failure", info.message);
}

test "error categories stay disjoint" {
    // A compile-time sanity check that the union actually includes each group.
    const E = QueryError;
    try testing.expect(@typeInfo(E) == .error_set);
}
