# Architecture

## Package Structure

```
protobuf/
├── build.zig              # Package build definition + GenerateStep
├── build.zig.zon          # Package manifest
├── docs/                  # Design documentation (this directory)
├── src/
│   ├── protobuf.zig       # Root module, public API re-exports
│   ├── encoding.zig       # Wire format primitives (Phase 1)
│   ├── message.zig        # Schema-agnostic message codec (Phase 2)
│   ├── rpc.zig            # Shared RPC types (Phase 6)
│   ├── well_known.zig     # Well-known type definitions (Phase 7)
│   ├── proto/             # .proto file processing (Phase 3)
│   │   ├── lexer.zig      # Tokenizer
│   │   ├── parser.zig     # Recursive descent parser
│   │   ├── ast.zig        # AST node definitions
│   │   └── linker.zig     # Type resolution and validation
│   ├── codegen/           # Code generation (Phase 4 + 6)
│   │   ├── emitter.zig    # Zig source text emitter
│   │   ├── messages.zig   # Message struct generation
│   │   ├── enums.zig      # Enum generation
│   │   └── services.zig   # RPC stub generation
│   └── well_known_protos/ # Bundled .proto files
│       ├── any.proto
│       ├── duration.proto
│       ├── empty.proto
│       ├── field_mask.proto
│       ├── struct.proto
│       ├── timestamp.proto
│       └── wrappers.proto
└── test/
    ├── encoding_test.zig
    ├── message_test.zig
    ├── lexer_test.zig
    ├── parser_test.zig
    ├── codegen_test.zig
    └── test_protos/       # .proto files for testing
```

## Layer Diagram

```
┌─────────────────────────────────────────────────────┐
│                   User Application                   │
├─────────────────────────────────────────────────────┤
│              Generated Zig Code (.zig)               │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────┐ │
│   │ Message types │  │  Enum types  │  │RPC stubs │ │
│   │  (structs)   │  │   (enums)    │  │(vtables) │ │
│   └──────┬───────┘  └──────┬───────┘  └────┬─────┘ │
├──────────┼─────────────────┼────────────────┼───────┤
│          ▼                 ▼                ▼       │
│  ┌─────────────────────────────────────────────┐    │
│  │          protobuf runtime library            │    │
│  │  ┌────────────┐  ┌──────────┐  ┌─────────┐ │    │
│  │  │  encoding   │  │ message  │  │  rpc    │ │    │
│  │  │ (primitives)│  │ (codec)  │  │ (types) │ │    │
│  │  └────────────┘  └──────────┘  └─────────┘ │    │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘

Build time:
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ .proto files │───▶│  proto/      │───▶│  codegen/    │───▶ .zig files
│              │    │  (parser)    │    │  (emitter)   │
└──────────────┘    └──────────────┘    └──────────────┘
```

## Design Principles

### 1. Zero External Dependencies

The entire package depends only on the Zig standard library. The `.proto`
parser is written from scratch in Zig — no dependency on `protoc` or any C
library.

### 2. Build-Time Code Generation

Code generation happens as a `build.zig` step, not at runtime. The generated
Zig code is cached by the build system and only regenerated when `.proto` files
change. This means:

- No runtime parsing of `.proto` files
- No runtime reflection overhead
- Generated code is inspectable and debuggable
- Build errors for schema problems, not runtime errors

### 3. Allocator-Explicit

Every function that allocates memory takes an `std.mem.Allocator` parameter.
No global allocators, no hidden allocations. Generated message types have a
`deinit` method that frees all owned memory.

Wire format primitives (`encoding.zig`) are allocation-free — they operate on
caller-provided buffers or writers.

### 4. Streaming I/O

Serialization writes to any `std.io.Writer`. Deserialization reads from any
`std.io.Reader` or from a byte slice. This supports:

- Writing directly to a socket
- Reading from a memory-mapped file
- Buffered I/O via `std.io.bufferedWriter`
- Composing with compression or encryption layers

### 5. Transport-Agnostic RPC

Generated RPC stubs define **interfaces** (vtable pattern), not
implementations. The stubs specify the method signatures, message types, and
metadata. The actual transport (HTTP/2, Unix socket, in-process, test mock) is
plugged in separately.

This means this package does NOT include a gRPC implementation. It generates
the stubs that a gRPC (or Connect, or Twirp, or custom) transport would use.

### 6. Proto2 and Proto3 Parity

Both protocol versions are first-class. The wire format layer handles all wire
types including deprecated groups. The parser understands both syntaxes. The
code generator emits different Zig types based on the proto version:

| Concept              | Proto2 Zig Type | Proto3 Zig Type          |
|----------------------|-----------------|--------------------------|
| Singular scalar      | `?T`            | `T` (zero-default)       |
| Optional scalar      | `?T`            | `?T`                     |
| Required scalar      | `T`             | N/A                      |
| Message field        | `?*M`           | `?*M`                    |
| Repeated             | `[]T`           | `[]T`                    |
| Map                  | `AutoArrayHashMap` | `AutoArrayHashMap`    |
| Oneof                | `union(enum)`   | `union(enum)`            |
| Enum (unknown value) | unknown field   | preserved as integer     |

## Separation of Concerns

### Runtime vs. Build-Time

**Runtime** (`src/encoding.zig`, `src/message.zig`, `src/rpc.zig`):
- Wire format encode/decode
- Schema-agnostic message iteration
- RPC type definitions (StatusCode, stream interfaces)
- These are linked into the user's application

**Build-Time** (`src/proto/`, `src/codegen/`, `build.zig`):
- `.proto` parsing and validation
- Zig source code generation
- These run during `zig build` only

### Generated Code Dependencies

Generated message types depend on `src/encoding.zig` for serialization
primitives and `std.mem.Allocator` for memory management. Generated RPC stubs
additionally depend on `src/rpc.zig` for shared types (`StatusCode`,
`ServerStream`, `ClientStream`, etc.).

The generated code does NOT import the parser or code generator — those are
build-time only.

## Error Handling Strategy

### Wire Format Errors
- Malformed varint (too many bytes, or truncated)
- Unexpected end of input
- Invalid wire type
- Negative length prefix
- UTF-8 validation failure for string fields

These are returned as Zig errors from decode functions. The error set is
defined in `encoding.zig`.

### Schema Validation Errors
- Missing required field (proto2)
- Unknown enum value handling (proto3: preserve; proto2: unknown field)
- Field number out of range
- Duplicate field (last wins for scalars, merge for messages)

### `.proto` Parse Errors
- Syntax errors with source location (file, line, column)
- Unresolved type references
- Duplicate field numbers
- Reserved field violations
- Invalid field number ranges

Parse errors are collected with source locations and reported as diagnostics.

## Thread Safety

All types are designed to be thread-safe when used correctly:

- Encoding/decoding functions are stateless and reentrant
- Generated message types own their data (no shared mutable state)
- RPC vtable pointers are `*const` — the vtable itself is immutable
- The code generator is single-threaded (runs in build step)

Concurrent access to the same message instance requires external
synchronization, as with any mutable data structure in Zig.
