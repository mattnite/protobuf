# Zig Protobuf — Roadmap

A pure-Zig Protocol Buffers library supporting proto2 and proto3 wire formats,
build-time code generation from `.proto` files, and RPC stub generation.

## Phase 1: Wire Format Primitives

The foundation layer. Pure encode/decode functions with no allocations for the
fixed-size primitives, allocator-explicit for variable-length data.

- Varint encoding/decoding (unsigned LEB128, max 10 bytes)
- ZigZag encoding/decoding for sint32/sint64
- Fixed-width encoding/decoding (32-bit and 64-bit little-endian)
- Float/double bit-casting through u32/u64
- Field tag encoding/decoding (`field_number << 3 | wire_type`)
- Length-delimited framing (varint length prefix + payload)

**Output**: `src/encoding.zig` — stateless functions, no allocator needed for
primitives. Fully tested against known test vectors.

## Phase 2: Low-Level Message Codec

A schema-agnostic message reader/writer that operates on raw wire data. This
layer doesn't know about `.proto` schemas — it just iterates field tags and
values.

- `FieldIterator` — iterate over tag/value pairs in a serialized message
- Wire type dispatch (varint, i64, len, sgroup, egroup, i32)
- Unknown field skipping (including recursive group skipping)
- Unknown field preservation for round-tripping
- `MessageWriter` — append fields by number and wire type
- Packed repeated field reading/writing
- Nested message reading (sub-slice by length prefix)
- Nested message writing (length-prefix backpatching or two-pass)

**Output**: `src/message.zig` — schema-agnostic codec. Foundation for both
hand-written and generated message types.

## Phase 3: `.proto` Lexer and Parser

A standalone `.proto` file parser in pure Zig (no protoc dependency). Produces
an AST that the code generator consumes.

### 3a: Lexer
- Tokenize into: identifier, integer, float, string, symbol, comment
- Handle string escapes (hex, octal, unicode)
- Track source locations (line, column) for error reporting
- Context-aware keyword recognition (protobuf keywords are valid identifiers
  in many positions)

### 3b: Parser
- `syntax`/`edition` declaration
- `package`, `import` (regular, public, weak)
- `option` (scalar values and aggregate/message-literal values)
- `message` (fields, nested messages, nested enums, oneofs, maps, reserved,
  extensions, groups)
- `enum` (values, `allow_alias`, reserved)
- `service` and `rpc` (unary, server/client/bidi streaming)
- `extend` (proto2 extensions)
- Field labels: `required`/`optional`/`repeated` (proto2),
  `optional`/`repeated`/implicit (proto3)
- Field options: `packed`, `deprecated`, `default`, `json_name`, custom options

### 3c: AST
- Typed node tree representing the full `.proto` file
- Preserves source locations for diagnostics
- Preserves comments (for potential doc generation)

### 3d: Linker
- Resolve imports (transitive for `import public`)
- Resolve all type references (relative and fully-qualified names)
- Validate field number uniqueness and ranges
- Validate enum constraints (proto3 first value = 0)
- Validate reserved field conflicts
- Produce a fully-resolved descriptor suitable for code generation

**Output**: `src/proto/lexer.zig`, `src/proto/parser.zig`, `src/proto/ast.zig`,
`src/proto/linker.zig`

## Phase 4: Code Generator

Transform resolved `.proto` descriptors into Zig source code. Outputs `.zig`
files containing struct definitions with serialize/deserialize methods.

### Generated for each message:
- Zig struct with typed fields
- `encode(self, writer) !void` — serialize to any `std.io.Writer`
- `decode(allocator, reader) !Self` — deserialize from any `std.io.Reader`
- `deinit(self, allocator) void` — free allocated memory
- `calc_size(self) usize` — compute serialized size without writing

### Field type mapping:
| Proto Type     | Zig Type              |
|----------------|-----------------------|
| double         | f64                   |
| float          | f32                   |
| int32/sint32   | i32                   |
| int64/sint64   | i64                   |
| uint32/fixed32 | u32                   |
| uint64/fixed64 | u64                   |
| bool           | bool                  |
| string         | []const u8            |
| bytes          | []const u8            |
| enum           | generated enum type   |
| message        | ?*GeneratedType       |
| repeated T     | []T                   |
| map<K, V>      | std.AutoArrayHashMap(K, V) |
| oneof          | tagged union          |

### Proto2-specific:
- Optional fields → `?T` (nullable)
- Required fields → `T` (non-nullable, validated on decode)
- Default values → `const default_<field> = ...;`
- Extension fields → stored as unknown fields or typed via registry

### Proto3-specific:
- Implicit presence scalars → `T` (zero-default, not serialized when zero)
- Explicit presence (`optional` keyword) → `?T` (nullable)
- Unknown enum values → stored as the integer value

**Output**: `src/codegen.zig` — takes resolved AST, emits Zig source text.

## Phase 5: `build.zig` Integration

A build step that takes `.proto` files as input and produces generated `.zig`
files as output, integrated into the Zig build graph.

- `protobuf.GenerateStep` — custom build step
- Input: list of `.proto` file paths + import search paths
- Output: generated `.zig` files in the build cache
- Exposes generated module as a dependency for downstream steps
- Caching: only regenerate when `.proto` files change
- Well-known types bundled with the package (timestamp, duration, any,
  wrappers, struct, empty, field_mask)

### Usage example:
```zig
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) void {
    const proto_mod = protobuf.generate(b, .{
        .proto_files = &.{
            "proto/messages.proto",
            "proto/services.proto",
        },
        .import_paths = &.{"proto/"},
    });

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "proto", .module = proto_mod },
            },
        }),
    });
}
```

**Output**: additions to `build.zig`, `src/build_step.zig`

## Phase 6: RPC Stub Generation

Generate Zig interfaces for protobuf `service` definitions. Transport-agnostic
— the generated code defines interfaces that any transport (gRPC/HTTP2,
Connect, custom) can implement.

### Generated per service:
- Server vtable interface (user implements this)
- Client struct with typed method wrappers
- Method descriptors (name, path, streaming bools) as comptime constants
- Service registration helper

### Streaming types (transport-provided):
- `ServerStream(T)` — vtable interface for reading incoming message streams
- `ClientStream(T)` — vtable interface for writing outgoing message streams

### Four method shapes:
| Type                | Server Signature                                     |
|---------------------|------------------------------------------------------|
| Unary               | `fn(ctx, Request) Error!Response`                    |
| Server streaming    | `fn(ctx, Request, ClientStream(Response)) Error!void`|
| Client streaming    | `fn(ctx, ServerStream(Request)) Error!Response`      |
| Bidi streaming      | `fn(ctx, ServerStream(Req), ClientStream(Resp)) Error!void` |

### Status/error types:
- `StatusCode` enum (17 gRPC-compatible codes)
- `RpcError` error set for transport failures
- `ServerContext` with metadata, deadline, peer info

**Output**: additions to `src/codegen.zig` for service generation,
`src/rpc.zig` for shared RPC types.

## Phase 7: Well-Known Types and Polish

- Bundle well-known type `.proto` files and pre-generated Zig code
- JSON serialization (protobuf canonical JSON mapping)
- Text format serialization (for debugging)
- Protobuf reflection / dynamic messages
- `protoc` plugin mode (read `CodeGeneratorRequest` from stdin, write
  `CodeGeneratorResponse` to stdout) as an alternative to the build step
- Performance benchmarks
- Fuzz testing against reference implementation outputs

---

## Non-Goals (for now)

- gRPC transport implementation (this package generates stubs; transport is
  a separate concern)
- Protobuf editions support (proto2 + proto3 first)
- Arena allocation (standard allocator-based first)

## Dependencies

- Zig standard library only (no external dependencies)
- Minimum Zig version: 0.15.2

## Conventions

- All public functions use `snake_case`
- Allocator passed explicitly where allocation is needed
- Errors returned via Zig error unions (not out-parameters)
- No global state
