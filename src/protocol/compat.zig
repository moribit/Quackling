//! Protocol constants in one place.
//!
//! Quack is beta and explicitly expects breaking changes, so every magic number
//! the wire format depends on lives here rather than being scattered through the
//! codec (todo.md §23). When DuckDB 2.0 stabilises Quack, this file plus
//! `docs/PROTOCOL.md` should be the bulk of what needs revisiting.

const std = @import("std");

/// `QuackServer::QUACK_VERSION`. Advertised as both the min and max version we
/// speak during the handshake.
pub const quack_version: u64 = 1;
pub const min_supported_version: u64 = 1;
pub const max_supported_version: u64 = 1;

/// DuckDB's `SerializationCompatibility::FromIndex(7)`, which is what
/// `QuackMessage::ToMemoryStream` pins. Recorded for documentation; the client
/// does not currently vary its behaviour on it.
pub const serialization_version: u64 = 7;

/// HTTP surface.
pub const http_path = "/quack";
pub const content_type = "application/vnd.duckdb";
pub const default_port: u16 = 9494;
pub const uri_scheme = "quack:";

/// The DuckDB version string this client reports. Purely informational to the
/// server; it does not gate behaviour.
pub const client_version_string = "v1.4.1";

/// Reported to the server for logging. Derived at comptime from the build
/// target so it is accurate for cross-compiled and wasm builds alike.
pub const client_platform = blk: {
    const builtin = @import("builtin");
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .wasm32 => "wasm32",
        else => "unknown",
    };
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "osx",
        .windows => "windows",
        .wasi => "wasi",
        .freestanding => "wasm",
        else => "unknown",
    };
    break :blk os ++ "_" ++ arch;
};

/// Server default for `quack_fetch_batch_chunks`: how many DataChunks a single
/// FETCH response may carry. Informational - the client reads what it is given.
pub const default_fetch_batch_chunks: u64 = 12;

test "advertised version range is self-consistent" {
    try std.testing.expect(min_supported_version <= max_supported_version);
    try std.testing.expect(quack_version >= min_supported_version);
    try std.testing.expect(quack_version <= max_supported_version);
}

test "platform string is well formed" {
    try std.testing.expect(std.mem.indexOfScalar(u8, client_platform, '_') != null);
}
