//! Query parameters.
//!
//! ## Why this is not protocol-level binding
//!
//! Quack protocol version 1 has **no wire representation for parameters**.
//! `PrepareRequestMessage` carries exactly one field - the SQL string - and the
//! server calls `SendQuery(sql)` with it directly
//! (`duckdb-quack/src/quack_server.cpp`). Two facts were verified against a
//! live server:
//!
//!   * `SELECT ?` returns *"Expected 1 parameters, but none were supplied"* -
//!     there is no channel to supply them.
//!   * Adding an extra field to `PREPARE_REQUEST` makes the server return
//!     HTTP 500 - unknown fields are rejected, so we cannot invent one.
//!
//! So parameters are rendered into the SQL text here, client-side. That places
//! the entire safety burden on this file, which is why the encoders below are
//! strict and why anything that cannot be encoded unambiguously is rejected
//! rather than approximated.
//!
//! Callers who want server-side prepared statements can still use SQL-level
//! `PREPARE` / `EXECUTE`, which the protocol handles fine.
//!
//! ```zig
//! var result = try client.queryParams(
//!     "SELECT * FROM t WHERE id = ? AND name = ?",
//!     &.{ .{ .integer = 42 }, .{ .text = "o'brien" } },
//! );
//! ```

const std = @import("std");
const value_mod = @import("types/value.zig");

/// `ParameterCountMismatch` - placeholder count did not match the arguments.
/// `UnsupportedParameter` - the value has no unambiguous SQL literal form.
/// `InvalidUtf8` - a text parameter was not valid UTF-8.
pub const Error = @import("error.zig").ParameterError || std.mem.Allocator.Error;

/// A bindable parameter.
///
/// Deliberately a smaller set than `Value`: every variant here has an exact,
/// unambiguous SQL literal form. Types whose text form would be lossy or
/// dialect-dependent are omitted rather than guessed at.
pub const Param = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    /// 128-bit integers, rendered exactly (they exceed f64 precision).
    hugeint: i128,
    unsigned: u64,
    uhugeint: u128,
    double: f64,
    /// Rendered as a quoted string literal with `''` escaping.
    text: []const u8,
    /// Rendered as a BLOB literal with hex escapes.
    blob: []const u8,
    /// Days since 1970-01-01, rendered as `DATE 'YYYY-MM-DD'`.
    date: i32,
    /// Microseconds since the epoch, as `TIMESTAMP 'YYYY-MM-DD HH:MM:SS[.ffffff]'`.
    timestamp: i64,
    /// A decimal, rendered exactly from its unscaled value.
    decimal: value_mod.Value.Decimal,
    /// Pre-rendered SQL, inserted verbatim.
    ///
    /// This is an escape hatch for expressions (`now()`, a column reference).
    /// It is **not escaped** - never build one from untrusted input.
    raw_sql: []const u8,

    /// Convenience constructors, so call sites read cleanly.
    pub fn int(v: anytype) Param {
        return .{ .integer = @intCast(v) };
    }
    pub fn str(v: []const u8) Param {
        return .{ .text = v };
    }
};

/// Substitute `params` into `sql`, replacing each `?` placeholder.
///
/// Returns freshly allocated SQL owned by the caller. Placeholders inside
/// string literals, quoted identifiers and comments are **not** substituted,
/// because they are data, not placeholders.
pub fn bind(
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: []const Param,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var next: usize = 0;
    var i: usize = 0;
    while (i < sql.len) {
        const c = sql[i];
        switch (c) {
            // A '?' inside a literal or comment is content, so the scanners
            // below copy those regions through untouched.
            '\'' => i = try copyQuoted(allocator, &out, sql, i, '\''),
            '"' => i = try copyQuoted(allocator, &out, sql, i, '"'),
            '$' => {
                // Dollar-quoted string: $tag$ ... $tag$
                if (findDollarQuote(sql, i)) |end| {
                    try out.appendSlice(allocator, sql[i..end]);
                    i = end;
                } else {
                    try out.append(allocator, c);
                    i += 1;
                }
            },
            '-' => {
                if (i + 1 < sql.len and sql[i + 1] == '-') {
                    const end = std.mem.indexOfScalarPos(u8, sql, i, '\n') orelse sql.len;
                    try out.appendSlice(allocator, sql[i..end]);
                    i = end;
                } else {
                    try out.append(allocator, c);
                    i += 1;
                }
            },
            '/' => {
                if (i + 1 < sql.len and sql[i + 1] == '*') {
                    const end = if (std.mem.indexOfPos(u8, sql, i + 2, "*/")) |e| e + 2 else sql.len;
                    try out.appendSlice(allocator, sql[i..end]);
                    i = end;
                } else {
                    try out.append(allocator, c);
                    i += 1;
                }
            },
            '?' => {
                if (next >= params.len) return Error.ParameterCountMismatch;
                try encode(allocator, &out, params[next]);
                next += 1;
                i += 1;
            },
            else => {
                try out.append(allocator, c);
                i += 1;
            },
        }
    }

    // Too few placeholders is just as wrong as too many: it means the caller
    // and the query disagree about the shape of the statement.
    if (next != params.len) return Error.ParameterCountMismatch;
    return out.toOwnedSlice(allocator);
}

/// Copy a quoted region verbatim, honouring doubled-quote escapes.
/// Returns the index just past the closing quote.
fn copyQuoted(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    sql: []const u8,
    start: usize,
    quote: u8,
) Error!usize {
    try out.append(allocator, sql[start]);
    var i = start + 1;
    while (i < sql.len) {
        if (sql[i] == quote) {
            // A doubled quote is an escaped quote, not the end.
            if (i + 1 < sql.len and sql[i + 1] == quote) {
                try out.appendSlice(allocator, sql[i .. i + 2]);
                i += 2;
                continue;
            }
            try out.append(allocator, quote);
            return i + 1;
        }
        try out.append(allocator, sql[i]);
        i += 1;
    }
    return i;
}

/// If `sql[start]` opens a dollar-quoted string, return the index just past its
/// terminator; otherwise null.
fn findDollarQuote(sql: []const u8, start: usize) ?usize {
    const tag_end = std.mem.indexOfScalarPos(u8, sql, start + 1, '$') orelse return null;
    const tag = sql[start .. tag_end + 1]; // includes both '$'
    // A tag may only contain identifier characters.
    for (sql[start + 1 .. tag_end]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    }
    const close = std.mem.indexOfPos(u8, sql, tag_end + 1, tag) orelse return null;
    return close + tag.len;
}

/// Render one parameter as a SQL literal.
pub fn encode(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    p: Param,
) Error!void {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    // `Allocating` takes the list by value; hand it back on every path so the
    // caller's buffer keeps the appended bytes.
    defer out.* = aw.toArrayList();
    const w = &aw.writer;
    encodeTo(w, p) catch |e| switch (e) {
        error.WriteFailed => return Error.OutOfMemory,
        else => |other| return other,
    };
}

fn encodeTo(w: *std.Io.Writer, p: Param) !void {
    switch (p) {
        .null => try w.writeAll("NULL"),
        .boolean => |v| try w.writeAll(if (v) "TRUE" else "FALSE"),
        .integer => |v| try w.print("{d}", .{v}),
        .hugeint => |v| try w.print("{d}", .{v}),
        .unsigned => |v| try w.print("{d}", .{v}),
        .uhugeint => |v| try w.print("{d}", .{v}),
        .double => |v| try encodeDouble(w, v),
        .text => |s| try encodeText(w, s),
        .blob => |b| try encodeBlob(w, b),
        .date => |d| {
            try w.writeAll("DATE '");
            try value_mod.writeDate(w, d);
            try w.writeAll("'");
        },
        .timestamp => |t| {
            try w.writeAll("TIMESTAMP '");
            try value_mod.writeTimestamp(w, t);
            try w.writeAll("'");
        },
        .decimal => |d| {
            try value_mod.writeDecimal(w, d);
        },
        .raw_sql => |s| try w.writeAll(s),
    }
}

/// Doubles need care: NaN/Inf have no plain literal form, and a default float
/// format can lose precision. Use the shortest round-trip representation and
/// cast so DuckDB reads it as a DOUBLE rather than a DECIMAL.
fn encodeDouble(w: *std.Io.Writer, v: f64) !void {
    if (std.math.isNan(v)) return w.writeAll("'NaN'::DOUBLE");
    if (std.math.isPositiveInf(v)) return w.writeAll("'Infinity'::DOUBLE");
    if (std.math.isNegativeInf(v)) return w.writeAll("'-Infinity'::DOUBLE");
    try w.print("{d}::DOUBLE", .{v});
}

/// Single-quoted literal with `''` escaping.
///
/// Also rejects embedded NUL, which DuckDB cannot carry inside a string
/// literal, and validates UTF-8 so a malformed byte sequence cannot produce a
/// surprising parse on the server.
fn encodeText(w: *std.Io.Writer, s: []const u8) !void {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return Error.UnsupportedParameter;
    if (!std.unicode.utf8ValidateSlice(s)) return Error.InvalidUtf8;

    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeByte('\'');
        try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// BLOB literal. Every byte is hex-escaped: unambiguous, and immune to
/// quoting issues in binary data.
fn encodeBlob(w: *std.Io.Writer, b: []const u8) !void {
    try w.writeAll("'");
    const hex = "0123456789ABCDEF";
    for (b) |c| {
        try w.writeAll("\\x");
        try w.writeByte(hex[c >> 4]);
        try w.writeByte(hex[c & 0x0F]);
    }
    try w.writeAll("'::BLOB");
}

const testing = std.testing;

fn bindAlloc(sql: []const u8, params: []const Param) ![]u8 {
    return bind(testing.allocator, sql, params);
}

test "scalar parameters render as literals" {
    const got = try bindAlloc("SELECT ?, ?, ?, ?", &.{
        .{ .integer = 42 },
        .{ .boolean = true },
        .null,
        .{ .double = 1.5 },
    });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("SELECT 42, TRUE, NULL, 1.5::DOUBLE", got);
}

test "string quotes are escaped by doubling" {
    const got = try bindAlloc("SELECT ?", &.{.{ .text = "o'brien" }});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("SELECT 'o''brien'", got);
}

test "classic injection attempts stay inside the literal" {
    const got = try bindAlloc("SELECT * FROM t WHERE n = ?", &.{
        .{ .text = "'; DROP TABLE users; --" },
    });
    defer testing.allocator.free(got);
    // The payload is one quoted string; the statement shape is unchanged.
    try testing.expectEqualStrings(
        "SELECT * FROM t WHERE n = '''; DROP TABLE users; --'",
        got,
    );
}

test "placeholders inside literals and comments are left alone" {
    // The '?' in the string literal is data, not a placeholder.
    const a = try bindAlloc("SELECT 'is it ?' , ?", &.{.{ .integer = 1 }});
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("SELECT 'is it ?' , 1", a);

    const b = try bindAlloc("SELECT ? -- what ?\n", &.{.{ .integer = 2 }});
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("SELECT 2 -- what ?\n", b);

    const c = try bindAlloc("SELECT /* ? */ ?", &.{.{ .integer = 3 }});
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("SELECT /* ? */ 3", c);

    const d = try bindAlloc("SELECT \"weird?col\", ?", &.{.{ .integer = 4 }});
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("SELECT \"weird?col\", 4", d);
}

test "doubled quotes inside a literal do not end it early" {
    const got = try bindAlloc("SELECT 'a''?b', ?", &.{.{ .integer = 9 }});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("SELECT 'a''?b', 9", got);
}

test "dollar quoted strings are left alone" {
    const got = try bindAlloc("SELECT $tag$ ? $tag$, ?", &.{.{ .integer = 5 }});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("SELECT $tag$ ? $tag$, 5", got);
}

test "parameter count must match exactly" {
    try testing.expectError(Error.ParameterCountMismatch, bindAlloc("SELECT ?", &.{}));
    try testing.expectError(
        Error.ParameterCountMismatch,
        bindAlloc("SELECT ?", &.{ .{ .integer = 1 }, .{ .integer = 2 } }),
    );
    try testing.expectError(
        Error.ParameterCountMismatch,
        bindAlloc("SELECT 1", &.{.{ .integer = 1 }}),
    );
}

test "blobs are hex escaped" {
    const got = try bindAlloc("SELECT ?", &.{.{ .blob = &[_]u8{ 0x00, 0xFF, 'a' } }});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("SELECT '\\x00\\xFF\\x61'::BLOB", got);
}

test "invalid utf8 and embedded NUL are rejected" {
    try testing.expectError(Error.InvalidUtf8, bindAlloc("SELECT ?", &.{
        .{ .text = &[_]u8{ 0xFF, 0xFE } },
    }));
    try testing.expectError(Error.UnsupportedParameter, bindAlloc("SELECT ?", &.{
        .{ .text = &[_]u8{ 'a', 0, 'b' } },
    }));
}

test "special floats get an explicit literal form" {
    const got = try bindAlloc("SELECT ?, ?, ?", &.{
        .{ .double = std.math.nan(f64) },
        .{ .double = std.math.inf(f64) },
        .{ .double = -std.math.inf(f64) },
    });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "SELECT 'NaN'::DOUBLE, 'Infinity'::DOUBLE, '-Infinity'::DOUBLE",
        got,
    );
}

test "wide integers keep full precision" {
    const got = try bindAlloc("SELECT ?, ?", &.{
        .{ .hugeint = std.math.maxInt(i128) },
        .{ .unsigned = std.math.maxInt(u64) },
    });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "SELECT 170141183460469231731687303715884105727, 18446744073709551615",
        got,
    );
}

test "temporal parameters render as typed literals" {
    const got = try bindAlloc("SELECT ?, ?", &.{
        .{ .date = 19797 }, // 2024-03-15
        .{ .timestamp = 1710506096000000 },
    });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "SELECT DATE '2024-03-15', TIMESTAMP '2024-03-15 12:34:56'",
        got,
    );
}

test "raw_sql is inserted verbatim" {
    const got = try bindAlloc("SELECT ?", &.{.{ .raw_sql = "now()" }});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("SELECT now()", got);
}
