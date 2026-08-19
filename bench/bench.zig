//! Decode/encode benchmarks.
//!
//! Measures the pure codec against fixtures captured from a real server, with
//! no network in the loop, so the numbers describe the library rather than the
//! link. Any optimisation should be justified by a before/after here
//! (todo.md §25).
//!
//!   zig build bench

const std = @import("std");
const quackling = @import("quackling");

const Reader = quackling.serialization.Reader;
const Writer = quackling.serialization.Writer;
const message = quackling.protocol.message;

const fixtures = @import("fixtures");
const select42 = fixtures.select42;
const largeresult = fixtures.largeresult;
const varchar = fixtures.varchar;
const nullmix = fixtures.nullmix;
const map_fx = fixtures.map;
const struct_fx = fixtures.@"struct";

/// Counts every allocation so we can report allocations-per-chunk, which is the
/// number that actually predicts behaviour under load.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    count: usize = 0,
    bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        self.bytes += len;
        return self.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(buf, a, new, ra);
    }
    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(buf, a, new, ra);
    }
    fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, a, ra);
    }
};

const Result = struct {
    name: []const u8,
    iters: u64,
    ns_total: u64,
    bytes_per_iter: usize,
    rows_per_iter: u64,
    allocs_per_iter: f64,

    fn nsPerIter(self: Result) f64 {
        return @as(f64, @floatFromInt(self.ns_total)) / @as(f64, @floatFromInt(self.iters));
    }
    fn mbPerSec(self: Result) f64 {
        const total_bytes = @as(f64, @floatFromInt(self.bytes_per_iter * self.iters));
        const secs = @as(f64, @floatFromInt(self.ns_total)) / 1e9;
        return total_bytes / secs / (1024 * 1024);
    }
    fn rowsPerSec(self: Result) f64 {
        const total = @as(f64, @floatFromInt(self.rows_per_iter * self.iters));
        const secs = @as(f64, @floatFromInt(self.ns_total)) / 1e9;
        return if (self.rows_per_iter == 0) 0 else total / secs;
    }
};

var results: std.ArrayList(Result) = .empty;

fn bench(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    payload: []const u8,
    iters: u64,
    comptime f: fn (std.mem.Allocator, []const u8) anyerror!u64,
) !void {
    // Warm up so the first-touch page faults do not land in the measurement.
    var w: u64 = 0;
    for (0..@min(iters / 10 + 1, 50)) |_| w +%= try f(allocator, payload);
    std.mem.doNotOptimizeAway(w);

    var counting = CountingAllocator{ .child = allocator };
    const ca = counting.allocator();
    var rows: u64 = 0;

    const start = std.Io.Clock.now(.awake, io);
    for (0..iters) |_| rows = try f(ca, payload);
    const end = std.Io.Clock.now(.awake, io);

    try results.append(allocator, .{
        .name = name,
        .iters = iters,
        .ns_total = @intCast(end.nanoseconds - start.nanoseconds),
        .bytes_per_iter = payload.len,
        .rows_per_iter = rows,
        .allocs_per_iter = @as(f64, @floatFromInt(counting.count)) / @as(f64, @floatFromInt(iters)),
    });
}

/// Full message decode: header + body + every chunk.
fn decodeFull(allocator: std.mem.Allocator, bytes: []const u8) !u64 {
    var r = Reader.init(bytes);
    _ = try message.MessageHeader.decode(&r);
    var body = try message.PrepareResponse.decode(&r, allocator);
    defer body.deinit();
    var rows: u64 = 0;
    for (body.chunks) |c| rows += c.row_count;
    return rows;
}

/// Decode plus touch every value through the `Value` path.
fn decodeAndReadValues(allocator: std.mem.Allocator, bytes: []const u8) !u64 {
    var r = Reader.init(bytes);
    _ = try message.MessageHeader.decode(&r);
    var body = try message.PrepareResponse.decode(&r, allocator);
    defer body.deinit();
    var acc: i64 = 0;
    var rows: u64 = 0;
    for (body.chunks) |c| {
        rows += c.row_count;
        for (0..c.columnCount()) |col| {
            for (0..c.row_count) |row| {
                const v = try c.getValue(col, row);
                acc +%= v.asI64() orelse 0;
            }
        }
    }
    std.mem.doNotOptimizeAway(acc);
    return rows;
}

/// Decode plus read every value through the typed fast path.
fn decodeAndReadFlat(allocator: std.mem.Allocator, bytes: []const u8) !u64 {
    var r = Reader.init(bytes);
    _ = try message.MessageHeader.decode(&r);
    var body = try message.PrepareResponse.decode(&r, allocator);
    defer body.deinit();
    var acc: i64 = 0;
    var rows: u64 = 0;
    for (body.chunks) |c| {
        rows += c.row_count;
        for (0..c.columnCount()) |col| {
            const v = c.column(col) orelse continue;
            if (v.isFlat(i64)) {
                for (0..c.row_count) |row| acc +%= v.at(i64, row) orelse 0;
            } else if (v.isFlat(i32)) {
                for (0..c.row_count) |row| acc +%= v.at(i32, row) orelse 0;
            }
        }
    }
    std.mem.doNotOptimizeAway(acc);
    return rows;
}

fn encodeQuery(allocator: std.mem.Allocator, _: []const u8) !u64 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try message.encodeMessage(allocator, &buf, .{
        .type = .prepare_request,
        .connection_id = "0123456789ABCDEF0123456789ABCDEF",
    }, message.PrepareRequest{ .sql = "SELECT * FROM lineitem WHERE l_orderkey < 1000" });
    std.mem.doNotOptimizeAway(buf.items.len);
    return 1;
}

/// Parameter substitution, including the SQL scan and literal escaping.
fn bindParams(allocator: std.mem.Allocator, _: []const u8) !u64 {
    const out = try quackling.params.bind(
        allocator,
        "SELECT * FROM t WHERE a = ? AND b = ? AND c = ? AND d = ?",
        &.{
            .{ .integer = 42 },
            .{ .text = "o'brien" },
            .{ .double = 1.5 },
            .null,
        },
    );
    defer allocator.free(out);
    std.mem.doNotOptimizeAway(out.len);
    return 1;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    defer results.deinit(allocator);

    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("Quackling codec benchmarks ({s}, {s})\n\n", .{
        @tagName(@import("builtin").mode),
        @tagName(@import("builtin").cpu.arch),
    });

    try bench(io, allocator, "decode SELECT 42", select42, 200_000, decodeFull);
    try bench(io, allocator, "decode 5k-row BIGINT", largeresult, 2_000, decodeFull);
    try bench(io, allocator, "decode+values 5k-row", largeresult, 1_000, decodeAndReadValues);
    try bench(io, allocator, "decode+flat 5k-row", largeresult, 1_000, decodeAndReadFlat);
    try bench(io, allocator, "decode VARCHAR", varchar, 100_000, decodeFull);
    try bench(io, allocator, "decode NULL-heavy", nullmix, 100_000, decodeFull);
    try bench(io, allocator, "decode STRUCT", struct_fx, 100_000, decodeFull);
    try bench(io, allocator, "decode MAP", map_fx, 100_000, decodeFull);
    try bench(io, allocator, "encode PREPARE req", select42, 200_000, encodeQuery);
    try bench(io, allocator, "bind 4 params", select42, 200_000, bindParams);

    try out.print("{s:<24} {s:>10} {s:>12} {s:>14} {s:>10}\n", .{
        "benchmark", "ns/op", "MB/s", "rows/s", "allocs/op",
    });
    try out.print("{s:-<24} {s:->10} {s:->12} {s:->14} {s:->10}\n", .{ "", "", "", "", "" });
    for (results.items) |r| {
        try out.print("{s:<24} {d:>10.0} {d:>12.1} {d:>14.0} {d:>10.2}\n", .{
            r.name, r.nsPerIter(), r.mbPerSec(), r.rowsPerSec(), r.allocs_per_iter,
        });
    }
    try out.writeAll(
        \\
        \\Notes:
        \\  * No network: these measure the codec alone, over fixtures captured
        \\    from a live DuckDB Quack server.
        \\  * "MB/s" is wire bytes decoded per second.
        \\  * allocs/op counts every allocator call during one iteration; the
        \\    decoder borrows bulk payloads from the input buffer rather than
        \\    copying them, so this scales with columns/chunks, not with rows.
        \\
    );
}
