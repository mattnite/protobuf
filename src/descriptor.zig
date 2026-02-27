const std = @import("std");
const testing = std.testing;

pub const Syntax = enum { proto2, proto3 };

pub const FieldType = enum {
    double,
    float,
    int32,
    int64,
    uint32,
    uint64,
    sint32,
    sint64,
    fixed32,
    fixed64,
    sfixed32,
    sfixed64,
    bool,
    string,
    bytes,
    message,
    enum_type,
    group,
};

pub const FieldLabel = enum { implicit, optional, required, repeated };

pub const FieldDescriptor = struct {
    name: []const u8,
    number: i32,
    field_type: FieldType,
    label: FieldLabel,
    type_name: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
    json_name: ?[]const u8 = null,
    oneof_index: ?u32 = null,
};

pub const OneofDescriptor = struct {
    name: []const u8,
};

pub const EnumValueDescriptor = struct {
    name: []const u8,
    number: i32,
};

pub const EnumDescriptor = struct {
    name: []const u8,
    full_name: []const u8,
    values: []const EnumValueDescriptor,
};

pub const MapEntryDescriptor = struct {
    key_type: FieldType,
    value_type: FieldType,
    value_type_name: ?[]const u8 = null,
};

pub const MessageDescriptor = struct {
    name: []const u8,
    full_name: []const u8,
    fields: []const FieldDescriptor,
    oneofs: []const OneofDescriptor = &.{},
    nested_messages: []const MessageDescriptor = &.{},
    nested_enums: []const EnumDescriptor = &.{},
    maps: []const MapFieldDescriptor = &.{},
};

pub const MapFieldDescriptor = struct {
    name: []const u8,
    number: i32,
    entry: MapEntryDescriptor,
};

pub const FileDescriptor = struct {
    name: []const u8,
    package: ?[]const u8,
    syntax: Syntax,
    messages: []const MessageDescriptor,
    enums: []const EnumDescriptor,
};

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

test "FieldDescriptor: default field values" {
    const fd: FieldDescriptor = .{
        .name = "test",
        .number = 1,
        .field_type = .int32,
        .label = .implicit,
    };
    try testing.expect(fd.type_name == null);
    try testing.expect(fd.default_value == null);
    try testing.expect(fd.json_name == null);
    try testing.expect(fd.oneof_index == null);
}

test "MessageDescriptor: default field values" {
    const md: MessageDescriptor = .{
        .name = "Test",
        .full_name = "pkg.Test",
        .fields = &.{},
    };
    try testing.expectEqual(@as(usize, 0), md.oneofs.len);
    try testing.expectEqual(@as(usize, 0), md.nested_messages.len);
    try testing.expectEqual(@as(usize, 0), md.nested_enums.len);
    try testing.expectEqual(@as(usize, 0), md.maps.len);
}

test "EnumDescriptor: values accessible" {
    const ed: EnumDescriptor = .{
        .name = "Color",
        .full_name = "pkg.Color",
        .values = &.{
            .{ .name = "RED", .number = 0 },
            .{ .name = "GREEN", .number = 1 },
        },
    };
    try testing.expectEqual(@as(usize, 2), ed.values.len);
    try testing.expectEqualStrings("RED", ed.values[0].name);
    try testing.expectEqual(@as(i32, 1), ed.values[1].number);
}

test "FileDescriptor: struct layout" {
    const fd: FileDescriptor = .{
        .name = "test.proto",
        .package = "mypackage",
        .syntax = .proto3,
        .messages = &.{},
        .enums = &.{},
    };
    try testing.expectEqualStrings("test.proto", fd.name);
    try testing.expectEqualStrings("mypackage", fd.package.?);
    try testing.expectEqual(Syntax.proto3, fd.syntax);
}

test "MapFieldDescriptor: entry types" {
    const mfd: MapFieldDescriptor = .{
        .name = "labels",
        .number = 5,
        .entry = .{
            .key_type = .string,
            .value_type = .message,
            .value_type_name = "pkg.SubMsg",
        },
    };
    try testing.expectEqual(FieldType.string, mfd.entry.key_type);
    try testing.expectEqual(FieldType.message, mfd.entry.value_type);
    try testing.expectEqualStrings("pkg.SubMsg", mfd.entry.value_type_name.?);
}
