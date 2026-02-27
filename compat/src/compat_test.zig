const std = @import("std");
const testing = std.testing;
const proto = @import("proto");
const message = @import("protobuf").message;
const encoding = @import("protobuf").encoding;
const framing = @import("framing.zig");

// Each proto file generates its own module (no shared package)
const ScalarMessage = proto.scalar3.ScalarMessage;
const Inner = proto.nested3.Inner;
const Middle = proto.nested3.Middle;
const Outer = proto.nested3.Outer;
const Color = proto.enum3.Color;
const EnumMessage = proto.enum3.EnumMessage;
const OneofMessage = proto.oneof3.OneofMessage;
const SubMsg = proto.oneof3.SubMsg;
const RepeatedMessage = proto.repeated3.RepeatedMessage;
const RepItem = proto.repeated3.RepItem;
const MapMessage = proto.map3.MapMessage;
const MapSubMsg = proto.map3.MapSubMsg;
const OptionalMessage = proto.optional3.OptionalMessage;
const EdgeMessage = proto.edge3.EdgeMessage;
const Scalar2Message = proto.scalar2.Scalar2Message;
const Required2Message = proto.required2.Required2Message;
const AcpMessage = proto.acp.AcpMessage;
const AcpMessageKind = proto.acp.AcpMessageKind;
const AcpStatusCode = proto.acp.AcpStatusCode;
const AcpAssetMetadata = proto.acp.AcpAssetMetadata;

const json = @import("protobuf").json;

// ── Helpers ───────────────────────────────────────────────────────────

fn json_encode(comptime T: type, msg: T) ![]const u8 {
    var buf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try msg.to_json(&w);
    const encoded = w.buffered();
    const result = try testing.allocator.alloc(u8, encoded.len);
    @memcpy(result, encoded);
    return result;
}

fn encode_to_buf(comptime T: type, msg: T) ![]const u8 {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try msg.encode(&w);
    const encoded = w.buffered();
    const result = try testing.allocator.alloc(u8, encoded.len);
    @memcpy(result, encoded);
    return result;
}

fn decode_msg(comptime T: type, data: []const u8) !T {
    return try T.decode(testing.allocator, data);
}

fn write_test_vectors(comptime _: type, cases: anytype, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    for (cases) |tc| {
        var msg_buf: [8192]u8 = undefined;
        var msg_w: std.Io.Writer = .fixed(&msg_buf);
        try tc.msg.encode(&msg_w);
        try framing.write_test_case(&w, tc.name, msg_w.buffered());
    }

    try file.writeAll(w.buffered());
}

fn read_go_vectors(path: []const u8) !?[]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const stat = try file.stat();
    if (stat.size == 0) return null;
    const data = try testing.allocator.alloc(u8, stat.size);
    const n = try file.readAll(data);
    if (n == 0) {
        testing.allocator.free(data);
        return null;
    }
    return data[0..n];
}

// ── Scalar3 Tests ─────────────────────────────────────────────────────

test "scalar3: encode/decode round-trip - all defaults" {
    const msg = ScalarMessage{};
    const data = try encode_to_buf(ScalarMessage, msg);
    defer testing.allocator.free(data);

    try testing.expectEqual(@as(usize, 0), data.len);

    var decoded = try decode_msg(ScalarMessage, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0), decoded.f_double);
    try testing.expectEqual(@as(i32, 0), decoded.f_int32);
    try testing.expectEqual(false, decoded.f_bool);
    try testing.expectEqualStrings("", decoded.f_string);
}

test "scalar3: encode/decode round-trip - all set" {
    const msg = ScalarMessage{
        .f_double = 1.5,
        .f_float = 2.5,
        .f_int32 = 42,
        .f_int64 = 100000,
        .f_uint32 = 200,
        .f_uint64 = 300000,
        .f_sint32 = -10,
        .f_sint64 = -20000,
        .f_fixed32 = 999,
        .f_fixed64 = 888888,
        .f_sfixed32 = -55,
        .f_sfixed64 = -66666,
        .f_bool = true,
        .f_string = "hello",
        .f_bytes = "world",
        .f_large_tag = 77,
    };

    const data = try encode_to_buf(ScalarMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(ScalarMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 1.5), decoded.f_double);
    try testing.expectEqual(@as(f32, 2.5), decoded.f_float);
    try testing.expectEqual(@as(i32, 42), decoded.f_int32);
    try testing.expectEqual(@as(i64, 100000), decoded.f_int64);
    try testing.expectEqual(@as(u32, 200), decoded.f_uint32);
    try testing.expectEqual(@as(u64, 300000), decoded.f_uint64);
    try testing.expectEqual(@as(i32, -10), decoded.f_sint32);
    try testing.expectEqual(@as(i64, -20000), decoded.f_sint64);
    try testing.expectEqual(@as(u32, 999), decoded.f_fixed32);
    try testing.expectEqual(@as(u64, 888888), decoded.f_fixed64);
    try testing.expectEqual(@as(i32, -55), decoded.f_sfixed32);
    try testing.expectEqual(@as(i64, -66666), decoded.f_sfixed64);
    try testing.expectEqual(true, decoded.f_bool);
    try testing.expectEqualStrings("hello", decoded.f_string);
    try testing.expectEqualStrings("world", decoded.f_bytes);
    try testing.expectEqual(@as(i32, 77), decoded.f_large_tag);
}

test "scalar3: max values" {
    const msg = ScalarMessage{
        .f_int32 = std.math.maxInt(i32),
        .f_int64 = std.math.maxInt(i64),
        .f_uint32 = std.math.maxInt(u32),
        .f_uint64 = std.math.maxInt(u64),
        .f_double = 1.7976931348623157e+308,
        .f_string = "a long string value for testing purposes",
    };

    const data = try encode_to_buf(ScalarMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(ScalarMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(std.math.maxInt(i32), decoded.f_int32);
    try testing.expectEqual(std.math.maxInt(i64), decoded.f_int64);
    try testing.expectEqual(std.math.maxInt(u32), decoded.f_uint32);
    try testing.expectEqual(std.math.maxInt(u64), decoded.f_uint64);
}

test "scalar3: min values" {
    const msg = ScalarMessage{
        .f_int32 = std.math.minInt(i32),
        .f_int64 = std.math.minInt(i64),
        .f_double = -1.7976931348623157e+308,
        .f_float = -3.4028235e+38,
    };

    const data = try encode_to_buf(ScalarMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(ScalarMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(std.math.minInt(i32), decoded.f_int32);
    try testing.expectEqual(std.math.minInt(i64), decoded.f_int64);
}

test "scalar3: large tag only" {
    const msg = ScalarMessage{
        .f_large_tag = 12345,
    };

    const data = try encode_to_buf(ScalarMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(ScalarMessage, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 12345), decoded.f_large_tag);
}

// ── Scalar3 Go vector validation ──────────────────────────────────────

test "scalar3: read Go test vectors" {
    const file_data = try read_go_vectors("testdata/go/scalar3.bin");
    if (file_data == null) return;
    defer testing.allocator.free(file_data.?);

    const cases = try framing.read_all_test_cases(testing.allocator, file_data.?);
    defer testing.allocator.free(cases);

    for (cases) |tc| {
        var decoded = try ScalarMessage.decode(testing.allocator, tc.data);
        defer decoded.deinit(testing.allocator);

        if (std.mem.eql(u8, tc.name, "all_defaults")) {
            try testing.expectEqual(@as(f64, 0), decoded.f_double);
            try testing.expectEqual(@as(i32, 0), decoded.f_int32);
            try testing.expectEqual(false, decoded.f_bool);
        } else if (std.mem.eql(u8, tc.name, "all_set")) {
            try testing.expectEqual(@as(f64, 1.5), decoded.f_double);
            try testing.expectEqual(@as(f32, 2.5), decoded.f_float);
            try testing.expectEqual(@as(i32, 42), decoded.f_int32);
            try testing.expectEqual(@as(i64, 100000), decoded.f_int64);
            try testing.expectEqual(@as(u32, 200), decoded.f_uint32);
            try testing.expectEqual(@as(u64, 300000), decoded.f_uint64);
            try testing.expectEqual(@as(i32, -10), decoded.f_sint32);
            try testing.expectEqual(@as(i64, -20000), decoded.f_sint64);
            try testing.expectEqual(@as(u32, 999), decoded.f_fixed32);
            try testing.expectEqual(@as(u64, 888888), decoded.f_fixed64);
            try testing.expectEqual(@as(i32, -55), decoded.f_sfixed32);
            try testing.expectEqual(@as(i64, -66666), decoded.f_sfixed64);
            try testing.expectEqual(true, decoded.f_bool);
            try testing.expectEqualStrings("hello", decoded.f_string);
            try testing.expectEqualStrings("world", decoded.f_bytes);
            try testing.expectEqual(@as(i32, 77), decoded.f_large_tag);
        } else if (std.mem.eql(u8, tc.name, "max_values")) {
            try testing.expectEqual(std.math.maxInt(i32), decoded.f_int32);
            try testing.expectEqual(std.math.maxInt(i64), decoded.f_int64);
            try testing.expectEqual(std.math.maxInt(u32), decoded.f_uint32);
            try testing.expectEqual(std.math.maxInt(u64), decoded.f_uint64);
        } else if (std.mem.eql(u8, tc.name, "min_values")) {
            try testing.expectEqual(std.math.minInt(i32), decoded.f_int32);
            try testing.expectEqual(std.math.minInt(i64), decoded.f_int64);
        } else if (std.mem.eql(u8, tc.name, "large_tag_only")) {
            try testing.expectEqual(@as(i32, 12345), decoded.f_large_tag);
        }
    }
}

test "scalar3: write Zig test vectors" {
    const cases = [_]struct { name: []const u8, msg: ScalarMessage }{
        .{ .name = "all_defaults", .msg = .{} },
        .{ .name = "all_set", .msg = .{
            .f_double = 1.5,
            .f_float = 2.5,
            .f_int32 = 42,
            .f_int64 = 100000,
            .f_uint32 = 200,
            .f_uint64 = 300000,
            .f_sint32 = -10,
            .f_sint64 = -20000,
            .f_fixed32 = 999,
            .f_fixed64 = 888888,
            .f_sfixed32 = -55,
            .f_sfixed64 = -66666,
            .f_bool = true,
            .f_string = "hello",
            .f_bytes = "world",
            .f_large_tag = 77,
        } },
        .{ .name = "max_values", .msg = .{
            .f_int32 = std.math.maxInt(i32),
            .f_int64 = std.math.maxInt(i64),
            .f_uint32 = std.math.maxInt(u32),
            .f_uint64 = std.math.maxInt(u64),
            .f_double = 1.7976931348623157e+308,
            .f_string = "a long string value for testing purposes",
        } },
        .{ .name = "min_values", .msg = .{
            .f_int32 = std.math.minInt(i32),
            .f_int64 = std.math.minInt(i64),
            .f_double = -1.7976931348623157e+308,
            .f_float = -3.4028235e+38,
        } },
        .{ .name = "large_tag_only", .msg = .{
            .f_large_tag = 12345,
        } },
    };

    try write_test_vectors(ScalarMessage, &cases, "testdata/zig/scalar3.bin");
}

// ── Nested3 Tests ─────────────────────────────────────────────────────

test "nested3: encode/decode round-trip - empty" {
    const msg = Outer{};
    const data = try encode_to_buf(Outer, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(Outer, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(?Middle, null), decoded.middle);
    try testing.expectEqual(@as(?Inner, null), decoded.direct_inner);
}

test "nested3: encode/decode round-trip - two levels" {
    const msg = Outer{
        .middle = .{
            .inner = .{ .value = 42, .label = "inner_label" },
            .id = 10,
        },
        .direct_inner = .{ .value = 99, .label = "direct" },
        .name = "outer",
    };

    const data = try encode_to_buf(Outer, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(Outer, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 10), decoded.middle.?.id);
    try testing.expectEqual(@as(i32, 42), decoded.middle.?.inner.?.value);
    try testing.expectEqualStrings("inner_label", decoded.middle.?.inner.?.label);
    try testing.expectEqual(@as(i32, 99), decoded.direct_inner.?.value);
    try testing.expectEqualStrings("direct", decoded.direct_inner.?.label);
    try testing.expectEqualStrings("outer", decoded.name);
}

test "nested3: read Go test vectors" {
    const file_data = try read_go_vectors("testdata/go/nested3.bin");
    if (file_data == null) return;
    defer testing.allocator.free(file_data.?);

    const cases = try framing.read_all_test_cases(testing.allocator, file_data.?);
    defer testing.allocator.free(cases);

    for (cases) |tc| {
        var decoded = try Outer.decode(testing.allocator, tc.data);
        defer decoded.deinit(testing.allocator);

        if (std.mem.eql(u8, tc.name, "empty")) {
            try testing.expectEqual(@as(?Middle, null), decoded.middle);
        } else if (std.mem.eql(u8, tc.name, "two_levels")) {
            try testing.expectEqual(@as(i32, 42), decoded.middle.?.inner.?.value);
            try testing.expectEqual(@as(i32, 10), decoded.middle.?.id);
            try testing.expectEqualStrings("outer", decoded.name);
        } else if (std.mem.eql(u8, tc.name, "single_level")) {
            try testing.expectEqual(@as(?Middle, null), decoded.middle);
            try testing.expectEqual(@as(i32, 5), decoded.direct_inner.?.value);
        }
    }
}

test "nested3: write Zig test vectors" {
    const cases = [_]struct { name: []const u8, msg: Outer }{
        .{ .name = "empty", .msg = .{} },
        .{ .name = "two_levels", .msg = .{
            .middle = .{
                .inner = .{ .value = 42, .label = "inner_label" },
                .id = 10,
            },
            .direct_inner = .{ .value = 99, .label = "direct" },
            .name = "outer",
        } },
        .{ .name = "single_level", .msg = .{
            .direct_inner = .{ .value = 5, .label = "only" },
        } },
    };

    try write_test_vectors(Outer, &cases, "testdata/zig/nested3.bin");
}

// ── Enum3 Tests ───────────────────────────────────────────────────────

test "enum3: encode/decode round-trip - default" {
    const msg = EnumMessage{};
    const data = try encode_to_buf(EnumMessage, msg);
    defer testing.allocator.free(data);

    // Default enum value is 0, which is skipped in proto3 implicit
    try testing.expectEqual(@as(usize, 0), data.len);

    var decoded = try decode_msg(EnumMessage, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(Color.COLOR_UNSPECIFIED, decoded.color);
    try testing.expectEqual(@as(usize, 0), decoded.colors.len);
    try testing.expectEqualStrings("", decoded.name);
}

test "enum3: encode/decode round-trip - non-default" {
    const msg = EnumMessage{
        .color = .COLOR_RED,
        .name = "test",
    };

    const data = try encode_to_buf(EnumMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(EnumMessage, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(Color.COLOR_RED, decoded.color);
    try testing.expectEqualStrings("test", decoded.name);
}

test "enum3: encode/decode round-trip - repeated enums" {
    // Create repeated enum values
    const colors = &[_]Color{ .COLOR_RED, .COLOR_GREEN, .COLOR_BLUE };
    const msg = EnumMessage{
        .color = .COLOR_BLUE,
        .colors = colors,
        .name = "multi",
    };

    const data = try encode_to_buf(EnumMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(EnumMessage, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(Color.COLOR_BLUE, decoded.color);
    try testing.expectEqual(@as(usize, 3), decoded.colors.len);
    try testing.expectEqual(Color.COLOR_RED, decoded.colors[0]);
    try testing.expectEqual(Color.COLOR_GREEN, decoded.colors[1]);
    try testing.expectEqual(Color.COLOR_BLUE, decoded.colors[2]);
    try testing.expectEqualStrings("multi", decoded.name);
}

test "enum3: read Go test vectors" {
    const file_data = try read_go_vectors("testdata/go/enum3.bin");
    if (file_data == null) return;
    defer testing.allocator.free(file_data.?);

    const cases = try framing.read_all_test_cases(testing.allocator, file_data.?);
    defer testing.allocator.free(cases);

    for (cases) |tc| {
        var decoded = try EnumMessage.decode(testing.allocator, tc.data);
        defer decoded.deinit(testing.allocator);

        if (std.mem.eql(u8, tc.name, "default")) {
            try testing.expectEqual(Color.COLOR_UNSPECIFIED, decoded.color);
        } else if (std.mem.eql(u8, tc.name, "red")) {
            try testing.expectEqual(Color.COLOR_RED, decoded.color);
        } else if (std.mem.eql(u8, tc.name, "repeated")) {
            try testing.expectEqual(@as(usize, 3), decoded.colors.len);
        }
    }
}

test "enum3: write Zig test vectors" {
    const colors = &[_]Color{ .COLOR_RED, .COLOR_GREEN, .COLOR_BLUE };
    const cases = [_]struct { name: []const u8, msg: EnumMessage }{
        .{ .name = "default", .msg = .{} },
        .{ .name = "red", .msg = .{ .color = .COLOR_RED, .name = "red_test" } },
        .{ .name = "repeated", .msg = .{ .color = .COLOR_BLUE, .colors = colors, .name = "multi" } },
    };

    try write_test_vectors(EnumMessage, &cases, "testdata/zig/enum3.bin");
}

// ── Oneof3 Tests ──────────────────────────────────────────────────────

test "oneof3: encode/decode round-trip - string variant" {
    const msg = OneofMessage{
        .name = "test",
        .value = .{ .str_val = "hello" },
    };

    const data = try encode_to_buf(OneofMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(OneofMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqualStrings("test", decoded.name);
    try testing.expectEqualStrings("hello", decoded.value.?.str_val);
}

test "oneof3: encode/decode round-trip - int variant" {
    const msg = OneofMessage{
        .name = "int_test",
        .value = .{ .int_val = 42 },
    };

    const data = try encode_to_buf(OneofMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(OneofMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 42), decoded.value.?.int_val);
}

test "oneof3: encode/decode round-trip - msg variant" {
    const msg = OneofMessage{
        .name = "msg_test",
        .value = .{ .msg_val = .{ .id = 1, .text = "sub" } },
    };

    const data = try encode_to_buf(OneofMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(OneofMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 1), decoded.value.?.msg_val.id);
    try testing.expectEqualStrings("sub", decoded.value.?.msg_val.text);
}

test "oneof3: read Go test vectors" {
    const file_data = try read_go_vectors("testdata/go/oneof3.bin");
    if (file_data == null) return;
    defer testing.allocator.free(file_data.?);

    const cases = try framing.read_all_test_cases(testing.allocator, file_data.?);
    defer testing.allocator.free(cases);

    for (cases) |tc| {
        var decoded = try OneofMessage.decode(testing.allocator, tc.data);
        defer decoded.deinit(testing.allocator);

        if (std.mem.eql(u8, tc.name, "none_set")) {
            try testing.expectEqual(@as(?OneofMessage.Value, null), decoded.value);
        } else if (std.mem.eql(u8, tc.name, "string_variant")) {
            try testing.expectEqualStrings("hello", decoded.value.?.str_val);
        } else if (std.mem.eql(u8, tc.name, "int_variant")) {
            try testing.expectEqual(@as(i32, 42), decoded.value.?.int_val);
        } else if (std.mem.eql(u8, tc.name, "msg_variant")) {
            try testing.expectEqual(@as(i32, 1), decoded.value.?.msg_val.id);
        }
    }
}

test "oneof3: write Zig test vectors" {
    const cases = [_]struct { name: []const u8, msg: OneofMessage }{
        .{ .name = "none_set", .msg = .{ .name = "empty" } },
        .{ .name = "string_variant", .msg = .{ .name = "test", .value = .{ .str_val = "hello" } } },
        .{ .name = "int_variant", .msg = .{ .name = "test", .value = .{ .int_val = 42 } } },
        .{ .name = "bytes_variant", .msg = .{ .name = "test", .value = .{ .bytes_val = "\x01\x02\x03" } } },
        .{ .name = "msg_variant", .msg = .{ .name = "test", .value = .{ .msg_val = .{ .id = 1, .text = "sub" } } } },
    };

    try write_test_vectors(OneofMessage, &cases, "testdata/zig/oneof3.bin");
}

// ── Repeated3 Tests ───────────────────────────────────────────────────

test "repeated3: encode/decode round-trip - empty" {
    const msg = RepeatedMessage{};
    const data = try encode_to_buf(RepeatedMessage, msg);
    defer testing.allocator.free(data);

    try testing.expectEqual(@as(usize, 0), data.len);

    var decoded = try decode_msg(RepeatedMessage, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), decoded.ints.len);
    try testing.expectEqual(@as(usize, 0), decoded.strings.len);
    try testing.expectEqual(@as(usize, 0), decoded.doubles.len);
    try testing.expectEqual(@as(usize, 0), decoded.bools.len);
    try testing.expectEqual(@as(usize, 0), decoded.byte_slices.len);
    try testing.expectEqual(@as(usize, 0), decoded.items.len);
}

test "repeated3: encode/decode round-trip - single" {
    const items = &[_]RepItem{.{ .id = 1, .name = "first" }};
    const msg = RepeatedMessage{
        .ints = &.{1},
        .strings = &.{"hello"},
        .doubles = &.{1.5},
        .bools = &.{true},
        .byte_slices = &.{"\x01"},
        .items = items,
    };

    const data = try encode_to_buf(RepeatedMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(RepeatedMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), decoded.ints.len);
    try testing.expectEqual(@as(i32, 1), decoded.ints[0]);
    try testing.expectEqual(@as(usize, 1), decoded.strings.len);
    try testing.expectEqualStrings("hello", decoded.strings[0]);
    try testing.expectEqual(@as(usize, 1), decoded.doubles.len);
    try testing.expectEqual(@as(f64, 1.5), decoded.doubles[0]);
    try testing.expectEqual(@as(usize, 1), decoded.bools.len);
    try testing.expectEqual(true, decoded.bools[0]);
    try testing.expectEqual(@as(usize, 1), decoded.byte_slices.len);
    try testing.expectEqualSlices(u8, "\x01", decoded.byte_slices[0]);
    try testing.expectEqual(@as(usize, 1), decoded.items.len);
    try testing.expectEqual(@as(i32, 1), decoded.items[0].id);
    try testing.expectEqualStrings("first", decoded.items[0].name);
}

test "repeated3: encode/decode round-trip - multiple" {
    const items = &[_]RepItem{
        .{ .id = 1, .name = "one" },
        .{ .id = 2, .name = "two" },
    };
    const msg = RepeatedMessage{
        .ints = &.{ 1, 2, 3 },
        .strings = &.{ "a", "b", "c" },
        .doubles = &.{ 1.1, 2.2, 3.3 },
        .bools = &.{ true, false, true },
        .byte_slices = &.{ "\x01", "\x02" },
        .items = items,
    };

    const data = try encode_to_buf(RepeatedMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(RepeatedMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), decoded.ints.len);
    try testing.expectEqual(@as(i32, 1), decoded.ints[0]);
    try testing.expectEqual(@as(i32, 2), decoded.ints[1]);
    try testing.expectEqual(@as(i32, 3), decoded.ints[2]);
    try testing.expectEqual(@as(usize, 3), decoded.strings.len);
    try testing.expectEqualStrings("a", decoded.strings[0]);
    try testing.expectEqualStrings("b", decoded.strings[1]);
    try testing.expectEqualStrings("c", decoded.strings[2]);
    try testing.expectEqual(@as(usize, 3), decoded.doubles.len);
    try testing.expectEqual(@as(usize, 3), decoded.bools.len);
    try testing.expectEqual(true, decoded.bools[0]);
    try testing.expectEqual(false, decoded.bools[1]);
    try testing.expectEqual(true, decoded.bools[2]);
    try testing.expectEqual(@as(usize, 2), decoded.byte_slices.len);
    try testing.expectEqual(@as(usize, 2), decoded.items.len);
    try testing.expectEqual(@as(i32, 1), decoded.items[0].id);
    try testing.expectEqualStrings("one", decoded.items[0].name);
    try testing.expectEqual(@as(i32, 2), decoded.items[1].id);
    try testing.expectEqualStrings("two", decoded.items[1].name);
}

test "repeated3: read Go test vectors" {
    const file_data = try read_go_vectors("testdata/go/repeated3.bin");
    if (file_data == null) return;
    defer testing.allocator.free(file_data.?);

    const cases = try framing.read_all_test_cases(testing.allocator, file_data.?);
    defer testing.allocator.free(cases);

    for (cases) |tc| {
        var decoded = try RepeatedMessage.decode(testing.allocator, tc.data);
        defer decoded.deinit(testing.allocator);

        if (std.mem.eql(u8, tc.name, "empty")) {
            try testing.expectEqual(@as(usize, 0), decoded.ints.len);
            try testing.expectEqual(@as(usize, 0), decoded.strings.len);
            try testing.expectEqual(@as(usize, 0), decoded.items.len);
        } else if (std.mem.eql(u8, tc.name, "single")) {
            try testing.expectEqual(@as(usize, 1), decoded.ints.len);
            try testing.expectEqual(@as(i32, 1), decoded.ints[0]);
            try testing.expectEqual(@as(usize, 1), decoded.strings.len);
            try testing.expectEqualStrings("hello", decoded.strings[0]);
            try testing.expectEqual(@as(usize, 1), decoded.doubles.len);
            try testing.expectEqual(@as(f64, 1.5), decoded.doubles[0]);
            try testing.expectEqual(@as(usize, 1), decoded.bools.len);
            try testing.expectEqual(true, decoded.bools[0]);
            try testing.expectEqual(@as(usize, 1), decoded.byte_slices.len);
            try testing.expectEqualSlices(u8, "\x01", decoded.byte_slices[0]);
            try testing.expectEqual(@as(usize, 1), decoded.items.len);
            try testing.expectEqual(@as(i32, 1), decoded.items[0].id);
            try testing.expectEqualStrings("first", decoded.items[0].name);
        } else if (std.mem.eql(u8, tc.name, "multiple")) {
            try testing.expectEqual(@as(usize, 3), decoded.ints.len);
            try testing.expectEqual(@as(usize, 3), decoded.strings.len);
            try testing.expectEqual(@as(usize, 2), decoded.items.len);
        }
    }
}

test "repeated3: write Zig test vectors" {
    const single_items = &[_]RepItem{.{ .id = 1, .name = "first" }};
    const multi_items = &[_]RepItem{
        .{ .id = 1, .name = "one" },
        .{ .id = 2, .name = "two" },
    };
    const cases = [_]struct { name: []const u8, msg: RepeatedMessage }{
        .{ .name = "empty", .msg = .{} },
        .{ .name = "single", .msg = .{
            .ints = &.{1},
            .strings = &.{"hello"},
            .doubles = &.{1.5},
            .bools = &.{true},
            .byte_slices = &.{"\x01"},
            .items = single_items,
        } },
        .{ .name = "multiple", .msg = .{
            .ints = &.{ 1, 2, 3 },
            .strings = &.{ "a", "b", "c" },
            .doubles = &.{ 1.1, 2.2, 3.3 },
            .bools = &.{ true, false, true },
            .byte_slices = &.{ "\x01", "\x02" },
            .items = multi_items,
        } },
    };

    try write_test_vectors(RepeatedMessage, &cases, "testdata/zig/repeated3.bin");
}

// ── Map3 Tests ────────────────────────────────────────────────────────

test "map3: encode/decode round-trip - empty" {
    const msg = MapMessage{};
    const data = try encode_to_buf(MapMessage, msg);
    defer testing.allocator.free(data);

    try testing.expectEqual(@as(usize, 0), data.len);

    var decoded = try decode_msg(MapMessage, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), decoded.str_str.count());
    try testing.expectEqual(@as(usize, 0), decoded.int_str.count());
    try testing.expectEqual(@as(usize, 0), decoded.str_msg.count());
}

test "map3: encode/decode round-trip - single" {
    var str_str: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer str_str.deinit(testing.allocator);
    try str_str.put(testing.allocator, "key", "val");

    var int_str: std.AutoArrayHashMapUnmanaged(i32, []const u8) = .empty;
    defer int_str.deinit(testing.allocator);
    try int_str.put(testing.allocator, 1, "one");

    var str_msg: std.StringArrayHashMapUnmanaged(MapSubMsg) = .empty;
    defer str_msg.deinit(testing.allocator);
    try str_msg.put(testing.allocator, "a", .{ .id = 1, .text = "alpha" });

    const msg = MapMessage{
        .str_str = str_str,
        .int_str = int_str,
        .str_msg = str_msg,
    };

    const data = try encode_to_buf(MapMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(MapMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), decoded.str_str.count());
    try testing.expectEqualStrings("val", decoded.str_str.get("key").?);
    try testing.expectEqual(@as(usize, 1), decoded.int_str.count());
    try testing.expectEqualStrings("one", decoded.int_str.get(1).?);
    try testing.expectEqual(@as(usize, 1), decoded.str_msg.count());
    const sub = decoded.str_msg.get("a").?;
    try testing.expectEqual(@as(i32, 1), sub.id);
    try testing.expectEqualStrings("alpha", sub.text);
}

test "map3: encode/decode round-trip - multiple" {
    var str_str: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer str_str.deinit(testing.allocator);
    try str_str.put(testing.allocator, "a", "1");
    try str_str.put(testing.allocator, "b", "2");

    var int_str: std.AutoArrayHashMapUnmanaged(i32, []const u8) = .empty;
    defer int_str.deinit(testing.allocator);
    try int_str.put(testing.allocator, 1, "one");
    try int_str.put(testing.allocator, 2, "two");

    var str_msg: std.StringArrayHashMapUnmanaged(MapSubMsg) = .empty;
    defer str_msg.deinit(testing.allocator);
    try str_msg.put(testing.allocator, "x", .{ .id = 10, .text = "x" });
    try str_msg.put(testing.allocator, "y", .{ .id = 20, .text = "y" });

    const msg = MapMessage{
        .str_str = str_str,
        .int_str = int_str,
        .str_msg = str_msg,
    };

    const data = try encode_to_buf(MapMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(MapMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), decoded.str_str.count());
    try testing.expectEqualStrings("1", decoded.str_str.get("a").?);
    try testing.expectEqualStrings("2", decoded.str_str.get("b").?);
    try testing.expectEqual(@as(usize, 2), decoded.int_str.count());
    try testing.expectEqualStrings("one", decoded.int_str.get(1).?);
    try testing.expectEqualStrings("two", decoded.int_str.get(2).?);
    try testing.expectEqual(@as(usize, 2), decoded.str_msg.count());
    const sub_x = decoded.str_msg.get("x").?;
    try testing.expectEqual(@as(i32, 10), sub_x.id);
    try testing.expectEqualStrings("x", sub_x.text);
    const sub_y = decoded.str_msg.get("y").?;
    try testing.expectEqual(@as(i32, 20), sub_y.id);
    try testing.expectEqualStrings("y", sub_y.text);
}

test "map3: read Go test vectors" {
    const file_data = try read_go_vectors("testdata/go/map3.bin");
    if (file_data == null) return;
    defer testing.allocator.free(file_data.?);

    const cases = try framing.read_all_test_cases(testing.allocator, file_data.?);
    defer testing.allocator.free(cases);

    for (cases) |tc| {
        var decoded = try MapMessage.decode(testing.allocator, tc.data);
        defer decoded.deinit(testing.allocator);

        if (std.mem.eql(u8, tc.name, "empty")) {
            try testing.expectEqual(@as(usize, 0), decoded.str_str.count());
            try testing.expectEqual(@as(usize, 0), decoded.int_str.count());
            try testing.expectEqual(@as(usize, 0), decoded.str_msg.count());
        } else if (std.mem.eql(u8, tc.name, "single")) {
            try testing.expectEqual(@as(usize, 1), decoded.str_str.count());
            try testing.expectEqualStrings("val", decoded.str_str.get("key").?);
            try testing.expectEqual(@as(usize, 1), decoded.int_str.count());
            try testing.expectEqualStrings("one", decoded.int_str.get(1).?);
            try testing.expectEqual(@as(usize, 1), decoded.str_msg.count());
            const sub = decoded.str_msg.get("a").?;
            try testing.expectEqual(@as(i32, 1), sub.id);
            try testing.expectEqualStrings("alpha", sub.text);
        } else if (std.mem.eql(u8, tc.name, "multiple")) {
            try testing.expectEqual(@as(usize, 2), decoded.str_str.count());
            try testing.expectEqualStrings("1", decoded.str_str.get("a").?);
            try testing.expectEqualStrings("2", decoded.str_str.get("b").?);
            try testing.expectEqual(@as(usize, 2), decoded.int_str.count());
            try testing.expectEqualStrings("one", decoded.int_str.get(1).?);
            try testing.expectEqualStrings("two", decoded.int_str.get(2).?);
            try testing.expectEqual(@as(usize, 2), decoded.str_msg.count());
            const sub_x = decoded.str_msg.get("x").?;
            try testing.expectEqual(@as(i32, 10), sub_x.id);
            const sub_y = decoded.str_msg.get("y").?;
            try testing.expectEqual(@as(i32, 20), sub_y.id);
        }
    }
}

test "map3: write Zig test vectors" {
    // We can't use struct literal initialization for maps with putAssumeCapacity
    // since the maps need runtime capacity. Instead, encode manually.
    // For the write_test_vectors helper, we need to build messages with maps.
    // Since maps are non-owning and default empty, we use the encode path directly.
    if (std.fs.path.dirname("testdata/zig/map3.bin")) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    var file = try std.fs.cwd().createFile("testdata/zig/map3.bin", .{});
    defer file.close();

    var buf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // empty
    {
        const msg = MapMessage{};
        var msg_buf: [8192]u8 = undefined;
        var msg_w: std.Io.Writer = .fixed(&msg_buf);
        try msg.encode(&msg_w);
        try framing.write_test_case(&w, "empty", msg_w.buffered());
    }

    // single
    {
        var str_str: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        defer str_str.deinit(testing.allocator);
        try str_str.put(testing.allocator, "key", "val");
        var int_str: std.AutoArrayHashMapUnmanaged(i32, []const u8) = .empty;
        defer int_str.deinit(testing.allocator);
        try int_str.put(testing.allocator, 1, "one");
        var str_msg: std.StringArrayHashMapUnmanaged(MapSubMsg) = .empty;
        defer str_msg.deinit(testing.allocator);
        try str_msg.put(testing.allocator, "a", .{ .id = 1, .text = "alpha" });
        const msg = MapMessage{
            .str_str = str_str,
            .int_str = int_str,
            .str_msg = str_msg,
        };
        var msg_buf: [8192]u8 = undefined;
        var msg_w: std.Io.Writer = .fixed(&msg_buf);
        try msg.encode(&msg_w);
        try framing.write_test_case(&w, "single", msg_w.buffered());
    }

    // multiple
    {
        var str_str: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        defer str_str.deinit(testing.allocator);
        try str_str.put(testing.allocator, "a", "1");
        try str_str.put(testing.allocator, "b", "2");
        var int_str: std.AutoArrayHashMapUnmanaged(i32, []const u8) = .empty;
        defer int_str.deinit(testing.allocator);
        try int_str.put(testing.allocator, 1, "one");
        try int_str.put(testing.allocator, 2, "two");
        var str_msg: std.StringArrayHashMapUnmanaged(MapSubMsg) = .empty;
        defer str_msg.deinit(testing.allocator);
        try str_msg.put(testing.allocator, "x", .{ .id = 10, .text = "x" });
        try str_msg.put(testing.allocator, "y", .{ .id = 20, .text = "y" });
        const msg = MapMessage{
            .str_str = str_str,
            .int_str = int_str,
            .str_msg = str_msg,
        };
        var msg_buf: [8192]u8 = undefined;
        var msg_w: std.Io.Writer = .fixed(&msg_buf);
        try msg.encode(&msg_w);
        try framing.write_test_case(&w, "multiple", msg_w.buffered());
    }

    try file.writeAll(w.buffered());
}

// ── Optional3 Tests ───────────────────────────────────────────────────

test "optional3: encode/decode round-trip - all unset" {
    const msg = OptionalMessage{};
    const data = try encode_to_buf(OptionalMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(OptionalMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(?i32, null), decoded.opt_int);
    try testing.expectEqual(@as(?[]const u8, null), decoded.opt_str);
    try testing.expectEqual(@as(?bool, null), decoded.opt_bool);
    try testing.expectEqual(@as(?f64, null), decoded.opt_double);
    try testing.expectEqual(@as(i32, 0), decoded.regular_int);
}

test "optional3: encode/decode round-trip - all zero" {
    const msg = OptionalMessage{
        .opt_int = 0,
        .opt_str = "",
        .opt_bool = false,
        .opt_double = 0.0,
        .regular_int = 0,
    };

    const data = try encode_to_buf(OptionalMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(OptionalMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(?i32, 0), decoded.opt_int);
    try testing.expectEqual(@as(?bool, false), decoded.opt_bool);
    try testing.expectEqual(@as(?f64, 0.0), decoded.opt_double);
}

test "optional3: read Go test vectors" {
    const file_data = try read_go_vectors("testdata/go/optional3.bin");
    if (file_data == null) return;
    defer testing.allocator.free(file_data.?);

    const cases = try framing.read_all_test_cases(testing.allocator, file_data.?);
    defer testing.allocator.free(cases);

    for (cases) |tc| {
        var decoded = try OptionalMessage.decode(testing.allocator, tc.data);
        defer decoded.deinit(testing.allocator);

        if (std.mem.eql(u8, tc.name, "all_unset")) {
            try testing.expectEqual(@as(?i32, null), decoded.opt_int);
            try testing.expectEqual(@as(?[]const u8, null), decoded.opt_str);
        } else if (std.mem.eql(u8, tc.name, "all_zero")) {
            try testing.expectEqual(@as(?i32, 0), decoded.opt_int);
            try testing.expectEqual(@as(?bool, false), decoded.opt_bool);
        } else if (std.mem.eql(u8, tc.name, "all_nonzero")) {
            try testing.expectEqual(@as(?i32, 42), decoded.opt_int);
            try testing.expectEqual(@as(?bool, true), decoded.opt_bool);
        }
    }
}

test "optional3: write Zig test vectors" {
    const cases = [_]struct { name: []const u8, msg: OptionalMessage }{
        .{ .name = "all_unset", .msg = .{} },
        .{ .name = "all_zero", .msg = .{
            .opt_int = 0,
            .opt_str = "",
            .opt_bool = false,
            .opt_double = 0.0,
        } },
        .{ .name = "all_nonzero", .msg = .{
            .opt_int = 42,
            .opt_str = "hello",
            .opt_bool = true,
            .opt_double = 3.14,
            .regular_int = 100,
        } },
    };

    try write_test_vectors(OptionalMessage, &cases, "testdata/zig/optional3.bin");
}

// ── Edge3 Tests ───────────────────────────────────────────────────────

test "edge3: encode/decode round-trip" {
    const msg = EdgeMessage{
        .f_nan = std.math.nan(f64),
        .f_pos_inf = std.math.inf(f64),
        .f_neg_inf = -std.math.inf(f64),
        .f_max_int32 = std.math.maxInt(i32),
        .f_min_int32 = std.math.minInt(i32),
        .f_max_int64 = std.math.maxInt(i64),
        .f_min_int64 = std.math.minInt(i64),
        .f_max_uint32 = std.math.maxInt(u32),
        .f_max_uint64 = std.math.maxInt(u64),
        .f_unicode = "hello \xc3\xa9\xc3\xa0\xc3\xbc \xe4\xb8\x96\xe7\x95\x8c",
        .f_binary = "\x00\x01\x02\xff\xfe\xfd",
        .f_empty_str = "",
        .f_empty_bytes = "",
    };

    const data = try encode_to_buf(EdgeMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(EdgeMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expect(std.math.isNan(decoded.f_nan));
    try testing.expect(std.math.isInf(decoded.f_pos_inf));
    try testing.expectEqual(-std.math.inf(f64), decoded.f_neg_inf);
    try testing.expectEqual(std.math.maxInt(i32), decoded.f_max_int32);
    try testing.expectEqual(std.math.minInt(i32), decoded.f_min_int32);
    try testing.expectEqual(std.math.maxInt(i64), decoded.f_max_int64);
    try testing.expectEqual(std.math.minInt(i64), decoded.f_min_int64);
    try testing.expectEqual(std.math.maxInt(u32), decoded.f_max_uint32);
    try testing.expectEqual(std.math.maxInt(u64), decoded.f_max_uint64);
    try testing.expectEqualStrings("hello \xc3\xa9\xc3\xa0\xc3\xbc \xe4\xb8\x96\xe7\x95\x8c", decoded.f_unicode);
    try testing.expectEqualSlices(u8, "\x00\x01\x02\xff\xfe\xfd", decoded.f_binary);
}

test "edge3: read Go test vectors" {
    const file_data = try read_go_vectors("testdata/go/edge3.bin");
    if (file_data == null) return;
    defer testing.allocator.free(file_data.?);

    const cases = try framing.read_all_test_cases(testing.allocator, file_data.?);
    defer testing.allocator.free(cases);

    for (cases) |tc| {
        var decoded = try EdgeMessage.decode(testing.allocator, tc.data);
        defer decoded.deinit(testing.allocator);

        if (std.mem.eql(u8, tc.name, "special_floats")) {
            try testing.expect(std.math.isNan(decoded.f_nan));
            try testing.expect(std.math.isInf(decoded.f_pos_inf));
            try testing.expectEqual(-std.math.inf(f64), decoded.f_neg_inf);
        } else if (std.mem.eql(u8, tc.name, "extreme_ints")) {
            try testing.expectEqual(std.math.maxInt(i32), decoded.f_max_int32);
            try testing.expectEqual(std.math.minInt(i32), decoded.f_min_int32);
            try testing.expectEqual(std.math.maxInt(i64), decoded.f_max_int64);
            try testing.expectEqual(std.math.minInt(i64), decoded.f_min_int64);
            try testing.expectEqual(std.math.maxInt(u32), decoded.f_max_uint32);
            try testing.expectEqual(std.math.maxInt(u64), decoded.f_max_uint64);
        }
    }
}

test "edge3: write Zig test vectors" {
    const cases = [_]struct { name: []const u8, msg: EdgeMessage }{
        .{ .name = "special_floats", .msg = .{
            .f_nan = std.math.nan(f64),
            .f_pos_inf = std.math.inf(f64),
            .f_neg_inf = -std.math.inf(f64),
        } },
        .{ .name = "extreme_ints", .msg = .{
            .f_max_int32 = std.math.maxInt(i32),
            .f_min_int32 = std.math.minInt(i32),
            .f_max_int64 = std.math.maxInt(i64),
            .f_min_int64 = std.math.minInt(i64),
            .f_max_uint32 = std.math.maxInt(u32),
            .f_max_uint64 = std.math.maxInt(u64),
        } },
        .{ .name = "unicode_and_binary", .msg = .{
            .f_unicode = "hello \xc3\xa9\xc3\xa0\xc3\xbc \xe4\xb8\x96\xe7\x95\x8c",
            .f_binary = "\x00\x01\x02\xff\xfe\xfd",
        } },
    };

    try write_test_vectors(EdgeMessage, &cases, "testdata/zig/edge3.bin");
}

// ── Scalar2 Tests ─────────────────────────────────────────────────────

test "scalar2: encode/decode round-trip" {
    const msg = Scalar2Message{
        .f_double = 1.5,
        .f_int32 = 42,
        .f_string = "hello",
        .f_bool = true,
    };

    const data = try encode_to_buf(Scalar2Message, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(Scalar2Message, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(?f64, 1.5), decoded.f_double);
    try testing.expectEqual(@as(?i32, 42), decoded.f_int32);
    try testing.expectEqualStrings("hello", decoded.f_string.?);
    try testing.expectEqual(@as(?bool, true), decoded.f_bool);
}

test "scalar2: read Go test vectors" {
    const file_data = try read_go_vectors("testdata/go/scalar2.bin");
    if (file_data == null) return;
    defer testing.allocator.free(file_data.?);

    const cases = try framing.read_all_test_cases(testing.allocator, file_data.?);
    defer testing.allocator.free(cases);

    for (cases) |tc| {
        var decoded = try Scalar2Message.decode(testing.allocator, tc.data);
        defer decoded.deinit(testing.allocator);

        if (std.mem.eql(u8, tc.name, "all_set")) {
            try testing.expectEqual(@as(?f64, 1.5), decoded.f_double);
            try testing.expectEqual(@as(?i32, 42), decoded.f_int32);
            try testing.expectEqual(@as(?bool, true), decoded.f_bool);
        } else if (std.mem.eql(u8, tc.name, "all_absent")) {
            try testing.expectEqual(@as(?f64, null), decoded.f_double);
            try testing.expectEqual(@as(?i32, null), decoded.f_int32);
        }
    }
}

test "scalar2: write Zig test vectors" {
    const cases = [_]struct { name: []const u8, msg: Scalar2Message }{
        .{ .name = "all_absent", .msg = .{} },
        .{ .name = "all_set", .msg = .{
            .f_double = 1.5,
            .f_float = 2.5,
            .f_int32 = 42,
            .f_int64 = 100000,
            .f_uint32 = 200,
            .f_uint64 = 300000,
            .f_sint32 = -10,
            .f_sint64 = -20000,
            .f_fixed32 = 999,
            .f_fixed64 = 888888,
            .f_sfixed32 = -55,
            .f_sfixed64 = -66666,
            .f_bool = true,
            .f_string = "hello",
            .f_bytes = "world",
        } },
    };

    try write_test_vectors(Scalar2Message, &cases, "testdata/zig/scalar2.bin");
}

// ── Required2 Tests ───────────────────────────────────────────────────

test "required2: encode/decode round-trip" {
    const msg = Required2Message{
        .req_id = 42,
        .req_name = "required",
        .opt_value = 10,
        .opt_label = "optional",
    };

    const data = try encode_to_buf(Required2Message, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(Required2Message, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 42), decoded.req_id);
    try testing.expectEqualStrings("required", decoded.req_name);
    try testing.expectEqual(@as(?i32, 10), decoded.opt_value);
    try testing.expectEqualStrings("optional", decoded.opt_label.?);
}

test "required2: read Go test vectors" {
    const file_data = try read_go_vectors("testdata/go/required2.bin");
    if (file_data == null) return;
    defer testing.allocator.free(file_data.?);

    const cases = try framing.read_all_test_cases(testing.allocator, file_data.?);
    defer testing.allocator.free(cases);

    for (cases) |tc| {
        var decoded = try Required2Message.decode(testing.allocator, tc.data);
        defer decoded.deinit(testing.allocator);

        if (std.mem.eql(u8, tc.name, "all_present")) {
            try testing.expectEqual(@as(i32, 42), decoded.req_id);
            try testing.expectEqualStrings("required", decoded.req_name);
            try testing.expectEqual(@as(?i32, 10), decoded.opt_value);
        } else if (std.mem.eql(u8, tc.name, "required_only")) {
            try testing.expectEqual(@as(i32, 1), decoded.req_id);
            try testing.expectEqualStrings("min", decoded.req_name);
            try testing.expectEqual(@as(?i32, null), decoded.opt_value);
        }
    }
}

test "required2: write Zig test vectors" {
    const cases = [_]struct { name: []const u8, msg: Required2Message }{
        .{ .name = "all_present", .msg = .{
            .req_id = 42,
            .req_name = "required",
            .opt_value = 10,
            .opt_label = "optional",
        } },
        .{ .name = "required_only", .msg = .{
            .req_id = 1,
            .req_name = "min",
        } },
    };

    try write_test_vectors(Required2Message, &cases, "testdata/zig/required2.bin");
}

// ── ACP Tests ─────────────────────────────────────────────────────────

test "acp: encode/decode round-trip - empty" {
    const msg = AcpMessage{};
    const data = try encode_to_buf(AcpMessage, msg);
    defer testing.allocator.free(data);

    try testing.expectEqual(@as(usize, 0), data.len);

    var decoded = try decode_msg(AcpMessage, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, null), decoded.version);
    try testing.expectEqual(@as(AcpMessageKind, @enumFromInt(0)), decoded.kind);
    try testing.expectEqual(@as(u64, 0), decoded.request_id);
    try testing.expectEqual(@as(?[]const u8, null), decoded.uri);
}

test "acp: encode/decode round-trip - hello" {
    const msg = AcpMessage{
        .version = 1,
        .kind = .HELLO,
    };
    const data = try encode_to_buf(AcpMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(AcpMessage, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 1), decoded.version);
    try testing.expectEqual(AcpMessageKind.HELLO, decoded.kind);
}

test "acp: encode/decode round-trip - request_with_uri" {
    const msg = AcpMessage{
        .version = 1,
        .kind = .REQUEST,
        .request_id = 42,
        .uri = "asset://textures/wood.png",
    };
    const data = try encode_to_buf(AcpMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(AcpMessage, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 1), decoded.version);
    try testing.expectEqual(AcpMessageKind.REQUEST, decoded.kind);
    try testing.expectEqual(@as(u64, 42), decoded.request_id);
    try testing.expectEqualStrings("asset://textures/wood.png", decoded.uri.?);
}

test "acp: encode/decode round-trip - discover_with_uris" {
    const uris = &[_][]const u8{
        "asset://models/tree.glb",
        "asset://textures/bark.png",
        "asset://shaders/pbr.wgsl",
    };
    const msg = AcpMessage{
        .kind = .DISCOVER,
        .request_id = 100,
        .uris = uris,
    };
    const data = try encode_to_buf(AcpMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(AcpMessage, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(AcpMessageKind.DISCOVER, decoded.kind);
    try testing.expectEqual(@as(u64, 100), decoded.request_id);
    try testing.expectEqual(@as(usize, 3), decoded.uris.len);
    try testing.expectEqualStrings("asset://models/tree.glb", decoded.uris[0]);
    try testing.expectEqualStrings("asset://textures/bark.png", decoded.uris[1]);
    try testing.expectEqualStrings("asset://shaders/pbr.wgsl", decoded.uris[2]);
}

test "acp: encode/decode round-trip - status_ok_with_metadata" {
    const msg = AcpMessage{
        .kind = .STATUS,
        .request_id = 7,
        .status = .OK,
        .metadata = .{
            .uri = "asset://textures/wood.png",
            .cache_path = "/tmp/cache/abc123",
            .payload_hash = "sha256:deadbeef",
            .file_length = 1048576,
            .uri_version = 3,
            .updated_at_ns = 1700000000000000000,
        },
    };
    const data = try encode_to_buf(AcpMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(AcpMessage, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(AcpMessageKind.STATUS, decoded.kind);
    try testing.expectEqual(@as(u64, 7), decoded.request_id);
    try testing.expectEqual(@as(?AcpStatusCode, .OK), decoded.status);
    try testing.expect(decoded.metadata != null);
    try testing.expectEqualStrings("asset://textures/wood.png", decoded.metadata.?.uri);
    try testing.expectEqualStrings("/tmp/cache/abc123", decoded.metadata.?.cache_path);
    try testing.expectEqualStrings("sha256:deadbeef", decoded.metadata.?.payload_hash);
    try testing.expectEqual(@as(i64, 1048576), decoded.metadata.?.file_length);
    try testing.expectEqual(@as(i64, 3), decoded.metadata.?.uri_version);
    try testing.expectEqual(@as(i64, 1700000000000000000), decoded.metadata.?.updated_at_ns);
}

test "acp: encode/decode round-trip - force_recook" {
    const msg = AcpMessage{
        .version = 2,
        .kind = .REQUEST,
        .request_id = 99,
        .uri = "asset://textures/grass.png",
        .force_recook = true,
    };
    const data = try encode_to_buf(AcpMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(AcpMessage, data);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 2), decoded.version);
    try testing.expectEqual(AcpMessageKind.REQUEST, decoded.kind);
    try testing.expectEqual(@as(u64, 99), decoded.request_id);
    try testing.expectEqualStrings("asset://textures/grass.png", decoded.uri.?);
    try testing.expectEqual(@as(?bool, true), decoded.force_recook);
}

test "acp: read Go test vectors" {
    const file_data = try read_go_vectors("testdata/go/acp.bin");
    if (file_data == null) return;
    defer testing.allocator.free(file_data.?);

    const cases = try framing.read_all_test_cases(testing.allocator, file_data.?);
    defer testing.allocator.free(cases);

    for (cases) |tc| {
        var decoded = try AcpMessage.decode(testing.allocator, tc.data);
        defer decoded.deinit(testing.allocator);

        if (std.mem.eql(u8, tc.name, "empty")) {
            try testing.expectEqual(@as(?u32, null), decoded.version);
            try testing.expectEqual(@as(u64, 0), decoded.request_id);
        } else if (std.mem.eql(u8, tc.name, "hello")) {
            try testing.expectEqual(@as(?u32, 1), decoded.version);
            try testing.expectEqual(AcpMessageKind.HELLO, decoded.kind);
        } else if (std.mem.eql(u8, tc.name, "request_with_uri")) {
            try testing.expectEqual(@as(?u32, 1), decoded.version);
            try testing.expectEqual(AcpMessageKind.REQUEST, decoded.kind);
            try testing.expectEqual(@as(u64, 42), decoded.request_id);
            try testing.expectEqualStrings("asset://textures/wood.png", decoded.uri.?);
        } else if (std.mem.eql(u8, tc.name, "discover_with_uris")) {
            try testing.expectEqual(AcpMessageKind.DISCOVER, decoded.kind);
            try testing.expectEqual(@as(u64, 100), decoded.request_id);
            try testing.expectEqual(@as(usize, 3), decoded.uris.len);
            try testing.expectEqualStrings("asset://models/tree.glb", decoded.uris[0]);
            try testing.expectEqualStrings("asset://textures/bark.png", decoded.uris[1]);
            try testing.expectEqualStrings("asset://shaders/pbr.wgsl", decoded.uris[2]);
        } else if (std.mem.eql(u8, tc.name, "status_ok_with_metadata")) {
            try testing.expectEqual(AcpMessageKind.STATUS, decoded.kind);
            try testing.expectEqual(@as(?AcpStatusCode, .OK), decoded.status);
            try testing.expect(decoded.metadata != null);
            try testing.expectEqualStrings("asset://textures/wood.png", decoded.metadata.?.uri);
            try testing.expectEqual(@as(i64, 1048576), decoded.metadata.?.file_length);
            try testing.expectEqual(@as(i64, 1700000000000000000), decoded.metadata.?.updated_at_ns);
        } else if (std.mem.eql(u8, tc.name, "status_not_found")) {
            try testing.expectEqual(@as(?AcpStatusCode, .NOT_FOUND), decoded.status);
            try testing.expectEqualStrings("asset not found in registry", decoded.detail.?);
        } else if (std.mem.eql(u8, tc.name, "updated_with_chunks")) {
            try testing.expectEqual(AcpMessageKind.UPDATED, decoded.kind);
            try testing.expectEqual(@as(u32, 3), decoded.chunk_index);
            try testing.expectEqual(@as(u32, 10), decoded.chunk_total);
            try testing.expect(decoded.metadata != null);
        } else if (std.mem.eql(u8, tc.name, "force_recook")) {
            try testing.expectEqual(@as(?u32, 2), decoded.version);
            try testing.expectEqual(@as(?bool, true), decoded.force_recook);
            try testing.expectEqualStrings("asset://textures/grass.png", decoded.uri.?);
        } else if (std.mem.eql(u8, tc.name, "all_status_codes")) {
            try testing.expectEqual(@as(?AcpStatusCode, .INTERNAL_ERROR), decoded.status);
            try testing.expectEqualStrings("unexpected codec failure", decoded.detail.?);
        } else if (std.mem.eql(u8, tc.name, "deload")) {
            try testing.expectEqual(AcpMessageKind.DELOAD, decoded.kind);
            try testing.expectEqual(@as(usize, 1), decoded.uris.len);
        }
    }
}

test "acp: write Zig test vectors" {
    const discover_uris = &[_][]const u8{
        "asset://models/tree.glb",
        "asset://textures/bark.png",
        "asset://shaders/pbr.wgsl",
    };
    const deload_uris = &[_][]const u8{
        "asset://textures/old.png",
    };
    const cases = [_]struct { name: []const u8, msg: AcpMessage }{
        .{ .name = "empty", .msg = .{} },
        .{ .name = "hello", .msg = .{
            .version = 1,
            .kind = .HELLO,
        } },
        .{ .name = "request_with_uri", .msg = .{
            .version = 1,
            .kind = .REQUEST,
            .request_id = 42,
            .uri = "asset://textures/wood.png",
        } },
        .{ .name = "discover_with_uris", .msg = .{
            .kind = .DISCOVER,
            .request_id = 100,
            .uris = discover_uris,
        } },
        .{ .name = "status_ok_with_metadata", .msg = .{
            .kind = .STATUS,
            .request_id = 7,
            .status = .OK,
            .metadata = .{
                .uri = "asset://textures/wood.png",
                .cache_path = "/tmp/cache/abc123",
                .payload_hash = "sha256:deadbeef",
                .file_length = 1048576,
                .uri_version = 3,
                .updated_at_ns = 1700000000000000000,
            },
        } },
        .{ .name = "status_not_found", .msg = .{
            .kind = .STATUS,
            .request_id = 8,
            .status = .NOT_FOUND,
            .detail = "asset not found in registry",
        } },
        .{ .name = "updated_with_chunks", .msg = .{
            .kind = .UPDATED,
            .request_id = 200,
            .uri = "asset://models/character.glb",
            .chunk_index = 3,
            .chunk_total = 10,
            .metadata = .{
                .uri = "asset://models/character.glb",
                .cache_path = "/var/cache/acp/char",
                .payload_hash = "sha256:cafebabe",
                .file_length = 5242880,
                .uri_version = 1,
                .updated_at_ns = 1700000000500000000,
            },
        } },
        .{ .name = "force_recook", .msg = .{
            .version = 2,
            .kind = .REQUEST,
            .request_id = 99,
            .uri = "asset://textures/grass.png",
            .force_recook = true,
        } },
        .{ .name = "all_status_codes", .msg = .{
            .kind = .STATUS,
            .status = .INTERNAL_ERROR,
            .detail = "unexpected codec failure",
        } },
        .{ .name = "deload", .msg = .{
            .kind = .DELOAD,
            .uris = deload_uris,
        } },
    };

    try write_test_vectors(AcpMessage, &cases, "testdata/zig/acp.bin");
}

// ══════════════════════════════════════════════════════════════════════
// JSON Round-Trip Tests
// ══════════════════════════════════════════════════════════════════════

test "json round-trip: scalar3 all defaults" {
    const msg = ScalarMessage{};
    const json_bytes = try json_encode(ScalarMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try ScalarMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 0), decoded.f_double);
    try testing.expectEqual(@as(i32, 0), decoded.f_int32);
    try testing.expectEqual(false, decoded.f_bool);
    try testing.expectEqualStrings("", decoded.f_string);
    try testing.expectEqualStrings("", decoded.f_bytes);
}

test "json round-trip: scalar3 all set" {
    const msg = ScalarMessage{
        .f_double = 1.5,
        .f_float = 2.5,
        .f_int32 = 42,
        .f_int64 = 100000,
        .f_uint32 = 200,
        .f_uint64 = 300000,
        .f_sint32 = -10,
        .f_sint64 = -20000,
        .f_fixed32 = 999,
        .f_fixed64 = 888888,
        .f_sfixed32 = -55,
        .f_sfixed64 = -66666,
        .f_bool = true,
        .f_string = "hello",
        .f_bytes = "world",
        .f_large_tag = 77,
    };

    const json_bytes = try json_encode(ScalarMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try ScalarMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 1.5), decoded.f_double);
    try testing.expectEqual(@as(f32, 2.5), decoded.f_float);
    try testing.expectEqual(@as(i32, 42), decoded.f_int32);
    try testing.expectEqual(@as(i64, 100000), decoded.f_int64);
    try testing.expectEqual(@as(u32, 200), decoded.f_uint32);
    try testing.expectEqual(@as(u64, 300000), decoded.f_uint64);
    try testing.expectEqual(@as(i32, -10), decoded.f_sint32);
    try testing.expectEqual(@as(i64, -20000), decoded.f_sint64);
    try testing.expectEqual(@as(u32, 999), decoded.f_fixed32);
    try testing.expectEqual(@as(u64, 888888), decoded.f_fixed64);
    try testing.expectEqual(@as(i32, -55), decoded.f_sfixed32);
    try testing.expectEqual(@as(i64, -66666), decoded.f_sfixed64);
    try testing.expectEqual(true, decoded.f_bool);
    try testing.expectEqualStrings("hello", decoded.f_string);
    try testing.expectEqualStrings("world", decoded.f_bytes);
    try testing.expectEqual(@as(i32, 77), decoded.f_large_tag);
}

test "json round-trip: nested3" {
    const msg = Outer{
        .middle = .{
            .inner = .{
                .value = 42,
                .label = "inner_label",
            },
            .id = 7,
        },
        .direct_inner = .{
            .value = 99,
            .label = "direct",
        },
        .name = "outer_name",
    };

    const json_bytes = try json_encode(Outer, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try Outer.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqualStrings("outer_name", decoded.name);
    try testing.expect(decoded.middle != null);
    try testing.expectEqual(@as(i32, 7), decoded.middle.?.id);
    try testing.expect(decoded.middle.?.inner != null);
    try testing.expectEqual(@as(i32, 42), decoded.middle.?.inner.?.value);
    try testing.expectEqualStrings("inner_label", decoded.middle.?.inner.?.label);
    try testing.expect(decoded.direct_inner != null);
    try testing.expectEqual(@as(i32, 99), decoded.direct_inner.?.value);
    try testing.expectEqualStrings("direct", decoded.direct_inner.?.label);
}

test "json round-trip: enum3" {
    const msg = EnumMessage{
        .color = .COLOR_BLUE,
        .colors = &[_]Color{ .COLOR_RED, .COLOR_GREEN, .COLOR_BLUE },
        .name = "colorful",
    };

    const json_bytes = try json_encode(EnumMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try EnumMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(Color.COLOR_BLUE, decoded.color);
    try testing.expectEqual(@as(usize, 3), decoded.colors.len);
    try testing.expectEqual(Color.COLOR_RED, decoded.colors[0]);
    try testing.expectEqual(Color.COLOR_GREEN, decoded.colors[1]);
    try testing.expectEqual(Color.COLOR_BLUE, decoded.colors[2]);
    try testing.expectEqualStrings("colorful", decoded.name);
}

test "json round-trip: oneof3 string variant" {
    const msg = OneofMessage{
        .name = "test",
        .value = .{ .str_val = "hello" },
    };

    const json_bytes = try json_encode(OneofMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try OneofMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqualStrings("test", decoded.name);
    try testing.expect(decoded.value != null);
    try testing.expectEqualStrings("hello", decoded.value.?.str_val);
}

test "json round-trip: oneof3 int variant" {
    const msg = OneofMessage{
        .name = "int_test",
        .value = .{ .int_val = 42 },
    };

    const json_bytes = try json_encode(OneofMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try OneofMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqualStrings("int_test", decoded.name);
    try testing.expect(decoded.value != null);
    try testing.expectEqual(@as(i32, 42), decoded.value.?.int_val);
}

test "json round-trip: oneof3 message variant" {
    const msg = OneofMessage{
        .name = "msg_test",
        .value = .{ .msg_val = .{ .id = 7, .text = "sub" } },
    };

    const json_bytes = try json_encode(OneofMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try OneofMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqualStrings("msg_test", decoded.name);
    try testing.expect(decoded.value != null);
    try testing.expectEqual(@as(i32, 7), decoded.value.?.msg_val.id);
    try testing.expectEqualStrings("sub", decoded.value.?.msg_val.text);
}

test "json round-trip: repeated3" {
    const items = [_]RepItem{
        .{ .id = 1, .name = "a" },
        .{ .id = 2, .name = "b" },
    };
    const msg = RepeatedMessage{
        .ints = &[_]i32{ 10, 20, 30 },
        .strings = &[_][]const u8{ "x", "y" },
        .doubles = &[_]f64{ 1.1, 2.2 },
        .bools = &[_]bool{ true, false, true },
        .items = &items,
    };

    const json_bytes = try json_encode(RepeatedMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try RepeatedMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), decoded.ints.len);
    try testing.expectEqual(@as(i32, 10), decoded.ints[0]);
    try testing.expectEqual(@as(i32, 20), decoded.ints[1]);
    try testing.expectEqual(@as(i32, 30), decoded.ints[2]);

    try testing.expectEqual(@as(usize, 2), decoded.strings.len);
    try testing.expectEqualStrings("x", decoded.strings[0]);
    try testing.expectEqualStrings("y", decoded.strings[1]);

    try testing.expectEqual(@as(usize, 2), decoded.doubles.len);
    try testing.expectEqual(@as(f64, 1.1), decoded.doubles[0]);
    try testing.expectEqual(@as(f64, 2.2), decoded.doubles[1]);

    try testing.expectEqual(@as(usize, 3), decoded.bools.len);
    try testing.expectEqual(true, decoded.bools[0]);
    try testing.expectEqual(false, decoded.bools[1]);
    try testing.expectEqual(true, decoded.bools[2]);

    try testing.expectEqual(@as(usize, 2), decoded.items.len);
    try testing.expectEqual(@as(i32, 1), decoded.items[0].id);
    try testing.expectEqualStrings("a", decoded.items[0].name);
    try testing.expectEqual(@as(i32, 2), decoded.items[1].id);
    try testing.expectEqualStrings("b", decoded.items[1].name);
}

test "json round-trip: map3 string-string" {
    var msg = MapMessage{};
    try msg.str_str.put(testing.allocator, "key1", "val1");
    try msg.str_str.put(testing.allocator, "key2", "val2");
    defer msg.str_str.deinit(testing.allocator);

    const json_bytes = try json_encode(MapMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try MapMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), decoded.str_str.count());
    try testing.expectEqualStrings("val1", decoded.str_str.get("key1").?);
    try testing.expectEqualStrings("val2", decoded.str_str.get("key2").?);
}

test "json round-trip: map3 int-string" {
    var msg = MapMessage{};
    try msg.int_str.put(testing.allocator, 1, "one");
    try msg.int_str.put(testing.allocator, 2, "two");
    defer msg.int_str.deinit(testing.allocator);

    const json_bytes = try json_encode(MapMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try MapMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), decoded.int_str.count());
    try testing.expectEqualStrings("one", decoded.int_str.get(1).?);
    try testing.expectEqualStrings("two", decoded.int_str.get(2).?);
}

test "json round-trip: map3 string-message" {
    var msg = MapMessage{};
    try msg.str_msg.put(testing.allocator, "a", .{ .id = 1, .text = "first" });
    defer msg.str_msg.deinit(testing.allocator);

    const json_bytes = try json_encode(MapMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try MapMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), decoded.str_msg.count());
    const val = decoded.str_msg.get("a").?;
    try testing.expectEqual(@as(i32, 1), val.id);
    try testing.expectEqualStrings("first", val.text);
}

test "json round-trip: optional3" {
    const msg = OptionalMessage{
        .opt_int = 42,
        .opt_str = "hello",
        .opt_bool = true,
        .opt_double = 3.14,
        .regular_int = 7,
    };

    const json_bytes = try json_encode(OptionalMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try OptionalMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 42), decoded.opt_int.?);
    try testing.expectEqualStrings("hello", decoded.opt_str.?);
    try testing.expectEqual(true, decoded.opt_bool.?);
    try testing.expectEqual(@as(f64, 3.14), decoded.opt_double.?);
    try testing.expectEqual(@as(i32, 7), decoded.regular_int);
}

test "json round-trip: optional3 nulls" {
    const msg = OptionalMessage{};

    const json_bytes = try json_encode(OptionalMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try OptionalMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expect(decoded.opt_int == null);
    try testing.expect(decoded.opt_str == null);
    try testing.expect(decoded.opt_bool == null);
    try testing.expect(decoded.opt_double == null);
    try testing.expectEqual(@as(i32, 0), decoded.regular_int);
}
