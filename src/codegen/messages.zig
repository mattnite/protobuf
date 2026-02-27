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

pub fn emit_message(e: *Emitter, msg: ast.Message, syntax: ast.Syntax) !void {
    try e.print("pub const {s} = struct", .{msg.name});
    try e.open_brace();

    // Nested enums first
    for (msg.nested_enums) |nested_enum| {
        try enums.emit_enum(e, nested_enum, syntax);
        try e.blank_line();
    }

    // Nested messages
    for (msg.nested_messages) |nested_msg| {
        try emit_message(e, nested_msg, syntax);
        try e.blank_line();
    }

    // Oneof union types
    for (msg.oneofs) |oneof| {
        try emit_oneof_type(e, oneof, syntax);
        try e.blank_line();
    }

    // Regular fields
    for (msg.fields) |field| {
        try emit_field(e, field, syntax);
    }

    // Map fields
    for (msg.maps) |map_field| {
        try emit_map_field(e, map_field);
    }

    // Oneof fields (the ?UnionType = null field on the struct)
    for (msg.oneofs) |oneof| {
        const escaped = types.escape_zig_keyword(oneof.name);
        try e.print("{f}: ?", .{escaped});
        try emit_oneof_type_name(e, oneof);
        try e.print_raw(" = null,\n", .{});
    }

    // Unknown fields
    try e.print("_unknown_fields: []const u8 = \"\",\n", .{});

    // Methods
    try e.blank_line();
    try emit_encode_method(e, msg, syntax);
    try e.blank_line();
    try emit_calc_size_method(e, msg, syntax);
    try e.blank_line();
    try emit_decode_method(e, msg, syntax);
    try e.blank_line();
    try emit_deinit_method(e, msg, syntax);
    try e.blank_line();
    try emit_to_json_method(e, msg, syntax);

    try e.close_brace();
}

fn emit_field(e: *Emitter, field: ast.Field, _: ast.Syntax) !void {
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
                    // Proto2 required: non-nullable with zero default
                    try e.print("{f}: {s} = {s},\n", .{ escaped, types.scalar_zig_type(s), types.scalar_default_value(s) });
                },
                .implicit => {
                    // Proto3 implicit: non-nullable with zero default
                    try e.print("{f}: {s} = {s},\n", .{ escaped, types.scalar_zig_type(s), types.scalar_default_value(s) });
                },
            }
        },
        .named => |name| {
            // Message type: always optional for implicit/optional labels.
            switch (field.label) {
                .repeated => {
                    try e.print("{f}: []const {s} = &.{{}},\n", .{ escaped, name });
                },
                .optional => {
                    try e.print("{f}: ?{s} = null,\n", .{ escaped, name });
                },
                .required => {
                    try e.print("{f}: {s} = undefined,\n", .{ escaped, name });
                },
                .implicit => {
                    try e.print("{f}: ?{s} = null,\n", .{ escaped, name });
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
                    try e.print("{f}: {s} = @enumFromInt(0),\n", .{ escaped, name });
                },
                .implicit => {
                    try e.print("{f}: {s} = @enumFromInt(0),\n", .{ escaped, name });
                },
            }
        },
    }
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
    try e.print("pub fn encode(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    try e.print("const mw = message.MessageWriter.init(writer);\n", .{});

    // Collect all field-like things and sort by number
    const items = try collect_all_fields(e.allocator, msg);
    defer e.allocator.free(items);

    for (items) |item| {
        switch (item) {
            .field => |f| try emit_encode_field(e, f, syntax),
            .map => |m| try emit_encode_map(e, m),
            .oneof => |o| try emit_encode_oneof(e, o),
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
                    } else if (s == .double or s == .float) {
                        try e.print("if (self.{f} != 0) try mw.{s}({d}, @bitCast(self.{f}));\n", .{ escaped, write_method, num, escaped });
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
                    _ = syntax;
                    try emit_encode_scalar_self(e, escaped, s, write_method, num);
                },
                .repeated => {
                    try e.print("for (self.{f}) |item| ", .{escaped});
                    try emit_encode_scalar_value(e, "item", s, write_method, num);
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
                    try e.print("for (self.{f}) |item| try mw.write_varint_field({d}, @as(u64, @bitCast(@as(i64, @intFromEnum(item)))));\n", .{ escaped, num });
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

// ── Calc Size Method ──────────────────────────────────────────────────

fn emit_calc_size_method(e: *Emitter, msg: ast.Message, syntax: ast.Syntax) !void {
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
                    } else if (s == .double or s == .float) {
                        try e.print("if (self.{f} != 0) size += message.{s}({d});\n", .{ escaped, size_fn, field.number });
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
                    _ = syntax;
                    try emit_size_scalar_required(e, escaped, s, size_fn, field.number);
                },
                .repeated => {
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
                    try e.print("for (self.{f}) |item| size += message.varint_field_size({d}, @as(u64, @bitCast(@as(i64, @intFromEnum(item)))));\n", .{ escaped, field.number });
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

fn emit_size_map(e: *Emitter, map_field: ast.MapField) !void {
    const escaped = types.escape_zig_keyword(map_field.name);
    const num = map_field.number;

    if (types.is_string_key(map_field.key_type)) {
        try e.print("for (self.{f}.keys(), self.{f}.values()) |key, val|", .{ escaped, escaped });
    } else {
        try e.print("for (self.{f}.keys(), self.{f}.values()) |key, val|", .{ escaped, escaped });
    }
    try e.open_brace();
    try e.print("var entry_size: usize = 0;\n", .{});
    try emit_map_entry_size_key(e, map_field.key_type);
    try emit_map_entry_size_value(e, map_field.value_type);
    try e.print("size += message.len_field_size({d}, entry_size);\n", .{num});
    try e.close_brace_nosemi();
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

// ── Decode Method ─────────────────────────────────────────────────────

fn emit_decode_method(e: *Emitter, msg: ast.Message, syntax: ast.Syntax) !void {
    try e.print("pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This()", .{});
    try e.open_brace();
    try e.print("var result: @This() = .{{}};\n", .{});
    try e.print("var iter = message.iterate_fields(bytes);\n", .{});
    try e.print("while (try iter.next()) |field|", .{});
    try e.open_brace();
    try e.print("switch (field.number)", .{});
    try e.open_brace();

    // Regular fields
    for (msg.fields) |field| {
        try emit_decode_field_case(e, field, syntax);
    }

    // Map fields
    for (msg.maps) |map_field| {
        try emit_decode_map_case(e, map_field);
    }

    // Oneof fields
    for (msg.oneofs) |oneof| {
        for (oneof.fields) |field| {
            try emit_decode_oneof_field_case(e, field, oneof);
        }
    }

    // else => unknown fields (skip for now)
    try e.print("else => {{}},\n", .{});

    try e.close_brace_nosemi(); // switch
    try e.close_brace_nosemi(); // while
    try e.print("return result;\n", .{});
    try e.close_brace_nosemi(); // fn
}

fn emit_decode_field_case(e: *Emitter, field: ast.Field, _: ast.Syntax) !void {
    const escaped = types.escape_zig_keyword(field.name);
    const num = field.number;

    try e.print("{d} =>", .{num});

    switch (field.type_name) {
        .scalar => |s| {
            switch (field.label) {
                .implicit, .required => {
                    if (s == .string or s == .bytes) {
                        try e.print_raw(" result.{f} = try allocator.dupe(u8, {s}),\n", .{ escaped, types.scalar_decode_expr(s) });
                    } else {
                        try e.print_raw(" result.{f} = {s},\n", .{ escaped, types.scalar_decode_expr(s) });
                    }
                },
                .optional => {
                    if (s == .string or s == .bytes) {
                        try e.print_raw(" result.{f} = try allocator.dupe(u8, {s}),\n", .{ escaped, types.scalar_decode_expr(s) });
                    } else {
                        try e.print_raw(" result.{f} = {s},\n", .{ escaped, types.scalar_decode_expr(s) });
                    }
                },
                .repeated => {
                    if (types.is_packable_scalar(s)) {
                        // Handle both packed (LEN) and individual element encoding
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
                        try e.print("else => {{}},\n", .{});
                        // Close switch
                        e.indent_level -= 1;
                        try e.print("}},\n", .{});
                    } else {
                        // string/bytes: always LEN wire type, no packed encoding
                        try e.print_raw("", .{});
                        try e.open_brace();
                        try e.print("const old = result.{f};\n", .{escaped});
                        try e.print("const new = try allocator.alloc({s}, old.len + 1);\n", .{types.scalar_zig_type(s)});
                        try e.print("@memcpy(new[0..old.len], old);\n", .{});
                        try e.print("new[old.len] = try allocator.dupe(u8, field.value.len);\n", .{});
                        try e.print("if (old.len > 0) allocator.free(old);\n", .{});
                        try e.print("result.{f} = new;\n", .{escaped});
                        e.indent_level -= 1;
                        try e.print("}},\n", .{});
                    }
                },
            }
        },
        .named => {
            switch (field.label) {
                .optional, .implicit => {
                    try e.print_raw(" result.{f} = try @TypeOf(result.{f}.?).decode(allocator, field.value.len),\n", .{ escaped, escaped });
                },
                .required => {
                    try e.print_raw(" result.{f} = try @TypeOf(result.{f}).decode(allocator, field.value.len),\n", .{ escaped, escaped });
                },
                .repeated => {
                    try e.print_raw("", .{});
                    try e.open_brace();
                    try e.print("const old = result.{f};\n", .{escaped});
                    try e.print("const new = try allocator.alloc(@TypeOf(old[0]), old.len + 1);\n", .{});
                    try e.print("@memcpy(new[0..old.len], old);\n", .{});
                    try e.print("new[old.len] = try @TypeOf(old[0]).decode(allocator, field.value.len);\n", .{});
                    try e.print("if (old.len > 0) allocator.free(old);\n", .{});
                    try e.print("result.{f} = new;\n", .{escaped});
                    e.indent_level -= 1;
                    try e.print("}},\n", .{});
                },
            }
        },
        .enum_ref => {
            const decode_expr = "@enumFromInt(@as(i32, @bitCast(@as(u32, @truncate(field.value.varint)))))";
            const packed_decode_expr = "@enumFromInt(@as(i32, @bitCast(@as(u32, @truncate(v)))))";
            switch (field.label) {
                .implicit, .required => {
                    try e.print_raw(" result.{f} = {s},\n", .{ escaped, decode_expr });
                },
                .optional => {
                    try e.print_raw(" result.{f} = {s},\n", .{ escaped, decode_expr });
                },
                .repeated => {
                    // Handle both packed (LEN) and individual varint encoding
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
                    try e.print("else => {{}},\n", .{});
                    // Close switch
                    e.indent_level -= 1;
                    try e.print("}},\n", .{});
                },
            }
        },
    }
}

fn emit_decode_map_case(e: *Emitter, map_field: ast.MapField) !void {
    const escaped = types.escape_zig_keyword(map_field.name);
    const num = map_field.number;

    try e.print("{d} =>", .{num});
    try e.open_brace();
    try e.print("var entry_iter = message.iterate_fields(field.value.len);\n", .{});

    // Declare key/value temporaries
    try emit_decode_map_key_decl(e, map_field.key_type);
    try emit_decode_map_value_decl(e, map_field.value_type);

    try e.print("while (try entry_iter.next()) |entry|", .{});
    try e.open_brace();
    try e.print("switch (entry.number)", .{});
    try e.open_brace();
    try emit_decode_map_key_case(e, map_field.key_type);
    try emit_decode_map_value_case(e, map_field.value_type);
    try e.print("else => {{}},\n", .{});
    try e.close_brace_nosemi(); // switch
    try e.close_brace_nosemi(); // while

    try e.print("try result.{f}.put(allocator, entry_key, entry_val);\n", .{escaped});
    e.indent_level -= 1;
    try e.print("}},\n", .{});
}

fn emit_decode_map_key_decl(e: *Emitter, key_type: ast.ScalarType) !void {
    if (key_type == .string) {
        try e.print("var entry_key: []const u8 = \"\";\n", .{});
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

fn emit_decode_map_key_case(e: *Emitter, key_type: ast.ScalarType) !void {
    if (key_type == .string) {
        try e.print("1 => entry_key = try allocator.dupe(u8, entry.value.len),\n", .{});
    } else {
        const decode_expr = types.scalar_decode_expr(key_type);
        // Replace "field." with "entry." in decode expressions
        _ = decode_expr;
        try e.print("1 => entry_key = {s},\n", .{scalar_decode_entry_expr(key_type)});
    }
}

fn emit_decode_map_value_case(e: *Emitter, value_type: ast.TypeRef) !void {
    switch (value_type) {
        .scalar => |s| {
            if (s == .string or s == .bytes) {
                try e.print("2 => entry_val = try allocator.dupe(u8, entry.value.len),\n", .{});
            } else {
                try e.print("2 => entry_val = {s},\n", .{scalar_decode_entry_expr(s)});
            }
        },
        .named => |name| {
            try e.print("2 => entry_val = try {s}.decode(allocator, entry.value.len),\n", .{name});
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

fn emit_decode_oneof_field_case(e: *Emitter, field: ast.Field, oneof: ast.Oneof) !void {
    const field_escaped = types.escape_zig_keyword(field.name);
    const oneof_escaped = types.escape_zig_keyword(oneof.name);
    const num = field.number;

    try e.print("{d} => ", .{num});
    switch (field.type_name) {
        .scalar => |s| {
            if (s == .string or s == .bytes) {
                try e.print_raw("result.{f} = .{{ .{f} = try allocator.dupe(u8, field.value.len) }},\n", .{ oneof_escaped, field_escaped });
            } else {
                try e.print_raw("result.{f} = .{{ .{f} = {s} }},\n", .{ oneof_escaped, field_escaped, types.scalar_decode_expr(s) });
            }
        },
        .named => |name| {
            try e.print_raw("result.{f} = .{{ .{f} = try {s}.decode(allocator, field.value.len) }},\n", .{ oneof_escaped, field_escaped, name });
        },
        .enum_ref => {
            try e.print_raw("result.{f} = .{{ .{f} = @enumFromInt(@as(i32, @bitCast(@as(u32, @truncate(field.value.varint))))) }},\n", .{ oneof_escaped, field_escaped });
        },
    }
}

// ── Deinit Method ─────────────────────────────────────────────────────

fn emit_deinit_method(e: *Emitter, msg: ast.Message, _: ast.Syntax) !void {
    try e.print("pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void", .{});
    try e.open_brace();

    // Regular fields
    for (msg.fields) |field| {
        try emit_deinit_field(e, field);
    }

    // Map fields
    for (msg.maps) |map_field| {
        try emit_deinit_map(e, map_field);
    }

    // Oneof fields
    for (msg.oneofs) |oneof| {
        try emit_deinit_oneof(e, oneof);
    }

    // Unknown fields
    try e.print("if (self._unknown_fields.len > 0) allocator.free(self._unknown_fields);\n", .{});

    try e.close_brace_nosemi();
}

fn emit_deinit_field(e: *Emitter, field: ast.Field) !void {
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
        .named => {
            switch (field.label) {
                .optional, .implicit => {
                    try e.print("if (self.{f}) |*sub| sub.deinit(allocator);\n", .{escaped});
                },
                .required => {
                    try e.print("self.{f}.deinit(allocator);\n", .{escaped});
                },
                .repeated => {
                    try e.print("for (self.{f}) |*item| item.deinit(allocator);\n", .{escaped});
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

// ── JSON Serialization Method ──────────────────────────────────────────

fn emit_to_json_method(e: *Emitter, msg: ast.Message, syntax: ast.Syntax) !void {
    try e.print("pub fn to_json(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void", .{});
    try e.open_brace();
    try e.print("try json.write_object_start(writer);\n", .{});
    try e.print("var first = true;\n", .{});

    const items = try collect_all_fields(e.allocator, msg);
    defer e.allocator.free(items);

    for (items) |item| {
        switch (item) {
            .field => |f| try emit_json_field(e, f, syntax),
            .map => |m| try emit_json_map(e, m),
            .oneof => |o| try emit_json_oneof(e, o),
        }
    }

    try e.print("try json.write_object_end(writer);\n", .{});
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

fn emit_json_field(e: *Emitter, field: ast.Field, syntax: ast.Syntax) !void {
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
                    } else if (s == .double or s == .float) {
                        try e.print("if (self.{f} != 0)", .{escaped});
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
        .named => {
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
                    try e.print("try item.to_json(writer);\n", .{});
                    try e.close_brace_nosemi();
                    try e.print("try json.write_array_end(writer);\n", .{});
                    try e.close_brace_nosemi();
                },
                .optional, .implicit => {
                    try e.print("if (self.{f}) |sub|", .{escaped});
                    try e.open_brace();
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    try e.print("try sub.to_json(writer);\n", .{});
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
            }
        },
        .enum_ref => {
            switch (field.label) {
                .implicit => {
                    try e.print("if (@intFromEnum(self.{f}) != 0)", .{escaped});
                    try e.open_brace();
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    try e.print("try json.write_int(writer, @as(i64, @intFromEnum(self.{f})));\n", .{escaped});
                    try e.close_brace_nosemi();
                },
                .optional => {
                    try e.print("if (self.{f}) |v|", .{escaped});
                    try e.open_brace();
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    try e.print("try json.write_int(writer, @as(i64, @intFromEnum(v)));\n", .{});
                    try e.close_brace_nosemi();
                },
                .required => {
                    try e.print("{{\n", .{});
                    e.indent_level += 1;
                    try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                    try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                    try e.print("try json.write_int(writer, @as(i64, @intFromEnum(self.{f})));\n", .{escaped});
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
                    try e.print("try json.write_int(writer, @as(i64, @intFromEnum(item)));\n", .{});
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
        // Convert numeric key to string representation
        try e.print("try writer.writeByte('\"');\n", .{});
        try e.print("try writer.print(\"{{d}}\", .{{key}});\n", .{});
        try e.print("try writer.writeAll(\"\\\":\");\n", .{});
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

fn emit_json_oneof(e: *Emitter, oneof: ast.Oneof) !void {
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
            .named => {
                try e.print(".{f} => |sub|", .{field_escaped});
                try e.open_brace();
                try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                try e.print("try sub.to_json(writer);\n", .{});
                try e.close_brace_comma();
            },
            .enum_ref => {
                try e.print(".{f} => |v|", .{field_escaped});
                try e.open_brace();
                try e.print("first = try json.write_field_sep(writer, first);\n", .{});
                try e.print("try json.write_field_name(writer, \"{s}\");\n", .{jname});
                try e.print("try json.write_int(writer, @as(i64, @intFromEnum(v)));\n", .{});
                try e.close_brace_comma();
            },
        }
    }
    try e.close_brace();
}

// ── Field Collection Helper ───────────────────────────────────────────

const FieldItem = union(enum) {
    field: ast.Field,
    map: ast.MapField,
    oneof: ast.Oneof,
};

fn collect_all_fields(allocator: std.mem.Allocator, msg: ast.Message) ![]FieldItem {
    const total = msg.fields.len + msg.maps.len + msg.oneofs.len;
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
    };
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

const loc = ast.SourceLocation{ .file = "", .line = 0, .column = 0 };

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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto2);
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

    try emit_message(&e, msg, .proto3);
    const output = e.get_output();
    try expect_output_contains(output, "pub const Value = union(enum)");
    try expect_output_contains(output, "        text: []const u8,");
    try expect_output_contains(output, "        count: i32,");
    try expect_output_contains(output, "    value: ?Value = null,");
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
    const output = e.get_output();
    try expect_output_contains(output, "pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {");
    try expect_output_contains(output, "var result: @This() = .{};");
    try expect_output_contains(output, "var iter = message.iterate_fields(bytes);");
    try expect_output_contains(output, "switch (field.number) {");
    try expect_output_contains(output, "1 => result.name = try allocator.dupe(u8, field.value.len),");
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
    const output = e.get_output();
    // Encode: switch on oneof variants
    try expect_output_contains(output, "if (self.payload) |oneof_val| switch (oneof_val)");
    try expect_output_contains(output, ".text => |v| try mw.write_len_field(1, v),");
    // Decode: oneof field assignments
    try expect_output_contains(output, "1 => result.payload = .{ .text = try allocator.dupe(u8, field.value.len) },");
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
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

    try emit_message(&e, msg, .proto3);
    const output = e.get_output();
    // The to_json should switch on oneof
    try expect_output_contains(output, "if (self.kind) |oneof_val| switch (oneof_val) {");
    try expect_output_contains(output, ".text => |v| {");
    try expect_output_contains(output, "try json.write_string(writer, v);");
    try expect_output_contains(output, ".sub_msg => |sub| {");
    try expect_output_contains(output, "try sub.to_json(writer);");
}
