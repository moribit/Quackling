//! Streaming a large result chunk by chunk.
//!
//! Memory stays proportional to one FETCH batch, not to the result: the client
//! releases each batch before requesting the next.

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

    var client = try quackling.Client.init(.{
        .allocator = allocator,
        .endpoint = "quack:localhost:9494",
        .token = "super_secret",
        .transport = http.transport(),
    });
    defer client.deinit();

    var result = try client.query("SELECT i, i * 2 AS doubled FROM range(1000000) t(i)");
    defer result.deinit();

    var chunks: u64 = 0;
    var rows: u64 = 0;
    var sum: i128 = 0;

    // The vectorized path: operate on whole columns, not row structs.
    while (try result.nextChunk()) |chunk| {
        chunks += 1;
        rows += chunk.row_count;

        const col = chunk.column(0) orelse continue;
        if (col.isFlat(i64)) {
            // Fast path: read the column with no per-value decoding.
            var i: usize = 0;
            while (i < chunk.row_count) : (i += 1) {
                sum += col.at(i64, i) orelse 0;
            }
        } else {
            var i: usize = 0;
            while (i < chunk.row_count) : (i += 1) {
                sum += (try chunk.getValue(0, i)).asI64() orelse 0;
            }
        }
    }

    try out.print("{d} rows in {d} chunks, sum = {d}\n", .{ rows, chunks, sum });
    try out.print("fetches: {d}, bytes received: {d}\n", .{
        client.stats.fetches,
        client.stats.bytes_received,
    });
}
