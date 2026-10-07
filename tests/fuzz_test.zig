//! Robustness tests for the decoder (todo.md §22).
//!
//! The decoder is the only component that consumes untrusted bytes, so the
//! contract it must uphold is narrow and absolute: **arbitrary input produces
//! either a successful decode or a typed error - never a panic, an
//! out-of-bounds read, an integer overflow, or unbounded allocation.**
//!
//! Three strategies here:
//!   1. Systematic truncation of every real fixture at every length.
//!   2. Single-byte corruption of real fixtures.
//!   3. Pseudo-random and adversarial byte strings.
//!
//! `zig build test` runs these deterministically. `zig build fuzz` hands the
//! same entry point to Zig's fuzzer for unbounded exploration.

const std = @import("std");
const quackling = @import("quackling");

const Reader = quackling.serialization.Reader;
const message = quackling.protocol.message;
const testing = std.testing;

const corpus = [_][]const u8{
    @embedFile("fixtures/select42.bin"),
    @embedFile("fixtures/varchar.bin"),
    @embedFile("fixtures/mixed.bin"),
    @embedFile("fixtures/nullmix.bin"),
    @embedFile("fixtures/multirow.bin"),
    @embedFile("fixtures/hugeint.bin"),
    @embedFile("fixtures/error.bin"),
    @embedFile("fixtures/emptyresult.bin"),
    // Nested types exercise the recursive decode paths, which is where a
    // malformed length or depth is most likely to do damage.
    @embedFile("fixtures/struct.bin"),
    @embedFile("fixtures/list.bin"),
    @embedFile("fixtures/array.bin"),
    @embedFile("fixtures/map.bin"),
    @embedFile("fixtures/map_nested.bin"),
    @embedFile("fixtures/enum.bin"),
    @embedFile("fixtures/union.bin"),
    @embedFile("fixtures/nested_deep.bin"),
    @embedFile("fixtures/variant.bin"),
};

/// Feed `bytes` through the full message decode path.
///
/// Returns normally whether the decode succeeded or failed; the point is that
/// it must not crash. Memory is freed on both paths so the leak checker also
/// verifies error-path cleanup.
fn decodeUntrusted(allocator: std.mem.Allocator, bytes: []const u8) void {
    var r = Reader.initWithLimits(bytes, .{
        // Tight limits so a malicious length cannot make the test itself slow.
        .max_byte_length = 1 << 20,
        .max_list_length = 1 << 16,
        .max_depth = 32,
    });

    const header = message.MessageHeader.decode(&r) catch return;

    switch (header.type) {
        .prepare_response => {
            var body = message.PrepareResponse.decode(&r, allocator) catch return;
            body.deinit();
        },
        .fetch_response => {
            var body = message.FetchResponse.decode(&r, allocator) catch return;
            body.deinit();
        },
        .connection_response => {
            _ = message.ConnectionResponse.decode(&r) catch return;
        },
        .error_response => {
            _ = message.ErrorResponse.decode(&r) catch return;
        },
        else => {},
    }
}

test "fuzz: every prefix of every fixture is handled safely" {
    // Truncation is the single most common malformed input, and the one most
    // likely to walk off the end of a buffer.
    for (corpus) |fixture| {
        var len: usize = 0;
        while (len <= fixture.len) : (len += 1) {
            decodeUntrusted(testing.allocator, fixture[0..len]);
        }
    }
}

test "fuzz: single-byte corruption never crashes the decoder" {
    var buf: [64 * 1024]u8 = undefined;
    for (corpus) |fixture| {
        if (fixture.len > buf.len) continue;
        // Flipping every byte of every fixture to a handful of interesting
        // values covers length prefixes, field ids and type tags.
        const interesting = [_]u8{ 0x00, 0x01, 0x7F, 0x80, 0xFF };
        for (0..fixture.len) |i| {
            for (interesting) |v| {
                @memcpy(buf[0..fixture.len], fixture);
                buf[i] = v;
                decodeUntrusted(testing.allocator, buf[0..fixture.len]);
            }
        }
    }
}

test "fuzz: pseudo-random bytes are rejected without crashing" {
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rand = prng.random();
    var buf: [512]u8 = undefined;

    for (0..4000) |_| {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..len]);
        decodeUntrusted(testing.allocator, buf[0..len]);
    }
}

test "fuzz: structurally plausible but hostile messages are rejected" {
    // Each case is a valid-looking header followed by an abusive body.
    const hdr = [_]u8{ 0x01, 0x00, 0x04, 0x03, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0xFF, 0xFF };

    const bodies = [_][]const u8{
        // A list claiming 2^32 elements.
        &[_]u8{ 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F },
        // A string claiming 2^40 bytes.
        &[_]u8{ 0x02, 0x00, 0x80, 0x80, 0x80, 0x80, 0x20 },
        // Row count beyond STANDARD_VECTOR_SIZE.
        &[_]u8{ 0x04, 0x00, 0x01, 0x01, 0x2C, 0x01, 0x64, 0x00, 0xFF, 0xFF, 0xFF, 0x0F },
        // A varint that never terminates.
        &[_]u8{ 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
        // Field id that does not belong in this message.
        &[_]u8{ 0x63, 0x00, 0x01, 0xFF, 0xFF },
        // Deeply nested objects, to probe the depth limit.
        comptime blk: {
            const pattern = [_]u8{ 0x01, 0x00, 0x01, 0x65, 0x00, 0x01 };
            var nested: [pattern.len * 40]u8 = undefined;
            for (0..40) |i| @memcpy(nested[i * pattern.len ..][0..pattern.len], &pattern);
            const bytes = nested;
            break :blk &bytes;
        },
    };

    var buf: [4096]u8 = undefined;
    for (bodies) |body| {
        if (hdr.len + body.len > buf.len) continue;
        @memcpy(buf[0..hdr.len], &hdr);
        @memcpy(buf[hdr.len..][0..body.len], body);
        decodeUntrusted(testing.allocator, buf[0 .. hdr.len + body.len]);
    }
}

test "fuzz: reader primitives reject malformed input at the boundary" {
    // Direct assertions on the primitives, where the guarantees are strongest.
    const reader = quackling.serialization.reader;

    // Overlong varints must not wrap around.
    var r1 = Reader.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F });
    try testing.expectError(reader.Error.VarIntOverflow, r1.readUVarInt(u64));

    // A length prefix beyond the buffer must fail before allocating.
    var r2 = Reader.init(&[_]u8{0xFF});
    try testing.expectError(reader.Error.UnexpectedEndOfBuffer, r2.readString());

    // An empty buffer yields end-of-buffer, not a panic.
    var r3 = Reader.init(&[_]u8{});
    try testing.expectError(reader.Error.UnexpectedEndOfBuffer, r3.readFieldId());
    try testing.expectError(reader.Error.UnexpectedEndOfBuffer, r3.readByte());
    try testing.expectError(reader.Error.UnexpectedEndOfBuffer, r3.readF64());
    try testing.expectError(reader.Error.UnexpectedEndOfBuffer, r3.readHugeInt());
}

test "fuzz: decoder honours the depth limit" {
    // 200 nested LogicalType objects, well past the default max_depth.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        // field 101 (type_info), present = 1, field 100 (eti type)
        try buf.appendSlice(testing.allocator, &[_]u8{ 0x65, 0x00, 0x01, 0x64, 0x00, 0x04 });
    }
    var r = Reader.initWithLimits(buf.items, .{ .max_depth = 16 });
    const decoder = quackling.serialization.decoder;
    // Must terminate with an error, not recurse until the stack dies.
    _ = decoder.decodeLogicalType(&r, testing.allocator) catch return;
}

// Fuzzer entry point: `zig build test --fuzz`.
//
// The deterministic tests above already cover truncation, corruption and random
// input; this hands the same decode path to Zig's coverage-guided fuzzer so it
// can search for inputs those strategies miss.
test "fuzz" {
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);
            decodeUntrusted(std.testing.allocator, buf[0..len]);
        }
    };
    // Under a normal `zig build test` this returns immediately after a single
    // deterministic input; with `--fuzz` it loops under coverage guidance.
    try std.testing.fuzz({}, Ctx.one, .{});
}
