const std = @import("std");
const testing = std.testing;

// ── Types ─────────────────────────────────────────────────────────────

/// Protocol Buffers wire type tags
pub const WireType = enum(u3) {
    varint = 0,
    i64 = 1,
    len = 2,
    sgroup = 3,
    egroup = 4,
    i32 = 5,
};

/// Decoded field tag (field number + wire type)
pub const Tag = struct {
    field_number: u29,
    wire_type: WireType,
};

/// Errors that can occur during wire format decoding
pub const DecodeError = std.Io.Reader.Error || error{
    Overflow,
    InvalidWireType,
    InvalidFieldNumber,
};

// ── Varint ────────────────────────────────────────────────────────────

/// Encode a u64 as a variable-length integer
pub fn encode_varint(w: *std.Io.Writer, value: u64) std.Io.Writer.Error!void {
    var v = value;
    while (v > 0x7F) {
        try w.writeByte(@as(u8, @truncate(v)) | 0x80);
        v >>= 7;
    }
    try w.writeByte(@truncate(v));
}

/// Return the encoded size in bytes of a varint value
pub fn varint_size(value: u64) u4 {
    var v = value;
    var size: u4 = 1;
    while (v > 0x7F) {
        v >>= 7;
        size += 1;
    }
    return size;
}

/// Decode a variable-length integer into a u64
pub fn decode_varint(r: *std.Io.Reader) (std.Io.Reader.Error || error{Overflow})!u64 {
    var result: u64 = 0;
    for (0..10) |i| {
        const byte = try r.takeByte();
        if (i == 9 and byte > 0x01) return error.Overflow;
        result |= @as(u64, byte & 0x7F) << @intCast(i * 7);
        if (byte & 0x80 == 0) return result;
    }
    unreachable;
}

// ── ZigZag ────────────────────────────────────────────────────────────

/// ZigZag-encode a signed 32-bit integer for sint32 wire format
pub fn zigzag_encode(value: i32) u32 {
    const v: u32 = @bitCast(value);
    const sign: u32 = @bitCast(value >> 31);
    return (v << 1) ^ sign;
}

/// ZigZag-decode a uint32 back to a signed 32-bit integer
pub fn zigzag_decode(value: u32) i32 {
    return @bitCast((value >> 1) ^ (0 -% (value & 1)));
}

/// ZigZag-encode a signed 64-bit integer for sint64 wire format
pub fn zigzag_encode_64(value: i64) u64 {
    const v: u64 = @bitCast(value);
    const sign: u64 = @bitCast(value >> 63);
    return (v << 1) ^ sign;
}

/// ZigZag-decode a uint64 back to a signed 64-bit integer
pub fn zigzag_decode_64(value: u64) i64 {
    return @bitCast((value >> 1) ^ (0 -% (value & 1)));
}

// ── Fixed-width ───────────────────────────────────────────────────────

/// Encode a u32 as 4 little-endian bytes (fixed32/sfixed32)
pub fn encode_fixed32(w: *std.Io.Writer, value: u32) std.Io.Writer.Error!void {
    const bytes: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, value));
    try w.writeAll(&bytes);
}

/// Decode 4 little-endian bytes into a u32
pub fn decode_fixed32(r: *std.Io.Reader) std.Io.Reader.Error!u32 {
    const bytes = try r.takeArray(4);
    return std.mem.littleToNative(u32, @bitCast(bytes.*));
}

/// Encode a u64 as 8 little-endian bytes (fixed64/sfixed64)
pub fn encode_fixed64(w: *std.Io.Writer, value: u64) std.Io.Writer.Error!void {
    const bytes: [8]u8 = @bitCast(std.mem.nativeToLittle(u64, value));
    try w.writeAll(&bytes);
}

/// Decode 8 little-endian bytes into a u64
pub fn decode_fixed64(r: *std.Io.Reader) std.Io.Reader.Error!u64 {
    const bytes = try r.takeArray(8);
    return std.mem.littleToNative(u64, @bitCast(bytes.*));
}

// ── Float/Double ──────────────────────────────────────────────────────

/// Encode an f32 as 4 little-endian bytes
pub fn encode_float(w: *std.Io.Writer, value: f32) std.Io.Writer.Error!void {
    return encode_fixed32(w, @bitCast(value));
}

/// Decode 4 little-endian bytes into an f32
pub fn decode_float(r: *std.Io.Reader) std.Io.Reader.Error!f32 {
    return @bitCast(try decode_fixed32(r));
}

/// Encode an f64 as 8 little-endian bytes
pub fn encode_double(w: *std.Io.Writer, value: f64) std.Io.Writer.Error!void {
    return encode_fixed64(w, @bitCast(value));
}

/// Decode 8 little-endian bytes into an f64
pub fn decode_double(r: *std.Io.Reader) std.Io.Reader.Error!f64 {
    return @bitCast(try decode_fixed64(r));
}

// ── Tag ───────────────────────────────────────────────────────────────

/// Encode a field tag (field number + wire type) as a varint
pub fn encode_tag(w: *std.Io.Writer, tag: Tag) std.Io.Writer.Error!void {
    return encode_varint(w, (@as(u64, tag.field_number) << 3) | @intFromEnum(tag.wire_type));
}

/// Decode a varint into a field tag
pub fn decode_tag(r: *std.Io.Reader) DecodeError!Tag {
    const raw = try decode_varint(r);
    const wire_type_int: u3 = @intCast(raw & 0x07);
    if (wire_type_int > 5) return error.InvalidWireType;
    const field_number_raw = raw >> 3;
    if (field_number_raw == 0) return error.InvalidFieldNumber;
    if (field_number_raw > std.math.maxInt(u29)) return error.InvalidFieldNumber;
    return .{
        .field_number = @intCast(field_number_raw),
        .wire_type = @enumFromInt(wire_type_int),
    };
}

/// Return the encoded size in bytes of a field tag
pub fn tag_size(field_number: u29) u4 {
    return varint_size(@as(u64, field_number) << 3);
}

// ── Length-delimited ──────────────────────────────────────────────────

/// Encode a length-delimited byte slice (length prefix + data)
pub fn encode_len(w: *std.Io.Writer, data: []const u8) std.Io.Writer.Error!void {
    try encode_varint(w, @intCast(data.len));
    try w.writeAll(data);
}

/// Decode a length-delimited byte slice, allocating the result
pub fn decode_len(r: *std.Io.Reader, allocator: std.mem.Allocator) ![]u8 {
    const len = std.math.cast(usize, try decode_varint(r)) orelse return error.Overflow;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try r.readSliceAll(buf);
    return buf;
}

// ── Scalar type helpers ───────────────────────────────────────────────

/// Encode an int32 as a varint (sign-extended to 64 bits)
pub fn encode_int32(w: *std.Io.Writer, value: i32) std.Io.Writer.Error!void {
    return encode_varint(w, @bitCast(@as(i64, value)));
}

/// Encode an int64 as a varint
pub fn encode_int64(w: *std.Io.Writer, value: i64) std.Io.Writer.Error!void {
    return encode_varint(w, @bitCast(value));
}

/// Encode a uint32 as a varint
pub fn encode_uint32(w: *std.Io.Writer, value: u32) std.Io.Writer.Error!void {
    return encode_varint(w, value);
}

/// Encode a sint32 using ZigZag encoding
pub fn encode_sint32(w: *std.Io.Writer, value: i32) std.Io.Writer.Error!void {
    return encode_varint(w, zigzag_encode(value));
}

/// Encode a sint64 using ZigZag encoding
pub fn encode_sint64(w: *std.Io.Writer, value: i64) std.Io.Writer.Error!void {
    return encode_varint(w, zigzag_encode_64(value));
}

/// Encode a bool as a varint (0 or 1)
pub fn encode_bool(w: *std.Io.Writer, value: bool) std.Io.Writer.Error!void {
    return encode_varint(w, @intFromBool(value));
}

/// Decode a varint into an i32
pub fn decode_int32(r: *std.Io.Reader) (std.Io.Reader.Error || error{Overflow})!i32 {
    return @bitCast(@as(u32, @truncate(try decode_varint(r))));
}

/// Decode a varint into a u32
pub fn decode_uint32(r: *std.Io.Reader) (std.Io.Reader.Error || error{Overflow})!u32 {
    return @truncate(try decode_varint(r));
}

/// Decode a varint into an i64
pub fn decode_int64(r: *std.Io.Reader) (std.Io.Reader.Error || error{Overflow})!i64 {
    return @bitCast(try decode_varint(r));
}

/// Decode a ZigZag-encoded varint into an i32
pub fn decode_sint32(r: *std.Io.Reader) (std.Io.Reader.Error || error{Overflow})!i32 {
    return zigzag_decode(@truncate(try decode_varint(r)));
}

/// Decode a ZigZag-encoded varint into an i64
pub fn decode_sint64(r: *std.Io.Reader) (std.Io.Reader.Error || error{Overflow})!i64 {
    return zigzag_decode_64(try decode_varint(r));
}

/// Decode a varint into a bool (nonzero = true)
pub fn decode_bool(r: *std.Io.Reader) (std.Io.Reader.Error || error{Overflow})!bool {
    return try decode_varint(r) != 0;
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

// ── Varint encode tests ──────────────────────────────────────────────

test "encode_varint: zero" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_varint(&w, 0);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, w.buffered());
}

test "encode_varint: one" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_varint(&w, 1);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, w.buffered());
}

test "encode_varint: 127" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_varint(&w, 127);
    try testing.expectEqualSlices(u8, &[_]u8{0x7F}, w.buffered());
}

test "encode_varint: 128" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_varint(&w, 128);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x01 }, w.buffered());
}

test "encode_varint: 300" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_varint(&w, 300);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAC, 0x02 }, w.buffered());
}

test "encode_varint: 150 (protobuf spec)" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_varint(&w, 150);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x96, 0x01 }, w.buffered());
}

test "encode_varint: maxInt(u64) produces 10 bytes" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_varint(&w, std.math.maxInt(u64));
    const expected = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    try testing.expectEqualSlices(u8, &expected, w.buffered());
}

// ── Varint size tests ────────────────────────────────────────────────

test "varint_size matches encoded length" {
    const cases = [_]u64{ 0, 1, 127, 128, 300, 150, std.math.maxInt(u32), std.math.maxInt(u64) };
    for (cases) |value| {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try encode_varint(&w, value);
        try testing.expectEqual(@as(u4, @intCast(w.buffered().len)), varint_size(value));
    }
}

// ── Varint decode tests ──────────────────────────────────────────────

test "decode_varint: known bytes 0x96 0x01 = 150" {
    var r: std.Io.Reader = .fixed(&[_]u8{ 0x96, 0x01 });
    try testing.expectEqual(@as(u64, 150), try decode_varint(&r));
}

test "decode_varint: round-trip" {
    const cases = [_]u64{ 0, 1, 127, 128, 300, std.math.maxInt(u32), std.math.maxInt(u64) };
    for (cases) |value| {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try encode_varint(&w, value);
        var r: std.Io.Reader = .fixed(w.buffered());
        try testing.expectEqual(value, try decode_varint(&r));
    }
}

test "decode_varint: empty input returns EndOfStream" {
    var r: std.Io.Reader = .fixed("");
    try testing.expectError(error.EndOfStream, decode_varint(&r));
}

test "decode_varint: truncated varint returns EndOfStream" {
    var r: std.Io.Reader = .fixed(&[_]u8{0x80});
    try testing.expectError(error.EndOfStream, decode_varint(&r));
}

test "decode_varint: overflow on 10th byte > 0x01" {
    var r: std.Io.Reader = .fixed(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02 });
    try testing.expectError(error.Overflow, decode_varint(&r));
}

test "decode_varint: overflow on >10 continuation bytes" {
    var r: std.Io.Reader = .fixed(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 });
    try testing.expectError(error.Overflow, decode_varint(&r));
}

test "decode_varint: overlong encoding 0x80 0x00 = 0 (valid)" {
    var r: std.Io.Reader = .fixed(&[_]u8{ 0x80, 0x00 });
    try testing.expectEqual(@as(u64, 0), try decode_varint(&r));
}

// ── ZigZag tests ─────────────────────────────────────────────────────

test "zigzag_encode: spec table" {
    try testing.expectEqual(@as(u32, 0), zigzag_encode(0));
    try testing.expectEqual(@as(u32, 1), zigzag_encode(-1));
    try testing.expectEqual(@as(u32, 2), zigzag_encode(1));
    try testing.expectEqual(@as(u32, 3), zigzag_encode(-2));
    try testing.expectEqual(@as(u32, 4), zigzag_encode(2));
    try testing.expectEqual(@as(u32, 0xfffffffe), zigzag_encode(std.math.maxInt(i32)));
    try testing.expectEqual(@as(u32, 0xffffffff), zigzag_encode(std.math.minInt(i32)));
}

test "zigzag_decode: spec table" {
    try testing.expectEqual(@as(i32, 0), zigzag_decode(0));
    try testing.expectEqual(@as(i32, -1), zigzag_decode(1));
    try testing.expectEqual(@as(i32, 1), zigzag_decode(2));
    try testing.expectEqual(@as(i32, -2), zigzag_decode(3));
    try testing.expectEqual(@as(i32, 2), zigzag_decode(4));
}

test "zigzag: round-trip 32-bit" {
    const cases = [_]i32{ 0, 1, -1, 2, -2, 127, -128, std.math.maxInt(i32), std.math.minInt(i32) };
    for (cases) |value| {
        try testing.expectEqual(value, zigzag_decode(zigzag_encode(value)));
    }
}

test "zigzag_encode_64: spec values" {
    try testing.expectEqual(@as(u64, 0), zigzag_encode_64(0));
    try testing.expectEqual(@as(u64, 1), zigzag_encode_64(-1));
    try testing.expectEqual(@as(u64, 2), zigzag_encode_64(1));
    try testing.expectEqual(@as(u64, 3), zigzag_encode_64(-2));
}

test "zigzag: round-trip 64-bit" {
    const cases = [_]i64{ 0, 1, -1, 2, -2, 127, -128, std.math.maxInt(i64), std.math.minInt(i64) };
    for (cases) |value| {
        try testing.expectEqual(value, zigzag_decode_64(zigzag_encode_64(value)));
    }
}

// ── Fixed-width tests ────────────────────────────────────────────────

test "encode_fixed32: 0xdeadbeef" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_fixed32(&w, 0xdeadbeef);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xef, 0xbe, 0xad, 0xde }, w.buffered());
}

test "fixed32: round-trip" {
    const cases = [_]u32{ 0, 1, 0xdeadbeef, std.math.maxInt(u32) };
    for (cases) |value| {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try encode_fixed32(&w, value);
        var r: std.Io.Reader = .fixed(w.buffered());
        try testing.expectEqual(value, try decode_fixed32(&r));
    }
}

test "decode_fixed32: insufficient bytes" {
    var r: std.Io.Reader = .fixed(&[_]u8{ 0x01, 0x02 });
    try testing.expectError(error.EndOfStream, decode_fixed32(&r));
}

test "encode_fixed64: known value" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_fixed64(&w, 0x0102030405060708);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 }, w.buffered());
}

test "fixed64: round-trip" {
    const cases = [_]u64{ 0, 1, 0xdeadbeefcafebabe, std.math.maxInt(u64) };
    for (cases) |value| {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try encode_fixed64(&w, value);
        var r: std.Io.Reader = .fixed(w.buffered());
        try testing.expectEqual(value, try decode_fixed64(&r));
    }
}

test "decode_fixed64: insufficient bytes" {
    var r: std.Io.Reader = .fixed(&[_]u8{ 0x01, 0x02, 0x03 });
    try testing.expectError(error.EndOfStream, decode_fixed64(&r));
}

// ── Float/Double tests ───────────────────────────────────────────────

test "encode_float: 1.0" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_float(&w, 1.0);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x80, 0x3f }, w.buffered());
}

test "float: round-trip" {
    const cases = [_]f32{ 0.0, 1.0, -1.0, std.math.inf(f32), -std.math.inf(f32) };
    for (cases) |value| {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try encode_float(&w, value);
        var r: std.Io.Reader = .fixed(w.buffered());
        try testing.expectEqual(value, try decode_float(&r));
    }
}

test "float: NaN bit pattern preserved" {
    const nan = std.math.nan(f32);
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_float(&w, nan);
    var r: std.Io.Reader = .fixed(w.buffered());
    const decoded = try decode_float(&r);
    try testing.expectEqual(@as(u32, @bitCast(nan)), @as(u32, @bitCast(decoded)));
}

test "double: round-trip" {
    const cases = [_]f64{ 0.0, 1.0, -1.0, std.math.inf(f64), -std.math.inf(f64) };
    for (cases) |value| {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try encode_double(&w, value);
        var r: std.Io.Reader = .fixed(w.buffered());
        try testing.expectEqual(value, try decode_double(&r));
    }
}

test "double: NaN bit pattern preserved" {
    const nan = std.math.nan(f64);
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_double(&w, nan);
    var r: std.Io.Reader = .fixed(w.buffered());
    const decoded = try decode_double(&r);
    try testing.expectEqual(@as(u64, @bitCast(nan)), @as(u64, @bitCast(decoded)));
}

// ── Tag tests ────────────────────────────────────────────────────────

test "encode_tag: field 1 varint" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_tag(&w, .{ .field_number = 1, .wire_type = .varint });
    try testing.expectEqualSlices(u8, &[_]u8{0x08}, w.buffered());
}

test "encode_tag: field 1 len" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_tag(&w, .{ .field_number = 1, .wire_type = .len });
    try testing.expectEqualSlices(u8, &[_]u8{0x0a}, w.buffered());
}

test "encode_tag: field 16 varint" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_tag(&w, .{ .field_number = 16, .wire_type = .varint });
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x01 }, w.buffered());
}

test "tag_size" {
    try testing.expectEqual(@as(u4, 1), tag_size(1));
    try testing.expectEqual(@as(u4, 2), tag_size(16));
}

test "decode_tag: round-trip" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const tag = Tag{ .field_number = 42, .wire_type = .len };
    try encode_tag(&w, tag);
    var r: std.Io.Reader = .fixed(w.buffered());
    const decoded = try decode_tag(&r);
    try testing.expectEqual(tag.field_number, decoded.field_number);
    try testing.expectEqual(tag.wire_type, decoded.wire_type);
}

test "decode_tag: invalid wire type 6" {
    // Wire type 6: field=0 doesn't matter, encode raw varint (0 << 3) | 6 = 6
    // But field 0 is also invalid. Use field=1: (1 << 3) | 6 = 14
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_varint(&w, 14); // field 1, wire type 6
    var r: std.Io.Reader = .fixed(w.buffered());
    try testing.expectError(error.InvalidWireType, decode_tag(&r));
}

test "decode_tag: invalid wire type 7" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_varint(&w, 15); // field 1, wire type 7
    var r: std.Io.Reader = .fixed(w.buffered());
    try testing.expectError(error.InvalidWireType, decode_tag(&r));
}

test "decode_tag: field number 0" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_varint(&w, 0); // field 0, wire type 0
    var r: std.Io.Reader = .fixed(w.buffered());
    try testing.expectError(error.InvalidFieldNumber, decode_tag(&r));
}

// ── Length-delimited tests ───────────────────────────────────────────

test "encode_len: hello" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_len(&w, "hello");
    try testing.expectEqualSlices(u8, &[_]u8{ 0x05, 'h', 'e', 'l', 'l', 'o' }, w.buffered());
}

test "encode_len: empty" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_len(&w, "");
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, w.buffered());
}

test "decode_len: round-trip" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_len(&w, "hello");
    var r: std.Io.Reader = .fixed(w.buffered());
    const decoded = try decode_len(&r, testing.allocator);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("hello", decoded);
}

test "decode_len: empty round-trip" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_len(&w, "");
    var r: std.Io.Reader = .fixed(w.buffered());
    const decoded = try decode_len(&r, testing.allocator);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 0), decoded.len);
}

test "decode_len: insufficient payload" {
    // Length says 5, but only 3 bytes follow
    var r: std.Io.Reader = .fixed(&[_]u8{ 0x05, 'a', 'b', 'c' });
    try testing.expectError(error.EndOfStream, decode_len(&r, testing.allocator));
}

// ── Scalar type helper tests ─────────────────────────────────────────

test "encode_int32: negative produces 10 bytes" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_int32(&w, -1);
    try testing.expectEqual(@as(usize, 10), w.buffered().len);
}

test "int32: round-trip" {
    const cases = [_]i32{ 0, 1, -1, 127, -128, std.math.maxInt(i32), std.math.minInt(i32) };
    for (cases) |value| {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try encode_int32(&w, value);
        var r: std.Io.Reader = .fixed(w.buffered());
        try testing.expectEqual(value, try decode_int32(&r));
    }
}

test "uint32: round-trip" {
    const cases = [_]u32{ 0, 1, 128, std.math.maxInt(u32) };
    for (cases) |value| {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try encode_uint32(&w, value);
        var r: std.Io.Reader = .fixed(w.buffered());
        try testing.expectEqual(value, try decode_uint32(&r));
    }
}

test "int64: round-trip" {
    const cases = [_]i64{ 0, 1, -1, std.math.maxInt(i64), std.math.minInt(i64) };
    for (cases) |value| {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try encode_int64(&w, value);
        var r: std.Io.Reader = .fixed(w.buffered());
        try testing.expectEqual(value, try decode_int64(&r));
    }
}

test "sint32: round-trip" {
    const cases = [_]i32{ 0, 1, -1, 2, -2, std.math.maxInt(i32), std.math.minInt(i32) };
    for (cases) |value| {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try encode_sint32(&w, value);
        var r: std.Io.Reader = .fixed(w.buffered());
        try testing.expectEqual(value, try decode_sint32(&r));
    }
}

test "sint64: round-trip" {
    const cases = [_]i64{ 0, 1, -1, 2, -2, std.math.maxInt(i64), std.math.minInt(i64) };
    for (cases) |value| {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try encode_sint64(&w, value);
        var r: std.Io.Reader = .fixed(w.buffered());
        try testing.expectEqual(value, try decode_sint64(&r));
    }
}

test "bool: round-trip" {
    for ([_]bool{ true, false }) |value| {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try encode_bool(&w, value);
        var r: std.Io.Reader = .fixed(w.buffered());
        try testing.expectEqual(value, try decode_bool(&r));
    }
}

test "decode_bool: varint 150 is true" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_varint(&w, 150);
    var r: std.Io.Reader = .fixed(w.buffered());
    try testing.expect(try decode_bool(&r));
}

// ── Integration tests ────────────────────────────────────────────────

test "protobuf spec: field 1 varint 150" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_tag(&w, .{ .field_number = 1, .wire_type = .varint });
    try encode_varint(&w, 150);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01 }, w.buffered());
}

test "protobuf spec: field 2 string testing" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_tag(&w, .{ .field_number = 2, .wire_type = .len });
    try encode_len(&w, "testing");
    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x07, 0x74, 0x65, 0x73, 0x74, 0x69, 0x6e, 0x67 }, w.buffered());
}

test "multi-field encode/decode sequence" {
    // Encode: field 1 varint 150, field 2 string "hi", field 3 fixed32 42
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_tag(&w, .{ .field_number = 1, .wire_type = .varint });
    try encode_varint(&w, 150);
    try encode_tag(&w, .{ .field_number = 2, .wire_type = .len });
    try encode_len(&w, "hi");
    try encode_tag(&w, .{ .field_number = 3, .wire_type = .i32 });
    try encode_fixed32(&w, 42);

    // Decode
    var r: std.Io.Reader = .fixed(w.buffered());

    const tag1 = try decode_tag(&r);
    try testing.expectEqual(@as(u29, 1), tag1.field_number);
    try testing.expectEqual(WireType.varint, tag1.wire_type);
    try testing.expectEqual(@as(u64, 150), try decode_varint(&r));

    const tag2 = try decode_tag(&r);
    try testing.expectEqual(@as(u29, 2), tag2.field_number);
    try testing.expectEqual(WireType.len, tag2.wire_type);
    const str = try decode_len(&r, testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("hi", str);

    const tag3 = try decode_tag(&r);
    try testing.expectEqual(@as(u29, 3), tag3.field_number);
    try testing.expectEqual(WireType.i32, tag3.wire_type);
    try testing.expectEqual(@as(u32, 42), try decode_fixed32(&r));
}

test "boundary: max field number" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const max_field: u29 = std.math.maxInt(u29);
    try encode_tag(&w, .{ .field_number = max_field, .wire_type = .varint });
    var r: std.Io.Reader = .fixed(w.buffered());
    const tag = try decode_tag(&r);
    try testing.expectEqual(max_field, tag.field_number);
}

test "boundary: field number 1" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode_tag(&w, .{ .field_number = 1, .wire_type = .varint });
    var r: std.Io.Reader = .fixed(w.buffered());
    const tag = try decode_tag(&r);
    try testing.expectEqual(@as(u29, 1), tag.field_number);
}

test "empty reader for each decode function" {
    {
        var r: std.Io.Reader = .fixed("");
        try testing.expectError(error.EndOfStream, decode_varint(&r));
    }
    {
        var r: std.Io.Reader = .fixed("");
        try testing.expectError(error.EndOfStream, decode_fixed32(&r));
    }
    {
        var r: std.Io.Reader = .fixed("");
        try testing.expectError(error.EndOfStream, decode_fixed64(&r));
    }
    {
        var r: std.Io.Reader = .fixed("");
        try testing.expectError(error.EndOfStream, decode_float(&r));
    }
    {
        var r: std.Io.Reader = .fixed("");
        try testing.expectError(error.EndOfStream, decode_double(&r));
    }
    {
        var r: std.Io.Reader = .fixed("");
        try testing.expectError(error.EndOfStream, decode_tag(&r));
    }
    {
        var r: std.Io.Reader = .fixed("");
        try testing.expectError(error.EndOfStream, decode_int32(&r));
    }
    {
        var r: std.Io.Reader = .fixed("");
        try testing.expectError(error.EndOfStream, decode_int64(&r));
    }
    {
        var r: std.Io.Reader = .fixed("");
        try testing.expectError(error.EndOfStream, decode_uint32(&r));
    }
    {
        var r: std.Io.Reader = .fixed("");
        try testing.expectError(error.EndOfStream, decode_sint32(&r));
    }
    {
        var r: std.Io.Reader = .fixed("");
        try testing.expectError(error.EndOfStream, decode_sint64(&r));
    }
    {
        var r: std.Io.Reader = .fixed("");
        try testing.expectError(error.EndOfStream, decode_bool(&r));
    }
}
