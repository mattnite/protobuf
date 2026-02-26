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
            // Could be enum or message. Messages are always optional.
            // Enums: proto3 implicit = E = .FIRST, proto3 optional = ?E = null
            // For named types, we don't know if it's enum or message from AST alone.
            // Convention: we generate as if message (always ?T = null) for non-repeated.
            // The file-level generator will know the actual type from the linker.
            // For now, generate conservatively:
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
                    // Proto3 implicit for named type: could be message (?T) or enum (E)
                    // Default to ?T (message) - the codegen caller can differentiate
                    try e.print("{f}: ?{s} = null,\n", .{ escaped, name });
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
        };
        try e.print("{f}: std.StringArrayHashMapUnmanaged({s}) = .empty,\n", .{ escaped, value_type });
    } else {
        // std.AutoArrayHashMapUnmanaged(K, V)
        const key_type = types.map_key_zig_type(map_field.key_type);
        const value_type = switch (map_field.value_type) {
            .scalar => |s| types.scalar_zig_type(s),
            .named => |n| n,
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
                    try e.print("try mw.write_len_field({d}, sub_size);\n", .{num});
                    try e.print("try item.encode(writer);\n", .{});
                    try e.close_brace_nosemi();
                },
                .optional, .implicit => {
                    try e.print("if (self.{f}) |sub|", .{escaped});
                    try e.open_brace();
                    try e.print("const sub_size = sub.calc_size();\n", .{});
                    try e.print("try mw.write_len_field({d}, sub_size);\n", .{num});
                    try e.print("try sub.encode(writer);\n", .{});
                    try e.close_brace_nosemi();
                },
                .required => {
                    try e.print("{{\n", .{});
                    e.indent_level += 1;
                    try e.print("const sub_size = self.{f}.calc_size();\n", .{escaped});
                    try e.print("try mw.write_len_field({d}, sub_size);\n", .{num});
                    try e.print("try self.{f}.encode(writer);\n", .{escaped});
                    e.indent_level -= 1;
                    try e.print("}}\n", .{});
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
    _ = val;
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
    try e.print("try mw.write_len_field({d}, entry_size);\n", .{num});
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
            try e.print("try mw.write_len_field(2, val_size);\n", .{});
            try e.print("try val.encode(writer);\n", .{});
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
                try e.print("try mw.write_len_field({d}, sub_size);\n", .{num});
                try e.print("try sub.encode(writer);\n", .{});
                try e.close_brace_nosemi();
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
                    try e.print("if (self.{f}) |v| ", .{escaped});
                    try emit_size_scalar_optional(e, s, size_fn, field.number);
                },
                .required => {
                    _ = syntax;
                    try emit_size_scalar_required(e, escaped, s, size_fn, field.number);
                },
                .repeated => {
                    try e.print("for (self.{f}) |item| ", .{escaped});
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

    try e.close_brace(); // switch
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
                    try e.print_raw("", .{});
                    try e.open_brace();
                    if (s == .string or s == .bytes) {
                        try e.print("var list = std.ArrayList({s}).init(allocator);\n", .{types.scalar_zig_type(s)});
                        try e.print("try list.append(try allocator.dupe(u8, field.value.len));\n", .{});
                        try e.print("result.{f} = try list.toOwnedSlice();\n", .{escaped});
                    } else {
                        try e.print("_ = @as(u8, 0); // TODO: repeated scalar accumulation\n", .{});
                    }
                    try e.close_brace_nosemi();
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
                    try e.print("_ = @as(u8, 0); // TODO: repeated message accumulation\n", .{});
                    try e.close_brace_nosemi();
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
    try e.close_brace(); // switch
    try e.close_brace_nosemi(); // while

    try e.print("try self.{f}.put(allocator, entry_key, entry_val);\n", .{escaped});
    try e.close_brace_nosemi();
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
