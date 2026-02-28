//! .proto file parsing and linking pipeline

/// Abstract syntax tree types for .proto files
pub const ast = @import("proto/ast.zig");
/// Tokenizer for .proto file syntax
pub const lexer = @import("proto/lexer.zig");
/// Parser that produces an AST from .proto tokens
pub const parser = @import("proto/parser.zig");
/// Linker that resolves cross-file type references
pub const linker = @import("proto/linker.zig");

test {
    _ = ast;
    _ = lexer;
    _ = parser;
    _ = linker;
}
