# protobuf

Pure-Zig Protocol Buffers. Compile `.proto` files to Zig structs at build time
with no dependency on `protoc` or any C library.

- Proto2 and proto3 wire formats
- Build-time code generation via `build.zig` step
- Transport-agnostic RPC stub generation
- 271 tests, ~11k lines, zero external dependencies

## Quick start

Add the dependency to your `build.zig.zon`:

```sh
zig fetch --save git+https://codeberg.org/mattnite/protobuf
```

In your `build.zig`:

```zig
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) void {
    const proto_dep = b.dependency("protobuf", .{});
    const proto_mod = protobuf.generate(b, proto_dep, .{
        .proto_sources = b.path("proto/"),
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
    b.installArtifact(exe);
}
```

Then use the generated types in your code:

```zig
const proto = @import("proto");
const Person = proto.@"addressbook".Person;

const person = Person{
    .name = "Alice",
    .id = 123,
};

// Serialize
var buf: [256]u8 = undefined;
var writer = std.Io.Writer.fixed(&buf);
try person.encode(&writer);
const bytes = buf[0..writer.pos];

// Deserialize
const decoded = try Person.decode(allocator, bytes);
defer decoded.deinit(allocator);
```

## What gets generated

Given a `.proto` file:

```protobuf
syntax = "proto3";
package example;

message SearchRequest {
    string query = 1;
    int32 page_number = 2;
    int32 results_per_page = 3;
}
```

The code generator produces a Zig struct with `encode`, `decode`, `calc_size`,
and `deinit` methods:

```zig
pub const SearchRequest = struct {
    query: []const u8 = "",
    page_number: i32 = 0,
    results_per_page: i32 = 0,
    _unknown_fields: []const u8 = "",

    pub fn encode(self: @This(), writer: *std.Io.Writer) !void { ... }
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !SearchRequest { ... }
    pub fn calc_size(self: @This()) usize { ... }
    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void { ... }
};
```

## Field type mapping

| Proto type | Zig type |
|---|---|
| `double` / `float` | `f64` / `f32` |
| `int32` / `sint32` / `sfixed32` | `i32` |
| `int64` / `sint64` / `sfixed64` | `i64` |
| `uint32` / `fixed32` | `u32` |
| `uint64` / `fixed64` | `u64` |
| `bool` | `bool` |
| `string` / `bytes` | `[]const u8` |
| `repeated T` | `[]const T` |
| `map<K, V>` | `std.StringArrayHashMapUnmanaged(V)` or `std.AutoArrayHashMapUnmanaged(K, V)` |
| `oneof` | `?union(enum) { ... }` |
| message field | `?MessageType` |

Proto2 optional fields are `?T` (nullable). Proto3 implicit-presence scalars
use zero defaults and are omitted from the wire when equal to the default.

## RPC stubs

Service definitions generate transport-agnostic interfaces using the standard
Zig vtable pattern (`ptr: *anyopaque` + `vtable: *const VTable`):

```protobuf
service RouteGuide {
    rpc GetFeature(Point) returns (Feature);
    rpc ListFeatures(Rectangle) returns (stream Feature);
    rpc RecordRoute(stream Point) returns (RouteSummary);
    rpc RouteChat(stream RouteNote) returns (stream RouteNote);
}
```

Generates a `RouteGuide` struct containing:

- **`service_descriptor`** -- method metadata (names, paths, streaming flags)
- **`Server`** -- vtable interface that you implement to handle RPCs
- **`Client`** -- stub that wraps a `Channel` transport and provides typed methods

All four streaming modes are supported: unary, server-streaming,
client-streaming, and bidirectional. The actual transport (gRPC, Connect,
in-process mock, etc.) is a separate concern that implements the `Channel`
interface.

## Import paths

If your protos import from other directories, pass additional search paths:

```zig
const proto_mod = protobuf.generate(b, proto_dep, .{
    .proto_sources = b.path("proto/"),
    .import_paths = &.{
        b.path("third_party/"),
    },
});
```

## Project structure

```
src/
  protobuf.zig         Root module
  encoding.zig         Wire format primitives (varint, zigzag, tags)
  message.zig          Schema-agnostic message reader/writer
  rpc.zig              Shared RPC types (StatusCode, streams, Channel)
  GenerateStep.zig     build.zig integration step
  proto/
    lexer.zig          .proto tokenizer
    parser.zig         Recursive descent parser
    ast.zig            AST node definitions
    linker.zig         Type resolution and validation
  codegen/
    emitter.zig        Zig source text emitter
    messages.zig       Message struct generation
    enums.zig          Enum generation
    services.zig       RPC stub generation
```

## Requirements

Zig 0.15.2 or later.

## Running tests

```sh
zig build test
```

## License

BSD-3-Clause
