pub const ast = @import("proto/ast.zig");
pub const lexer = @import("proto/lexer.zig");
pub const parser = @import("proto/parser.zig");
pub const linker = @import("proto/linker.zig");

test {
    _ = ast;
    _ = lexer;
    _ = parser;
    _ = linker;
}
