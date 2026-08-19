//! Quackling - a lightweight, standalone DuckDB Quack protocol client in Zig.
//!
//! Pure Zig: no DuckDB library, no C/C++ runtime, no external HTTP client.
//! The protocol core is free of OS and libc dependencies so it compiles for
//! native, WASI and freestanding wasm32 alike; I/O arrives through an injected
//! `Transport`.
//!
//! ```zig
//! var http = try quackling.NativeTransport.init(allocator, .{});
//! defer http.deinit();
//!
//! var client = try quackling.Client.init(.{
//!     .allocator = allocator,
//!     .endpoint = "quack:localhost:9494",
//!     .token = "super_secret",
//!     .transport = http.transport(),
//! });
//! defer client.deinit();
//!
//! var result = try client.query("SELECT 42 AS answer");
//! defer result.deinit();
//!
//! while (try result.nextChunk()) |chunk| {
//!     // vectorized processing
//! }
//! ```

const builtin = @import("builtin");

// -- public API ---------------------------------------------------------------

pub const Client = @import("client.zig").Client;
pub const ClientOptions = @import("client.zig").Options;
pub const Result = @import("result.zig").Result;
pub const RowStream = @import("result.zig").RowStream;

pub const DataChunk = @import("types/data_chunk.zig").DataChunk;
pub const Row = @import("types/data_chunk.zig").Row;
pub const Vector = @import("types/vector.zig").Vector;
pub const VectorType = @import("types/vector.zig").VectorType;
pub const Value = @import("types/value.zig").Value;
pub const LogicalType = @import("types/logical_type.zig").LogicalType;
pub const LogicalTypeId = @import("types/logical_type.zig").LogicalTypeId;
pub const ValidityMask = @import("types/validity.zig").ValidityMask;

pub const Transport = @import("transport/transport.zig").Transport;
pub const MockTransport = @import("transport/transport.zig").MockTransport;
pub const CancelToken = @import("transport/transport.zig").CancelToken;
pub const Header = @import("transport/transport.zig").Header;
/// The transport module, for callers implementing a custom `Transport` —
/// `quackling.transport.Request`, `.Response`, `.Error`.
///
/// Writing an adapter (e.g. onto a web framework's own HTTP client) needs these
/// types by name, so they get a namespace rather than only the flattened
/// aliases above.
pub const transport = @import("transport/transport.zig");

/// Deprecated alias for `transport`. The `_mod` suffix was an internal naming
/// convention that should not have reached the public API.
pub const transport_mod = transport;

/// Native HTTP transport. Only available on targets with networking; wasm
/// builds supply their own transport instead.
pub const NativeTransport = if (builtin.target.cpu.arch.isWasm())
    @compileError("NativeTransport is unavailable on wasm; provide a Transport (e.g. the browser fetch bridge in src/wasm)")
else
    @import("transport/native.zig").NativeTransport;

pub const Stats = @import("stats.zig").Stats;
pub const Observer = @import("stats.zig").Observer;
pub const ErrorInfo = @import("error.zig").ErrorInfo;

pub const typed = @import("typed.zig");
pub const params = @import("params.zig");
pub const AppendColumn = @import("serialization/encoder.zig").Column;
pub const Pool = @import("pool.zig").Pool;
pub const PoolOptions = @import("pool.zig").Options;
pub const Lease = @import("pool.zig").Lease;
pub const Param = @import("params.zig").Param;

// -- layered modules, exported for advanced use and testing -------------------

pub const serialization = struct {
    pub const Reader = @import("serialization/reader.zig").Reader;
    pub const Writer = @import("serialization/writer.zig").Writer;
    pub const decoder = @import("serialization/decoder.zig");
    pub const encoder = @import("serialization/encoder.zig");
    pub const reader = @import("serialization/reader.zig");
    pub const writer = @import("serialization/writer.zig");
};

pub const protocol = struct {
    pub const message = @import("protocol/message.zig");
    pub const compat = @import("protocol/compat.zig");
    pub const MessageType = @import("protocol/message.zig").MessageType;
    pub const MessageHeader = @import("protocol/message.zig").MessageHeader;
};

pub const uri = @import("uri.zig");
pub const errors = @import("error.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    // Explicitly pull in every module so its tests run under `zig build test`.
    _ = @import("serialization/reader.zig");
    _ = @import("serialization/writer.zig");
    _ = @import("serialization/decoder.zig");
    _ = @import("serialization/encoder.zig");
    _ = @import("types/logical_type.zig");
    _ = @import("types/validity.zig");
    _ = @import("types/value.zig");
    _ = @import("types/vector.zig");
    _ = @import("types/data_chunk.zig");
    _ = @import("protocol/compat.zig");
    _ = @import("protocol/message.zig");
    _ = @import("transport/transport.zig");
    _ = @import("transport/native.zig");
    _ = @import("uri.zig");
    _ = @import("stats.zig");
    _ = @import("error.zig");
    _ = @import("typed.zig");
    _ = @import("params.zig");
    _ = @import("pool.zig");
    _ = @import("result.zig");
    _ = @import("client.zig");
}

test "transport namespace is usable by adapter authors" {
    // An out-of-tree Transport implementation needs these by name; a regression
    // here breaks framework adapters without breaking anything in this repo.
    const T = @import("std").testing;
    try T.expect(transport.Request == transport_mod.Request);
    try T.expect(@TypeOf(transport.Error) == @TypeOf(transport_mod.Error));
    _ = transport.Response;
    _ = transport.Header;
    _ = transport.CancelToken;
}
