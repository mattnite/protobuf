# Code Generation

Design for transforming resolved `.proto` descriptors into Zig source files.
Covers message structs, enum types, and the build system integration.

## Overview

```
Resolved AST ──▶ Zig Source Emitter ──▶ .zig files (in build cache)
                                              │
                                              ▼
                                    User code imports generated module
```

Code generation runs at build time as a `build.zig` step. The generated `.zig`
files are placed in the build cache and exposed as an importable module.

## Generated File Layout

For a `.proto` file like:

```protobuf
syntax = "proto3";
package myapp.v1;

message SearchRequest { ... }
message SearchResponse { ... }
enum Status { ... }
service SearchService { ... }
```

The generator produces:

```
(build cache)/
  myapp/
    v1.zig        # all types from myapp.v1 package
```

Package mapping: protobuf package `a.b.c` → Zig path `a/b/c.zig`. If no
package, the proto file name (sans extension) is used.

The generated file contains:
- All message structs
- All enum types
- RPC stub types (see `rpc.md`)
- A namespace struct wrapping everything

## Message Struct Generation

### Example

Given:
```protobuf
syntax = "proto3";
package example;

message Person {
    string name = 1;
    int32 id = 2;
    optional string email = 3;
    repeated string phones = 4;

    enum PhoneType {
        MOBILE = 0;
        HOME = 1;
        WORK = 2;
    }

    message PhoneNumber {
        string number = 1;
        PhoneType type = 2;
    }

    repeated PhoneNumber phone_numbers = 5;
    map<string, string> attributes = 6;
}
```

Generated Zig:

```zig
const std = @import("std");
const protobuf = @import("protobuf");
const encoding = protobuf.encoding;

pub const Person = struct {
    /// Proto field 1, string
    name: []const u8 = "",
    /// Proto field 2, int32
    id: i32 = 0,
    /// Proto field 3, optional string (explicit presence)
    email: ?[]const u8 = null,
    /// Proto field 4, repeated string
    phones: []const []const u8 = &.{},
    /// Proto field 5, repeated PhoneNumber
    phone_numbers: []const PhoneNumber = &.{},
    /// Proto field 6, map<string, string>
    attributes: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    _unknown_fields: []const u8 = "",

    pub const PhoneType = enum(i32) {
        MOBILE = 0,
        HOME = 1,
        WORK = 2,
        _,  // allow unknown values (proto3)
    };

    pub const PhoneNumber = struct {
        number: []const u8 = "",
        type: PhoneType = .MOBILE,
        _unknown_fields: []const u8 = "",

        pub fn encode(self: PhoneNumber, writer: anytype) !void { ... }
        pub fn decode(allocator: std.mem.Allocator, reader: anytype) !PhoneNumber { ... }
        pub fn deinit(self: *PhoneNumber, allocator: std.mem.Allocator) void { ... }
        pub fn calc_size(self: PhoneNumber) usize { ... }
    };

    pub fn encode(self: Person, writer: anytype) !void { ... }
    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !Person { ... }
    pub fn deinit(self: *Person, allocator: std.mem.Allocator) void { ... }
    pub fn calc_size(self: Person) usize { ... }
};
```

### Field Type Mapping

| Proto Type      | Proto2 Zig Type               | Proto3 Zig Type (implicit)    | Proto3 Zig Type (optional)    |
|----------------|-------------------------------|-------------------------------|-------------------------------|
| double         | `?f64`                        | `f64 = 0`                    | `?f64 = null`                 |
| float          | `?f32`                        | `f32 = 0`                    | `?f32 = null`                 |
| int32          | `?i32`                        | `i32 = 0`                    | `?i32 = null`                 |
| int64          | `?i64`                        | `i64 = 0`                    | `?i64 = null`                 |
| uint32         | `?u32`                        | `u32 = 0`                    | `?u32 = null`                 |
| uint64         | `?u64`                        | `u64 = 0`                    | `?u64 = null`                 |
| sint32         | `?i32`                        | `i32 = 0`                    | `?i32 = null`                 |
| sint64         | `?i64`                        | `i64 = 0`                    | `?i64 = null`                 |
| fixed32        | `?u32`                        | `u32 = 0`                    | `?u32 = null`                 |
| fixed64        | `?u64`                        | `u64 = 0`                    | `?u64 = null`                 |
| sfixed32       | `?i32`                        | `i32 = 0`                    | `?i32 = null`                 |
| sfixed64       | `?i64`                        | `i64 = 0`                    | `?i64 = null`                 |
| bool           | `?bool`                       | `bool = false`               | `?bool = null`                |
| string         | `?[]const u8`                 | `[]const u8 = ""`            | `?[]const u8 = null`          |
| bytes          | `?[]const u8`                 | `[]const u8 = ""`            | `?[]const u8 = null`          |
| enum E         | `?E`                          | `E = first_value`            | `?E = null`                   |
| message M      | `?M`                          | `?M = null`                  | `?M = null`                   |
| repeated T     | `[]const T = &.{}`            | `[]const T = &.{}`           | N/A                           |
| map<K, V>      | (see below)                   | (see below)                  | N/A                           |

Proto2 `required` fields use `T` (non-nullable). Decode fails if missing.

### Map Fields

Maps use `std.StringArrayHashMapUnmanaged(V)` for string keys and
`std.AutoArrayHashMapUnmanaged(K, V)` for integer keys. Unmanaged variants
are used because the generated `deinit` manages memory explicitly.

### Oneof Fields

```protobuf
message Sample {
    oneof test {
        string name = 1;
        int32 id = 2;
        SubMessage sub = 3;
    }
}
```

Generates a tagged union:

```zig
pub const Sample = struct {
    test: ?Test = null,

    pub const Test = union(enum) {
        name: []const u8,
        id: i32,
        sub: SubMessage,
    };

    // ...
};
```

### Generated Method Signatures

```zig
/// Serialize this message to the writer in protobuf binary format.
pub fn encode(self: @This(), writer: anytype) !void

/// Deserialize a message from the reader. Allocates memory for
/// variable-length fields (strings, bytes, repeated, maps, nested messages).
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This()

/// Free all memory allocated during decode.
pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void

/// Compute the serialized byte size without writing.
pub fn calc_size(self: @This()) usize
```

### Encode Logic

Fields are serialized in field number order. The encode method:

1. For each field (in number order):
   - **Proto3 implicit**: skip if value == default (zero/empty/false)
   - **Proto3 optional**: skip if `null`
   - **Proto2 optional**: skip if `null` (not set)
   - **Proto2 required**: always write (no skip check)
   - **Repeated**: skip if slice is empty
   - **Map**: skip if map is empty
   - **Oneof**: write the active variant's field
2. Write unknown fields verbatim at the end.

For nested messages, the two-pass approach:
```
size = sub_message.calc_size();
write_tag(field_number, .len);
write_varint(size);
sub_message.encode(writer);
```

### Decode Logic

The decode method uses a field iteration loop:

```
while (has more data) {
    tag = read_tag();
    switch (tag.field_number) {
        1 => self.name = decode_string(...),
        2 => self.id = decode_varint_as_i32(...),
        // ...
        else => store_unknown_field(tag, ...),
    }
}
```

Merge semantics:
- Scalar: overwrite with last value
- Message: merge (decode into existing, or decode new and merge)
- Repeated: append to slice
- Oneof: overwrite (clear previous variant)
- Map: insert/overwrite per key

### Naming Conventions

- Proto field names → Zig field names: already snake_case in proto convention,
  used as-is. If a proto field name conflicts with a Zig keyword, append `_`
  suffix (e.g., `type` → `@"type"`).
- Proto message names → Zig type names: PascalCase, used as-is.
- Proto enum names → Zig enum type names: PascalCase, used as-is.
- Proto enum values → Zig enum fields: used as-is (typically SCREAMING_SNAKE).
- Proto nested types → Zig nested `pub const` types.
- Proto package → Zig module path (dots become directory separators).

## Enum Generation

### Proto3

```protobuf
enum Status {
    UNKNOWN = 0;
    ACTIVE = 1;
    INACTIVE = 2;
}
```

```zig
pub const Status = enum(i32) {
    UNKNOWN = 0,
    ACTIVE = 1,
    INACTIVE = 2,
    _,  // non-exhaustive: allows unknown values from the wire
};
```

The `_` makes the enum non-exhaustive, which is required for proto3 since
unknown enum values must be preserved as integers.

### Proto2

```protobuf
enum Color {
    RED = 0;
    GREEN = 1;
    BLUE = 2;
}
```

```zig
pub const Color = enum(i32) {
    RED = 0,
    GREEN = 1,
    BLUE = 2,
    // No underscore — proto2 enums store unknown values in unknown fields
};
```

Proto2 enums are exhaustive. Unknown values during decode are stored in the
unknown fields section.

### Enum Aliases

```protobuf
enum Foo {
    option allow_alias = true;
    BAR = 0;
    BAZ = 0;  // alias for BAR
}
```

```zig
pub const Foo = enum(i32) {
    BAR = 0,
    // BAZ is an alias for BAR (same numeric value)
    pub const BAZ: Foo = .BAR;
    _,
};
```

Zig enums don't allow duplicate values, so aliases become `pub const` declarations.

## Emitter (`src/codegen/emitter.zig`)

The emitter is a Zig source code writer. It handles indentation, imports, and
formatting.

```zig
pub const Emitter = struct {
    output: std.ArrayList(u8),
    indent_level: u32,

    pub fn init(allocator: std.mem.Allocator) Emitter
    pub fn emit_file(self: *Emitter, file: ResolvedFile) !void
    pub fn get_output(self: *Emitter) []const u8
};
```

The emitter produces syntactically valid Zig source that passes `zig fmt`
without changes.

## Build Step (`build.zig`)

### GenerateStep

```zig
pub const GenerateStep = struct {
    step: std.Build.Step,
    proto_files: []const std.Build.LazyPath,
    import_paths: []const std.Build.LazyPath,
    output_module: *std.Build.Module,

    pub fn create(
        b: *std.Build,
        options: struct {
            proto_files: []const std.Build.LazyPath,
            import_paths: []const std.Build.LazyPath = &.{},
        },
    ) *GenerateStep
};
```

### Build Graph Integration

The step:
1. Reads all `.proto` files (declared as step dependencies for caching)
2. Lexes and parses each file
3. Links all files together (resolving imports and types)
4. Generates `.zig` files into `b.cache_root`
5. Creates an `std.Build.Module` that other steps can depend on

The module includes both the generated code and the protobuf runtime library
(`encoding.zig`, `message.zig`, `rpc.zig`).

### Caching

The build step uses Zig's built-in caching. The step hash includes:
- All `.proto` file contents
- The protobuf package version
- Generator options

If the hash matches a previous run, the cached output is reused.
