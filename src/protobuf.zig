pub const encoding = @import("encoding.zig");
pub const message = @import("message.zig");
pub const proto = @import("proto.zig");
pub const codegen = @import("codegen.zig");
pub const rpc = @import("rpc.zig");
pub const json = @import("json.zig");
pub const text_format = @import("text_format.zig");
pub const descriptor = @import("descriptor.zig");
pub const dynamic = @import("dynamic.zig");

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
}
