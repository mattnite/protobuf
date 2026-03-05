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
// TypeRegistry — cross-file type resolution
// ══════════════════════════════════════════════════════════════════════

/// A registry that maps fully-qualified type names to their descriptors,
/// enabling cross-file type resolution during dynamic message decoding.
pub const TypeRegistry = struct {
    messages: std.StringHashMapUnmanaged(*const MessageDescriptor),
    enums: std.StringHashMapUnmanaged(*const EnumDescriptor),
    allocator: std.mem.Allocator,

    /// Initialize an empty registry using `allocator` for map storage.
    pub fn init(allocator: std.mem.Allocator) TypeRegistry {
        return .{
            .messages = .empty,
            .enums = .empty,
            .allocator = allocator,
        };
    }

    /// Release all registry map storage.
    pub fn deinit(self: *TypeRegistry) void {
        self.messages.deinit(self.allocator);
        self.enums.deinit(self.allocator);
    }

    /// Register all types from a file descriptor (messages and enums).
    pub fn registerFileDescriptor(self: *TypeRegistry, file: *const FileDescriptor) std.mem.Allocator.Error!void {
        for (file.messages) |*msg| {
            try self.registerMessage(msg);
        }
        for (file.enums) |*e| {
            try self.enums.put(self.allocator, e.full_name, e);
        }
    }

    /// Register a message descriptor and all its nested types recursively.
    pub fn registerMessage(self: *TypeRegistry, msg: *const MessageDescriptor) std.mem.Allocator.Error!void {
        try self.messages.put(self.allocator, msg.full_name, msg);
        for (msg.nested_messages) |*nested| {
            try self.registerMessage(nested);
        }
        for (msg.nested_enums) |*e| {
            try self.enums.put(self.allocator, e.full_name, e);
        }
    }

    /// Register a single enum descriptor.
    pub fn registerEnum(self: *TypeRegistry, e: *const EnumDescriptor) std.mem.Allocator.Error!void {
        try self.enums.put(self.allocator, e.full_name, e);
    }

    /// Look up a message descriptor by fully-qualified name.
    /// Handles both ".pkg.Msg" (absolute) and "pkg.Msg" (without leading dot) forms.
    pub fn findMessage(self: *const TypeRegistry, type_name: []const u8) ?*const MessageDescriptor {
        // Try as-is first.
        if (self.messages.get(type_name)) |m| return m;
        // Try stripping leading dot.
        if (type_name.len > 0 and type_name[0] == '.') {
            if (self.messages.get(type_name[1..])) |m| return m;
        }
        return null;
    }

    /// Look up an enum descriptor by fully-qualified name.
    pub fn findEnum(self: *const TypeRegistry, type_name: []const u8) ?*const EnumDescriptor {
        if (self.enums.get(type_name)) |e| return e;
        if (type_name.len > 0 and type_name[0] == '.') {
            if (self.enums.get(type_name[1..])) |e| return e;
        }
        return null;
    }
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

test "TypeRegistry: register and find message" {
    var reg = TypeRegistry.init(testing.allocator);
    defer reg.deinit();

    const msg_desc: MessageDescriptor = .{
        .name = "Person",
        .full_name = "example.Person",
        .fields = &.{},
    };
    try reg.registerMessage(&msg_desc);

    // Lookup by full name.
    const found = reg.findMessage("example.Person");
    try testing.expect(found != null);
    try testing.expectEqualStrings("Person", found.?.name);

    // Lookup with leading dot.
    const found_dot = reg.findMessage(".example.Person");
    try testing.expect(found_dot != null);
    try testing.expectEqualStrings("Person", found_dot.?.name);

    // Not found.
    try testing.expect(reg.findMessage("nonexistent.Msg") == null);
}

test "TypeRegistry: register nested messages recursively" {
    var reg = TypeRegistry.init(testing.allocator);
    defer reg.deinit();

    const inner_desc: MessageDescriptor = .{
        .name = "Inner",
        .full_name = "pkg.Outer.Inner",
        .fields = &.{},
    };
    const outer_desc: MessageDescriptor = .{
        .name = "Outer",
        .full_name = "pkg.Outer",
        .fields = &.{},
        .nested_messages = &.{inner_desc},
    };
    try reg.registerMessage(&outer_desc);

    try testing.expect(reg.findMessage("pkg.Outer") != null);
    try testing.expect(reg.findMessage("pkg.Outer.Inner") != null);
}

test "TypeRegistry: register enums" {
    var reg = TypeRegistry.init(testing.allocator);
    defer reg.deinit();

    const enum_desc: EnumDescriptor = .{
        .name = "Color",
        .full_name = "example.Color",
        .values = &.{
            .{ .name = "RED", .number = 0 },
        },
    };
    try reg.registerEnum(&enum_desc);

    const found = reg.findEnum("example.Color");
    try testing.expect(found != null);
    try testing.expectEqualStrings("Color", found.?.name);

    const found_dot = reg.findEnum(".example.Color");
    try testing.expect(found_dot != null);
}

test "TypeRegistry: registerFileDescriptor" {
    var reg = TypeRegistry.init(testing.allocator);
    defer reg.deinit();

    const msg_desc: MessageDescriptor = .{
        .name = "Request",
        .full_name = "api.Request",
        .fields = &.{},
    };
    const enum_desc: EnumDescriptor = .{
        .name = "Status",
        .full_name = "api.Status",
        .values = &.{},
    };
    const file_desc: FileDescriptor = .{
        .name = "api.proto",
        .package = "api",
        .syntax = .proto3,
        .messages = &.{msg_desc},
        .enums = &.{enum_desc},
    };
    try reg.registerFileDescriptor(&file_desc);

    try testing.expect(reg.findMessage("api.Request") != null);
    try testing.expect(reg.findEnum("api.Status") != null);
}
