const std = @import("std");
const testing = std.testing;
const ast = @import("../proto/ast.zig");

const ScalarType = ast.ScalarType;

pub fn scalar_zig_type(s: ScalarType) []const u8 {
    return switch (s) {
        .double => "f64",
        .float => "f32",
        .int32 => "i32",
        .int64 => "i64",
        .uint32 => "u32",
        .uint64 => "u64",
        .sint32 => "i32",
        .sint64 => "i64",
        .fixed32 => "u32",
        .fixed64 => "u64",
        .sfixed32 => "i32",
        .sfixed64 => "i64",
        .bool => "bool",
        .string => "[]const u8",
        .bytes => "[]const u8",
    };
}

pub fn scalar_wire_type(s: ScalarType) []const u8 {
    return switch (s) {
        .double => ".i64",
        .float => ".i32",
        .int32, .int64, .uint32, .uint64, .sint32, .sint64, .bool => ".varint",
        .fixed32, .sfixed32 => ".i32",
        .fixed64, .sfixed64 => ".i64",
        .string, .bytes => ".len",
    };
}

pub fn scalar_default_value(s: ScalarType) []const u8 {
    return switch (s) {
        .double, .float => "0",
        .int32, .int64, .sint32, .sint64, .sfixed32, .sfixed64 => "0",
        .uint32, .uint64, .fixed32, .fixed64 => "0",
        .bool => "false",
        .string, .bytes => "\"\"",
    };
}

pub fn scalar_encode_fn(s: ScalarType) []const u8 {
    return switch (s) {
        .double => "encode_double",
        .float => "encode_float",
        .int32 => "encode_int32",
        .int64 => "encode_int64",
        .uint32 => "encode_uint32",
        .uint64 => "encode_varint",
        .sint32 => "encode_sint32",
        .sint64 => "encode_sint64",
        .fixed32 => "encode_fixed32",
        .fixed64 => "encode_fixed64",
        .sfixed32 => "encode_fixed32",
        .sfixed64 => "encode_fixed64",
        .bool => "encode_bool",
        .string, .bytes => "encode_len",
    };
}

/// Returns the MessageWriter field-write method name for this scalar type.
pub fn scalar_write_method(s: ScalarType) []const u8 {
    return switch (s) {
        .double, .fixed64, .sfixed64 => "write_i64_field",
        .float, .fixed32, .sfixed32 => "write_i32_field",
        .int32, .int64, .uint32, .uint64, .sint32, .sint64, .bool => "write_varint_field",
        .string, .bytes => "write_len_field",
    };
}

/// Returns the expression to convert a Zig value to the wire representation
/// for use with MessageWriter.write_*_field calls.
pub fn scalar_to_wire_expr(s: ScalarType, value_expr: []const u8, buf: []u8) []const u8 {
    return switch (s) {
        .int32 => std.fmt.bufPrint(buf, "@bitCast(@as(i64, {s}))", .{value_expr}) catch unreachable,
        .int64 => std.fmt.bufPrint(buf, "@bitCast({s})", .{value_expr}) catch unreachable,
        .uint32 => std.fmt.bufPrint(buf, "@as(u64, {s})", .{value_expr}) catch unreachable,
        .uint64 => value_expr,
        .sint32 => std.fmt.bufPrint(buf, "encoding.zigzag_encode({s})", .{value_expr}) catch unreachable,
        .sint64 => std.fmt.bufPrint(buf, "encoding.zigzag_encode_64({s})", .{value_expr}) catch unreachable,
        .bool => std.fmt.bufPrint(buf, "@intFromBool({s})", .{value_expr}) catch unreachable,
        .double => std.fmt.bufPrint(buf, "@bitCast({s})", .{value_expr}) catch unreachable,
        .float => std.fmt.bufPrint(buf, "@bitCast({s})", .{value_expr}) catch unreachable,
        .fixed32, .sfixed32 => std.fmt.bufPrint(buf, "@bitCast({s})", .{value_expr}) catch unreachable,
        .fixed64, .sfixed64 => std.fmt.bufPrint(buf, "@bitCast({s})", .{value_expr}) catch unreachable,
        .string, .bytes => value_expr,
    };
}

/// Returns the size calculation expression for a scalar field.
/// For varint-based fields, size depends on value; for fixed/len, it's static or len-based.
pub fn scalar_size_fn(s: ScalarType) []const u8 {
    return switch (s) {
        .double, .fixed64, .sfixed64 => "i64_field_size",
        .float, .fixed32, .sfixed32 => "i32_field_size",
        .int32, .int64, .uint32, .uint64, .sint32, .sint64, .bool => "varint_field_size",
        .string, .bytes => "len_field_size",
    };
}

/// Returns the expression to decode a scalar from a FieldValue.
pub fn scalar_decode_expr(s: ScalarType) []const u8 {
    return switch (s) {
        .int32 => "@bitCast(@as(u32, @truncate(field.value.varint)))",
        .int64 => "@bitCast(field.value.varint)",
        .uint32 => "@truncate(field.value.varint)",
        .uint64 => "field.value.varint",
        .sint32 => "encoding.zigzag_decode(@truncate(field.value.varint))",
        .sint64 => "encoding.zigzag_decode_64(field.value.varint)",
        .bool => "field.value.varint != 0",
        .double => "@bitCast(field.value.i64)",
        .float => "@bitCast(field.value.i32)",
        .fixed32 => "field.value.i32",
        .fixed64 => "field.value.i64",
        .sfixed32 => "@bitCast(field.value.i32)",
        .sfixed64 => "@bitCast(field.value.i64)",
        .string, .bytes => "field.value.len",
    };
}

/// Decode expression for packed encoding, where `v` is the raw value from a packed iterator.
pub fn scalar_packed_decode_expr(s: ScalarType) []const u8 {
    return switch (s) {
        .int32 => "@bitCast(@as(u32, @truncate(v)))",
        .int64 => "@bitCast(v)",
        .uint32 => "@truncate(v)",
        .uint64 => "v",
        .sint32 => "encoding.zigzag_decode(@truncate(v))",
        .sint64 => "encoding.zigzag_decode_64(v)",
        .bool => "v != 0",
        .double => "@bitCast(v)",
        .float => "@bitCast(v)",
        .fixed32 => "v",
        .fixed64 => "v",
        .sfixed32 => "@bitCast(v)",
        .sfixed64 => "@bitCast(v)",
        .string, .bytes => unreachable,
    };
}

/// The packed iterator type name for a given scalar type.
pub fn scalar_packed_iterator(s: ScalarType) []const u8 {
    return switch (s) {
        .int32, .int64, .uint32, .uint64, .sint32, .sint64, .bool => "message.PackedVarintIterator",
        .fixed32, .sfixed32, .float => "message.PackedFixed32Iterator",
        .fixed64, .sfixed64, .double => "message.PackedFixed64Iterator",
        .string, .bytes => unreachable,
    };
}

/// The wire type variant name for individual (non-packed) encoding of a scalar.
pub fn scalar_wire_variant(s: ScalarType) []const u8 {
    return switch (s) {
        .int32, .int64, .uint32, .uint64, .sint32, .sint64, .bool => ".varint",
        .fixed32, .sfixed32, .float => ".i32",
        .fixed64, .sfixed64, .double => ".i64",
        .string, .bytes => ".len",
    };
}

pub fn is_packable_scalar(s: ScalarType) bool {
    return s != .string and s != .bytes;
}

const zig_keywords = [_][]const u8{
    "addrspace",  "align",      "allowzero", "and",        "anyframe",
    "anytype",    "asm",        "async",     "await",      "break",
    "callconv",   "catch",      "comptime",  "const",      "continue",
    "defer",      "else",       "enum",      "errdefer",   "error",
    "export",     "extern",     "false",     "fn",         "for",
    "if",         "inline",     "linksection",             "noalias",
    "nosuspend",  "null",       "opaque",    "or",         "orelse",
    "packed",     "pub",        "resume",    "return",     "struct",
    "suspend",    "switch",     "test",      "threadlocal","true",
    "try",        "type",       "undefined", "union",      "unreachable",
    "var",        "volatile",   "while",
};

pub fn escape_zig_keyword(name: []const u8) EscapedName {
    for (zig_keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) {
            return .{ .escaped = true, .name = name };
        }
    }
    // Also escape names starting with underscore (Zig reserves _)
    if (name.len > 0 and name[0] == '_') {
        return .{ .escaped = true, .name = name };
    }
    return .{ .escaped = false, .name = name };
}

pub const EscapedName = struct {
    escaped: bool,
    name: []const u8,

    pub fn format(self: EscapedName, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.escaped) {
            try writer.print("@\"{s}\"", .{self.name});
        } else {
            try writer.writeAll(self.name);
        }
    }
};

pub fn map_key_zig_type(s: ScalarType) []const u8 {
    return scalar_zig_type(s);
}

/// Returns the map container type string for a map field.
/// For string keys: std.StringArrayHashMapUnmanaged(V)
/// For int keys: std.AutoArrayHashMapUnmanaged(K, V)
pub fn is_string_key(key_type: ScalarType) bool {
    return key_type == .string;
}

/// Converts a proto snake_case name to lowerCamelCase for JSON field names.
/// E.g. "my_field_name" -> "myFieldName", "name" -> "name", "_foo" -> "Foo"
pub fn snake_to_lower_camel(name: []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    var capitalize_next = false;
    for (name) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else {
            if (len >= buf.len) break;
            if (capitalize_next) {
                buf[len] = std.ascii.toUpper(c);
                capitalize_next = false;
            } else {
                buf[len] = c;
            }
            len += 1;
        }
    }
    return buf[0..len];
}

/// Returns the json.write_* function name for a scalar type.
pub fn scalar_json_write_fn(s: ScalarType) []const u8 {
    return switch (s) {
        .double, .float => "write_float",
        .int32, .sint32, .uint32, .fixed32, .sfixed32 => "write_int",
        .int64, .sint64, .sfixed64 => "write_int_string",
        .uint64, .fixed64 => "write_uint_string",
        .bool => "write_bool",
        .string => "write_string",
        .bytes => "write_bytes",
    };
}

/// Returns the json write expression for converting a Zig value to the appropriate
/// json.write_* call argument type.
pub fn scalar_json_value_expr(s: ScalarType, val_expr: []const u8, buf: []u8) []const u8 {
    return switch (s) {
        .int32, .sint32, .sfixed32 => std.fmt.bufPrint(buf, "@as(i64, {s})", .{val_expr}) catch unreachable,
        .int64, .sint64, .sfixed64 => std.fmt.bufPrint(buf, "@as(i64, {s})", .{val_expr}) catch unreachable,
        .uint32 => std.fmt.bufPrint(buf, "@as(u64, {s})", .{val_expr}) catch unreachable,
        .uint64, .fixed32, .fixed64 => std.fmt.bufPrint(buf, "@as(u64, {s})", .{val_expr}) catch unreachable,
        .double, .float, .bool, .string, .bytes => val_expr,
    };
}

/// Returns the json.read_* function name for parsing a scalar type from JSON.
pub fn scalar_json_read_fn(s: ScalarType) []const u8 {
    return switch (s) {
        .double => "read_float64",
        .float => "read_float32",
        .int32, .sint32, .sfixed32 => "read_int32",
        .int64, .sint64, .sfixed64 => "read_int64",
        .uint32, .fixed32 => "read_uint32",
        .uint64, .fixed64 => "read_uint64",
        .bool => "read_bool",
        .string => "read_string",
        .bytes => "read_bytes",
    };
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

test "scalar_zig_type: all 15 types" {
    try testing.expectEqualStrings("f64", scalar_zig_type(.double));
    try testing.expectEqualStrings("f32", scalar_zig_type(.float));
    try testing.expectEqualStrings("i32", scalar_zig_type(.int32));
    try testing.expectEqualStrings("i64", scalar_zig_type(.int64));
    try testing.expectEqualStrings("u32", scalar_zig_type(.uint32));
    try testing.expectEqualStrings("u64", scalar_zig_type(.uint64));
    try testing.expectEqualStrings("i32", scalar_zig_type(.sint32));
    try testing.expectEqualStrings("i64", scalar_zig_type(.sint64));
    try testing.expectEqualStrings("u32", scalar_zig_type(.fixed32));
    try testing.expectEqualStrings("u64", scalar_zig_type(.fixed64));
    try testing.expectEqualStrings("i32", scalar_zig_type(.sfixed32));
    try testing.expectEqualStrings("i64", scalar_zig_type(.sfixed64));
    try testing.expectEqualStrings("bool", scalar_zig_type(.bool));
    try testing.expectEqualStrings("[]const u8", scalar_zig_type(.string));
    try testing.expectEqualStrings("[]const u8", scalar_zig_type(.bytes));
}

test "scalar_wire_type: varint/i32/i64/len classification" {
    try testing.expectEqualStrings(".varint", scalar_wire_type(.int32));
    try testing.expectEqualStrings(".varint", scalar_wire_type(.bool));
    try testing.expectEqualStrings(".i32", scalar_wire_type(.fixed32));
    try testing.expectEqualStrings(".i32", scalar_wire_type(.float));
    try testing.expectEqualStrings(".i64", scalar_wire_type(.fixed64));
    try testing.expectEqualStrings(".i64", scalar_wire_type(.double));
    try testing.expectEqualStrings(".len", scalar_wire_type(.string));
    try testing.expectEqualStrings(".len", scalar_wire_type(.bytes));
}

test "scalar_default_value: zero/false/empty" {
    try testing.expectEqualStrings("0", scalar_default_value(.int32));
    try testing.expectEqualStrings("0", scalar_default_value(.double));
    try testing.expectEqualStrings("false", scalar_default_value(.bool));
    try testing.expectEqualStrings("\"\"", scalar_default_value(.string));
    try testing.expectEqualStrings("\"\"", scalar_default_value(.bytes));
}

test "escape_zig_keyword: escapes keywords" {
    const type_esc = escape_zig_keyword("type");
    try testing.expect(type_esc.escaped);
    try testing.expectEqualStrings("type", type_esc.name);

    const error_esc = escape_zig_keyword("error");
    try testing.expect(error_esc.escaped);

    const return_esc = escape_zig_keyword("return");
    try testing.expect(return_esc.escaped);

    const pub_esc = escape_zig_keyword("pub");
    try testing.expect(pub_esc.escaped);

    const fn_esc = escape_zig_keyword("fn");
    try testing.expect(fn_esc.escaped);
}

test "escape_zig_keyword: passes through non-keywords" {
    const name = escape_zig_keyword("name");
    try testing.expect(!name.escaped);
    try testing.expectEqualStrings("name", name.name);

    const field = escape_zig_keyword("my_field");
    try testing.expect(!field.escaped);
}

test "escape_zig_keyword: escapes underscore prefix" {
    const under = escape_zig_keyword("_foo");
    try testing.expect(under.escaped);
}

test "EscapedName: format produces @\"name\" for escaped" {
    const esc = escape_zig_keyword("type");
    var buf: [32]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{f}", .{esc}) catch unreachable;
    try testing.expectEqualStrings("@\"type\"", result);
}

test "EscapedName: format produces plain name for non-escaped" {
    const esc = escape_zig_keyword("name");
    var buf: [32]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{f}", .{esc}) catch unreachable;
    try testing.expectEqualStrings("name", result);
}

test "is_string_key: string vs int" {
    try testing.expect(is_string_key(.string));
    try testing.expect(!is_string_key(.int32));
    try testing.expect(!is_string_key(.uint64));
}

test "scalar_decode_expr: representative types" {
    try testing.expectEqualStrings("@bitCast(@as(u32, @truncate(field.value.varint)))", scalar_decode_expr(.int32));
    try testing.expectEqualStrings("field.value.varint", scalar_decode_expr(.uint64));
    try testing.expectEqualStrings("field.value.varint != 0", scalar_decode_expr(.bool));
    try testing.expectEqualStrings("@bitCast(field.value.i64)", scalar_decode_expr(.double));
    try testing.expectEqualStrings("field.value.i32", scalar_decode_expr(.fixed32));
    try testing.expectEqualStrings("field.value.len", scalar_decode_expr(.string));
}

test "snake_to_lower_camel: single word" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("name", snake_to_lower_camel("name", &buf));
}

test "snake_to_lower_camel: multi word" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("myFieldName", snake_to_lower_camel("my_field_name", &buf));
}

test "snake_to_lower_camel: leading underscore" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Foo", snake_to_lower_camel("_foo", &buf));
}

test "snake_to_lower_camel: double underscore" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("aB", snake_to_lower_camel("a__b", &buf));
}

test "scalar_json_write_fn: type mapping" {
    try testing.expectEqualStrings("write_int", scalar_json_write_fn(.int32));
    try testing.expectEqualStrings("write_int_string", scalar_json_write_fn(.int64));
    try testing.expectEqualStrings("write_uint_string", scalar_json_write_fn(.uint64));
    try testing.expectEqualStrings("write_uint_string", scalar_json_write_fn(.fixed64));
    try testing.expectEqualStrings("write_float", scalar_json_write_fn(.double));
    try testing.expectEqualStrings("write_float", scalar_json_write_fn(.float));
    try testing.expectEqualStrings("write_bool", scalar_json_write_fn(.bool));
    try testing.expectEqualStrings("write_string", scalar_json_write_fn(.string));
    try testing.expectEqualStrings("write_bytes", scalar_json_write_fn(.bytes));
}

test "scalar_json_read_fn: type mapping" {
    try testing.expectEqualStrings("read_int32", scalar_json_read_fn(.int32));
    try testing.expectEqualStrings("read_int32", scalar_json_read_fn(.sint32));
    try testing.expectEqualStrings("read_int32", scalar_json_read_fn(.sfixed32));
    try testing.expectEqualStrings("read_int64", scalar_json_read_fn(.int64));
    try testing.expectEqualStrings("read_int64", scalar_json_read_fn(.sint64));
    try testing.expectEqualStrings("read_int64", scalar_json_read_fn(.sfixed64));
    try testing.expectEqualStrings("read_uint32", scalar_json_read_fn(.uint32));
    try testing.expectEqualStrings("read_uint32", scalar_json_read_fn(.fixed32));
    try testing.expectEqualStrings("read_uint64", scalar_json_read_fn(.uint64));
    try testing.expectEqualStrings("read_uint64", scalar_json_read_fn(.fixed64));
    try testing.expectEqualStrings("read_float64", scalar_json_read_fn(.double));
    try testing.expectEqualStrings("read_float32", scalar_json_read_fn(.float));
    try testing.expectEqualStrings("read_bool", scalar_json_read_fn(.bool));
    try testing.expectEqualStrings("read_string", scalar_json_read_fn(.string));
    try testing.expectEqualStrings("read_bytes", scalar_json_read_fn(.bytes));
}
