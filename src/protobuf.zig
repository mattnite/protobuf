pub const encoding = @import("encoding.zig");
pub const message = @import("message.zig");
pub const proto = @import("proto.zig");
pub const codegen = @import("codegen.zig");

test {
    _ = encoding;
    _ = message;
    _ = proto;
    _ = codegen;
}
