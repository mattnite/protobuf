const std = @import("std");
const testing = std.testing;
const ast = @import("../proto/ast.zig");
const Emitter = @import("emitter.zig").Emitter;
const enums = @import("enums.zig");
const types = @import("types.zig");

// These are referenced in generated code strings, not used directly here.
// They exist to document the dependency.
const encoding = @import("../encoding.zig");
const message = @import("../message.zig");
comptime {
    _ = encoding;
    _ = message;
}

/// Set of message type names that participate in recursive size-dependency cycles.
/// Fields referencing these types use `?*T` instead of `?T` to break the cycle.
pub const RecursiveTypes = std.StringHashMap(void);

const WrapperKind = enum {
    bool_value,
    int32_value,
    int64_value,
    uint32_value,
    uint64_value,
    float_value,
    double_value,
    string_value,
    bytes_value,
};

fn detect_wrapper_kind(full_name: []const u8) ?WrapperKind {
    if (std.mem.eql(u8, full_name, "google.protobuf.BoolValue")) return .bool_value;
    if (std.mem.eql(u8, full_name, "google.protobuf.Int32Value")) return .int32_value;
    if (std.mem.eql(u8, full_name, "google.protobuf.Int64Value")) return .int64_value;
    if (std.mem.eql(u8, full_name, "google.protobuf.UInt32Value")) return .uint32_value;
    if (std.mem.eql(u8, full_name, "google.protobuf.UInt64Value")) return .uint64_value;
    if (std.mem.eql(u8, full_name, "google.protobuf.FloatValue")) return .float_value;
    if (std.mem.eql(u8, full_name, "google.protobuf.DoubleValue")) return .double_value;
    if (std.mem.eql(u8, full_name, "google.protobuf.StringValue")) return .string_value;
    if (std.mem.eql(u8, full_name, "google.protobuf.BytesValue")) return .bytes_value;
    return null;
}

fn is_timestamp_type(full_name: []const u8) bool {
    return std.mem.eql(u8, full_name, "google.protobuf.Timestamp");
}

fn is_duration_type(full_name: []const u8) bool {
    return std.mem.eql(u8, full_name, "google.protobuf.Duration");
}

fn is_field_mask_type(full_name: []const u8) bool {
    return std.mem.eql(u8, full_name, "google.protobuf.FieldMask");
}

fn is_struct_type(full_name: []const u8) bool {
    return std.mem.eql(u8, full_name, "google.protobuf.Struct");
}

fn is_value_type(full_name: []const u8) bool {
    return std.mem.eql(u8, full_name, "google.protobuf.Value");
}

fn is_list_value_type(full_name: []const u8) bool {
    return std.mem.eql(u8, full_name, "google.protobuf.ListValue");
}

fn is_any_type(full_name: []const u8) bool {
    return std.mem.eql(u8, full_name, "google.protobuf.Any");
}

/// Emit Zig source for a protobuf message, including nested types and helpers.
pub fn emit_message(e: *Emitter, msg: ast.Message, syntax: ast.Syntax, full_name: []const u8, recursive_types: *const RecursiveTypes) std.mem.Allocator.Error!void {
    try e.print("/// Protocol Buffers message: {s}\n", .{msg.name});
    try e.print("pub const {s} = struct", .{msg.name});
    try e.open_brace();

    // Nested enums first
    for (msg.nested_enums) |nested_enum| {
        var name_buf: [512]u8 = undefined;
        const nested_full = std.fmt.bufPrint(&name_buf, "{s}.{s}", .{ full_name, nested_enum.name }) catch unreachable;
        try enums.emit_enum(e, nested_enum, syntax, nested_full);
        try e.blank_line();
    }

    // Nested messages
    for (msg.nested_messages) |nested_msg| {
        var name_buf: [512]u8 = undefined;
        const nested_full = std.fmt.bufPrint(&name_buf, "{s}.{s}", .{ full_name, nested_msg.name }) catch unreachable;
        try emit_message(e, nested_msg, syntax, nested_full, recursive_types);
        try e.blank_line();
    }

    // Oneof union types
    for (msg.oneofs) |oneof| {
        try emit_oneof_type(e, oneof, syntax);
        try e.blank_line();
    }

    // Group types (emit as nested structs)
    for (msg.groups) |group| {
        var group_name_buf: [512]u8 = undefined;
        const group_full = std.fmt.bufPrint(&group_name_buf, "{s}.{s}", .{ full_name, group.name }) catch unreachable;
        try emit_group_struct(e, group, syntax, group_full, recursive_types);
        try e.blank_line();
    }

    // Regular fields
    for (msg.fields) |field| {
        try emit_field(e, field, syntax, recursive_types);
    }

    // Group fields on the parent struct
    for (msg.groups) |group| {
        try emit_group_field(e, group);
    }

    // Map fields
    for (msg.maps) |map_field| {
        try emit_map_field(e, map_field);
    }

    // Oneof fields (the ?UnionType = null field on the struct)
    // Use @This() to avoid ambiguity with nested messages that have same-named oneofs
    for (msg.oneofs) |oneof| {
        const escaped = types.escape_zig_keyword(oneof.name);
        try e.print("{f}: ?@This().", .{escaped});
        try emit_oneof_type_name(e, oneof);
        try e.print_raw(" = null,\n", .{});
    }

    // Unknown fields
    try e.print("_unknown_fields: []const u8 = \"\",\n", .{});

    // Getter methods for optional fields with custom defaults
    for (msg.fields) |field| {
        if (field.label == .optional) {
            if (types.extract_default(field.options)) |def| {
                try e.blank_line();
                try emit_getter_method(e, field, def);
            }
        }
    }

    // Descriptor
    try e.blank_line();
    try emit_descriptor(e, msg, syntax, full_name);

    // Methods
    try e.blank_line();
    try emit_encode_method(e, msg, syntax);
    try e.blank_line();
    try emit_calc_size_method(e, msg, syntax);
    try e.blank_line();
    try emit_decode_method(e, msg, syntax, recursive_types);
    try e.blank_line();
    try emit_deinit_method(e, msg, syntax, recursive_types);
    try e.blank_line();
    try emit_to_json_method(e, msg, syntax, full_name);
    try e.blank_line();
    try emit_from_json_method(e, msg, syntax, full_name, recursive_types);
    try e.blank_line();
    try emit_to_text_method(e, msg, syntax, full_name);
    try e.blank_line();
    try emit_from_text_method(e, msg, syntax, full_name, recursive_types);

    try e.close_brace();
}

fn emit_descriptor(e: *Emitter, msg: ast.Message, syntax: ast.Syntax, full_name: []const u8) std.mem.Allocator.Error!void {
    _ = syntax;
    try e.print("/// Runtime type descriptor for reflection and dynamic message operations\n", .{});
    try e.print("pub const descriptor = protobuf.descriptor.MessageDescriptor{{\n", .{});
    e.indent_level += 1;
    try e.print(".name = \"{s}\",\n", .{msg.name});
    try e.print(".full_name = \"{s}\",\n", .{full_name});

    // Fields
    try e.print(".fields = &.{{\n", .{});
    e.indent_level += 1;
    // Regular fields
    for (msg.fields) |field| {
        try emit_field_descriptor(e, field);
    }
    // Oneof fields
    for (msg.oneofs, 0..) |oneof, oneof_idx| {
        for (oneof.fields) |field| {
            try emit_oneof_field_descriptor(e, field, @intCast(oneof_idx));
        }
    }
    // Group fields
    for (msg.groups) |group| {
        try emit_group_field_descriptor(e, group);
    }
    e.indent_level -= 1;
    try e.print("}},\n", .{});

    // Oneofs
    if (msg.oneofs.len > 0) {
        try e.print(".oneofs = &.{{\n", .{});
        e.indent_level += 1;
        for (msg.oneofs) |oneof| {
            try e.print(".{{ .name = \"{s}\" }},\n", .{oneof.name});
        }
        e.indent_level -= 1;
        try e.print("}},\n", .{});
    }

    // Nested messages
    if (msg.nested_messages.len > 0) {
        try e.print(".nested_messages = &.{{\n", .{});
        e.indent_level += 1;
        for (msg.nested_messages) |nested| {
            try e.print("{s}.descriptor,\n", .{nested.name});
        }
        e.indent_level -= 1;
        try e.print("}},\n", .{});
    }

    // Nested enums
    if (msg.nested_enums.len > 0) {
        try e.print(".nested_enums = &.{{\n", .{});
        e.indent_level += 1;
        for (msg.nested_enums) |nested_enum| {
            try e.print("{s}.descriptor,\n", .{nested_enum.name});
        }
        e.indent_level -= 1;
        try e.print("}},\n", .{});
    }

    // Maps
    if (msg.maps.len > 0) {
        try e.print(".maps = &.{{\n", .{});
        e.indent_level += 1;
        for (msg.maps) |map_field| {
            try emit_map_field_descriptor(e, map_field);
        }
        e.indent_level -= 1;
        try e.print("}},\n", .{});
    }

    e.indent_level -= 1;
    try e.print("}};\n", .{});
}

fn emit_field_descriptor(e: *Emitter, field: ast.Field) !void {
    try e.print(".{{ .name = \"{s}\", .number = {d}, .field_type = ", .{ field.name, field.number });
    switch (field.type_name) {
        .scalar => |s| try e.print_raw("{s}", .{types.scalar_descriptor_type(s)}),
        .named => try e.print_raw(".message", .{}),
        .enum_ref => try e.print_raw(".enum_type", .{}),
    }
    try e.print_raw(", .label = ", .{});
    switch (field.label) {
        .implicit => try e.print_raw(".implicit", .{}),
        .optional => try e.print_raw(".optional", .{}),
        .required => try e.print_raw(".required", .{}),
        .repeated => try e.print_raw(".repeated", .{}),
    }
    // Type name for message/enum refs
    switch (field.type_name) {
        .named => |name| try e.print_raw(", .type_name = \"{s}\"", .{name}),
        .enum_ref => |name| try e.print_raw(", .type_name = \"{s}\"", .{name}),
        .scalar => {},
    }
    // JSON name
    var json_name_buf: [256]u8 = undefined;
    const jname = json_field_name(field.name, field.options, &json_name_buf);
    if (!std.mem.eql(u8, jname, field.name)) {
        try e.print_raw(", .json_name = \"{s}\"", .{jname});
    }
    // Default value
    if (types.extract_default(field.options)) |def| {
        var def_buf: [256]u8 = undefined;
        const def_str = emit_default_string(def, &def_buf);
        try e.print_raw(", .default_value = \"{s}\"", .{def_str});
    }
    try e.print_raw(" }},\n", .{});
}

fn emit_oneof_field_descriptor(e: *Emitter, field: ast.Field, oneof_index: u32) !void {
    try e.print(".{{ .name = \"{s}\", .number = {d}, .field_type = ", .{ field.name, field.number });
    switch (field.type_name) {
        .scalar => |s| try e.print_raw("{s}", .{types.scalar_descriptor_type(s)}),
        .named => try e.print_raw(".message", .{}),
        .enum_ref => try e.print_raw(".enum_type", .{}),
    }
    try e.print_raw(", .label = .optional, .oneof_index = {d}", .{oneof_index});
    switch (field.type_name) {
        .named => |name| try e.print_raw(", .type_name = \"{s}\"", .{name}),
        .enum_ref => |name| try e.print_raw(", .type_name = \"{s}\"", .{name}),
        .scalar => {},
    }
    // JSON name
    var json_name_buf: [256]u8 = undefined;
    const jname = json_field_name(field.name, field.options, &json_name_buf);
    if (!std.mem.eql(u8, jname, field.name)) {
        try e.print_raw(", .json_name = \"{s}\"", .{jname});
    }
    try e.print_raw(" }},\n", .{});
}

fn emit_group_field_descriptor(e: *Emitter, group: ast.Group) !void {
    try e.print(".{{ .name = \"{s}\", .number = {d}, .field_type = .group, .label = ", .{ group.name, group.number });
    switch (group.label) {
        .implicit => try e.print_raw(".implicit", .{}),
        .optional => try e.print_raw(".optional", .{}),
        .required => try e.print_raw(".required", .{}),
        .repeated => try e.print_raw(".repeated", .{}),
    }
    try e.print_raw(", .type_name = \"{s}\"", .{group.name});
    try e.print_raw(" }},\n", .{});
}

fn emit_map_field_descriptor(e: *Emitter, map_field: ast.MapField) !void {
    try e.print(".{{ .name = \"{s}\", .number = {d}, .entry = .{{ .key_type = {s}, .value_type = ", .{
        map_field.name,
        map_field.number,
        types.scalar_descriptor_type(map_field.key_type),
    });
    switch (map_field.value_type) {
        .scalar => |s| try e.print_raw("{s}", .{types.scalar_descriptor_type(s)}),
        .named => try e.print_raw(".message", .{}),
        .enum_ref => try e.print_raw(".enum_type", .{}),
    }
    switch (map_field.value_type) {
        .named => |name| try e.print_raw(", .value_type_name = \"{s}\"", .{name}),
        .enum_ref => |name| try e.print_raw(", .value_type_name = \"{s}\"", .{name}),
        .scalar => {},
    }
    try e.print_raw(" }} }},\n", .{});
}

fn emit_group_descriptor(e: *Emitter, group: ast.Group, full_name: []const u8) !void {
    try e.print("/// Runtime type descriptor for reflection and dynamic message operations\n", .{});
    try e.print("pub const descriptor = protobuf.descriptor.MessageDescriptor{{\n", .{});
    e.indent_level += 1;
    try e.print(".name = \"{s}\",\n", .{group.name});
    try e.print(".full_name = \"{s}\",\n", .{full_name});

    // Fields
    try e.print(".fields = &.{{\n", .{});
    e.indent_level += 1;
    for (group.fields) |field| {
        try emit_field_descriptor(e, field);
    }
    e.indent_level -= 1;
    try e.print("}},\n", .{});

    // Nested messages
    if (group.nested_messages.len > 0) {
        try e.print(".nested_messages = &.{{\n", .{});
        e.indent_level += 1;
        for (group.nested_messages) |nested| {
            try e.print("{s}.descriptor,\n", .{nested.name});
        }
        e.indent_level -= 1;
        try e.print("}},\n", .{});
    }

    // Nested enums
    if (group.nested_enums.len > 0) {
        try e.print(".nested_enums = &.{{\n", .{});
        e.indent_level += 1;
        for (group.nested_enums) |nested_enum| {
            try e.print("{s}.descriptor,\n", .{nested_enum.name});
        }
        e.indent_level -= 1;
        try e.print("}},\n", .{});
    }

    e.indent_level -= 1;
    try e.print("}};\n", .{});
}

/// Convert a Constant to its string representation for default_value in descriptors.
fn emit_default_string(constant: ast.Constant, buf: []u8) []const u8 {
    switch (constant) {
        .integer => |n| return std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable,
        .unsigned_integer => |n| return std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable,
        .float_value => |f| return std.fmt.bufPrint(buf, "{d}", .{f}) catch unreachable,
        .bool_value => |b| return if (b) "true" else "false",
        .string_value => |s| return s,
        .identifier => |id| return id,
        .aggregate => return "",
    }
}

fn emit_field(e: *Emitter, field: ast.Field, _: ast.Syntax, recursive_types: *const RecursiveTypes) !void {
    const escaped = types.escape_zig_keyword(field.name);
    switch (field.type_name) {
        .scalar => |s| {
            switch (field.label) {
                .repeated => {
                    try e.print("{f}: []const {s} = &.{{}},\n", .{ escaped, types.scalar_zig_type(s) });
                },
                .optional => {
                    // Proto2 optional or proto3 explicit optional
                    try e.print("{f}: ?{s} = null,\n", .{ escaped, types.scalar_zig_type(s) });
                },
                .required => {
                    // Proto2 required: non-nullable with custom or zero default
                    if (types.extract_default(field.options)) |def| {
                        var def_buf: [256]u8 = undefined;
                        const def_lit = types.emit_default_literal(def, s, &def_buf);
                        try e.print("{f}: {s} = {s},\n", .{ escaped, types.scalar_zig_type(s), def_lit });
                    } else {
                        try e.print("{f}: {s} = {s},\n", .{ escaped, types.scalar_zig_type(s), types.scalar_default_value(s) });
                    }
                },
                .implicit => {
                    // Proto3 implicit: non-nullable with zero default
                    try e.print("{f}: {s} = {s},\n", .{ escaped, types.scalar_zig_type(s), types.scalar_default_value(s) });
                },
            }
        },
        .named => |name| {
            const is_recursive = recursive_types.contains(name);
            // Message type: use ?*T for recursive types, ?T otherwise.
            switch (field.label) {
                .repeated => {
                    try e.print("{f}: []const {s} = &.{{}},\n", .{ escaped, name });
                },
                .optional => {
                    if (is_recursive) {
                        try e.print("{f}: ?*{s} = null,\n", .{ escaped, name });
                    } else {
                        try e.print("{f}: ?{s} = null,\n", .{ escaped, name });
                    }
                },
                .required => {
                    try e.print("{f}: {s} = .{{}},\n", .{ escaped, name });
                },
                .implicit => {
                    if (is_recursive) {
                        try e.print("{f}: ?*{s} = null,\n", .{ escaped, name });
                    } else {
                        try e.print("{f}: ?{s} = null,\n", .{ escaped, name });
                    }
                },
            }
        },
        .enum_ref => |name| {
            // Enum type: value type (not optional) for implicit/required.
            switch (field.label) {
                .repeated => {
                    try e.print("{f}: []const {s} = &.{{}},\n", .{ escaped, name });
                },
                .optional => {
                    try e.print("{f}: ?{s} = null,\n", .{ escaped, name });
                },
                .required => {
                    if (types.extract_default(field.options)) |def| {
                        var def_buf: [256]u8 = undefined;
                        const def_lit = types.emit_default_literal(def, .int32, &def_buf);
                        try e.print("{f}: {s} = {s},\n", .{ escaped, name, def_lit });
                    } else {
                        try e.print("{f}: {s} = @enumFromInt(0),\n", .{ escaped, name });
                    }
                },
                .implicit => {
                    try e.print("{f}: {s} = @enumFromInt(0),\n", .{ escaped, name });
                },
            }
        },
    }
}

fn emit_getter_method(e: *Emitter, field: ast.Field, def: ast.Constant) !void {
    const escaped = types.escape_zig_keyword(field.name);
    const return_type = switch (field.type_name) {
        .scalar => |s| types.scalar_zig_type(s),
        .enum_ref => |name| name,
        .named => |name| name,
    };
    const scalar_for_literal: ast.ScalarType = switch (field.type_name) {
        .scalar => |s| s,
        .enum_ref => .int32,
        .named => .int32,
    };
    var def_buf: [256]u8 = undefined;
    const def_lit = types.emit_default_literal(def, scalar_for_literal, &def_buf);

    try e.print("/// Return the value of {s}, or its default if not set\n", .{field.name});
    try e.print("pub fn get_{f}(self: @This()) {s}", .{ escaped, return_type });
    try e.open_brace();
    try e.print("return self.{f} orelse {s};\n", .{ escaped, def_lit });
    try e.close_brace_nosemi();
}

fn emit_group_struct(e: *Emitter, group: ast.Group, syntax: ast.Syntax, full_name: []const u8, recursive_types: *const RecursiveTypes) !void {
    // Groups are like mini-messages: emit as nested struct
    try e.print("/// Protocol Buffers group: {s}\n", .{group.name});
    try e.print("pub const {s} = struct", .{group.name});
    try e.open_brace();

    // Nested enums
    for (group.nested_enums) |nested_enum| {
        var name_buf: [512]u8 = undefined;
        const nested_full = std.fmt.bufPrint(&name_buf, "{s}.{s}", .{ full_name, nested_enum.name }) catch unreachable;
        try enums.emit_enum(e, nested_enum, syntax, nested_full);
        try e.blank_line();
    }

    // Nested messages
    for (group.nested_messages) |nested_msg| {
        var name_buf: [512]u8 = undefined;
        const nested_full = std.fmt.bufPrint(&name_buf, "{s}.{s}", .{ full_name, nested_msg.name }) catch unreachable;
        try emit_message(e, nested_msg, syntax, nested_full, recursive_types);
        try e.blank_line();
    }

    // Fields
    for (group.fields) |field| {
        try emit_field(e, field, syntax, recursive_types);
    }

    // Unknown fields
    try e.print("_unknown_fields: []const u8 = \"\",\n", .{});

    // Descriptor
    try e.blank_line();
    try emit_group_descriptor(e, group, full_name);

    // Encode method (same as message encode but without unknown fields tracking on output)
    try e.blank_line();
    try emit_group_encode_method(e, group, syntax);

    // Calc size method
    try e.blank_line();
    try emit_group_calc_size_method(e, group, syntax);

    // Decode group method (reads until matching egroup tag)
    try e.blank_line();
    try emit_group_decode_method(e, group, syntax, recursive_types);

    // Deinit
    try e.blank_line();
    try emit_group_deinit_method(e, group, recursive_types);

    // JSON methods
    try e.blank_line();
    try emit_group_to_json_method(e, group, syntax);
    try e.blank_line();
    try emit_group_from_json_method(e, group, syntax, recursive_types);

    // Text format methods
    try e.blank_line();
    try emit_group_to_text_method(e, group);
    try e.blank_line();
    try emit_group_from_text_method(e, group, recursive_types);

    try e.close_brace();
}

fn emit_group_field(e: *Emitter, group: ast.Group) !void {
    // Convert group name to lowercase field name
    var name_buf: [256]u8 = undefined;
    var name_len: usize = 0;
    for (group.name) |c| {
        name_buf[name_len] = std.ascii.toLower(c);
        name_len += 1;
    }
    const field_name = name_buf[0..name_len];
    const escaped = types.escape_zig_keyword(field_name);

    switch (group.label) {
        .optional => {
            try e.print("{f}: ?{s} = null,\n", .{ escaped, group.name });
        },
        .required => {
            try e.print("{f}: {s} = .{{}},\n", .{ escaped, group.name });
        },
        .repeated => {
            try e.print("{f}: []const {s} = &.{{}},\n", .{ escaped, group.name });
        },
        .implicit => {
            try e.print("{f}: ?{s} = null,\n", .{ escaped, group.name });
        },
    }
}

fn group_field_name(group_name: []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    for (group_name) |c| {
        buf[len] = std.ascii.toLower(c);
        len += 1;
    }
    return buf[0..len];
}

fn emit_group_encode_method(e: *Emitter, group: ast.Group, syntax: ast.Syntax) !void {
    try e.print("/// Serialize this group to protobuf binary wire format\n", .{});
    try e.print("pub fn encode(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    if (group.fields.len > 0) {
        try e.print("const mw = message.MessageWriter.init(writer);\n", .{});
        for (group.fields) |field| {
            try emit_encode_field(e, field, syntax);
        }
    }
    try e.print("if (self._unknown_fields.len > 0) try writer.writeAll(self._unknown_fields);\n", .{});
    try e.close_brace_nosemi();
}

fn emit_group_calc_size_method(e: *Emitter, group: ast.Group, syntax: ast.Syntax) !void {
    try e.print("/// Calculate the serialized size in bytes without encoding\n", .{});
    try e.print("pub fn calc_size(self: @This()) usize", .{});
    try e.open_brace();
    try e.print("var size: usize = 0;\n", .{});
    for (group.fields) |field| {
        try emit_size_field(e, field, syntax);
    }
    try e.print("size += self._unknown_fields.len;\n", .{});
    try e.print("return size;\n", .{});
    try e.close_brace_nosemi();
}

fn emit_group_decode_method(e: *Emitter, group: ast.Group, syntax: ast.Syntax, recursive_types: *const RecursiveTypes) !void {
    // Public wrapper with default depth
    try e.print("/// Deserialize this group from a field iterator. Caller must call deinit when done\n", .{});
    try e.print("pub fn decode_group(allocator: std.mem.Allocator, iter: *message.FieldIterator, group_field_number: u29) !@This()", .{});
    try e.open_brace();
    try e.print("return @This().decode_group_inner(allocator, iter, group_field_number, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    // Inner decode with depth tracking
    try e.print("pub fn decode_group_inner(allocator: std.mem.Allocator, iter: *message.FieldIterator, group_field_number: u29, depth_remaining: usize) !@This()", .{});
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});

    if (group.fields.len == 0) {
        if (!group_fields_need_allocator(group)) {
            try e.print("_ = allocator;\n", .{});
        }
        try e.print("const result: @This() = .{{}};\n", .{});
    } else {
        try e.print("var result: @This() = .{{}};\n", .{});
        try e.print("errdefer result.deinit(allocator);\n", .{});
    }
    try e.print("while (try iter.next()) |field|", .{});
    try e.open_brace();
    // Check for egroup matching the group field number
    try e.print("if (field.value == .egroup and field.number == group_field_number) return result;\n", .{});
    try e.print("switch (field.number)", .{});
    try e.open_brace();

    // Use iter.data as the bytes source for nested decodes
    for (group.fields) |field| {
        try emit_decode_field_case(e, field, syntax, recursive_types);
    }

    // Unknown field handling (including nested sgroups)
    try e.print("else => switch (field.value)", .{});
    try e.open_brace();
    try e.print(".sgroup => try message.skip_group_depth(iter.data, &iter.pos, field.number, depth_remaining - 1),\n", .{});
    try e.print("else => {{}},\n", .{});
    try e.close_brace_comma();

    try e.close_brace_nosemi(); // switch
    try e.close_brace_nosemi(); // while
    try e.print("return error.EndOfStream;\n", .{});
    try e.close_brace_nosemi(); // fn
}

fn emit_group_deinit_method(e: *Emitter, group: ast.Group, recursive_types: *const RecursiveTypes) !void {
    try e.print("/// Free all allocator-owned memory\n", .{});
    try e.print("pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void", .{});
    try e.open_brace();
    for (group.fields) |field| {
        try emit_deinit_field(e, field, recursive_types);
    }
    try e.print("if (self._unknown_fields.len > 0) allocator.free(self._unknown_fields);\n", .{});
    try e.close_brace_nosemi();
}

fn emit_group_to_json_method(e: *Emitter, group: ast.Group, _: ast.Syntax) !void {
    try e.print("/// Serialize this group to proto-JSON format\n", .{});
    try e.print("pub fn to_json(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    if (group.fields.len > 0) {
        try e.print("try json.write_object_start(writer);\n", .{});
        try e.print("var first = true;\n", .{});
        for (group.fields) |field| {
            try emit_json_field(e, field, .proto2, "");
        }
        try e.print("try json.write_object_end(writer);\n", .{});
    } else {
        try e.print("_ = self;\n", .{});
        try e.print("try json.write_object_start(writer);\n", .{});
        try e.print("try json.write_object_end(writer);\n", .{});
    }
    try e.close_brace_nosemi();
}

fn emit_group_from_json_method(e: *Emitter, group: ast.Group, _: ast.Syntax, recursive_types: *const RecursiveTypes) !void {
    const json_mod = "json";

    // from_json entry point
    try e.print("/// Deserialize this group from proto-JSON format bytes\n", .{});
    try e.print("pub fn from_json(allocator: std.mem.Allocator, json_bytes: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("var scanner = {s}.JsonScanner.init(allocator, json_bytes);\n", .{json_mod});
    try e.print("defer scanner.deinit();\n", .{});
    try e.print("return try @This().from_json_scanner(allocator, &scanner);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    // from_json_scanner public wrapper (use @This() to avoid ambiguity with parent struct)
    try e.print("pub fn from_json_scanner(allocator: std.mem.Allocator, scanner: *{s}.JsonScanner) !@This()", .{json_mod});
    try e.open_brace();
    try e.print("return @This().from_json_scanner_inner(allocator, scanner, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    // from_json_scanner_inner with depth tracking
    try e.print("pub fn from_json_scanner_inner(allocator: std.mem.Allocator, scanner: *{s}.JsonScanner, depth_remaining: usize) !@This()", .{json_mod});
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});

    const has_group_fields = group.fields.len > 0;

    if (!group_fields_need_allocator(group) and !has_group_fields) {
        try e.print("_ = allocator;\n", .{});
    }
    if (!has_group_fields) {
        try e.print("const result: @This() = .{{}};\n", .{});
    } else {
        try e.print("var result: @This() = .{{}};\n", .{});
        try e.print("errdefer result.deinit(allocator);\n", .{});
        try e.print("var seen_fields: std.StringHashMapUnmanaged(void) = .{{}};\n", .{});
        try e.print("defer seen_fields.deinit(allocator);\n", .{});
    }
    try e.print("const start_tok = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (start_tok != .object_start) return error.UnexpectedToken;\n", .{});
    try e.print("while (true)", .{});
    try e.open_brace();
    try e.print("const tok = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("switch (tok)", .{});
    try e.open_brace();
    try e.print(".object_end => return result,\n", .{});

    if (!has_group_fields) {
        try e.print(".string => |_|", .{});
    } else {
        try e.print(".string => |key|", .{});
    }
    try e.open_brace();

    // Null check
    try e.print("if (try scanner.peek()) |peeked| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (peeked == .null_value) {{\n", .{});
    e.indent_level += 1;
    try e.print("_ = try scanner.next();\n", .{});
    try e.print("continue;\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});

    // Field matching
    var first_branch = true;
    for (group.fields) |field| {
        try emit_from_json_field_branch(e, field, .proto2, &first_branch, recursive_types, "");
    }

    // else: skip unknown
    if (first_branch) {
        try e.print("try {s}.skip_value(scanner);\n", .{json_mod});
    } else {
        try e.print(" else {{\n", .{});
        e.indent_level += 1;
        try e.print("try {s}.skip_value(scanner);\n", .{json_mod});
        e.indent_level -= 1;
        try e.print("}}\n", .{});
    }

    try e.close_brace_comma(); // .string => |key| { ... },
    try e.print("else => return error.UnexpectedToken,\n", .{});
    try e.close_brace_nosemi(); // switch
    try e.close_brace_nosemi(); // while
    try e.print("return result;\n", .{});
    try e.close_brace_nosemi(); // fn
}

fn emit_map_field(e: *Emitter, map_field: ast.MapField) !void {
    const escaped = types.escape_zig_keyword(map_field.name);
    if (types.is_string_key(map_field.key_type)) {
        // std.StringArrayHashMapUnmanaged(V)
        const value_type = switch (map_field.value_type) {
            .scalar => |s| types.scalar_zig_type(s),
            .named => |n| n,
            .enum_ref => |n| n,
        };
        try e.print("{f}: std.StringArrayHashMapUnmanaged({s}) = .empty,\n", .{ escaped, value_type });
    } else {
        // std.AutoArrayHashMapUnmanaged(K, V)
        const key_type = types.map_key_zig_type(map_field.key_type);
        const value_type = switch (map_field.value_type) {
            .scalar => |s| types.scalar_zig_type(s),
            .named => |n| n,
            .enum_ref => |n| n,
        };
        try e.print("{f}: std.AutoArrayHashMapUnmanaged({s}, {s}) = .empty,\n", .{ escaped, key_type, value_type });
    }
}

fn emit_oneof_type(e: *Emitter, oneof: ast.Oneof, syntax: ast.Syntax) !void {
    try e.print("/// Oneof union for mutually exclusive fields\n", .{});
    try e.print("pub const ", .{});
    try emit_oneof_type_name(e, oneof);
    try e.print_raw(" = union(enum)", .{});
    try e.open_brace();
    for (oneof.fields) |field| {
        const escaped = types.escape_zig_keyword(field.name);
        switch (field.type_name) {
            .scalar => |s| {
                try e.print("{f}: {s},\n", .{ escaped, types.scalar_zig_type(s) });
            },
            .named => |name| {
                try e.print("{f}: {s},\n", .{ escaped, name });
                _ = syntax;
            },
            .enum_ref => |name| {
                try e.print("{f}: {s},\n", .{ escaped, name });
            },
        }
    }
    try e.close_brace();
}

fn emit_oneof_type_name(e: *Emitter, oneof: ast.Oneof) !void {
    // Convert snake_case oneof name to PascalCase for the union type name
    // e.g., "my_oneof" -> "MyOneof"
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    var capitalize_next = true;
    for (oneof.name) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else {
            if (capitalize_next) {
                buf[len] = std.ascii.toUpper(c);
                capitalize_next = false;
            } else {
                buf[len] = c;
            }
            len += 1;
        }
    }
    try e.print_raw("{s}", .{buf[0..len]});
}

// ── Encode Method ─────────────────────────────────────────────────────

fn emit_encode_method(e: *Emitter, msg: ast.Message, syntax: ast.Syntax) !void {
    try e.print("/// Serialize this message to protobuf binary wire format\n", .{});
    try e.print("pub fn encode(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();

    // Collect all field-like things and sort by number
    const items = try collect_all_fields(e.allocator, msg);
    defer e.allocator.free(items);

    if (items.len > 0) {
        try e.print("const mw = message.MessageWriter.init(writer);\n", .{});
        for (items) |item| {
            switch (item) {
                .field => |f| try emit_encode_field(e, f, syntax),
                .map => |m| try emit_encode_map(e, m),
                .oneof => |o| try emit_encode_oneof(e, o),
                .group => |g| try emit_encode_group(e, g),
            }
        }
    }

    // Unknown fields
    try e.print("if (self._unknown_fields.len > 0) try writer.writeAll(self._unknown_fields);\n", .{});

    try e.close_brace_nosemi();
}

fn emit_encode_field(e: *Emitter, field: ast.Field, syntax: ast.Syntax) !void {
    const escaped = types.escape_zig_keyword(field.name);
    const num = field.number;

    switch (field.type_name) {
        .scalar => |s| {
            const write_method = types.scalar_write_method(s);
            switch (field.label) {
                .implicit => {
                    // Proto3 implicit: skip if default
                    if (s == .string or s == .bytes) {
                        try e.print("if (self.{f}.len > 0) try mw.{s}({d}, self.{f});\n", .{ escaped, write_method, num, escaped });
                    } else if (s == .bool) {
                        try e.print("if (self.{f}) try mw.{s}({d}, @intFromBool(self.{f}));\n", .{ escaped, write_method, num, escaped });
                    } else if (s == .double) {
                        // Preserve -0.0 for proto3 implicit presence checks.
                        try e.print("if (@as(u64, @bitCast(self.{f})) != 0) try mw.{s}({d}, @bitCast(self.{f}));\n", .{ escaped, write_method, num, escaped });
                    } else if (s == .float) {
                        // Preserve -0.0 for proto3 implicit presence checks.
                        try e.print("if (@as(u32, @bitCast(self.{f})) != 0) try mw.{s}({d}, @bitCast(self.{f}));\n", .{ escaped, write_method, num, escaped });
                    } else {
                        // integer types
                        try emit_encode_scalar_int(e, escaped, s, write_method, num, false);
                    }
                },
                .optional => {
                    try e.print("if (self.{f}) |v| ", .{escaped});
                    try emit_encode_scalar_value(e, "v", s, write_method, num);
                },
                .required => {
                    try emit_encode_scalar_self(e, escaped, s, write_method, num);
                },
                .repeated => {
                    if (types.is_packed(field, syntax)) {
                        try emit_encode_packed_scalar(e, escaped, s, num);
                    } else {
                        try e.print("for (self.{f}) |item| ", .{escaped});
                        try emit_encode_scalar_value(e, "item", s, write_method, num);
                    }
                },
            }
        },
        .named => |_| {
            switch (field.label) {
                .repeated => {
                    try e.print("for (self.{f}) |item|", .{escaped});
                    try e.open_brace();
                    try e.print("const sub_size = item.calc_size();\n", .{});
                    try e.print("try mw.write_len_prefix({d}, sub_size);\n", .{num});
                    try e.print("try item.encode(writer);\n", .{});
                    try e.close_brace_nosemi();
                },
                .optional, .implicit => {
                    try e.print("if (self.{f}) |sub|", .{escaped});
                    try e.open_brace();
                    try e.print("const sub_size = sub.calc_size();\n", .{});
                    try e.print("try mw.write_len_prefix({d}, sub_size);\n", .{num});
                    try e.print("try sub.encode(writer);\n", .{});
                    try e.close_brace_nosemi();
                },
                .required => {
                    try e.print("{{\n", .{});
                    e.indent_level += 1;
                    try e.print("const sub_size = self.{f}.calc_size();\n", .{escaped});
                    try e.print("try mw.write_len_prefix({d}, sub_size);\n", .{num});
                    try e.print("try self.{f}.encode(writer);\n", .{escaped});
                    e.indent_level -= 1;
                    try e.print("}}\n", .{});
                },
            }
        },
        .enum_ref => |_| {
            // Enums use varint wire type (same as int32)
            switch (field.label) {
                .implicit => {
                    try e.print("if (@intFromEnum(self.{f}) != 0) try mw.write_varint_field({d}, @as(u64, @bitCast(@as(i64, @intFromEnum(self.{f})))));\n", .{ escaped, num, escaped });
                },
                .optional => {
                    try e.print("if (self.{f}) |v| try mw.write_varint_field({d}, @as(u64, @bitCast(@as(i64, @intFromEnum(v)))));\n", .{ escaped, num });
                },
                .required => {
                    try e.print("try mw.write_varint_field({d}, @as(u64, @bitCast(@as(i64, @intFromEnum(self.{f})))));\n", .{ num, escaped });
                },
                .repeated => {
                    if (types.is_packed(field, syntax)) {
                        try emit_encode_packed_enum(e, escaped, num);
                    } else {
                        try e.print("for (self.{f}) |item| try mw.write_varint_field({d}, @as(u64, @bitCast(@as(i64, @intFromEnum(item)))));\n", .{ escaped, num });
                    }
                },
            }
        },
    }
}

fn emit_encode_scalar_int(e: *Emitter, escaped: types.EscapedName, s: ast.ScalarType, write_method: []const u8, num: i32, _: bool) !void {
    switch (s) {
        .int32 => try e.print("if (self.{f} != 0) try mw.{s}({d}, @as(u64, @bitCast(@as(i64, self.{f}))));\n", .{ escaped, write_method, num, escaped }),
        .int64 => try e.print("if (self.{f} != 0) try mw.{s}({d}, @as(u64, @bitCast(self.{f})));\n", .{ escaped, write_method, num, escaped }),
        .uint32 => try e.print("if (self.{f} != 0) try mw.{s}({d}, @as(u64, self.{f}));\n", .{ escaped, write_method, num, escaped }),
        .uint64 => try e.print("if (self.{f} != 0) try mw.{s}({d}, self.{f});\n", .{ escaped, write_method, num, escaped }),
        .sint32 => try e.print("if (self.{f} != 0) try mw.{s}({d}, @as(u64, encoding.zigzag_encode(self.{f})));\n", .{ escaped, write_method, num, escaped }),
        .sint64 => try e.print("if (self.{f} != 0) try mw.{s}({d}, encoding.zigzag_encode_64(self.{f}));\n", .{ escaped, write_method, num, escaped }),
        .fixed32, .sfixed32 => try e.print("if (self.{f} != 0) try mw.{s}({d}, @bitCast(self.{f}));\n", .{ escaped, write_method, num, escaped }),
        .fixed64, .sfixed64 => try e.print("if (self.{f} != 0) try mw.{s}({d}, @bitCast(self.{f}));\n", .{ escaped, write_method, num, escaped }),
        else => unreachable,
    }
}

fn emit_encode_scalar_value(e: *Emitter, val: []const u8, s: ast.ScalarType, write_method: []const u8, num: i32) !void {
    // Emits: try mw.write_*_field(N, <converted_val>);
    const conversion = scalar_value_conversion(s, val);
    try e.print_raw("try mw.{s}({d}, {s});\n", .{ write_method, num, conversion });
}

fn emit_encode_scalar_self(e: *Emitter, escaped: types.EscapedName, s: ast.ScalarType, write_method: []const u8, num: i32) !void {
    // For required fields - always write, using self.field
    switch (s) {
        .string, .bytes => {
            try e.print("try mw.{s}({d}, self.{f});\n", .{ write_method, num, escaped });
        },
        .bool => {
            try e.print("try mw.{s}({d}, @intFromBool(self.{f}));\n", .{ write_method, num, escaped });
        },
        .double, .float => {
            try e.print("try mw.{s}({d}, @bitCast(self.{f}));\n", .{ write_method, num, escaped });
        },
        .int32 => {
            try e.print("try mw.{s}({d}, @as(u64, @bitCast(@as(i64, self.{f}))));\n", .{ write_method, num, escaped });
        },
        .int64 => {
            try e.print("try mw.{s}({d}, @as(u64, @bitCast(self.{f})));\n", .{ write_method, num, escaped });
        },
        .uint32 => {
            try e.print("try mw.{s}({d}, @as(u64, self.{f}));\n", .{ write_method, num, escaped });
        },
        .uint64 => {
            try e.print("try mw.{s}({d}, self.{f});\n", .{ write_method, num, escaped });
        },
        .sint32 => {
            try e.print("try mw.{s}({d}, @as(u64, encoding.zigzag_encode(self.{f})));\n", .{ write_method, num, escaped });
        },
        .sint64 => {
            try e.print("try mw.{s}({d}, encoding.zigzag_encode_64(self.{f}));\n", .{ write_method, num, escaped });
        },
        .fixed32, .sfixed32 => {
            try e.print("try mw.{s}({d}, @bitCast(self.{f}));\n", .{ write_method, num, escaped });
        },
        .fixed64, .sfixed64 => {
            try e.print("try mw.{s}({d}, @bitCast(self.{f}));\n", .{ write_method, num, escaped });
        },
    }
}

fn emit_encode_packed_scalar(e: *Emitter, escaped: types.EscapedName, s: ast.ScalarType, num: i32) !void {
    try e.print("if (self.{f}.len > 0)", .{escaped});
    try e.open_brace();
    const cat = types.scalar_packed_category(s);
    switch (cat) {
        .varint => {
            try e.print("var packed_size: usize = 0;\n", .{});
            try e.print("for (self.{f}) |item| packed_size += {s};\n", .{ escaped, types.scalar_packed_varint_size_expr(s) });
            try e.print("try mw.write_len_prefix({d}, packed_size);\n", .{num});
            try e.print("for (self.{f}) |item| {s};\n", .{ escaped, types.scalar_packed_encode_expr(s) });
        },
        .fixed32 => {
            try e.print("try mw.write_len_prefix({d}, self.{f}.len * 4);\n", .{ num, escaped });
            try e.print("for (self.{f}) |item| {s};\n", .{ escaped, types.scalar_packed_encode_expr(s) });
        },
        .fixed64 => {
            try e.print("try mw.write_len_prefix({d}, self.{f}.len * 8);\n", .{ num, escaped });
            try e.print("for (self.{f}) |item| {s};\n", .{ escaped, types.scalar_packed_encode_expr(s) });
        },
    }
    try e.close_brace_nosemi();
}

fn emit_encode_packed_enum(e: *Emitter, escaped: types.EscapedName, num: i32) !void {
    try e.print("if (self.{f}.len > 0)", .{escaped});
    try e.open_brace();
    try e.print("var packed_size: usize = 0;\n", .{});
    try e.print("for (self.{f}) |item| packed_size += encoding.varint_size(@as(u64, @bitCast(@as(i64, @intFromEnum(item)))));\n", .{escaped});
    try e.print("try mw.write_len_prefix({d}, packed_size);\n", .{num});
    try e.print("for (self.{f}) |item| try encoding.encode_varint(writer, @as(u64, @bitCast(@as(i64, @intFromEnum(item)))));\n", .{escaped});
    try e.close_brace_nosemi();
}

fn scalar_value_conversion(s: ast.ScalarType, val: []const u8) []const u8 {
    // When val is "v" (default), return the pre-built strings
    if (std.mem.eql(u8, val, "v")) {
        return switch (s) {
            .string, .bytes => "v",
            .bool => "@intFromBool(v)",
            .double, .float => "@bitCast(v)",
            .int32 => "@as(u64, @bitCast(@as(i64, v)))",
            .int64 => "@as(u64, @bitCast(v))",
            .uint32 => "@as(u64, v)",
            .uint64 => "v",
            .sint32 => "@as(u64, encoding.zigzag_encode(v))",
            .sint64 => "encoding.zigzag_encode_64(v)",
            .fixed32, .sfixed32 => "@bitCast(v)",
            .fixed64, .sfixed64 => "@bitCast(v)",
        };
    }
    // When val is "item" (repeated), return the item variants
    return switch (s) {
        .string, .bytes => "item",
        .bool => "@intFromBool(item)",
        .double, .float => "@bitCast(item)",
        .int32 => "@as(u64, @bitCast(@as(i64, item)))",
        .int64 => "@as(u64, @bitCast(item))",
        .uint32 => "@as(u64, item)",
        .uint64 => "item",
        .sint32 => "@as(u64, encoding.zigzag_encode(item))",
        .sint64 => "encoding.zigzag_encode_64(item)",
        .fixed32, .sfixed32 => "@bitCast(item)",
        .fixed64, .sfixed64 => "@bitCast(item)",
    };
}

fn emit_encode_map(e: *Emitter, map_field: ast.MapField) !void {
    const escaped = types.escape_zig_keyword(map_field.name);
    const num = map_field.number;

    if (types.is_string_key(map_field.key_type)) {
        try e.print("for (self.{f}.keys(), self.{f}.values()) |key, val|", .{ escaped, escaped });
    } else {
        try e.print("for (self.{f}.keys(), self.{f}.values()) |key, val|", .{ escaped, escaped });
    }
    try e.open_brace();
    // Each map entry is encoded as a sub-message with field 1=key, field 2=value
    try e.print("var entry_size: usize = 0;\n", .{});
    try emit_map_entry_size_key(e, map_field.key_type);
    try emit_map_entry_size_value(e, map_field.value_type);
    try e.print("try mw.write_len_prefix({d}, entry_size);\n", .{num});
    try emit_map_entry_encode_key(e, map_field.key_type);
    try emit_map_entry_encode_value(e, map_field.value_type);
    try e.close_brace_nosemi();
}

fn emit_map_entry_size_key(e: *Emitter, key_type: ast.ScalarType) !void {
    const size_fn = types.scalar_size_fn(key_type);
    if (key_type == .string) {
        try e.print("entry_size += message.len_field_size(1, key.len);\n", .{});
    } else if (key_type == .fixed32 or key_type == .sfixed32) {
        try e.print("entry_size += message.i32_field_size(1);\n", .{});
    } else if (key_type == .fixed64 or key_type == .sfixed64) {
        try e.print("entry_size += message.i64_field_size(1);\n", .{});
    } else {
        try e.print("entry_size += message.{s}(1, {s});\n", .{ size_fn, scalar_key_wire_expr(key_type) });
    }
}

fn emit_map_entry_size_value(e: *Emitter, value_type: ast.TypeRef) !void {
    switch (value_type) {
        .scalar => |s| {
            const size_fn = types.scalar_size_fn(s);
            if (s == .string or s == .bytes) {
                try e.print("entry_size += message.len_field_size(2, val.len);\n", .{});
            } else if (s == .fixed32 or s == .sfixed32 or s == .float) {
                try e.print("entry_size += message.i32_field_size(2);\n", .{});
            } else if (s == .fixed64 or s == .sfixed64 or s == .double) {
                try e.print("entry_size += message.i64_field_size(2);\n", .{});
            } else {
                try e.print("entry_size += message.{s}(2, {s});\n", .{ size_fn, scalar_val_wire_expr(s) });
            }
        },
        .named => {
            try e.print("const val_size = val.calc_size();\n", .{});
            try e.print("entry_size += message.len_field_size(2, val_size);\n", .{});
        },
        .enum_ref => {
            try e.print("entry_size += message.varint_field_size(2, @as(u64, @bitCast(@as(i64, @intFromEnum(val)))));\n", .{});
        },
    }
}

fn emit_map_entry_encode_key(e: *Emitter, key_type: ast.ScalarType) !void {
    const write_method = types.scalar_write_method(key_type);
    if (key_type == .string) {
        try e.print("try mw.{s}(1, key);\n", .{write_method});
    } else {
        try e.print("try mw.{s}(1, {s});\n", .{ write_method, scalar_key_wire_expr(key_type) });
    }
}

fn emit_map_entry_encode_value(e: *Emitter, value_type: ast.TypeRef) !void {
    switch (value_type) {
        .scalar => |s| {
            const write_method = types.scalar_write_method(s);
            if (s == .string or s == .bytes) {
                try e.print("try mw.{s}(2, val);\n", .{write_method});
            } else {
                try e.print("try mw.{s}(2, {s});\n", .{ write_method, scalar_val_wire_expr(s) });
            }
        },
        .named => {
            try e.print("try mw.write_len_prefix(2, val_size);\n", .{});
            try e.print("try val.encode(writer);\n", .{});
        },
        .enum_ref => {
            try e.print("try mw.write_varint_field(2, @as(u64, @bitCast(@as(i64, @intFromEnum(val)))));\n", .{});
        },
    }
}

fn scalar_key_wire_expr(s: ast.ScalarType) []const u8 {
    return switch (s) {
        .int32 => "@as(u64, @bitCast(@as(i64, key)))",
        .int64 => "@as(u64, @bitCast(key))",
        .uint32 => "@as(u64, key)",
        .uint64 => "key",
        .sint32 => "@as(u64, encoding.zigzag_encode(key))",
        .sint64 => "encoding.zigzag_encode_64(key)",
        .bool => "@intFromBool(key)",
        .fixed32, .sfixed32 => "@bitCast(key)",
        .fixed64, .sfixed64 => "@bitCast(key)",
        .string => "key",
        else => unreachable,
    };
}

fn scalar_val_wire_expr(s: ast.ScalarType) []const u8 {
    return switch (s) {
        .int32 => "@as(u64, @bitCast(@as(i64, val)))",
        .int64 => "@as(u64, @bitCast(val))",
        .uint32 => "@as(u64, val)",
        .uint64 => "val",
        .sint32 => "@as(u64, encoding.zigzag_encode(val))",
        .sint64 => "encoding.zigzag_encode_64(val)",
        .bool => "@intFromBool(val)",
        .double, .float => "@bitCast(val)",
        .fixed32, .sfixed32 => "@bitCast(val)",
        .fixed64, .sfixed64 => "@bitCast(val)",
        .string, .bytes => "val",
    };
}

fn emit_encode_oneof(e: *Emitter, oneof: ast.Oneof) !void {
    const escaped = types.escape_zig_keyword(oneof.name);
    try e.print("if (self.{f}) |oneof_val| switch (oneof_val)", .{escaped});
    try e.open_brace();
    for (oneof.fields) |field| {
        const field_escaped = types.escape_zig_keyword(field.name);
        const num = field.number;
        switch (field.type_name) {
            .scalar => |s| {
                const write_method = types.scalar_write_method(s);
                const conversion = scalar_value_conversion(s, "v");
                try e.print(".{f} => |v| try mw.{s}({d}, {s}),\n", .{ field_escaped, write_method, num, conversion });
            },
            .named => {
                try e.print(".{f} => |sub|", .{field_escaped});
                try e.open_brace();
                try e.print("const sub_size = sub.calc_size();\n", .{});
                try e.print("try mw.write_len_prefix({d}, sub_size);\n", .{num});
                try e.print("try sub.encode(writer);\n", .{});
                try e.close_brace_comma();
            },
            .enum_ref => {
                try e.print(".{f} => |v| try mw.write_varint_field({d}, @as(u64, @bitCast(@as(i64, @intFromEnum(v))))),\n", .{ field_escaped, num });
            },
        }
    }
    try e.close_brace();
}

fn emit_encode_group(e: *Emitter, grp: ast.Group) !void {
    var name_buf: [256]u8 = undefined;
    const field_name = group_field_name(grp.name, &name_buf);
    const escaped = types.escape_zig_keyword(field_name);
    const num = grp.number;

    switch (grp.label) {
        .optional => {
            try e.print("if (self.{f}) |grp|", .{escaped});
            try e.open_brace();
            try e.print("try mw.write_sgroup_field({d});\n", .{num});
            try e.print("try grp.encode(writer);\n", .{});
            try e.print("try mw.write_egroup_field({d});\n", .{num});
            try e.close_brace_nosemi();
        },
        .required => {
            try e.print("{{\n", .{});
            e.indent_level += 1;
            try e.print("try mw.write_sgroup_field({d});\n", .{num});
            try e.print("try self.{f}.encode(writer);\n", .{escaped});
            try e.print("try mw.write_egroup_field({d});\n", .{num});
            e.indent_level -= 1;
            try e.print("}}\n", .{});
        },
        .repeated => {
            try e.print("for (self.{f}) |grp|", .{escaped});
            try e.open_brace();
            try e.print("try mw.write_sgroup_field({d});\n", .{num});
            try e.print("try grp.encode(writer);\n", .{});
            try e.print("try mw.write_egroup_field({d});\n", .{num});
            try e.close_brace_nosemi();
        },
        .implicit => {
            try e.print("if (self.{f}) |grp|", .{escaped});
            try e.open_brace();
            try e.print("try mw.write_sgroup_field({d});\n", .{num});
            try e.print("try grp.encode(writer);\n", .{});
            try e.print("try mw.write_egroup_field({d});\n", .{num});
            try e.close_brace_nosemi();
        },
    }
}

// ── Calc Size Method ──────────────────────────────────────────────────

fn emit_calc_size_method(e: *Emitter, msg: ast.Message, syntax: ast.Syntax) !void {
    try e.print("/// Calculate the serialized size in bytes without encoding\n", .{});
    try e.print("pub fn calc_size(self: @This()) usize", .{});
    try e.open_brace();
    try e.print("var size: usize = 0;\n", .{});

    const items = try collect_all_fields(e.allocator, msg);
    defer e.allocator.free(items);

    for (items) |item| {
        switch (item) {
            .field => |f| try emit_size_field(e, f, syntax),
            .map => |m| try emit_size_map(e, m),
            .oneof => |o| try emit_size_oneof(e, o),
            .group => |g| try emit_size_group(e, g),
        }
    }

    try e.print("size += self._unknown_fields.len;\n", .{});
    try e.print("return size;\n", .{});

    try e.close_brace_nosemi();
}

fn emit_size_field(e: *Emitter, field: ast.Field, syntax: ast.Syntax) !void {
    const escaped = types.escape_zig_keyword(field.name);

    switch (field.type_name) {
        .scalar => |s| {
            const size_fn = types.scalar_size_fn(s);
            switch (field.label) {
                .implicit => {
                    if (s == .string or s == .bytes) {
                        try e.print("if (self.{f}.len > 0) size += message.{s}({d}, self.{f}.len);\n", .{ escaped, size_fn, field.number, escaped });
                    } else if (s == .bool) {
                        try e.print("if (self.{f}) size += message.{s}({d}, 1);\n", .{ escaped, size_fn, field.number });
                    } else if (s == .double) {
                        // Preserve -0.0 for proto3 implicit presence checks.
                        try e.print("if (@as(u64, @bitCast(self.{f})) != 0) size += message.{s}({d});\n", .{ escaped, size_fn, field.number });
                    } else if (s == .float) {
                        // Preserve -0.0 for proto3 implicit presence checks.
                        try e.print("if (@as(u32, @bitCast(self.{f})) != 0) size += message.{s}({d});\n", .{ escaped, size_fn, field.number });
                    } else {
                        try emit_size_scalar_int(e, escaped, s, size_fn, field.number, false);
                    }
                },
                .optional => {
                    // For fixed-size types, the value isn't needed for size calc
                    const needs_value = switch (s) {
                        .double, .float, .fixed32, .sfixed32, .fixed64, .sfixed64 => false,
                        else => true,
                    };
                    if (needs_value) {
                        try e.print("if (self.{f}) |v| ", .{escaped});
                    } else {
                        try e.print("if (self.{f} != null) ", .{escaped});
                    }
                    try emit_size_scalar_optional(e, s, size_fn, field.number);
                },
                .required => {
                    try emit_size_scalar_required(e, escaped, s, size_fn, field.number);
                },
                .repeated => {
                    if (types.is_packed(field, syntax)) {
                        try emit_size_packed_scalar(e, escaped, s, field.number);
                    } else {
                        const needs_value = switch (s) {
                            .double, .float, .fixed32, .sfixed32, .fixed64, .sfixed64 => false,
                            else => true,
                        };
                        if (needs_value) {
                            try e.print("for (self.{f}) |item| ", .{escaped});
                        } else {
                            try e.print("for (self.{f}) |_| ", .{escaped});
                        }
                        try emit_size_scalar_repeated(e, s, size_fn, field.number);
                    }
                },
            }
        },
        .named => {
            switch (field.label) {
                .repeated => {
                    try e.print("for (self.{f}) |item| size += message.len_field_size({d}, item.calc_size());\n", .{ escaped, field.number });
                },
                .optional, .implicit => {
                    try e.print("if (self.{f}) |sub| size += message.len_field_size({d}, sub.calc_size());\n", .{ escaped, field.number });
                },
                .required => {
                    try e.print("size += message.len_field_size({d}, self.{f}.calc_size());\n", .{ field.number, escaped });
                },
            }
        },
        .enum_ref => {
            switch (field.label) {
                .implicit => {
                    try e.print("if (@intFromEnum(self.{f}) != 0) size += message.varint_field_size({d}, @as(u64, @bitCast(@as(i64, @intFromEnum(self.{f})))));\n", .{ escaped, field.number, escaped });
                },
                .optional => {
                    try e.print("if (self.{f}) |v| size += message.varint_field_size({d}, @as(u64, @bitCast(@as(i64, @intFromEnum(v)))));\n", .{ escaped, field.number });
                },
                .required => {
                    try e.print("size += message.varint_field_size({d}, @as(u64, @bitCast(@as(i64, @intFromEnum(self.{f})))));\n", .{ field.number, escaped });
                },
                .repeated => {
                    if (types.is_packed(field, syntax)) {
                        try emit_size_packed_enum(e, escaped, field.number);
                    } else {
                        try e.print("for (self.{f}) |item| size += message.varint_field_size({d}, @as(u64, @bitCast(@as(i64, @intFromEnum(item)))));\n", .{ escaped, field.number });
                    }
                },
            }
        },
    }
}

fn emit_size_scalar_int(e: *Emitter, escaped: types.EscapedName, s: ast.ScalarType, size_fn: []const u8, num: i32, _: bool) !void {
    switch (s) {
        .fixed32, .sfixed32 => {
            try e.print("if (self.{f} != 0) size += message.{s}({d});\n", .{ escaped, size_fn, num });
        },
        .fixed64, .sfixed64 => {
            try e.print("if (self.{f} != 0) size += message.{s}({d});\n", .{ escaped, size_fn, num });
        },
        .int32 => {
            try e.print("if (self.{f} != 0) size += message.{s}({d}, @as(u64, @bitCast(@as(i64, self.{f}))));\n", .{ escaped, size_fn, num, escaped });
        },
        .int64 => {
            try e.print("if (self.{f} != 0) size += message.{s}({d}, @as(u64, @bitCast(self.{f})));\n", .{ escaped, size_fn, num, escaped });
        },
        .uint32 => {
            try e.print("if (self.{f} != 0) size += message.{s}({d}, @as(u64, self.{f}));\n", .{ escaped, size_fn, num, escaped });
        },
        .uint64 => {
            try e.print("if (self.{f} != 0) size += message.{s}({d}, self.{f});\n", .{ escaped, size_fn, num, escaped });
        },
        .sint32 => {
            try e.print("if (self.{f} != 0) size += message.{s}({d}, @as(u64, encoding.zigzag_encode(self.{f})));\n", .{ escaped, size_fn, num, escaped });
        },
        .sint64 => {
            try e.print("if (self.{f} != 0) size += message.{s}({d}, encoding.zigzag_encode_64(self.{f}));\n", .{ escaped, size_fn, num, escaped });
        },
        else => unreachable,
    }
}

fn emit_size_scalar_optional(e: *Emitter, s: ast.ScalarType, size_fn: []const u8, num: i32) !void {
    switch (s) {
        .string, .bytes => try e.print_raw("size += message.{s}({d}, v.len);\n", .{ size_fn, num }),
        .bool => try e.print_raw("size += message.{s}({d}, @intFromBool(v));\n", .{ size_fn, num }),
        .double, .float, .fixed32, .sfixed32, .fixed64, .sfixed64 => try e.print_raw("size += message.{s}({d});\n", .{ size_fn, num }),
        .int32 => try e.print_raw("size += message.{s}({d}, @as(u64, @bitCast(@as(i64, v))));\n", .{ size_fn, num }),
        .int64 => try e.print_raw("size += message.{s}({d}, @as(u64, @bitCast(v)));\n", .{ size_fn, num }),
        .uint32 => try e.print_raw("size += message.{s}({d}, @as(u64, v));\n", .{ size_fn, num }),
        .uint64 => try e.print_raw("size += message.{s}({d}, v);\n", .{ size_fn, num }),
        .sint32 => try e.print_raw("size += message.{s}({d}, @as(u64, encoding.zigzag_encode(v)));\n", .{ size_fn, num }),
        .sint64 => try e.print_raw("size += message.{s}({d}, encoding.zigzag_encode_64(v));\n", .{ size_fn, num }),
    }
}

fn emit_size_scalar_required(e: *Emitter, escaped: types.EscapedName, s: ast.ScalarType, size_fn: []const u8, num: i32) !void {
    switch (s) {
        .string, .bytes => try e.print("size += message.{s}({d}, self.{f}.len);\n", .{ size_fn, num, escaped }),
        .bool => try e.print("size += message.{s}({d}, @intFromBool(self.{f}));\n", .{ size_fn, num, escaped }),
        .double, .float, .fixed32, .sfixed32, .fixed64, .sfixed64 => try e.print("size += message.{s}({d});\n", .{ size_fn, num }),
        .int32 => try e.print("size += message.{s}({d}, @as(u64, @bitCast(@as(i64, self.{f}))));\n", .{ size_fn, num, escaped }),
        .int64 => try e.print("size += message.{s}({d}, @as(u64, @bitCast(self.{f})));\n", .{ size_fn, num, escaped }),
        .uint32 => try e.print("size += message.{s}({d}, @as(u64, self.{f}));\n", .{ size_fn, num, escaped }),
        .uint64 => try e.print("size += message.{s}({d}, self.{f});\n", .{ size_fn, num, escaped }),
        .sint32 => try e.print("size += message.{s}({d}, @as(u64, encoding.zigzag_encode(self.{f})));\n", .{ size_fn, num, escaped }),
        .sint64 => try e.print("size += message.{s}({d}, encoding.zigzag_encode_64(self.{f}));\n", .{ size_fn, num, escaped }),
    }
}

fn emit_size_scalar_repeated(e: *Emitter, s: ast.ScalarType, size_fn: []const u8, num: i32) !void {
    switch (s) {
        .string, .bytes => try e.print_raw("size += message.{s}({d}, item.len);\n", .{ size_fn, num }),
        .bool => try e.print_raw("size += message.{s}({d}, @intFromBool(item));\n", .{ size_fn, num }),
        .double, .float, .fixed32, .sfixed32, .fixed64, .sfixed64 => try e.print_raw("size += message.{s}({d});\n", .{ size_fn, num }),
        .int32 => try e.print_raw("size += message.{s}({d}, @as(u64, @bitCast(@as(i64, item))));\n", .{ size_fn, num }),
        .int64 => try e.print_raw("size += message.{s}({d}, @as(u64, @bitCast(item)));\n", .{ size_fn, num }),
        .uint32 => try e.print_raw("size += message.{s}({d}, @as(u64, item));\n", .{ size_fn, num }),
        .uint64 => try e.print_raw("size += message.{s}({d}, item);\n", .{ size_fn, num }),
        .sint32 => try e.print_raw("size += message.{s}({d}, @as(u64, encoding.zigzag_encode(item)));\n", .{ size_fn, num }),
        .sint64 => try e.print_raw("size += message.{s}({d}, encoding.zigzag_encode_64(item));\n", .{ size_fn, num }),
    }
}

fn emit_size_packed_scalar(e: *Emitter, escaped: types.EscapedName, s: ast.ScalarType, num: i32) !void {
    try e.print("if (self.{f}.len > 0)", .{escaped});
    try e.open_brace();
    const cat = types.scalar_packed_category(s);
    switch (cat) {
        .varint => {
            try e.print("var packed_size: usize = 0;\n", .{});
            try e.print("for (self.{f}) |item| packed_size += {s};\n", .{ escaped, types.scalar_packed_varint_size_expr(s) });
            try e.print("size += message.len_field_size({d}, packed_size);\n", .{num});
        },
        .fixed32 => {
            try e.print("size += message.len_field_size({d}, self.{f}.len * 4);\n", .{ num, escaped });
        },
        .fixed64 => {
            try e.print("size += message.len_field_size({d}, self.{f}.len * 8);\n", .{ num, escaped });
        },
    }
    try e.close_brace_nosemi();
}

fn emit_size_packed_enum(e: *Emitter, escaped: types.EscapedName, num: i32) !void {
    try e.print("if (self.{f}.len > 0)", .{escaped});
    try e.open_brace();
    try e.print("var packed_size: usize = 0;\n", .{});
    try e.print("for (self.{f}) |item| packed_size += encoding.varint_size(@as(u64, @bitCast(@as(i64, @intFromEnum(item)))));\n", .{escaped});
    try e.print("size += message.len_field_size({d}, packed_size);\n", .{num});
    try e.close_brace_nosemi();
}

fn emit_size_map(e: *Emitter, map_field: ast.MapField) !void {
    const escaped = types.escape_zig_keyword(map_field.name);
    const num = map_field.number;

    const key_needs_value = !is_fixed_size_scalar(map_field.key_type);
    const val_needs_value = switch (map_field.value_type) {
        .scalar => |s| !is_fixed_size_scalar(s),
        .named => true,
        .enum_ref => true,
    };
    const key_capture: []const u8 = if (key_needs_value) "key" else "_";
    const val_capture: []const u8 = if (val_needs_value) "val" else "_";
    try e.print("for (self.{f}.keys(), self.{f}.values()) |{s}, {s}|", .{ escaped, escaped, key_capture, val_capture });
    try e.open_brace();
    try e.print("var entry_size: usize = 0;\n", .{});
    try emit_map_entry_size_key(e, map_field.key_type);
    try emit_map_entry_size_value(e, map_field.value_type);
    try e.print("size += message.len_field_size({d}, entry_size);\n", .{num});
    try e.close_brace_nosemi();
}

fn is_fixed_size_scalar(s: ast.ScalarType) bool {
    return switch (s) {
        .fixed32, .sfixed32, .float => true,
        .fixed64, .sfixed64, .double => true,
        else => false,
    };
}

fn emit_size_oneof(e: *Emitter, oneof: ast.Oneof) !void {
    const escaped = types.escape_zig_keyword(oneof.name);
    try e.print("if (self.{f}) |oneof_val| switch (oneof_val)", .{escaped});
    try e.open_brace();
    for (oneof.fields) |field| {
        const field_escaped = types.escape_zig_keyword(field.name);
        const num = field.number;
        switch (field.type_name) {
            .scalar => |s| {
                const size_fn = types.scalar_size_fn(s);
                switch (s) {
                    .string, .bytes => try e.print(".{f} => |v| size += message.{s}({d}, v.len),\n", .{ field_escaped, size_fn, num }),
                    .bool => try e.print(".{f} => |v| size += message.{s}({d}, @intFromBool(v)),\n", .{ field_escaped, size_fn, num }),
                    .double, .float, .fixed32, .sfixed32, .fixed64, .sfixed64 => try e.print(".{f} => size += message.{s}({d}),\n", .{ field_escaped, size_fn, num }),
                    .int32 => try e.print(".{f} => |v| size += message.{s}({d}, @as(u64, @bitCast(@as(i64, v)))),\n", .{ field_escaped, size_fn, num }),
                    .int64 => try e.print(".{f} => |v| size += message.{s}({d}, @as(u64, @bitCast(v))),\n", .{ field_escaped, size_fn, num }),
                    .uint32 => try e.print(".{f} => |v| size += message.{s}({d}, @as(u64, v)),\n", .{ field_escaped, size_fn, num }),
                    .uint64 => try e.print(".{f} => |v| size += message.{s}({d}, v),\n", .{ field_escaped, size_fn, num }),
                    .sint32 => try e.print(".{f} => |v| size += message.{s}({d}, @as(u64, encoding.zigzag_encode(v))),\n", .{ field_escaped, size_fn, num }),
                    .sint64 => try e.print(".{f} => |v| size += message.{s}({d}, encoding.zigzag_encode_64(v)),\n", .{ field_escaped, size_fn, num }),
                }
            },
            .named => {
                try e.print(".{f} => |sub| size += message.len_field_size({d}, sub.calc_size()),\n", .{ field_escaped, num });
            },
            .enum_ref => {
                try e.print(".{f} => |v| size += message.varint_field_size({d}, @as(u64, @bitCast(@as(i64, @intFromEnum(v))))),\n", .{ field_escaped, num });
            },
        }
    }
    try e.close_brace();
}

fn emit_size_group(e: *Emitter, grp: ast.Group) !void {
    var name_buf: [256]u8 = undefined;
    const field_name = group_field_name(grp.name, &name_buf);
    const escaped = types.escape_zig_keyword(field_name);
    const num = grp.number;

    switch (grp.label) {
        .optional => {
            try e.print("if (self.{f}) |grp| size += message.sgroup_tag_size({d}) + grp.calc_size() + message.egroup_tag_size({d});\n", .{ escaped, num, num });
        },
        .required => {
            try e.print("size += message.sgroup_tag_size({d}) + self.{f}.calc_size() + message.egroup_tag_size({d});\n", .{ num, escaped, num });
        },
        .repeated => {
            try e.print("for (self.{f}) |grp| size += message.sgroup_tag_size({d}) + grp.calc_size() + message.egroup_tag_size({d});\n", .{ escaped, num, num });
        },
        .implicit => {
            try e.print("if (self.{f}) |grp| size += message.sgroup_tag_size({d}) + grp.calc_size() + message.egroup_tag_size({d});\n", .{ escaped, num, num });
        },
    }
}

// ── Decode Method ─────────────────────────────────────────────────────

fn emit_decode_method(e: *Emitter, msg: ast.Message, syntax: ast.Syntax, recursive_types: *const RecursiveTypes) !void {
    // Public wrapper with default depth
    try e.print("/// Deserialize from protobuf binary wire format bytes. Caller must call deinit when done\n", .{});
    try e.print("pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("return @This().decode_inner(allocator, bytes, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    // Inner decode with depth tracking
    // Use explicit error set for recursive types to break error set cycles
    if (recursive_types.contains(msg.name)) {
        try e.print("pub fn decode_inner(allocator: std.mem.Allocator, bytes: []const u8, depth_remaining: usize) message.DecodeError!@This()", .{});
    } else {
        try e.print("pub fn decode_inner(allocator: std.mem.Allocator, bytes: []const u8, depth_remaining: usize) !@This()", .{});
    }
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});

    try e.print("var result: @This() = .{{}};\n", .{});
    try e.print("errdefer result.deinit(allocator);\n", .{});
    try e.print("var unknown_writer: std.Io.Writer.Allocating = .init(allocator);\n", .{});
    try e.print("defer unknown_writer.deinit();\n", .{});
    try e.print("var iter = message.iterate_fields(bytes);\n", .{});
    try e.print("while (true)", .{});
    try e.open_brace();
    try e.print("const field_start = iter.pos;\n", .{});
    try e.print("const field = (try iter.next()) orelse break;\n", .{});
    try e.print("switch (field.number)", .{});
    try e.open_brace();

    // Regular fields
    for (msg.fields) |field| {
        try emit_decode_field_case(e, field, syntax, recursive_types);
    }

    // Map fields
    for (msg.maps) |map_field| {
        try emit_decode_map_case(e, map_field, syntax);
    }

    // Oneof fields
    for (msg.oneofs) |oneof| {
        for (oneof.fields) |field| {
            try emit_decode_oneof_field_case(e, field, oneof, syntax);
        }
    }

    // Group fields
    for (msg.groups) |grp| {
        try emit_decode_group_case(e, grp);
    }

    // else => unknown fields — preserve bytes and validate group correctness
    try e.print("else => switch (field.value) {{\n", .{});
    e.indent_level += 1;
    try e.print(".egroup => return error.InvalidWireType,\n", .{});
    try e.print(".sgroup => {{\n", .{});
    e.indent_level += 1;
    try e.print("try message.skip_group_depth(bytes, &iter.pos, field.number, depth_remaining - 1);\n", .{});
    try e.print("unknown_writer.writer.writeAll(bytes[field_start..iter.pos]) catch return error.OutOfMemory;\n", .{});
    e.indent_level -= 1;
    try e.print("}},\n", .{});
    try e.print("else => unknown_writer.writer.writeAll(bytes[field_start..iter.pos]) catch return error.OutOfMemory,\n", .{});
    e.indent_level -= 1;
    try e.print("}},\n", .{});

    try e.close_brace_nosemi(); // switch
    try e.close_brace_nosemi(); // while
    try e.print("if (unknown_writer.written().len > 0) result._unknown_fields = try unknown_writer.toOwnedSlice();\n", .{});
    try e.print("return result;\n", .{});
    try e.close_brace_nosemi(); // fn
}

fn emit_decode_field_case(e: *Emitter, field: ast.Field, syntax: ast.Syntax, recursive_types: *const RecursiveTypes) !void {
    const escaped = types.escape_zig_keyword(field.name);
    const num = field.number;

    try e.print("{d} =>", .{num});

    switch (field.type_name) {
        .scalar => |s| {
            switch (field.label) {
                .implicit, .required, .optional => {
                    // Wire type guard: skip field if wire type doesn't match expected
                    const wire = types.scalar_wire_variant(s);
                    if (s == .string and syntax == .proto3) {
                        try e.print_raw(" if (field.value == {s})", .{wire});
                        try e.open_brace();
                        try e.print("try message.validate_utf8(field.value.len);\n", .{});
                        try emit_free_old_scalar(e, field.label, escaped, s);
                        try e.print("result.{f} = try allocator.dupe(u8, field.value.len);\n", .{escaped});
                        e.indent_level -= 1;
                        try e.print("}} else return error.InvalidWireType,\n", .{});
                    } else if (s == .string or s == .bytes) {
                        try e.print_raw(" if (field.value == {s})", .{wire});
                        try e.open_brace();
                        try emit_free_old_scalar(e, field.label, escaped, s);
                        try e.print("result.{f} = try allocator.dupe(u8, {s});\n", .{ escaped, types.scalar_decode_expr(s) });
                        e.indent_level -= 1;
                        try e.print("}} else return error.InvalidWireType,\n", .{});
                    } else {
                        try e.print_raw(" if (field.value == {s}) {{ result.{f} = {s}; }} else return error.InvalidWireType,\n", .{ wire, escaped, types.scalar_decode_expr(s) });
                    }
                },
                .repeated => {
                    if (types.is_packable_scalar(s)) {
                        // Handle both packed (LEN) and individual element encoding
                        // Already safe — switch on field.value with else => {}
                        try e.print_raw(" switch (field.value)", .{});
                        try e.open_brace();
                        // Packed encoding case
                        try e.print(".len => |packed_data|", .{});
                        try e.open_brace();
                        try e.print("var count: usize = 0;\n", .{});
                        try e.print("var count_iter = {s}.init(packed_data);\n", .{types.scalar_packed_iterator(s)});
                        try e.print("while (try count_iter.next()) |_| count += 1;\n", .{});
                        try e.print("const old = result.{f};\n", .{escaped});
                        try e.print("const new = try allocator.alloc({s}, old.len + count);\n", .{types.scalar_zig_type(s)});
                        try e.print("errdefer allocator.free(new);\n", .{});
                        try e.print("@memcpy(new[0..old.len], old);\n", .{});
                        try e.print("var packed_iter = {s}.init(packed_data);\n", .{types.scalar_packed_iterator(s)});
                        try e.print("var idx: usize = old.len;\n", .{});
                        try e.print("while (try packed_iter.next()) |v| : (idx += 1) new[idx] = {s};\n", .{types.scalar_packed_decode_expr(s)});
                        try e.print("if (old.len > 0) allocator.free(old);\n", .{});
                        try e.print("result.{f} = new;\n", .{escaped});
                        e.indent_level -= 1;
                        try e.print("}},\n", .{});
                        // Individual element case
                        try e.print("{s} =>", .{types.scalar_wire_variant(s)});
                        try e.open_brace();
                        try e.print("const old = result.{f};\n", .{escaped});
                        try e.print("const new = try allocator.alloc({s}, old.len + 1);\n", .{types.scalar_zig_type(s)});
                        try e.print("@memcpy(new[0..old.len], old);\n", .{});
                        try e.print("new[old.len] = {s};\n", .{types.scalar_decode_expr(s)});
                        try e.print("if (old.len > 0) allocator.free(old);\n", .{});
                        try e.print("result.{f} = new;\n", .{escaped});
                        e.indent_level -= 1;
                        try e.print("}},\n", .{});
                        try e.print("else => return error.InvalidWireType,\n", .{});
                        // Close switch
                        e.indent_level -= 1;
                        try e.print("}},\n", .{});
                    } else {
                        // string/bytes: always LEN wire type, no packed encoding
                        try e.print_raw(" if (field.value == .len)", .{});
                        try e.open_brace();
                        try e.print("const old = result.{f};\n", .{escaped});
                        try e.print("const new = try allocator.alloc({s}, old.len + 1);\n", .{types.scalar_zig_type(s)});
                        try e.print("errdefer allocator.free(new);\n", .{});
                        try e.print("@memcpy(new[0..old.len], old);\n", .{});
                        if (s == .string and syntax == .proto3) {
                            try e.print("try message.validate_utf8(field.value.len);\n", .{});
                        }
                        try e.print("new[old.len] = try allocator.dupe(u8, field.value.len);\n", .{});
                        try e.print("if (old.len > 0) allocator.free(old);\n", .{});
                        try e.print("result.{f} = new;\n", .{escaped});
                        e.indent_level -= 1;
                        try e.print("}} else return error.InvalidWireType,\n", .{});
                    }
                },
            }
        },
        .named => |name| {
            const is_recursive = recursive_types.contains(name);
            switch (field.label) {
                .optional, .implicit => {
                    if (is_recursive) {
                        // Heap-allocate for recursive types and merge duplicate message fields.
                        try e.print_raw(" if (field.value == .len)", .{});
                        try e.open_brace();
                        try e.print("if (result.{f}) |existing_ptr|", .{escaped});
                        try e.open_brace();
                        try e.print("const old_size = existing_ptr.calc_size();\n", .{});
                        try e.print("const merged_buf = try allocator.alloc(u8, old_size + field.value.len.len);\n", .{});
                        try e.print("defer allocator.free(merged_buf);\n", .{});
                        try e.print("var merged_writer = std.Io.Writer.fixed(merged_buf);\n", .{});
                        try e.print("existing_ptr.encode(&merged_writer) catch return error.OutOfMemory;\n", .{});
                        try e.print("@memcpy(merged_buf[old_size..], field.value.len);\n", .{});
                        try e.print("const merged_val = try {s}.decode_inner(allocator, merged_buf, depth_remaining - 1);\n", .{name});
                        try e.print("existing_ptr.deinit(allocator);\n", .{});
                        try e.print("existing_ptr.* = merged_val;\n", .{});
                        try e.close_brace_nosemi();
                        try e.print("else", .{});
                        try e.open_brace();
                        try e.print("const val = try {s}.decode_inner(allocator, field.value.len, depth_remaining - 1);\n", .{name});
                        try e.print("const ptr = try allocator.create({s});\n", .{name});
                        try e.print("ptr.* = val;\n", .{});
                        try e.print("result.{f} = ptr;\n", .{escaped});
                        try e.close_brace_nosemi();
                        e.indent_level -= 1;
                        try e.print("}} else return error.InvalidWireType,\n", .{});
                    } else {
                        try e.print_raw(" if (field.value == .len)", .{});
                        try e.open_brace();
                        try e.print("if (result.{f}) |*existing|", .{escaped});
                        try e.open_brace();
                        try e.print("const old_size = existing.calc_size();\n", .{});
                        try e.print("const merged_buf = try allocator.alloc(u8, old_size + field.value.len.len);\n", .{});
                        try e.print("defer allocator.free(merged_buf);\n", .{});
                        try e.print("var merged_writer = std.Io.Writer.fixed(merged_buf);\n", .{});
                        try e.print("existing.encode(&merged_writer) catch return error.OutOfMemory;\n", .{});
                        try e.print("@memcpy(merged_buf[old_size..], field.value.len);\n", .{});
                        try e.print("const merged_val = try @TypeOf(result.{f}.?).decode_inner(allocator, merged_buf, depth_remaining - 1);\n", .{escaped});
                        try e.print("existing.deinit(allocator);\n", .{});
                        try e.print("existing.* = merged_val;\n", .{});
                        try e.close_brace_nosemi();
                        try e.print("else {{ result.{f} = try @TypeOf(result.{f}.?).decode_inner(allocator, field.value.len, depth_remaining - 1); }}\n", .{ escaped, escaped });
                        e.indent_level -= 1;
                        try e.print("}} else return error.InvalidWireType,\n", .{});
                    }
                },
                .required => {
                    try e.print_raw(" if (field.value == .len)", .{});
                    try e.open_brace();
                    try e.print("const old_size = result.{f}.calc_size();\n", .{escaped});
                    try e.print("const merged_buf = try allocator.alloc(u8, old_size + field.value.len.len);\n", .{});
                    try e.print("defer allocator.free(merged_buf);\n", .{});
                    try e.print("var merged_writer = std.Io.Writer.fixed(merged_buf);\n", .{});
                    try e.print("result.{f}.encode(&merged_writer) catch return error.OutOfMemory;\n", .{escaped});
                    try e.print("@memcpy(merged_buf[old_size..], field.value.len);\n", .{});
                    try e.print("const merged_val = try @TypeOf(result.{f}).decode_inner(allocator, merged_buf, depth_remaining - 1);\n", .{escaped});
                    try e.print("result.{f}.deinit(allocator);\n", .{escaped});
                    try e.print("result.{f} = merged_val;\n", .{escaped});
                    e.indent_level -= 1;
                    try e.print("}} else return error.InvalidWireType,\n", .{});
                },
                .repeated => {
                    try e.print_raw(" if (field.value == .len)", .{});
                    try e.open_brace();
                    try e.print("const old = result.{f};\n", .{escaped});
                    try e.print("const new = try allocator.alloc(@TypeOf(old[0]), old.len + 1);\n", .{});
                    try e.print("errdefer allocator.free(new);\n", .{});
                    try e.print("@memcpy(new[0..old.len], old);\n", .{});
                    try e.print("new[old.len] = try @TypeOf(old[0]).decode_inner(allocator, field.value.len, depth_remaining - 1);\n", .{});
                    try e.print("if (old.len > 0) allocator.free(old);\n", .{});
                    try e.print("result.{f} = new;\n", .{escaped});
                    e.indent_level -= 1;
                    try e.print("}} else return error.InvalidWireType,\n", .{});
                },
            }
        },
        .enum_ref => {
            const decode_expr = "@enumFromInt(@as(i32, @bitCast(@as(u32, @truncate(field.value.varint)))))";
            const packed_decode_expr = "@enumFromInt(@as(i32, @bitCast(@as(u32, @truncate(v)))))";
            switch (field.label) {
                .implicit, .required, .optional => {
                    try e.print_raw(" if (field.value == .varint) {{ result.{f} = {s}; }} else return error.InvalidWireType,\n", .{ escaped, decode_expr });
                },
                .repeated => {
                    // Handle both packed (LEN) and individual varint encoding
                    // Already safe — switch on field.value with else => {}
                    try e.print_raw(" switch (field.value)", .{});
                    try e.open_brace();
                    // Packed encoding case
                    try e.print(".len => |packed_data|", .{});
                    try e.open_brace();
                    try e.print("var count: usize = 0;\n", .{});
                    try e.print("var count_iter = message.PackedVarintIterator.init(packed_data);\n", .{});
                    try e.print("while (try count_iter.next()) |_| count += 1;\n", .{});
                    try e.print("const old = result.{f};\n", .{escaped});
                    try e.print("const new = try allocator.alloc(@TypeOf(old[0]), old.len + count);\n", .{});
                    try e.print("errdefer allocator.free(new);\n", .{});
                    try e.print("@memcpy(new[0..old.len], old);\n", .{});
                    try e.print("var packed_iter = message.PackedVarintIterator.init(packed_data);\n", .{});
                    try e.print("var idx: usize = old.len;\n", .{});
                    try e.print("while (try packed_iter.next()) |v| : (idx += 1) new[idx] = {s};\n", .{packed_decode_expr});
                    try e.print("if (old.len > 0) allocator.free(old);\n", .{});
                    try e.print("result.{f} = new;\n", .{escaped});
                    e.indent_level -= 1;
                    try e.print("}},\n", .{});
                    // Individual varint case
                    try e.print(".varint =>", .{});
                    try e.open_brace();
                    try e.print("const old = result.{f};\n", .{escaped});
                    try e.print("const new = try allocator.alloc(@TypeOf(old[0]), old.len + 1);\n", .{});
                    try e.print("@memcpy(new[0..old.len], old);\n", .{});
                    try e.print("new[old.len] = {s};\n", .{decode_expr});
                    try e.print("if (old.len > 0) allocator.free(old);\n", .{});
                    try e.print("result.{f} = new;\n", .{escaped});
                    e.indent_level -= 1;
                    try e.print("}},\n", .{});
                    try e.print("else => return error.InvalidWireType,\n", .{});
                    // Close switch
                    e.indent_level -= 1;
                    try e.print("}},\n", .{});
                },
            }
        },
    }
}

fn emit_decode_map_case(e: *Emitter, map_field: ast.MapField, syntax: ast.Syntax) !void {
    const escaped = types.escape_zig_keyword(map_field.name);
    const num = map_field.number;

    try e.print("{d} => if (field.value == .len)", .{num});
    try e.open_brace();
    try e.print("var entry_iter = message.iterate_fields(field.value.len);\n", .{});

    // Declare key/value temporaries
    try emit_decode_map_key_decl(e, map_field.key_type);
    try emit_decode_map_value_decl(e, map_field.value_type);
    try emit_decode_map_errdefer(e, map_field.key_type, map_field.value_type);

    try e.print("while (try entry_iter.next()) |entry|", .{});
    try e.open_brace();
    try e.print("switch (entry.number)", .{});
    try e.open_brace();
    try emit_decode_map_key_case(e, map_field.key_type, syntax);
    try emit_decode_map_value_case(e, map_field.value_type, syntax);
    try e.print("else => {{}},\n", .{});
    try e.close_brace_nosemi(); // switch
    try e.close_brace_nosemi(); // while

    switch (map_field.value_type) {
        .named => try emit_map_put_with_free(e, escaped, map_field.key_type, map_field.value_type, "entry_key", "entry_val orelse .{}"),
        else => try emit_map_put_with_free(e, escaped, map_field.key_type, map_field.value_type, "entry_key", "entry_val"),
    }
    e.indent_level -= 1;
    try e.print("}} else return error.InvalidWireType,\n", .{});
}

fn emit_decode_map_key_decl(e: *Emitter, key_type: ast.ScalarType) !void {
    if (key_type == .string) {
        try e.print("var entry_key: []const u8 = \"\";\n", .{});
    } else if (key_type == .bool) {
        try e.print("var entry_key: bool = false;\n", .{});
    } else {
        try e.print("var entry_key: {s} = 0;\n", .{types.scalar_zig_type(key_type)});
    }
}

fn emit_decode_map_value_decl(e: *Emitter, value_type: ast.TypeRef) !void {
    switch (value_type) {
        .scalar => |s| {
            if (s == .string or s == .bytes) {
                try e.print("var entry_val: []const u8 = \"\";\n", .{});
            } else {
                try e.print("var entry_val: {s} = {s};\n", .{ types.scalar_zig_type(s), types.scalar_default_value(s) });
            }
        },
        .named => |name| {
            try e.print("var entry_val: ?{s} = null;\n", .{name});
        },
        .enum_ref => |name| {
            try e.print("var entry_val: {s} = @enumFromInt(0);\n", .{name});
        },
    }
}

fn emit_decode_map_errdefer(e: *Emitter, key_type: ast.ScalarType, value_type: ast.TypeRef) !void {
    if (key_type == .string) {
        try e.print("errdefer {{ if (entry_key.len > 0) allocator.free(entry_key); }}\n", .{});
    }
    switch (value_type) {
        .scalar => |s| {
            if (s == .string or s == .bytes) {
                try e.print("errdefer {{ if (entry_val.len > 0) allocator.free(entry_val); }}\n", .{});
            }
        },
        .named => {
            try e.print("errdefer {{ if (entry_val) |*v| v.deinit(allocator); }}\n", .{});
        },
        .enum_ref => {},
    }
}

fn emit_decode_map_key_case(e: *Emitter, key_type: ast.ScalarType, syntax: ast.Syntax) !void {
    if (key_type == .string) {
        if (syntax == .proto3) {
            try e.print("1 =>", .{});
            try e.open_brace();
            try e.print("try message.validate_utf8(entry.value.len);\n", .{});
            try e.print("entry_key = try allocator.dupe(u8, entry.value.len);\n", .{});
            e.indent_level -= 1;
            try e.print("}},\n", .{});
        } else {
            try e.print("1 => entry_key = try allocator.dupe(u8, entry.value.len),\n", .{});
        }
    } else {
        const decode_expr = types.scalar_decode_expr(key_type);
        // Replace "field." with "entry." in decode expressions
        _ = decode_expr;
        try e.print("1 => entry_key = {s},\n", .{scalar_decode_entry_expr(key_type)});
    }
}

fn emit_decode_map_value_case(e: *Emitter, value_type: ast.TypeRef, syntax: ast.Syntax) !void {
    switch (value_type) {
        .scalar => |s| {
            if (s == .string and syntax == .proto3) {
                try e.print("2 =>", .{});
                try e.open_brace();
                try e.print("try message.validate_utf8(entry.value.len);\n", .{});
                try e.print("entry_val = try allocator.dupe(u8, entry.value.len);\n", .{});
                e.indent_level -= 1;
                try e.print("}},\n", .{});
            } else if (s == .string or s == .bytes) {
                try e.print("2 => entry_val = try allocator.dupe(u8, entry.value.len),\n", .{});
            } else {
                try e.print("2 => entry_val = {s},\n", .{scalar_decode_entry_expr(s)});
            }
        },
        .named => |name| {
            try e.print("2 => entry_val = try {s}.decode_inner(allocator, entry.value.len, depth_remaining - 1),\n", .{name});
        },
        .enum_ref => {
            try e.print("2 => entry_val = @enumFromInt(@as(i32, @bitCast(@as(u32, @truncate(entry.value.varint))))),\n", .{});
        },
    }
}

fn scalar_decode_entry_expr(s: ast.ScalarType) []const u8 {
    return switch (s) {
        .int32 => "@bitCast(@as(u32, @truncate(entry.value.varint)))",
        .int64 => "@bitCast(entry.value.varint)",
        .uint32 => "@truncate(entry.value.varint)",
        .uint64 => "entry.value.varint",
        .sint32 => "encoding.zigzag_decode(@truncate(entry.value.varint))",
        .sint64 => "encoding.zigzag_decode_64(entry.value.varint)",
        .bool => "entry.value.varint != 0",
        .double => "@bitCast(entry.value.i64)",
        .float => "@bitCast(entry.value.i32)",
        .fixed32 => "entry.value.i32",
        .fixed64 => "entry.value.i64",
        .sfixed32 => "@bitCast(entry.value.i32)",
        .sfixed64 => "@bitCast(entry.value.i64)",
        .string, .bytes => "entry.value.len",
    };
}

fn emit_decode_oneof_field_case(e: *Emitter, field: ast.Field, oneof: ast.Oneof, syntax: ast.Syntax) !void {
    const field_escaped = types.escape_zig_keyword(field.name);
    const oneof_escaped = types.escape_zig_keyword(oneof.name);
    const num = field.number;

    try e.print("{d} => ", .{num});
    switch (field.type_name) {
        .scalar => |s| {
            const wire = types.scalar_wire_variant(s);
            if (s == .string and syntax == .proto3) {
                try e.print_raw("if (field.value == {s})", .{wire});
                try e.open_brace();
                try e.print("try message.validate_utf8(field.value.len);\n", .{});
                try e.print("result.{f} = .{{ .{f} = try allocator.dupe(u8, field.value.len) }};\n", .{ oneof_escaped, field_escaped });
                e.indent_level -= 1;
                try e.print("}} else return error.InvalidWireType,\n", .{});
            } else if (s == .string or s == .bytes) {
                try e.print_raw("if (field.value == {s}) {{ result.{f} = .{{ .{f} = try allocator.dupe(u8, field.value.len) }}; }} else return error.InvalidWireType,\n", .{ wire, oneof_escaped, field_escaped });
            } else {
                try e.print_raw("if (field.value == {s}) {{ result.{f} = .{{ .{f} = {s} }}; }} else return error.InvalidWireType,\n", .{ wire, oneof_escaped, field_escaped, types.scalar_decode_expr(s) });
            }
        },
        .named => |name| {
            try e.print_raw("if (field.value == .len)", .{});
            try e.open_brace();
            try e.print("if (result.{f}) |*oneof_val|", .{oneof_escaped});
            try e.open_brace();
            try e.print("switch (oneof_val.*)", .{});
            try e.open_brace();
            try e.print(".{f} => |*existing|", .{field_escaped});
            try e.open_brace();
            try e.print("const old_size = existing.calc_size();\n", .{});
            try e.print("const merged_buf = try allocator.alloc(u8, old_size + field.value.len.len);\n", .{});
            try e.print("defer allocator.free(merged_buf);\n", .{});
            try e.print("var merged_writer = std.Io.Writer.fixed(merged_buf);\n", .{});
            try e.print("existing.encode(&merged_writer) catch return error.OutOfMemory;\n", .{});
            try e.print("@memcpy(merged_buf[old_size..], field.value.len);\n", .{});
            try e.print("const merged_val = try {s}.decode_inner(allocator, merged_buf, depth_remaining - 1);\n", .{name});
            try e.print("existing.deinit(allocator);\n", .{});
            try e.print("existing.* = merged_val;\n", .{});
            try e.close_brace_comma();
            try e.print("else => result.{f} = .{{ .{f} = try {s}.decode_inner(allocator, field.value.len, depth_remaining - 1) }},\n", .{ oneof_escaped, field_escaped, name });
            try e.close_brace_nosemi(); // switch
            try e.close_brace_nosemi(); // if result.oneof
            try e.print("else result.{f} = .{{ .{f} = try {s}.decode_inner(allocator, field.value.len, depth_remaining - 1) }};\n", .{ oneof_escaped, field_escaped, name });
            e.indent_level -= 1;
            try e.print("}} else return error.InvalidWireType,\n", .{});
        },
        .enum_ref => {
            try e.print_raw("if (field.value == .varint) {{ result.{f} = .{{ .{f} = @enumFromInt(@as(i32, @bitCast(@as(u32, @truncate(field.value.varint))))) }}; }} else return error.InvalidWireType,\n", .{ oneof_escaped, field_escaped });
        },
    }
}

fn emit_decode_group_case(e: *Emitter, grp: ast.Group) !void {
    var name_buf: [256]u8 = undefined;
    const field_name = group_field_name(grp.name, &name_buf);
    const escaped = types.escape_zig_keyword(field_name);
    const num = grp.number;

    try e.print("{d} => ", .{num});
    switch (grp.label) {
        .optional, .implicit => {
            try e.print_raw("if (field.value == .sgroup) {{ result.{f} = try {s}.decode_group_inner(allocator, &iter, {d}, depth_remaining - 1); }} else return error.InvalidWireType,\n", .{ escaped, grp.name, num });
        },
        .required => {
            try e.print_raw("if (field.value == .sgroup) {{ result.{f} = try {s}.decode_group_inner(allocator, &iter, {d}, depth_remaining - 1); }} else return error.InvalidWireType,\n", .{ escaped, grp.name, num });
        },
        .repeated => {
            try e.print_raw("if (field.value == .sgroup)", .{});
            try e.open_brace();
            try e.print("const old = result.{f};\n", .{escaped});
            try e.print("const new = try allocator.alloc({s}, old.len + 1);\n", .{grp.name});
            try e.print("errdefer allocator.free(new);\n", .{});
            try e.print("@memcpy(new[0..old.len], old);\n", .{});
            try e.print("new[old.len] = try {s}.decode_group_inner(allocator, &iter, {d}, depth_remaining - 1);\n", .{ grp.name, num });
            try e.print("if (old.len > 0) allocator.free(old);\n", .{});
            try e.print("result.{f} = new;\n", .{escaped});
            e.indent_level -= 1;
            try e.print("}} else return error.InvalidWireType,\n", .{});
        },
    }
}

/// Emit code to free the old value of a scalar string/bytes field before overwriting it.
/// This handles duplicate fields in binary/text format (last value wins, but old must be freed).
fn emit_free_old_scalar(e: *Emitter, label: ast.FieldLabel, escaped: types.EscapedName, s: ast.ScalarType) !void {
    if (s != .string and s != .bytes) return;
    switch (label) {
        .implicit, .required => {
            try e.print("if (result.{f}.len > 0) allocator.free(result.{f});\n", .{ escaped, escaped });
        },
        .optional => {
            try e.print("if (result.{f}) |_old| allocator.free(_old);\n", .{escaped});
        },
        .repeated => {},
    }
}

/// Emit code to put a key/value into a map, freeing old entries on duplicate keys.
/// Uses getOrPut to detect duplicates and properly clean up old key/value.
fn emit_map_put_with_free(e: *Emitter, escaped: types.EscapedName, key_type: ast.ScalarType, value_type: ast.TypeRef, key_expr: []const u8, val_expr: []const u8) !void {
    try e.print("const _gop = try result.{f}.getOrPut(allocator, {s});\n", .{ escaped, key_expr });
    try e.print("if (_gop.found_existing)", .{});
    try e.open_brace();
    // Free the duplicate new key if string (old key stays in the map)
    if (types.is_string_key(key_type)) {
        try e.print("allocator.free({s});\n", .{key_expr});
    }
    // Free the old value being replaced
    switch (value_type) {
        .scalar => |s| {
            if (s == .string or s == .bytes) {
                try e.print("if (_gop.value_ptr.*.len > 0) allocator.free(_gop.value_ptr.*);\n", .{});
            }
        },
        .named => {
            try e.print("_gop.value_ptr.deinit(allocator);\n", .{});
        },
        .enum_ref => {},
    }
    try e.close_brace_nosemi();
    // For non-found case with getOrPut, key is already stored
    try e.print("\n", .{});
    try e.print("_gop.value_ptr.* = {s};\n", .{val_expr});
}

/// Emit errdefer to clean up a local `list` variable on error paths.
/// Frees string/bytes elements and the list backing array.
fn emit_list_errdefer(e: *Emitter, s: ast.ScalarType) !void {
    if (s == .string or s == .bytes) {
        try e.print("errdefer {{ for (list.items) |_item| allocator.free(_item); list.deinit(allocator); }}\n", .{});
    } else {
        try e.print("errdefer list.deinit(allocator);\n", .{});
    }
}

/// Emit errdefer for a list of named (message) types - deinits each element.
fn emit_named_list_errdefer(e: *Emitter) !void {
    try e.print("errdefer {{ for (list.items) |*_item| _item.deinit(allocator); list.deinit(allocator); }}\n", .{});
}

// ── Deinit Method ─────────────────────────────────────────────────────

fn emit_deinit_method(e: *Emitter, msg: ast.Message, _: ast.Syntax, recursive_types: *const RecursiveTypes) !void {
    try e.print("/// Free all allocator-owned memory (repeated fields, strings, bytes, nested messages)\n", .{});
    try e.print("pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void", .{});
    try e.open_brace();

    // Regular fields
    for (msg.fields) |field| {
        try emit_deinit_field(e, field, recursive_types);
    }

    // Map fields
    for (msg.maps) |map_field| {
        try emit_deinit_map(e, map_field);
    }

    // Oneof fields
    for (msg.oneofs) |oneof| {
        try emit_deinit_oneof(e, oneof);
    }

    // Group fields
    for (msg.groups) |grp| {
        try emit_deinit_group(e, grp);
    }

    // Unknown fields
    try e.print("if (self._unknown_fields.len > 0) allocator.free(self._unknown_fields);\n", .{});

    try e.close_brace_nosemi();
}

fn emit_deinit_field(e: *Emitter, field: ast.Field, recursive_types: *const RecursiveTypes) !void {
    const escaped = types.escape_zig_keyword(field.name);

    switch (field.type_name) {
        .scalar => |s| {
            switch (field.label) {
                .implicit, .required => {
                    if (s == .string or s == .bytes) {
                        try e.print("if (self.{f}.len > 0) allocator.free(self.{f});\n", .{ escaped, escaped });
                    }
                },
                .optional => {
                    if (s == .string or s == .bytes) {
                        try e.print("if (self.{f}) |v| allocator.free(v);\n", .{escaped});
                    }
                },
                .repeated => {
                    if (s == .string or s == .bytes) {
                        try e.print("for (self.{f}) |item| allocator.free(item);\n", .{escaped});
                    }
                    try e.print("if (self.{f}.len > 0) allocator.free(self.{f});\n", .{ escaped, escaped });
                },
            }
        },
        .named => |name| {
            const is_recursive = recursive_types.contains(name);
            switch (field.label) {
                .optional, .implicit => {
                    if (is_recursive) {
                        // Free heap-allocated pointer for recursive types
                        try e.print("if (self.{f}) |sub|", .{escaped});
                        try e.open_brace();
                        try e.print("sub.deinit(allocator);\n", .{});
                        try e.print("allocator.destroy(sub);\n", .{});
                        try e.close_brace_nosemi();
                    } else {
                        try e.print("if (self.{f}) |*sub| sub.deinit(allocator);\n", .{escaped});
                    }
                },
                .required => {
                    try e.print("self.{f}.deinit(allocator);\n", .{escaped});
                },
                .repeated => {
                    try e.print("for (self.{f}) |item| {{\n", .{escaped});
                    e.indent_level += 1;
                    try e.print("var m = item;\n", .{});
                    try e.print("m.deinit(allocator);\n", .{});
                    e.indent_level -= 1;
                    try e.print("}}\n", .{});
                    try e.print("if (self.{f}.len > 0) allocator.free(self.{f});\n", .{ escaped, escaped });
                },
            }
        },
        .enum_ref => {
            // Enums are value types — only free the slice for repeated
            switch (field.label) {
                .implicit, .optional, .required => {},
                .repeated => {
                    try e.print("if (self.{f}.len > 0) allocator.free(self.{f});\n", .{ escaped, escaped });
                },
            }
        },
    }
}

fn emit_deinit_map(e: *Emitter, map_field: ast.MapField) !void {
    const escaped = types.escape_zig_keyword(map_field.name);

    if (types.is_string_key(map_field.key_type)) {
        // Free string keys
        try e.print("for (self.{f}.keys()) |key| allocator.free(key);\n", .{escaped});
    }

    // Free values if they need freeing
    switch (map_field.value_type) {
        .scalar => |s| {
            if (s == .string or s == .bytes) {
                try e.print("for (self.{f}.values()) |val| allocator.free(val);\n", .{escaped});
            }
        },
        .named => {
            try e.print("for (self.{f}.values()) |*val| val.deinit(allocator);\n", .{escaped});
        },
        .enum_ref => {
            // Enum values don't need freeing
        },
    }

    try e.print("self.{f}.deinit(allocator);\n", .{escaped});
}

fn emit_deinit_oneof(e: *Emitter, oneof: ast.Oneof) !void {
    const escaped = types.escape_zig_keyword(oneof.name);

    try e.print("if (self.{f}) |*oneof_val| switch (oneof_val.*)", .{escaped});
    try e.open_brace();
    for (oneof.fields) |field| {
        const field_escaped = types.escape_zig_keyword(field.name);
        switch (field.type_name) {
            .scalar => |s| {
                if (s == .string or s == .bytes) {
                    try e.print(".{f} => |v| allocator.free(v),\n", .{field_escaped});
                } else {
                    try e.print(".{f} => {{}},\n", .{field_escaped});
                }
            },
            .named => {
                try e.print(".{f} => |*sub| sub.deinit(allocator),\n", .{field_escaped});
            },
            .enum_ref => {
                try e.print(".{f} => {{}},\n", .{field_escaped});
            },
        }
    }
    try e.close_brace();
}

fn emit_deinit_group(e: *Emitter, grp: ast.Group) !void {
    var name_buf: [256]u8 = undefined;
    const field_name = group_field_name(grp.name, &name_buf);
    const escaped = types.escape_zig_keyword(field_name);

    switch (grp.label) {
        .optional, .implicit => {
            try e.print("if (self.{f}) |*grp| grp.deinit(allocator);\n", .{escaped});
        },
        .required => {
            try e.print("self.{f}.deinit(allocator);\n", .{escaped});
        },
        .repeated => {
            try e.print("for (self.{f}) |item| {{\n", .{escaped});
            e.indent_level += 1;
            try e.print("var m = item;\n", .{});
            try e.print("m.deinit(allocator);\n", .{});
            e.indent_level -= 1;
            try e.print("}}\n", .{});
            try e.print("if (self.{f}.len > 0) allocator.free(self.{f});\n", .{ escaped, escaped });
        },
    }
}

// ── JSON Serialization Method ──────────────────────────────────────────

fn emit_wrapper_to_json_method(e: *Emitter, kind: WrapperKind) !void {
    try e.print("/// Serialize this message to proto-JSON format\n", .{});
    try e.print("pub fn to_json(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    switch (kind) {
        .bool_value => try e.print("try json.write_bool(writer, self.value);\n", .{}),
        .int32_value => try e.print("try json.write_int(writer, @as(i64, self.value));\n", .{}),
        .int64_value => try e.print("try json.write_int_string(writer, self.value);\n", .{}),
        .uint32_value => try e.print("try json.write_uint(writer, @as(u64, self.value));\n", .{}),
        .uint64_value => try e.print("try json.write_uint_string(writer, self.value);\n", .{}),
        .float_value => try e.print("try json.write_float(writer, self.value);\n", .{}),
        .double_value => try e.print("try json.write_float(writer, self.value);\n", .{}),
        .string_value => try e.print("try json.write_string(writer, self.value);\n", .{}),
        .bytes_value => try e.print("try json.write_bytes(writer, self.value);\n", .{}),
    }
    try e.close_brace_nosemi();
}

fn emit_wrapper_from_json_method(e: *Emitter, kind: WrapperKind) !void {
    try e.print("/// Deserialize from proto-JSON format bytes. Caller must call deinit when done\n", .{});
    try e.print("pub fn from_json(allocator: std.mem.Allocator, json_bytes: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("var scanner = json.JsonScanner.init(allocator, json_bytes);\n", .{});
    try e.print("defer scanner.deinit();\n", .{});
    try e.print("return try @This().from_json_scanner(allocator, &scanner);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner(allocator: std.mem.Allocator, scanner: *json.JsonScanner) !@This()", .{});
    try e.open_brace();
    try e.print("return @This().from_json_scanner_inner(allocator, scanner, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner_inner(allocator: std.mem.Allocator, scanner: *json.JsonScanner, depth_remaining: usize) !@This()", .{});
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});
    try e.print("var result: @This() = .{{}};\n", .{});
    try e.print("errdefer result.deinit(allocator);\n", .{});
    try e.print("const maybe_tok = try scanner.peek() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (maybe_tok == .null_value) {{ _ = try scanner.next(); return result; }}\n", .{});
    switch (kind) {
        .bool_value => try e.print("result.value = try json.read_bool(scanner);\n", .{}),
        .int32_value => try e.print("result.value = try json.read_int32(scanner);\n", .{}),
        .int64_value => try e.print("result.value = try json.read_int64(scanner);\n", .{}),
        .uint32_value => try e.print("result.value = try json.read_uint32(scanner);\n", .{}),
        .uint64_value => try e.print("result.value = try json.read_uint64(scanner);\n", .{}),
        .float_value => try e.print("result.value = try json.read_float32(scanner);\n", .{}),
        .double_value => try e.print("result.value = try json.read_float64(scanner);\n", .{}),
        .string_value => try e.print("result.value = try allocator.dupe(u8, try json.read_string(scanner));\n", .{}),
        .bytes_value => try e.print("result.value = try json.read_bytes(scanner, allocator);\n", .{}),
    }
    try e.print("return result;\n", .{});
    try e.close_brace_nosemi();
}

fn emit_timestamp_to_json_method(e: *Emitter) !void {
    try e.print("/// Serialize this message to proto-JSON format\n", .{});
    try e.print("pub fn to_json(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    try e.print("try json.write_timestamp_value(writer, self.seconds, self.nanos);\n", .{});
    try e.close_brace_nosemi();
}

fn emit_duration_to_json_method(e: *Emitter) !void {
    try e.print("/// Serialize this message to proto-JSON format\n", .{});
    try e.print("pub fn to_json(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    try e.print("try json.write_duration_value(writer, self.seconds, self.nanos);\n", .{});
    try e.close_brace_nosemi();
}

fn emit_field_mask_to_json_method(e: *Emitter) !void {
    try e.print("/// Serialize this message to proto-JSON format\n", .{});
    try e.print("pub fn to_json(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    try e.print("try json.write_field_mask_paths(writer, self.paths);\n", .{});
    try e.close_brace_nosemi();
}

fn emit_timestamp_from_json_method(e: *Emitter) !void {
    try e.print("/// Deserialize from proto-JSON format bytes. Caller must call deinit when done\n", .{});
    try e.print("pub fn from_json(allocator: std.mem.Allocator, json_bytes: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("var scanner = json.JsonScanner.init(allocator, json_bytes);\n", .{});
    try e.print("defer scanner.deinit();\n", .{});
    try e.print("return try @This().from_json_scanner(allocator, &scanner);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner(allocator: std.mem.Allocator, scanner: *json.JsonScanner) !@This()", .{});
    try e.open_brace();
    try e.print("return @This().from_json_scanner_inner(allocator, scanner, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner_inner(allocator: std.mem.Allocator, scanner: *json.JsonScanner, depth_remaining: usize) !@This()", .{});
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});
    try e.print("var result: @This() = .{{}};\n", .{});
    try e.print("errdefer result.deinit(allocator);\n", .{});
    try e.print("if (try json.read_timestamp_value(scanner)) |ts| {{ result.seconds = ts.seconds; result.nanos = ts.nanos; }}\n", .{});
    try e.print("return result;\n", .{});
    try e.close_brace_nosemi();
}

fn emit_duration_from_json_method(e: *Emitter) !void {
    try e.print("/// Deserialize from proto-JSON format bytes. Caller must call deinit when done\n", .{});
    try e.print("pub fn from_json(allocator: std.mem.Allocator, json_bytes: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("var scanner = json.JsonScanner.init(allocator, json_bytes);\n", .{});
    try e.print("defer scanner.deinit();\n", .{});
    try e.print("return try @This().from_json_scanner(allocator, &scanner);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner(allocator: std.mem.Allocator, scanner: *json.JsonScanner) !@This()", .{});
    try e.open_brace();
    try e.print("return @This().from_json_scanner_inner(allocator, scanner, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner_inner(allocator: std.mem.Allocator, scanner: *json.JsonScanner, depth_remaining: usize) !@This()", .{});
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});
    try e.print("var result: @This() = .{{}};\n", .{});
    try e.print("errdefer result.deinit(allocator);\n", .{});
    try e.print("if (try json.read_duration_value(scanner)) |dur| {{ result.seconds = dur.seconds; result.nanos = dur.nanos; }}\n", .{});
    try e.print("return result;\n", .{});
    try e.close_brace_nosemi();
}

fn emit_field_mask_from_json_method(e: *Emitter) !void {
    try e.print("/// Deserialize from proto-JSON format bytes. Caller must call deinit when done\n", .{});
    try e.print("pub fn from_json(allocator: std.mem.Allocator, json_bytes: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("var scanner = json.JsonScanner.init(allocator, json_bytes);\n", .{});
    try e.print("defer scanner.deinit();\n", .{});
    try e.print("return try @This().from_json_scanner(allocator, &scanner);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner(allocator: std.mem.Allocator, scanner: *json.JsonScanner) !@This()", .{});
    try e.open_brace();
    try e.print("return @This().from_json_scanner_inner(allocator, scanner, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner_inner(allocator: std.mem.Allocator, scanner: *json.JsonScanner, depth_remaining: usize) !@This()", .{});
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});
    try e.print("var result: @This() = .{{}};\n", .{});
    try e.print("errdefer result.deinit(allocator);\n", .{});
    try e.print("result.paths = try json.read_field_mask_paths(scanner, allocator);\n", .{});
    try e.print("return result;\n", .{});
    try e.close_brace_nosemi();
}

fn emit_any_to_json_method(e: *Emitter) !void {
    try e.print("/// Serialize this message to proto-JSON format\n", .{});
    try e.print("pub fn to_json(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    try e.print("try self.to_json_with_context(writer, void, \"\");\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn to_json_with_context(self: @This(), writer: *std.Io.Writer, comptime ContextType: type, context_full_name: []const u8) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    try e.print("if (self.type_url.len == 0) {{\n", .{});
    e.indent_level += 1;
    try e.print("try json.write_object_start(writer);\n", .{});
    try e.print("try json.write_object_end(writer);\n", .{});
    try e.print("return;\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    try e.print("if (!text_format.is_valid_any_type_url(self.type_url)) return error.WriteFailed;\n", .{});
    try e.print("const type_name = text_format.any_type_name(self.type_url) orelse return error.WriteFailed;\n", .{});

    try e.print("try json.write_object_start(writer);\n", .{});
    try e.print("var first = true;\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"@type\");\n", .{});
    try e.print("try json.write_string(writer, self.type_url);\n", .{});

    try e.print("if (std.mem.eql(u8, type_name, \"google.protobuf.Empty\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"empty.zig\").Empty.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Any\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @This().decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json_with_context(writer, ContextType, context_full_name);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Timestamp\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"timestamp.zig\").Timestamp.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Duration\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"duration.zig\").Duration.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.FieldMask\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"field_mask.zig\").FieldMask.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Struct\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"struct.zig\").Struct.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Value\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"struct.zig\").Value.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.ListValue\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"struct.zig\").ListValue.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.BoolValue\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"wrappers.zig\").BoolValue.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Int32Value\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"wrappers.zig\").Int32Value.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Int64Value\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"wrappers.zig\").Int64Value.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.UInt32Value\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"wrappers.zig\").UInt32Value.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.UInt64Value\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"wrappers.zig\").UInt64Value.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.FloatValue\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"wrappers.zig\").FloatValue.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.DoubleValue\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"wrappers.zig\").DoubleValue.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.StringValue\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"wrappers.zig\").StringValue.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.BytesValue\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = @import(\"wrappers.zig\").BytesValue.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, \"value\");\n", .{});
    try e.print("try sub.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (ContextType != void and context_full_name.len > 0 and std.mem.eql(u8, type_name, context_full_name)) {{\n", .{});
    e.indent_level += 1;
    try e.print("var sub = ContextType.decode(std.heap.page_allocator, self.value) catch return error.WriteFailed;\n", .{});
    try e.print("defer sub.deinit(std.heap.page_allocator);\n", .{});
    try e.print("var payload_writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);\n", .{});
    try e.print("defer payload_writer.deinit();\n", .{});
    try e.print("sub.to_json(&payload_writer.writer) catch return error.WriteFailed;\n", .{});
    try e.print("const payload_json = payload_writer.written();\n", .{});
    try e.print("if (payload_json.len < 2 or payload_json[0] != '{{' or payload_json[payload_json.len - 1] != '}}') return error.WriteFailed;\n", .{});
    try e.print("if (payload_json.len > 2) {{\n", .{});
    e.indent_level += 1;
    try e.print("_ = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try writer.writeAll(payload_json[1 .. payload_json.len - 1]);\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    e.indent_level -= 1;
    try e.print("}} else {{\n", .{});
    e.indent_level += 1;
    try e.print("return error.WriteFailed;\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});

    try e.print("try json.write_object_end(writer);\n", .{});
    try e.close_brace_nosemi();
}

fn emit_any_from_json_method(e: *Emitter) !void {
    try e.print("/// Deserialize from proto-JSON format bytes. Caller must call deinit when done\n", .{});
    try e.print("pub fn from_json(allocator: std.mem.Allocator, json_bytes: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("var scanner = json.JsonScanner.init(allocator, json_bytes);\n", .{});
    try e.print("defer scanner.deinit();\n", .{});
    try e.print("return try @This().from_json_scanner(allocator, &scanner);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_with_context(allocator: std.mem.Allocator, json_bytes: []const u8, comptime ContextType: type, context_full_name: []const u8) json.DecodeError!@This()", .{});
    try e.open_brace();
    try e.print("var scanner = json.JsonScanner.init(allocator, json_bytes);\n", .{});
    try e.print("defer scanner.deinit();\n", .{});
    try e.print("return try @This().from_json_scanner_with_context(allocator, &scanner, message.default_max_decode_depth, ContextType, context_full_name);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner(allocator: std.mem.Allocator, scanner: *json.JsonScanner) json.DecodeError!@This()", .{});
    try e.open_brace();
    try e.print("return @This().from_json_scanner_inner(allocator, scanner, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner_inner(allocator: std.mem.Allocator, scanner: *json.JsonScanner, depth_remaining: usize) json.DecodeError!@This()", .{});
    try e.open_brace();
    try e.print("return @This().from_json_scanner_with_context(allocator, scanner, depth_remaining, void, \"\");\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner_with_context(allocator: std.mem.Allocator, scanner: *json.JsonScanner, depth_remaining: usize, comptime ContextType: type, context_full_name: []const u8) json.DecodeError!@This()", .{});
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});
    try e.print("var result: @This() = .{{}};\n", .{});
    try e.print("errdefer result.deinit(allocator);\n", .{});
    try e.print("var seen_fields: std.StringHashMapUnmanaged(void) = .{{}};\n", .{});
    try e.print("defer seen_fields.deinit(allocator);\n", .{});
    try e.print("var payload_entries: std.ArrayListUnmanaged(struct {{ key: []const u8, value_json: []const u8 }}) = .empty;\n", .{});
    try e.print("defer {{\n", .{});
    e.indent_level += 1;
    try e.print("for (payload_entries.items) |entry| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (entry.key.len > 0) allocator.free(entry.key);\n", .{});
    try e.print("if (entry.value_json.len > 0) allocator.free(entry.value_json);\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    try e.print("payload_entries.deinit(allocator);\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});

    try e.print("const start_tok = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (start_tok != .object_start) return error.UnexpectedToken;\n", .{});
    try e.print("while (true) {{\n", .{});
    e.indent_level += 1;
    try e.print("const tok = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("switch (tok) {{\n", .{});
    e.indent_level += 1;
    try e.print(".object_end => break,\n", .{});
    try e.print(".string => |key| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (try json.mark_field_seen(&seen_fields, allocator, key)) return error.UnexpectedToken;\n", .{});
    try e.print("if (std.mem.eql(u8, key, \"@type\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("result.type_url = try allocator.dupe(u8, try json.read_string(scanner));\n", .{});
    e.indent_level -= 1;
    try e.print("}} else {{\n", .{});
    e.indent_level += 1;
    try e.print("const key_copy = try allocator.dupe(u8, key);\n", .{});
    try e.print("errdefer allocator.free(key_copy);\n", .{});
    try e.print("const value_json = try json.capture_value(scanner, allocator);\n", .{});
    try e.print("errdefer if (value_json.len > 0) allocator.free(value_json);\n", .{});
    try e.print("try payload_entries.append(allocator, .{{ .key = key_copy, .value_json = value_json }});\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    e.indent_level -= 1;
    try e.print("}},\n", .{});
    try e.print("else => return error.UnexpectedToken,\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});

    try e.print("if (result.type_url.len == 0) {{\n", .{});
    e.indent_level += 1;
    try e.print("if (payload_entries.items.len > 0) return error.UnexpectedToken;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    try e.print("if (!text_format.is_valid_any_type_url(result.type_url)) return error.UnexpectedToken;\n", .{});
    try e.print("const type_name = text_format.any_type_name(result.type_url) orelse return error.UnexpectedToken;\n", .{});
    try e.print("const maybe_value_json: ?[]const u8 = if (payload_entries.items.len == 1 and std.mem.eql(u8, payload_entries.items[0].key, \"value\")) payload_entries.items[0].value_json else null;\n", .{});

    try e.print("if (std.mem.eql(u8, type_name, \"google.protobuf.Empty\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("if (payload_entries.items.len != 0) return error.UnexpectedToken;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Any\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @This().from_json_with_context(allocator, value_json, ContextType, context_full_name);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Timestamp\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"timestamp.zig\").Timestamp.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Duration\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"duration.zig\").Duration.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.FieldMask\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"field_mask.zig\").FieldMask.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Struct\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"struct.zig\").Struct.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Value\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"struct.zig\").Value.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.ListValue\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"struct.zig\").ListValue.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.BoolValue\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"wrappers.zig\").BoolValue.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Int32Value\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"wrappers.zig\").Int32Value.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.Int64Value\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"wrappers.zig\").Int64Value.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.UInt32Value\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"wrappers.zig\").UInt32Value.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.UInt64Value\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"wrappers.zig\").UInt64Value.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.FloatValue\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"wrappers.zig\").FloatValue.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.DoubleValue\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"wrappers.zig\").DoubleValue.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.StringValue\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"wrappers.zig\").StringValue.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (std.mem.eql(u8, type_name, \"google.protobuf.BytesValue\")) {{\n", .{});
    e.indent_level += 1;
    try e.print("const value_json = maybe_value_json orelse return error.UnexpectedToken;\n", .{});
    try e.print("var sub = try @import(\"wrappers.zig\").BytesValue.from_json(allocator, value_json);\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else if (ContextType != void and context_full_name.len > 0 and std.mem.eql(u8, type_name, context_full_name)) {{\n", .{});
    e.indent_level += 1;
    try e.print("var payload_writer: std.Io.Writer.Allocating = .init(allocator);\n", .{});
    try e.print("defer payload_writer.deinit();\n", .{});
    try e.print("json.write_object_start(&payload_writer.writer) catch return error.OutOfMemory;\n", .{});
    try e.print("var payload_first = true;\n", .{});
    try e.print("for (payload_entries.items) |entry| {{\n", .{});
    e.indent_level += 1;
    try e.print("payload_first = json.write_field_sep(&payload_writer.writer, payload_first) catch return error.OutOfMemory;\n", .{});
    try e.print("json.write_field_name(&payload_writer.writer, entry.key) catch return error.OutOfMemory;\n", .{});
    try e.print("payload_writer.writer.writeAll(entry.value_json) catch return error.OutOfMemory;\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    try e.print("json.write_object_end(&payload_writer.writer) catch return error.OutOfMemory;\n", .{});
    try e.print("var sub = try ContextType.from_json(allocator, payload_writer.written());\n", .{});
    try e.print("defer sub.deinit(allocator);\n", .{});
    try e.print("const sub_size = sub.calc_size();\n", .{});
    try e.print("const encoded_value = try allocator.alloc(u8, sub_size);\n", .{});
    try e.print("var sub_writer = std.Io.Writer.fixed(encoded_value);\n", .{});
    try e.print("sub.encode(&sub_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.value = encoded_value;\n", .{});
    try e.print("return result;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else {{\n", .{});
    e.indent_level += 1;
    try e.print("return error.UnexpectedToken;\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    try e.close_brace_nosemi();
}

fn emit_struct_to_json_method(e: *Emitter) !void {
    try e.print("/// Serialize this message to proto-JSON format\n", .{});
    try e.print("pub fn to_json(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    try e.print("try json.write_object_start(writer);\n", .{});
    try e.print("var first = true;\n", .{});
    try e.print("for (self.fields.keys(), self.fields.values()) |key, val| {{\n", .{});
    e.indent_level += 1;
    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
    try e.print("try json.write_field_name(writer, key);\n", .{});
    try e.print("try val.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    try e.print("try json.write_object_end(writer);\n", .{});
    try e.close_brace_nosemi();
}

fn emit_struct_from_json_method(e: *Emitter) !void {
    try e.print("/// Deserialize from proto-JSON format bytes. Caller must call deinit when done\n", .{});
    try e.print("pub fn from_json(allocator: std.mem.Allocator, json_bytes: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("var scanner = json.JsonScanner.init(allocator, json_bytes);\n", .{});
    try e.print("defer scanner.deinit();\n", .{});
    try e.print("return try @This().from_json_scanner(allocator, &scanner);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner(allocator: std.mem.Allocator, scanner: *json.JsonScanner) !@This()", .{});
    try e.open_brace();
    try e.print("return @This().from_json_scanner_inner(allocator, scanner, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner_inner(allocator: std.mem.Allocator, scanner: *json.JsonScanner, depth_remaining: usize) json.DecodeError!@This()", .{});
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});
    try e.print("var result: @This() = .{{}};\n", .{});
    try e.print("errdefer result.deinit(allocator);\n", .{});
    try e.print("const start_tok = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (start_tok == .null_value) return result;\n", .{});
    try e.print("if (start_tok != .object_start) return error.UnexpectedToken;\n", .{});
    try e.print("while (true) {{\n", .{});
    e.indent_level += 1;
    try e.print("const tok = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("switch (tok) {{\n", .{});
    e.indent_level += 1;
    try e.print(".object_end => return result,\n", .{});
    try e.print(".string => |key| {{\n", .{});
    e.indent_level += 1;
    try e.print("const map_key = try allocator.dupe(u8, key);\n", .{});
    try e.print("const map_val = try Value.from_json_scanner_inner(allocator, scanner, depth_remaining - 1);\n", .{});
    try e.print("try result.fields.put(allocator, map_key, map_val);\n", .{});
    e.indent_level -= 1;
    try e.print("}},\n", .{});
    try e.print("else => return error.UnexpectedToken,\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    try e.print("return result;\n", .{});
    try e.close_brace_nosemi();
}

fn emit_list_value_to_json_method(e: *Emitter) !void {
    try e.print("/// Serialize this message to proto-JSON format\n", .{});
    try e.print("pub fn to_json(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    try e.print("try json.write_array_start(writer);\n", .{});
    try e.print("for (self.values, 0..) |item, i| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (i > 0) try writer.writeByte(',');\n", .{});
    try e.print("try item.to_json(writer);\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    try e.print("try json.write_array_end(writer);\n", .{});
    try e.close_brace_nosemi();
}

fn emit_list_value_from_json_method(e: *Emitter) !void {
    try e.print("/// Deserialize from proto-JSON format bytes. Caller must call deinit when done\n", .{});
    try e.print("pub fn from_json(allocator: std.mem.Allocator, json_bytes: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("var scanner = json.JsonScanner.init(allocator, json_bytes);\n", .{});
    try e.print("defer scanner.deinit();\n", .{});
    try e.print("return try @This().from_json_scanner(allocator, &scanner);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner(allocator: std.mem.Allocator, scanner: *json.JsonScanner) !@This()", .{});
    try e.open_brace();
    try e.print("return @This().from_json_scanner_inner(allocator, scanner, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner_inner(allocator: std.mem.Allocator, scanner: *json.JsonScanner, depth_remaining: usize) json.DecodeError!@This()", .{});
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});
    try e.print("var result: @This() = .{{}};\n", .{});
    try e.print("errdefer result.deinit(allocator);\n", .{});
    try e.print("const start_tok = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (start_tok == .null_value) return result;\n", .{});
    try e.print("if (start_tok != .array_start) return error.UnexpectedToken;\n", .{});
    try e.print("var list: std.ArrayListUnmanaged(Value) = .empty;\n", .{});
    try e.print("while (true) {{\n", .{});
    e.indent_level += 1;
    try e.print("if (try scanner.peek()) |p| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (p == .array_end) {{ _ = try scanner.next(); break; }}\n", .{});
    e.indent_level -= 1;
    try e.print("}} else break;\n", .{});
    try e.print("try list.append(allocator, try Value.from_json_scanner_inner(allocator, scanner, depth_remaining - 1));\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    try e.print("result.values = try list.toOwnedSlice(allocator);\n", .{});
    try e.print("return result;\n", .{});
    try e.close_brace_nosemi();
}

fn emit_value_to_json_method(e: *Emitter) !void {
    try e.print("/// Serialize this message to proto-JSON format\n", .{});
    try e.print("pub fn to_json(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    try e.print("if (self.kind) |oneof_val| switch (oneof_val) {{\n", .{});
    e.indent_level += 1;
    try e.print(".null_value => |_| try json.write_null(writer),\n", .{});
    try e.print(".number_value => |v| try json.write_float(writer, v),\n", .{});
    try e.print(".string_value => |v| try json.write_string(writer, v),\n", .{});
    try e.print(".bool_value => |v| try json.write_bool(writer, v),\n", .{});
    try e.print(".struct_value => |sub| try sub.to_json(writer),\n", .{});
    try e.print(".list_value => |sub| try sub.to_json(writer),\n", .{});
    e.indent_level -= 1;
    try e.print("}} else try json.write_null(writer);\n", .{});
    try e.close_brace_nosemi();
}

fn emit_value_from_json_method(e: *Emitter) !void {
    try e.print("/// Deserialize from proto-JSON format bytes. Caller must call deinit when done\n", .{});
    try e.print("pub fn from_json(allocator: std.mem.Allocator, json_bytes: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("var scanner = json.JsonScanner.init(allocator, json_bytes);\n", .{});
    try e.print("defer scanner.deinit();\n", .{});
    try e.print("return try @This().from_json_scanner(allocator, &scanner);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner(allocator: std.mem.Allocator, scanner: *json.JsonScanner) !@This()", .{});
    try e.open_brace();
    try e.print("return @This().from_json_scanner_inner(allocator, scanner, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn from_json_scanner_inner(allocator: std.mem.Allocator, scanner: *json.JsonScanner, depth_remaining: usize) json.DecodeError!@This()", .{});
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});
    try e.print("var result: @This() = .{{}};\n", .{});
    try e.print("errdefer result.deinit(allocator);\n", .{});
    try e.print("const tok = try scanner.peek() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("switch (tok) {{\n", .{});
    e.indent_level += 1;
    try e.print(".null_value => {{\n", .{});
    e.indent_level += 1;
    try e.print("_ = try scanner.next();\n", .{});
    try e.print("result.kind = .{{ .null_value = @enumFromInt(0) }};\n", .{});
    e.indent_level -= 1;
    try e.print("}},\n", .{});
    try e.print(".true_value, .false_value => result.kind = .{{ .bool_value = try json.read_bool(scanner) }},\n", .{});
    try e.print(".number => result.kind = .{{ .number_value = try json.read_float64(scanner) }},\n", .{});
    try e.print(".string => result.kind = .{{ .string_value = try allocator.dupe(u8, try json.read_string(scanner)) }},\n", .{});
    try e.print(".object_start => result.kind = .{{ .struct_value = try Struct.from_json_scanner_inner(allocator, scanner, depth_remaining - 1) }},\n", .{});
    try e.print(".array_start => result.kind = .{{ .list_value = try ListValue.from_json_scanner_inner(allocator, scanner, depth_remaining - 1) }},\n", .{});
    try e.print("else => return error.UnexpectedToken,\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    try e.print("return result;\n", .{});
    try e.close_brace_nosemi();
}

fn emit_to_json_method(e: *Emitter, msg: ast.Message, syntax: ast.Syntax, full_name: []const u8) !void {
    if (is_any_type(full_name)) {
        try emit_any_to_json_method(e);
        return;
    }
    if (detect_wrapper_kind(full_name)) |kind| {
        try emit_wrapper_to_json_method(e, kind);
        return;
    }
    if (is_timestamp_type(full_name)) {
        try emit_timestamp_to_json_method(e);
        return;
    }
    if (is_duration_type(full_name)) {
        try emit_duration_to_json_method(e);
        return;
    }
    if (is_field_mask_type(full_name)) {
        try emit_field_mask_to_json_method(e);
        return;
    }
    if (is_struct_type(full_name)) {
        try emit_struct_to_json_method(e);
        return;
    }
    if (is_value_type(full_name)) {
        try emit_value_to_json_method(e);
        return;
    }
    if (is_list_value_type(full_name)) {
        try emit_list_value_to_json_method(e);
        return;
    }

    try e.print("/// Serialize this message to proto-JSON format\n", .{});
    try e.print("pub fn to_json(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();

    const items = try collect_all_fields(e.allocator, msg);
    defer e.allocator.free(items);

    if (items.len > 0) {
        try e.print("try json.write_object_start(writer);\n", .{});
        try e.print("var first = true;\n", .{});

        for (items) |item| {
            switch (item) {
                .field => |f| try emit_json_field(e, f, syntax, full_name),
                .map => |m| try emit_json_map(e, m),
                .oneof => |o| try emit_json_oneof(e, o, full_name),
                .group => |g| try emit_json_group(e, g),
            }
        }

        try e.print("try json.write_object_end(writer);\n", .{});
    } else {
        try e.print("_ = self;\n", .{});
        try e.print("try json.write_object_start(writer);\n", .{});
        try e.print("try json.write_object_end(writer);\n", .{});
    }
    try e.close_brace_nosemi();
}

fn json_field_name(field_name: []const u8, options: []const ast.FieldOption, buf: []u8) []const u8 {
    // Check for explicit json_name option
    for (options) |opt| {
        if (opt.name.parts.len == 1 and !opt.name.parts[0].is_extension and std.mem.eql(u8, opt.name.parts[0].name, "json_name")) {
            switch (opt.value) {
                .string_value => |s| return s,
                else => {},
            }
        }
    }
    // Default: convert snake_case to lowerCamelCase
    return types.snake_to_lower_camel(field_name, buf);
}

fn emit_json_field(e: *Emitter, field: ast.Field, syntax: ast.Syntax, full_name: []const u8) !void {
    const escaped = types.escape_zig_keyword(field.name);
    var json_name_buf: [256]u8 = undefined;
    const jname = json_field_name(field.name, field.options, &json_name_buf);

    switch (field.type_name) {
        .scalar => |s| {
            const write_fn = types.scalar_json_write_fn(s);
            switch (field.label) {
                .implicit => {
                    // Proto3 implicit: skip if default
                    if (s == .string or s == .bytes) {
                        try e.print("if (self.{f}.len > 0)", .{escaped});
                        try e.open_brace();
                        try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                        try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                        try e.print("try json.{s}(writer, self.{f});\n", .{ write_fn, escaped });
                        try e.close_brace_nosemi();
                    } else if (s == .bool) {
                        try e.print("if (self.{f})", .{escaped});
                        try e.open_brace();
                        try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                        try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                        try e.print("try json.write_bool(writer, self.{f});\n", .{escaped});
                        try e.close_brace_nosemi();
                    } else if (s == .double) {
                        // Preserve -0.0 for proto3 implicit presence checks.
                        try e.print("if (@as(u64, @bitCast(self.{f})) != 0)", .{escaped});
                        try e.open_brace();
                        try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                        try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                        try e.print("try json.write_float(writer, self.{f});\n", .{escaped});
                        try e.close_brace_nosemi();
                    } else if (s == .float) {
                        // Preserve -0.0 for proto3 implicit presence checks.
                        try e.print("if (@as(u32, @bitCast(self.{f})) != 0)", .{escaped});
                        try e.open_brace();
                        try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                        try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                        try e.print("try json.write_float(writer, self.{f});\n", .{escaped});
                        try e.close_brace_nosemi();
                    } else {
                        // integer types
                        try e.print("if (self.{f} != 0)", .{escaped});
                        try e.open_brace();
                        try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                        try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                        try emit_json_scalar_write(e, write_fn, s, escaped);
                        try e.close_brace_nosemi();
                    }
                },
                .optional => {
                    try e.print("if (self.{f}) |v|", .{escaped});
                    try e.open_brace();
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    try emit_json_scalar_write_val(e, write_fn, s);
                    try e.close_brace_nosemi();
                },
                .required => {
                    _ = syntax;
                    try e.print("{{\n", .{});
                    e.indent_level += 1;
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    try emit_json_scalar_write(e, write_fn, s, escaped);
                    e.indent_level -= 1;
                    try e.print("}}\n", .{});
                },
                .repeated => {
                    try e.print("if (self.{f}.len > 0)", .{escaped});
                    try e.open_brace();
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    try e.print("try json.write_array_start(writer);\n", .{});
                    try e.print("for (self.{f}, 0..) |item, i|", .{escaped});
                    try e.open_brace();
                    try e.print("if (i > 0) try writer.writeByte(',');\n", .{});
                    try emit_json_scalar_write_item(e, write_fn, s);
                    try e.close_brace_nosemi();
                    try e.print("try json.write_array_end(writer);\n", .{});
                    try e.close_brace_nosemi();
                },
            }
        },
        .named => |name| {
            switch (field.label) {
                .repeated => {
                    try e.print("if (self.{f}.len > 0)", .{escaped});
                    try e.open_brace();
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    try e.print("try json.write_array_start(writer);\n", .{});
                    try e.print("for (self.{f}, 0..) |item, i|", .{escaped});
                    try e.open_brace();
                    try e.print("if (i > 0) try writer.writeByte(',');\n", .{});
                    if (std.mem.eql(u8, name, "google.protobuf.Any")) {
                        try e.print("try item.to_json_with_context(writer, @This(), \"{s}\");\n", .{full_name});
                    } else {
                        try e.print("try item.to_json(writer);\n", .{});
                    }
                    try e.close_brace_nosemi();
                    try e.print("try json.write_array_end(writer);\n", .{});
                    try e.close_brace_nosemi();
                },
                .optional, .implicit => {
                    try e.print("if (self.{f}) |sub|", .{escaped});
                    try e.open_brace();
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    if (std.mem.eql(u8, name, "google.protobuf.Any")) {
                        try e.print("try sub.to_json_with_context(writer, @This(), \"{s}\");\n", .{full_name});
                    } else {
                        try e.print("try sub.to_json(writer);\n", .{});
                    }
                    try e.close_brace_nosemi();
                },
                .required => {
                    try e.print("{{\n", .{});
                    e.indent_level += 1;
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    if (std.mem.eql(u8, name, "google.protobuf.Any")) {
                        try e.print("try self.{f}.to_json_with_context(writer, @This(), \"{s}\");\n", .{ escaped, full_name });
                    } else {
                        try e.print("try self.{f}.to_json(writer);\n", .{escaped});
                    }
                    e.indent_level -= 1;
                    try e.print("}}\n", .{});
                },
            }
        },
        .enum_ref => |enum_name| {
            switch (field.label) {
                .implicit => {
                    try e.print("if (@intFromEnum(self.{f}) != 0)", .{escaped});
                    try e.open_brace();
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    if (std.mem.eql(u8, enum_name, "google.protobuf.NullValue")) {
                        try e.print("try json.write_null(writer);\n", .{});
                    } else {
                        try e.print("try json.write_int(writer, @as(i64, @intFromEnum(self.{f})));\n", .{escaped});
                    }
                    try e.close_brace_nosemi();
                },
                .optional => {
                    try e.print("if (self.{f}) |v|", .{escaped});
                    try e.open_brace();
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    if (std.mem.eql(u8, enum_name, "google.protobuf.NullValue")) {
                        try e.print("try json.write_null(writer);\n", .{});
                    } else {
                        try e.print("try json.write_int(writer, @as(i64, @intFromEnum(v)));\n", .{});
                    }
                    try e.close_brace_nosemi();
                },
                .required => {
                    try e.print("{{\n", .{});
                    e.indent_level += 1;
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    if (std.mem.eql(u8, enum_name, "google.protobuf.NullValue")) {
                        try e.print("try json.write_null(writer);\n", .{});
                    } else {
                        try e.print("try json.write_int(writer, @as(i64, @intFromEnum(self.{f})));\n", .{escaped});
                    }
                    e.indent_level -= 1;
                    try e.print("}}\n", .{});
                },
                .repeated => {
                    try e.print("if (self.{f}.len > 0)", .{escaped});
                    try e.open_brace();
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    try e.print("try json.write_array_start(writer);\n", .{});
                    try e.print("for (self.{f}, 0..) |item, i|", .{escaped});
                    try e.open_brace();
                    try e.print("if (i > 0) try writer.writeByte(',');\n", .{});
                    if (std.mem.eql(u8, enum_name, "google.protobuf.NullValue")) {
                        try e.print("try json.write_null(writer);\n", .{});
                    } else {
                        try e.print("try json.write_int(writer, @as(i64, @intFromEnum(item)));\n", .{});
                    }
                    try e.close_brace_nosemi();
                    try e.print("try json.write_array_end(writer);\n", .{});
                    try e.close_brace_nosemi();
                },
            }
        },
    }
}

fn emit_json_scalar_write(e: *Emitter, write_fn: []const u8, s: ast.ScalarType, escaped: types.EscapedName) !void {
    // For int types that need casting
    switch (s) {
        .int32, .sint32, .sfixed32 => {
            try e.print("try json.{s}(writer, @as(i64, self.{f}));\n", .{ write_fn, escaped });
        },
        .int64, .sint64, .sfixed64 => {
            try e.print("try json.{s}(writer, @as(i64, self.{f}));\n", .{ write_fn, escaped });
        },
        .uint32 => {
            try e.print("try json.write_int(writer, @as(i64, self.{f}));\n", .{escaped});
        },
        .uint64, .fixed64 => {
            try e.print("try json.{s}(writer, @as(u64, self.{f}));\n", .{ write_fn, escaped });
        },
        .fixed32 => {
            try e.print("try json.write_int(writer, @as(i64, self.{f}));\n", .{escaped});
        },
        .double, .float, .bool, .string, .bytes => {
            try e.print("try json.{s}(writer, self.{f});\n", .{ write_fn, escaped });
        },
    }
}

fn emit_json_scalar_write_val(e: *Emitter, write_fn: []const u8, s: ast.ScalarType) !void {
    switch (s) {
        .int32, .sint32, .sfixed32 => {
            try e.print("try json.{s}(writer, @as(i64, v));\n", .{write_fn});
        },
        .int64, .sint64, .sfixed64 => {
            try e.print("try json.{s}(writer, @as(i64, v));\n", .{write_fn});
        },
        .uint32, .fixed32 => {
            try e.print("try json.write_int(writer, @as(i64, v));\n", .{});
        },
        .uint64, .fixed64 => {
            try e.print("try json.{s}(writer, @as(u64, v));\n", .{write_fn});
        },
        .double, .float, .bool, .string, .bytes => {
            try e.print("try json.{s}(writer, v);\n", .{write_fn});
        },
    }
}

fn emit_json_scalar_write_item(e: *Emitter, write_fn: []const u8, s: ast.ScalarType) !void {
    switch (s) {
        .int32, .sint32, .sfixed32 => {
            try e.print("try json.{s}(writer, @as(i64, item));\n", .{write_fn});
        },
        .int64, .sint64, .sfixed64 => {
            try e.print("try json.{s}(writer, @as(i64, item));\n", .{write_fn});
        },
        .uint32, .fixed32 => {
            try e.print("try json.write_int(writer, @as(i64, item));\n", .{});
        },
        .uint64, .fixed64 => {
            try e.print("try json.{s}(writer, @as(u64, item));\n", .{write_fn});
        },
        .double, .float, .bool, .string, .bytes => {
            try e.print("try json.{s}(writer, item);\n", .{write_fn});
        },
    }
}

fn emit_json_map(e: *Emitter, map_field: ast.MapField) !void {
    const escaped = types.escape_zig_keyword(map_field.name);
    var json_name_buf: [256]u8 = undefined;
    const jname = json_field_name(map_field.name, map_field.options, &json_name_buf);

    if (types.is_string_key(map_field.key_type)) {
        try e.print("if (self.{f}.count() > 0)", .{escaped});
        try e.open_brace();
        try e.print("first = try json.write_field_sep(writer, first);\n", .{});
        try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
        try e.print("try json.write_object_start(writer);\n", .{});
        try e.print("var map_first = true;\n", .{});
        try e.print("for (self.{f}.keys(), self.{f}.values()) |key, val|", .{ escaped, escaped });
        try e.open_brace();
        try e.print("map_first = try json.write_field_sep(writer, map_first);\n", .{});
        try e.print("try json.write_field_name(writer, key);\n", .{});
        try emit_json_map_value(e, map_field.value_type);
        try e.close_brace_nosemi();
        try e.print("try json.write_object_end(writer);\n", .{});
        try e.close_brace_nosemi();
    } else {
        // Non-string keys: proto-JSON represents as object with string keys
        try e.print("if (self.{f}.count() > 0)", .{escaped});
        try e.open_brace();
        try e.print("first = try json.write_field_sep(writer, first);\n", .{});
        try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
        try e.print("try json.write_object_start(writer);\n", .{});
        try e.print("var map_first = true;\n", .{});
        try e.print("for (self.{f}.keys(), self.{f}.values()) |key, val|", .{ escaped, escaped });
        try e.open_brace();
        try e.print("map_first = try json.write_field_sep(writer, map_first);\n", .{});
        // Convert key to string representation for JSON object key
        if (map_field.key_type == .bool) {
            try e.print("try writer.writeAll(if (key) \"\\\"true\\\":\" else \"\\\"false\\\":\");\n", .{});
        } else {
            try e.print("try writer.writeByte('\"');\n", .{});
            try e.print("try writer.print(\"{{d}}\", .{{key}});\n", .{});
            try e.print("try writer.writeAll(\"\\\":\");\n", .{});
        }
        try emit_json_map_value(e, map_field.value_type);
        try e.close_brace_nosemi();
        try e.print("try json.write_object_end(writer);\n", .{});
        try e.close_brace_nosemi();
    }
}

fn emit_json_map_value(e: *Emitter, value_type: ast.TypeRef) !void {
    switch (value_type) {
        .scalar => |s| {
            const write_fn = types.scalar_json_write_fn(s);
            switch (s) {
                .int32, .sint32, .sfixed32 => {
                    try e.print("try json.{s}(writer, @as(i64, val));\n", .{write_fn});
                },
                .int64, .sint64, .sfixed64 => {
                    try e.print("try json.{s}(writer, @as(i64, val));\n", .{write_fn});
                },
                .uint32, .fixed32 => {
                    try e.print("try json.write_int(writer, @as(i64, val));\n", .{});
                },
                .uint64, .fixed64 => {
                    try e.print("try json.{s}(writer, @as(u64, val));\n", .{write_fn});
                },
                .double, .float, .bool, .string, .bytes => {
                    try e.print("try json.{s}(writer, val);\n", .{write_fn});
                },
            }
        },
        .named => {
            try e.print("try val.to_json(writer);\n", .{});
        },
        .enum_ref => {
            try e.print("try json.write_int(writer, @as(i64, @intFromEnum(val)));\n", .{});
        },
    }
}

fn emit_json_group(e: *Emitter, grp: ast.Group) !void {
    var name_buf: [256]u8 = undefined;
    const field_name = group_field_name(grp.name, &name_buf);
    const escaped = types.escape_zig_keyword(field_name);
    // Use lowercase field name as JSON key
    var json_name_buf: [256]u8 = undefined;
    const jname = types.snake_to_lower_camel(field_name, &json_name_buf);

    switch (grp.label) {
        .optional, .implicit => {
            try e.print("if (self.{f}) |grp|", .{escaped});
            try e.open_brace();
            try e.print("first = try json.write_field_sep(writer, first);\n", .{});
            try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
            try e.print("try grp.to_json(writer);\n", .{});
            try e.close_brace_nosemi();
        },
        .required => {
            try e.print("{{\n", .{});
            e.indent_level += 1;
            try e.print("first = try json.write_field_sep(writer, first);\n", .{});
            try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
            try e.print("try self.{f}.to_json(writer);\n", .{escaped});
            e.indent_level -= 1;
            try e.print("}}\n", .{});
        },
        .repeated => {
            try e.print("if (self.{f}.len > 0)", .{escaped});
            try e.open_brace();
            try e.print("first = try json.write_field_sep(writer, first);\n", .{});
            try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
            try e.print("try json.write_array_start(writer);\n", .{});
            try e.print("for (self.{f}, 0..) |item, i|", .{escaped});
            try e.open_brace();
            try e.print("if (i > 0) try writer.writeByte(',');\n", .{});
            try e.print("try item.to_json(writer);\n", .{});
            try e.close_brace_nosemi();
            try e.print("try json.write_array_end(writer);\n", .{});
            try e.close_brace_nosemi();
        },
    }
}

fn emit_json_oneof(e: *Emitter, oneof: ast.Oneof, full_name: []const u8) !void {
    const escaped = types.escape_zig_keyword(oneof.name);
    try e.print("if (self.{f}) |oneof_val| switch (oneof_val)", .{escaped});
    try e.open_brace();
    for (oneof.fields) |field| {
        const field_escaped = types.escape_zig_keyword(field.name);
        var json_name_buf: [256]u8 = undefined;
        const jname = json_field_name(field.name, field.options, &json_name_buf);

        switch (field.type_name) {
            .scalar => |s| {
                const write_fn = types.scalar_json_write_fn(s);
                try e.print(".{f} => |v|", .{field_escaped});
                try e.open_brace();
                try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                switch (s) {
                    .int32, .sint32, .sfixed32 => {
                        try e.print("try json.{s}(writer, @as(i64, v));\n", .{write_fn});
                    },
                    .int64, .sint64, .sfixed64 => {
                        try e.print("try json.{s}(writer, @as(i64, v));\n", .{write_fn});
                    },
                    .uint32, .fixed32 => {
                        try e.print("try json.write_int(writer, @as(i64, v));\n", .{});
                    },
                    .uint64, .fixed64 => {
                        try e.print("try json.{s}(writer, @as(u64, v));\n", .{write_fn});
                    },
                    .double, .float, .bool, .string, .bytes => {
                        try e.print("try json.{s}(writer, v);\n", .{write_fn});
                    },
                }
                try e.close_brace_comma();
            },
            .named => |name| {
                try e.print(".{f} => |sub|", .{field_escaped});
                try e.open_brace();
                try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                if (std.mem.eql(u8, name, "google.protobuf.Any")) {
                    try e.print("try sub.to_json_with_context(writer, @This(), \"{s}\");\n", .{full_name});
                } else {
                    try e.print("try sub.to_json(writer);\n", .{});
                }
                try e.close_brace_comma();
            },
            .enum_ref => |enum_name| {
                try e.print(".{f} => |v|", .{field_escaped});
                try e.open_brace();
                try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                if (std.mem.eql(u8, enum_name, "google.protobuf.NullValue")) {
                    try e.print("_ = v;\n", .{});
                    try e.print("try json.write_null(writer);\n", .{});
                } else {
                    try e.print("try json.write_int(writer, @as(i64, @intFromEnum(v)));\n", .{});
                }
                try e.close_brace_comma();
            },
        }
    }
    try e.close_brace();
}

// ── JSON Deserialization Method ─────────────────────────────────────────

fn emit_from_json_method(e: *Emitter, msg: ast.Message, syntax: ast.Syntax, full_name: []const u8, recursive_types: *const RecursiveTypes) !void {
    const json_mod = "json";

    if (is_any_type(full_name)) {
        try emit_any_from_json_method(e);
        return;
    }
    if (detect_wrapper_kind(full_name)) |kind| {
        try emit_wrapper_from_json_method(e, kind);
        return;
    }
    if (is_timestamp_type(full_name)) {
        try emit_timestamp_from_json_method(e);
        return;
    }
    if (is_duration_type(full_name)) {
        try emit_duration_from_json_method(e);
        return;
    }
    if (is_field_mask_type(full_name)) {
        try emit_field_mask_from_json_method(e);
        return;
    }
    if (is_struct_type(full_name)) {
        try emit_struct_from_json_method(e);
        return;
    }
    if (is_value_type(full_name)) {
        try emit_value_from_json_method(e);
        return;
    }
    if (is_list_value_type(full_name)) {
        try emit_list_value_from_json_method(e);
        return;
    }

    // from_json entry point
    try e.print("/// Deserialize from proto-JSON format bytes. Caller must call deinit when done\n", .{});
    try e.print("pub fn from_json(allocator: std.mem.Allocator, json_bytes: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("var scanner = {s}.JsonScanner.init(allocator, json_bytes);\n", .{json_mod});
    try e.print("defer scanner.deinit();\n", .{});
    try e.print("return try @This().from_json_scanner(allocator, &scanner);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    // from_json_scanner public wrapper
    try e.print("pub fn from_json_scanner(allocator: std.mem.Allocator, scanner: *{s}.JsonScanner) !@This()", .{json_mod});
    try e.open_brace();
    try e.print("return @This().from_json_scanner_inner(allocator, scanner, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    // from_json_scanner_inner with depth tracking
    // Use explicit error set for recursive types to break error set cycles
    if (recursive_types.contains(msg.name)) {
        try e.print("pub fn from_json_scanner_inner(allocator: std.mem.Allocator, scanner: *{s}.JsonScanner, depth_remaining: usize) {s}.DecodeError!@This()", .{ json_mod, json_mod });
    } else {
        try e.print("pub fn from_json_scanner_inner(allocator: std.mem.Allocator, scanner: *{s}.JsonScanner, depth_remaining: usize) !@This()", .{json_mod});
    }
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});

    // Collect all fields for the if/else if chain
    const items = try collect_all_fields(e.allocator, msg);
    defer e.allocator.free(items);

    if (!msg_fields_need_allocator(msg) and items.len == 0) {
        try e.print("_ = allocator;\n", .{});
    }
    if (items.len == 0) {
        try e.print("const result: @This() = .{{}};\n", .{});
    } else {
        try e.print("var result: @This() = .{{}};\n", .{});
        try e.print("errdefer result.deinit(allocator);\n", .{});
        try e.print("var seen_fields: std.StringHashMapUnmanaged(void) = .{{}};\n", .{});
        try e.print("defer seen_fields.deinit(allocator);\n", .{});
    }

    // Expect object_start
    try e.print("const start_tok = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (start_tok != .object_start) return error.UnexpectedToken;\n", .{});

    // Loop over keys
    try e.print("while (true)", .{});
    try e.open_brace();
    try e.print("const tok = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("switch (tok)", .{});
    try e.open_brace();
    try e.print(".object_end => return result,\n", .{});

    if (items.len == 0) {
        try e.print(".string => |_|", .{});
    } else {
        try e.print(".string => |key|", .{});
    }
    try e.open_brace();

    var has_null_special_field = false;
    for (items) |item| switch (item) {
        .field => |f| switch (f.type_name) {
            .named => |name| {
                if (std.mem.eql(u8, name, "google.protobuf.Value")) has_null_special_field = true;
            },
            .enum_ref => |enum_name| {
                if (std.mem.eql(u8, enum_name, "google.protobuf.NullValue")) has_null_special_field = true;
            },
            else => {},
        },
        .oneof => |o| for (o.fields) |f| switch (f.type_name) {
            .named => |name| {
                if (std.mem.eql(u8, name, "google.protobuf.Value")) has_null_special_field = true;
            },
            .enum_ref => |enum_name| {
                if (std.mem.eql(u8, enum_name, "google.protobuf.NullValue")) has_null_special_field = true;
            },
            else => {},
        },
        else => {},
    };

    // Null check: consume-and-skip for most fields, but let google.protobuf.Value
    // and google.protobuf.NullValue fields handle null explicitly.
    try e.print("if (try scanner.peek()) |peeked| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (peeked == .null_value) {{\n", .{});
    e.indent_level += 1;
    if (has_null_special_field) {
        try e.print("const allow_null_special_field = ", .{});
        var first_null_check = true;
        for (items) |item| switch (item) {
            .field => |f| switch (f.type_name) {
                .named => |name| {
                    if (std.mem.eql(u8, name, "google.protobuf.Value")) {
                        var json_name_buf: [256]u8 = undefined;
                        const jname = json_field_name(f.name, f.options, &json_name_buf);
                        if (!first_null_check) try e.print_raw(" or ", .{});
                        first_null_check = false;
                        try e.print_raw("std.mem.eql(u8, key, \"{s}\")", .{jname});
                        if (!std.mem.eql(u8, jname, f.name)) {
                            try e.print_raw(" or std.mem.eql(u8, key, \"{s}\")", .{f.name});
                        }
                    }
                },
                .enum_ref => |enum_name| {
                    if (std.mem.eql(u8, enum_name, "google.protobuf.NullValue")) {
                        var json_name_buf: [256]u8 = undefined;
                        const jname = json_field_name(f.name, f.options, &json_name_buf);
                        if (!first_null_check) try e.print_raw(" or ", .{});
                        first_null_check = false;
                        try e.print_raw("std.mem.eql(u8, key, \"{s}\")", .{jname});
                        if (!std.mem.eql(u8, jname, f.name)) {
                            try e.print_raw(" or std.mem.eql(u8, key, \"{s}\")", .{f.name});
                        }
                    }
                },
                else => {},
            },
            .oneof => |o| for (o.fields) |f| switch (f.type_name) {
                .named => |name| {
                    if (std.mem.eql(u8, name, "google.protobuf.Value")) {
                        var json_name_buf: [256]u8 = undefined;
                        const jname = json_field_name(f.name, f.options, &json_name_buf);
                        if (!first_null_check) try e.print_raw(" or ", .{});
                        first_null_check = false;
                        try e.print_raw("std.mem.eql(u8, key, \"{s}\")", .{jname});
                        if (!std.mem.eql(u8, jname, f.name)) {
                            try e.print_raw(" or std.mem.eql(u8, key, \"{s}\")", .{f.name});
                        }
                    }
                },
                .enum_ref => |enum_name| {
                    if (std.mem.eql(u8, enum_name, "google.protobuf.NullValue")) {
                        var json_name_buf: [256]u8 = undefined;
                        const jname = json_field_name(f.name, f.options, &json_name_buf);
                        if (!first_null_check) try e.print_raw(" or ", .{});
                        first_null_check = false;
                        try e.print_raw("std.mem.eql(u8, key, \"{s}\")", .{jname});
                        if (!std.mem.eql(u8, jname, f.name)) {
                            try e.print_raw(" or std.mem.eql(u8, key, \"{s}\")", .{f.name});
                        }
                    }
                },
                else => {},
            },
            else => {},
        };
        try e.print_raw(";\n", .{});
        try e.print("if (!allow_null_special_field) {{\n", .{});
        e.indent_level += 1;
        try e.print("_ = try scanner.next();\n", .{});
        try e.print("continue;\n", .{});
        e.indent_level -= 1;
        try e.print("}}\n", .{});
    } else {
        try e.print("_ = try scanner.next();\n", .{});
        try e.print("continue;\n", .{});
    }
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});

    var first_branch = true;
    for (items) |item| {
        switch (item) {
            .field => |f| {
                try emit_from_json_field_branch(e, f, syntax, &first_branch, recursive_types, full_name);
            },
            .map => |m| {
                try emit_from_json_map_branch(e, m, &first_branch);
            },
            .oneof => |o| {
                for (o.fields) |f| {
                    try emit_from_json_oneof_field_branch(e, f, o, &first_branch, full_name);
                }
            },
            .group => |g| {
                try emit_from_json_group_branch(e, g, &first_branch);
            },
        }
    }

    // else: skip unknown field
    if (first_branch) {
        try e.print("try {s}.skip_value(scanner);\n", .{json_mod});
    } else {
        try e.print(" else {{\n", .{});
        e.indent_level += 1;
        try e.print("try {s}.skip_value(scanner);\n", .{json_mod});
        e.indent_level -= 1;
        try e.print("}}\n", .{});
    }

    try e.close_brace_comma(); // .string => |key| { ... },
    try e.print("else => return error.UnexpectedToken,\n", .{});
    try e.close_brace_nosemi(); // switch
    try e.close_brace_nosemi(); // while
    try e.print("return result;\n", .{});
    try e.close_brace_nosemi(); // fn
}

fn emit_from_json_field_branch(e: *Emitter, field: ast.Field, _: ast.Syntax, first_branch: *bool, recursive_types: *const RecursiveTypes, full_name: []const u8) !void {
    const escaped = types.escape_zig_keyword(field.name);
    var json_name_buf: [256]u8 = undefined;
    const jname = json_field_name(field.name, field.options, &json_name_buf);
    const json_mod = "json";

    // Build condition: match both camelCase and original name
    if (first_branch.*) {
        try e.print("if (", .{});
        first_branch.* = false;
    } else {
        try e.print_raw(" else if (", .{});
    }
    try e.print_raw("std.mem.eql(u8, key, \"{s}\")", .{jname});
    if (!std.mem.eql(u8, jname, field.name)) {
        try e.print_raw(" or std.mem.eql(u8, key, \"{s}\")", .{field.name});
    }
    try e.print_raw(")", .{});
    try e.open_brace();
    try e.print("if (try {s}.mark_field_seen(&seen_fields, allocator, \"{s}\")) return error.UnexpectedToken;\n", .{ json_mod, field.name });

    switch (field.type_name) {
        .scalar => |s| {
            const read_fn = types.scalar_json_read_fn(s);
            switch (field.label) {
                .implicit, .optional, .required => {
                    if (s == .string) {
                        try e.print("result.{f} = try allocator.dupe(u8, try {s}.{s}(scanner));\n", .{ escaped, json_mod, read_fn });
                    } else if (s == .bytes) {
                        try e.print("result.{f} = try {s}.{s}(scanner, allocator);\n", .{ escaped, json_mod, read_fn });
                    } else {
                        try e.print("result.{f} = try {s}.{s}(scanner);\n", .{ escaped, json_mod, read_fn });
                    }
                },
                .repeated => {
                    try emit_from_json_repeated_scalar(e, escaped, s, read_fn);
                },
            }
        },
        .named => |name| {
            const is_recursive = recursive_types.contains(name);
            switch (field.label) {
                .implicit, .optional => {
                    if (std.mem.eql(u8, name, "google.protobuf.Any")) {
                        try e.print("result.{f} = try {s}.from_json_scanner_with_context(allocator, scanner, depth_remaining - 1, @This(), \"{s}\");\n", .{ escaped, name, full_name });
                    } else if (is_recursive) {
                        try e.print("{{\n", .{});
                        e.indent_level += 1;
                        try e.print("const val = try {s}.from_json_scanner_inner(allocator, scanner, depth_remaining - 1);\n", .{name});
                        try e.print("const ptr = try allocator.create({s});\n", .{name});
                        try e.print("ptr.* = val;\n", .{});
                        try e.print("result.{f} = ptr;\n", .{escaped});
                        e.indent_level -= 1;
                        try e.print("}}\n", .{});
                    } else {
                        try e.print("result.{f} = try {s}.from_json_scanner_inner(allocator, scanner, depth_remaining - 1);\n", .{ escaped, name });
                    }
                },
                .required => {
                    if (std.mem.eql(u8, name, "google.protobuf.Any")) {
                        try e.print("result.{f} = try {s}.from_json_scanner_with_context(allocator, scanner, depth_remaining - 1, @This(), \"{s}\");\n", .{ escaped, name, full_name });
                    } else {
                        try e.print("result.{f} = try {s}.from_json_scanner_inner(allocator, scanner, depth_remaining - 1);\n", .{ escaped, name });
                    }
                },
                .repeated => {
                    try emit_from_json_repeated_named(e, escaped, name, full_name);
                },
            }
        },
        .enum_ref => |enum_name| {
            switch (field.label) {
                .implicit, .optional, .required => {
                    try e.print("const enum_val = {s}.read_enum_value(scanner, &{s}.descriptor) catch |err| switch (err) {{\n", .{ json_mod, enum_name });
                    e.indent_level += 1;
                    try e.print("error.UnexpectedToken => if ({s}.ignore_unknown_enum_values) continue else return err,\n", .{json_mod});
                    try e.print("else => return err,\n", .{});
                    e.indent_level -= 1;
                    try e.print("}};\n", .{});
                    try e.print("result.{f} = @enumFromInt(enum_val);\n", .{escaped});
                },
                .repeated => {
                    try emit_from_json_repeated_enum(e, escaped, enum_name);
                },
            }
        },
    }

    e.indent_level -= 1;
    try e.print("}}", .{});
}

fn emit_from_json_repeated_scalar(e: *Emitter, escaped: types.EscapedName, s: ast.ScalarType, read_fn: []const u8) !void {
    const json_mod = "json";
    try e.print("const arr_start = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (arr_start != .array_start) return error.UnexpectedToken;\n", .{});
    try e.print("var list: std.ArrayListUnmanaged({s}) = .empty;\n", .{types.scalar_zig_type(s)});
    try emit_list_errdefer(e, s);
    try e.print("while (true)", .{});
    try e.open_brace();
    try e.print("if (try scanner.peek()) |p| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (p == .array_end) {{ _ = try scanner.next(); break; }}\n", .{});
    e.indent_level -= 1;
    try e.print("}} else break;\n", .{});
    if (s == .string) {
        try e.print("try list.append(allocator, try allocator.dupe(u8, try {s}.{s}(scanner)));\n", .{ json_mod, read_fn });
    } else if (s == .bytes) {
        try e.print("try list.append(allocator, try {s}.{s}(scanner, allocator));\n", .{ json_mod, read_fn });
    } else {
        try e.print("try list.append(allocator, try {s}.{s}(scanner));\n", .{ json_mod, read_fn });
    }
    try e.close_brace_nosemi();
    try e.print("result.{f} = try list.toOwnedSlice(allocator);\n", .{escaped});
}

fn emit_from_json_repeated_named(e: *Emitter, escaped: types.EscapedName, name: []const u8, full_name: []const u8) !void {
    try e.print("const arr_start = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (arr_start != .array_start) return error.UnexpectedToken;\n", .{});
    try e.print("var list: std.ArrayListUnmanaged({s}) = .empty;\n", .{name});
    try emit_named_list_errdefer(e);
    try e.print("while (true)", .{});
    try e.open_brace();
    try e.print("if (try scanner.peek()) |p| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (p == .array_end) {{ _ = try scanner.next(); break; }}\n", .{});
    e.indent_level -= 1;
    try e.print("}} else break;\n", .{});
    if (std.mem.eql(u8, name, "google.protobuf.Any")) {
        try e.print("try list.append(allocator, try {s}.from_json_scanner_with_context(allocator, scanner, depth_remaining - 1, @This(), \"{s}\"));\n", .{ name, full_name });
    } else {
        try e.print("try list.append(allocator, try {s}.from_json_scanner_inner(allocator, scanner, depth_remaining - 1));\n", .{name});
    }
    try e.close_brace_nosemi();
    try e.print("result.{f} = try list.toOwnedSlice(allocator);\n", .{escaped});
}

fn emit_from_json_repeated_enum(e: *Emitter, escaped: types.EscapedName, enum_name: []const u8) !void {
    const json_mod = "json";
    try e.print("const arr_start = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (arr_start != .array_start) return error.UnexpectedToken;\n", .{});
    try e.print("var list: std.ArrayListUnmanaged(@TypeOf(result.{f}[0])) = .empty;\n", .{escaped});
    try e.print("errdefer list.deinit(allocator);\n", .{});
    try e.print("while (true)", .{});
    try e.open_brace();
    try e.print("if (try scanner.peek()) |p| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (p == .array_end) {{ _ = try scanner.next(); break; }}\n", .{});
    e.indent_level -= 1;
    try e.print("}} else break;\n", .{});
    try e.print("const enum_val = {s}.read_enum_value(scanner, &{s}.descriptor) catch |err| switch (err) {{\n", .{ json_mod, enum_name });
    e.indent_level += 1;
    try e.print("error.UnexpectedToken => if ({s}.ignore_unknown_enum_values) continue else return err,\n", .{json_mod});
    try e.print("else => return err,\n", .{});
    e.indent_level -= 1;
    try e.print("}};\n", .{});
    try e.print("try list.append(allocator, @enumFromInt(enum_val));\n", .{});
    try e.close_brace_nosemi();
    try e.print("result.{f} = try list.toOwnedSlice(allocator);\n", .{escaped});
}

fn emit_from_json_map_branch(e: *Emitter, map_field: ast.MapField, first_branch: *bool) !void {
    const escaped = types.escape_zig_keyword(map_field.name);
    var json_name_buf: [256]u8 = undefined;
    const jname = json_field_name(map_field.name, map_field.options, &json_name_buf);
    const json_mod = "json";

    if (first_branch.*) {
        try e.print("if (", .{});
        first_branch.* = false;
    } else {
        try e.print_raw(" else if (", .{});
    }
    try e.print_raw("std.mem.eql(u8, key, \"{s}\")", .{jname});
    if (!std.mem.eql(u8, jname, map_field.name)) {
        try e.print_raw(" or std.mem.eql(u8, key, \"{s}\")", .{map_field.name});
    }
    try e.print_raw(")", .{});
    try e.open_brace();
    try e.print("if (try {s}.mark_field_seen(&seen_fields, allocator, \"{s}\")) return error.UnexpectedToken;\n", .{ json_mod, map_field.name });

    // Expect object_start
    try e.print("const map_start = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (map_start != .object_start) return error.UnexpectedToken;\n", .{});

    // Loop
    try e.print("while (true)", .{});
    try e.open_brace();
    try e.print("if (try scanner.peek()) |p| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (p == .object_end) {{ _ = try scanner.next(); break; }}\n", .{});
    e.indent_level -= 1;
    try e.print("}} else break;\n", .{});

    // Read key as string
    try e.print("const map_key_str = try {s}.read_string(scanner);\n", .{json_mod});

    // Coerce key
    if (types.is_string_key(map_field.key_type)) {
        try e.print("const map_key = try allocator.dupe(u8, map_key_str);\n", .{});
        try e.print("errdefer allocator.free(map_key);\n", .{});
    } else if (map_field.key_type == .bool) {
        try e.print("const map_key = std.mem.eql(u8, map_key_str, \"true\");\n", .{});
    } else {
        // Integer key types
        const zig_type = types.scalar_zig_type(map_field.key_type);
        try e.print("const map_key = std.fmt.parseInt({s}, map_key_str, 10) catch return error.Overflow;\n", .{zig_type});
    }

    // Read value
    switch (map_field.value_type) {
        .scalar => |s| {
            const read_fn = types.scalar_json_read_fn(s);
            if (s == .string) {
                try e.print("const map_val = try allocator.dupe(u8, try {s}.{s}(scanner));\n", .{ json_mod, read_fn });
                try e.print("errdefer allocator.free(map_val);\n", .{});
            } else if (s == .bytes) {
                try e.print("const map_val = try {s}.{s}(scanner, allocator);\n", .{ json_mod, read_fn });
                try e.print("errdefer allocator.free(map_val);\n", .{});
            } else {
                try e.print("const map_val = try {s}.{s}(scanner);\n", .{ json_mod, read_fn });
            }
        },
        .named => |name| {
            try e.print("var map_val = try {s}.from_json_scanner_inner(allocator, scanner, depth_remaining - 1);\n", .{name});
            try e.print("errdefer map_val.deinit(allocator);\n", .{});
        },
        .enum_ref => |name| {
            try e.print("const map_val_opt: ?{s} = blk: {{\n", .{name});
            e.indent_level += 1;
            try e.print("const enum_val = {s}.read_enum_value(scanner, &{s}.descriptor) catch |err| switch (err) {{\n", .{ json_mod, name });
            e.indent_level += 1;
            try e.print("error.UnexpectedToken => if ({s}.ignore_unknown_enum_values) break :blk null else return err,\n", .{json_mod});
            try e.print("else => return err,\n", .{});
            e.indent_level -= 1;
            try e.print("}};\n", .{});
            try e.print("break :blk @enumFromInt(enum_val);\n", .{});
            e.indent_level -= 1;
            try e.print("}};\n", .{});
        },
    }
    switch (map_field.value_type) {
        .enum_ref => {
            try e.print("if (map_val_opt) |map_val|", .{});
            try e.open_brace();
            try emit_map_put_with_free(e, escaped, map_field.key_type, map_field.value_type, "map_key", "map_val");
            try e.close_brace_nosemi();
            try e.print("\n", .{});
        },
        else => {
            try emit_map_put_with_free(e, escaped, map_field.key_type, map_field.value_type, "map_key", "map_val");
        },
    }

    try e.close_brace_nosemi(); // while
    e.indent_level -= 1;
    try e.print("}}", .{});
}

fn emit_from_json_group_branch(e: *Emitter, grp: ast.Group, first_branch: *bool) !void {
    var name_buf: [256]u8 = undefined;
    const field_name = group_field_name(grp.name, &name_buf);
    const escaped = types.escape_zig_keyword(field_name);
    var json_name_buf: [256]u8 = undefined;
    const jname = types.snake_to_lower_camel(field_name, &json_name_buf);

    if (first_branch.*) {
        try e.print("if (", .{});
        first_branch.* = false;
    } else {
        try e.print_raw(" else if (", .{});
    }
    try e.print_raw("std.mem.eql(u8, key, \"{s}\")", .{jname});
    if (!std.mem.eql(u8, jname, field_name)) {
        try e.print_raw(" or std.mem.eql(u8, key, \"{s}\")", .{field_name});
    }
    try e.print_raw(")", .{});
    try e.open_brace();
    try e.print("if (try json.mark_field_seen(&seen_fields, allocator, \"{s}\")) return error.UnexpectedToken;\n", .{field_name});

    switch (grp.label) {
        .optional, .implicit, .required => {
            try e.print("result.{f} = try {s}.from_json_scanner_inner(allocator, scanner, depth_remaining - 1);\n", .{ escaped, grp.name });
        },
        .repeated => {
            try e.print("const arr_start = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
            try e.print("if (arr_start != .array_start) return error.UnexpectedToken;\n", .{});
            try e.print("var list: std.ArrayListUnmanaged({s}) = .empty;\n", .{grp.name});
            try e.print("while (true)", .{});
            try e.open_brace();
            try e.print("if (try scanner.peek()) |p| {{\n", .{});
            e.indent_level += 1;
            try e.print("if (p == .array_end) {{ _ = try scanner.next(); break; }}\n", .{});
            e.indent_level -= 1;
            try e.print("}} else break;\n", .{});
            try e.print("try list.append(allocator, try {s}.from_json_scanner_inner(allocator, scanner, depth_remaining - 1));\n", .{grp.name});
            try e.close_brace_nosemi();
            try e.print("result.{f} = try list.toOwnedSlice(allocator);\n", .{escaped});
        },
    }

    e.indent_level -= 1;
    try e.print("}}", .{});
}

fn emit_from_json_oneof_field_branch(e: *Emitter, field: ast.Field, oneof: ast.Oneof, first_branch: *bool, full_name: []const u8) !void {
    const field_escaped = types.escape_zig_keyword(field.name);
    const oneof_escaped = types.escape_zig_keyword(oneof.name);
    var json_name_buf: [256]u8 = undefined;
    const jname = json_field_name(field.name, field.options, &json_name_buf);
    const json_mod = "json";

    if (first_branch.*) {
        try e.print("if (", .{});
        first_branch.* = false;
    } else {
        try e.print_raw(" else if (", .{});
    }
    try e.print_raw("std.mem.eql(u8, key, \"{s}\")", .{jname});
    if (!std.mem.eql(u8, jname, field.name)) {
        try e.print_raw(" or std.mem.eql(u8, key, \"{s}\")", .{field.name});
    }
    try e.print_raw(")", .{});
    try e.open_brace();
    try e.print("if (try {s}.mark_field_seen(&seen_fields, allocator, \"{s}\")) return error.UnexpectedToken;\n", .{ json_mod, field.name });
    try e.print("if (result.{f} != null) return error.UnexpectedToken;\n", .{oneof_escaped});

    switch (field.type_name) {
        .scalar => |s| {
            const read_fn = types.scalar_json_read_fn(s);
            if (s == .string) {
                try e.print("result.{f} = .{{ .{f} = try allocator.dupe(u8, try {s}.{s}(scanner)) }};\n", .{ oneof_escaped, field_escaped, json_mod, read_fn });
            } else if (s == .bytes) {
                try e.print("result.{f} = .{{ .{f} = try {s}.{s}(scanner, allocator) }};\n", .{ oneof_escaped, field_escaped, json_mod, read_fn });
            } else {
                try e.print("result.{f} = .{{ .{f} = try {s}.{s}(scanner) }};\n", .{ oneof_escaped, field_escaped, json_mod, read_fn });
            }
        },
        .named => |name| {
            if (std.mem.eql(u8, name, "google.protobuf.Any")) {
                try e.print("result.{f} = .{{ .{f} = try {s}.from_json_scanner_with_context(allocator, scanner, depth_remaining - 1, @This(), \"{s}\") }};\n", .{ oneof_escaped, field_escaped, name, full_name });
            } else {
                try e.print("result.{f} = .{{ .{f} = try {s}.from_json_scanner_inner(allocator, scanner, depth_remaining - 1) }};\n", .{ oneof_escaped, field_escaped, name });
            }
        },
        .enum_ref => |enum_name| {
            try e.print("const enum_val = {s}.read_enum_value(scanner, &{s}.descriptor) catch |err| switch (err) {{\n", .{ json_mod, enum_name });
            e.indent_level += 1;
            try e.print("error.UnexpectedToken => if ({s}.ignore_unknown_enum_values) continue else return err,\n", .{json_mod});
            try e.print("else => return err,\n", .{});
            e.indent_level -= 1;
            try e.print("}};\n", .{});
            try e.print("result.{f} = .{{ .{f} = @enumFromInt(enum_val) }};\n", .{ oneof_escaped, field_escaped });
        },
    }

    e.indent_level -= 1;
    try e.print("}}", .{});
}

// ── Text Format Serialization Method ─────────────────────────────────

fn emit_to_text_method(e: *Emitter, msg: ast.Message, syntax: ast.Syntax, full_name: []const u8) !void {
    try e.print("/// Serialize this message to protobuf text format\n", .{});
    try e.print("pub fn to_text(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    try e.print("return self.to_text_indent(writer, 0);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn to_text_indent(self: @This(), writer: *std.Io.Writer, indent: usize) std.Io.Writer.Error!void", .{});
    try e.open_brace();

    const items = try collect_all_fields(e.allocator, msg);
    defer e.allocator.free(items);

    if (items.len > 0) {
        for (items) |item| {
            switch (item) {
                .field => |f| try emit_text_field(e, f, syntax),
                .map => |m| try emit_text_map(e, m),
                .oneof => |o| try emit_text_oneof(e, o),
                .group => |g| {
                    const is_ext_group = number_in_extension_ranges(g.number, msg.extension_ranges);
                    if (is_ext_group) {
                        var field_name_buf: [256]u8 = undefined;
                        var ext_name_buf: [512]u8 = undefined;
                        const ext_field_name = group_field_name(g.name, &field_name_buf);
                        const ext_full_name = if (std.mem.lastIndexOfScalar(u8, full_name, '.')) |idx|
                            std.fmt.bufPrint(&ext_name_buf, "{s}.{s}", .{ full_name[0..idx], ext_field_name }) catch unreachable
                        else
                            ext_field_name;
                        try emit_text_group(e, g, ext_full_name);
                    } else {
                        try emit_text_group(e, g, null);
                    }
                },
            }
        }
    } else {
        try e.print("_ = self;\n", .{});
        try e.print("_ = writer;\n", .{});
        try e.print("_ = indent;\n", .{});
    }

    try e.close_brace_nosemi();
}

fn emit_text_field(e: *Emitter, field: ast.Field, syntax: ast.Syntax) !void {
    const escaped = types.escape_zig_keyword(field.name);
    _ = syntax;

    switch (field.type_name) {
        .scalar => |s| {
            const write_fn = types.scalar_text_write_fn(s);
            switch (field.label) {
                .implicit => {
                    // Proto3 implicit: skip if default
                    if (s == .string or s == .bytes) {
                        try e.print("if (self.{f}.len > 0)", .{escaped});
                        try e.open_brace();
                        try e.print("try text_format.write_indent(writer, indent);\n", .{});
                        try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                        try e.print("try text_format.{s}(writer, self.{f});\n", .{ write_fn, escaped });
                        try e.print("try writer.writeByte('\\n');\n", .{});
                        try e.close_brace_nosemi();
                    } else if (s == .bool) {
                        try e.print("if (self.{f})", .{escaped});
                        try e.open_brace();
                        try e.print("try text_format.write_indent(writer, indent);\n", .{});
                        try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                        try e.print("try text_format.write_bool(writer, self.{f});\n", .{escaped});
                        try e.print("try writer.writeByte('\\n');\n", .{});
                        try e.close_brace_nosemi();
                    } else if (s == .double) {
                        // Preserve -0.0 for proto3 implicit presence checks.
                        try e.print("if (@as(u64, @bitCast(self.{f})) != 0)", .{escaped});
                        try e.open_brace();
                        try e.print("try text_format.write_indent(writer, indent);\n", .{});
                        try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                        try e.print("try text_format.write_float(writer, self.{f});\n", .{escaped});
                        try e.print("try writer.writeByte('\\n');\n", .{});
                        try e.close_brace_nosemi();
                    } else if (s == .float) {
                        // Preserve -0.0 for proto3 implicit presence checks.
                        try e.print("if (@as(u32, @bitCast(self.{f})) != 0)", .{escaped});
                        try e.open_brace();
                        try e.print("try text_format.write_indent(writer, indent);\n", .{});
                        try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                        try e.print("try text_format.write_float(writer, self.{f});\n", .{escaped});
                        try e.print("try writer.writeByte('\\n');\n", .{});
                        try e.close_brace_nosemi();
                    } else {
                        // integer types
                        try e.print("if (self.{f} != 0)", .{escaped});
                        try e.open_brace();
                        try e.print("try text_format.write_indent(writer, indent);\n", .{});
                        try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                        try emit_text_scalar_write(e, write_fn, s, escaped);
                        try e.print("try writer.writeByte('\\n');\n", .{});
                        try e.close_brace_nosemi();
                    }
                },
                .optional => {
                    try e.print("if (self.{f}) |v|", .{escaped});
                    try e.open_brace();
                    try e.print("try text_format.write_indent(writer, indent);\n", .{});
                    try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                    try emit_text_scalar_write_val(e, write_fn, s);
                    try e.print("try writer.writeByte('\\n');\n", .{});
                    try e.close_brace_nosemi();
                },
                .required => {
                    try e.print("{{\n", .{});
                    e.indent_level += 1;
                    try e.print("try text_format.write_indent(writer, indent);\n", .{});
                    try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                    try emit_text_scalar_write(e, write_fn, s, escaped);
                    try e.print("try writer.writeByte('\\n');\n", .{});
                    e.indent_level -= 1;
                    try e.print("}}\n", .{});
                },
                .repeated => {
                    try e.print("for (self.{f}) |item|", .{escaped});
                    try e.open_brace();
                    try e.print("try text_format.write_indent(writer, indent);\n", .{});
                    try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                    try emit_text_scalar_write_item(e, write_fn, s);
                    try e.print("try writer.writeByte('\\n');\n", .{});
                    try e.close_brace_nosemi();
                },
            }
        },
        .named => {
            switch (field.label) {
                .repeated => {
                    try e.print("for (self.{f}) |item|", .{escaped});
                    try e.open_brace();
                    try e.print("try text_format.write_indent(writer, indent);\n", .{});
                    try e.print("try writer.writeAll(\"{s} {{\\n\");\n", .{field.name});
                    try e.print("try item.to_text_indent(writer, indent + 1);\n", .{});
                    try e.print("try text_format.write_indent(writer, indent);\n", .{});
                    try e.print("try writer.writeAll(\"}}\\n\");\n", .{});
                    try e.close_brace_nosemi();
                },
                .optional, .implicit => {
                    try e.print("if (self.{f}) |sub|", .{escaped});
                    try e.open_brace();
                    try e.print("try text_format.write_indent(writer, indent);\n", .{});
                    try e.print("try writer.writeAll(\"{s} {{\\n\");\n", .{field.name});
                    try e.print("try sub.to_text_indent(writer, indent + 1);\n", .{});
                    try e.print("try text_format.write_indent(writer, indent);\n", .{});
                    try e.print("try writer.writeAll(\"}}\\n\");\n", .{});
                    try e.close_brace_nosemi();
                },
                .required => {
                    try e.print("{{\n", .{});
                    e.indent_level += 1;
                    try e.print("try text_format.write_indent(writer, indent);\n", .{});
                    try e.print("try writer.writeAll(\"{s} {{\\n\");\n", .{field.name});
                    try e.print("try self.{f}.to_text_indent(writer, indent + 1);\n", .{escaped});
                    try e.print("try text_format.write_indent(writer, indent);\n", .{});
                    try e.print("try writer.writeAll(\"}}\\n\");\n", .{});
                    e.indent_level -= 1;
                    try e.print("}}\n", .{});
                },
            }
        },
        .enum_ref => {
            switch (field.label) {
                .implicit => {
                    try e.print("if (@intFromEnum(self.{f}) != 0)", .{escaped});
                    try e.open_brace();
                    try e.print("try text_format.write_indent(writer, indent);\n", .{});
                    try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                    try e.print("try text_format.write_enum_value(writer, self.{f});\n", .{escaped});
                    try e.print("try writer.writeByte('\\n');\n", .{});
                    try e.close_brace_nosemi();
                },
                .optional => {
                    try e.print("if (self.{f}) |v|", .{escaped});
                    try e.open_brace();
                    try e.print("try text_format.write_indent(writer, indent);\n", .{});
                    try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                    try e.print("try text_format.write_enum_value(writer, v);\n", .{});
                    try e.print("try writer.writeByte('\\n');\n", .{});
                    try e.close_brace_nosemi();
                },
                .required => {
                    try e.print("{{\n", .{});
                    e.indent_level += 1;
                    try e.print("try text_format.write_indent(writer, indent);\n", .{});
                    try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                    try e.print("try text_format.write_enum_value(writer, self.{f});\n", .{escaped});
                    try e.print("try writer.writeByte('\\n');\n", .{});
                    e.indent_level -= 1;
                    try e.print("}}\n", .{});
                },
                .repeated => {
                    try e.print("for (self.{f}) |item|", .{escaped});
                    try e.open_brace();
                    try e.print("try text_format.write_indent(writer, indent);\n", .{});
                    try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                    try e.print("try text_format.write_enum_value(writer, item);\n", .{});
                    try e.print("try writer.writeByte('\\n');\n", .{});
                    try e.close_brace_nosemi();
                },
            }
        },
    }
}

fn emit_text_scalar_write(e: *Emitter, write_fn: []const u8, s: ast.ScalarType, escaped: types.EscapedName) !void {
    switch (s) {
        .int32, .sint32, .sfixed32 => {
            try e.print("try text_format.{s}(writer, @as(i64, self.{f}));\n", .{ write_fn, escaped });
        },
        .int64, .sint64, .sfixed64 => {
            try e.print("try text_format.{s}(writer, @as(i64, self.{f}));\n", .{ write_fn, escaped });
        },
        .uint32, .fixed32 => {
            try e.print("try text_format.{s}(writer, @as(u64, self.{f}));\n", .{ write_fn, escaped });
        },
        .uint64, .fixed64 => {
            try e.print("try text_format.{s}(writer, @as(u64, self.{f}));\n", .{ write_fn, escaped });
        },
        .double, .float, .bool, .string, .bytes => {
            try e.print("try text_format.{s}(writer, self.{f});\n", .{ write_fn, escaped });
        },
    }
}

fn emit_text_scalar_write_val(e: *Emitter, write_fn: []const u8, s: ast.ScalarType) !void {
    switch (s) {
        .int32, .sint32, .sfixed32 => {
            try e.print("try text_format.{s}(writer, @as(i64, v));\n", .{write_fn});
        },
        .int64, .sint64, .sfixed64 => {
            try e.print("try text_format.{s}(writer, @as(i64, v));\n", .{write_fn});
        },
        .uint32, .fixed32 => {
            try e.print("try text_format.{s}(writer, @as(u64, v));\n", .{write_fn});
        },
        .uint64, .fixed64 => {
            try e.print("try text_format.{s}(writer, @as(u64, v));\n", .{write_fn});
        },
        .double, .float, .bool, .string, .bytes => {
            try e.print("try text_format.{s}(writer, v);\n", .{write_fn});
        },
    }
}

fn emit_text_scalar_write_item(e: *Emitter, write_fn: []const u8, s: ast.ScalarType) !void {
    switch (s) {
        .int32, .sint32, .sfixed32 => {
            try e.print("try text_format.{s}(writer, @as(i64, item));\n", .{write_fn});
        },
        .int64, .sint64, .sfixed64 => {
            try e.print("try text_format.{s}(writer, @as(i64, item));\n", .{write_fn});
        },
        .uint32, .fixed32 => {
            try e.print("try text_format.{s}(writer, @as(u64, item));\n", .{write_fn});
        },
        .uint64, .fixed64 => {
            try e.print("try text_format.{s}(writer, @as(u64, item));\n", .{write_fn});
        },
        .double, .float, .bool, .string, .bytes => {
            try e.print("try text_format.{s}(writer, item);\n", .{write_fn});
        },
    }
}

fn emit_text_map(e: *Emitter, map_field: ast.MapField) !void {
    const escaped = types.escape_zig_keyword(map_field.name);

    try e.print("for (self.{f}.keys(), self.{f}.values()) |key, val|", .{ escaped, escaped });
    try e.open_brace();
    try e.print("try text_format.write_indent(writer, indent);\n", .{});
    try e.print("try writer.writeAll(\"{s} {{\\n\");\n", .{map_field.name});

    // Write key
    try e.print("try text_format.write_indent(writer, indent + 1);\n", .{});
    try e.print("try writer.writeAll(\"key: \");\n", .{});
    if (types.is_string_key(map_field.key_type)) {
        try e.print("try text_format.write_string(writer, key);\n", .{});
    } else if (map_field.key_type == .bool) {
        try e.print("try text_format.write_bool(writer, key);\n", .{});
    } else {
        const write_fn = types.scalar_text_write_fn(map_field.key_type);
        switch (map_field.key_type) {
            .int32, .sint32, .sfixed32 => {
                try e.print("try text_format.{s}(writer, @as(i64, key));\n", .{write_fn});
            },
            .int64, .sint64, .sfixed64 => {
                try e.print("try text_format.{s}(writer, @as(i64, key));\n", .{write_fn});
            },
            .uint32, .fixed32 => {
                try e.print("try text_format.{s}(writer, @as(u64, key));\n", .{write_fn});
            },
            .uint64, .fixed64 => {
                try e.print("try text_format.{s}(writer, @as(u64, key));\n", .{write_fn});
            },
            else => {
                try e.print("try text_format.{s}(writer, key);\n", .{write_fn});
            },
        }
    }
    try e.print("try writer.writeByte('\\n');\n", .{});

    // Write value
    try e.print("try text_format.write_indent(writer, indent + 1);\n", .{});
    switch (map_field.value_type) {
        .scalar => |s| {
            const write_fn = types.scalar_text_write_fn(s);
            try e.print("try writer.writeAll(\"value: \");\n", .{});
            switch (s) {
                .int32, .sint32, .sfixed32 => {
                    try e.print("try text_format.{s}(writer, @as(i64, val));\n", .{write_fn});
                },
                .int64, .sint64, .sfixed64 => {
                    try e.print("try text_format.{s}(writer, @as(i64, val));\n", .{write_fn});
                },
                .uint32, .fixed32 => {
                    try e.print("try text_format.{s}(writer, @as(u64, val));\n", .{write_fn});
                },
                .uint64, .fixed64 => {
                    try e.print("try text_format.{s}(writer, @as(u64, val));\n", .{write_fn});
                },
                .double, .float, .bool, .string, .bytes => {
                    try e.print("try text_format.{s}(writer, val);\n", .{write_fn});
                },
            }
            try e.print("try writer.writeByte('\\n');\n", .{});
        },
        .named => {
            try e.print("try writer.writeAll(\"value {{\\n\");\n", .{});
            try e.print("try val.to_text_indent(writer, indent + 2);\n", .{});
            try e.print("try text_format.write_indent(writer, indent + 1);\n", .{});
            try e.print("try writer.writeAll(\"}}\\n\");\n", .{});
        },
        .enum_ref => {
            try e.print("try writer.writeAll(\"value: \");\n", .{});
            try e.print("try text_format.write_enum_value(writer, val);\n", .{});
            try e.print("try writer.writeByte('\\n');\n", .{});
        },
    }

    try e.print("try text_format.write_indent(writer, indent);\n", .{});
    try e.print("try writer.writeAll(\"}}\\n\");\n", .{});
    try e.close_brace_nosemi();
}

fn emit_text_oneof(e: *Emitter, oneof: ast.Oneof) !void {
    const escaped = types.escape_zig_keyword(oneof.name);
    try e.print("if (self.{f}) |oneof_val| switch (oneof_val)", .{escaped});
    try e.open_brace();
    for (oneof.fields) |field| {
        const field_escaped = types.escape_zig_keyword(field.name);

        switch (field.type_name) {
            .scalar => |s| {
                const write_fn = types.scalar_text_write_fn(s);
                try e.print(".{f} => |v|", .{field_escaped});
                try e.open_brace();
                try e.print("try text_format.write_indent(writer, indent);\n", .{});
                try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                switch (s) {
                    .int32, .sint32, .sfixed32 => {
                        try e.print("try text_format.{s}(writer, @as(i64, v));\n", .{write_fn});
                    },
                    .int64, .sint64, .sfixed64 => {
                        try e.print("try text_format.{s}(writer, @as(i64, v));\n", .{write_fn});
                    },
                    .uint32, .fixed32 => {
                        try e.print("try text_format.{s}(writer, @as(u64, v));\n", .{write_fn});
                    },
                    .uint64, .fixed64 => {
                        try e.print("try text_format.{s}(writer, @as(u64, v));\n", .{write_fn});
                    },
                    .double, .float, .bool, .string, .bytes => {
                        try e.print("try text_format.{s}(writer, v);\n", .{write_fn});
                    },
                }
                try e.print("try writer.writeByte('\\n');\n", .{});
                try e.close_brace_comma();
            },
            .named => {
                try e.print(".{f} => |sub|", .{field_escaped});
                try e.open_brace();
                try e.print("try text_format.write_indent(writer, indent);\n", .{});
                try e.print("try writer.writeAll(\"{s} {{\\n\");\n", .{field.name});
                try e.print("try sub.to_text_indent(writer, indent + 1);\n", .{});
                try e.print("try text_format.write_indent(writer, indent);\n", .{});
                try e.print("try writer.writeAll(\"}}\\n\");\n", .{});
                try e.close_brace_comma();
            },
            .enum_ref => {
                try e.print(".{f} => |v|", .{field_escaped});
                try e.open_brace();
                try e.print("try text_format.write_indent(writer, indent);\n", .{});
                try e.print("try writer.writeAll(\"{s}: \");\n", .{field.name});
                try e.print("try text_format.write_enum_value(writer, v);\n", .{});
                try e.print("try writer.writeByte('\\n');\n", .{});
                try e.close_brace_comma();
            },
        }
    }
    try e.close_brace();
}

fn number_in_extension_ranges(number: i32, ranges: []const ast.ExtensionRange) bool {
    for (ranges) |range| {
        if (number >= range.start and number <= range.end) return true;
    }
    return false;
}

fn emit_text_group(e: *Emitter, grp: ast.Group, extension_full_name: ?[]const u8) !void {
    var name_buf: [256]u8 = undefined;
    const field_name = group_field_name(grp.name, &name_buf);
    const escaped = types.escape_zig_keyword(field_name);

    switch (grp.label) {
        .optional, .implicit => {
            try e.print("if (self.{f}) |grp|", .{escaped});
            try e.open_brace();
            try e.print("try text_format.write_indent(writer, indent);\n", .{});
            if (extension_full_name) |ext_name| {
                try e.print("try writer.writeAll(\"[{s}] {{\\n\");\n", .{ext_name});
            } else {
                try e.print("try writer.writeAll(\"{s} {{\\n\");\n", .{field_name});
            }
            try e.print("try grp.to_text_indent(writer, indent + 1);\n", .{});
            try e.print("try text_format.write_indent(writer, indent);\n", .{});
            try e.print("try writer.writeAll(\"}}\\n\");\n", .{});
            try e.close_brace_nosemi();
        },
        .required => {
            try e.print("{{\n", .{});
            e.indent_level += 1;
            try e.print("try text_format.write_indent(writer, indent);\n", .{});
            if (extension_full_name) |ext_name| {
                try e.print("try writer.writeAll(\"[{s}] {{\\n\");\n", .{ext_name});
            } else {
                try e.print("try writer.writeAll(\"{s} {{\\n\");\n", .{field_name});
            }
            try e.print("try self.{f}.to_text_indent(writer, indent + 1);\n", .{escaped});
            try e.print("try text_format.write_indent(writer, indent);\n", .{});
            try e.print("try writer.writeAll(\"}}\\n\");\n", .{});
            e.indent_level -= 1;
            try e.print("}}\n", .{});
        },
        .repeated => {
            try e.print("for (self.{f}) |item|", .{escaped});
            try e.open_brace();
            try e.print("try text_format.write_indent(writer, indent);\n", .{});
            if (extension_full_name) |ext_name| {
                try e.print("try writer.writeAll(\"[{s}] {{\\n\");\n", .{ext_name});
            } else {
                try e.print("try writer.writeAll(\"{s} {{\\n\");\n", .{field_name});
            }
            try e.print("try item.to_text_indent(writer, indent + 1);\n", .{});
            try e.print("try text_format.write_indent(writer, indent);\n", .{});
            try e.print("try writer.writeAll(\"}}\\n\");\n", .{});
            try e.close_brace_nosemi();
        },
    }
}

fn emit_group_to_text_method(e: *Emitter, group: ast.Group) !void {
    try e.print("/// Serialize this group to protobuf text format\n", .{});
    try e.print("pub fn to_text(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    try e.print("return self.to_text_indent(writer, 0);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    try e.print("pub fn to_text_indent(self: @This(), writer: *std.Io.Writer, indent: usize) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    if (group.fields.len > 0) {
        for (group.fields) |field| {
            try emit_text_field(e, field, .proto2);
        }
    } else {
        try e.print("_ = self;\n", .{});
        try e.print("_ = writer;\n", .{});
        try e.print("_ = indent;\n", .{});
    }
    try e.close_brace_nosemi();
}

// ── Text Format Deserialization Method ──────────────────────────────────

fn emit_from_text_method(e: *Emitter, msg: ast.Message, syntax: ast.Syntax, full_name: []const u8, recursive_types: *const RecursiveTypes) !void {
    _ = syntax;

    // from_text entry point
    try e.print("/// Deserialize from protobuf text format. Caller must call deinit when done\n", .{});
    try e.print("pub fn from_text(allocator: std.mem.Allocator, text: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("var scanner = text_format.TextScanner.init(allocator, text);\n", .{});
    try e.print("defer scanner.deinit();\n", .{});
    try e.print("return try @This().from_text_scanner(allocator, &scanner);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    // from_text_scanner public wrapper
    try e.print("pub fn from_text_scanner(allocator: std.mem.Allocator, scanner: *text_format.TextScanner) !@This()", .{});
    try e.open_brace();
    try e.print("return @This().from_text_scanner_inner(allocator, scanner, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    // from_text_scanner_inner with depth tracking
    // Use explicit error set for recursive types to break error set cycles
    if (recursive_types.contains(msg.name)) {
        try e.print("pub fn from_text_scanner_inner(allocator: std.mem.Allocator, scanner: *text_format.TextScanner, depth_remaining: usize) text_format.DecodeError!@This()", .{});
    } else {
        try e.print("pub fn from_text_scanner_inner(allocator: std.mem.Allocator, scanner: *text_format.TextScanner, depth_remaining: usize) !@This()", .{});
    }
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});

    // Collect all fields for the if/else if chain
    const items = try collect_all_fields(e.allocator, msg);
    defer e.allocator.free(items);

    if (items.len == 0) {
        if (!msg_fields_need_allocator(msg)) {
            try e.print("_ = allocator;\n", .{});
        }
        try e.print("const result: @This() = .{{}};\n", .{});
    } else {
        try e.print("var result: @This() = .{{}};\n", .{});
        try e.print("errdefer result.deinit(allocator);\n", .{});
    }

    // Loop over tokens
    try e.print("while (try scanner.peek()) |tok|", .{});
    try e.open_brace();
    try e.print("switch (tok)", .{});
    try e.open_brace();
    try e.print(".close_brace, .close_angle => return result,\n", .{});
    try e.print(".comma, .semicolon => {{\n", .{});
    e.indent_level += 1;
    try e.print("_ = try scanner.next();\n", .{});
    // Duplicate separators (,, or ;;) are parse errors
    try e.print("if (try scanner.peek()) |sep_next| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (sep_next == .comma or sep_next == .semicolon) return error.UnexpectedToken;\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    try e.print("continue;\n", .{});
    e.indent_level -= 1;
    try e.print("}},\n", .{});

    if (items.len == 0) {
        try e.print(".identifier => |_|", .{});
    } else {
        try e.print(".identifier => |field_name|", .{});
    }
    try e.open_brace();
    try e.print("_ = try scanner.next();\n", .{}); // consume the identifier
    try emit_from_text_dispatch(e, items, recursive_types, full_name, false);

    try e.close_brace_comma(); // .identifier => |field_name| { ... },
    try e.print(".open_bracket => {{\n", .{});
    e.indent_level += 1;
    try e.print("const ext_full_name = try text_format.read_bracketed_name(scanner);\n", .{});
    try e.print("const field_name = text_format.extension_name_tail(ext_full_name);\n", .{});
    if (items.len == 0) {
        try e.print("_ = field_name;\n", .{});
    }
    try emit_from_text_dispatch(e, items, recursive_types, full_name, true);
    e.indent_level -= 1;
    try e.print("}},\n", .{});
    try e.print("else => return error.UnexpectedToken,\n", .{});
    try e.close_brace_nosemi(); // switch
    try e.close_brace_nosemi(); // while
    try e.print("return result;\n", .{});
    try e.close_brace_nosemi(); // fn
}

fn emit_from_text_dispatch(e: *Emitter, items: []const FieldItem, recursive_types: *const RecursiveTypes, full_name: []const u8, is_extension_syntax: bool) !void {
    var first_branch = true;
    for (items) |item| {
        switch (item) {
            .field => |f| try emit_from_text_field_branch(e, f, &first_branch, recursive_types, full_name),
            .map => |m| try emit_from_text_map_branch(e, m, &first_branch),
            .oneof => |o| {
                for (o.fields) |f| {
                    try emit_from_text_oneof_field_branch(e, f, o, &first_branch);
                }
            },
            .group => |g| try emit_from_text_group_branch(e, g, &first_branch, !is_extension_syntax),
        }
    }

    // else: skip unknown field
    if (first_branch) {
        if (is_extension_syntax) {
            try e.print("return error.UnexpectedToken;\n", .{});
        } else {
            try e.print("try text_format.skip_field(scanner);\n", .{});
        }
    } else {
        if (is_extension_syntax) {
            try e.print(" else return error.UnexpectedToken;\n", .{});
        } else {
            try e.print(" else {{\n", .{});
            e.indent_level += 1;
            try e.print("try text_format.skip_field(scanner);\n", .{});
            e.indent_level -= 1;
            try e.print("}}\n", .{});
        }
    }
}

fn emit_from_text_field_branch(e: *Emitter, field: ast.Field, first_branch: *bool, recursive_types: *const RecursiveTypes, full_name: []const u8) !void {
    const escaped = types.escape_zig_keyword(field.name);

    if (first_branch.*) {
        try e.print("if (", .{});
        first_branch.* = false;
    } else {
        try e.print_raw(" else if (", .{});
    }
    try e.print_raw("std.mem.eql(u8, field_name, \"{s}\"))", .{field.name});
    try e.open_brace();

    switch (field.type_name) {
        .scalar => |s| {
            const read_fn = types.scalar_text_read_fn(s);
            switch (field.label) {
                .implicit, .optional, .required => {
                    try e.print("try scanner.expect_colon();\n", .{});
                    if (s == .string) {
                        try e.print("{{\n", .{});
                        e.indent_level += 1;
                        try e.print("const _sv = try text_format.{s}(scanner);\n", .{read_fn});
                        try e.print("try text_format.validate_utf8(_sv);\n", .{});
                        try emit_free_old_scalar(e, field.label, escaped, s);
                        try e.print("result.{f} = try allocator.dupe(u8, _sv);\n", .{escaped});
                        e.indent_level -= 1;
                        try e.print("}}\n", .{});
                    } else if (s == .bytes) {
                        try e.print("{{\n", .{});
                        e.indent_level += 1;
                        try e.print("const _bv = try text_format.{s}(scanner);\n", .{read_fn});
                        try emit_free_old_scalar(e, field.label, escaped, s);
                        try e.print("result.{f} = try allocator.dupe(u8, _bv);\n", .{escaped});
                        e.indent_level -= 1;
                        try e.print("}}\n", .{});
                    } else {
                        try e.print("result.{f} = try text_format.{s}(scanner);\n", .{ escaped, read_fn });
                    }
                },
                .repeated => {
                    try emit_from_text_repeated_scalar(e, escaped, s, read_fn);
                },
            }
        },
        .named => |name| {
            const is_recursive = recursive_types.contains(name);
            switch (field.label) {
                .implicit, .optional => {
                    // Text format allows optional colon before message blocks
                    try emit_text_consume_optional_colon(e);
                    try emit_text_expect_open_brace_or_angle(e);
                    if (std.mem.eql(u8, name, "google.protobuf.Any")) {
                        try emit_from_text_any_shorthand_field(e, escaped, full_name);
                    } else if (is_recursive) {
                        try e.print("{{\n", .{});
                        e.indent_level += 1;
                        try e.print("const val = try {s}.from_text_scanner_inner(allocator, scanner, depth_remaining - 1);\n", .{name});
                        try e.print("if (result.{f}) |old_ptr| {{ old_ptr.deinit(allocator); allocator.destroy(old_ptr); }}\n", .{escaped});
                        try e.print("const ptr = try allocator.create({s});\n", .{name});
                        try e.print("ptr.* = val;\n", .{});
                        try e.print("result.{f} = ptr;\n", .{escaped});
                        e.indent_level -= 1;
                        try e.print("}}\n", .{});
                    } else {
                        try e.print("{{\n", .{});
                        e.indent_level += 1;
                        try e.print("const val = try {s}.from_text_scanner_inner(allocator, scanner, depth_remaining - 1);\n", .{name});
                        try e.print("if (result.{f}) |*_old| _old.deinit(allocator);\n", .{escaped});
                        try e.print("result.{f} = val;\n", .{escaped});
                        e.indent_level -= 1;
                        try e.print("}}\n", .{});
                    }
                    try emit_text_expect_close_brace_or_angle(e);
                },
                .required => {
                    try emit_text_consume_optional_colon(e);
                    try emit_text_expect_open_brace_or_angle(e);
                    if (std.mem.eql(u8, name, "google.protobuf.Any")) {
                        try emit_from_text_any_shorthand_field(e, escaped, full_name);
                    } else {
                        try e.print("{{\n", .{});
                        e.indent_level += 1;
                        try e.print("const val = try {s}.from_text_scanner_inner(allocator, scanner, depth_remaining - 1);\n", .{name});
                        try e.print("result.{f}.deinit(allocator);\n", .{escaped});
                        try e.print("result.{f} = val;\n", .{escaped});
                        e.indent_level -= 1;
                        try e.print("}}\n", .{});
                    }
                    try emit_text_expect_close_brace_or_angle(e);
                },
                .repeated => {
                    try emit_from_text_repeated_named(e, escaped, name);
                },
            }
        },
        .enum_ref => {
            switch (field.label) {
                .optional => {
                    try e.print("try scanner.expect_colon();\n", .{});
                    try e.print("const enum_val = try text_format.read_enum_or_int(scanner);\n", .{});
                    try e.print("result.{f} = switch (enum_val) {{\n", .{escaped});
                    e.indent_level += 1;
                    try e.print(".name => |n| std.meta.stringToEnum(@TypeOf(result.{f}.?), n) orelse @enumFromInt(0),\n", .{escaped});
                    try e.print(".number => |num| std.meta.intToEnum(@TypeOf(result.{f}.?), num) catch return error.UnexpectedToken,\n", .{escaped});
                    e.indent_level -= 1;
                    try e.print("}};\n", .{});
                },
                .implicit, .required => {
                    try e.print("try scanner.expect_colon();\n", .{});
                    try e.print("const enum_val = try text_format.read_enum_or_int(scanner);\n", .{});
                    try e.print("result.{f} = switch (enum_val) {{\n", .{escaped});
                    e.indent_level += 1;
                    try e.print(".name => |n| std.meta.stringToEnum(@TypeOf(result.{f}), n) orelse @enumFromInt(0),\n", .{escaped});
                    try e.print(".number => |num| std.meta.intToEnum(@TypeOf(result.{f}), num) catch return error.UnexpectedToken,\n", .{escaped});
                    e.indent_level -= 1;
                    try e.print("}};\n", .{});
                },
                .repeated => {
                    try emit_from_text_repeated_enum(e, escaped);
                },
            }
        },
    }

    e.indent_level -= 1;
    try e.print("}}", .{});
}

fn emit_text_consume_optional_colon(e: *Emitter) !void {
    try e.print("if (try scanner.peek()) |maybe_colon| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (maybe_colon == .colon) {{ _ = try scanner.next(); }}\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
}

fn emit_from_text_any_shorthand_field(e: *Emitter, escaped: types.EscapedName, full_name: []const u8) !void {
    try e.print("if (try scanner.peek()) |any_tok| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (any_tok == .open_bracket) {{\n", .{});
    e.indent_level += 1;
    try e.print("const any_type_url = try text_format.read_bracketed_name(scanner);\n", .{});
    try e.print("if (!text_format.is_valid_any_type_url(any_type_url)) return error.UnexpectedToken;\n", .{});
    try e.print("const any_type_name = text_format.any_type_name(any_type_url) orelse return error.UnexpectedToken;\n", .{});
    try e.print("if (!std.mem.eql(u8, any_type_name, \"{s}\")) return error.UnexpectedToken;\n", .{full_name});
    try emit_text_expect_open_brace_or_angle(e);
    try e.print("var any_msg = try @This().from_text_scanner_inner(allocator, scanner, depth_remaining - 1);\n", .{});
    try e.print("defer any_msg.deinit(allocator);\n", .{});
    try emit_text_expect_close_brace_or_angle(e);
    try e.print("const any_size = any_msg.calc_size();\n", .{});
    try e.print("const any_buf = try allocator.alloc(u8, any_size);\n", .{});
    try e.print("errdefer allocator.free(any_buf);\n", .{});
    try e.print("var any_writer = std.Io.Writer.fixed(any_buf);\n", .{});
    try e.print("any_msg.encode(&any_writer) catch return error.OutOfMemory;\n", .{});
    try e.print("result.{f} = .{{ .type_url = try allocator.dupe(u8, any_type_url), .value = any_writer.buffered() }};\n", .{escaped});
    e.indent_level -= 1;
    try e.print("}} else {{\n", .{});
    e.indent_level += 1;
    try e.print("result.{f} = try google.protobuf.Any.from_text_scanner_inner(allocator, scanner, depth_remaining - 1);\n", .{escaped});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    e.indent_level -= 1;
    try e.print("}} else return error.UnexpectedEndOfInput;\n", .{});
}

fn emit_from_text_repeated_scalar(e: *Emitter, escaped: types.EscapedName, s: ast.ScalarType, read_fn: []const u8) !void {
    try e.print("try scanner.expect_colon();\n", .{});
    try e.print("{{\n", .{});
    e.indent_level += 1;
    try e.print("var list: std.ArrayListUnmanaged({s}) = .empty;\n", .{types.scalar_zig_type(s)});
    try emit_list_errdefer(e, s);
    try e.print("for (result.{f}) |existing| try list.append(allocator, existing);\n", .{escaped});
    try e.print("if (result.{f}.len > 0) allocator.free(result.{f});\n", .{ escaped, escaped });
    // Check for bracket list form: field: [val, val, ...]
    try e.print("const _brk = try scanner.peek();\n", .{});
    try e.print("if (_brk != null and _brk.? == .open_bracket) {{\n", .{});
    e.indent_level += 1;
    try e.print("_ = try scanner.next(); // consume [\n", .{});
    try e.print("while (true) {{\n", .{});
    e.indent_level += 1;
    try emit_text_repeated_scalar_append(e, s, read_fn);
    try e.print("const _sep = try scanner.peek() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (_sep == .close_bracket) {{ _ = try scanner.next(); break; }}\n", .{});
    try e.print("if (_sep != .comma) return error.UnexpectedToken;\n", .{});
    try e.print("_ = try scanner.next(); // consume comma\n", .{});
    try e.print("if ((try scanner.peek())) |_next| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (_next == .close_bracket) return error.UnexpectedToken; // no trailing comma\n", .{});
    e.indent_level -= 1;
    try e.print("}} else return error.UnexpectedEndOfInput;\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{}); // while
    e.indent_level -= 1;
    try e.print("}} else {{\n", .{});
    e.indent_level += 1;
    // Single value (no brackets)
    try emit_text_repeated_scalar_append(e, s, read_fn);
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    try e.print("result.{f} = try list.toOwnedSlice(allocator);\n", .{escaped});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
}

/// Generate code to read one repeated scalar value and append to `list`
fn emit_text_repeated_scalar_append(e: *Emitter, s: ast.ScalarType, read_fn: []const u8) !void {
    if (s == .string) {
        try e.print("{{\n", .{});
        e.indent_level += 1;
        try e.print("const _sv = try text_format.{s}(scanner);\n", .{read_fn});
        try e.print("try text_format.validate_utf8(_sv);\n", .{});
        try e.print("try list.append(allocator, try allocator.dupe(u8, _sv));\n", .{});
        e.indent_level -= 1;
        try e.print("}}\n", .{});
    } else if (s == .bytes) {
        try e.print("try list.append(allocator, try allocator.dupe(u8, try text_format.{s}(scanner)));\n", .{read_fn});
    } else {
        try e.print("try list.append(allocator, try text_format.{s}(scanner));\n", .{read_fn});
    }
}

fn emit_from_text_repeated_named(e: *Emitter, escaped: types.EscapedName, name: []const u8) !void {
    try emit_text_consume_optional_colon_static(e);
    try emit_text_expect_open_brace_or_angle(e);
    try e.print("{{\n", .{});
    e.indent_level += 1;
    try e.print("var list: std.ArrayListUnmanaged({s}) = .empty;\n", .{name});
    try emit_named_list_errdefer(e);
    try e.print("for (result.{f}) |existing| try list.append(allocator, existing);\n", .{escaped});
    try e.print("if (result.{f}.len > 0) allocator.free(result.{f});\n", .{ escaped, escaped });
    try e.print("try list.append(allocator, try {s}.from_text_scanner_inner(allocator, scanner, depth_remaining - 1));\n", .{name});
    try emit_text_expect_close_brace_or_angle(e);
    try e.print("result.{f} = try list.toOwnedSlice(allocator);\n", .{escaped});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
}

fn emit_from_text_repeated_enum(e: *Emitter, escaped: types.EscapedName) !void {
    try e.print("try scanner.expect_colon();\n", .{});
    try e.print("{{\n", .{});
    e.indent_level += 1;
    try e.print("var list: std.ArrayListUnmanaged(@TypeOf(result.{f}[0])) = .empty;\n", .{escaped});
    try e.print("errdefer list.deinit(allocator);\n", .{});
    try e.print("for (result.{f}) |existing| try list.append(allocator, existing);\n", .{escaped});
    try e.print("if (result.{f}.len > 0) allocator.free(result.{f});\n", .{ escaped, escaped });
    // Check for bracket list form
    try e.print("const _ebrk = try scanner.peek();\n", .{});
    try e.print("if (_ebrk != null and _ebrk.? == .open_bracket) {{\n", .{});
    e.indent_level += 1;
    try e.print("_ = try scanner.next(); // consume [\n", .{});
    try e.print("while (true) {{\n", .{});
    e.indent_level += 1;
    try emit_text_repeated_enum_append(e, escaped);
    try e.print("const _sep = try scanner.peek() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (_sep == .close_bracket) {{ _ = try scanner.next(); break; }}\n", .{});
    try e.print("if (_sep != .comma) return error.UnexpectedToken;\n", .{});
    try e.print("_ = try scanner.next(); // consume comma\n", .{});
    try e.print("if ((try scanner.peek())) |_next| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (_next == .close_bracket) return error.UnexpectedToken;\n", .{});
    e.indent_level -= 1;
    try e.print("}} else return error.UnexpectedEndOfInput;\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{}); // while
    e.indent_level -= 1;
    try e.print("}} else {{\n", .{});
    e.indent_level += 1;
    try emit_text_repeated_enum_append(e, escaped);
    e.indent_level -= 1;
    try e.print("}}\n", .{});
    try e.print("result.{f} = try list.toOwnedSlice(allocator);\n", .{escaped});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
}

fn emit_text_repeated_enum_append(e: *Emitter, escaped: types.EscapedName) !void {
    try e.print("const _ev = try text_format.read_enum_or_int(scanner);\n", .{});
    try e.print("try list.append(allocator, switch (_ev) {{\n", .{});
    e.indent_level += 1;
    try e.print(".name => |n| std.meta.stringToEnum(@TypeOf(result.{f}[0]), n) orelse @enumFromInt(0),\n", .{escaped});
    try e.print(".number => |num| std.meta.intToEnum(@TypeOf(result.{f}[0]), num) catch return error.UnexpectedToken,\n", .{escaped});
    e.indent_level -= 1;
    try e.print("}});\n", .{});
}

fn emit_text_consume_optional_colon_static(e: *Emitter) !void {
    try e.print("if (try scanner.peek()) |maybe_colon| {{\n", .{});
    e.indent_level += 1;
    try e.print("if (maybe_colon == .colon) {{ _ = try scanner.next(); }}\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
}

fn emit_text_expect_open_brace_or_angle(e: *Emitter) !void {
    try e.print("{{\n", .{});
    e.indent_level += 1;
    try e.print("const brace_tok = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (brace_tok != .open_brace and brace_tok != .open_angle) return error.UnexpectedToken;\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
}

fn emit_text_expect_close_brace_or_angle(e: *Emitter) !void {
    try e.print("{{\n", .{});
    e.indent_level += 1;
    try e.print("const close_tok = try scanner.next() orelse return error.UnexpectedEndOfInput;\n", .{});
    try e.print("if (close_tok != .close_brace and close_tok != .close_angle) return error.UnexpectedToken;\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});
}

fn emit_text_map_errdefer(e: *Emitter, key_type: ast.ScalarType, value_type: ast.TypeRef) !void {
    if (types.is_string_key(key_type)) {
        try e.print("errdefer {{ if (map_key) |k| allocator.free(k); }}\n", .{});
    }
    switch (value_type) {
        .scalar => |s| {
            if (s == .string or s == .bytes) {
                try e.print("errdefer {{ if (map_val) |v| {{ if (v.len > 0) allocator.free(v); }} }}\n", .{});
            }
        },
        .named => {
            try e.print("errdefer {{ if (map_val) |*v| v.deinit(allocator); }}\n", .{});
        },
        .enum_ref => {},
    }
}

fn emit_from_text_map_branch(e: *Emitter, map_field: ast.MapField, first_branch: *bool) !void {
    const escaped = types.escape_zig_keyword(map_field.name);

    if (first_branch.*) {
        try e.print("if (", .{});
        first_branch.* = false;
    } else {
        try e.print_raw(" else if (", .{});
    }
    try e.print_raw("std.mem.eql(u8, field_name, \"{s}\"))", .{map_field.name});
    try e.open_brace();

    // Expect open brace or angle bracket for the map entry
    try emit_text_consume_optional_colon_static(e);
    try emit_text_expect_open_brace_or_angle(e);

    // Initialize key/value as optionals
    const key_zig_type = types.scalar_zig_type(map_field.key_type);
    try e.print("var map_key: ?{s} = null;\n", .{key_zig_type});

    const value_zig_type = switch (map_field.value_type) {
        .scalar => |s| types.scalar_zig_type(s),
        .named => |n| n,
        .enum_ref => |n| n,
    };
    try e.print("var map_val: ?{s} = null;\n", .{value_zig_type});
    try emit_text_map_errdefer(e, map_field.key_type, map_field.value_type);

    // Loop inside map entry
    try e.print("while (try scanner.peek()) |entry_tok|", .{});
    try e.open_brace();
    try e.print("switch (entry_tok)", .{});
    try e.open_brace();
    try e.print(".close_brace, .close_angle => {{ _ = try scanner.next(); break; }},\n", .{});
    try e.print(".comma, .semicolon => {{ _ = try scanner.next(); continue; }},\n", .{});
    try e.print(".identifier => |entry_name|", .{});
    try e.open_brace();
    try e.print("_ = try scanner.next();\n", .{});

    // key branch
    try e.print("if (std.mem.eql(u8, entry_name, \"key\"))", .{});
    try e.open_brace();
    try e.print("try scanner.expect_colon();\n", .{});
    if (types.is_string_key(map_field.key_type)) {
        try e.print("map_key = try allocator.dupe(u8, try text_format.read_string(scanner));\n", .{});
    } else if (map_field.key_type == .bool) {
        try e.print("map_key = try text_format.read_bool(scanner);\n", .{});
    } else {
        const read_fn = types.scalar_text_read_fn(map_field.key_type);
        try e.print("map_key = try text_format.{s}(scanner);\n", .{read_fn});
    }
    e.indent_level -= 1;
    try e.print("}}", .{});

    // value branch
    try e.print_raw(" else if (std.mem.eql(u8, entry_name, \"value\"))", .{});
    try e.open_brace();
    switch (map_field.value_type) {
        .scalar => |s| {
            const read_fn = types.scalar_text_read_fn(s);
            try e.print("try scanner.expect_colon();\n", .{});
            if (s == .string or s == .bytes) {
                try e.print("map_val = try allocator.dupe(u8, try text_format.{s}(scanner));\n", .{read_fn});
            } else {
                try e.print("map_val = try text_format.{s}(scanner);\n", .{read_fn});
            }
        },
        .named => |name| {
            try emit_text_consume_optional_colon_static(e);
            try emit_text_expect_open_brace_or_angle(e);
            try e.print("map_val = try {s}.from_text_scanner_inner(allocator, scanner, depth_remaining - 1);\n", .{name});
            try emit_text_expect_close_brace_or_angle(e);
        },
        .enum_ref => {
            try e.print("try scanner.expect_colon();\n", .{});
            try e.print("const enum_val = try text_format.read_enum_or_int(scanner);\n", .{});
            try e.print("map_val = switch (enum_val) {{\n", .{});
            e.indent_level += 1;
            try e.print(".name => |n| std.meta.stringToEnum({s}, n) orelse @enumFromInt(0),\n", .{value_zig_type});
            try e.print(".number => |num| std.meta.intToEnum({s}, num) catch return error.UnexpectedToken,\n", .{value_zig_type});
            e.indent_level -= 1;
            try e.print("}};\n", .{});
        },
    }
    e.indent_level -= 1;
    try e.print("}}", .{});

    // else: skip unknown entry field
    try e.print_raw(" else {{\n", .{});
    e.indent_level += 1;
    try e.print("try text_format.skip_field(scanner);\n", .{});
    e.indent_level -= 1;
    try e.print("}}\n", .{});

    try e.close_brace_comma(); // .identifier
    try e.print("else => return error.UnexpectedToken,\n", .{});
    try e.close_brace_nosemi(); // switch
    try e.close_brace_nosemi(); // while

    // Put key/value into map, freeing old entries on duplicate keys
    try e.print("if (map_key) |k|", .{});
    try e.open_brace();
    switch (map_field.value_type) {
        .scalar => |s| try e.print("const v = map_val orelse {s};\n", .{types.scalar_default_value(s)}),
        .named => |nname| try e.print("const v: {s} = map_val orelse .{{}};\n", .{nname}),
        .enum_ref => |ename| try e.print("const v: {s} = map_val orelse @enumFromInt(0);\n", .{ename}),
    }
    try emit_map_put_with_free(e, escaped, map_field.key_type, map_field.value_type, "k", "v");
    try e.close_brace_nosemi();
    try e.print("\n", .{});

    e.indent_level -= 1;
    try e.print("}}", .{});
}

fn emit_from_text_group_branch(e: *Emitter, grp: ast.Group, first_branch: *bool, allow_group_type_name: bool) !void {
    var name_buf: [256]u8 = undefined;
    const field_name = group_field_name(grp.name, &name_buf);
    const escaped = types.escape_zig_keyword(field_name);

    if (first_branch.*) {
        try e.print("if (", .{});
        first_branch.* = false;
    } else {
        try e.print_raw(" else if (", .{});
    }
    // Match lowercase field name; for regular group field syntax also accept type name.
    try e.print_raw("std.mem.eql(u8, field_name, \"{s}\")", .{field_name});
    if (allow_group_type_name and !std.mem.eql(u8, field_name, grp.name)) {
        try e.print_raw(" or std.mem.eql(u8, field_name, \"{s}\")", .{grp.name});
    }
    try e.print_raw(")", .{});
    try e.open_brace();

    switch (grp.label) {
        .optional, .implicit, .required => {
            try emit_text_consume_optional_colon_static(e);
            try emit_text_expect_open_brace_or_angle(e);
            try e.print("result.{f} = try {s}.from_text_scanner_inner(allocator, scanner, depth_remaining - 1);\n", .{ escaped, grp.name });
            try emit_text_expect_close_brace_or_angle(e);
        },
        .repeated => {
            try emit_text_consume_optional_colon_static(e);
            try emit_text_expect_open_brace_or_angle(e);
            try e.print("{{\n", .{});
            e.indent_level += 1;
            try e.print("var list: std.ArrayListUnmanaged({s}) = .empty;\n", .{grp.name});
            try e.print("for (result.{f}) |existing| try list.append(allocator, existing);\n", .{escaped});
            try e.print("if (result.{f}.len > 0) allocator.free(result.{f});\n", .{ escaped, escaped });
            try e.print("try list.append(allocator, try {s}.from_text_scanner_inner(allocator, scanner, depth_remaining - 1));\n", .{grp.name});
            try emit_text_expect_close_brace_or_angle(e);
            try e.print("result.{f} = try list.toOwnedSlice(allocator);\n", .{escaped});
            e.indent_level -= 1;
            try e.print("}}\n", .{});
        },
    }

    e.indent_level -= 1;
    try e.print("}}", .{});
}

fn emit_from_text_oneof_field_branch(e: *Emitter, field: ast.Field, oneof: ast.Oneof, first_branch: *bool) !void {
    const field_escaped = types.escape_zig_keyword(field.name);
    const oneof_escaped = types.escape_zig_keyword(oneof.name);

    if (first_branch.*) {
        try e.print("if (", .{});
        first_branch.* = false;
    } else {
        try e.print_raw(" else if (", .{});
    }
    try e.print_raw("std.mem.eql(u8, field_name, \"{s}\"))", .{field.name});
    try e.open_brace();

    switch (field.type_name) {
        .scalar => |s| {
            const read_fn = types.scalar_text_read_fn(s);
            try e.print("try scanner.expect_colon();\n", .{});
            if (s == .string or s == .bytes) {
                try e.print("result.{f} = .{{ .{f} = try allocator.dupe(u8, try text_format.{s}(scanner)) }};\n", .{ oneof_escaped, field_escaped, read_fn });
            } else {
                try e.print("result.{f} = .{{ .{f} = try text_format.{s}(scanner) }};\n", .{ oneof_escaped, field_escaped, read_fn });
            }
        },
        .named => |name| {
            try emit_text_consume_optional_colon_static(e);
            try emit_text_expect_open_brace_or_angle(e);
            try e.print("result.{f} = .{{ .{f} = try {s}.from_text_scanner_inner(allocator, scanner, depth_remaining - 1) }};\n", .{ oneof_escaped, field_escaped, name });
            try emit_text_expect_close_brace_or_angle(e);
        },
        .enum_ref => {
            try e.print("try scanner.expect_colon();\n", .{});
            try e.print("const enum_val = try text_format.read_enum_or_int(scanner);\n", .{});
            try e.print("result.{f} = .{{ .{f} = switch (enum_val) {{\n", .{ oneof_escaped, field_escaped });
            e.indent_level += 1;
            try e.print(".name => |n| std.meta.stringToEnum(@TypeOf(result.{f}.?.{f}), n) orelse @enumFromInt(0),\n", .{ oneof_escaped, field_escaped });
            try e.print(".number => |num| std.meta.intToEnum(@TypeOf(result.{f}.?.{f}), num) catch return error.UnexpectedToken,\n", .{ oneof_escaped, field_escaped });
            e.indent_level -= 1;
            try e.print("}} }};\n", .{});
        },
    }

    e.indent_level -= 1;
    try e.print("}}", .{});
}

fn emit_group_from_text_method(e: *Emitter, group: ast.Group, recursive_types: *const RecursiveTypes) !void {
    // from_text entry point
    try e.print("/// Deserialize this group from protobuf text format\n", .{});
    try e.print("pub fn from_text(allocator: std.mem.Allocator, text: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("var scanner = text_format.TextScanner.init(allocator, text);\n", .{});
    try e.print("defer scanner.deinit();\n", .{});
    try e.print("return try @This().from_text_scanner(allocator, &scanner);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    // from_text_scanner public wrapper
    try e.print("pub fn from_text_scanner(allocator: std.mem.Allocator, scanner: *text_format.TextScanner) !@This()", .{});
    try e.open_brace();
    try e.print("return @This().from_text_scanner_inner(allocator, scanner, message.default_max_decode_depth);\n", .{});
    try e.close_brace_nosemi();

    try e.blank_line();

    // from_text_scanner_inner with depth tracking
    try e.print("pub fn from_text_scanner_inner(allocator: std.mem.Allocator, scanner: *text_format.TextScanner, depth_remaining: usize) !@This()", .{});
    try e.open_brace();
    try e.print("if (depth_remaining == 0) return error.RecursionLimitExceeded;\n", .{});

    if (group.fields.len == 0) {
        if (!group_fields_need_allocator(group)) {
            try e.print("_ = allocator;\n", .{});
        }
        try e.print("const result: @This() = .{{}};\n", .{});
    } else {
        try e.print("var result: @This() = .{{}};\n", .{});
        try e.print("errdefer result.deinit(allocator);\n", .{});
    }
    try e.print("while (try scanner.peek()) |tok|", .{});
    try e.open_brace();
    try e.print("switch (tok)", .{});
    try e.open_brace();
    try e.print(".close_brace, .close_angle => return result,\n", .{});
    try e.print(".comma, .semicolon => {{ _ = try scanner.next(); continue; }},\n", .{});

    if (group.fields.len == 0) {
        try e.print(".identifier => |_|", .{});
    } else {
        try e.print(".identifier => |field_name|", .{});
    }
    try e.open_brace();
    try e.print("_ = try scanner.next();\n", .{});

    // Field matching
    var first_branch = true;
    for (group.fields) |field| {
        try emit_from_text_field_branch(e, field, &first_branch, recursive_types, "");
    }

    // else: skip unknown
    if (first_branch) {
        try e.print("try text_format.skip_field(scanner);\n", .{});
    } else {
        try e.print(" else {{\n", .{});
        e.indent_level += 1;
        try e.print("try text_format.skip_field(scanner);\n", .{});
        e.indent_level -= 1;
        try e.print("}}\n", .{});
    }

    try e.close_brace_comma(); // .identifier
    try e.print("else => return error.UnexpectedToken,\n", .{});
    try e.close_brace_nosemi(); // switch
    try e.close_brace_nosemi(); // while
    try e.print("return result;\n", .{});
    try e.close_brace_nosemi(); // fn
}

/// Check if any field in a message requires the allocator during decode/parse.
/// Returns true if any field is string, bytes, message, repeated, map, group,
/// or a oneof containing such types.
fn msg_fields_need_allocator(msg: ast.Message) bool {
    return fields_need_allocator(msg.fields) or msg.maps.len > 0 or msg.groups.len > 0 or
        oneofs_need_allocator(msg.oneofs);
}

fn group_fields_need_allocator(group: ast.Group) bool {
    return fields_need_allocator(group.fields);
}

fn fields_need_allocator(fields: []const ast.Field) bool {
    for (fields) |f| {
        if (f.label == .repeated) return true;
        switch (f.type_name) {
            .scalar => |s| if (s == .string or s == .bytes) return true,
            .named => return true,
            .enum_ref => {},
        }
    }
    return false;
}

fn oneofs_need_allocator(oneofs: []const ast.Oneof) bool {
    for (oneofs) |o| {
        if (fields_need_allocator(o.fields)) return true;
    }
    return false;
}

// ── Field Collection Helper ───────────────────────────────────────────

const FieldItem = union(enum) {
    field: ast.Field,
    map: ast.MapField,
    oneof: ast.Oneof,
    group: ast.Group,
};

fn collect_all_fields(allocator: std.mem.Allocator, msg: ast.Message) ![]FieldItem {
    const total = msg.fields.len + msg.maps.len + msg.oneofs.len + msg.groups.len;
    var items = try allocator.alloc(FieldItem, total);
    var idx: usize = 0;
    for (msg.fields) |f| {
        items[idx] = .{ .field = f };
        idx += 1;
    }
    for (msg.maps) |m| {
        items[idx] = .{ .map = m };
        idx += 1;
    }
    for (msg.oneofs) |o| {
        items[idx] = .{ .oneof = o };
        idx += 1;
    }
    for (msg.groups) |g| {
        items[idx] = .{ .group = g };
        idx += 1;
    }
    // Sort by field number
    std.mem.sort(FieldItem, items, {}, struct {
        fn lessThan(_: void, a: FieldItem, b: FieldItem) bool {
            return field_item_number(a) < field_item_number(b);
        }
    }.lessThan);
    return items;
}

fn field_item_number(item: FieldItem) i32 {
    return switch (item) {
        .field => |f| f.number,
        .map => |m| m.number,
        .oneof => |o| if (o.fields.len > 0) o.fields[0].number else 0,
        .group => |g| g.number,
    };
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

const loc = ast.SourceLocation{ .file = "", .line = 0, .column = 0 };
const empty_recursive: RecursiveTypes = RecursiveTypes.init(testing.allocator);

fn make_field(name: []const u8, number: i32, label: ast.FieldLabel, type_name: ast.TypeRef) ast.Field {
    return .{
        .name = name,
        .number = number,
        .label = label,
        .type_name = type_name,
        .options = &.{},
        .location = loc,
    };
}

fn make_msg(name: []const u8) ast.Message {
    return .{
        .name = name,
        .fields = &.{},
        .oneofs = &.{},
        .nested_messages = &.{},
        .nested_enums = &.{},
        .maps = &.{},
        .reserved_ranges = &.{},
        .reserved_names = &.{},
        .extension_ranges = &.{},
        .extensions = &.{},
        .groups = &.{},
        .options = &.{},
        .location = loc,
    };
}

fn expect_output_contains(output: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, output, expected) == null) {
        std.debug.print("\n=== EXPECTED (not found) ===\n{s}\n=== IN OUTPUT ===\n{s}\n=== END ===\n", .{ expected, output });
        return error.TestExpectedEqual;
    }
}

test "emit_message: proto3 implicit scalar fields" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("name", 1, .implicit, .{ .scalar = .string }),
        make_field("id", 2, .implicit, .{ .scalar = .int32 }),
        make_field("active", 3, .implicit, .{ .scalar = .bool }),
    };

    var msg = make_msg("Person");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "pub const Person = struct {");
    try expect_output_contains(output, "    name: []const u8 = \"\",");
    try expect_output_contains(output, "    id: i32 = 0,");
    try expect_output_contains(output, "    active: bool = false,");
    try expect_output_contains(output, "    _unknown_fields: []const u8 = \"\",");
}

test "emit_message: proto3 optional field" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("name", 1, .implicit, .{ .scalar = .string }),
        make_field("email", 2, .optional, .{ .scalar = .string }),
    };

    var msg = make_msg("User");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "    email: ?[]const u8 = null,");
}

test "emit_message: proto2 required/optional fields" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("name", 1, .required, .{ .scalar = .string }),
        make_field("email", 2, .optional, .{ .scalar = .string }),
    };

    var msg = make_msg("LegacyUser");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto2, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "    name: []const u8 = \"\",");
    try expect_output_contains(output, "    email: ?[]const u8 = null,");
}

test "emit_message: oneof field" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var oneof_fields = [_]ast.Field{
        make_field("text", 1, .implicit, .{ .scalar = .string }),
        make_field("count", 2, .implicit, .{ .scalar = .int32 }),
    };
    var oneofs = [_]ast.Oneof{.{
        .name = "value",
        .fields = &oneof_fields,
        .options = &.{},
        .location = loc,
    }};

    var msg = make_msg("Sample");
    msg.oneofs = &oneofs;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "pub const Value = union(enum)");
    try expect_output_contains(output, "        text: []const u8,");
    try expect_output_contains(output, "        count: i32,");
    try expect_output_contains(output, "    value: ?@This().Value = null,");
}

test "emit_message: map fields" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var maps = [_]ast.MapField{
        .{
            .name = "labels",
            .number = 1,
            .key_type = .string,
            .value_type = .{ .scalar = .string },
            .options = &.{},
            .location = loc,
        },
        .{
            .name = "scores",
            .number = 2,
            .key_type = .int32,
            .value_type = .{ .scalar = .float },
            .options = &.{},
            .location = loc,
        },
    };

    var msg = make_msg("Container");
    msg.maps = &maps;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "    labels: std.StringArrayHashMapUnmanaged([]const u8) = .empty,");
    try expect_output_contains(output, "    scores: std.AutoArrayHashMapUnmanaged(i32, f32) = .empty,");
}

test "emit_message: nested message and enum" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var enum_values = [_]ast.EnumValue{
        .{ .name = "A", .number = 0, .options = &.{}, .location = loc },
        .{ .name = "B", .number = 1, .options = &.{}, .location = loc },
    };
    var nested_enums = [_]ast.Enum{.{
        .name = "Kind",
        .values = &enum_values,
        .options = &.{},
        .allow_alias = false,
        .reserved_ranges = &.{},
        .reserved_names = &.{},
        .location = loc,
    }};

    var inner_fields = [_]ast.Field{
        make_field("x", 1, .implicit, .{ .scalar = .int32 }),
    };
    var nested_msgs = [_]ast.Message{blk: {
        var m = make_msg("Inner");
        m.fields = &inner_fields;
        break :blk m;
    }};

    var msg = make_msg("Outer");
    msg.nested_enums = &nested_enums;
    msg.nested_messages = &nested_msgs;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "pub const Kind = enum(i32)");
    try expect_output_contains(output, "pub const Inner = struct {");
}

test "emit_message: field with Zig keyword name" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("type", 1, .implicit, .{ .scalar = .int32 }),
        make_field("error", 2, .optional, .{ .scalar = .string }),
    };

    var msg = make_msg("KeywordTest");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "    @\"type\": i32 = 0,");
    try expect_output_contains(output, "    @\"error\": ?[]const u8 = null,");
}

test "emit_message: repeated fields" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("ids", 1, .repeated, .{ .scalar = .int32 }),
        make_field("names", 2, .repeated, .{ .scalar = .string }),
        make_field("items", 3, .repeated, .{ .named = "Item" }),
    };

    var msg = make_msg("Collection");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "    ids: []const i32 = &.{},");
    try expect_output_contains(output, "    names: []const []const u8 = &.{},");
    try expect_output_contains(output, "    items: []const Item = &.{},");
}

test "emit_message: encode method for simple scalar message" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("name", 1, .implicit, .{ .scalar = .string }),
        make_field("id", 2, .implicit, .{ .scalar = .int32 }),
    };

    var msg = make_msg("Simple");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "pub fn encode(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {");
    try expect_output_contains(output, "const mw = message.MessageWriter.init(writer);");
    try expect_output_contains(output, "if (self.name.len > 0) try mw.write_len_field(1, self.name);");
    try expect_output_contains(output, "if (self.id != 0) try mw.write_varint_field(2,");
}

test "emit_message: calc_size method" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("name", 1, .implicit, .{ .scalar = .string }),
        make_field("id", 2, .implicit, .{ .scalar = .int32 }),
    };

    var msg = make_msg("Simple");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "pub fn calc_size(self: @This()) usize {");
    try expect_output_contains(output, "var size: usize = 0;");
    try expect_output_contains(output, "if (self.name.len > 0) size += message.len_field_size(1, self.name.len);");
    try expect_output_contains(output, "size += self._unknown_fields.len;");
    try expect_output_contains(output, "return size;");
}

test "emit_message: decode method" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("name", 1, .implicit, .{ .scalar = .string }),
        make_field("id", 2, .implicit, .{ .scalar = .int32 }),
    };

    var msg = make_msg("Simple");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {");
    try expect_output_contains(output, "return @This().decode_inner(allocator, bytes, message.default_max_decode_depth);");
    try expect_output_contains(output, "pub fn decode_inner(allocator: std.mem.Allocator, bytes: []const u8, depth_remaining: usize) !@This() {");
    try expect_output_contains(output, "if (depth_remaining == 0) return error.RecursionLimitExceeded;");
    try expect_output_contains(output, "var result: @This() = .{};");
    try expect_output_contains(output, "var iter = message.iterate_fields(bytes);");
    try expect_output_contains(output, "switch (field.number) {");
    // Proto3 string field generates UTF-8 validation
    try expect_output_contains(output, "try message.validate_utf8(field.value.len);");
    try expect_output_contains(output, "result.name = try allocator.dupe(u8, field.value.len);");
}

test "emit_message: deinit method" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("name", 1, .implicit, .{ .scalar = .string }),
        make_field("id", 2, .implicit, .{ .scalar = .int32 }),
        make_field("items", 3, .repeated, .{ .scalar = .string }),
    };

    var msg = make_msg("WithDeinit");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {");
    try expect_output_contains(output, "if (self.name.len > 0) allocator.free(self.name);");
    try expect_output_contains(output, "for (self.items) |item| allocator.free(item);");
    try expect_output_contains(output, "if (self._unknown_fields.len > 0) allocator.free(self._unknown_fields);");
}

test "emit_message: oneof encode/decode/deinit" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var oneof_fields = [_]ast.Field{
        make_field("text", 1, .implicit, .{ .scalar = .string }),
        make_field("count", 2, .implicit, .{ .scalar = .int32 }),
    };
    var oneofs = [_]ast.Oneof{.{
        .name = "payload",
        .fields = &oneof_fields,
        .options = &.{},
        .location = loc,
    }};

    var msg = make_msg("OneofMsg");
    msg.oneofs = &oneofs;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    // Encode: switch on oneof variants
    try expect_output_contains(output, "if (self.payload) |oneof_val| switch (oneof_val)");
    try expect_output_contains(output, ".text => |v| try mw.write_len_field(1, v),");
    // Decode: oneof field assignments (proto3 string gets UTF-8 validation)
    try expect_output_contains(output, "try message.validate_utf8(field.value.len);");
    try expect_output_contains(output, "result.payload = .{ .text = try allocator.dupe(u8, field.value.len) };");
    // Deinit: switch
    try expect_output_contains(output, "if (self.payload) |*oneof_val| switch (oneof_val.*)");
    try expect_output_contains(output, ".text => |v| allocator.free(v),");
}

// ── to_json tests ─────────────────────────────────────────────────────

test "emit_message: to_json method signature" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("name", 1, .implicit, .{ .scalar = .string }),
        make_field("id", 2, .implicit, .{ .scalar = .int32 }),
    };

    var msg = make_msg("Simple");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "pub fn to_json(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {");
    try expect_output_contains(output, "try json.write_object_start(writer);");
    try expect_output_contains(output, "var first = true;");
    try expect_output_contains(output, "try json.write_object_end(writer);");
}

test "emit_message: to_json snake_case to camelCase" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("my_field_name", 1, .implicit, .{ .scalar = .string }),
    };

    var msg = make_msg("CamelTest");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    // JSON name should be camelCase
    try expect_output_contains(output, "try json.write_field_name(writer, \"myFieldName\");");
}

test "emit_message: to_json int64 uses write_int_string" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("big_int", 1, .implicit, .{ .scalar = .int64 }),
        make_field("big_uint", 2, .implicit, .{ .scalar = .uint64 }),
    };

    var msg = make_msg("Int64Test");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    // int64 -> write_int_string (as JSON string)
    try expect_output_contains(output, "try json.write_int_string(writer,");
    // uint64 -> write_uint_string (as JSON string)
    try expect_output_contains(output, "try json.write_uint_string(writer,");
}

test "emit_message: to_json scalar types use correct write functions" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("d", 1, .implicit, .{ .scalar = .double }),
        make_field("b", 2, .implicit, .{ .scalar = .bool }),
        make_field("s", 3, .implicit, .{ .scalar = .string }),
        make_field("raw", 4, .implicit, .{ .scalar = .bytes }),
    };

    var msg = make_msg("ScalarJson");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "try json.write_float(writer, self.d);");
    try expect_output_contains(output, "try json.write_bool(writer, self.b);");
    try expect_output_contains(output, "try json.write_string(writer, self.s);");
    try expect_output_contains(output, "try json.write_bytes(writer, self.raw);");
}

test "emit_message: to_json optional field null check" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("opt", 1, .optional, .{ .scalar = .int32 }),
    };

    var msg = make_msg("OptTest");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "if (self.opt) |v| {");
    try expect_output_contains(output, "try json.write_field_name(writer, \"opt\");");
}

test "emit_message: to_json repeated field array pattern" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("tags", 1, .repeated, .{ .scalar = .string }),
    };

    var msg = make_msg("RepTest");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "if (self.tags.len > 0) {");
    try expect_output_contains(output, "try json.write_array_start(writer);");
    try expect_output_contains(output, "try json.write_string(writer, item);");
    try expect_output_contains(output, "try json.write_array_end(writer);");
}

test "emit_message: to_json nested message" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var fields = [_]ast.Field{
        make_field("sub", 1, .implicit, .{ .named = "SubMsg" }),
    };

    var msg = make_msg("NestedJson");
    msg.fields = &fields;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "if (self.sub) |sub| {");
    try expect_output_contains(output, "try sub.to_json(writer);");
}

test "emit_message: to_json map field" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var maps = [_]ast.MapField{.{
        .name = "labels",
        .number = 1,
        .key_type = .string,
        .value_type = .{ .scalar = .string },
        .options = &.{},
        .location = loc,
    }};

    var msg = make_msg("MapJson");
    msg.maps = &maps;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    try expect_output_contains(output, "if (self.labels.count() > 0) {");
    try expect_output_contains(output, "try json.write_object_start(writer);");
    try expect_output_contains(output, "try json.write_field_name(writer, key);");
    try expect_output_contains(output, "try json.write_object_end(writer);");
}

test "emit_message: to_json oneof field" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var oneof_fields = [_]ast.Field{
        make_field("text", 1, .implicit, .{ .scalar = .string }),
        make_field("sub_msg", 2, .implicit, .{ .named = "SubMsg" }),
    };
    var oneofs = [_]ast.Oneof{.{
        .name = "kind",
        .fields = &oneof_fields,
        .options = &.{},
        .location = loc,
    }};

    var msg = make_msg("OneofJson");
    msg.oneofs = &oneofs;

    try emit_message(&e, msg, .proto3, "Test", &empty_recursive);
    const output = e.get_output();
    // The to_json should switch on oneof
    try expect_output_contains(output, "if (self.kind) |oneof_val| switch (oneof_val) {");
    try expect_output_contains(output, ".text => |v| {");
    try expect_output_contains(output, "try json.write_string(writer, v);");
    try expect_output_contains(output, ".sub_msg => |sub| {");
    try expect_output_contains(output, "try sub.to_json(writer);");
}
