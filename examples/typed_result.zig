//! Mapping rows onto a Zig struct with comptime reflection.
//!
//! `typed` is built on the DataChunk API; the protocol core knows nothing
//! about it.

const std = @import("std");
const quackling = @import("quackling");

/// Field names are matched to column names; `?T` accepts NULL.
const User = struct {
    id: i64,
    name: []const u8,
    score: f64,
    nickname: ?[]const u8,
};

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

    var result = try client.query(
        \\SELECT * FROM (VALUES
        \\  (1, 'alice', 9.5, 'al'),
        \\  (2, 'bob',   7.25, NULL)
        \\) AS t(id, name, score, nickname) ORDER BY id
    );
    defer result.deinit();

    var it = try quackling.typed.iterator(User, &result);
    while (try it.next()) |user| {
        // `name` borrows the chunk buffer - valid until the next chunk.
        try out.print("{d}: {s} ({d}) nickname={s}\n", .{
            user.id,
            user.name,
            user.score,
            user.nickname orelse "<none>",
        });
    }
}
