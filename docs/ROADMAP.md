# Zig Protobuf — Roadmap

A pure-Zig Protocol Buffers library supporting proto2 and proto3 wire formats,
build-time code generation from `.proto` files, and RPC stub generation.

---

## Completed Phases

### Phase 1: Wire Format Primitives — DONE

The foundation layer. Pure encode/decode functions with no allocations for the
fixed-size primitives, allocator-explicit for variable-length data.

- Varint encoding/decoding (unsigned LEB128, max 10 bytes)
- ZigZag encoding/decoding for sint32/sint64
- Fixed-width encoding/decoding (32-bit and 64-bit little-endian)
- Float/double bit-casting through u32/u64
- Field tag encoding/decoding (`field_number << 3 | wire_type`)
- Length-delimited framing (varint length prefix + payload)

**Output**: `src/encoding.zig`

### Phase 2: Low-Level Message Codec — DONE

A schema-agnostic message reader/writer that operates on raw wire data.

- `FieldIterator` — iterate over tag/value pairs in a serialized message
- Wire type dispatch (varint, i64, len, sgroup, egroup, i32)
- Unknown field skipping (including recursive group skipping)
- Unknown field preservation for round-tripping
- `MessageWriter` — append fields by number and wire type
- Packed repeated field reading/writing
- Nested message reading (sub-slice by length prefix)
- Nested message writing (two-pass: calc_size then write)

**Output**: `src/message.zig`

### Phase 3: `.proto` Lexer, Parser, AST, and Linker — DONE

A standalone `.proto` file parser in pure Zig (no protoc dependency).

- Full proto2 and proto3 syntax support
- Lexer with string escapes (hex, octal, unicode), source location tracking
- Parser: `syntax`, `package`, `import`, `option`, `message`, `enum`,
  `service`, `rpc`, `extend`, `group`, `oneof`, `map`, `reserved`,
  `extensions`, field options
- Typed AST with preserved source locations and comments
- Linker: import resolution, type resolution (relative + fully-qualified),
  field number validation, enum constraints, reserved field conflicts

**Output**: `src/proto/lexer.zig`, `src/proto/parser.zig`, `src/proto/ast.zig`,
`src/proto/linker.zig`

### Phase 4: Code Generator — DONE

Transform resolved `.proto` descriptors into Zig source code.

Generated for each message:
- Zig struct with typed fields
- `encode(self, writer) !void` — serialize to `std.Io.Writer`
- `decode(allocator, bytes) !Self` — deserialize from byte slice
- `calc_size(self) usize` — compute serialized size without writing
- `deinit(self, allocator) void` — free allocated memory
- `to_json(self, writer) !void` — proto-canonical JSON encoding

Field type mapping:
| Proto Type     | Zig Type                                  |
|----------------|-------------------------------------------|
| double/float   | f64/f32                                   |
| int32/sint32   | i32                                       |
| int64/sint64   | i64                                       |
| uint32/fixed32 | u32                                       |
| uint64/fixed64 | u64                                       |
| bool           | bool                                      |
| string/bytes   | []const u8                                |
| enum           | generated non-exhaustive enum (proto3) or exhaustive (proto2) |
| message        | ?MessageType (optional/implicit) or MessageType (required) |
| repeated T     | []const T                                 |
| map\<K, V\>    | StringArrayHashMapUnmanaged / AutoArrayHashMapUnmanaged |
| oneof          | ?union(enum)                              |

Proto3: implicit presence (zero-default), explicit `optional` as `?T`.
Proto2: `optional` as `?T`, `required` as non-nullable.

**Output**: `src/codegen/` (emitter, messages, enums, services)

### Phase 5: `build.zig` Integration — DONE

A build step that takes `.proto` files as input and produces generated `.zig`
files, integrated into the Zig build graph.

- `GenerateStep` — custom build step (lex → parse → link → codegen pipeline)
- Content-hash caching (Wyhash) — only regenerate when `.proto` files change
- Root module (`root.zig`) re-exports generated files as `@"name"` constants
- Well-known types bundled and auto-added to search paths
- Public API: `protobuf.generate(b, dep, options) → *Module`

**Output**: `src/GenerateStep.zig`, `build.zig`

### Phase 6: RPC Stub Generation — DONE

Transport-agnostic interfaces for protobuf `service` definitions.

- Server vtable interface (user implements)
- Client struct with typed method wrappers
- Method descriptors as comptime constants
- `SendStream(T)` / `RecvStream(T)` interfaces
- `StatusCode` (17 gRPC-compatible codes), `RpcError`, `Context`
- Four method shapes: unary, server-streaming, client-streaming, bidi

**Output**: `src/codegen/services.zig`, `src/rpc.zig`

### Phase 7: Well-Known Types and JSON Encoding — DONE

- 7 bundled well-known protos: empty, timestamp, duration, any, field_mask,
  wrappers, struct
- `to_json()` method generated on every message
- Proto-canonical JSON mapping: int64/uint64 as strings, bytes as base64,
  NaN/Inf as strings, lowerCamelCase field names with `json_name` support
- Runtime helpers in `src/json.zig`

**Output**: `src/well_known_protos/`, `src/json.zig`

### Compat Test Suite — DONE

Bidirectional Zig/Go validation for 11 proto definitions:

| Proto          | Coverage |
|----------------|----------|
| scalar3        | All 15 scalar types, large field tags, min/max values |
| nested3        | 3-level nested messages |
| enum3          | Singular + repeated enums |
| oneof3         | All variant types (string, int, bytes, message) |
| repeated3      | Scalars, strings, bytes, nested messages |
| map3           | string→string, int→string, string→message |
| optional3      | Explicit optional fields, zero vs absent |
| edge3          | NaN, Infinity, unicode, binary, empty strings |
| scalar2        | Proto2 optional scalars |
| required2      | Proto2 required fields |
| acp            | Complex real-world proto with package + nested enums |

Each proto has: Zig round-trip tests, Go vector generation, Go vector
validation of Zig output, Zig validation of Go output.

---

### Phase 8: JSON Decoding — DONE

Added `from_json()` deserialization to complement the existing `to_json()`.

- Pull-based `JsonScanner` tokenizer over `[]const u8` (auto-skips `:` and `,`)
- Zero-copy strings when no escapes; allocates only for escape sequences
- Helper functions: `skip_value`, `read_string`, `read_bytes`, `read_bool`,
  `read_int32/64`, `read_uint32/64`, `read_float32/64`, `read_enum_int`
- JSON ↔ protobuf coercions: string→int64/uint64, NaN/Infinity strings→float,
  base64→bytes, null→field not present
- Generated `from_json(allocator, json_bytes) !Self` and
  `from_json_scanner(allocator, *scanner) !Self` on every message
- Field matching: both lowerCamelCase and original snake_case names accepted
- Respects `json_name` option
- All field types: scalars, messages, enums, oneofs, maps, repeated
- Unknown JSON fields silently skipped
- Well-known type JSON specializations (Timestamp as RFC 3339, etc.) deferred

**Output**: additions to `src/json.zig`, `src/codegen/messages.zig`, `src/codegen/types.zig`

## Remaining Phases

### Phase 9: Proto2 Completeness

Fill in the proto2 features that are parsed but not generated.

#### 9a: Explicit Default Values
- The parser already captures `[default = value]` on field options
- Codegen must emit these as field initializers instead of zero-defaults
- Affects: scalar fields (all types), enum fields, string/bytes fields
- Example: `optional string name = 1 [default = "unnamed"]` → `name: ?[]const u8 = "unnamed"`
- String defaults need proper escape handling

#### 9b: Extensions
- Proto2 `extend` blocks add fields to messages defined elsewhere
- The parser already captures `extend MessageName { ... }` and
  `extensions 100 to 199;` range declarations
- Codegen must:
  - Generate accessor methods for extension fields
  - Store extension data in the unknown fields buffer (already preserved)
  - Provide typed get/set for known extensions
  - Validate extension field numbers against declared ranges
- Consider: extension registry pattern vs static codegen approach

#### 9c: Groups (Deprecated)
- Proto2 `group` defines a message and a field simultaneously
- Wire format: start-group / end-group markers (wire types 3 and 4)
- The parser already captures group definitions
- The message codec already handles group skipping
- Codegen must:
  - Generate a nested message type for the group
  - Encode/decode using start-group/end-group wire types
- Low priority since groups are deprecated in favor of nested messages

**Output**: additions to `src/codegen/messages.zig`

### Phase 10: Text Format

Protobuf text format for debugging, logging, and configuration files.

#### 10a: Text Format Serialization
- `to_text(self, writer) !void` method on every message
- Human-readable `field_name: value` format with indentation
- Message fields as nested blocks: `sub { field: value }`
- Repeated fields as multiple entries
- Enum values as names (not integers)
- Bytes as escaped strings

#### 10b: Text Format Deserialization
- `from_text(allocator, text) !Self` method
- Tokenizer for text format syntax
- Handle field names (not numbers) for human-authored input
- Error reporting with line/column

**Output**: `src/text_format.zig`, generated methods in codegen

### Phase 11: Reflection and Dynamic Messages

Runtime introspection of protobuf schemas.

#### 11a: Descriptors
- `FileDescriptor`, `MessageDescriptor`, `FieldDescriptor`,
  `EnumDescriptor`, `ServiceDescriptor`
- Generated as comptime constants alongside each message/enum/service
- Provide field names, numbers, types, labels, options at runtime

#### 11b: Dynamic Messages
- `DynamicMessage` type that can hold any message shape
- Create from a `MessageDescriptor`
- Get/set fields by name or number
- Encode/decode without generated types
- Useful for: generic middleware, proxies, debugging tools

**Output**: `src/descriptor.zig`, `src/dynamic.zig`, additions to codegen

### Phase 12: Protoc Plugin Mode

Allow this package to run as a `protoc` plugin, reading
`CodeGeneratorRequest` from stdin and writing `CodeGeneratorResponse`
to stdout.

- Parse `google.protobuf.compiler.CodeGeneratorRequest`
- Convert protoc's `FileDescriptorProto` to our internal AST
- Run existing codegen pipeline
- Emit `CodeGeneratorResponse` with generated `.zig` file contents
- Bundle the plugin as an executable: `protoc-gen-zig`
- Support `--zig_out` flag in protoc invocations

This provides an alternative integration path for projects already using
protoc in their build systems.

**Output**: `src/plugin.zig`, `build.zig` additions for the plugin executable

### Phase 13: Performance and Robustness

#### 13a: Benchmarks
- Encode/decode throughput for various message sizes
- Comparison against known reference numbers
- Memory allocation tracking (bytes allocated per decode)

#### 13b: Fuzz Testing
- Fuzz the wire format decoder with random bytes
- Fuzz the JSON parser with random strings
- Fuzz the `.proto` parser with random input
- Ensure no crashes, only clean error returns

#### 13c: Packed Encoding Optimization
- Currently repeated scalars encode one field per element
- Packed encoding (proto3 default) packs all values into a single
  length-delimited field — smaller on the wire
- Decoder already handles both packed and unpacked

**Output**: `bench/`, fuzz harnesses, codegen improvements

---

### Phase 14: Protobuf Editions

Support for the Editions syntax (Edition 2023+), which replaces the
`proto2`/`proto3` syntax distinction with per-feature flags.

#### 14a: Parser Support
- `edition = "2023";` declaration
- Feature flags on files, messages, fields, enums, oneofs:
  `features.field_presence`, `features.enum_type`,
  `features.repeated_field_encoding`, `features.message_encoding`, etc.
- Feature inheritance: file → message → field (child inherits parent unless
  overridden)
- Feature defaults per edition (Edition 2023 defaults match proto3 behavior)

#### 14b: Feature Resolution
- Resolve effective features for every element after parsing
- Map features to existing codegen behavior:
  - `field_presence = EXPLICIT` → generate `?T` (like proto2 optional)
  - `field_presence = IMPLICIT` → generate `T` with zero default (like proto3)
  - `field_presence = LEGACY_REQUIRED` → generate `T` non-nullable (like proto2 required)
  - `enum_type = OPEN` → non-exhaustive enum (like proto3)
  - `enum_type = CLOSED` → exhaustive enum (like proto2)
  - `repeated_field_encoding = PACKED` → packed wire format
  - `repeated_field_encoding = EXPANDED` → one-per-element wire format
  - `message_encoding = DELIMITED` → length-delimited (normal)
  - `message_encoding = LENGTH_PREFIX` → group encoding (legacy)

#### 14c: Codegen
- Reuse existing proto2/proto3 codegen paths based on resolved features
- Most of the work is in the parser and feature resolution — codegen already
  handles all the underlying behaviors

**Output**: additions to `src/proto/parser.zig`, new `src/proto/features.zig`,
additions to codegen

---

## Non-Goals (for now)

- **gRPC transport implementation** — this package generates stubs; transport
  is a separate concern
- **`protoc` as a build dependency** — the pure-Zig parser eliminates this need
  (protoc plugin mode is an optional alternative, not a requirement)

## Dependencies

- Zig standard library only (no external dependencies)
- Minimum Zig version: 0.15.2
