# Proto File Parser

Design for the standalone `.proto` file parser. Supports both `syntax =
"proto2"` and `syntax = "proto3"`. Implemented in pure Zig with no protoc
dependency.

## Pipeline Overview

```
.proto source text
       │
       ▼
  ┌──────────┐
  │  Lexer   │  src/proto/lexer.zig
  │          │  Bytes → Tokens (with source locations)
  └────┬─────┘
       │ Token stream
       ▼
  ┌──────────┐
  │  Parser  │  src/proto/parser.zig
  │          │  Tokens → AST (per-file, unresolved references)
  └────┬─────┘
       │ AST nodes
       ▼
  ┌──────────┐
  │  Linker  │  src/proto/linker.zig
  │          │  Multiple ASTs → Resolved descriptor set
  │          │  (type resolution, validation, import handling)
  └────┬─────┘
       │ Resolved descriptors
       ▼
  Code Generator (see codegen.md)
```

## Lexer (`src/proto/lexer.zig`)

### Token Types

```zig
pub const TokenKind = enum {
    // Literals
    identifier,     // letter (letter | digit | '_')*
    integer,        // decimal, octal (0...), or hex (0x...)
    float_literal,  // decimal float, "inf", "nan"
    string_literal, // single or double quoted, with escapes resolved

    // Punctuation / symbols
    semicolon,      // ;
    comma,          // ,
    dot,            // .
    equals,         // =
    minus,          // -
    plus,           // +
    open_brace,     // {
    close_brace,    // }
    open_bracket,   // [
    close_bracket,  // ]
    open_paren,     // (
    close_paren,    // )
    open_angle,     // <
    close_angle,    // >
    slash,          // /

    // Special
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,       // raw source text of the token
    location: SourceLocation,
};

pub const SourceLocation = struct {
    file: []const u8,
    line: u32,
    column: u32,
};
```

### Keyword Handling

Protobuf keywords (`message`, `enum`, `service`, `optional`, `repeated`,
`map`, `oneof`, `import`, `package`, `syntax`, `returns`, `stream`, `rpc`,
`extend`, `extensions`, `reserved`, `required`, `group`, `option`, `to`,
`max`, `true`, `false`, `inf`, `nan`) are lexed as `identifier` tokens.

The parser checks the text of identifier tokens against keywords in context.
This is necessary because keywords are valid as field names, type names, and
other identifiers in many positions. For example, this is legal:

```protobuf
message message {
    optional string optional = 1;
}
```

### String Literals

The lexer resolves escape sequences during tokenization:
- `\a`, `\b`, `\f`, `\n`, `\r`, `\t`, `\v`, `\\`, `\'`, `\"`
- `\xHH` — hex escape (1-2 hex digits)
- `\OOO` — octal escape (1-3 octal digits)
- `\uHHHH` — unicode escape (4 hex digits)
- `\UHHHHHHHH` — long unicode escape (8 hex digits, max U+10FFFF)

Adjacent string literals are concatenated (like C):
```protobuf
option foo = "hello "
             "world";  // equivalent to "hello world"
```

### Comments

- Line comments: `//` through end of line
- Block comments: `/* ... */` (no nesting)

Comments are consumed by the lexer but can optionally be preserved for
documentation generation. They are not emitted as tokens to the parser.

### Lexer Interface

```zig
pub const Lexer = struct {
    source: []const u8,
    file_name: []const u8,
    pos: usize,
    line: u32,
    column: u32,

    pub fn init(source: []const u8, file_name: []const u8) Lexer

    /// Return the next token. Returns .eof when input is exhausted.
    pub fn next(self: *Lexer) !Token

    /// Peek at the next token without consuming it.
    pub fn peek(self: *Lexer) !Token
};
```

## Parser (`src/proto/parser.zig`)

Recursive descent parser. Consumes the token stream and produces an AST. Each
parse function corresponds to a grammar production.

### Grammar (Simplified)

```
file        = syntax_decl { top_level_stmt }
syntax_decl = "syntax" "=" string_lit ";"

top_level_stmt = import_decl
               | package_decl
               | option_decl
               | message_def
               | enum_def
               | service_def
               | extend_def        // proto2 only
               | ";"

import_decl   = "import" [ "public" | "weak" ] string_lit ";"
package_decl  = "package" full_ident ";"
option_decl   = "option" option_name "=" constant ";"

message_def   = "message" ident "{" { message_element } "}"
message_element = field
                | enum_def
                | message_def
                | extend_def
                | extensions_decl
                | group_def
                | option_decl
                | oneof_def
                | map_field
                | reserved_decl
                | ";"

field = [ label ] type ident "=" integer [ "[" field_options "]" ] ";"
label = "required" | "optional" | "repeated"

enum_def    = "enum" ident "{" { enum_element } "}"
enum_element = enum_field | option_decl | reserved_decl | ";"
enum_field  = ident "=" [ "-" ] integer [ "[" field_options "]" ] ";"

service_def = "service" ident "{" { service_element } "}"
service_element = option_decl | rpc_def | ";"
rpc_def     = "rpc" ident "(" [ "stream" ] type_name ")"
              "returns" "(" [ "stream" ] type_name ")"
              ( "{" { option_decl | ";" } "}" | ";" )

oneof_def   = "oneof" ident "{" { oneof_field | option_decl | ";" } "}"
oneof_field = type ident "=" integer [ "[" field_options "]" ] ";"

map_field   = "map" "<" key_type "," type ">" ident "=" integer
              [ "[" field_options "]" ] ";"

reserved_decl    = "reserved" ( ranges | field_names ) ";"
extensions_decl  = "extensions" ranges [ "[" field_options "]" ] ";"
extend_def       = "extend" type_name "{" { field | group_def } "}"
group_def        = label "group" ident "=" integer "{" { message_element } "}"
```

### Parser Interface

```zig
pub const Parser = struct {
    lexer: Lexer,
    allocator: std.mem.Allocator,
    diagnostics: *DiagnosticList,

    pub fn init(lexer: Lexer, allocator: std.mem.Allocator, diagnostics: *DiagnosticList) Parser
    pub fn parse_file(self: *Parser) !ast.File
};

pub const Diagnostic = struct {
    location: SourceLocation,
    severity: enum { err, warning },
    message: []const u8,
};

pub const DiagnosticList = std.ArrayList(Diagnostic);
```

### Lookahead Strategy

The grammar is LL(2) at most. The main ambiguity is distinguishing:
- A field definition from a message/enum/oneof/map definition (look at first
  token: keyword vs type name)
- A label (`optional`/`required`/`repeated`) from a type name (these keywords
  can be type names; look ahead to see if the next token is also an identifier
  followed by `=`)

The parser peeks 1-2 tokens ahead to resolve these.

## AST (`src/proto/ast.zig`)

The AST represents a single `.proto` file. Type references are unresolved
strings at this stage.

```zig
pub const File = struct {
    syntax: Syntax,
    package: ?[]const u8,
    imports: []Import,
    options: []Option,
    messages: []Message,
    enums: []Enum,
    services: []Service,
    extensions: []Extend,   // top-level extend declarations
};

pub const Syntax = enum { proto2, proto3 };

pub const Import = struct {
    path: []const u8,
    kind: enum { default, public, weak },
    location: SourceLocation,
};

pub const Message = struct {
    name: []const u8,
    fields: []Field,
    oneofs: []Oneof,
    nested_messages: []Message,
    nested_enums: []Enum,
    maps: []MapField,
    reserved_ranges: []ReservedRange,
    reserved_names: [][]const u8,
    extension_ranges: []ExtensionRange, // proto2
    extensions: []Extend,               // proto2
    groups: []Group,                    // proto2, deprecated
    options: []Option,
    location: SourceLocation,
};

pub const Field = struct {
    name: []const u8,
    number: i32,
    label: FieldLabel,
    type_name: TypeRef,
    options: []FieldOption,
    location: SourceLocation,
};

pub const FieldLabel = enum {
    required,   // proto2 only
    optional,   // proto2 always, proto3 explicit presence
    repeated,
    implicit,   // proto3 no-label (no presence tracking)
};

pub const TypeRef = union(enum) {
    /// Built-in scalar type.
    scalar: ScalarType,
    /// Reference to a message or enum type (not yet resolved).
    named: []const u8,
};

pub const ScalarType = enum {
    double,
    float,
    int32,
    int64,
    uint32,
    uint64,
    sint32,
    sint64,
    fixed32,
    fixed64,
    sfixed32,
    sfixed64,
    bool,
    string,
    bytes,
};

pub const Oneof = struct {
    name: []const u8,
    fields: []Field,
    options: []Option,
    location: SourceLocation,
};

pub const MapField = struct {
    name: []const u8,
    number: i32,
    key_type: ScalarType,   // only int/string types allowed
    value_type: TypeRef,
    options: []FieldOption,
    location: SourceLocation,
};

pub const Enum = struct {
    name: []const u8,
    values: []EnumValue,
    options: []Option,
    allow_alias: bool,
    reserved_ranges: []ReservedRange,
    reserved_names: [][]const u8,
    location: SourceLocation,
};

pub const EnumValue = struct {
    name: []const u8,
    number: i32,
    options: []FieldOption,
    location: SourceLocation,
};

pub const Service = struct {
    name: []const u8,
    methods: []Method,
    options: []Option,
    location: SourceLocation,
};

pub const Method = struct {
    name: []const u8,
    input_type: []const u8,     // unresolved type reference
    output_type: []const u8,    // unresolved type reference
    client_streaming: bool,
    server_streaming: bool,
    options: []Option,
    location: SourceLocation,
};

pub const Option = struct {
    name: OptionName,
    value: Constant,
    location: SourceLocation,
};

pub const OptionName = struct {
    parts: []Part,

    pub const Part = struct {
        name: []const u8,
        is_extension: bool,     // true if wrapped in ()
    };
};

pub const FieldOption = struct {
    name: OptionName,
    value: Constant,
};

pub const Constant = union(enum) {
    identifier: []const u8,
    integer: i64,
    unsigned_integer: u64,
    float_value: f64,
    string_value: []const u8,
    bool_value: bool,
    aggregate: []const u8,  // message literal as raw text (for custom options)
};

pub const ReservedRange = struct {
    start: i32,     // inclusive
    end: i32,       // inclusive (max = 536870911)
};

pub const ExtensionRange = struct {
    start: i32,
    end: i32,
    options: []FieldOption,
};

pub const Extend = struct {
    type_name: []const u8,  // message being extended
    fields: []Field,
    groups: []Group,
    location: SourceLocation,
};

pub const Group = struct {
    name: []const u8,
    number: i32,
    label: FieldLabel,
    fields: []Field,
    nested_messages: []Message,
    nested_enums: []Enum,
    location: SourceLocation,
};
```

## Linker (`src/proto/linker.zig`)

The linker takes multiple parsed ASTs (one per `.proto` file) and produces a
fully resolved descriptor set. This is the most complex phase.

### Responsibilities

1. **Import resolution**: Load imported files, handle `import public`
   transitivity.
2. **Name resolution**: Convert relative type references to fully-qualified
   names. Walk up the enclosing scope chain to find matches.
3. **Validation**:
   - Field numbers unique within each message
   - Field numbers not in reserved ranges
   - Field names not in reserved names
   - Required fields not in oneofs
   - Map key types are valid (integral or string only)
   - Proto3 first enum value is 0
   - Extension field numbers within declared ranges
   - No circular message dependencies (for required fields)
4. **Type classification**: Determine whether each named type reference is a
   message or an enum.

### Name Resolution Algorithm

Type references are resolved by walking up the scope chain:

```
For reference "Foo" in scope ".package.Outer.Inner":
  1. Try ".package.Outer.Inner.Foo"
  2. Try ".package.Outer.Foo"
  3. Try ".package.Foo"
  4. Try ".Foo"

For reference ".absolute.Foo":
  1. Try ".absolute.Foo" (absolute, no walking)
```

A leading dot means the reference is fully qualified.

### Linker Interface

```zig
pub const Linker = struct {
    allocator: std.mem.Allocator,
    diagnostics: *DiagnosticList,
    /// Callback to load an imported file by path.
    file_loader: *const fn (path: []const u8) ![]const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        diagnostics: *DiagnosticList,
        file_loader: *const fn (path: []const u8) ![]const u8,
    ) Linker

    /// Link a set of parsed files into a resolved descriptor set.
    pub fn link(self: *Linker, files: []const ast.File) !ResolvedFileSet
};

pub const ResolvedFileSet = struct {
    files: []ResolvedFile,

    pub const ResolvedFile = struct {
        source: ast.File,
        /// All type references resolved to fully-qualified names.
        /// Messages and enums indexed by fully-qualified name.
        type_registry: std.StringHashMap(TypeInfo),
    };

    pub const TypeInfo = union(enum) {
        message: *const ast.Message,
        @"enum": *const ast.Enum,
    };
};
```

### Import Loading

The linker uses a callback (`file_loader`) to load imported `.proto` files.
This allows different strategies:

- **Build step**: load from the filesystem using import search paths
- **Testing**: load from in-memory strings
- **Protoc plugin mode**: files come from `CodeGeneratorRequest.proto_file`

Files are loaded in dependency order (topological sort). Circular imports are
detected and reported as errors.

## Error Reporting

All phases produce `Diagnostic` values with source locations. The caller
collects them and can format them for display:

```
proto/messages.proto:42:5: error: field number 3 is already used by field "name"
proto/messages.proto:15:3: error: unresolved type "UnknownMessage"
proto/services.proto:8:24: error: service method input type "Foo" is not a message
```

Errors do not abort parsing immediately — the parser recovers and reports
multiple errors per file where possible (skip to next semicolon or closing
brace on error).
