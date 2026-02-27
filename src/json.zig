const std = @import("std");
const testing = std.testing;

const Writer = std.Io.Writer;
const Error = Writer.Error;

pub fn write_object_start(writer: *Writer) Error!void {
    try writer.writeByte('{');
}

pub fn write_object_end(writer: *Writer) Error!void {
    try writer.writeByte('}');
}

pub fn write_array_start(writer: *Writer) Error!void {
    try writer.writeByte('[');
}

pub fn write_array_end(writer: *Writer) Error!void {
    try writer.writeByte(']');
}

/// Writes a field separator (`,`) if not the first field. Returns false (for use as `first = ...`).
pub fn write_field_sep(writer: *Writer, first: bool) Error!bool {
    if (!first) try writer.writeByte(',');
    return false;
}

pub fn write_field_name(writer: *Writer, name: []const u8) Error!void {
    try writer.writeByte('"');
    try writer.writeAll(name);
    try writer.writeAll("\":");
}

pub fn write_string(writer: *Writer, value: []const u8) Error!void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                try writer.print("\\u{x:0>4}", .{c});
            },
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

pub fn write_int(writer: *Writer, value: i64) Error!void {
    try writer.print("{d}", .{value});
}

pub fn write_uint(writer: *Writer, value: u64) Error!void {
    try writer.print("{d}", .{value});
}

/// Writes an int64/sint64/sfixed64 value as a JSON string (proto-JSON canonical form).
pub fn write_int_string(writer: *Writer, value: i64) Error!void {
    try writer.print("\"{d}\"", .{value});
}

/// Writes a uint64/fixed64 value as a JSON string (proto-JSON canonical form).
pub fn write_uint_string(writer: *Writer, value: u64) Error!void {
    try writer.print("\"{d}\"", .{value});
}

pub fn write_float(writer: *Writer, value: anytype) Error!void {
    const T = @TypeOf(value);
    if (T != f32 and T != f64) @compileError("write_float expects f32 or f64");
    if (std.math.isNan(value)) {
        try writer.writeAll("\"NaN\"");
    } else if (std.math.isInf(value)) {
        if (value < 0) {
            try writer.writeAll("\"-Infinity\"");
        } else {
            try writer.writeAll("\"Infinity\"");
        }
    } else {
        try writer.print("{d}", .{value});
    }
}

pub fn write_bool(writer: *Writer, value: bool) Error!void {
    try writer.writeAll(if (value) "true" else "false");
}

pub fn write_bytes(writer: *Writer, value: []const u8) Error!void {
    try writer.writeByte('"');
    try std.base64.standard.Encoder.encodeWriter(writer, value);
    try writer.writeByte('"');
}

pub fn write_null(writer: *Writer) Error!void {
    try writer.writeAll("null");
}

/// Writes an enum value as its string name.
pub fn write_enum_name(writer: *Writer, name: []const u8) Error!void {
    try writer.writeByte('"');
    try writer.writeAll(name);
    try writer.writeByte('"');
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

fn test_write(comptime f: anytype, args: anytype) ![]const u8 {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try @call(.auto, f, .{&writer} ++ args);
    return writer.buffered();
}

test "write_object_start/end" {
    const start = try test_write(write_object_start, .{});
    try testing.expectEqualStrings("{", start);
    const end = try test_write(write_object_end, .{});
    try testing.expectEqualStrings("}", end);
}

test "write_array_start/end" {
    const start = try test_write(write_array_start, .{});
    try testing.expectEqualStrings("[", start);
    const end = try test_write(write_array_end, .{});
    try testing.expectEqualStrings("]", end);
}

test "write_field_sep: first field" {
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const result = try write_field_sep(&writer, true);
    try testing.expect(!result);
    try testing.expectEqualStrings("", writer.buffered());
}

test "write_field_sep: subsequent field" {
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const result = try write_field_sep(&writer, false);
    try testing.expect(!result);
    try testing.expectEqualStrings(",", writer.buffered());
}

test "write_field_name" {
    const result = try test_write(write_field_name, .{"myField"});
    try testing.expectEqualStrings("\"myField\":", result);
}

test "write_string: simple" {
    const result = try test_write(write_string, .{"hello"});
    try testing.expectEqualStrings("\"hello\"", result);
}

test "write_string: escaping" {
    const result = try test_write(write_string, .{"a\"b\\c\nd\re\tf"});
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\re\\tf\"", result);
}

test "write_string: control chars" {
    const result = try test_write(write_string, .{"\x01\x1f"});
    try testing.expectEqualStrings("\"\\u0001\\u001f\"", result);
}

test "write_int" {
    const result = try test_write(write_int, .{@as(i64, -42)});
    try testing.expectEqualStrings("-42", result);
}

test "write_uint" {
    const result = try test_write(write_uint, .{@as(u64, 123)});
    try testing.expectEqualStrings("123", result);
}

test "write_int_string" {
    const result = try test_write(write_int_string, .{@as(i64, -9223372036854775807)});
    try testing.expectEqualStrings("\"-9223372036854775807\"", result);
}

test "write_uint_string" {
    const result = try test_write(write_uint_string, .{@as(u64, 18446744073709551615)});
    try testing.expectEqualStrings("\"18446744073709551615\"", result);
}

test "write_float: normal" {
    const result = try test_write(write_float, .{@as(f64, 3.14)});
    try testing.expectEqualStrings("3.14", result);
}

test "write_float: NaN" {
    const result = try test_write(write_float, .{std.math.nan(f64)});
    try testing.expectEqualStrings("\"NaN\"", result);
}

test "write_float: Infinity" {
    const result = try test_write(write_float, .{std.math.inf(f64)});
    try testing.expectEqualStrings("\"Infinity\"", result);
}

test "write_float: negative Infinity" {
    const result = try test_write(write_float, .{-std.math.inf(f64)});
    try testing.expectEqualStrings("\"-Infinity\"", result);
}

test "write_bool: true" {
    const result = try test_write(write_bool, .{true});
    try testing.expectEqualStrings("true", result);
}

test "write_bool: false" {
    const result = try test_write(write_bool, .{false});
    try testing.expectEqualStrings("false", result);
}

test "write_bytes: empty" {
    const result = try test_write(write_bytes, .{@as([]const u8, "")});
    try testing.expectEqualStrings("\"\"", result);
}

test "write_bytes: base64 encoding" {
    const result = try test_write(write_bytes, .{"hello"});
    try testing.expectEqualStrings("\"aGVsbG8=\"", result);
}

test "write_null" {
    const result = try test_write(write_null, .{});
    try testing.expectEqualStrings("null", result);
}

test "write_enum_name" {
    const result = try test_write(write_enum_name, .{"ACTIVE"});
    try testing.expectEqualStrings("\"ACTIVE\"", result);
}

test "write_float: f32" {
    const result = try test_write(write_float, .{@as(f32, 1.5)});
    // f32 1.5 should render as a number
    try testing.expect(result.len > 0);
    try testing.expect(result[0] != '"'); // Not a string
}
