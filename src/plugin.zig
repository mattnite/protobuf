const std = @import("std");
const testing = std.testing;
const message = @import("message.zig");
const encoding = @import("encoding.zig");
const ast = @import("proto/ast.zig");
const codegen = @import("codegen.zig");

// ── Helpers ──────────────────────────────────────────────────────────

fn varint_as_i32(v: u64) i32 {
    return @bitCast(@as(u32, @truncate(v)));
}

fn varint_as_bool(v: u64) bool {
    return v != 0;
}

// ── Intermediate Descriptor Structs ──────────────────────────────────

const ExtensionRange = struct {
    start: i32 = 0,
    end: i32 = 0,
};

const ReservedRange = struct {
    start: i32 = 0,
    end: i32 = 0,
};

const EnumReservedRange = struct {
    start: i32 = 0,
    end: i32 = 0,
};

const MessageOptions = struct {
    map_entry: bool = false,
};

const EnumOptions = struct {
    allow_alias: bool = false,
};

const FieldOptions = struct {
    @"packed": ?bool = null,
};

const EnumValueDescriptorProto = struct {
    name: []const u8 = "",
    number: i32 = 0,
};

const EnumDescriptorProto = struct {
    name: []const u8 = "",
    value: []const EnumValueDescriptorProto = &.{},
    options: ?EnumOptions = null,
    reserved_range: []const EnumReservedRange = &.{},
    reserved_name: []const []const u8 = &.{},
};

const OneofDescriptorProto = struct {
    name: []const u8 = "",
};

const MethodDescriptorProto = struct {
    name: []const u8 = "",
    input_type: []const u8 = "",
    output_type: []const u8 = "",
    client_streaming: bool = false,
    server_streaming: bool = false,
};

const ServiceDescriptorProto = struct {
    name: []const u8 = "",
    method: []const MethodDescriptorProto = &.{},
};

const FieldDescriptorProto = struct {
    name: []const u8 = "",
    number: i32 = 0,
    label: i32 = 0, // 1=OPTIONAL, 2=REQUIRED, 3=REPEATED
    @"type": i32 = 0, // 1=DOUBLE..18=SINT64
    type_name: []const u8 = "",
    default_value: []const u8 = "",
    oneof_index: i32 = -1, // -1 means not in a oneof
    json_name: []const u8 = "",
    options: ?FieldOptions = null,
};

const DescriptorProto = struct {
    name: []const u8 = "",
    field: []const FieldDescriptorProto = &.{},
    nested_type: []const DescriptorProto = &.{},
    enum_type: []const EnumDescriptorProto = &.{},
    extension_range: []const ExtensionRange = &.{},
    extension: []const FieldDescriptorProto = &.{},
    oneof_decl: []const OneofDescriptorProto = &.{},
    reserved_range: []const ReservedRange = &.{},
    reserved_name: []const []const u8 = &.{},
    options: ?MessageOptions = null,
};

const FileDescriptorProto = struct {
    name: []const u8 = "",
    package: []const u8 = "",
    dependency: []const []const u8 = &.{},
    message_type: []const DescriptorProto = &.{},
    enum_type: []const EnumDescriptorProto = &.{},
    service: []const ServiceDescriptorProto = &.{},
    extension: []const FieldDescriptorProto = &.{},
    syntax: []const u8 = "",
};

const CodeGeneratorRequest = struct {
    file_to_generate: []const []const u8 = &.{},
    parameter: []const u8 = "",
    proto_file: []const FileDescriptorProto = &.{},
};

// ── Decode Functions ─────────────────────────────────────────────────

const DecodeError = message.Error || std.mem.Allocator.Error;

fn decode_extension_range(data: []const u8) DecodeError!ExtensionRange {
    var result: ExtensionRange = .{};
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            1 => result.start = varint_as_i32(field.value.varint),
            2 => result.end = varint_as_i32(field.value.varint),
            else => {},
        }
    }
    return result;
}

fn decode_reserved_range(data: []const u8) DecodeError!ReservedRange {
    var result: ReservedRange = .{};
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            1 => result.start = varint_as_i32(field.value.varint),
            2 => result.end = varint_as_i32(field.value.varint),
            else => {},
        }
    }
    return result;
}

fn decode_enum_value(data: []const u8) DecodeError!EnumValueDescriptorProto {
    var result: EnumValueDescriptorProto = .{};
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            1 => result.name = field.value.len,
            2 => result.number = varint_as_i32(field.value.varint),
            else => {},
        }
    }
    return result;
}

fn decode_enum_options(data: []const u8) DecodeError!EnumOptions {
    var result: EnumOptions = .{};
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            2 => result.allow_alias = varint_as_bool(field.value.varint),
            else => {},
        }
    }
    return result;
}

fn decode_enum(allocator: std.mem.Allocator, data: []const u8) DecodeError!EnumDescriptorProto {
    var result: EnumDescriptorProto = .{};
    var values: std.ArrayListUnmanaged(EnumValueDescriptorProto) = .empty;
    var reserved_ranges: std.ArrayListUnmanaged(EnumReservedRange) = .empty;
    var reserved_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            1 => result.name = field.value.len,
            2 => try values.append(allocator, try decode_enum_value(field.value.len)),
            3 => result.options = try decode_enum_options(field.value.len),
            4 => {
                var rr: EnumReservedRange = .{};
                var sub_iter = message.iterate_fields(field.value.len);
                while (try sub_iter.next()) |sf| {
                    switch (sf.number) {
                        1 => rr.start = varint_as_i32(sf.value.varint),
                        2 => rr.end = varint_as_i32(sf.value.varint),
                        else => {},
                    }
                }
                try reserved_ranges.append(allocator, rr);
            },
            5 => try reserved_names.append(allocator, field.value.len),
            else => {},
        }
    }
    result.value = try values.toOwnedSlice(allocator);
    result.reserved_range = try reserved_ranges.toOwnedSlice(allocator);
    result.reserved_name = try reserved_names.toOwnedSlice(allocator);
    return result;
}

fn decode_oneof(data: []const u8) DecodeError!OneofDescriptorProto {
    var result: OneofDescriptorProto = .{};
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            1 => result.name = field.value.len,
            else => {},
        }
    }
    return result;
}

fn decode_method(data: []const u8) DecodeError!MethodDescriptorProto {
    var result: MethodDescriptorProto = .{};
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            1 => result.name = field.value.len,
            2 => result.input_type = field.value.len,
            3 => result.output_type = field.value.len,
            5 => result.client_streaming = varint_as_bool(field.value.varint),
            6 => result.server_streaming = varint_as_bool(field.value.varint),
            else => {},
        }
    }
    return result;
}

fn decode_service(allocator: std.mem.Allocator, data: []const u8) DecodeError!ServiceDescriptorProto {
    var result: ServiceDescriptorProto = .{};
    var methods: std.ArrayListUnmanaged(MethodDescriptorProto) = .empty;
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            1 => result.name = field.value.len,
            2 => try methods.append(allocator, try decode_method(field.value.len)),
            else => {},
        }
    }
    result.method = try methods.toOwnedSlice(allocator);
    return result;
}

fn decode_message_options(data: []const u8) DecodeError!MessageOptions {
    var result: MessageOptions = .{};
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            7 => result.map_entry = varint_as_bool(field.value.varint),
            else => {},
        }
    }
    return result;
}

fn decode_field(data: []const u8) DecodeError!FieldDescriptorProto {
    var result: FieldDescriptorProto = .{};
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            1 => result.name = field.value.len,
            3 => result.number = varint_as_i32(field.value.varint),
            4 => result.label = varint_as_i32(field.value.varint),
            5 => result.@"type" = varint_as_i32(field.value.varint),
            6 => result.type_name = field.value.len,
            7 => result.default_value = field.value.len,
            8 => result.options = try decode_field_options(field.value.len),
            9 => result.oneof_index = varint_as_i32(field.value.varint),
            10 => result.json_name = field.value.len,
            else => {},
        }
    }
    return result;
}

fn decode_field_options(data: []const u8) DecodeError!FieldOptions {
    var result: FieldOptions = .{};
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            2 => result.@"packed" = varint_as_bool(field.value.varint),
            else => {},
        }
    }
    return result;
}

fn decode_message(allocator: std.mem.Allocator, data: []const u8) DecodeError!DescriptorProto {
    var result: DescriptorProto = .{};
    var fields: std.ArrayListUnmanaged(FieldDescriptorProto) = .empty;
    var nested_types: std.ArrayListUnmanaged(DescriptorProto) = .empty;
    var enum_types: std.ArrayListUnmanaged(EnumDescriptorProto) = .empty;
    var ext_ranges: std.ArrayListUnmanaged(ExtensionRange) = .empty;
    var extensions: std.ArrayListUnmanaged(FieldDescriptorProto) = .empty;
    var oneofs: std.ArrayListUnmanaged(OneofDescriptorProto) = .empty;
    var reserved_ranges: std.ArrayListUnmanaged(ReservedRange) = .empty;
    var reserved_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            1 => result.name = field.value.len,
            2 => try fields.append(allocator, try decode_field(field.value.len)),
            3 => try nested_types.append(allocator, try decode_message(allocator, field.value.len)),
            4 => try enum_types.append(allocator, try decode_enum(allocator, field.value.len)),
            5 => try ext_ranges.append(allocator, try decode_extension_range(field.value.len)),
            6 => try extensions.append(allocator, try decode_field(field.value.len)),
            7 => result.options = try decode_message_options(field.value.len),
            8 => try oneofs.append(allocator, try decode_oneof(field.value.len)),
            9 => try reserved_ranges.append(allocator, try decode_reserved_range(field.value.len)),
            10 => try reserved_names.append(allocator, field.value.len),
            else => {},
        }
    }
    result.field = try fields.toOwnedSlice(allocator);
    result.nested_type = try nested_types.toOwnedSlice(allocator);
    result.enum_type = try enum_types.toOwnedSlice(allocator);
    result.extension_range = try ext_ranges.toOwnedSlice(allocator);
    result.extension = try extensions.toOwnedSlice(allocator);
    result.oneof_decl = try oneofs.toOwnedSlice(allocator);
    result.reserved_range = try reserved_ranges.toOwnedSlice(allocator);
    result.reserved_name = try reserved_names.toOwnedSlice(allocator);
    return result;
}

fn decode_file(allocator: std.mem.Allocator, data: []const u8) DecodeError!FileDescriptorProto {
    var result: FileDescriptorProto = .{};
    var deps: std.ArrayListUnmanaged([]const u8) = .empty;
    var messages: std.ArrayListUnmanaged(DescriptorProto) = .empty;
    var enums: std.ArrayListUnmanaged(EnumDescriptorProto) = .empty;
    var services: std.ArrayListUnmanaged(ServiceDescriptorProto) = .empty;
    var extensions: std.ArrayListUnmanaged(FieldDescriptorProto) = .empty;
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            1 => result.name = field.value.len,
            2 => result.package = field.value.len,
            3 => try deps.append(allocator, field.value.len),
            4 => try messages.append(allocator, try decode_message(allocator, field.value.len)),
            5 => try enums.append(allocator, try decode_enum(allocator, field.value.len)),
            6 => try services.append(allocator, try decode_service(allocator, field.value.len)),
            7 => try extensions.append(allocator, try decode_field(field.value.len)),
            12 => result.syntax = field.value.len,
            else => {},
        }
    }
    result.dependency = try deps.toOwnedSlice(allocator);
    result.message_type = try messages.toOwnedSlice(allocator);
    result.enum_type = try enums.toOwnedSlice(allocator);
    result.service = try services.toOwnedSlice(allocator);
    result.extension = try extensions.toOwnedSlice(allocator);
    return result;
}

fn decode_request(allocator: std.mem.Allocator, data: []const u8) DecodeError!CodeGeneratorRequest {
    var result: CodeGeneratorRequest = .{};
    var files_to_gen: std.ArrayListUnmanaged([]const u8) = .empty;
    var proto_files: std.ArrayListUnmanaged(FileDescriptorProto) = .empty;
    var iter = message.iterate_fields(data);
    while (try iter.next()) |field| {
        switch (field.number) {
            1 => try files_to_gen.append(allocator, field.value.len),
            2 => result.parameter = field.value.len,
            15 => try proto_files.append(allocator, try decode_file(allocator, field.value.len)),
            else => {},
        }
    }
    result.file_to_generate = try files_to_gen.toOwnedSlice(allocator);
    result.proto_file = try proto_files.toOwnedSlice(allocator);
    return result;
}

// ── Type Name + Conversion Helpers ───────────────────────────────────

/// Strip leading dot and package prefix from a fully-qualified type name.
/// ".mypackage.MyMessage" with package "mypackage" → "MyMessage"
/// ".MyMessage" with no package → "MyMessage"
/// ".other.pkg.MyMessage" with package "mypackage" → "other.pkg.MyMessage"
fn strip_type_prefix(type_name: []const u8, package: []const u8) []const u8 {
    // Strip leading dot
    const name = if (type_name.len > 0 and type_name[0] == '.')
        type_name[1..]
    else
        type_name;

    // Strip package prefix if same package
    if (package.len > 0) {
        if (std.mem.startsWith(u8, name, package)) {
            if (name.len > package.len and name[package.len] == '.') {
                return name[package.len + 1 ..];
            }
        }
    }

    return name;
}

/// Convert a protoc field type integer + type_name to an ast.TypeRef.
fn convert_type(field_type: i32, type_name: []const u8, package: []const u8) ast.TypeRef {
    return switch (field_type) {
        1 => .{ .scalar = .double },
        2 => .{ .scalar = .float },
        3 => .{ .scalar = .int64 },
        4 => .{ .scalar = .uint64 },
        5 => .{ .scalar = .int32 },
        6 => .{ .scalar = .fixed64 },
        7 => .{ .scalar = .fixed32 },
        8 => .{ .scalar = .bool },
        9 => .{ .scalar = .string },
        10 => .{ .named = strip_type_prefix(type_name, package) }, // GROUP
        11 => .{ .named = strip_type_prefix(type_name, package) }, // MESSAGE
        12 => .{ .scalar = .bytes },
        13 => .{ .scalar = .uint32 },
        14 => .{ .enum_ref = strip_type_prefix(type_name, package) }, // ENUM
        15 => .{ .scalar = .sfixed32 },
        16 => .{ .scalar = .sfixed64 },
        17 => .{ .scalar = .sint32 },
        18 => .{ .scalar = .sint64 },
        else => .{ .scalar = .int32 }, // fallback
    };
}

/// Check if a DescriptorProto is a map entry (synthetic message).
fn is_map_entry(desc: DescriptorProto) bool {
    if (desc.options) |opts| {
        return opts.map_entry;
    }
    return false;
}

/// Find a map entry nested type by matching the field's type_name suffix.
fn find_map_entry(nested: []const DescriptorProto, type_name: []const u8) ?DescriptorProto {
    // type_name might be ".pkg.Parent.MapEntryName" — we match on the last segment
    const search_name = if (std.mem.lastIndexOfScalar(u8, type_name, '.')) |idx|
        type_name[idx + 1 ..]
    else
        type_name;

    for (nested) |desc| {
        if (is_map_entry(desc) and std.mem.eql(u8, desc.name, search_name)) {
            return desc;
        }
    }
    return null;
}

// ── FileDescriptorProto → ast.File Conversion ────────────────────────

const no_loc = ast.SourceLocation{ .file = "", .line = 0, .column = 0 };

fn convert_enum(allocator: std.mem.Allocator, desc: EnumDescriptorProto) !ast.Enum {
    const values = try allocator.alloc(ast.EnumValue, desc.value.len);
    for (desc.value, 0..) |v, i| {
        values[i] = .{
            .name = v.name,
            .number = v.number,
            .options = &.{},
            .location = no_loc,
        };
    }

    const reserved_ranges = try allocator.alloc(ast.ReservedRange, desc.reserved_range.len);
    for (desc.reserved_range, 0..) |rr, i| {
        reserved_ranges[i] = .{ .start = rr.start, .end = rr.end };
    }

    return .{
        .name = desc.name,
        .values = values,
        .options = &.{},
        .allow_alias = if (desc.options) |opts| opts.allow_alias else false,
        .reserved_ranges = reserved_ranges,
        .reserved_names = try allocator.dupe([]const u8, desc.reserved_name),
        .location = no_loc,
    };
}

fn convert_service(allocator: std.mem.Allocator, desc: ServiceDescriptorProto, package: []const u8) !ast.Service {
    const methods = try allocator.alloc(ast.Method, desc.method.len);
    for (desc.method, 0..) |m, i| {
        methods[i] = .{
            .name = m.name,
            .input_type = strip_type_prefix(m.input_type, package),
            .output_type = strip_type_prefix(m.output_type, package),
            .client_streaming = m.client_streaming,
            .server_streaming = m.server_streaming,
            .options = &.{},
            .location = no_loc,
        };
    }
    return .{
        .name = desc.name,
        .methods = methods,
        .options = &.{},
        .location = no_loc,
    };
}

fn convert_message(allocator: std.mem.Allocator, desc: DescriptorProto, package: []const u8, syntax: ast.Syntax) !ast.Message {
    // Count fields per oneof_index to detect synthetic oneofs (proto3 optional)
    var oneof_field_counts: std.ArrayListUnmanaged(u32) = .empty;
    for (0..desc.oneof_decl.len) |_| {
        try oneof_field_counts.append(allocator, 0);
    }
    for (desc.field) |f| {
        if (f.oneof_index >= 0 and @as(usize, @intCast(f.oneof_index)) < oneof_field_counts.items.len) {
            oneof_field_counts.items[@intCast(f.oneof_index)] += 1;
        }
    }

    // Identify map entry types
    // Build a set of fields that are maps (repeated field referencing a map_entry message)
    var map_fields: std.ArrayListUnmanaged(ast.MapField) = .empty;
    var map_field_numbers = std.AutoArrayHashMapUnmanaged(i32, void){};

    for (desc.field) |f| {
        if (f.label == 3 and f.@"type" == 11) { // REPEATED MESSAGE
            if (find_map_entry(desc.nested_type, f.type_name)) |map_entry| {
                // Extract key and value types from the map entry
                var key_type: ast.ScalarType = .string;
                var value_type: ast.TypeRef = .{ .scalar = .string };
                for (map_entry.field) |mf| {
                    if (mf.number == 1) {
                        // Key is always scalar
                        key_type = switch (mf.@"type") {
                            5 => .int32,
                            3 => .int64,
                            13 => .uint32,
                            4 => .uint64,
                            17 => .sint32,
                            18 => .sint64,
                            7 => .fixed32,
                            6 => .fixed64,
                            15 => .sfixed32,
                            16 => .sfixed64,
                            8 => .bool,
                            9 => .string,
                            else => .string,
                        };
                    } else if (mf.number == 2) {
                        value_type = convert_type(mf.@"type", mf.type_name, package);
                    }
                }
                try map_fields.append(allocator, .{
                    .name = f.name,
                    .number = f.number,
                    .key_type = key_type,
                    .value_type = value_type,
                    .options = &.{},
                    .location = no_loc,
                });
                try map_field_numbers.put(allocator, f.number, {});
            }
        }
    }

    // Convert regular fields (excluding map fields)
    var fields: std.ArrayListUnmanaged(ast.Field) = .empty;
    // Track which fields belong to real oneofs
    var oneof_fields_map = std.AutoArrayHashMapUnmanaged(usize, std.ArrayListUnmanaged(ast.Field)){};

    for (desc.field) |f| {
        // Skip map fields
        if (map_field_numbers.get(f.number) != null) continue;

        const type_ref = convert_type(f.@"type", f.type_name, package);

        // Determine label
        const label: ast.FieldLabel = blk: {
            if (f.oneof_index >= 0) {
                const oi: usize = @intCast(f.oneof_index);
                if (oi < oneof_field_counts.items.len and oneof_field_counts.items[oi] == 1) {
                    // Synthetic oneof (proto3 optional) — mark as optional
                    break :blk .optional;
                }
                // Real oneof member — will be added to the oneof, use implicit label
                break :blk .implicit;
            }
            break :blk switch (f.label) {
                1 => if (syntax == .proto3) .implicit else .optional, // OPTIONAL
                2 => .required, // REQUIRED
                3 => .repeated, // REPEATED
                else => .implicit,
            };
        };

        // Build field options (default value + packed)
        var field_opts_list: std.ArrayListUnmanaged(ast.FieldOption) = .empty;
        if (f.default_value.len > 0) {
            const parts = try allocator.alloc(ast.OptionName.Part, 1);
            parts[0] = .{ .name = "default", .is_extension = false };
            try field_opts_list.append(allocator, .{
                .name = .{ .parts = parts },
                .value = .{ .string_value = f.default_value },
            });
        }
        if (f.options) |opts| {
            if (opts.@"packed") |is_packed| {
                const parts = try allocator.alloc(ast.OptionName.Part, 1);
                parts[0] = .{ .name = "packed", .is_extension = false };
                try field_opts_list.append(allocator, .{
                    .name = .{ .parts = parts },
                    .value = .{ .bool_value = is_packed },
                });
            }
        }
        const field_options = try field_opts_list.toOwnedSlice(allocator);

        const ast_field = ast.Field{
            .name = f.name,
            .number = f.number,
            .label = label,
            .type_name = type_ref,
            .options = field_options,
            .location = no_loc,
        };

        // Check if field belongs to a real oneof
        if (f.oneof_index >= 0) {
            const oi: usize = @intCast(f.oneof_index);
            if (oi < oneof_field_counts.items.len and oneof_field_counts.items[oi] > 1) {
                // Real oneof member
                const entry = try oneof_fields_map.getOrPut(allocator, oi);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .empty;
                }
                try entry.value_ptr.append(allocator, ast_field);
                continue;
            }
        }

        try fields.append(allocator, ast_field);
    }

    // Convert real oneofs
    var oneofs: std.ArrayListUnmanaged(ast.Oneof) = .empty;
    for (desc.oneof_decl, 0..) |od, oi| {
        // Skip synthetic oneofs (single member)
        if (oi < oneof_field_counts.items.len and oneof_field_counts.items[oi] <= 1) continue;

        const oneof_fields_list = oneof_fields_map.getPtr(oi);
        const oneof_field_slice = if (oneof_fields_list) |l|
            try l.toOwnedSlice(allocator)
        else
            @as([]ast.Field, &.{});

        try oneofs.append(allocator, .{
            .name = od.name,
            .fields = oneof_field_slice,
            .options = &.{},
            .location = no_loc,
        });
    }

    // Convert nested types (skip map entries)
    var nested_messages: std.ArrayListUnmanaged(ast.Message) = .empty;
    for (desc.nested_type) |nt| {
        if (is_map_entry(nt)) continue;
        try nested_messages.append(allocator, try convert_message(allocator, nt, package, syntax));
    }

    // Convert nested enums
    var nested_enums: std.ArrayListUnmanaged(ast.Enum) = .empty;
    for (desc.enum_type) |et| {
        try nested_enums.append(allocator, try convert_enum(allocator, et));
    }

    // Convert extension ranges
    const ext_ranges = try allocator.alloc(ast.ExtensionRange, desc.extension_range.len);
    for (desc.extension_range, 0..) |er, i| {
        ext_ranges[i] = .{ .start = er.start, .end = er.end, .options = &.{} };
    }

    // Convert reserved ranges
    const res_ranges = try allocator.alloc(ast.ReservedRange, desc.reserved_range.len);
    for (desc.reserved_range, 0..) |rr, i| {
        res_ranges[i] = .{ .start = rr.start, .end = rr.end };
    }

    // Convert extensions (extend blocks)
    var extend_fields: std.ArrayListUnmanaged(ast.Field) = .empty;
    for (desc.extension) |ext| {
        const ext_type_ref = convert_type(ext.@"type", ext.type_name, package);
        try extend_fields.append(allocator, .{
            .name = ext.name,
            .number = ext.number,
            .label = switch (ext.label) {
                1 => .optional,
                2 => .required,
                3 => .repeated,
                else => .optional,
            },
            .type_name = ext_type_ref,
            .options = &.{},
            .location = no_loc,
        });
    }

    // Build extensions slice
    var extensions: []ast.Extend = &.{};
    if (extend_fields.items.len > 0) {
        const extends = try allocator.alloc(ast.Extend, 1);
        extends[0] = .{
            .type_name = desc.name,
            .fields = try extend_fields.toOwnedSlice(allocator),
            .groups = &.{},
            .location = no_loc,
        };
        extensions = extends;
    }

    return .{
        .name = desc.name,
        .fields = try fields.toOwnedSlice(allocator),
        .oneofs = try oneofs.toOwnedSlice(allocator),
        .nested_messages = try nested_messages.toOwnedSlice(allocator),
        .nested_enums = try nested_enums.toOwnedSlice(allocator),
        .maps = try map_fields.toOwnedSlice(allocator),
        .reserved_ranges = res_ranges,
        .reserved_names = try allocator.dupe([]const u8, desc.reserved_name),
        .extension_ranges = ext_ranges,
        .extensions = extensions,
        .groups = &.{},
        .options = &.{},
        .location = no_loc,
    };
}

fn convert_file(allocator: std.mem.Allocator, file_desc: FileDescriptorProto) !ast.File {
    const syntax: ast.Syntax = if (std.mem.eql(u8, file_desc.syntax, "proto3"))
        .proto3
    else
        .proto2;

    const package: ?[]const u8 = if (file_desc.package.len > 0) file_desc.package else null;
    const pkg_str = file_desc.package;

    // Convert messages
    var messages: std.ArrayListUnmanaged(ast.Message) = .empty;
    for (file_desc.message_type) |mt| {
        try messages.append(allocator, try convert_message(allocator, mt, pkg_str, syntax));
    }

    // Convert enums
    var file_enums: std.ArrayListUnmanaged(ast.Enum) = .empty;
    for (file_desc.enum_type) |et| {
        try file_enums.append(allocator, try convert_enum(allocator, et));
    }

    // Convert services
    var services: std.ArrayListUnmanaged(ast.Service) = .empty;
    for (file_desc.service) |s| {
        try services.append(allocator, try convert_service(allocator, s, pkg_str));
    }

    // Convert file-level extensions
    var extends: std.ArrayListUnmanaged(ast.Extend) = .empty;
    if (file_desc.extension.len > 0) {
        var ext_fields: std.ArrayListUnmanaged(ast.Field) = .empty;
        for (file_desc.extension) |ext| {
            const ext_type_ref = convert_type(ext.@"type", ext.type_name, pkg_str);
            try ext_fields.append(allocator, .{
                .name = ext.name,
                .number = ext.number,
                .label = switch (ext.label) {
                    1 => .optional,
                    2 => .required,
                    3 => .repeated,
                    else => .optional,
                },
                .type_name = ext_type_ref,
                .options = &.{},
                .location = no_loc,
            });
        }
        // Group all file-level extensions by target type
        // For simplicity, use the first extension's type_name
        if (file_desc.extension.len > 0) {
            const ext = try allocator.alloc(ast.Extend, 1);
            ext[0] = .{
                .type_name = strip_type_prefix(file_desc.extension[0].type_name, pkg_str),
                .fields = try ext_fields.toOwnedSlice(allocator),
                .groups = &.{},
                .location = no_loc,
            };
            try extends.appendSlice(allocator, ext);
        }
    }

    return .{
        .syntax = syntax,
        .package = package,
        .imports = &.{},
        .options = &.{},
        .messages = try messages.toOwnedSlice(allocator),
        .enums = try file_enums.toOwnedSlice(allocator),
        .services = try services.toOwnedSlice(allocator),
        .extensions = try extends.toOwnedSlice(allocator),
    };
}

// ── Response Encoding ────────────────────────────────────────────────

const ResponseFile = struct {
    name: []const u8,
    content: []const u8,
};

fn encode_response_file(allocator: std.mem.Allocator, file: ResponseFile) ![]const u8 {
    // Calculate size
    var size: usize = 0;
    if (file.name.len > 0) size += message.len_field_size(1, file.name.len);
    if (file.content.len > 0) size += message.len_field_size(15, file.content.len);

    const buf = try allocator.alloc(u8, size);
    var writer: std.Io.Writer = .fixed(buf);
    const mw = message.MessageWriter.init(&writer);
    if (file.name.len > 0) try mw.write_len_field(1, file.name);
    if (file.content.len > 0) try mw.write_len_field(15, file.content);
    return writer.buffered();
}

fn encode_response(allocator: std.mem.Allocator, err_msg: ?[]const u8, features: u64, files: []const ResponseFile) ![]const u8 {
    // Pre-encode all files
    const encoded_files = try allocator.alloc([]const u8, files.len);
    for (files, 0..) |f, i| {
        encoded_files[i] = try encode_response_file(allocator, f);
    }

    // Calculate total size
    var size: usize = 0;
    if (err_msg) |e| {
        if (e.len > 0) size += message.len_field_size(1, e.len);
    }
    if (features != 0) size += message.varint_field_size(2, features);
    for (encoded_files) |ef| {
        size += message.len_field_size(15, ef.len);
    }

    const buf = try allocator.alloc(u8, size);
    var writer: std.Io.Writer = .fixed(buf);
    const mw = message.MessageWriter.init(&writer);
    if (err_msg) |e| {
        if (e.len > 0) try mw.write_len_field(1, e);
    }
    if (features != 0) try mw.write_varint_field(2, features);
    for (encoded_files) |ef| {
        try mw.write_len_field(15, ef);
    }
    return writer.buffered();
}

// ── Plugin Entry Point ───────────────────────────────────────────────

/// Feature flag: FEATURE_PROTO3_OPTIONAL = 1
const FEATURE_PROTO3_OPTIONAL: u64 = 1;

/// Read a CodeGeneratorRequest from stdin, generate Zig sources, and write the response to stdout
pub fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Read request from stdin
    const stdin = std.fs.File.stdin();
    const request_bytes = stdin.readToEndAlloc(allocator, 100 * 1024 * 1024) catch |err| {
        try write_error_response("Failed to read stdin");
        return err;
    };

    const response_bytes = generate(allocator, request_bytes) catch |err| {
        try write_error_response(@errorName(err));
        return;
    };

    // Write response to stdout
    const stdout = std.fs.File.stdout();
    stdout.writeAll(response_bytes) catch |err| {
        return err;
    };
}

/// Generate Zig source files from a serialized CodeGeneratorRequest, returning the serialized response
pub fn generate(allocator: std.mem.Allocator, request_bytes: []const u8) ![]const u8 {
    const request = try decode_request(allocator, request_bytes);

    // Build set of files to generate
    var files_to_gen = std.StringArrayHashMapUnmanaged(void){};
    for (request.file_to_generate) |f| {
        try files_to_gen.put(allocator, f, {});
    }

    // Process each requested file
    var response_files: std.ArrayListUnmanaged(ResponseFile) = .empty;
    for (request.proto_file) |proto_file| {
        if (files_to_gen.get(proto_file.name) == null) continue;

        const ast_file = try convert_file(allocator, proto_file);
        const zig_source = try codegen.generate_file(allocator, ast_file, proto_file.name);
        const out_path = try codegen.package_to_path(allocator, ast_file.package, proto_file.name);

        try response_files.append(allocator, .{
            .name = out_path,
            .content = zig_source,
        });
    }

    return try encode_response(allocator, null, FEATURE_PROTO3_OPTIONAL, response_files.items);
}

fn write_error_response(err_msg: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const response_bytes = try encode_response(allocator, err_msg, 0, &.{});
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(response_bytes);
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

// ── Helper: encode a submessage and return its bytes ─────────────────

fn encode_submessage(buf: []u8, write_fn: anytype) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    const mw = message.MessageWriter.init(&writer);
    write_fn(mw) catch unreachable;
    return writer.buffered();
}

// ── Decode Tests ─────────────────────────────────────────────────────

test "decode_enum_value: name and number" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = message.MessageWriter.init(&w);
    try mw.write_len_field(1, "MY_VALUE");
    try mw.write_varint_field(2, @bitCast(@as(i64, 42)));

    const ev = try decode_enum_value(w.buffered());
    try testing.expectEqualStrings("MY_VALUE", ev.name);
    try testing.expectEqual(@as(i32, 42), ev.number);
}

test "decode_enum: name, values, allow_alias" {
    const allocator = testing.allocator;

    // Encode an enum value submessage
    var val_buf: [64]u8 = undefined;
    var val_w: std.Io.Writer = .fixed(&val_buf);
    var val_mw = message.MessageWriter.init(&val_w);
    try val_mw.write_len_field(1, "FOO");
    try val_mw.write_varint_field(2, 0);
    const val_bytes = val_w.buffered();

    // Encode enum options with allow_alias=true
    var opt_buf: [16]u8 = undefined;
    var opt_w: std.Io.Writer = .fixed(&opt_buf);
    var opt_mw = message.MessageWriter.init(&opt_w);
    try opt_mw.write_varint_field(2, 1);
    const opt_bytes = opt_w.buffered();

    // Encode the enum
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = message.MessageWriter.init(&w);
    try mw.write_len_field(1, "MyEnum");
    try mw.write_len_field(2, val_bytes);
    try mw.write_len_field(3, opt_bytes);

    const en = try decode_enum(allocator, w.buffered());
    defer allocator.free(en.value);
    try testing.expectEqualStrings("MyEnum", en.name);
    try testing.expectEqual(@as(usize, 1), en.value.len);
    try testing.expectEqualStrings("FOO", en.value[0].name);
    try testing.expect(en.options.?.allow_alias);
}

test "decode_field: all key fields" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = message.MessageWriter.init(&w);
    try mw.write_len_field(1, "my_field");
    try mw.write_varint_field(3, 5); // number
    try mw.write_varint_field(4, 1); // label OPTIONAL
    try mw.write_varint_field(5, 11); // type MESSAGE
    try mw.write_len_field(6, ".pkg.MyMsg");
    try mw.write_len_field(10, "myField"); // json_name

    const fd = try decode_field(w.buffered());
    try testing.expectEqualStrings("my_field", fd.name);
    try testing.expectEqual(@as(i32, 5), fd.number);
    try testing.expectEqual(@as(i32, 1), fd.label);
    try testing.expectEqual(@as(i32, 11), fd.@"type");
    try testing.expectEqualStrings(".pkg.MyMsg", fd.type_name);
    try testing.expectEqualStrings("myField", fd.json_name);
}

test "decode_message: fields and nested types" {
    const allocator = testing.allocator;

    // Encode a field
    var field_buf: [64]u8 = undefined;
    var field_w: std.Io.Writer = .fixed(&field_buf);
    var field_mw = message.MessageWriter.init(&field_w);
    try field_mw.write_len_field(1, "x");
    try field_mw.write_varint_field(3, 1);
    try field_mw.write_varint_field(4, 1);
    try field_mw.write_varint_field(5, 5); // int32
    const field_bytes = field_w.buffered();

    // Encode the message
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = message.MessageWriter.init(&w);
    try mw.write_len_field(1, "MyMessage");
    try mw.write_len_field(2, field_bytes);

    const msg = try decode_message(allocator, w.buffered());
    defer {
        allocator.free(msg.field);
        allocator.free(msg.nested_type);
        allocator.free(msg.enum_type);
        allocator.free(msg.extension_range);
        allocator.free(msg.extension);
        allocator.free(msg.oneof_decl);
        allocator.free(msg.reserved_range);
        allocator.free(msg.reserved_name);
    }
    try testing.expectEqualStrings("MyMessage", msg.name);
    try testing.expectEqual(@as(usize, 1), msg.field.len);
    try testing.expectEqualStrings("x", msg.field[0].name);
    try testing.expectEqual(@as(i32, 1), msg.field[0].number);
}

test "decode_service: name and methods" {
    const allocator = testing.allocator;

    // Encode a method
    var method_buf: [128]u8 = undefined;
    var method_w: std.Io.Writer = .fixed(&method_buf);
    var method_mw = message.MessageWriter.init(&method_w);
    try method_mw.write_len_field(1, "GetUser");
    try method_mw.write_len_field(2, ".pkg.GetUserRequest");
    try method_mw.write_len_field(3, ".pkg.GetUserResponse");
    try method_mw.write_varint_field(6, 1); // server_streaming
    const method_bytes = method_w.buffered();

    // Encode the service
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = message.MessageWriter.init(&w);
    try mw.write_len_field(1, "UserService");
    try mw.write_len_field(2, method_bytes);

    const svc = try decode_service(allocator, w.buffered());
    defer allocator.free(svc.method);
    try testing.expectEqualStrings("UserService", svc.name);
    try testing.expectEqual(@as(usize, 1), svc.method.len);
    try testing.expectEqualStrings("GetUser", svc.method[0].name);
    try testing.expectEqualStrings(".pkg.GetUserRequest", svc.method[0].input_type);
    try testing.expect(svc.method[0].server_streaming);
    try testing.expect(!svc.method[0].client_streaming);
}

test "decode_request: files_to_generate and proto_file" {
    const allocator = testing.allocator;

    // Encode a minimal FileDescriptorProto
    var file_buf: [128]u8 = undefined;
    var file_w: std.Io.Writer = .fixed(&file_buf);
    var file_mw = message.MessageWriter.init(&file_w);
    try file_mw.write_len_field(1, "test.proto");
    try file_mw.write_len_field(12, "proto3");
    const file_bytes = file_w.buffered();

    // Encode the request
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = message.MessageWriter.init(&w);
    try mw.write_len_field(1, "test.proto");
    try mw.write_len_field(2, "my_param");
    try mw.write_len_field(15, file_bytes);

    const req = try decode_request(allocator, w.buffered());
    defer {
        allocator.free(req.file_to_generate);
        for (req.proto_file) |pf| {
            allocator.free(pf.dependency);
            allocator.free(pf.message_type);
            allocator.free(pf.enum_type);
            allocator.free(pf.service);
            allocator.free(pf.extension);
        }
        allocator.free(req.proto_file);
    }
    try testing.expectEqual(@as(usize, 1), req.file_to_generate.len);
    try testing.expectEqualStrings("test.proto", req.file_to_generate[0]);
    try testing.expectEqualStrings("my_param", req.parameter);
    try testing.expectEqual(@as(usize, 1), req.proto_file.len);
    try testing.expectEqualStrings("test.proto", req.proto_file[0].name);
    try testing.expectEqualStrings("proto3", req.proto_file[0].syntax);
}

// ── Type Name Helper Tests ───────────────────────────────────────────

test "strip_type_prefix: with leading dot and package" {
    try testing.expectEqualStrings("MyMessage", strip_type_prefix(".mypackage.MyMessage", "mypackage"));
}

test "strip_type_prefix: with leading dot, no package" {
    try testing.expectEqualStrings("MyMessage", strip_type_prefix(".MyMessage", ""));
}

test "strip_type_prefix: different package not stripped" {
    try testing.expectEqualStrings("other.pkg.MyMessage", strip_type_prefix(".other.pkg.MyMessage", "mypackage"));
}

test "strip_type_prefix: nested type in same package" {
    try testing.expectEqualStrings("Outer.Inner", strip_type_prefix(".mypackage.Outer.Inner", "mypackage"));
}

test "convert_type: scalar types" {
    try testing.expectEqual(ast.ScalarType.double, convert_type(1, "", "").scalar);
    try testing.expectEqual(ast.ScalarType.float, convert_type(2, "", "").scalar);
    try testing.expectEqual(ast.ScalarType.int64, convert_type(3, "", "").scalar);
    try testing.expectEqual(ast.ScalarType.uint64, convert_type(4, "", "").scalar);
    try testing.expectEqual(ast.ScalarType.int32, convert_type(5, "", "").scalar);
    try testing.expectEqual(ast.ScalarType.bool, convert_type(8, "", "").scalar);
    try testing.expectEqual(ast.ScalarType.string, convert_type(9, "", "").scalar);
    try testing.expectEqual(ast.ScalarType.bytes, convert_type(12, "", "").scalar);
}

test "convert_type: message type" {
    const t = convert_type(11, ".pkg.MyMsg", "pkg");
    try testing.expectEqualStrings("MyMsg", t.named);
}

test "convert_type: enum type" {
    const t = convert_type(14, ".pkg.MyEnum", "pkg");
    try testing.expectEqualStrings("MyEnum", t.enum_ref);
}

test "is_map_entry: true for map entry" {
    const desc = DescriptorProto{
        .name = "LabelsEntry",
        .options = .{ .map_entry = true },
    };
    try testing.expect(is_map_entry(desc));
}

test "is_map_entry: false for regular message" {
    const desc = DescriptorProto{ .name = "Regular" };
    try testing.expect(!is_map_entry(desc));
}

// ── Conversion Tests ─────────────────────────────────────────────────

test "convert_enum: basic enum" {
    const allocator = testing.allocator;
    const values = [_]EnumValueDescriptorProto{
        .{ .name = "UNKNOWN", .number = 0 },
        .{ .name = "ACTIVE", .number = 1 },
    };
    const desc = EnumDescriptorProto{
        .name = "Status",
        .value = &values,
    };

    const en = try convert_enum(allocator, desc);
    defer allocator.free(en.values);
    try testing.expectEqualStrings("Status", en.name);
    try testing.expectEqual(@as(usize, 2), en.values.len);
    try testing.expectEqualStrings("UNKNOWN", en.values[0].name);
    try testing.expectEqual(@as(i32, 0), en.values[0].number);
}

test "convert_service: methods with type name stripping" {
    const allocator = testing.allocator;
    const methods = [_]MethodDescriptorProto{.{
        .name = "GetUser",
        .input_type = ".pkg.GetUserRequest",
        .output_type = ".pkg.GetUserResponse",
        .server_streaming = true,
    }};
    const desc = ServiceDescriptorProto{
        .name = "UserService",
        .method = &methods,
    };

    const svc = try convert_service(allocator, desc, "pkg");
    defer allocator.free(svc.methods);
    try testing.expectEqualStrings("UserService", svc.name);
    try testing.expectEqual(@as(usize, 1), svc.methods.len);
    try testing.expectEqualStrings("GetUser", svc.methods[0].name);
    try testing.expectEqualStrings("GetUserRequest", svc.methods[0].input_type);
    try testing.expectEqualStrings("GetUserResponse", svc.methods[0].output_type);
    try testing.expect(svc.methods[0].server_streaming);
}

test "convert_file: proto3 with message and enum" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const enum_values = [_]EnumValueDescriptorProto{
        .{ .name = "UNKNOWN", .number = 0 },
        .{ .name = "ACTIVE", .number = 1 },
    };
    const enums = [_]EnumDescriptorProto{.{
        .name = "Status",
        .value = &enum_values,
    }};

    const fields = [_]FieldDescriptorProto{
        .{ .name = "name", .number = 1, .label = 1, .@"type" = 9 }, // string
        .{ .name = "id", .number = 2, .label = 1, .@"type" = 5 }, // int32
    };
    const messages = [_]DescriptorProto{.{
        .name = "Person",
        .field = &fields,
    }};

    const file_desc = FileDescriptorProto{
        .name = "test.proto",
        .package = "mypackage",
        .syntax = "proto3",
        .message_type = &messages,
        .enum_type = &enums,
    };

    const ast_file = try convert_file(a, file_desc);
    try testing.expectEqual(ast.Syntax.proto3, ast_file.syntax);
    try testing.expectEqualStrings("mypackage", ast_file.package.?);
    try testing.expectEqual(@as(usize, 1), ast_file.messages.len);
    try testing.expectEqualStrings("Person", ast_file.messages[0].name);
    try testing.expectEqual(@as(usize, 2), ast_file.messages[0].fields.len);
    try testing.expectEqual(@as(usize, 1), ast_file.enums.len);
    try testing.expectEqualStrings("Status", ast_file.enums[0].name);
}

test "convert_file: proto3 with map field" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Map entry type
    const map_entry_fields = [_]FieldDescriptorProto{
        .{ .name = "key", .number = 1, .label = 1, .@"type" = 9 }, // string key
        .{ .name = "value", .number = 2, .label = 1, .@"type" = 9 }, // string value
    };
    const nested = [_]DescriptorProto{.{
        .name = "LabelsEntry",
        .field = &map_entry_fields,
        .options = .{ .map_entry = true },
    }};

    // The actual map field appears as repeated
    const fields = [_]FieldDescriptorProto{
        .{ .name = "labels", .number = 1, .label = 3, .@"type" = 11, .type_name = ".pkg.MyMsg.LabelsEntry" },
    };

    const messages = [_]DescriptorProto{.{
        .name = "MyMsg",
        .field = &fields,
        .nested_type = &nested,
    }};

    const file_desc = FileDescriptorProto{
        .name = "test.proto",
        .package = "pkg",
        .syntax = "proto3",
        .message_type = &messages,
    };

    const ast_file = try convert_file(a, file_desc);
    try testing.expectEqual(@as(usize, 1), ast_file.messages.len);
    // Map field should be extracted
    try testing.expectEqual(@as(usize, 1), ast_file.messages[0].maps.len);
    try testing.expectEqualStrings("labels", ast_file.messages[0].maps[0].name);
    try testing.expectEqual(ast.ScalarType.string, ast_file.messages[0].maps[0].key_type);
    // Regular field list should be empty (the map field was extracted)
    try testing.expectEqual(@as(usize, 0), ast_file.messages[0].fields.len);
    // Map entry should not appear as nested message
    try testing.expectEqual(@as(usize, 0), ast_file.messages[0].nested_messages.len);
}

test "convert_file: proto3 optional (synthetic oneof)" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proto3 optional: field with oneof_index pointing to a synthetic oneof (1 member)
    const fields = [_]FieldDescriptorProto{
        .{ .name = "name", .number = 1, .label = 1, .@"type" = 9 }, // regular
        .{ .name = "nickname", .number = 2, .label = 1, .@"type" = 9, .oneof_index = 0 }, // synthetic oneof
    };
    const oneofs = [_]OneofDescriptorProto{
        .{ .name = "_nickname" },
    };

    const messages = [_]DescriptorProto{.{
        .name = "Person",
        .field = &fields,
        .oneof_decl = &oneofs,
    }};

    const file_desc = FileDescriptorProto{
        .name = "test.proto",
        .syntax = "proto3",
        .message_type = &messages,
    };

    const ast_file = try convert_file(a, file_desc);
    try testing.expectEqual(@as(usize, 1), ast_file.messages.len);
    const msg = ast_file.messages[0];
    // Synthetic oneof should NOT create an ast.Oneof
    try testing.expectEqual(@as(usize, 0), msg.oneofs.len);
    // Should have 2 fields
    try testing.expectEqual(@as(usize, 2), msg.fields.len);
    // First field: implicit (proto3 default)
    try testing.expectEqual(ast.FieldLabel.implicit, msg.fields[0].label);
    // Second field: optional (from synthetic oneof)
    try testing.expectEqual(ast.FieldLabel.optional, msg.fields[1].label);
}

test "convert_file: real oneof" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fields = [_]FieldDescriptorProto{
        .{ .name = "id", .number = 1, .label = 1, .@"type" = 5 }, // regular int32
        .{ .name = "text", .number = 2, .label = 1, .@"type" = 9, .oneof_index = 0 },
        .{ .name = "count", .number = 3, .label = 1, .@"type" = 5, .oneof_index = 0 },
    };
    const oneofs = [_]OneofDescriptorProto{
        .{ .name = "payload" },
    };

    const messages = [_]DescriptorProto{.{
        .name = "MyMsg",
        .field = &fields,
        .oneof_decl = &oneofs,
    }};

    const file_desc = FileDescriptorProto{
        .name = "test.proto",
        .syntax = "proto3",
        .message_type = &messages,
    };

    const ast_file = try convert_file(a, file_desc);
    const msg = ast_file.messages[0];
    // Should have 1 regular field
    try testing.expectEqual(@as(usize, 1), msg.fields.len);
    try testing.expectEqualStrings("id", msg.fields[0].name);
    // Should have 1 real oneof
    try testing.expectEqual(@as(usize, 1), msg.oneofs.len);
    try testing.expectEqualStrings("payload", msg.oneofs[0].name);
    try testing.expectEqual(@as(usize, 2), msg.oneofs[0].fields.len);
    try testing.expectEqualStrings("text", msg.oneofs[0].fields[0].name);
    try testing.expectEqualStrings("count", msg.oneofs[0].fields[1].name);
}

// ── Response Encoding Tests ──────────────────────────────────────────

test "encode_response_file: round-trip" {
    const allocator = testing.allocator;
    const file = ResponseFile{ .name = "out.zig", .content = "const x = 42;" };
    const encoded = try encode_response_file(allocator, file);
    defer allocator.free(encoded);

    // Decode and verify
    var iter = message.iterate_fields(encoded);
    var name: []const u8 = "";
    var content: []const u8 = "";
    while (try iter.next()) |field| {
        switch (field.number) {
            1 => name = field.value.len,
            15 => content = field.value.len,
            else => {},
        }
    }
    try testing.expectEqualStrings("out.zig", name);
    try testing.expectEqualStrings("const x = 42;", content);
}

test "encode_response: with error message" {
    const allocator = testing.allocator;
    const encoded = try encode_response(allocator, "something broke", 0, &.{});
    defer allocator.free(encoded);

    var iter = message.iterate_fields(encoded);
    var err_msg: []const u8 = "";
    while (try iter.next()) |field| {
        switch (field.number) {
            1 => err_msg = field.value.len,
            else => {},
        }
    }
    try testing.expectEqualStrings("something broke", err_msg);
}

test "encode_response: with files and features" {
    // Use an arena since encode_response allocates intermediate buffers
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const files = [_]ResponseFile{
        .{ .name = "a.zig", .content = "const a = 1;" },
        .{ .name = "b.zig", .content = "const b = 2;" },
    };
    const encoded = try encode_response(allocator, null, 1, &files);

    // Verify we can decode the response
    var iter = message.iterate_fields(encoded);
    var features: u64 = 0;
    var file_count: usize = 0;
    while (try iter.next()) |field| {
        switch (field.number) {
            2 => features = field.value.varint,
            15 => file_count += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(u64, 1), features);
    try testing.expectEqual(@as(usize, 2), file_count);
}

// ── End-to-End Tests ─────────────────────────────────────────────────

fn expect_contains(output: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, output, expected) == null) {
        std.debug.print("\n=== EXPECTED (not found) ===\n{s}\n=== IN OUTPUT ({d} bytes) ===\n{s}\n=== END ===\n", .{ expected, output.len, output });
        return error.TestExpectedEqual;
    }
}

fn build_proto3_scalar_request(allocator: std.mem.Allocator) ![]const u8 {
    // Build a CodeGeneratorRequest with a simple proto3 file containing a scalar message

    // Field: name string = 1
    var f1_buf: [64]u8 = undefined;
    var f1_w: std.Io.Writer = .fixed(&f1_buf);
    var f1_mw = message.MessageWriter.init(&f1_w);
    try f1_mw.write_len_field(1, "name");
    try f1_mw.write_varint_field(3, 1); // number
    try f1_mw.write_varint_field(4, 1); // label OPTIONAL
    try f1_mw.write_varint_field(5, 9); // type STRING
    try f1_mw.write_len_field(10, "name"); // json_name
    const f1_bytes = f1_w.buffered();

    // Field: id int32 = 2
    var f2_buf: [64]u8 = undefined;
    var f2_w: std.Io.Writer = .fixed(&f2_buf);
    var f2_mw = message.MessageWriter.init(&f2_w);
    try f2_mw.write_len_field(1, "id");
    try f2_mw.write_varint_field(3, 2); // number
    try f2_mw.write_varint_field(4, 1); // label OPTIONAL
    try f2_mw.write_varint_field(5, 5); // type INT32
    try f2_mw.write_len_field(10, "id"); // json_name
    const f2_bytes = f2_w.buffered();

    // Message: Person
    var msg_buf: [256]u8 = undefined;
    var msg_w: std.Io.Writer = .fixed(&msg_buf);
    var msg_mw = message.MessageWriter.init(&msg_w);
    try msg_mw.write_len_field(1, "Person");
    try msg_mw.write_len_field(2, f1_bytes);
    try msg_mw.write_len_field(2, f2_bytes);
    const msg_bytes = msg_w.buffered();

    // FileDescriptorProto
    var file_buf: [512]u8 = undefined;
    var file_w: std.Io.Writer = .fixed(&file_buf);
    var file_mw = message.MessageWriter.init(&file_w);
    try file_mw.write_len_field(1, "test.proto");
    try file_mw.write_len_field(12, "proto3");
    try file_mw.write_len_field(4, msg_bytes);
    const file_bytes = file_w.buffered();

    // CodeGeneratorRequest
    const req_buf = try allocator.alloc(u8, 1024);
    var req_w: std.Io.Writer = .fixed(req_buf);
    const req_mw = message.MessageWriter.init(&req_w);
    try req_mw.write_len_field(1, "test.proto");
    try req_mw.write_len_field(15, file_bytes);
    const result = req_w.buffered();

    // Copy to owned slice so we can return it
    const owned = try allocator.alloc(u8, result.len);
    @memcpy(owned, result);
    allocator.free(req_buf);
    return owned;
}

test "end-to-end: proto3 scalar message" {
    const allocator = testing.allocator;
    const request_bytes = try build_proto3_scalar_request(allocator);
    defer allocator.free(request_bytes);

    // Use an arena for the generation
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const response_bytes = try generate(arena.allocator(), request_bytes);

    // Decode the response
    var resp_iter = message.iterate_fields(response_bytes);
    var generated_content: []const u8 = "";
    var generated_name: []const u8 = "";
    while (try resp_iter.next()) |field| {
        switch (field.number) {
            2 => try testing.expectEqual(@as(u64, FEATURE_PROTO3_OPTIONAL), field.value.varint),
            15 => {
                // Decode the File submessage
                var file_iter = message.iterate_fields(field.value.len);
                while (try file_iter.next()) |ff| {
                    switch (ff.number) {
                        1 => generated_name = ff.value.len,
                        15 => generated_content = ff.value.len,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    // Verify output filename
    try testing.expectEqualStrings("test.zig", generated_name);

    // Verify generated Zig code contains expected elements
    try expect_contains(generated_content, "pub const Person = struct {");
    try expect_contains(generated_content, "name:");
    try expect_contains(generated_content, "id:");
    try expect_contains(generated_content, "pub fn encode(");
    try expect_contains(generated_content, "pub fn decode(");
}

test "end-to-end: proto3 with enum" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Enum value: UNKNOWN = 0
    var ev_buf: [32]u8 = undefined;
    var ev_w: std.Io.Writer = .fixed(&ev_buf);
    var ev_mw = message.MessageWriter.init(&ev_w);
    try ev_mw.write_len_field(1, "UNKNOWN");
    try ev_mw.write_varint_field(2, 0);
    const ev_bytes = ev_w.buffered();

    // Enum value: ACTIVE = 1
    var ev2_buf: [32]u8 = undefined;
    var ev2_w: std.Io.Writer = .fixed(&ev2_buf);
    var ev2_mw = message.MessageWriter.init(&ev2_w);
    try ev2_mw.write_len_field(1, "ACTIVE");
    try ev2_mw.write_varint_field(2, 1);
    const ev2_bytes = ev2_w.buffered();

    // Enum
    var enum_buf: [128]u8 = undefined;
    var enum_w: std.Io.Writer = .fixed(&enum_buf);
    var enum_mw = message.MessageWriter.init(&enum_w);
    try enum_mw.write_len_field(1, "Status");
    try enum_mw.write_len_field(2, ev_bytes);
    try enum_mw.write_len_field(2, ev2_bytes);
    const enum_bytes = enum_w.buffered();

    // Field referencing enum
    var f_buf: [64]u8 = undefined;
    var f_w: std.Io.Writer = .fixed(&f_buf);
    var f_mw = message.MessageWriter.init(&f_w);
    try f_mw.write_len_field(1, "status");
    try f_mw.write_varint_field(3, 1);
    try f_mw.write_varint_field(4, 1); // OPTIONAL
    try f_mw.write_varint_field(5, 14); // ENUM
    try f_mw.write_len_field(6, ".Status");
    const f_bytes = f_w.buffered();

    // Message
    var msg_buf: [128]u8 = undefined;
    var msg_w: std.Io.Writer = .fixed(&msg_buf);
    var msg_mw = message.MessageWriter.init(&msg_w);
    try msg_mw.write_len_field(1, "MyMsg");
    try msg_mw.write_len_field(2, f_bytes);
    const msg_bytes = msg_w.buffered();

    // File
    var file_buf: [512]u8 = undefined;
    var file_w: std.Io.Writer = .fixed(&file_buf);
    var file_mw = message.MessageWriter.init(&file_w);
    try file_mw.write_len_field(1, "enum_test.proto");
    try file_mw.write_len_field(12, "proto3");
    try file_mw.write_len_field(4, msg_bytes);
    try file_mw.write_len_field(5, enum_bytes);
    const file_bytes = file_w.buffered();

    // Request
    var req_buf: [1024]u8 = undefined;
    var req_w: std.Io.Writer = .fixed(&req_buf);
    var req_mw = message.MessageWriter.init(&req_w);
    try req_mw.write_len_field(1, "enum_test.proto");
    try req_mw.write_len_field(15, file_bytes);

    const response_bytes = try generate(a, req_w.buffered());

    // Find the generated content
    var resp_iter = message.iterate_fields(response_bytes);
    var generated_content: []const u8 = "";
    while (try resp_iter.next()) |field| {
        if (field.number == 15) {
            var file_iter = message.iterate_fields(field.value.len);
            while (try file_iter.next()) |ff| {
                if (ff.number == 15) generated_content = ff.value.len;
            }
        }
    }

    try expect_contains(generated_content, "pub const Status = enum(i32)");
    try expect_contains(generated_content, "UNKNOWN = 0,");
    try expect_contains(generated_content, "ACTIVE = 1,");
    try expect_contains(generated_content, "pub const MyMsg = struct");
}

test "end-to-end: proto2 with required field" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Required field
    var f_buf: [64]u8 = undefined;
    var f_w: std.Io.Writer = .fixed(&f_buf);
    var f_mw = message.MessageWriter.init(&f_w);
    try f_mw.write_len_field(1, "name");
    try f_mw.write_varint_field(3, 1);
    try f_mw.write_varint_field(4, 2); // REQUIRED
    try f_mw.write_varint_field(5, 9); // STRING

    // Optional field
    var f2_buf: [64]u8 = undefined;
    var f2_w: std.Io.Writer = .fixed(&f2_buf);
    var f2_mw = message.MessageWriter.init(&f2_w);
    try f2_mw.write_len_field(1, "email");
    try f2_mw.write_varint_field(3, 2);
    try f2_mw.write_varint_field(4, 1); // OPTIONAL
    try f2_mw.write_varint_field(5, 9); // STRING

    // Message
    var msg_buf: [256]u8 = undefined;
    var msg_w: std.Io.Writer = .fixed(&msg_buf);
    var msg_mw = message.MessageWriter.init(&msg_w);
    try msg_mw.write_len_field(1, "User");
    try msg_mw.write_len_field(2, f_w.buffered());
    try msg_mw.write_len_field(2, f2_w.buffered());

    // File (proto2 = no syntax field or "proto2")
    var file_buf: [512]u8 = undefined;
    var file_w: std.Io.Writer = .fixed(&file_buf);
    var file_mw = message.MessageWriter.init(&file_w);
    try file_mw.write_len_field(1, "user.proto");
    try file_mw.write_len_field(12, "proto2");
    try file_mw.write_len_field(4, msg_w.buffered());

    // Request
    var req_buf: [1024]u8 = undefined;
    var req_w: std.Io.Writer = .fixed(&req_buf);
    var req_mw = message.MessageWriter.init(&req_w);
    try req_mw.write_len_field(1, "user.proto");
    try req_mw.write_len_field(15, file_w.buffered());

    const response_bytes = try generate(a, req_w.buffered());

    // Find generated content
    var resp_iter = message.iterate_fields(response_bytes);
    var generated_content: []const u8 = "";
    while (try resp_iter.next()) |field| {
        if (field.number == 15) {
            var file_iter = message.iterate_fields(field.value.len);
            while (try file_iter.next()) |ff| {
                if (ff.number == 15) generated_content = ff.value.len;
            }
        }
    }

    try expect_contains(generated_content, "pub const User = struct");
    // Required field should not be optional
    try expect_contains(generated_content, "name: []const u8 = \"\",");
    // Optional field should be nullable
    try expect_contains(generated_content, "email: ?[]const u8 = null,");
}

test "end-to-end: empty request" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Empty request — no files to generate
    const response_bytes = try generate(arena.allocator(), "");

    // Should get a valid response with features but no files
    var resp_iter = message.iterate_fields(response_bytes);
    var file_count: usize = 0;
    while (try resp_iter.next()) |field| {
        if (field.number == 15) file_count += 1;
    }
    try testing.expectEqual(@as(usize, 0), file_count);
}

test "end-to-end: file with package produces correct output path" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Simple message
    var f_buf: [64]u8 = undefined;
    var f_w: std.Io.Writer = .fixed(&f_buf);
    var f_mw = message.MessageWriter.init(&f_w);
    try f_mw.write_len_field(1, "x");
    try f_mw.write_varint_field(3, 1);
    try f_mw.write_varint_field(4, 1);
    try f_mw.write_varint_field(5, 5);

    var msg_buf: [128]u8 = undefined;
    var msg_w: std.Io.Writer = .fixed(&msg_buf);
    var msg_mw = message.MessageWriter.init(&msg_w);
    try msg_mw.write_len_field(1, "Point");
    try msg_mw.write_len_field(2, f_w.buffered());

    var file_buf: [512]u8 = undefined;
    var file_w: std.Io.Writer = .fixed(&file_buf);
    var file_mw = message.MessageWriter.init(&file_w);
    try file_mw.write_len_field(1, "point.proto");
    try file_mw.write_len_field(2, "my.package");
    try file_mw.write_len_field(12, "proto3");
    try file_mw.write_len_field(4, msg_w.buffered());

    var req_buf: [1024]u8 = undefined;
    var req_w: std.Io.Writer = .fixed(&req_buf);
    var req_mw = message.MessageWriter.init(&req_w);
    try req_mw.write_len_field(1, "point.proto");
    try req_mw.write_len_field(15, file_w.buffered());

    const response_bytes = try generate(a, req_w.buffered());

    var resp_iter = message.iterate_fields(response_bytes);
    var generated_name: []const u8 = "";
    while (try resp_iter.next()) |field| {
        if (field.number == 15) {
            var file_iter = message.iterate_fields(field.value.len);
            while (try file_iter.next()) |ff| {
                if (ff.number == 1) generated_name = ff.value.len;
            }
        }
    }
    try testing.expectEqualStrings("my/package.zig", generated_name);
}

test "end-to-end: nested messages" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Inner message field: x int32 = 1
    var inner_f_buf: [64]u8 = undefined;
    var inner_f_w: std.Io.Writer = .fixed(&inner_f_buf);
    var inner_f_mw = message.MessageWriter.init(&inner_f_w);
    try inner_f_mw.write_len_field(1, "x");
    try inner_f_mw.write_varint_field(3, 1);
    try inner_f_mw.write_varint_field(4, 1);
    try inner_f_mw.write_varint_field(5, 5);

    // Inner message
    var inner_buf: [128]u8 = undefined;
    var inner_w: std.Io.Writer = .fixed(&inner_buf);
    var inner_mw = message.MessageWriter.init(&inner_w);
    try inner_mw.write_len_field(1, "Inner");
    try inner_mw.write_len_field(2, inner_f_w.buffered());

    // Outer field referencing Inner
    var outer_f_buf: [64]u8 = undefined;
    var outer_f_w: std.Io.Writer = .fixed(&outer_f_buf);
    var outer_f_mw = message.MessageWriter.init(&outer_f_w);
    try outer_f_mw.write_len_field(1, "inner");
    try outer_f_mw.write_varint_field(3, 1);
    try outer_f_mw.write_varint_field(4, 1);
    try outer_f_mw.write_varint_field(5, 11); // MESSAGE
    try outer_f_mw.write_len_field(6, ".Outer.Inner");

    // Outer message
    var outer_buf: [256]u8 = undefined;
    var outer_w: std.Io.Writer = .fixed(&outer_buf);
    var outer_mw = message.MessageWriter.init(&outer_w);
    try outer_mw.write_len_field(1, "Outer");
    try outer_mw.write_len_field(2, outer_f_w.buffered());
    try outer_mw.write_len_field(3, inner_w.buffered()); // nested_type

    // File
    var file_buf: [512]u8 = undefined;
    var file_w: std.Io.Writer = .fixed(&file_buf);
    var file_mw = message.MessageWriter.init(&file_w);
    try file_mw.write_len_field(1, "nested.proto");
    try file_mw.write_len_field(12, "proto3");
    try file_mw.write_len_field(4, outer_w.buffered());

    // Request
    var req_buf: [1024]u8 = undefined;
    var req_w: std.Io.Writer = .fixed(&req_buf);
    var req_mw = message.MessageWriter.init(&req_w);
    try req_mw.write_len_field(1, "nested.proto");
    try req_mw.write_len_field(15, file_w.buffered());

    const response_bytes = try generate(a, req_w.buffered());

    var resp_iter = message.iterate_fields(response_bytes);
    var generated_content: []const u8 = "";
    while (try resp_iter.next()) |field| {
        if (field.number == 15) {
            var file_iter = message.iterate_fields(field.value.len);
            while (try file_iter.next()) |ff| {
                if (ff.number == 15) generated_content = ff.value.len;
            }
        }
    }

    try expect_contains(generated_content, "pub const Outer = struct");
    try expect_contains(generated_content, "pub const Inner = struct");
}

test "end-to-end: service generation" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Method
    var method_buf: [128]u8 = undefined;
    var method_w: std.Io.Writer = .fixed(&method_buf);
    var method_mw = message.MessageWriter.init(&method_w);
    try method_mw.write_len_field(1, "GetUser");
    try method_mw.write_len_field(2, ".UserRequest");
    try method_mw.write_len_field(3, ".UserResponse");

    // Service
    var svc_buf: [256]u8 = undefined;
    var svc_w: std.Io.Writer = .fixed(&svc_buf);
    var svc_mw = message.MessageWriter.init(&svc_w);
    try svc_mw.write_len_field(1, "UserService");
    try svc_mw.write_len_field(2, method_w.buffered());

    // File
    var file_buf: [512]u8 = undefined;
    var file_w: std.Io.Writer = .fixed(&file_buf);
    var file_mw = message.MessageWriter.init(&file_w);
    try file_mw.write_len_field(1, "service.proto");
    try file_mw.write_len_field(12, "proto3");
    try file_mw.write_len_field(6, svc_w.buffered());

    // Request
    var req_buf: [1024]u8 = undefined;
    var req_w: std.Io.Writer = .fixed(&req_buf);
    var req_mw = message.MessageWriter.init(&req_w);
    try req_mw.write_len_field(1, "service.proto");
    try req_mw.write_len_field(15, file_w.buffered());

    const response_bytes = try generate(a, req_w.buffered());

    var resp_iter = message.iterate_fields(response_bytes);
    var generated_content: []const u8 = "";
    while (try resp_iter.next()) |field| {
        if (field.number == 15) {
            var file_iter = message.iterate_fields(field.value.len);
            while (try file_iter.next()) |ff| {
                if (ff.number == 15) generated_content = ff.value.len;
            }
        }
    }

    try expect_contains(generated_content, "pub const UserService = struct");
    try expect_contains(generated_content, "GetUser");
}
