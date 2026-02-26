# Wire Format

Low-level encoding and decoding of the Protocol Buffers binary wire format.
This document covers the design of `src/encoding.zig` (Phase 1) and
`src/message.zig` (Phase 2).

## Wire Types

Every field on the wire is preceded by a tag encoded as a varint:

```
tag = (field_number << 3) | wire_type
```

| ID | Wire Type         | Size               | Used For                                      |
|----|-------------------|--------------------|-----------------------------------------------|
| 0  | VARINT            | 1-10 bytes         | int32, int64, uint32, uint64, sint32, sint64, bool, enum |
| 1  | I64               | 8 bytes            | fixed64, sfixed64, double                     |
| 2  | LEN               | varint + N bytes   | string, bytes, nested messages, packed repeated |
| 3  | SGROUP            | N/A (delimited)    | group start (proto2, deprecated)              |
| 4  | EGROUP            | 0 bytes            | group end (proto2, deprecated)                |
| 5  | I32               | 4 bytes            | fixed32, sfixed32, float                      |

Wire types 6 and 7 are invalid. Wire types 3/4 are deprecated but must be
handled for backwards compatibility.

## `encoding.zig` — API Design

All functions are stateless. Encode functions write to a `std.io.Writer`.
Decode functions read from a `std.io.Reader` or a byte slice.

### Varint (Unsigned LEB128)

```zig
/// Encode a u64 as a varint. Returns number of bytes written.
pub fn encode_varint(writer: anytype, value: u64) !void

/// Decode a varint into a u64. Returns the decoded value.
/// Error on malformed varint (>10 bytes) or unexpected end of input.
pub fn decode_varint(reader: anytype) !u64

/// Compute the encoded size of a varint without writing.
pub fn varint_size(value: u64) u4
```

Varints use little-endian base-128 encoding. Each byte contributes 7 data bits;
bit 7 is the continuation flag (1 = more bytes follow, 0 = last byte).

Maximum encoded size: 10 bytes (ceil(64 / 7)).

### ZigZag (for sint32/sint64)

Maps signed integers to unsigned so that small magnitudes encode efficiently:

```
 0 -> 0,  -1 -> 1,  1 -> 2,  -2 -> 3,  2 -> 4,  ...
```

```zig
pub fn zigzag_encode(value: i32) u32
pub fn zigzag_decode(value: u32) i32
pub fn zigzag_encode_64(value: i64) u64
pub fn zigzag_decode_64(value: u64) i64
```

Implementation:
```
encode: (n << 1) ^ (n >> 31)     // arithmetic right shift
decode: (n >>> 1) ^ -(n & 1)     // logical right shift
```

### Fixed-Width

```zig
/// Encode a 32-bit value in little-endian.
pub fn encode_fixed32(writer: anytype, value: u32) !void
pub fn decode_fixed32(reader: anytype) !u32

/// Encode a 64-bit value in little-endian.
pub fn encode_fixed64(writer: anytype, value: u64) !void
pub fn decode_fixed64(reader: anytype) !u64
```

Float and double use `@bitCast` through the corresponding unsigned integer:

```zig
pub fn encode_float(writer: anytype, value: f32) !void
pub fn decode_float(reader: anytype) !f32
pub fn encode_double(writer: anytype, value: f64) !void
pub fn decode_double(reader: anytype) !f64
```

### Field Tag

```zig
pub const WireType = enum(u3) {
    varint = 0,
    i64 = 1,
    len = 2,
    sgroup = 3,
    egroup = 4,
    i32 = 5,
    // 6, 7 are invalid
};

pub const Tag = struct {
    field_number: u29,
    wire_type: WireType,
};

pub fn encode_tag(writer: anytype, tag: Tag) !void
pub fn decode_tag(reader: anytype) !Tag
pub fn tag_size(field_number: u29) u4
```

### Length-Delimited

```zig
/// Encode a length-delimited field (varint length prefix + payload).
pub fn encode_len(writer: anytype, data: []const u8) !void

/// Decode a length-delimited field. Returns a sub-slice or reads into buffer.
/// The caller provides the allocator for variable-length data.
pub fn decode_len(reader: anytype, allocator: std.mem.Allocator) ![]const u8
```

## Scalar Type Encoding Rules

| Proto Type   | Zig Type | Encode Function                                          |
|-------------|----------|----------------------------------------------------------|
| int32       | i32      | Sign-extend to i64, cast to u64, varint                  |
| int64       | i64      | Cast to u64, varint                                      |
| uint32      | u32      | Varint                                                   |
| uint64      | u64      | Varint                                                   |
| sint32      | i32      | ZigZag encode to u32, varint                             |
| sint64      | i64      | ZigZag encode to u64, varint                             |
| bool        | bool     | Varint (0 or 1)                                          |
| enum        | i32      | Sign-extend to i64, cast to u64, varint (like int32)     |
| fixed32     | u32      | 4 bytes little-endian                                    |
| sfixed32    | i32      | 4 bytes little-endian (two's complement)                 |
| float       | f32      | @bitCast to u32, 4 bytes little-endian                   |
| fixed64     | u64      | 8 bytes little-endian                                    |
| sfixed64    | i64      | 8 bytes little-endian (two's complement)                 |
| double      | f64      | @bitCast to u64, 8 bytes little-endian                   |
| string      | []const u8 | Varint length + UTF-8 bytes                            |
| bytes       | []const u8 | Varint length + raw bytes                              |

### Critical: Negative int32

Negative `int32` values are sign-extended to 64 bits before varint encoding.
This means a negative `int32` always takes **10 bytes** on the wire. Use
`sint32` for fields that are frequently negative.

### Critical: Bool Decoding

When decoding a bool, any non-zero varint value is `true`. Don't compare
against 1 specifically.

### Critical: Truncation

When decoding `int32`/`uint32`/`sint32`/`bool` from a varint, the varint may
contain a full 64 bits. Truncate to the target width (take lower bits).

## `message.zig` — Schema-Agnostic Codec

### FieldIterator

Iterate over tag/value pairs in a serialized protobuf message without knowing
the schema. Used by generated decode functions and for unknown field handling.

```zig
pub const FieldValue = union(WireType) {
    varint: u64,
    i64: u64,
    len: []const u8,
    sgroup: void,  // caller must recursively skip/parse until egroup
    egroup: void,
    i32: u32,
};

pub const Field = struct {
    number: u29,
    value: FieldValue,
};

pub const FieldIterator = struct {
    data: []const u8,
    pos: usize,

    pub fn next(self: *FieldIterator) !?Field
};

pub fn iterate_fields(data: []const u8) FieldIterator
```

### MessageWriter

Append fields to a growable buffer or writer.

```zig
pub const MessageWriter = struct {
    writer: std.io.AnyWriter,

    pub fn write_varint_field(self: *MessageWriter, field_number: u29, value: u64) !void
    pub fn write_i32_field(self: *MessageWriter, field_number: u29, value: u32) !void
    pub fn write_i64_field(self: *MessageWriter, field_number: u29, value: u64) !void
    pub fn write_len_field(self: *MessageWriter, field_number: u29, data: []const u8) !void
    pub fn write_packed_field(self: *MessageWriter, field_number: u29, data: []const u8) !void
};
```

### Nested Messages

A nested message is wire type LEN. To decode: read the length prefix, then
decode the sub-message from the sub-slice.

To encode, there are two approaches:

1. **Two-pass**: first compute the serialized size, then write the length
   prefix, then serialize the message. Requires `calc_size()`.
2. **Backpatch**: write a placeholder length, serialize the message, then
   backpatch the length. Only works with seekable writers.

Generated code uses the two-pass approach since `calc_size()` is always
available and it works with non-seekable writers.

### Merging Semantics

If the same field number appears multiple times in a message:

| Field Kind      | Behavior                                  |
|----------------|-------------------------------------------|
| Scalar         | Last value wins                           |
| Message        | Merge recursively                         |
| Repeated       | Concatenate                               |
| Oneof member   | Last value wins (clears previous members) |
| Map entry      | Last value for each key wins              |

### Unknown Fields

Fields with unrecognized field numbers should be preserved for round-tripping.
Store as raw bytes keyed by `(field_number, wire_type)`. Re-emit during
serialization after known fields.

```zig
pub const UnknownField = struct {
    field_number: u29,
    wire_type: WireType,
    data: []const u8,  // raw wire bytes (not including tag)
};
```

### Group Skipping

To skip an unknown group (wire type 3): recursively read and skip fields until
encountering an EGROUP (wire type 4) with the matching field number. Groups can
be nested, so this must be recursive.

```zig
/// Skip a group, reading from the current position until the matching
/// end-group tag. Returns the number of bytes consumed.
pub fn skip_group(reader: anytype, field_number: u29) !void
```

## Packed Repeated Fields

Scalar numeric repeated fields can be packed: all values concatenated into a
single LEN field.

```
[tag (wire_type=LEN)] [byte_length] [value1] [value2] [value3] ...
```

Only numeric scalars can be packed (int32, int64, uint32, uint64, sint32,
sint64, bool, enum, fixed32, fixed64, sfixed32, sfixed64, float, double).
Strings, bytes, and messages cannot be packed.

**Critical**: A conformant parser must accept both packed and unpacked encoding
for any repeated numeric field, regardless of the `.proto` declaration. Multiple
packed chunks for the same field are concatenated.

Proto3 default: packed. Proto2 default: unpacked (opt-in with `[packed=true]`).

## Proto2 vs. Proto3 Wire Differences

The wire format is identical between proto2 and proto3 — the differences are
in serialization/deserialization **behavior**:

### Serialization

| Rule                          | Proto2                          | Proto3                          |
|-------------------------------|--------------------------------|--------------------------------|
| When to omit a field          | When not explicitly set         | When equal to zero default     |
| `optional` with explicit presence | Always (all optional fields) | Only if `optional` keyword used |
| Required field validation     | Must be set before serializing  | N/A                            |
| Packed repeated default       | Unpacked                       | Packed                         |

### Deserialization

| Rule                          | Proto2                          | Proto3                          |
|-------------------------------|--------------------------------|--------------------------------|
| Missing field                 | "not set" (has_field = false)  | Value is zero default          |
| Unknown enum value            | Store as unknown field          | Preserve as integer            |
| Required field missing        | Error                          | N/A                            |
| Groups (wire types 3/4)       | Parse or skip                  | Skip (can't define, but must handle) |
