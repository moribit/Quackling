//! Quack endpoint parsing.
//!
//! Accepts `quack:host[:port]` (DuckDB's own form) as well as plain
//! `http://host[:port]` / `https://host[:port]`, and produces the POST URL.
//!
//! Validation is deliberately strict (todo.md §21): a host that contains
//! control characters, spaces, or embedded credentials is rejected rather than
//! being pasted into a URL.

const std = @import("std");
const compat = @import("protocol/compat.zig");

pub const Error = @import("error.zig").UriError || std.mem.Allocator.Error;

pub const Scheme = enum { http, https };

pub const Endpoint = struct {
    scheme: Scheme,
    /// Borrowed from the input string.
    host: []const u8,
    port: u16,

    /// Build the full `.../quack` URL. Caller owns the returned memory.
    pub fn toHttpUrl(self: Endpoint, allocator: std.mem.Allocator) Error![]u8 {
        const scheme_str = switch (self.scheme) {
            .http => "http",
            .https => "https",
        };
        // IPv6 literals must stay bracketed in a URL.
        const needs_brackets = std.mem.indexOfScalar(u8, self.host, ':') != null and
            self.host[0] != '[';
        return if (needs_brackets)
            std.fmt.allocPrint(allocator, "{s}://[{s}]:{d}{s}", .{
                scheme_str, self.host, self.port, compat.http_path,
            })
        else
            std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{
                scheme_str, self.host, self.port, compat.http_path,
            });
    }
};

pub fn parse(input: []const u8) Error!Endpoint {
    if (input.len == 0) return Error.EmptyHost;

    var rest = input;
    var scheme: Scheme = .http;

    if (std.mem.startsWith(u8, rest, "quack://")) {
        rest = rest["quack://".len..];
    } else if (std.mem.startsWith(u8, rest, "quack:")) {
        rest = rest["quack:".len..];
    } else if (std.mem.startsWith(u8, rest, "https://")) {
        scheme = .https;
        rest = rest["https://".len..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest["http://".len..];
    }

    // Drop any path/query - the endpoint path is fixed by the protocol.
    if (std.mem.indexOfAny(u8, rest, "/?#")) |i| rest = rest[0..i];

    // Reject embedded credentials: they would be silently dropped, and a URL
    // that looks authenticated but is not is worse than an error.
    if (std.mem.indexOfScalar(u8, rest, '@') != null) return Error.InvalidUrl;

    var host = rest;
    var port: u16 = compat.default_port;

    if (rest.len > 0 and rest[0] == '[') {
        // Bracketed IPv6, optionally followed by :port.
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return Error.InvalidUrl;
        host = rest[1..close];
        const after = rest[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return Error.InvalidUrl;
            port = try parsePort(after[1..]);
        }
    } else if (std.mem.lastIndexOfScalar(u8, rest, ':')) |i| {
        // A bare IPv6 address has several colons and no port.
        if (std.mem.count(u8, rest, ":") == 1) {
            host = rest[0..i];
            port = try parsePort(rest[i + 1 ..]);
        }
    }

    if (host.len == 0) return Error.EmptyHost;
    for (host) |c| {
        if (c <= 0x20 or c == 0x7F) return Error.InvalidUrl;
    }

    return .{ .scheme = scheme, .host = host, .port = port };
}

fn parsePort(s: []const u8) Error!u16 {
    if (s.len == 0) return Error.InvalidPort;
    const p = std.fmt.parseInt(u16, s, 10) catch return Error.InvalidPort;
    if (p == 0) return Error.InvalidPort;
    return p;
}

const testing = std.testing;

test "quack scheme defaults to the standard port" {
    const e = try parse("quack:localhost");
    try testing.expectEqualStrings("localhost", e.host);
    try testing.expectEqual(@as(u16, 9494), e.port);
    try testing.expectEqual(Scheme.http, e.scheme);
}

test "explicit port overrides the default" {
    const e = try parse("quack:example.com:1234");
    try testing.expectEqualStrings("example.com", e.host);
    try testing.expectEqual(@as(u16, 1234), e.port);
}

test "http and https urls are accepted" {
    const h = try parse("http://localhost:9494");
    try testing.expectEqual(Scheme.http, h.scheme);
    const s = try parse("https://db.example.com");
    try testing.expectEqual(Scheme.https, s.scheme);
    try testing.expectEqualStrings("db.example.com", s.host);
}

test "url building appends the protocol path" {
    const e = try parse("quack:localhost:9494");
    const url = try e.toHttpUrl(testing.allocator);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("http://localhost:9494/quack", url);
}

test "ipv6 literals stay bracketed" {
    const e = try parse("quack:[::1]:9494");
    try testing.expectEqualStrings("::1", e.host);
    try testing.expectEqual(@as(u16, 9494), e.port);
    const url = try e.toHttpUrl(testing.allocator);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("http://[::1]:9494/quack", url);
}

test "paths and queries are discarded" {
    const e = try parse("http://localhost:9494/some/path?x=1");
    try testing.expectEqualStrings("localhost", e.host);
    try testing.expectEqual(@as(u16, 9494), e.port);
}

test "hostile inputs are rejected" {
    try testing.expectError(Error.EmptyHost, parse(""));
    try testing.expectError(Error.InvalidUrl, parse("quack:user:pass@host"));
    try testing.expectError(Error.InvalidPort, parse("quack:host:0"));
    try testing.expectError(Error.InvalidPort, parse("quack:host:99999"));
    try testing.expectError(Error.InvalidPort, parse("quack:host:abc"));
    try testing.expectError(Error.InvalidUrl, parse("quack:ho st"));
    try testing.expectError(Error.InvalidUrl, parse("quack:host\nX"));
}
