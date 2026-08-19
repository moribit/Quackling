//! The smallest useful Quackling program: connect, query, print.
//!
//!   zig build examples
//!   ./zig-out/bin/example-query

const std = @import("std");
const quackling = @import("quackling");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // The transport is chosen by the caller, never by the library.
    var http = quackling.NativeTransport.initWithIo(allocator, init.io, .{});
    defer http.deinit();

    var client = try quackling.Client.init(.{
        .allocator = allocator,
        .endpoint = "quack:localhost:9494",
        .token = "super_secret",
        .transport = http.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT 42 AS answer");
    defer result.deinit();

    const answer = (try result.scalar()) orelse {
        try out.writeAll("no rows\n");
        return;
    };
    try out.print("answer = {f}\n", .{answer});
}
