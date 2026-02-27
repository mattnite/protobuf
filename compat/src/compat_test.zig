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
const DefaultMessage = proto.default2.DefaultMessage;
const DefaultColor = proto.default2.DefaultColor;
const ExtBase = proto.extension2.ExtBase;
const GroupMessage = proto.group2.GroupMessage;
const TextMessage = proto.text3.TextMessage;
const SubMessage = proto.text3.SubMessage;
const TextEnum = proto.text3.TextEnum;

const json = @import("protobuf").json;
const text_format = @import("protobuf").text_format;
const descriptor = @import("protobuf").descriptor;
const dynamic = @import("protobuf").dynamic;
const DynamicMessage = dynamic.DynamicMessage;
const DynamicValue = dynamic.DynamicValue;

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

fn text_encode(comptime T: type, msg: T) ![]const u8 {
    var buf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try msg.to_text(&w);
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

// ── Default2 Tests ────────────────────────────────────────────────────

test "default2: getters return custom defaults when null" {
    const msg = DefaultMessage{};
    // Getters should return custom defaults
    try testing.expectEqual(@as(i32, 42), msg.get_opt_int());
    try testing.expectEqualStrings("hello", msg.get_opt_string());
    try testing.expectEqual(true, msg.get_opt_bool());
    try testing.expectEqual(@as(f32, 3.14), msg.get_opt_float());
    try testing.expectEqual(@as(f64, 2.718), msg.get_opt_double());
    try testing.expectEqualStrings("raw", msg.get_opt_bytes());
    try testing.expectEqual(DefaultColor.GREEN, msg.get_opt_color());
    try testing.expectEqual(@as(i32, -10), msg.get_opt_sint());
    try testing.expectEqual(@as(u64, 1000000), msg.get_opt_uint64());
    // opt_no_default has no getter
}

test "default2: required fields have custom defaults" {
    const msg = DefaultMessage{};
    try testing.expectEqual(@as(i32, 99), msg.req_with_default);
    try testing.expectEqual(DefaultColor.BLUE, msg.req_color);
}

test "default2: getters return set values when present" {
    var msg = DefaultMessage{};
    msg.opt_int = 7;
    msg.opt_string = "world";
    msg.opt_bool = false;
    msg.opt_color = .RED;
    try testing.expectEqual(@as(i32, 7), msg.get_opt_int());
    try testing.expectEqualStrings("world", msg.get_opt_string());
    try testing.expectEqual(false, msg.get_opt_bool());
    try testing.expectEqual(DefaultColor.RED, msg.get_opt_color());
}

test "default2: wire round-trip preserves set values" {
    var msg = DefaultMessage{};
    msg.opt_int = 7;
    msg.opt_string = "world";
    msg.opt_bool = false;
    msg.opt_float = 1.0;
    msg.opt_color = .RED;
    msg.req_with_default = 55;
    msg.req_color = .GREEN;

    const data = try encode_to_buf(DefaultMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(DefaultMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 7), decoded.get_opt_int());
    try testing.expectEqualStrings("world", decoded.get_opt_string());
    try testing.expectEqual(false, decoded.get_opt_bool());
    try testing.expectEqual(@as(f32, 1.0), decoded.get_opt_float());
    try testing.expectEqual(DefaultColor.RED, decoded.get_opt_color());
    try testing.expectEqual(@as(i32, 55), decoded.req_with_default);
    try testing.expectEqual(DefaultColor.GREEN, decoded.req_color);
}

test "default2: json round-trip" {
    var msg = DefaultMessage{};
    msg.opt_int = 7;
    msg.req_with_default = 55;
    msg.req_color = .GREEN;

    const json_bytes = try json_encode(DefaultMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try DefaultMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    // Set values preserved
    try testing.expectEqual(@as(i32, 7), decoded.get_opt_int());
    try testing.expectEqual(@as(i32, 55), decoded.req_with_default);
    try testing.expectEqual(DefaultColor.GREEN, decoded.req_color);
    // Null fields still get defaults from getters
    try testing.expect(decoded.opt_string == null);
    try testing.expectEqualStrings("hello", decoded.get_opt_string());
}

// ── Extension2 Tests ──────────────────────────────────────────────────

test "extension2: extension fields appear on struct" {
    var msg = ExtBase{};
    msg.id = 1;
    msg.name = "test";
    msg.ext_value = 42;
    msg.ext_label = "ext";
    msg.ext_flag = true;

    try testing.expectEqual(@as(i32, 1), msg.id);
    try testing.expectEqual(@as(i32, 42), msg.ext_value.?);
    try testing.expectEqualStrings("ext", msg.ext_label.?);
    try testing.expectEqual(true, msg.ext_flag.?);
}

test "extension2: wire round-trip" {
    var msg = ExtBase{};
    msg.id = 10;
    msg.name = "base";
    msg.ext_value = 77;
    msg.ext_label = "hello";
    msg.ext_flag = true;

    const data = try encode_to_buf(ExtBase, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(ExtBase, data);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 10), decoded.id);
    try testing.expectEqualStrings("base", decoded.name.?);
    try testing.expectEqual(@as(i32, 77), decoded.ext_value.?);
    try testing.expectEqualStrings("hello", decoded.ext_label.?);
    try testing.expectEqual(true, decoded.ext_flag.?);
}

test "extension2: json round-trip" {
    var msg = ExtBase{};
    msg.id = 5;
    msg.ext_value = 99;
    msg.ext_flag = true;

    const json_bytes = try json_encode(ExtBase, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try ExtBase.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 5), decoded.id);
    try testing.expectEqual(@as(i32, 99), decoded.ext_value.?);
    try testing.expectEqual(true, decoded.ext_flag.?);
}

// ── Group2 Tests ──────────────────────────────────────────────────────

test "group2: wire round-trip with group fields set" {
    var msg = GroupMessage{};
    msg.mygroup = .{ .value = 42, .label = "hello" };
    msg.after_group = 99;

    const data = try encode_to_buf(GroupMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(GroupMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expect(decoded.mygroup != null);
    try testing.expectEqual(@as(i32, 42), decoded.mygroup.?.value.?);
    try testing.expectEqualStrings("hello", decoded.mygroup.?.label.?);
    try testing.expectEqual(@as(i32, 99), decoded.after_group.?);
}

test "group2: wire format uses sgroup/egroup tags" {
    var msg = GroupMessage{};
    msg.mygroup = .{ .value = 1 };

    const data = try encode_to_buf(GroupMessage, msg);
    defer testing.allocator.free(data);

    // sgroup tag for field 1: (1 << 3) | 3 = 0x0B
    // egroup tag for field 1: (1 << 3) | 4 = 0x0C
    // Check that first byte is sgroup tag
    try testing.expectEqual(@as(u8, 0x0B), data[0]);
    // Check that last byte is egroup tag
    try testing.expectEqual(@as(u8, 0x0C), data[data.len - 1]);
}

test "group2: json round-trip" {
    var msg = GroupMessage{};
    msg.mygroup = .{ .value = 42, .label = "world" };
    msg.after_group = 7;

    const json_bytes = try json_encode(GroupMessage, msg);
    defer testing.allocator.free(json_bytes);

    var decoded = try GroupMessage.from_json(testing.allocator, json_bytes);
    defer decoded.deinit(testing.allocator);

    try testing.expect(decoded.mygroup != null);
    try testing.expectEqual(@as(i32, 42), decoded.mygroup.?.value.?);
    try testing.expectEqualStrings("world", decoded.mygroup.?.label.?);
    try testing.expectEqual(@as(i32, 7), decoded.after_group.?);
}

test "group2: null group round-trip" {
    const msg = GroupMessage{};

    const data = try encode_to_buf(GroupMessage, msg);
    defer testing.allocator.free(data);

    var decoded = try decode_msg(GroupMessage, data);
    defer decoded.deinit(testing.allocator);

    try testing.expect(decoded.mygroup == null);
    try testing.expect(decoded.after_group == null);
}

test "group2: unknown sgroup field is skipped" {
    // Build a message manually with an unknown group field (field 10)
    // followed by a known field (after_group = 4)
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = message.MessageWriter.init(&w);

    // Unknown sgroup field 10
    try mw.write_sgroup_field(10);
    // Inner: field 11 varint 42
    try mw.write_varint_field(11, 42);
    // Matching egroup field 10
    try mw.write_egroup_field(10);
    // Known field: after_group (field 4) = 99
    try mw.write_varint_field(4, 99);

    var decoded = try decode_msg(GroupMessage, w.buffered());
    defer decoded.deinit(testing.allocator);

    // The unknown group should be skipped
    try testing.expect(decoded.mygroup == null);
    // The field after should be correctly parsed
    try testing.expectEqual(@as(i32, 99), decoded.after_group.?);
}

// ══════════════════════════════════════════════════════════════════════
// Text Format Serialization Tests
// ══════════════════════════════════════════════════════════════════════

test "text format: empty message (proto3 defaults skipped)" {
    const msg = TextMessage{};
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("", text);
}

test "text format: scalar fields" {
    const msg = TextMessage{
        .id = 42,
        .name = "hello",
        .active = true,
        .score = 3.14,
        .data = "bin",
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "id: 42\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "name: \"hello\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "active: true\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "score: 3.14\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "data: \"bin\"\n") != null);
}

test "text format: enum field" {
    const msg = TextMessage{
        .status = .ALPHA,
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "status: ALPHA\n") != null);
}

test "text format: message field with indentation" {
    const msg = TextMessage{
        .sub = .{ .x = 7, .y = "inner" },
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "sub {\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  x: 7\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  y: \"inner\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "}\n") != null);
}

test "text format: repeated fields" {
    const msg = TextMessage{
        .numbers = &[_]i32{ 1, 2, 3 },
        .labels = &[_][]const u8{ "a", "b" },
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);
    // Repeated fields appear as separate lines with same name
    try testing.expect(std.mem.indexOf(u8, text, "numbers: 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "numbers: 2\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "numbers: 3\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "labels: \"a\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "labels: \"b\"\n") != null);
}

test "text format: repeated message fields" {
    const msg = TextMessage{
        .items = &[_]SubMessage{
            .{ .x = 1, .y = "first" },
            .{ .x = 2, .y = "second" },
        },
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);
    // Each repeated message is a separate block
    try testing.expect(std.mem.indexOf(u8, text, "items {\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  x: 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  y: \"first\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  x: 2\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  y: \"second\"\n") != null);
}

test "text format: map entries" {
    var msg = TextMessage{};
    var counts = @TypeOf(msg.counts){};
    try counts.put(testing.allocator, "alpha", 1);
    try counts.put(testing.allocator, "beta", 2);
    msg.counts = counts;
    defer {
        msg.counts = .empty;
        counts.deinit(testing.allocator);
    }

    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "counts {\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  key: \"alpha\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  value: 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  key: \"beta\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  value: 2\n") != null);
}

test "text format: oneof string variant" {
    const msg = TextMessage{
        .payload = .{ .text = "oneof_val" },
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "text: \"oneof_val\"\n") != null);
}

test "text format: oneof int variant" {
    const msg = TextMessage{
        .payload = .{ .number = 99 },
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "number: 99\n") != null);
}

test "text format: special float inf" {
    const msg = TextMessage{
        .score = std.math.inf(f64),
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "score: inf\n") != null);
}

test "text format: special float -inf" {
    const msg = TextMessage{
        .score = -std.math.inf(f64),
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "score: -inf\n") != null);
}

test "text format: special float nan" {
    const msg = TextMessage{
        .score = std.math.nan(f64),
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "score: nan\n") != null);
}

test "text format: string escaping" {
    const msg = TextMessage{
        .name = "hello\nworld\t\"end\"",
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "name: \"hello\\nworld\\t\\\"end\\\"\"\n") != null);
}

// ══════════════════════════════════════════════════════════════════════
// Text Format Round-Trip Tests
// ══════════════════════════════════════════════════════════════════════

test "text round-trip: empty message" {
    const msg = TextMessage{};
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);

    var decoded = try TextMessage.from_text(testing.allocator, text);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 0), decoded.id);
    try testing.expectEqualStrings("", decoded.name);
    try testing.expectEqual(false, decoded.active);
}

test "text round-trip: scalar fields" {
    const msg = TextMessage{
        .id = 42,
        .name = "hello",
        .active = true,
        .score = 3.14,
        .data = "bin",
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);

    var decoded = try TextMessage.from_text(testing.allocator, text);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 42), decoded.id);
    try testing.expectEqualStrings("hello", decoded.name);
    try testing.expectEqual(true, decoded.active);
    try testing.expectEqual(@as(f64, 3.14), decoded.score);
    try testing.expectEqualStrings("bin", decoded.data);
}

test "text round-trip: enum field" {
    const msg = TextMessage{
        .status = .BETA,
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);

    var decoded = try TextMessage.from_text(testing.allocator, text);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(TextEnum.BETA, decoded.status);
}

test "text round-trip: nested message" {
    const msg = TextMessage{
        .sub = .{ .x = 7, .y = "inner" },
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);

    var decoded = try TextMessage.from_text(testing.allocator, text);
    defer decoded.deinit(testing.allocator);

    try testing.expect(decoded.sub != null);
    try testing.expectEqual(@as(i32, 7), decoded.sub.?.x);
    try testing.expectEqualStrings("inner", decoded.sub.?.y);
}

test "text round-trip: repeated fields" {
    const msg = TextMessage{
        .numbers = &[_]i32{ 1, 2, 3 },
        .labels = &[_][]const u8{ "a", "b" },
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);

    var decoded = try TextMessage.from_text(testing.allocator, text);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), decoded.numbers.len);
    try testing.expectEqual(@as(i32, 1), decoded.numbers[0]);
    try testing.expectEqual(@as(i32, 2), decoded.numbers[1]);
    try testing.expectEqual(@as(i32, 3), decoded.numbers[2]);
    try testing.expectEqual(@as(usize, 2), decoded.labels.len);
    try testing.expectEqualStrings("a", decoded.labels[0]);
    try testing.expectEqualStrings("b", decoded.labels[1]);
}

test "text round-trip: repeated messages" {
    const msg = TextMessage{
        .items = &[_]SubMessage{
            .{ .x = 1, .y = "first" },
            .{ .x = 2, .y = "second" },
        },
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);

    var decoded = try TextMessage.from_text(testing.allocator, text);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), decoded.items.len);
    try testing.expectEqual(@as(i32, 1), decoded.items[0].x);
    try testing.expectEqualStrings("first", decoded.items[0].y);
    try testing.expectEqual(@as(i32, 2), decoded.items[1].x);
    try testing.expectEqualStrings("second", decoded.items[1].y);
}

test "text round-trip: map entries" {
    var msg = TextMessage{};
    var counts = @TypeOf(msg.counts){};
    try counts.put(testing.allocator, "alpha", 10);
    try counts.put(testing.allocator, "beta", 20);
    msg.counts = counts;

    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);

    // Must clean up the original
    counts.deinit(testing.allocator);
    msg.counts = .empty;

    var decoded = try TextMessage.from_text(testing.allocator, text);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), decoded.counts.count());
    try testing.expectEqual(@as(i32, 10), decoded.counts.get("alpha").?);
    try testing.expectEqual(@as(i32, 20), decoded.counts.get("beta").?);
}

test "text round-trip: oneof string" {
    const msg = TextMessage{
        .payload = .{ .text = "hello" },
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);

    var decoded = try TextMessage.from_text(testing.allocator, text);
    defer decoded.deinit(testing.allocator);

    try testing.expect(decoded.payload != null);
    try testing.expectEqualStrings("hello", decoded.payload.?.text);
}

test "text round-trip: oneof int" {
    const msg = TextMessage{
        .payload = .{ .number = 77 },
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);

    var decoded = try TextMessage.from_text(testing.allocator, text);
    defer decoded.deinit(testing.allocator);

    try testing.expect(decoded.payload != null);
    try testing.expectEqual(@as(i32, 77), decoded.payload.?.number);
}

test "text round-trip: string with special characters" {
    const msg = TextMessage{
        .name = "hello\nworld\t\"end\"\\back",
    };
    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);

    var decoded = try TextMessage.from_text(testing.allocator, text);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqualStrings("hello\nworld\t\"end\"\\back", decoded.name);
}

test "text round-trip: from_text with comments and extra whitespace" {
    const input =
        \\# This is a comment
        \\id: 42
        \\
        \\  name: "hello"
        \\# another comment
        \\active: true
        \\
    ;
    var decoded = try TextMessage.from_text(testing.allocator, input);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 42), decoded.id);
    try testing.expectEqualStrings("hello", decoded.name);
    try testing.expectEqual(true, decoded.active);
}

test "text round-trip: unknown fields skipped gracefully" {
    const input =
        \\id: 42
        \\unknown_field: "skip me"
        \\unknown_msg { nested: 1 }
        \\name: "hello"
        \\
    ;
    var decoded = try TextMessage.from_text(testing.allocator, input);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 42), decoded.id);
    try testing.expectEqualStrings("hello", decoded.name);
}

test "text round-trip: fully populated message" {
    var msg = TextMessage{
        .id = 100,
        .name = "full",
        .active = true,
        .score = 9.5,
        .data = "raw",
        .status = .ALPHA,
        .sub = .{ .x = 5, .y = "nested" },
        .numbers = &[_]i32{ 10, 20 },
        .labels = &[_][]const u8{"tag"},
        .payload = .{ .text = "choice" },
        .items = &[_]SubMessage{.{ .x = 3, .y = "item" }},
    };

    var counts = @TypeOf(msg.counts){};
    try counts.put(testing.allocator, "k", 1);
    msg.counts = counts;

    const text = try text_encode(TextMessage, msg);
    defer testing.allocator.free(text);

    counts.deinit(testing.allocator);
    msg.counts = .empty;

    var decoded = try TextMessage.from_text(testing.allocator, text);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 100), decoded.id);
    try testing.expectEqualStrings("full", decoded.name);
    try testing.expectEqual(true, decoded.active);
    try testing.expectEqual(@as(f64, 9.5), decoded.score);
    try testing.expectEqualStrings("raw", decoded.data);
    try testing.expectEqual(TextEnum.ALPHA, decoded.status);
    try testing.expectEqual(@as(i32, 5), decoded.sub.?.x);
    try testing.expectEqualStrings("nested", decoded.sub.?.y);
    try testing.expectEqual(@as(usize, 2), decoded.numbers.len);
    try testing.expectEqual(@as(i32, 10), decoded.numbers[0]);
    try testing.expectEqual(@as(i32, 20), decoded.numbers[1]);
    try testing.expectEqual(@as(usize, 1), decoded.labels.len);
    try testing.expectEqualStrings("tag", decoded.labels[0]);
    try testing.expectEqualStrings("choice", decoded.payload.?.text);
    try testing.expectEqual(@as(usize, 1), decoded.items.len);
    try testing.expectEqual(@as(i32, 3), decoded.items[0].x);
    try testing.expectEqualStrings("item", decoded.items[0].y);
    try testing.expectEqual(@as(usize, 1), decoded.counts.count());
    try testing.expectEqual(@as(i32, 1), decoded.counts.get("k").?);
}

// ── Descriptor Tests ──────────────────────────────────────────────────

test "descriptor: ScalarMessage has 16 fields" {
    const desc = ScalarMessage.descriptor;
    try testing.expectEqualStrings("ScalarMessage", desc.name);
    try testing.expectEqual(@as(usize, 16), desc.fields.len);
    // First field
    try testing.expectEqualStrings("f_double", desc.fields[0].name);
    try testing.expectEqual(@as(i32, 1), desc.fields[0].number);
    try testing.expectEqual(descriptor.FieldType.double, desc.fields[0].field_type);
    try testing.expectEqual(descriptor.FieldLabel.implicit, desc.fields[0].label);
    // Last field
    try testing.expectEqualStrings("f_large_tag", desc.fields[15].name);
    try testing.expectEqual(@as(i32, 1000), desc.fields[15].number);
}

test "descriptor: EnumMessage fields and enum descriptor" {
    const desc = EnumMessage.descriptor;
    try testing.expectEqualStrings("EnumMessage", desc.name);
    try testing.expectEqual(@as(usize, 3), desc.fields.len);
    // Enum field
    try testing.expectEqual(descriptor.FieldType.enum_type, desc.fields[0].field_type);
    try testing.expectEqualStrings("Color", desc.fields[0].type_name.?);
    // Repeated enum field
    try testing.expectEqual(descriptor.FieldLabel.repeated, desc.fields[1].label);

    // Color enum descriptor
    const color_desc = Color.descriptor;
    try testing.expectEqualStrings("Color", color_desc.name);
    try testing.expectEqual(@as(usize, 4), color_desc.values.len);
    try testing.expectEqualStrings("COLOR_UNSPECIFIED", color_desc.values[0].name);
    try testing.expectEqual(@as(i32, 0), color_desc.values[0].number);
    try testing.expectEqualStrings("COLOR_BLUE", color_desc.values[3].name);
    try testing.expectEqual(@as(i32, 3), color_desc.values[3].number);
}

test "descriptor: nested message descriptors" {
    const desc = Outer.descriptor;
    try testing.expectEqualStrings("Outer", desc.name);
    try testing.expectEqual(@as(usize, 3), desc.fields.len);
    // Message reference field
    try testing.expectEqual(descriptor.FieldType.message, desc.fields[0].field_type);
    try testing.expectEqualStrings("Middle", desc.fields[0].type_name.?);
}

test "descriptor: OneofMessage has oneof" {
    const desc = OneofMessage.descriptor;
    try testing.expectEqual(@as(usize, 1), desc.oneofs.len);
    try testing.expectEqualStrings("value", desc.oneofs[0].name);
    // Oneof fields should have oneof_index
    var found_oneof_field = false;
    for (desc.fields) |f| {
        if (f.oneof_index != null) {
            try testing.expectEqual(@as(u32, 0), f.oneof_index.?);
            found_oneof_field = true;
        }
    }
    try testing.expect(found_oneof_field);
}

test "descriptor: MapMessage has map fields" {
    const desc = MapMessage.descriptor;
    try testing.expectEqual(@as(usize, 3), desc.maps.len);
    // Check first map: str_str
    try testing.expectEqualStrings("str_str", desc.maps[0].name);
    try testing.expectEqual(descriptor.FieldType.string, desc.maps[0].entry.key_type);
    try testing.expectEqual(descriptor.FieldType.string, desc.maps[0].entry.value_type);
    // Check third map: str_msg (message value)
    try testing.expectEqualStrings("str_msg", desc.maps[2].name);
    try testing.expectEqual(descriptor.FieldType.message, desc.maps[2].entry.value_type);
    try testing.expectEqualStrings("MapSubMsg", desc.maps[2].entry.value_type_name.?);
}

test "descriptor: file descriptor accessible" {
    const fd = proto.scalar3._file_descriptor;
    try testing.expectEqualStrings("scalar3.proto", fd.name);
    try testing.expectEqual(descriptor.Syntax.proto3, fd.syntax);
    try testing.expectEqual(@as(usize, 1), fd.messages.len);
    try testing.expectEqualStrings("ScalarMessage", fd.messages[0].name);
}

test "descriptor: enum3 file descriptor" {
    const fd = proto.enum3._file_descriptor;
    try testing.expectEqual(@as(usize, 1), fd.messages.len);
    try testing.expectEqual(@as(usize, 1), fd.enums.len);
    try testing.expectEqualStrings("Color", fd.enums[0].name);
    try testing.expectEqualStrings("EnumMessage", fd.messages[0].name);
}

test "descriptor: json_name set when different from name" {
    const desc = ScalarMessage.descriptor;
    // "f_double" in camelCase is "fDouble"
    try testing.expectEqualStrings("fDouble", desc.fields[0].json_name.?);
    // "f_large_tag" -> "fLargeTag"
    try testing.expectEqualStrings("fLargeTag", desc.fields[15].json_name.?);
}

// ── DynamicMessage Interop Tests ──────────────────────────────────────

test "dynamic interop: generated encode → dynamic decode (scalars)" {
    const generated = ScalarMessage{
        .f_double = 3.14,
        .f_float = 2.72,
        .f_int32 = -42,
        .f_int64 = -100000,
        .f_uint32 = 42,
        .f_uint64 = 100000,
        .f_sint32 = -7,
        .f_sint64 = -8,
        .f_fixed32 = 9,
        .f_fixed64 = 10,
        .f_sfixed32 = -11,
        .f_sfixed64 = -12,
        .f_bool = true,
        .f_string = "hello",
        .f_bytes = "world",
        .f_large_tag = 999,
    };

    const encoded = try encode_to_buf(ScalarMessage, generated);
    defer testing.allocator.free(encoded);

    var dyn = try DynamicMessage.decode(testing.allocator, &ScalarMessage.descriptor, encoded);
    defer dyn.deinit();

    try testing.expectEqual(@as(f64, 3.14), dyn.get(1).?.singular.double_val);
    try testing.expectApproxEqAbs(@as(f32, 2.72), dyn.get(2).?.singular.float_val, 0.01);
    try testing.expectEqual(@as(i32, -42), dyn.get(3).?.singular.int32_val);
    try testing.expectEqual(@as(i64, -100000), dyn.get(4).?.singular.int64_val);
    try testing.expectEqual(@as(u32, 42), dyn.get(5).?.singular.uint32_val);
    try testing.expectEqual(@as(u64, 100000), dyn.get(6).?.singular.uint64_val);
    try testing.expectEqual(@as(i32, -7), dyn.get(7).?.singular.int32_val);
    try testing.expectEqual(@as(i64, -8), dyn.get(8).?.singular.int64_val);
    try testing.expectEqual(@as(u32, 9), dyn.get(9).?.singular.uint32_val);
    try testing.expectEqual(@as(u64, 10), dyn.get(10).?.singular.uint64_val);
    try testing.expectEqual(@as(i32, -11), dyn.get(11).?.singular.int32_val);
    try testing.expectEqual(@as(i64, -12), dyn.get(12).?.singular.int64_val);
    try testing.expect(dyn.get(13).?.singular.bool_val);
    try testing.expectEqualStrings("hello", dyn.get(14).?.singular.string_val);
    try testing.expectEqualStrings("world", dyn.get(15).?.singular.bytes_val);
    try testing.expectEqual(@as(i32, 999), dyn.get(1000).?.singular.int32_val);
}

test "dynamic interop: dynamic encode → generated decode (scalars)" {
    var dyn = DynamicMessage.init(testing.allocator, &ScalarMessage.descriptor);
    defer dyn.deinit();

    try dyn.set(1, .{ .double_val = 1.5 });
    try dyn.set(2, .{ .float_val = 2.5 });
    try dyn.set(3, .{ .int32_val = 100 });
    try dyn.set(4, .{ .int64_val = 200 });
    try dyn.set(5, .{ .uint32_val = 300 });
    try dyn.set(6, .{ .uint64_val = 400 });
    try dyn.set(7, .{ .int32_val = -50 });
    try dyn.set(8, .{ .int64_val = -60 });
    try dyn.set(9, .{ .uint32_val = 70 });
    try dyn.set(10, .{ .uint64_val = 80 });
    try dyn.set(11, .{ .int32_val = -90 });
    try dyn.set(12, .{ .int64_val = -100 });
    try dyn.set(13, .{ .bool_val = true });
    try dyn.set(14, .{ .string_val = "dynamic" });
    try dyn.set(15, .{ .bytes_val = "bytes" });

    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try dyn.encode(&writer);
    const encoded = writer.buffered();

    var decoded = try ScalarMessage.decode(testing.allocator, encoded);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 1.5), decoded.f_double);
    try testing.expectApproxEqAbs(@as(f32, 2.5), decoded.f_float, 0.01);
    try testing.expectEqual(@as(i32, 100), decoded.f_int32);
    try testing.expectEqual(@as(i64, 200), decoded.f_int64);
    try testing.expectEqual(@as(u32, 300), decoded.f_uint32);
    try testing.expectEqual(@as(u64, 400), decoded.f_uint64);
    try testing.expectEqual(@as(i32, -50), decoded.f_sint32);
    try testing.expectEqual(@as(i64, -60), decoded.f_sint64);
    try testing.expectEqual(@as(u32, 70), decoded.f_fixed32);
    try testing.expectEqual(@as(u64, 80), decoded.f_fixed64);
    try testing.expectEqual(@as(i32, -90), decoded.f_sfixed32);
    try testing.expectEqual(@as(i64, -100), decoded.f_sfixed64);
    try testing.expect(decoded.f_bool);
    try testing.expectEqualStrings("dynamic", decoded.f_string);
    try testing.expectEqualStrings("bytes", decoded.f_bytes);
}

test "dynamic interop: generated→dynamic→re-encode→generated round-trip" {
    const original = ScalarMessage{
        .f_double = 99.9,
        .f_int32 = 42,
        .f_string = "round-trip",
        .f_bool = true,
    };

    // generated → bytes
    const encoded1 = try encode_to_buf(ScalarMessage, original);
    defer testing.allocator.free(encoded1);

    // bytes → dynamic
    var dyn = try DynamicMessage.decode(testing.allocator, &ScalarMessage.descriptor, encoded1);
    defer dyn.deinit();

    // dynamic → bytes
    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try dyn.encode(&writer);
    const encoded2 = writer.buffered();

    // bytes → generated
    var decoded = try ScalarMessage.decode(testing.allocator, encoded2);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 99.9), decoded.f_double);
    try testing.expectEqual(@as(i32, 42), decoded.f_int32);
    try testing.expectEqualStrings("round-trip", decoded.f_string);
    try testing.expect(decoded.f_bool);
}

test "dynamic interop: generated encode → dynamic decode (map)" {
    // Use dynamic message to encode the map (avoids literal key lifetime issues with generated deinit)
    var dyn_src = DynamicMessage.init(testing.allocator, &MapMessage.descriptor);
    defer dyn_src.deinit();
    try dyn_src.putMap(1, .{ .string_val = "key1" }, .{ .string_val = "val1" });
    try dyn_src.putMap(1, .{ .string_val = "key2" }, .{ .string_val = "val2" });

    var enc_buf: [8192]u8 = undefined;
    var enc_w: std.Io.Writer = .fixed(&enc_buf);
    try dyn_src.encode(&enc_w);
    const encoded = try testing.allocator.dupe(u8, enc_w.buffered());
    defer testing.allocator.free(encoded);

    var dyn = try DynamicMessage.decode(testing.allocator, &MapMessage.descriptor, encoded);
    defer dyn.deinit();

    const map_storage = dyn.get(1).?;
    try testing.expectEqual(@as(usize, 2), map_storage.map_str.count());
    try testing.expectEqualStrings("val1", map_storage.map_str.get("key1").?.string_val);
    try testing.expectEqualStrings("val2", map_storage.map_str.get("key2").?.string_val);
}

test "dynamic interop: dynamic encode → generated decode (map)" {
    var dyn = DynamicMessage.init(testing.allocator, &MapMessage.descriptor);
    defer dyn.deinit();

    try dyn.putMap(1, .{ .string_val = "a" }, .{ .string_val = "1" });
    try dyn.putMap(1, .{ .string_val = "b" }, .{ .string_val = "2" });

    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try dyn.encode(&writer);
    const encoded = writer.buffered();

    var decoded = try MapMessage.decode(testing.allocator, encoded);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), decoded.str_str.count());
    try testing.expectEqualStrings("1", decoded.str_str.get("a").?);
    try testing.expectEqualStrings("2", decoded.str_str.get("b").?);
}
