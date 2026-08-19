//! Transport abstraction.
//!
//! The protocol codec never touches a socket. It hands a request body to a
//! `Transport` and gets a response body back. That single indirection is what
//! lets the same codec run over native TCP, browser `fetch()`, or an in-memory
//! mock (todo.md §5).
//!
//! The interface is a vtable rather than a comptime interface so a client can
//! hold a transport chosen at runtime, and so `Client` is not generic over it
//! (which would leak into every downstream type signature).

const std = @import("std");

pub const Error = error{
    ConnectionFailed,
    Timeout,
    /// Server replied with a non-2xx status.
    HttpError,
    /// Response was larger than the configured limit.
    ResponseTooLarge,
    TlsError,
    InvalidUrl,
    /// The operation was cancelled through the request's cancel token.
    Cancelled,
    /// This transport cannot perform the operation (e.g. sync call on an
    /// inherently async transport).
    Unsupported,
    NetworkError,
} || std.mem.Allocator.Error;

/// An extra HTTP header, for proxies and gateways that need one.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// A cooperative cancellation flag.
///
/// Deliberately just an atomic bool: it works without a runtime, is safe to set
/// from another thread or from a signal handler, and imposes no async model on
/// the caller (todo.md §13, §19).
pub const CancelToken = struct {
    flag: std.atomic.Value(bool) = .init(false),

    pub fn cancel(self: *CancelToken) void {
        self.flag.store(true, .release);
    }

    pub fn isCancelled(self: *const CancelToken) bool {
        return self.flag.load(.acquire);
    }

    pub fn reset(self: *CancelToken) void {
        self.flag.store(false, .release);
    }
};

pub const Request = struct {
    /// Absolute URL, e.g. `http://localhost:9494/quack`.
    url: []const u8,
    body: []const u8,
    content_type: []const u8,
    headers: []const Header = &.{},
    timeout_ms: ?u32 = null,
    cancel: ?*CancelToken = null,
};

/// The response body, plus who owns it.
///
/// A transport that can hand back a borrowed view of its own buffer sets
/// `owned = false` and avoids a copy; one that allocates sets `owned = true`
/// and the caller frees. Making this explicit keeps the zero-copy path
/// available without ambiguity about lifetime (todo.md §11).
pub const Response = struct {
    status: u16,
    body: []const u8,
    owned: bool = false,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.body);
        self.body = &.{};
    }
};

/// Runtime-dispatched transport.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Perform one request/response round trip.
        send: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, req: Request) Error!Response,
        /// Release any transport-held resources. Optional.
        close: ?*const fn (ptr: *anyopaque) void = null,
    };

    pub fn send(self: Transport, allocator: std.mem.Allocator, req: Request) Error!Response {
        return self.vtable.send(self.ptr, allocator, req);
    }

    pub fn close(self: Transport) void {
        if (self.vtable.close) |f| f(self.ptr);
    }
};

// -- mock transport -----------------------------------------------------------

/// A transport that replays canned responses. Used by the golden tests and
/// available to library users for testing their own code without a server.
pub const MockTransport = struct {
    /// Responses handed out in order, one per `send` call.
    responses: []const []const u8,
    /// Status returned alongside each response; defaults to 200.
    status: u16 = 200,
    /// Bodies captured from the caller, if `record_allocator` is set.
    sent: std.ArrayList([]const u8) = .empty,
    record_allocator: ?std.mem.Allocator = null,
    index: usize = 0,
    /// When set, `send` returns this error instead of a response.
    fail_with: ?Error = null,

    pub fn deinit(self: *MockTransport) void {
        if (self.record_allocator) |a| {
            for (self.sent.items) |s| a.free(s);
            self.sent.deinit(a);
        }
    }

    pub fn transport(self: *MockTransport) Transport {
        return .{ .ptr = self, .vtable = &.{ .send = sendFn } };
    }

    fn sendFn(ptr: *anyopaque, allocator: std.mem.Allocator, req: Request) Error!Response {
        const self: *MockTransport = @ptrCast(@alignCast(ptr));
        if (self.fail_with) |e| return e;
        if (req.cancel) |c| if (c.isCancelled()) return Error.Cancelled;

        if (self.record_allocator) |a| {
            try self.sent.append(a, try a.dupe(u8, req.body));
        }
        _ = allocator;
        if (self.index >= self.responses.len) return Error.NetworkError;
        const body = self.responses[self.index];
        self.index += 1;
        // Borrowed: the fixture outlives the response.
        return .{ .status = self.status, .body = body, .owned = false };
    }
};

const testing = std.testing;

test "mock transport replays responses in order" {
    var mock = MockTransport{ .responses = &.{ "first", "second" } };
    defer mock.deinit();
    const t = mock.transport();

    var r1 = try t.send(testing.allocator, .{ .url = "u", .body = "", .content_type = "x" });
    defer r1.deinit(testing.allocator);
    try testing.expectEqualStrings("first", r1.body);

    var r2 = try t.send(testing.allocator, .{ .url = "u", .body = "", .content_type = "x" });
    defer r2.deinit(testing.allocator);
    try testing.expectEqualStrings("second", r2.body);

    try testing.expectError(Error.NetworkError, t.send(testing.allocator, .{ .url = "u", .body = "", .content_type = "x" }));
}

test "mock transport records what was sent" {
    var mock = MockTransport{ .responses = &.{"ok"}, .record_allocator = testing.allocator };
    defer mock.deinit();
    const t = mock.transport();
    var r = try t.send(testing.allocator, .{ .url = "u", .body = "hello", .content_type = "x" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), mock.sent.items.len);
    try testing.expectEqualStrings("hello", mock.sent.items[0]);
}

test "cancelled token short-circuits the request" {
    var mock = MockTransport{ .responses = &.{"ok"} };
    defer mock.deinit();
    var token = CancelToken{};
    token.cancel();
    try testing.expectError(Error.Cancelled, mock.transport().send(testing.allocator, .{
        .url = "u",
        .body = "",
        .content_type = "x",
        .cancel = &token,
    }));
}

test "cancel token round trips" {
    var token = CancelToken{};
    try testing.expect(!token.isCancelled());
    token.cancel();
    try testing.expect(token.isCancelled());
    token.reset();
    try testing.expect(!token.isCancelled());
}
