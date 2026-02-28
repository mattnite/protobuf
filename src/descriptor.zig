const std = @import("std");
const testing = std.testing;

/// Protocol Buffers syntax version (proto2 or proto3)
pub const Syntax = enum { proto2, proto3 };

/// Protocol Buffers field type for reflection
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

/// Field cardinality label for reflection
pub const FieldLabel = enum { implicit, optional, required, repeated };

/// Runtime descriptor for a single message field
pub const FieldDescriptor = struct {
    name: []const u8,
    number: i32,
    field_type: FieldType,
    label: FieldLabel,
    /// Qualified type name for message and enum fields
    type_name: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
    json_name: ?[]const u8 = null,
    /// Index into the parent message's oneofs slice, if this field belongs to a oneof
    oneof_index: ?u32 = null,
};

/// Runtime descriptor for a oneof group
pub const OneofDescriptor = struct {
    name: []const u8,
};

/// Runtime descriptor for a single enum value
pub const EnumValueDescriptor = struct {
    name: []const u8,
    number: i32,
};

/// Runtime descriptor for an enum type
pub const EnumDescriptor = struct {
    name: []const u8,
    full_name: []const u8,
    values: []const EnumValueDescriptor,
};

/// Runtime descriptor for a map entry's key and value types
pub const MapEntryDescriptor = struct {
    key_type: FieldType,
    value_type: FieldType,
    value_type_name: ?[]const u8 = null,
};

/// Runtime descriptor for a message type
pub const MessageDescriptor = struct {
    name: []const u8,
    full_name: []const u8,
    fields: []const FieldDescriptor,
    oneofs: []const OneofDescriptor = &.{},
    nested_messages: []const MessageDescriptor = &.{},
    nested_enums: []const EnumDescriptor = &.{},
    maps: []const MapFieldDescriptor = &.{},
};

/// Runtime descriptor for a map field
pub const MapFieldDescriptor = struct {
    name: []const u8,
    number: i32,
    entry: MapEntryDescriptor,
};

/// Runtime descriptor for a .proto file
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
