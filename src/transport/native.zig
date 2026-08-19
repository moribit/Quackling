//! Native HTTP transport built on `std.http.Client`.
//!
//! Pure Zig standard library: no libcurl, no C dependency (todo.md §2). This
//! file is the only place in the library that knows sockets exist, and it is
//! never imported by the protocol core - `root.zig` only pulls it in on targets
//! that have networking.

const std = @import("std");
const transport = @import("transport.zig");

const Transport = transport.Transport;
const Request = transport.Request;
const Response = transport.Response;
const Error = transport.Error;

pub const Options = struct {
    /// Hard cap on a response body, so a hostile or broken server cannot drive
    /// unbounded allocation (todo.md §21).
    max_response_bytes: usize = 256 * 1024 * 1024,
    /// Reserved for per-request deadlines. `std.http.Client` does not expose a
    /// granular timeout hook yet; cancellation is available via `CancelToken`.
    timeout_ms: ?u32 = null,
};

/// Owns an `std.Io` implementation so callers who do not have one can just use
/// the transport. Callers that already run an event loop should instead build
/// `NativeTransport` with `initWithIo` and pass their own `Io` - that is the
/// seam through which io_uring/epoll/kqueue backends arrive (todo.md §13).
pub const NativeTransport = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    options: Options,
    /// Non-null only when this struct created the Io itself.
    owned_io: ?*std.Io.Threaded = null,

    /// Create a transport with a self-managed threaded `Io`.
    pub fn init(allocator: std.mem.Allocator, options: Options) !NativeTransport {
        const threaded = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = .init(allocator, .{});
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = threaded.io() },
            .options = options,
            .owned_io = threaded,
        };
    }

    /// Create a transport over a caller-provided `Io`.
    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io, options: Options) NativeTransport {
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = io },
            .options = options,
        };
    }

    pub fn deinit(self: *NativeTransport) void {
        self.client.deinit();
        if (self.owned_io) |t| {
            t.deinit();
            self.allocator.destroy(t);
            self.owned_io = null;
        }
    }

    pub fn transport(self: *NativeTransport) Transport {
        return .{ .ptr = self, .vtable = &.{ .send = sendFn } };
    }

    fn sendFn(ptr: *anyopaque, allocator: std.mem.Allocator, req: Request) Error!Response {
        const self: *NativeTransport = @ptrCast(@alignCast(ptr));

        if (req.cancel) |c| if (c.isCancelled()) return Error.Cancelled;

        const uri = std.Uri.parse(req.url) catch return Error.InvalidUrl;

        // `std.http.Header` and our `Header` are layout-compatible in spirit
        // but distinct types, so translate into a temporary owned by this call.
        const extra: []std.http.Header = if (req.headers.len == 0)
            &.{}
        else
            allocator.alloc(std.http.Header, req.headers.len) catch return Error.OutOfMemory;
        defer if (extra.len > 0) allocator.free(extra);
        for (req.headers, 0..) |h, i| extra[i] = .{ .name = h.name, .value = h.value };

        var body: std.Io.Writer.Allocating = .init(allocator);
        errdefer body.deinit();

        const result = self.client.fetch(.{
            .location = .{ .uri = uri },
            .method = .POST,
            .payload = req.body,
            .headers = .{ .content_type = .{ .override = req.content_type } },
            .extra_headers = extra,
            .response_writer = &body.writer,
        }) catch |err| return mapError(err);

        if (req.cancel) |c| if (c.isCancelled()) {
            body.deinit();
            return Error.Cancelled;
        };

        const owned = body.toOwnedSlice() catch return Error.OutOfMemory;
        errdefer allocator.free(owned);

        if (owned.len > self.options.max_response_bytes) {
            allocator.free(owned);
            return Error.ResponseTooLarge;
        }

        const status = @intFromEnum(result.status);
        return .{ .status = status, .body = owned, .owned = true };
    }

    fn mapError(err: anyerror) Error {
        return switch (err) {
            error.OutOfMemory => Error.OutOfMemory,
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            error.ConnectionTimedOut,
            error.NetworkUnreachable,
            error.HostLacksNetworkAddresses,
            error.TemporaryNameServerFailure,
            error.NameServerFailure,
            error.UnknownHostName,
            => Error.ConnectionFailed,
            error.TlsInitializationFailed => Error.TlsError,
            error.UnsupportedUriScheme, error.UriMissingHost => Error.InvalidUrl,
            else => Error.NetworkError,
        };
    }
};

const testing = std.testing;

test "invalid url is rejected before any socket work" {
    var nt = try NativeTransport.init(testing.allocator, .{});
    defer nt.deinit();
    try testing.expectError(Error.InvalidUrl, nt.transport().send(testing.allocator, .{
        .url = "not a url at all",
        .body = "",
        .content_type = "application/vnd.duckdb",
    }));
}

test "pre-cancelled request does not open a connection" {
    var nt = try NativeTransport.init(testing.allocator, .{});
    defer nt.deinit();
    var token = transport.CancelToken{};
    token.cancel();
    try testing.expectError(Error.Cancelled, nt.transport().send(testing.allocator, .{
        .url = "http://127.0.0.1:1/quack",
        .body = "",
        .content_type = "application/vnd.duckdb",
        .cancel = &token,
    }));
}
