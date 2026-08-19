//! The Quackling CLI - a thin consumer of the library, exposed as `quackling`
//! (with a `qkl` alias for typing).
//!
//! Everything here is presentation and argument handling. No protocol logic
//! lives in this file, and nothing in the core library knows the CLI exists
//! (todo.md §15).
//!
//!   quackling --url quack:localhost:9494 --token secret "SELECT 42"
//!   quackling --format json "SELECT * FROM t"
//!   echo "SELECT 42" | quackling

const std = @import("std");
const quackling = @import("quackling");
const build_options = @import("build_options");

/// Reported by `--version`. Sourced from build.zig.zon (or `-Dversion=`), so it
/// cannot drift from the package metadata.
const version = build_options.version;

const Format = enum { table, csv, json, ndjson, markdown };

/// Typed empty slice, for `orelse` against `?[]const u8`.
const empty: []const u8 = "";

const Args = struct {
    url: []const u8 = "quack:localhost:9494",
    token: []const u8 = "",
    sql: ?[]const u8 = null,
    format: Format = .table,
    timing: bool = false,
    stats: bool = false,
    help: bool = false,
    version: bool = false,
    max_rows: ?u64 = null,
};

const usage =
    \\quackling - query a remote DuckDB over the Quack protocol
    \\
    \\Usage:
    \\  quackling [options] "<SQL>"
    \\  quackling [options] < query.sql
    \\
    \\`qkl` is installed as a shorter alias for the same command.
    \\
    \\Options:
    \\  --url <endpoint>    Server endpoint (default: quack:localhost:9494)
    \\  --token <token>     Authentication token
    \\  --format <fmt>      table | csv | json | ndjson | markdown  (default: table)
    \\  --max-rows <n>      Stop after n rows
    \\  --timing            Print elapsed time
    \\  --stats             Print connection statistics
    \\  -V, --version       Print the version and exit
    \\  -h, --help          Show this help
    \\
    \\The token may also be supplied via the QUACK_TOKEN environment variable.
    \\
    \\Examples:
    \\  quackling --url quack:localhost:9494 --token secret "SELECT 42"
    \\  quackling --format json "SELECT * FROM range(3) t(i)"
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    // The runtime-provided Io is shared by stdio and the HTTP transport.
    const io = init.io;
    // Process-lifetime arena, reclaimed by the runtime on exit.
    const arena = init.arena.allocator();

    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_file.interface;
    defer out.flush() catch {};

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr().writer(io, &stderr_buf);
    const err_w = &stderr_file.interface;
    defer err_w.flush() catch {};

    const argv = try init.minimal.args.toSlice(arena);

    var args = parseArgs(argv) catch |e| {
        try err_w.print("error: {s}\n\n{s}", .{ @errorName(e), usage });
        try err_w.flush();
        return 2;
    };

    if (args.version) {
        // Plain `name version` so installers and scripts can parse it.
        try out.print("quackling {s}\n", .{version});
        return 0;
    }

    if (args.help) {
        try out.writeAll(usage);
        return 0;
    }

    // Read SQL from stdin when it was not given as an argument.
    var stdin_sql: ?[]u8 = null;
    defer if (stdin_sql) |s| allocator.free(s);
    if (args.sql == null) {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_file = std.Io.File.stdin().reader(io, &stdin_buf);
        stdin_sql = stdin_file.interface.allocRemaining(allocator, .limited(1 << 20)) catch null;
        if (stdin_sql) |s| {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            if (trimmed.len > 0) args.sql = trimmed;
        }
    }

    const sql = args.sql orelse {
        try err_w.writeAll("error: no SQL provided\n\n");
        try err_w.writeAll(usage);
        try err_w.flush();
        return 2;
    };

    return run(allocator, io, args, sql, out, err_w) catch |e| {
        try err_w.print("error: {s}\n", .{@errorName(e)});
        try err_w.flush();
        return 1;
    };
}

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: Args,
    sql: []const u8,
    out: *std.Io.Writer,
    err_w: *std.Io.Writer,
) !u8 {
    var http = quackling.NativeTransport.initWithIo(allocator, io, .{});
    defer http.deinit();

    var client = try quackling.Client.init(.{
        .allocator = allocator,
        .endpoint = args.url,
        .token = args.token,
        .transport = http.transport(),
    });
    defer client.deinit();

    const started = std.Io.Clock.now(.awake, io);

    client.connect(null) catch |e| {
        // Surface the server's own words when it gave any.
        if (client.lastError().len > 0) {
            try err_w.print("connection failed: {s}\n", .{client.lastError()});
        } else {
            try err_w.print("connection failed: {s} ({s})\n", .{ @errorName(e), args.url });
        }
        try err_w.flush();
        return 1;
    };

    var result = client.query(sql) catch |e| {
        if (client.lastError().len > 0) {
            try err_w.print("{s}\n", .{client.lastError()});
        } else {
            try err_w.print("query failed: {s}\n", .{@errorName(e)});
        }
        try err_w.flush();
        return 1;
    };
    defer result.deinit();

    const rows = try emit(allocator, &result, args, out);

    if (args.timing) {
        const ended = std.Io.Clock.now(.awake, io);
        const ns = ended.nanoseconds - started.nanoseconds;
        try out.print("\n{d} row(s) in {d:.3} ms\n", .{
            rows,
            @as(f64, @floatFromInt(ns)) / 1_000_000.0,
        });
    }
    if (args.stats) {
        try out.print("\n{f}\n", .{client.stats});
    }
    try out.flush();
    return 0;
}

/// Dispatch to the chosen formatter. All of them consume the chunk stream, so
/// even `table` never holds the whole result in memory - only the rows it has
/// buffered for column widths.
fn emit(
    allocator: std.mem.Allocator,
    result: *quackling.Result,
    args: Args,
    out: *std.Io.Writer,
) !u64 {
    return switch (args.format) {
        .csv => try emitSeparated(allocator, result, args, out, ',', false),
        .markdown => try emitSeparated(allocator, result, args, out, '|', true),
        .ndjson => try emitJson(allocator, result, args, out, true),
        .json => try emitJson(allocator, result, args, out, false),
        .table => try emitTable(allocator, result, args, out),
    };
}

fn emitSeparated(
    allocator: std.mem.Allocator,
    result: *quackling.Result,
    args: Args,
    out: *std.Io.Writer,
    sep: u8,
    markdown: bool,
) !u64 {
    const ncols = result.columnCount();
    if (markdown) try out.writeAll("| ");
    for (0..ncols) |i| {
        if (i > 0) try out.writeAll(if (markdown) " | " else ",");
        try writeCsvField(out, result.columnName(i) orelse empty, sep, markdown);
    }
    if (markdown) try out.writeAll(" |");
    try out.writeAll("\n");

    if (markdown) {
        try out.writeAll("|");
        for (0..ncols) |_| try out.writeAll(" --- |");
        try out.writeAll("\n");
    }

    var n: u64 = 0;
    var stream = result.rows();
    while (try stream.next()) |row| {
        if (args.max_rows) |m| if (n >= m) break;
        if (markdown) try out.writeAll("| ");
        for (0..ncols) |i| {
            if (i > 0) try out.writeAll(if (markdown) " | " else ",");
            try writeCellEscaped(out, allocator, row, i, sep, markdown);
        }
        if (markdown) try out.writeAll(" |");
        try out.writeAll("\n");
        n += 1;
    }
    return n;
}

fn emitJson(
    allocator: std.mem.Allocator,
    result: *quackling.Result,
    args: Args,
    out: *std.Io.Writer,
    ndjson: bool,
) !u64 {
    const ncols = result.columnCount();
    if (!ndjson) try out.writeAll("[\n");

    var n: u64 = 0;
    var stream = result.rows();
    while (try stream.next()) |row| {
        if (args.max_rows) |m| if (n >= m) break;
        if (!ndjson and n > 0) try out.writeAll(",\n");
        try out.writeAll("{");
        for (0..ncols) |i| {
            if (i > 0) try out.writeAll(",");
            try out.writeAll("\"");
            try writeJsonString(out, result.columnName(i) orelse empty);
            try out.writeAll("\":");
            if (row.chunk.getValue(i, row.index)) |v| {
                try writeJsonValue(out, v);
            } else |err| switch (err) {
                error.UnsupportedType => {
                    const cell = try renderCell(allocator, row.chunk, i, row.index);
                    defer allocator.free(cell);
                    try out.writeAll("\"");
                    try writeJsonString(out, cell);
                    try out.writeAll("\"");
                },
                else => return err,
            }
        }
        try out.writeAll("}");
        if (ndjson) try out.writeAll("\n");
        n += 1;
    }
    if (!ndjson) try out.writeAll("\n]\n");
    return n;
}

/// Aligned table. Buffers rows to compute column widths, so it is capped: past
/// the cap it switches to streaming with the widths already determined.
fn emitTable(
    allocator: std.mem.Allocator,
    result: *quackling.Result,
    args: Args,
    out: *std.Io.Writer,
) !u64 {
    const ncols = result.columnCount();
    if (ncols == 0) {
        try out.writeAll("(no columns)\n");
        return 0;
    }

    const max_buffered = 1000;

    var widths = try allocator.alloc(usize, ncols);
    defer allocator.free(widths);
    for (0..ncols) |i| widths[i] = displayWidth(result.columnName(i) orelse "");

    // Buffer the first N rows as rendered strings to size the columns.
    var buffered: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (buffered.items) |row| {
            for (row) |cell| allocator.free(cell);
            allocator.free(row);
        }
        buffered.deinit(allocator);
    }

    var stream = result.rows();
    var truncated = false;
    while (try stream.next()) |row| {
        if (args.max_rows) |m| if (buffered.items.len >= m) break;
        if (buffered.items.len >= max_buffered) {
            truncated = true;
            break;
        }
        const cells = try allocator.alloc([]const u8, ncols);
        var filled: usize = 0;
        // Free what we already rendered if a later column fails, otherwise the
        // partially-built row leaks.
        errdefer {
            for (cells[0..filled]) |c| allocator.free(c);
            allocator.free(cells);
        }
        for (0..ncols) |i| {
            cells[i] = try renderCell(allocator, row.chunk, i, row.index);
            widths[i] = @max(widths[i], displayWidth(cells[i]));
            filled += 1;
        }
        try buffered.append(allocator, cells);
    }

    try writeRule(out, widths, "┌", "┬", "┐");
    try out.writeAll("│");
    for (0..ncols) |i| {
        try out.writeAll(" ");
        try writePadded(out, result.columnName(i) orelse empty, widths[i]);
        try out.writeAll(" │");
    }
    try out.writeAll("\n");
    try writeRule(out, widths, "├", "┼", "┤");

    var n: u64 = 0;
    for (buffered.items) |cells| {
        try out.writeAll("│");
        for (cells, 0..) |cell, i| {
            try out.writeAll(" ");
            try writePadded(out, cell, widths[i]);
            try out.writeAll(" │");
        }
        try out.writeAll("\n");
        n += 1;
    }

    // Anything past the buffer cap streams out with the established widths.
    if (truncated) {
        while (try stream.next()) |row| {
            if (args.max_rows) |m| if (n >= m) break;
            try out.writeAll("│");
            for (0..ncols) |i| {
                try out.writeAll(" ");
                const cell = try renderCell(allocator, row.chunk, i, row.index);
                defer allocator.free(cell);
                try writePadded(out, cell, widths[i]);
                try out.writeAll(" │");
            }
            try out.writeAll("\n");
            n += 1;
        }
    }

    try writeRule(out, widths, "└", "┴", "┘");
    return n;
}

fn writeRule(out: *std.Io.Writer, widths: []const usize, l: []const u8, m: []const u8, r: []const u8) !void {
    try out.writeAll(l);
    for (widths, 0..) |w, i| {
        if (i > 0) try out.writeAll(m);
        for (0..w + 2) |_| try out.writeAll("─");
    }
    try out.writeAll(r);
    try out.writeAll("\n");
}

/// Pad to `width` counting UTF-8 codepoints, not bytes, so multi-byte text
/// does not skew the columns.
fn writePadded(out: *std.Io.Writer, s: []const u8, width: usize) !void {
    try out.writeAll(s);
    const w = displayWidth(s);
    if (w < width) for (0..width - w) |_| try out.writeAll(" ");
}

fn displayWidth(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        // Count only UTF-8 lead bytes.
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

fn renderValue(allocator: std.mem.Allocator, v: quackling.Value) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    try v.format(&w.writer);
    return w.toOwnedSlice();
}

/// Render one cell, falling back to a structural rendering for the nested
/// types that the flat `Value` union cannot represent.
fn renderCell(
    allocator: std.mem.Allocator,
    chunk: *const quackling.DataChunk,
    col: usize,
    row: usize,
) ![]const u8 {
    if (chunk.getValue(col, row)) |v| {
        return renderValue(allocator, v);
    } else |err| switch (err) {
        error.UnsupportedType => {},
        else => return err,
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const vec = chunk.column(col) orelse return renderValue(allocator, .null);
    try writeNested(&w.writer, vec, row);
    return w.toOwnedSlice();
}

/// STRUCT / LIST / ARRAY / MAP / UNION rendering, mirroring DuckDB's text form.
fn writeNested(w: *std.Io.Writer, vec: *const quackling.Vector, row: usize) !void {
    if (vec.isNull(row)) return w.writeAll("NULL");

    // MAP and UNION are checked first: both are physically a LIST/STRUCT, so
    // the generic branches below would render their internal shape instead of
    // the type the user actually asked for.
    if (vec.mapEntry(row)) |m| {
        try w.writeAll("{");
        for (0..m.length) |k| {
            if (k > 0) try w.writeAll(", ");
            try writeNested(w, m.keys, @intCast(m.offset + k));
            try w.writeAll("=");
            try writeNested(w, m.values, @intCast(m.offset + k));
        }
        return w.writeAll("}");
    }

    if (vec.unionValue(row)) |u| {
        return writeNested(w, u.vector, row);
    }

    if (vec.children()) |kids| {
        try w.writeAll("{");
        for (kids, 0..) |*kid, i| {
            if (i > 0) try w.writeAll(", ");
            if (i < vec.type.children.len) {
                try w.print("'{s}': ", .{vec.type.children[i].name});
            }
            try writeNested(w, kid, row);
        }
        return w.writeAll("}");
    }

    if (vec.listEntry(row)) |entry| {
        const child = vec.listChild() orelse return w.writeAll("[]");
        try w.writeAll("[");
        for (0..entry.length) |k| {
            if (k > 0) try w.writeAll(", ");
            try writeNested(w, child, @intCast(entry.offset + k));
        }
        return w.writeAll("]");
    }

    if (vec.arraySize()) |size| {
        const child = vec.listChild() orelse return w.writeAll("[]");
        try w.writeAll("[");
        for (0..size) |k| {
            if (k > 0) try w.writeAll(", ");
            try writeNested(w, child, row * @as(usize, @intCast(size)) + k);
        }
        return w.writeAll("]");
    }

    // A scalar reachable here is one `Value` cannot model.
    const v = vec.getValue(row) catch return w.writeAll("<unsupported>");
    try v.format(w);
}

fn writeCsvField(out: *std.Io.Writer, s: []const u8, sep: u8, markdown: bool) !void {
    if (markdown) {
        // Escape the cell separator so it cannot break the table.
        for (s) |c| {
            if (c == '|') try out.writeAll("\\|") else try out.writeByte(c);
        }
        return;
    }
    const needs_quote = std.mem.indexOfScalar(u8, s, sep) != null or
        std.mem.indexOfAny(u8, s, "\"\n\r") != null;
    if (!needs_quote) return out.writeAll(s);
    try out.writeByte('"');
    for (s) |c| {
        if (c == '"') try out.writeAll("\"\"") else try out.writeByte(c);
    }
    try out.writeByte('"');
}

fn writeValueEscaped(out: *std.Io.Writer, v: quackling.Value, sep: u8, markdown: bool) !void {
    switch (v) {
        // NULL renders as an empty CSV field, which is the usual convention.
        .null => return,
        .varchar, .blob => |s| return writeCsvField(out, s, sep, markdown),
        else => {},
    }
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    v.format(&w) catch return out.writeAll("?");
    try writeCsvField(out, w.buffered(), sep, markdown);
}

/// Escape one cell for CSV/markdown, handling nested types via `renderCell`.
fn writeCellEscaped(
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    row: quackling.Row,
    col: usize,
    sep: u8,
    markdown: bool,
) !void {
    if (row.chunk.getValue(col, row.index)) |v| {
        return writeValueEscaped(out, v, sep, markdown);
    } else |err| switch (err) {
        error.UnsupportedType => {},
        else => return err,
    }
    const cell = try renderCell(allocator, row.chunk, col, row.index);
    defer allocator.free(cell);
    try writeCsvField(out, cell, sep, markdown);
}

fn writeJsonString(out: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        else => {
            if (c < 0x20) {
                try out.print("\\u{x:0>4}", .{c});
            } else {
                try out.writeByte(c);
            }
        },
    };
}

fn writeJsonValue(out: *std.Io.Writer, v: quackling.Value) !void {
    switch (v) {
        .null => try out.writeAll("null"),
        .boolean => |b| try out.writeAll(if (b) "true" else "false"),
        // Numeric types emit bare JSON numbers...
        .tinyint, .smallint, .integer, .bigint, .utinyint, .usmallint, .uinteger => {
            try out.print("{d}", .{v.asI64().?});
        },
        .float => |f| try out.print("{d}", .{f}),
        .double => |d| try out.print("{d}", .{d}),
        // ...except the 64/128-bit ones, which JSON cannot represent exactly.
        .ubigint => |x| try out.print("\"{d}\"", .{x}),
        .hugeint => |x| try out.print("\"{d}\"", .{x}),
        .uhugeint => |x| try out.print("\"{d}\"", .{x}),
        else => {
            var buf: [256]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            v.format(&w) catch {
                try out.writeAll("null");
                return;
            };
            try out.writeAll("\"");
            try writeJsonString(out, w.buffered());
            try out.writeAll("\"");
        },
    }
}

fn parseArgs(argv: []const [:0]const u8) !Args {
    var args = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            args.help = true;
        } else if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            args.version = true;
        } else if (std.mem.eql(u8, a, "--timing")) {
            args.timing = true;
        } else if (std.mem.eql(u8, a, "--stats")) {
            args.stats = true;
        } else if (std.mem.eql(u8, a, "--url")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.url = argv[i];
        } else if (std.mem.eql(u8, a, "--token")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.token = argv[i];
        } else if (std.mem.eql(u8, a, "--format")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.format = std.meta.stringToEnum(Format, argv[i]) orelse return error.UnknownFormat;
        } else if (std.mem.eql(u8, a, "--max-rows")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.max_rows = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownOption;
        } else {
            args.sql = a;
        }
    }
    return args;
}

const testing = std.testing;

test "argument parsing" {
    const argv = [_][:0]const u8{ "quackling", "--url", "quack:h:1", "--token", "t", "--format", "json", "SELECT 1" };
    const a = try parseArgs(&argv);
    try testing.expectEqualStrings("quack:h:1", a.url);
    try testing.expectEqualStrings("t", a.token);
    try testing.expectEqual(Format.json, a.format);
    try testing.expectEqualStrings("SELECT 1", a.sql.?);
}

test "unknown format and option are rejected" {
    try testing.expectError(error.UnknownFormat, parseArgs(&[_][:0]const u8{ "q", "--format", "xml" }));
    try testing.expectError(error.UnknownOption, parseArgs(&[_][:0]const u8{ "q", "--nope" }));
    try testing.expectError(error.MissingValue, parseArgs(&[_][:0]const u8{ "q", "--url" }));
}

/// Render through a formatter into a fixed buffer, for the escaping tests.
fn renderWith(
    buf: []u8,
    comptime f: fn (*std.Io.Writer, []const u8, u8, bool) anyerror!void,
    s: []const u8,
    sep: u8,
    markdown: bool,
) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try f(&w, s, sep, markdown);
    return w.buffered();
}

test "csv quoting follows RFC 4180" {
    var buf: [128]u8 = undefined;
    // Plain values are not quoted.
    try testing.expectEqualStrings("abc", try renderWith(&buf, writeCsvField, "abc", ',', false));
    // A separator forces quoting.
    try testing.expectEqualStrings("\"a,b\"", try renderWith(&buf, writeCsvField, "a,b", ',', false));
    // Embedded quotes are doubled.
    try testing.expectEqualStrings("\"say \"\"hi\"\"\"", try renderWith(&buf, writeCsvField, "say \"hi\"", ',', false));
    // Newlines and carriage returns force quoting too.
    try testing.expectEqualStrings("\"a\nb\"", try renderWith(&buf, writeCsvField, "a\nb", ',', false));
    try testing.expectEqualStrings("\"a\rb\"", try renderWith(&buf, writeCsvField, "a\rb", ',', false));
    // An empty field stays empty.
    try testing.expectEqualStrings("", try renderWith(&buf, writeCsvField, "", ',', false));
}

test "markdown cells escape the column separator" {
    var buf: [128]u8 = undefined;
    // A raw '|' would break the table structure.
    try testing.expectEqualStrings(
        "a\\|b",
        try renderWith(&buf, writeCsvField, "a|b", '|', true),
    );
    try testing.expectEqualStrings("plain", try renderWith(&buf, writeCsvField, "plain", '|', true));
}

test "json strings escape control characters and quotes" {
    var buf: [256]u8 = undefined;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "plain", .want = "plain" },
        .{ .in = "say \"hi\"", .want = "say \\\"hi\\\"" },
        .{ .in = "back\\slash", .want = "back\\\\slash" },
        .{ .in = "line\nbreak", .want = "line\\nbreak" },
        .{ .in = "tab\there", .want = "tab\\there" },
        .{ .in = "cr\rhere", .want = "cr\\rhere" },
        // Other control characters use the \u form.
        .{ .in = &[_]u8{ 'a', 0x01, 'b' }, .want = "a\\u0001b" },
        // Multi-byte UTF-8 passes through untouched.
        .{ .in = "wörld🦆", .want = "wörld🦆" },
    };
    for (cases) |c| {
        var w = std.Io.Writer.fixed(&buf);
        try writeJsonString(&w, c.in);
        try testing.expectEqualStrings(c.want, w.buffered());
    }
}

test "json values use the right literal kind per type" {
    var buf: [256]u8 = undefined;
    const cases = [_]struct { v: quackling.Value, want: []const u8 }{
        .{ .v = .null, .want = "null" },
        .{ .v = .{ .boolean = true }, .want = "true" },
        .{ .v = .{ .boolean = false }, .want = "false" },
        .{ .v = .{ .integer = -7 }, .want = "-7" },
        .{ .v = .{ .double = 1.5 }, .want = "1.5" },
        // 64/128-bit values exceed JSON's exact integer range, so they are
        // emitted as strings rather than silently losing precision.
        .{ .v = .{ .ubigint = std.math.maxInt(u64) }, .want = "\"18446744073709551615\"" },
        .{ .v = .{ .hugeint = std.math.maxInt(i128) }, .want = "\"170141183460469231731687303715884105727\"" },
        // Everything else renders as a quoted text form.
        .{ .v = .{ .date = 0 }, .want = "\"1970-01-01\"" },
    };
    for (cases) |c| {
        var w = std.Io.Writer.fixed(&buf);
        try writeJsonValue(&w, c.v);
        try testing.expectEqualStrings(c.want, w.buffered());
    }
}

test "json output survives a string that looks like json" {
    // A value containing braces and quotes must not break the document.
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJsonValue(&w, .{ .varchar = "{\"injected\": true}" });
    try testing.expectEqualStrings("\"{\\\"injected\\\": true}\"", w.buffered());
}

test "csv null renders as an empty field" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeValueEscaped(&w, .null, ',', false);
    try testing.expectEqualStrings("", w.buffered());
}

test "display width counts codepoints not bytes" {
    try testing.expectEqual(@as(usize, 5), displayWidth("hello"));
    try testing.expectEqual(@as(usize, 5), displayWidth("wörld"));
    try testing.expectEqual(@as(usize, 1), displayWidth("🦆"));
}
