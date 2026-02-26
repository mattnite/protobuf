const std = @import("std");
const testing = std.testing;
const encoding = @import("encoding.zig");

// ── Types ─────────────────────────────────────────────────────────────

pub const Error = error{ EndOfStream, Overflow, InvalidWireType, InvalidFieldNumber };

pub const FieldValue = union(encoding.WireType) {
    varint: u64,
    i64: u64,
    len: []const u8,
    sgroup: void,
    egroup: void,
    i32: u32,
};

pub const Field = struct {
    number: u29,
    value: FieldValue,
};

// ── Private Slice Helpers ─────────────────────────────────────────────

fn decode_varint_slice(data: []const u8, pos: *usize) error{ EndOfStream, Overflow }!u64 {
    var result: u64 = 0;
    for (0..10) |i| {
        if (pos.* >= data.len) return error.EndOfStream;
        const byte = data[pos.*];
        pos.* += 1;
        if (i == 9 and byte > 0x01) return error.Overflow;
        result |= @as(u64, byte & 0x7F) << @intCast(i * 7);
        if (byte & 0x80 == 0) return result;
    }
    unreachable;
}

fn decode_tag_slice(data: []const u8, pos: *usize) Error!encoding.Tag {
    const raw = try decode_varint_slice(data, pos);
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

fn read_fixed_slice(comptime n: comptime_int, data: []const u8, pos: *usize) error{EndOfStream}![n]u8 {
    if (pos.* + n > data.len) return error.EndOfStream;
    const result: [n]u8 = data[pos.*..][0..n].*;
    pos.* += n;
    return result;
}

// ── FieldIterator ─────────────────────────────────────────────────────

pub const FieldIterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(self: *FieldIterator) Error!?Field {
        if (self.pos >= self.data.len) return null;

        const tag = try decode_tag_slice(self.data, &self.pos);
        const value: FieldValue = switch (tag.wire_type) {
            .varint => .{ .varint = try decode_varint_slice(self.data, &self.pos) },
            .i64 => .{ .i64 = std.mem.littleToNative(u64, @bitCast(try read_fixed_slice(8, self.data, &self.pos))) },
            .i32 => .{ .i32 = std.mem.littleToNative(u32, @bitCast(try read_fixed_slice(4, self.data, &self.pos))) },
            .len => blk: {
                const len = std.math.cast(usize, try decode_varint_slice(self.data, &self.pos)) orelse return error.Overflow;
                if (self.pos + len > self.data.len) return error.EndOfStream;
                const slice = self.data[self.pos..][0..len];
                self.pos += len;
                break :blk .{ .len = slice };
            },
            .sgroup => .{ .sgroup = {} },
            .egroup => .{ .egroup = {} },
        };

        return .{ .number = tag.field_number, .value = value };
    }
};

pub fn iterate_fields(data: []const u8) FieldIterator {
    return .{ .data = data };
}

// ── Skip Functions ────────────────────────────────────────────────────

pub fn skip_field(data: []const u8, pos: *usize, wire_type: encoding.WireType) Error!void {
    switch (wire_type) {
        .varint => _ = try decode_varint_slice(data, pos),
        .i64 => _ = try read_fixed_slice(8, data, pos),
        .i32 => _ = try read_fixed_slice(4, data, pos),
        .len => {
            const len = std.math.cast(usize, try decode_varint_slice(data, pos)) orelse return error.Overflow;
            if (pos.* + len > data.len) return error.EndOfStream;
            pos.* += len;
        },
        .sgroup => |_| return error.InvalidWireType,
        .egroup => {},
    }
}

pub fn skip_group(data: []const u8, pos: *usize, field_number: u29) Error!void {
    while (pos.* < data.len) {
        const tag = try decode_tag_slice(data, pos);
        if (tag.wire_type == .egroup) {
            if (tag.field_number == field_number) return;
            continue;
        }
        if (tag.wire_type == .sgroup) {
            try skip_group(data, pos, tag.field_number);
            continue;
        }
        try skip_field(data, pos, tag.wire_type);
    }
    return error.EndOfStream;
}

// ── MessageWriter ─────────────────────────────────────────────────────

pub const MessageWriter = struct {
    writer: *std.Io.Writer,

    pub fn init(writer: *std.Io.Writer) MessageWriter {
        return .{ .writer = writer };
    }

    pub fn write_varint_field(self: MessageWriter, field_number: u29, value: u64) std.Io.Writer.Error!void {
        try encoding.encode_tag(self.writer, .{ .field_number = field_number, .wire_type = .varint });
        try encoding.encode_varint(self.writer, value);
    }

    pub fn write_i32_field(self: MessageWriter, field_number: u29, value: u32) std.Io.Writer.Error!void {
        try encoding.encode_tag(self.writer, .{ .field_number = field_number, .wire_type = .i32 });
        try encoding.encode_fixed32(self.writer, value);
    }

    pub fn write_i64_field(self: MessageWriter, field_number: u29, value: u64) std.Io.Writer.Error!void {
        try encoding.encode_tag(self.writer, .{ .field_number = field_number, .wire_type = .i64 });
        try encoding.encode_fixed64(self.writer, value);
    }

    pub fn write_len_field(self: MessageWriter, field_number: u29, data: []const u8) std.Io.Writer.Error!void {
        try encoding.encode_tag(self.writer, .{ .field_number = field_number, .wire_type = .len });
        try encoding.encode_len(self.writer, data);
    }

    pub fn write_packed_field(self: MessageWriter, field_number: u29, data: []const u8) std.Io.Writer.Error!void {
        try encoding.encode_tag(self.writer, .{ .field_number = field_number, .wire_type = .len });
        try encoding.encode_len(self.writer, data);
    }
};

// ── Packed Iterators ──────────────────────────────────────────────────

pub const PackedVarintIterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) PackedVarintIterator {
        return .{ .data = data };
    }

    pub fn next(self: *PackedVarintIterator) error{ EndOfStream, Overflow }!?u64 {
        if (self.pos >= self.data.len) return null;
        return try decode_varint_slice(self.data, &self.pos);
    }
};

pub const PackedFixed32Iterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) PackedFixed32Iterator {
        return .{ .data = data };
    }

    pub fn next(self: *PackedFixed32Iterator) error{EndOfStream}!?u32 {
        if (self.pos >= self.data.len) return null;
        return std.mem.littleToNative(u32, @bitCast(try read_fixed_slice(4, self.data, &self.pos)));
    }
};

pub const PackedFixed64Iterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) PackedFixed64Iterator {
        return .{ .data = data };
    }

    pub fn next(self: *PackedFixed64Iterator) error{EndOfStream}!?u64 {
        if (self.pos >= self.data.len) return null;
        return std.mem.littleToNative(u64, @bitCast(try read_fixed_slice(8, self.data, &self.pos)));
    }
};

// ── Size Helpers ──────────────────────────────────────────────────────

pub fn varint_field_size(field_number: u29, value: u64) usize {
    return @as(usize, encoding.tag_size(field_number)) + @as(usize, encoding.varint_size(value));
}

pub fn i32_field_size(field_number: u29) usize {
    return @as(usize, encoding.tag_size(field_number)) + 4;
}

pub fn i64_field_size(field_number: u29) usize {
    return @as(usize, encoding.tag_size(field_number)) + 8;
}

pub fn len_field_size(field_number: u29, data_len: usize) usize {
    return @as(usize, encoding.tag_size(field_number)) + @as(usize, encoding.varint_size(@intCast(data_len))) + data_len;
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

// ── decode_varint_slice tests ─────────────────────────────────────────

test "decode_varint_slice: known bytes 0x96 0x01 = 150" {
    const data = [_]u8{ 0x96, 0x01 };
    var pos: usize = 0;
    try testing.expectEqual(@as(u64, 150), try decode_varint_slice(&data, &pos));
    try testing.expectEqual(@as(usize, 2), pos);
}

test "decode_varint_slice: zero" {
    const data = [_]u8{0x00};
    var pos: usize = 0;
    try testing.expectEqual(@as(u64, 0), try decode_varint_slice(&data, &pos));
    try testing.expectEqual(@as(usize, 1), pos);
}

test "decode_varint_slice: maxInt(u64)" {
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    var pos: usize = 0;
    try testing.expectEqual(std.math.maxInt(u64), try decode_varint_slice(&data, &pos));
    try testing.expectEqual(@as(usize, 10), pos);
}

test "decode_varint_slice: empty data returns EndOfStream" {
    var pos: usize = 0;
    try testing.expectError(error.EndOfStream, decode_varint_slice("", &pos));
}

test "decode_varint_slice: truncated varint returns EndOfStream" {
    const data = [_]u8{0x80};
    var pos: usize = 0;
    try testing.expectError(error.EndOfStream, decode_varint_slice(&data, &pos));
}

test "decode_varint_slice: overflow on 10th byte > 0x01" {
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02 };
    var pos: usize = 0;
    try testing.expectError(error.Overflow, decode_varint_slice(&data, &pos));
}

// ── FieldIterator tests ───────────────────────────────────────────────

test "FieldIterator: empty message returns null" {
    var iter = iterate_fields("");
    try testing.expectEqual(@as(?Field, null), try iter.next());
}

test "FieldIterator: single varint field (field 1, value 150)" {
    // field 1 varint: tag = 0x08, value = 0x96 0x01
    const data = [_]u8{ 0x08, 0x96, 0x01 };
    var iter = iterate_fields(&data);
    const field = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 1), field.number);
    try testing.expectEqual(@as(u64, 150), field.value.varint);
    try testing.expectEqual(@as(?Field, null), try iter.next());
}

test "FieldIterator: single LEN field (field 2, 'testing')" {
    // field 2 len: tag = 0x12, length = 0x07, data = "testing"
    const data = [_]u8{ 0x12, 0x07, 0x74, 0x65, 0x73, 0x74, 0x69, 0x6e, 0x67 };
    var iter = iterate_fields(&data);
    const field = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 2), field.number);
    try testing.expectEqualStrings("testing", field.value.len);
    try testing.expectEqual(@as(?Field, null), try iter.next());
}

test "FieldIterator: i64 field" {
    // Encode field 1 i64 with value 0x0102030405060708
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encoding.encode_tag(&w, .{ .field_number = 1, .wire_type = .i64 });
    try encoding.encode_fixed64(&w, 0x0102030405060708);
    var iter = iterate_fields(w.buffered());
    const field = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 1), field.number);
    try testing.expectEqual(@as(u64, 0x0102030405060708), field.value.i64);
    try testing.expectEqual(@as(?Field, null), try iter.next());
}

test "FieldIterator: i32 field" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encoding.encode_tag(&w, .{ .field_number = 3, .wire_type = .i32 });
    try encoding.encode_fixed32(&w, 42);
    var iter = iterate_fields(w.buffered());
    const field = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 3), field.number);
    try testing.expectEqual(@as(u32, 42), field.value.i32);
    try testing.expectEqual(@as(?Field, null), try iter.next());
}

test "FieldIterator: sgroup and egroup fields" {
    // sgroup tag: (field_number=1 << 3) | 3 = 0x0B
    // egroup tag: (field_number=1 << 3) | 4 = 0x0C
    const data = [_]u8{ 0x0B, 0x0C };
    var iter = iterate_fields(&data);

    const sgroup = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 1), sgroup.number);
    try testing.expectEqual(encoding.WireType.sgroup, @as(encoding.WireType, sgroup.value));

    const egroup = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 1), egroup.number);
    try testing.expectEqual(encoding.WireType.egroup, @as(encoding.WireType, egroup.value));

    try testing.expectEqual(@as(?Field, null), try iter.next());
}

test "FieldIterator: multiple fields in sequence" {
    // field 1 varint 150, field 2 string "hi", field 3 fixed32 42
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encoding.encode_tag(&w, .{ .field_number = 1, .wire_type = .varint });
    try encoding.encode_varint(&w, 150);
    try encoding.encode_tag(&w, .{ .field_number = 2, .wire_type = .len });
    try encoding.encode_len(&w, "hi");
    try encoding.encode_tag(&w, .{ .field_number = 3, .wire_type = .i32 });
    try encoding.encode_fixed32(&w, 42);

    var iter = iterate_fields(w.buffered());

    const f1 = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 1), f1.number);
    try testing.expectEqual(@as(u64, 150), f1.value.varint);

    const f2 = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 2), f2.number);
    try testing.expectEqualStrings("hi", f2.value.len);

    const f3 = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 3), f3.number);
    try testing.expectEqual(@as(u32, 42), f3.value.i32);

    try testing.expectEqual(@as(?Field, null), try iter.next());
}

test "FieldIterator: truncated varint value returns EndOfStream" {
    // tag for field 1 varint, but no value bytes
    const data = [_]u8{0x08};
    var iter = iterate_fields(&data);
    try testing.expectError(error.EndOfStream, iter.next());
}

test "FieldIterator: truncated i32 value returns EndOfStream" {
    // tag for field 1 i32, but only 2 bytes of value
    const data = [_]u8{ 0x0D, 0x01, 0x02 };
    var iter = iterate_fields(&data);
    try testing.expectError(error.EndOfStream, iter.next());
}

test "FieldIterator: truncated i64 value returns EndOfStream" {
    // tag for field 1 i64, but only 3 bytes of value
    const data = [_]u8{ 0x09, 0x01, 0x02, 0x03 };
    var iter = iterate_fields(&data);
    try testing.expectError(error.EndOfStream, iter.next());
}

test "FieldIterator: truncated LEN payload returns EndOfStream" {
    // tag for field 2 len, length=5 but only 3 bytes follow
    const data = [_]u8{ 0x12, 0x05, 'a', 'b', 'c' };
    var iter = iterate_fields(&data);
    try testing.expectError(error.EndOfStream, iter.next());
}

test "FieldIterator: invalid wire type 6" {
    // raw varint (1 << 3) | 6 = 14
    const data = [_]u8{0x0E};
    var iter = iterate_fields(&data);
    try testing.expectError(error.InvalidWireType, iter.next());
}

test "FieldIterator: invalid wire type 7" {
    // raw varint (1 << 3) | 7 = 15
    const data = [_]u8{0x0F};
    var iter = iterate_fields(&data);
    try testing.expectError(error.InvalidWireType, iter.next());
}

test "FieldIterator: field number 0 returns InvalidFieldNumber" {
    // raw varint (0 << 3) | 0 = 0
    const data = [_]u8{0x00};
    var iter = iterate_fields(&data);
    try testing.expectError(error.InvalidFieldNumber, iter.next());
}

// ── skip_field tests ──────────────────────────────────────────────────

test "skip_field: varint" {
    const data = [_]u8{ 0x96, 0x01 };
    var pos: usize = 0;
    try skip_field(&data, &pos, .varint);
    try testing.expectEqual(@as(usize, 2), pos);
}

test "skip_field: i64" {
    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var pos: usize = 0;
    try skip_field(&data, &pos, .i64);
    try testing.expectEqual(@as(usize, 8), pos);
}

test "skip_field: i32" {
    const data = [_]u8{ 1, 2, 3, 4 };
    var pos: usize = 0;
    try skip_field(&data, &pos, .i32);
    try testing.expectEqual(@as(usize, 4), pos);
}

test "skip_field: len" {
    const data = [_]u8{ 0x03, 'a', 'b', 'c' };
    var pos: usize = 0;
    try skip_field(&data, &pos, .len);
    try testing.expectEqual(@as(usize, 4), pos);
}

test "skip_field: egroup is no-op" {
    var pos: usize = 0;
    try skip_field("", &pos, .egroup);
    try testing.expectEqual(@as(usize, 0), pos);
}

test "skip_field: sgroup returns InvalidWireType" {
    var pos: usize = 0;
    try testing.expectError(error.InvalidWireType, skip_field("", &pos, .sgroup));
}

test "skip_field: truncated i32 returns EndOfStream" {
    const data = [_]u8{ 1, 2 };
    var pos: usize = 0;
    try testing.expectError(error.EndOfStream, skip_field(&data, &pos, .i32));
}

test "skip_field: truncated len returns EndOfStream" {
    const data = [_]u8{ 0x05, 'a', 'b' };
    var pos: usize = 0;
    try testing.expectError(error.EndOfStream, skip_field(&data, &pos, .len));
}

// ── skip_group tests ──────────────────────────────────────────────────

test "skip_group: simple group with one varint field" {
    // Inner: field 2 varint 150 (0x10, 0x96, 0x01), then egroup field 1 (0x0C)
    const data = [_]u8{ 0x10, 0x96, 0x01, 0x0C };
    var pos: usize = 0;
    try skip_group(&data, &pos, 1);
    try testing.expectEqual(@as(usize, 4), pos);
}

test "skip_group: nested groups" {
    // Outer group field 1: contains inner sgroup field 2, inner varint field 3, inner egroup field 2, then egroup field 1
    // sgroup field 2: (2 << 3) | 3 = 0x13
    // field 3 varint 1: 0x18, 0x01
    // egroup field 2: (2 << 3) | 4 = 0x14
    // egroup field 1: (1 << 3) | 4 = 0x0C
    const data = [_]u8{ 0x13, 0x18, 0x01, 0x14, 0x0C };
    var pos: usize = 0;
    try skip_group(&data, &pos, 1);
    try testing.expectEqual(@as(usize, 5), pos);
}

test "skip_group: mismatched egroup field number continues" {
    // egroup field 2 (0x14), then field 3 varint 1 (0x18 0x01), then egroup field 1 (0x0C)
    const data = [_]u8{ 0x14, 0x18, 0x01, 0x0C };
    var pos: usize = 0;
    try skip_group(&data, &pos, 1);
    try testing.expectEqual(@as(usize, 4), pos);
}

test "skip_group: no matching egroup returns EndOfStream" {
    // field 2 varint 1, then end of data
    const data = [_]u8{ 0x10, 0x01 };
    var pos: usize = 0;
    try testing.expectError(error.EndOfStream, skip_group(&data, &pos, 1));
}

// ── MessageWriter tests ───────────────────────────────────────────────

test "MessageWriter: write_varint_field" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = MessageWriter.init(&w);
    try mw.write_varint_field(1, 150);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01 }, w.buffered());
}

test "MessageWriter: write_i32_field" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = MessageWriter.init(&w);
    try mw.write_i32_field(3, 42);
    // tag: (3 << 3) | 5 = 29 = 0x1D, value: 42 LE = 0x2A 0x00 0x00 0x00
    try testing.expectEqualSlices(u8, &[_]u8{ 0x1D, 0x2A, 0x00, 0x00, 0x00 }, w.buffered());
}

test "MessageWriter: write_i64_field" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = MessageWriter.init(&w);
    try mw.write_i64_field(1, 1);
    // tag: (1 << 3) | 1 = 0x09, value: 1 LE = 0x01 0x00...
    try testing.expectEqualSlices(u8, &[_]u8{ 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, w.buffered());
}

test "MessageWriter: write_len_field" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = MessageWriter.init(&w);
    try mw.write_len_field(2, "testing");
    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x07, 0x74, 0x65, 0x73, 0x74, 0x69, 0x6e, 0x67 }, w.buffered());
}

test "MessageWriter: write_packed_field same as write_len_field" {
    var buf1: [32]u8 = undefined;
    var w1: std.Io.Writer = .fixed(&buf1);
    const mw1 = MessageWriter.init(&w1);
    try mw1.write_len_field(4, &[_]u8{ 0x01, 0x02, 0x03 });

    var buf2: [32]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    const mw2 = MessageWriter.init(&w2);
    try mw2.write_packed_field(4, &[_]u8{ 0x01, 0x02, 0x03 });

    try testing.expectEqualSlices(u8, w1.buffered(), w2.buffered());
}

test "MessageWriter: write then iterate round-trip" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = MessageWriter.init(&w);
    try mw.write_varint_field(1, 150);
    try mw.write_len_field(2, "hi");
    try mw.write_i32_field(3, 42);
    try mw.write_i64_field(4, 99);

    var iter = iterate_fields(w.buffered());

    const f1 = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 1), f1.number);
    try testing.expectEqual(@as(u64, 150), f1.value.varint);

    const f2 = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 2), f2.number);
    try testing.expectEqualStrings("hi", f2.value.len);

    const f3 = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 3), f3.number);
    try testing.expectEqual(@as(u32, 42), f3.value.i32);

    const f4 = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 4), f4.number);
    try testing.expectEqual(@as(u64, 99), f4.value.i64);

    try testing.expectEqual(@as(?Field, null), try iter.next());
}

// ── PackedVarintIterator tests ────────────────────────────────────────

test "PackedVarintIterator: iterate [150, 1, 0]" {
    // Encode 150, 1, 0 as varints
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encoding.encode_varint(&w, 150);
    try encoding.encode_varint(&w, 1);
    try encoding.encode_varint(&w, 0);

    var iter = PackedVarintIterator.init(w.buffered());
    try testing.expectEqual(@as(u64, 150), (try iter.next()).?);
    try testing.expectEqual(@as(u64, 1), (try iter.next()).?);
    try testing.expectEqual(@as(u64, 0), (try iter.next()).?);
    try testing.expectEqual(@as(?u64, null), try iter.next());
}

test "PackedVarintIterator: empty data" {
    var iter = PackedVarintIterator.init("");
    try testing.expectEqual(@as(?u64, null), try iter.next());
}

test "PackedVarintIterator: truncated varint returns EndOfStream" {
    const data = [_]u8{0x80};
    var iter = PackedVarintIterator.init(&data);
    try testing.expectError(error.EndOfStream, iter.next());
}

// ── PackedFixed32Iterator tests ───────────────────────────────────────

test "PackedFixed32Iterator: iterate [1, 2, 3]" {
    // 3 x u32 LE
    const data = [_]u8{
        0x01, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00,
    };
    var iter = PackedFixed32Iterator.init(&data);
    try testing.expectEqual(@as(u32, 1), (try iter.next()).?);
    try testing.expectEqual(@as(u32, 2), (try iter.next()).?);
    try testing.expectEqual(@as(u32, 3), (try iter.next()).?);
    try testing.expectEqual(@as(?u32, null), try iter.next());
}

test "PackedFixed32Iterator: partial data returns EndOfStream" {
    const data = [_]u8{ 0x01, 0x02 };
    var iter = PackedFixed32Iterator.init(&data);
    try testing.expectError(error.EndOfStream, iter.next());
}

// ── PackedFixed64Iterator tests ───────────────────────────────────────

test "PackedFixed64Iterator: iterate [1, 2]" {
    const data = [_]u8{
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var iter = PackedFixed64Iterator.init(&data);
    try testing.expectEqual(@as(u64, 1), (try iter.next()).?);
    try testing.expectEqual(@as(u64, 2), (try iter.next()).?);
    try testing.expectEqual(@as(?u64, null), try iter.next());
}

test "PackedFixed64Iterator: partial data returns EndOfStream" {
    const data = [_]u8{ 0x01, 0x02, 0x03 };
    var iter = PackedFixed64Iterator.init(&data);
    try testing.expectError(error.EndOfStream, iter.next());
}

// ── Size helper tests ─────────────────────────────────────────────────

test "varint_field_size matches encoded size" {
    const cases = [_]struct { field: u29, value: u64 }{
        .{ .field = 1, .value = 0 },
        .{ .field = 1, .value = 150 },
        .{ .field = 16, .value = 300 },
        .{ .field = 1, .value = std.math.maxInt(u64) },
    };
    for (cases) |c| {
        var buf: [32]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        const mw = MessageWriter.init(&w);
        try mw.write_varint_field(c.field, c.value);
        try testing.expectEqual(w.buffered().len, varint_field_size(c.field, c.value));
    }
}

test "i32_field_size matches encoded size" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = MessageWriter.init(&w);
    try mw.write_i32_field(1, 42);
    try testing.expectEqual(w.buffered().len, i32_field_size(1));
}

test "i64_field_size matches encoded size" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = MessageWriter.init(&w);
    try mw.write_i64_field(1, 99);
    try testing.expectEqual(w.buffered().len, i64_field_size(1));
}

test "len_field_size matches encoded size" {
    const cases = [_]struct { field: u29, data: []const u8 }{
        .{ .field = 1, .data = "" },
        .{ .field = 2, .data = "testing" },
        .{ .field = 16, .data = "hello world" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        const mw = MessageWriter.init(&w);
        try mw.write_len_field(c.field, c.data);
        try testing.expectEqual(w.buffered().len, len_field_size(c.field, c.data.len));
    }
}

// ── Integration tests ─────────────────────────────────────────────────

test "integration: protobuf spec vector field 1 varint 150" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = MessageWriter.init(&w);
    try mw.write_varint_field(1, 150);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01 }, w.buffered());

    var iter = iterate_fields(w.buffered());
    const field = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 1), field.number);
    try testing.expectEqual(@as(u64, 150), field.value.varint);
}

test "integration: nested message" {
    // Inner message: field 1 varint 42
    var inner_buf: [32]u8 = undefined;
    var inner_w: std.Io.Writer = .fixed(&inner_buf);
    const inner_mw = MessageWriter.init(&inner_w);
    try inner_mw.write_varint_field(1, 42);

    // Outer message: field 1 varint 1, field 2 len (inner message)
    var outer_buf: [64]u8 = undefined;
    var outer_w: std.Io.Writer = .fixed(&outer_buf);
    const outer_mw = MessageWriter.init(&outer_w);
    try outer_mw.write_varint_field(1, 1);
    try outer_mw.write_len_field(2, inner_w.buffered());

    // Iterate outer
    var outer_iter = iterate_fields(outer_w.buffered());
    const f1 = (try outer_iter.next()).?;
    try testing.expectEqual(@as(u29, 1), f1.number);
    try testing.expectEqual(@as(u64, 1), f1.value.varint);

    const f2 = (try outer_iter.next()).?;
    try testing.expectEqual(@as(u29, 2), f2.number);

    // Iterate inner from sub-slice
    var inner_iter = iterate_fields(f2.value.len);
    const inner_f1 = (try inner_iter.next()).?;
    try testing.expectEqual(@as(u29, 1), inner_f1.number);
    try testing.expectEqual(@as(u64, 42), inner_f1.value.varint);
    try testing.expectEqual(@as(?Field, null), try inner_iter.next());

    try testing.expectEqual(@as(?Field, null), try outer_iter.next());
}

test "integration: packed repeated varints" {
    // Encode packed varint data: 1, 150, 300
    var packed_buf: [16]u8 = undefined;
    var packed_w: std.Io.Writer = .fixed(&packed_buf);
    try encoding.encode_varint(&packed_w, 1);
    try encoding.encode_varint(&packed_w, 150);
    try encoding.encode_varint(&packed_w, 300);

    // Write as packed field
    var msg_buf: [32]u8 = undefined;
    var msg_w: std.Io.Writer = .fixed(&msg_buf);
    const mw = MessageWriter.init(&msg_w);
    try mw.write_packed_field(4, packed_w.buffered());

    // Iterate outer to get LEN blob
    var iter = iterate_fields(msg_w.buffered());
    const field = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 4), field.number);

    // Iterate packed values
    var packed_iter = PackedVarintIterator.init(field.value.len);
    try testing.expectEqual(@as(u64, 1), (try packed_iter.next()).?);
    try testing.expectEqual(@as(u64, 150), (try packed_iter.next()).?);
    try testing.expectEqual(@as(u64, 300), (try packed_iter.next()).?);
    try testing.expectEqual(@as(?u64, null), try packed_iter.next());
}

test "integration: unknown field skipping" {
    // Write fields 1, 2, 3 — iterate and skip field 2
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = MessageWriter.init(&w);
    try mw.write_varint_field(1, 10);
    try mw.write_len_field(2, "skip me");
    try mw.write_varint_field(3, 30);

    var iter = iterate_fields(w.buffered());

    const f1 = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 1), f1.number);
    try testing.expectEqual(@as(u64, 10), f1.value.varint);

    // Read field 2 but skip it (just ignore the value)
    const f2 = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 2), f2.number);
    // We skip it by simply not processing the len sub-slice

    const f3 = (try iter.next()).?;
    try testing.expectEqual(@as(u29, 3), f3.number);
    try testing.expectEqual(@as(u64, 30), f3.value.varint);

    try testing.expectEqual(@as(?Field, null), try iter.next());
}

test "integration: unknown field skipping with skip_field" {
    // Build message bytes manually, then use skip_field to skip over a field value
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = MessageWriter.init(&w);
    try mw.write_varint_field(1, 10);
    try mw.write_len_field(2, "skip me");
    try mw.write_varint_field(3, 30);
    const data = w.buffered();

    var pos: usize = 0;
    // Read tag 1
    const tag1 = try decode_tag_slice(data, &pos);
    try testing.expectEqual(@as(u29, 1), tag1.field_number);
    // Skip field 1 value
    try skip_field(data, &pos, tag1.wire_type);

    // Read tag 2
    const tag2 = try decode_tag_slice(data, &pos);
    try testing.expectEqual(@as(u29, 2), tag2.field_number);
    // Skip field 2 value
    try skip_field(data, &pos, tag2.wire_type);

    // Read tag 3
    const tag3 = try decode_tag_slice(data, &pos);
    try testing.expectEqual(@as(u29, 3), tag3.field_number);
    try testing.expectEqual(@as(u64, 30), try decode_varint_slice(data, &pos));
}

test "integration: size helpers match MessageWriter output" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = MessageWriter.init(&w);

    try mw.write_varint_field(1, 150);
    try mw.write_i32_field(2, 42);
    try mw.write_i64_field(3, 99);
    try mw.write_len_field(4, "hello");

    const expected_size = varint_field_size(1, 150) +
        i32_field_size(2) +
        i64_field_size(3) +
        len_field_size(4, 5);

    try testing.expectEqual(expected_size, w.buffered().len);
}

test "integration: empty message round-trip" {
    var iter = iterate_fields("");
    try testing.expectEqual(@as(?Field, null), try iter.next());
}
