//! Wire payloads captured from a live DuckDB Quack server, embedded so that
//! benchmarks and tests need no filesystem access at runtime.
pub const select42 = @embedFile("select42.bin");
pub const largeresult = @embedFile("largeresult.bin");
pub const varchar = @embedFile("varchar.bin");
pub const nullmix = @embedFile("nullmix.bin");
pub const mixed = @embedFile("mixed.bin");
pub const multirow = @embedFile("multirow.bin");
pub const @"struct" = @embedFile("struct.bin");
pub const list = @embedFile("list.bin");
pub const list_nulls = @embedFile("list_nulls.bin");
pub const array = @embedFile("array.bin");
pub const map = @embedFile("map.bin");
pub const map_nested = @embedFile("map_nested.bin");
pub const @"enum" = @embedFile("enum.bin");
pub const @"union" = @embedFile("union.bin");
pub const nested_deep = @embedFile("nested_deep.bin");
pub const temporal = @embedFile("temporal.bin");
pub const decimal = @embedFile("decimal.bin");
pub const uuid = @embedFile("uuid.bin");
pub const blob = @embedFile("blob.bin");
