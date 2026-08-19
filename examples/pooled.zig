//! Connection pooling and bound parameters.
//!
//! A Quack connection is one server-side session with one result cursor, so
//! concurrent work needs concurrent connections. This is the shape a web
//! server would use: lease a connection per request, release it afterwards.

const std = @import("std");
const quackling = @import("quackling");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var http = quackling.NativeTransport.initWithIo(allocator, init.io, .{});
    defer http.deinit();

    var pool = try quackling.Pool.init(.{
        .allocator = allocator,
        .endpoint = "quack:localhost:9494",
        .token = "super_secret",
        .transport = http.transport(),
        .io = init.io,
        .max_connections = 4,
        .min_connections = 2,
    });
    defer pool.deinit();

    // Each iteration models one request: acquire, query, release.
    for (0..6) |i| {
        var lease = try pool.acquire(null);
        defer lease.release();

        // Parameters are escaped by the client; see src/params.zig for why
        // this cannot be done at the protocol level in Quack v1.
        var result = try lease.client.queryParams(
            "SELECT ?::BIGINT AS n, ?::VARCHAR AS label",
            &.{ .{ .integer = @intCast(i * i) }, .{ .text = "it's fine" } },
        );
        defer result.deinit();

        const chunk = (try result.nextChunk()) orelse continue;
        try out.print("request {d}: n={f} label={f}\n", .{
            i,
            try chunk.getValue(0, 0),
            try chunk.getValue(1, 0),
        });
    }

    const s = pool.snapshot();
    try out.print(
        "\npool: {d} connections, {d} idle, {d} acquires, {d} created\n",
        .{ s.total, s.idle, s.acquires, s.creates },
    );
}
