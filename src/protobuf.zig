//! Pure Zig Protocol Buffers library — proto2/proto3 wire format, codegen, JSON, text format, and RPC stubs

/// Wire format encoding and decoding primitives (varints, fixed-width, tags, ZigZag)
pub const encoding = @import("encoding.zig");
/// Schema-agnostic message-level codec (field iteration, skipping, size calculation)
pub const message = @import("message.zig");
/// Pure-Zig .proto file lexer, parser, AST, and linker
pub const proto = @import("proto.zig");
/// Code generator that emits Zig structs from parsed .proto definitions
pub const codegen = @import("codegen.zig");
/// Transport-agnostic RPC stub types and service interfaces
pub const rpc = @import("rpc.zig");
/// Proto-JSON encoding and decoding helpers
pub const json = @import("json.zig");
/// Proto text format serialization and deserialization helpers
pub const text_format = @import("text_format.zig");
/// Runtime descriptor types for protobuf reflection
pub const descriptor = @import("descriptor.zig");
/// Dynamic message encode/decode without generated code, driven by descriptors
pub const dynamic = @import("dynamic.zig");
/// Protoc plugin support for use as protoc-gen-zig
pub const plugin = @import("plugin.zig");

test {
    _ = encoding;
    _ = message;
    _ = proto;
    _ = codegen;
    _ = rpc;
    _ = json;
    _ = text_format;
    _ = descriptor;
    _ = dynamic;
    _ = plugin;
}
