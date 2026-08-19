//! Integration tests against a live DuckDB Quack server.
//!
//! Not part of `zig build test` - run with `zig build test-integration`.
//! Start a server first:
//!
//! ```
//! duckdb -c "LOAD quack; CALL quack_serve('quack:localhost:9494', token => 'super_secret');"
//! ```
//!
//! Override via `QUACK_TEST_ENDPOINT` / `QUACK_TEST_TOKEN`. When no server is
//! reachable the tests skip rather than fail, so this file is safe to run in a
//! CI job that may or may not have a server (todo.md §26).

const std = @import("std");
const quackling = @import("quackling");

const testing = std.testing;

const default_endpoint = "quack:localhost:9494";
const default_token = "super_secret";

/// Endpoint / token, overridable at build time:
///
///   zig build test-integration -Dquack-endpoint=quack:host:9494 -Dquack-token=...
///
/// A build option rather than an environment variable so the same code works
/// identically on every target, including Windows and WASI.
const build_options = @import("build_options");

fn endpoint() []const u8 {
    return if (build_options.quack_endpoint.len > 0)
        build_options.quack_endpoint
    else
        default_endpoint;
}

fn token() []const u8 {
    return if (build_options.quack_token.len > 0)
        build_options.quack_token
    else
        default_token;
}

const Harness = struct {
    transport: *quackling.NativeTransport,
    client: quackling.Client,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Harness {
        const t = try allocator.create(quackling.NativeTransport);
        errdefer allocator.destroy(t);
        t.* = try quackling.NativeTransport.init(allocator, .{});
        errdefer t.deinit();

        var client = try quackling.Client.init(.{
            .allocator = allocator,
            .endpoint = endpoint(),
            .token = token(),
            .transport = t.transport(),
        });
        errdefer client.deinit();

        client.connect(null) catch |e| switch (e) {
            error.ConnectionFailed, error.NetworkError, error.Timeout => {
                client.deinit();
                t.deinit();
                allocator.destroy(t);
                return error.SkipZigTest;
            },
            else => return e,
        };

        return .{ .transport = t, .client = client, .allocator = allocator };
    }

    fn deinit(self: *Harness) void {
        self.client.deinit();
        self.transport.deinit();
        self.allocator.destroy(self.transport);
    }
};

test "integration: connect performs the handshake" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try testing.expect(h.client.isConnected());
    try testing.expectEqual(@as(usize, 32), h.client.connection_id.len);
    try testing.expectEqual(@as(u64, 1), h.client.quack_version);
    try testing.expect(h.client.server_version.len > 0);
}

test "integration: SELECT 42 returns 42" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var result = try h.client.query("SELECT 42 AS answer");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.columnCount());
    try testing.expectEqualStrings("answer", result.columnName(0).?);

    const v = (try result.scalar()).?;
    try testing.expectEqual(@as(i64, 42), v.asI64().?);
}

test "integration: primitives, NULLs and VARCHAR round trip" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var result = try h.client.query(
        \\SELECT 1::TINYINT a, 2::SMALLINT b, 3::INTEGER c, 4::BIGINT d,
        \\       5.5::FLOAT e, 6.25::DOUBLE f, 'hello' g, NULL::INTEGER h,
        \\       true i, 'wörld🦆' j
    );
    defer result.deinit();

    const chunk = (try result.nextChunk()).?;
    try testing.expectEqual(@as(usize, 1), chunk.row_count);
    try testing.expectEqual(@as(i8, 1), (try chunk.getValue(0, 0)).tinyint);
    try testing.expectEqual(@as(i16, 2), (try chunk.getValue(1, 0)).smallint);
    try testing.expectEqual(@as(i32, 3), (try chunk.getValue(2, 0)).integer);
    try testing.expectEqual(@as(i64, 4), (try chunk.getValue(3, 0)).bigint);
    try testing.expectEqual(@as(f32, 5.5), (try chunk.getValue(4, 0)).float);
    try testing.expectEqual(@as(f64, 6.25), (try chunk.getValue(5, 0)).double);
    try testing.expectEqualStrings("hello", (try chunk.getValue(6, 0)).varchar);
    try testing.expect((try chunk.getValue(7, 0)).isNull());
    try testing.expectEqual(true, (try chunk.getValue(8, 0)).boolean);
    try testing.expectEqualStrings("wörld🦆", (try chunk.getValue(9, 0)).varchar);
}

test "integration: multiple rows stream in order" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var result = try h.client.query("SELECT i FROM range(100) t(i) ORDER BY i");
    defer result.deinit();

    var stream = result.rows();
    var expect: i64 = 0;
    while (try stream.next()) |row| : (expect += 1) {
        try testing.expectEqual(expect, (try row.get(0)).asI64().?);
    }
    try testing.expectEqual(@as(i64, 100), expect);
}

test "integration: a large result streams across FETCH round trips" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const n = 100_000;
    var result = try h.client.query("SELECT i FROM range(100000) t(i) ORDER BY i");
    defer result.deinit();

    var count: u64 = 0;
    var expect: i64 = 0;
    var chunks: u64 = 0;
    while (try result.nextChunk()) |chunk| {
        chunks += 1;
        var i: usize = 0;
        while (i < chunk.row_count) : (i += 1) {
            try testing.expectEqual(expect, (try chunk.getValue(0, i)).asI64().?);
            expect += 1;
        }
        count += chunk.row_count;
    }
    try testing.expectEqual(@as(u64, n), count);
    // 100k rows cannot fit in one 2048-row chunk, nor one 12-chunk batch.
    try testing.expect(chunks > 12);
    try testing.expect(h.client.stats.fetches > 0);
}

test "integration: server errors surface with DuckDB's message" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = h.client.query("SELECT * FROM definitely_not_a_table");
    try testing.expectError(error.ServerError, res);
    // DuckDB's own text must survive to the caller (todo.md §20).
    try testing.expect(h.client.lastError().len > 0);
    try testing.expect(std.mem.indexOf(u8, h.client.lastError(), "definitely_not_a_table") != null);

    // The connection stays usable after a query error.
    var ok = try h.client.query("SELECT 1");
    defer ok.deinit();
    try testing.expectEqual(@as(i64, 1), (try ok.scalar()).?.asI64().?);
}

test "integration: syntax errors are reported, not swallowed" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try testing.expectError(error.ServerError, h.client.query("SELECT FROM WHERE"));
    try testing.expect(h.client.lastError().len > 0);
}

test "integration: empty result reports schema with no rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var result = try h.client.query("SELECT 1 AS a WHERE false");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.columnCount());
    try testing.expectEqualStrings("a", result.columnName(0).?);
    try testing.expectEqual(@as(u64, 0), try result.drain());
}

test "integration: typed struct mapping" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const Row = struct {
        id: i64,
        name: []const u8,
        score: f64,
    };

    var result = try h.client.query(
        \\SELECT * FROM (VALUES (1, 'alice', 9.5), (2, 'bob', 7.25))
        \\  AS t(id, name, score) ORDER BY id
    );
    defer result.deinit();

    var it = try quackling.typed.iterator(Row, &result);
    const first = (try it.next()).?;
    try testing.expectEqual(@as(i64, 1), first.id);
    try testing.expectEqualStrings("alice", first.name);
    try testing.expectEqual(@as(f64, 9.5), first.score);

    const second = (try it.next()).?;
    try testing.expectEqualStrings("bob", second.name);
    try testing.expectEqual(@as(?Row, null), try it.next());
}

test "integration: optional fields accept NULL" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const R = struct { v: ?i64 };
    var result = try h.client.query(
        "SELECT CASE WHEN i % 2 = 0 THEN NULL ELSE i END::BIGINT AS v FROM range(4) t(i)",
    );
    defer result.deinit();

    var it = try quackling.typed.iterator(R, &result);
    var i: usize = 0;
    while (try it.next()) |row| : (i += 1) {
        if (i % 2 == 0) {
            try testing.expectEqual(@as(?i64, null), row.v);
        } else {
            try testing.expectEqual(@as(?i64, @intCast(i)), row.v);
        }
    }
    try testing.expectEqual(@as(usize, 4), i);
}

test "integration: DDL and DML execute" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.client.exec("CREATE OR REPLACE TABLE quackling_it (id INTEGER, label VARCHAR)");
    try h.client.exec("INSERT INTO quackling_it VALUES (1, 'one'), (2, 'two')");

    var result = try h.client.query("SELECT label FROM quackling_it ORDER BY id");
    defer result.deinit();
    var stream = result.rows();
    const a = (try stream.next()).?;
    try testing.expectEqualStrings("one", (try a.get(0)).varchar);
    const b = (try stream.next()).?;
    try testing.expectEqualStrings("two", (try b.get(0)).varchar);

    try h.client.exec("DROP TABLE quackling_it");
}

test "integration: wide types decode correctly" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var result = try h.client.query(
        \\SELECT 170141183460469231731687303715884105727::HUGEINT h,
        \\       DATE '2024-03-15' d,
        \\       TIMESTAMP '2024-03-15 12:34:56' ts,
        \\       12.34::DECIMAL(10,2) dec_val,
        \\       'abc'::BLOB b
    );
    defer result.deinit();

    const chunk = (try result.nextChunk()).?;
    try testing.expectEqual(@as(i128, std.math.maxInt(i128)), (try chunk.getValue(0, 0)).hugeint);

    // Rendered forms are the readable check for date/time/decimal.
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try (try chunk.getValue(1, 0)).format(&w);
    try testing.expectEqualStrings("2024-03-15", w.buffered());

    var w2 = std.Io.Writer.fixed(&buf);
    try (try chunk.getValue(2, 0)).format(&w2);
    try testing.expectEqualStrings("2024-03-15 12:34:56", w2.buffered());

    var w3 = std.Io.Writer.fixed(&buf);
    try (try chunk.getValue(3, 0)).format(&w3);
    try testing.expectEqualStrings("12.34", w3.buffered());

    try testing.expectEqualStrings("abc", (try chunk.getValue(4, 0)).blob);
}

test "integration: stats track the work performed" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const before = h.client.stats;
    var result = try h.client.query("SELECT i FROM range(10) t(i)");
    defer result.deinit();
    _ = try result.drain();

    try testing.expect(h.client.stats.queries > before.queries);
    try testing.expect(h.client.stats.bytes_sent > before.bytes_sent);
    try testing.expect(h.client.stats.bytes_received > before.bytes_received);
    try testing.expectEqual(@as(u64, 10), h.client.stats.rows_received - before.rows_received);
}

test "integration: bad token is rejected" {
    var t = try quackling.NativeTransport.init(testing.allocator, .{});
    defer t.deinit();

    var client = quackling.Client.init(.{
        .allocator = testing.allocator,
        .endpoint = endpoint(),
        .token = "definitely-the-wrong-token",
        .transport = t.transport(),
    }) catch return error.SkipZigTest;
    defer client.deinit();

    client.connect(null) catch |e| switch (e) {
        error.ConnectionFailed, error.NetworkError => return error.SkipZigTest,
        // Either classification is acceptable; both mean "refused".
        error.AuthenticationFailed, error.ServerError => {
            try testing.expect(!client.isConnected());
            return;
        },
        else => return e,
    };
    return error.TestExpectedAuthFailure;
}

// -- nested and extended types ------------------------------------------------

test "integration: STRUCT, LIST, ARRAY round trip" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var result = try h.client.query(
        "SELECT {'a': 1, 'b': 'x'} AS s, [10,20,30] AS l, [1,2]::INTEGER[2] AS arr",
    );
    defer result.deinit();
    const chunk = (try result.nextChunk()).?;

    const kids = chunk.column(0).?.children().?;
    try testing.expectEqual(@as(i32, 1), (try kids[0].getValue(0)).integer);
    try testing.expectEqualStrings("x", (try kids[1].getValue(0)).varchar);

    const lv = chunk.column(1).?;
    const e = lv.listEntry(0).?;
    try testing.expectEqual(@as(u64, 3), e.length);
    try testing.expectEqual(
        @as(i64, 20),
        (try lv.listChild().?.getValue(@intCast(e.offset + 1))).asI64().?,
    );

    try testing.expectEqual(@as(u64, 2), chunk.column(2).?.arraySize().?);
}

test "integration: MAP round trips keys and values" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var result = try h.client.query("SELECT MAP{'x': 10, 'y': 20} AS m");
    defer result.deinit();
    const chunk = (try result.nextChunk()).?;
    const m = chunk.column(0).?.mapEntry(0).?;
    try testing.expectEqual(@as(u64, 2), m.length);
    try testing.expectEqualStrings("x", (try m.keys.getValue(@intCast(m.offset))).varchar);
    try testing.expectEqual(@as(i32, 20), (try m.values.getValue(@intCast(m.offset + 1))).integer);
}

test "integration: ENUM resolves to labels across rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var result = try h.client.query(
        "SELECT unnest(['sad','happy','ok'])::ENUM('sad','ok','happy') AS mood",
    );
    defer result.deinit();

    const expect = [_][]const u8{ "sad", "happy", "ok" };
    var stream = result.rows();
    var i: usize = 0;
    while (try stream.next()) |row| : (i += 1) {
        try testing.expectEqualStrings(expect[i], (try row.get(0)).@"enum".label);
    }
    try testing.expectEqual(@as(usize, 3), i);
}

test "integration: UNION reports the active member" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var result = try h.client.query("SELECT union_value(num := 7) AS u");
    defer result.deinit();
    const chunk = (try result.nextChunk()).?;
    const u = chunk.column(0).?.unionValue(0).?;
    try testing.expectEqualStrings("num", u.name);
    try testing.expectEqual(@as(i32, 7), (try u.vector.getValue(0)).integer);
}

test "integration: nested NULLs are preserved" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var result = try h.client.query("SELECT [1, NULL, 3] AS l");
    defer result.deinit();
    const chunk = (try result.nextChunk()).?;
    const v = chunk.column(0).?;
    const e = v.listEntry(0).?;
    const child = v.listChild().?;
    try testing.expect(!child.isNull(@intCast(e.offset)));
    try testing.expect(child.isNull(@intCast(e.offset + 1)));
    try testing.expect(!child.isNull(@intCast(e.offset + 2)));
}

// -- parameters ----------------------------------------------------------------

test "integration: bound parameters round trip by type" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var result = try h.client.queryParams(
        "SELECT ?::BIGINT a, ?::DOUBLE b, ?::VARCHAR c, ?::BOOLEAN d, ? e",
        &.{
            .{ .integer = std.math.maxInt(i64) },
            .{ .double = 1.5 },
            .{ .text = "wörld🦆" },
            .{ .boolean = true },
            .null,
        },
    );
    defer result.deinit();

    const chunk = (try result.nextChunk()).?;
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), (try chunk.getValue(0, 0)).bigint);
    try testing.expectEqual(@as(f64, 1.5), (try chunk.getValue(1, 0)).double);
    try testing.expectEqualStrings("wörld🦆", (try chunk.getValue(2, 0)).varchar);
    try testing.expectEqual(true, (try chunk.getValue(3, 0)).boolean);
    try testing.expect((try chunk.getValue(4, 0)).isNull());
}

test "integration: parameter binding resists SQL injection" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.client.exec("CREATE OR REPLACE TABLE quackling_inj (id INTEGER, name VARCHAR)");
    defer h.client.exec("DROP TABLE IF EXISTS quackling_inj") catch {};

    // A payload that would drop the table if it were interpolated naively.
    const attack = "'); DROP TABLE quackling_inj; --";
    try h.client.execParams(
        "INSERT INTO quackling_inj VALUES (?, ?)",
        &.{ .{ .integer = 1 }, .{ .text = attack } },
    );

    // The table must still exist, holding the payload as literal data.
    var result = try h.client.query("SELECT name FROM quackling_inj");
    defer result.deinit();
    const stored = (try result.scalar()).?;
    try testing.expectEqualStrings(attack, stored.varchar);
}

test "integration: parameter count mismatch is caught before sending" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try testing.expectError(
        error.ParameterCountMismatch,
        h.client.queryParams("SELECT ?, ?", &.{.{ .integer = 1 }}),
    );
}

// -- pooling -------------------------------------------------------------------

test "integration: pooled connections each run queries" {
    var t = try quackling.NativeTransport.init(testing.allocator, .{});
    defer t.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var pool = quackling.Pool.init(.{
        .allocator = testing.allocator,
        .endpoint = endpoint(),
        .token = token(),
        .transport = t.transport(),
        .io = threaded.io(),
        .max_connections = 3,
    }) catch return error.SkipZigTest;
    defer pool.deinit();

    // Hold several leases at once: each is a distinct server session.
    var a = pool.acquire(null) catch return error.SkipZigTest;
    var b = try pool.acquire(null);

    var ra = a.client.query("SELECT 1 AS v") catch |e| switch (e) {
        error.ConnectionFailed, error.NetworkError => return error.SkipZigTest,
        else => return e,
    };
    defer ra.deinit();
    var rb = try b.client.query("SELECT 2 AS v");
    defer rb.deinit();

    try testing.expectEqual(@as(i64, 1), (try ra.scalar()).?.asI64().?);
    try testing.expectEqual(@as(i64, 2), (try rb.scalar()).?.asI64().?);
    try testing.expect(!std.mem.eql(u8, a.client.connection_id, b.client.connection_id));

    ra.deinit();
    rb.deinit();
    a.release();
    b.release();
    try testing.expectEqual(@as(usize, 2), pool.snapshot().idle);
}

test "integration: streaming memory is bounded by batch size, not result size" {
    // The streaming contract (todo.md §12) is that peak memory tracks one
    // FETCH batch, not the whole result. Asserted by counting *live*
    // allocations at the high-water mark rather than by timing or RSS, which
    // are too noisy to gate a test on.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const Counting = struct {
        child: std.mem.Allocator,
        live: usize = 0,
        peak: usize = 0,

        fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const p = self.child.rawAlloc(len, a, ra) orelse return null;
            self.live += len;
            if (self.live > self.peak) self.peak = self.live;
            return p;
        }
        fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new: usize, ra: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!self.child.rawResize(buf, a, new, ra)) return false;
            self.live = self.live + new - buf.len;
            if (self.live > self.peak) self.peak = self.live;
            return true;
        }
        fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new: usize, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const p = self.child.rawRemap(buf, a, new, ra) orelse return null;
            self.live = self.live + new - buf.len;
            if (self.live > self.peak) self.peak = self.live;
            return p;
        }
        fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.child.rawFree(buf, a, ra);
            self.live -= buf.len;
        }
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            } };
        }
    };

    // Stream `n` rows and report the peak live-byte count.
    const measure = struct {
        fn run(client: *quackling.Client, counting: *Counting, n: u64) !usize {
            counting.peak = 0;
            var buf: [96]u8 = undefined;
            const sql = try std.fmt.bufPrint(&buf, "SELECT i FROM range({d}) t(i)", .{n});
            var result = try client.query(sql);
            defer result.deinit();
            var rows: u64 = 0;
            while (try result.nextChunk()) |chunk| rows += chunk.row_count;
            try testing.expectEqual(n, rows);
            return counting.peak;
        }
    }.run;

    var counting = Counting{ .child = testing.allocator };
    // Swap the client's allocator for the measuring one.
    h.client.allocator = counting.allocator();

    const small = try measure(&h.client, &counting, 10_000);
    const large = try measure(&h.client, &counting, 500_000);

    // 50x the rows must not cost anything like 50x the memory. A generous 4x
    // ceiling still fails loudly if streaming regresses into buffering.
    try testing.expect(large < small * 4);

    // Restore before teardown so the client frees with the allocator it used.
    h.client.allocator = testing.allocator;
}

// -- append (bulk insert) --------------------------------------------------------

test "integration: append inserts a chunk" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.client.exec(
        "CREATE OR REPLACE TABLE quackling_ap (id INTEGER, name VARCHAR, score DOUBLE, ok BOOLEAN)",
    );
    defer h.client.exec("DROP TABLE IF EXISTS quackling_ap") catch {};

    const ids = [_]quackling.Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    // An apostrophe here is the point: APPEND is binary, so no SQL escaping is
    // involved at all.
    const names = [_]quackling.Value{ .{ .varchar = "alice" }, .{ .varchar = "o'brien" }, .null };
    const scores = [_]quackling.Value{ .{ .double = 9.5 }, .{ .double = 7.25 }, .{ .double = 0 } };
    const oks = [_]quackling.Value{ .{ .boolean = true }, .{ .boolean = false }, .{ .boolean = true } };

    try h.client.append("quackling_ap", &.{
        .{ .type = .{ .id = .integer }, .values = &ids },
        .{ .type = .{ .id = .varchar }, .values = &names },
        .{ .type = .{ .id = .double }, .values = &scores },
        .{ .type = .{ .id = .boolean }, .values = &oks },
    });
    try testing.expectEqual(@as(u64, 1), h.client.stats.appends);

    var result = try h.client.query("SELECT id, name, score, ok FROM quackling_ap ORDER BY id");
    defer result.deinit();
    const chunk = (try result.nextChunk()).?;
    try testing.expectEqual(@as(usize, 3), chunk.row_count);
    try testing.expectEqualStrings("o'brien", (try chunk.getValue(1, 1)).varchar);
    try testing.expect(chunk.isNull(1, 2));
    try testing.expectEqual(@as(f64, 9.5), (try chunk.getValue(2, 0)).double);
    try testing.expectEqual(false, (try chunk.getValue(3, 1)).boolean);
}

test "integration: append handles a full 2048-row chunk" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.client.exec("CREATE OR REPLACE TABLE quackling_ap_bulk (i INTEGER)");
    defer h.client.exec("DROP TABLE IF EXISTS quackling_ap_bulk") catch {};

    const n = quackling.serialization.encoder.max_rows;
    const vals = try testing.allocator.alloc(quackling.Value, n);
    defer testing.allocator.free(vals);
    for (vals, 0..) |*v, i| v.* = .{ .integer = @intCast(i) };

    try h.client.append("quackling_ap_bulk", &.{
        .{ .type = .{ .id = .integer }, .values = vals },
    });

    var result = try h.client.query("SELECT count(*), sum(i) FROM quackling_ap_bulk");
    defer result.deinit();
    const chunk = (try result.nextChunk()).?;
    try testing.expectEqual(@as(i64, @intCast(n)), (try chunk.getValue(0, 0)).asI64().?);
    const expect: i64 = @intCast(n * (n - 1) / 2);
    try testing.expectEqual(expect, (try chunk.getValue(1, 0)).asI64().?);
}

test "integration: append to a missing table reports the server error" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const vals = [_]quackling.Value{.{ .integer = 1 }};
    try testing.expectError(error.ServerError, h.client.append("no_such_table_for_append", &.{
        .{ .type = .{ .id = .integer }, .values = &vals },
    }));
    try testing.expect(h.client.lastError().len > 0);
}

test "integration: append is far cheaper than row-wise INSERT" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // The reason APPEND exists: one request per chunk instead of per row, with
    // no SQL to re-parse. Asserted on request count, which is deterministic,
    // rather than on wall time.
    try h.client.exec("CREATE OR REPLACE TABLE quackling_ap_cost (i INTEGER)");
    defer h.client.exec("DROP TABLE IF EXISTS quackling_ap_cost") catch {};

    const n = 1000;
    const vals = try testing.allocator.alloc(quackling.Value, n);
    defer testing.allocator.free(vals);
    for (vals, 0..) |*v, i| v.* = .{ .integer = @intCast(i) };

    const before = h.client.stats.requests;
    try h.client.append("quackling_ap_cost", &.{
        .{ .type = .{ .id = .integer }, .values = vals },
    });
    // 1000 rows, one request.
    try testing.expectEqual(@as(u64, 1), h.client.stats.requests - before);
}

test "integration: cancellation stops a query" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var cancel = quackling.CancelToken{};
    cancel.cancel();
    try testing.expectError(
        error.Cancelled,
        h.client.queryWithCancel("SELECT 1", &cancel),
    );
}
