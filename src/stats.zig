//! Observability.
//!
//! Two mechanisms, both dependency-free (todo.md §18):
//!
//!   * `Stats` - counters the client updates as it works. Read them whenever.
//!   * `Observer` - an optional callback struct for per-request events.
//!
//! No logging framework is imported, and nothing is written anywhere by
//! default. In particular the client never logs the auth token (todo.md §21).

const std = @import("std");

pub const Stats = struct {
    connects: u64 = 0,
    requests: u64 = 0,
    queries: u64 = 0,
    fetches: u64 = 0,
    appends: u64 = 0,
    chunks_received: u64 = 0,
    rows_received: u64 = 0,
    bytes_sent: u64 = 0,
    bytes_received: u64 = 0,
    server_errors: u64 = 0,
    transport_errors: u64 = 0,
    protocol_errors: u64 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }

    pub fn format(self: Stats, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print(
            "requests={d} queries={d} fetches={d} chunks={d} rows={d} sent={d}B recv={d}B errors={d}/{d}/{d}",
            .{
                self.requests,        self.queries,       self.fetches,
                self.chunks_received, self.rows_received, self.bytes_sent,
                self.bytes_received,  self.server_errors, self.transport_errors,
                self.protocol_errors,
            },
        );
    }
};

/// Per-request hooks. Every field is optional; the client checks before calling.
///
/// Kept as a struct of function pointers rather than an interface so that a
/// caller can supply just the one hook they care about.
pub const Observer = struct {
    ctx: ?*anyopaque = null,
    on_request_start: ?*const fn (ctx: ?*anyopaque, bytes: usize) void = null,
    on_request_end: ?*const fn (ctx: ?*anyopaque, bytes: usize, failed: bool) void = null,
    on_chunk: ?*const fn (ctx: ?*anyopaque, rows: usize) void = null,

    pub fn onRequestStart(self: Observer, bytes: usize) void {
        if (self.on_request_start) |f| f(self.ctx, bytes);
    }

    pub fn onRequestEnd(self: Observer, bytes: usize, failed: bool) void {
        if (self.on_request_end) |f| f(self.ctx, bytes, failed);
    }

    pub fn onChunk(self: Observer, rows: usize) void {
        if (self.on_chunk) |f| f(self.ctx, rows);
    }
};

const testing = std.testing;

test "stats accumulate and reset" {
    var s = Stats{};
    s.requests += 1;
    s.rows_received += 42;
    try testing.expectEqual(@as(u64, 42), s.rows_received);
    s.reset();
    try testing.expectEqual(@as(u64, 0), s.rows_received);
    try testing.expectEqual(@as(u64, 0), s.requests);
}

test "observer with no hooks set is safe to call" {
    const o = Observer{};
    o.onRequestStart(10);
    o.onRequestEnd(20, false);
    o.onChunk(5);
}

test "observer invokes the hooks that are set" {
    const Counter = struct {
        var starts: usize = 0;
        var ends: usize = 0;
        fn start(_: ?*anyopaque, _: usize) void {
            starts += 1;
        }
        fn end(_: ?*anyopaque, _: usize, _: bool) void {
            ends += 1;
        }
    };
    Counter.starts = 0;
    Counter.ends = 0;
    const o = Observer{ .on_request_start = Counter.start, .on_request_end = Counter.end };
    o.onRequestStart(1);
    o.onRequestEnd(2, false);
    try testing.expectEqual(@as(usize, 1), Counter.starts);
    try testing.expectEqual(@as(usize, 1), Counter.ends);
}
