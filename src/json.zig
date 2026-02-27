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
// JSON Scanner (Decoding)
// ══════════════════════════════════════════════════════════════════════

pub const JsonError = error{
    UnexpectedToken,
    UnexpectedEndOfInput,
    InvalidNumber,
    InvalidEscape,
    InvalidBase64,
    Overflow,
    OutOfMemory,
};

pub const JsonToken = union(enum) {
    object_start,
    object_end,
    array_start,
    array_end,
    string: []const u8,
    number: []const u8,
    true_value,
    false_value,
    null_value,
};

pub const JsonScanner = struct {
    inner: std.json.Scanner,
    allocator: std.mem.Allocator,
    peeked: ?JsonToken,
    allocated_strings: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator, source: []const u8) JsonScanner {
        return .{
            .inner = std.json.Scanner.initCompleteInput(allocator, source),
            .allocator = allocator,
            .peeked = null,
            .allocated_strings = .empty,
        };
    }

    pub fn deinit(self: *JsonScanner) void {
        for (self.allocated_strings.items) |s| {
            self.allocator.free(s);
        }
        self.allocated_strings.deinit(self.allocator);
        self.inner.deinit();
    }

    pub fn next(self: *JsonScanner) JsonError!?JsonToken {
        if (self.peeked) |tok| {
            self.peeked = null;
            return tok;
        }
        return self.next_inner();
    }

    pub fn peek(self: *JsonScanner) JsonError!?JsonToken {
        if (self.peeked) |tok| {
            return tok;
        }
        self.peeked = try self.next_inner();
        return self.peeked;
    }

    fn next_inner(self: *JsonScanner) JsonError!?JsonToken {
        const token = self.inner.nextAlloc(self.allocator, .alloc_if_needed) catch |err| {
            return switch (err) {
                error.OutOfMemory => JsonError.OutOfMemory,
                else => JsonError.UnexpectedToken,
            };
        };
        return switch (token) {
            .object_begin => .object_start,
            .object_end => .object_end,
            .array_begin => .array_start,
            .array_end => .array_end,
            .string => |s| .{ .string = s },
            .allocated_string => |s| {
                self.allocated_strings.append(self.allocator, s) catch {
                    self.allocator.free(s);
                    return error.OutOfMemory;
                };
                return .{ .string = s };
            },
            .number => |n| .{ .number = n },
            .allocated_number => |n| {
                self.allocated_strings.append(self.allocator, n) catch {
                    self.allocator.free(n);
                    return error.OutOfMemory;
                };
                return .{ .number = n };
            },
            .@"true" => .true_value,
            .@"false" => .false_value,
            .@"null" => .null_value,
            .end_of_document => null,
            .partial_number,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => unreachable,
        };
    }
};

// ── Scanner Helper Functions ──────────────────────────────────────────

pub fn skip_value(scanner: *JsonScanner) JsonError!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .object_start => {
            while (true) {
                const next_tok = try scanner.peek() orelse return JsonError.UnexpectedEndOfInput;
                if (next_tok == .object_end) {
                    _ = try scanner.next();
                    return;
                }
                // skip key
                const key = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
                if (key != .string) return JsonError.UnexpectedToken;
                // skip value
                try skip_value(scanner);
            }
        },
        .array_start => {
            while (true) {
                const next_tok = try scanner.peek() orelse return JsonError.UnexpectedEndOfInput;
                if (next_tok == .array_end) {
                    _ = try scanner.next();
                    return;
                }
                try skip_value(scanner);
            }
        },
        .string, .number, .true_value, .false_value, .null_value => return,
        .object_end, .array_end => return JsonError.UnexpectedToken,
    }
}

pub fn read_string(scanner: *JsonScanner) JsonError![]const u8 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .string => |s| return s,
        else => return JsonError.UnexpectedToken,
    }
}

pub fn read_bytes(scanner: *JsonScanner, allocator: std.mem.Allocator) JsonError![]const u8 {
    const b64_str = try read_string(scanner);
    if (b64_str.len == 0) {
        return allocator.alloc(u8, 0) catch return JsonError.OutOfMemory;
    }
    // Try standard base64 first, then URL-safe
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64_str) catch
        std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(b64_str) catch
        return JsonError.InvalidBase64;
    const buf = allocator.alloc(u8, decoded_len) catch return JsonError.OutOfMemory;
    std.base64.standard.Decoder.decode(buf, b64_str) catch {
        std.base64.url_safe_no_pad.Decoder.decode(buf, b64_str) catch {
            allocator.free(buf);
            return JsonError.InvalidBase64;
        };
    };
    return buf;
}

pub fn read_bool(scanner: *JsonScanner) JsonError!bool {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .true_value => return true,
        .false_value => return false,
        else => return JsonError.UnexpectedToken,
    }
}

pub fn read_int32(scanner: *JsonScanner) JsonError!i32 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .number => |n| n,
        .string => |s| s,
        else => return JsonError.UnexpectedToken,
    };
    return std.fmt.parseInt(i32, text, 10) catch return JsonError.Overflow;
}

pub fn read_int64(scanner: *JsonScanner) JsonError!i64 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .number => |n| n,
        .string => |s| s,
        else => return JsonError.UnexpectedToken,
    };
    return std.fmt.parseInt(i64, text, 10) catch return JsonError.Overflow;
}

pub fn read_uint32(scanner: *JsonScanner) JsonError!u32 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .number => |n| n,
        .string => |s| s,
        else => return JsonError.UnexpectedToken,
    };
    return std.fmt.parseInt(u32, text, 10) catch return JsonError.Overflow;
}

pub fn read_uint64(scanner: *JsonScanner) JsonError!u64 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .number => |n| n,
        .string => |s| s,
        else => return JsonError.UnexpectedToken,
    };
    return std.fmt.parseInt(u64, text, 10) catch return JsonError.Overflow;
}

pub fn read_float32(scanner: *JsonScanner) JsonError!f32 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .number => |n| n,
        .string => |s| s,
        else => return JsonError.UnexpectedToken,
    };
    if (std.mem.eql(u8, text, "NaN")) return std.math.nan(f32);
    if (std.mem.eql(u8, text, "Infinity")) return std.math.inf(f32);
    if (std.mem.eql(u8, text, "-Infinity")) return -std.math.inf(f32);
    return std.fmt.parseFloat(f32, text) catch return JsonError.InvalidNumber;
}

pub fn read_float64(scanner: *JsonScanner) JsonError!f64 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .number => |n| n,
        .string => |s| s,
        else => return JsonError.UnexpectedToken,
    };
    if (std.mem.eql(u8, text, "NaN")) return std.math.nan(f64);
    if (std.mem.eql(u8, text, "Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, text, "-Infinity")) return -std.math.inf(f64);
    return std.fmt.parseFloat(f64, text) catch return JsonError.InvalidNumber;
}

pub fn read_enum_int(scanner: *JsonScanner) JsonError!i32 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .number => |n| n,
        .string => |s| s,
        else => return JsonError.UnexpectedToken,
    };
    return std.fmt.parseInt(i32, text, 10) catch return JsonError.Overflow;
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

// ── Scanner Tests ─────────────────────────────────────────────────────

test "scanner: empty input" {
    var s = JsonScanner.init(testing.allocator, "");
    defer s.deinit();
    try testing.expectError(JsonError.UnexpectedToken, s.next());
}

test "scanner: empty object" {
    var s = JsonScanner.init(testing.allocator, "{}");
    defer s.deinit();
    try testing.expect((try s.next()).? == .object_start);
    try testing.expect((try s.next()).? == .object_end);
    try testing.expect(try s.next() == null);
}

test "scanner: empty array" {
    var s = JsonScanner.init(testing.allocator, "[]");
    defer s.deinit();
    try testing.expect((try s.next()).? == .array_start);
    try testing.expect((try s.next()).? == .array_end);
    try testing.expect(try s.next() == null);
}

test "scanner: plain string" {
    var s = JsonScanner.init(testing.allocator, "\"hello\"");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("hello", tok.string);
}

test "scanner: escaped string" {
    var s = JsonScanner.init(testing.allocator, "\"a\\\"b\\\\c\\nd\"");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("a\"b\\c\nd", tok.string);
}

test "scanner: unicode escape" {
    var s = JsonScanner.init(testing.allocator, "\"\\u0041\"");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("A", tok.string);
}

test "scanner: numbers" {
    var s = JsonScanner.init(testing.allocator, "42");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("42", tok.number);
}

test "scanner: negative number" {
    var s = JsonScanner.init(testing.allocator, "-17");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("-17", tok.number);
}

test "scanner: float number" {
    var s = JsonScanner.init(testing.allocator, "3.14");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("3.14", tok.number);
}

test "scanner: exponent number" {
    var s = JsonScanner.init(testing.allocator, "1e10");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("1e10", tok.number);
}

test "scanner: keywords" {
    var s1 = JsonScanner.init(testing.allocator, "true");
    defer s1.deinit();
    try testing.expect((try s1.next()).? == .true_value);

    var s2 = JsonScanner.init(testing.allocator, "false");
    defer s2.deinit();
    try testing.expect((try s2.next()).? == .false_value);

    var s3 = JsonScanner.init(testing.allocator, "null");
    defer s3.deinit();
    try testing.expect((try s3.next()).? == .null_value);
}

test "scanner: nested structure" {
    var s = JsonScanner.init(testing.allocator, "{\"a\":[1,2],\"b\":true}");
    defer s.deinit();
    try testing.expect((try s.next()).? == .object_start);
    try testing.expectEqualStrings("a", (try s.next()).?.string);
    try testing.expect((try s.next()).? == .array_start);
    try testing.expectEqualStrings("1", (try s.next()).?.number);
    try testing.expectEqualStrings("2", (try s.next()).?.number);
    try testing.expect((try s.next()).? == .array_end);
    try testing.expectEqualStrings("b", (try s.next()).?.string);
    try testing.expect((try s.next()).? == .true_value);
    try testing.expect((try s.next()).? == .object_end);
}

test "scanner: peek then next" {
    var s = JsonScanner.init(testing.allocator, "42");
    defer s.deinit();
    const peeked = (try s.peek()).?;
    try testing.expectEqualStrings("42", peeked.number);
    const next_tok = (try s.next()).?;
    try testing.expectEqualStrings("42", next_tok.number);
    try testing.expect(try s.next() == null);
}

test "scanner: unexpected token" {
    var s = JsonScanner.init(testing.allocator, "x");
    defer s.deinit();
    try testing.expectError(JsonError.UnexpectedToken, s.next());
}

// ── skip_value Tests ──────────────────────────────────────────────────

test "skip_value: number" {
    var s = JsonScanner.init(testing.allocator, "42");
    defer s.deinit();
    try skip_value(&s);
    try testing.expect(try s.next() == null);
}

test "skip_value: string" {
    var s = JsonScanner.init(testing.allocator, "\"hello\"");
    defer s.deinit();
    try skip_value(&s);
    try testing.expect(try s.next() == null);
}

test "skip_value: nested object" {
    var s = JsonScanner.init(testing.allocator, "{\"a\":{\"b\":1},\"c\":[2,3]}");
    defer s.deinit();
    try skip_value(&s);
    try testing.expect(try s.next() == null);
}

test "skip_value: nested array" {
    var s = JsonScanner.init(testing.allocator, "[[1,2],[3,4]]");
    defer s.deinit();
    try skip_value(&s);
    try testing.expect(try s.next() == null);
}

test "skip_value: keywords" {
    var s = JsonScanner.init(testing.allocator, "true");
    defer s.deinit();
    try skip_value(&s);
    try testing.expect(try s.next() == null);
}

// ── read_* Tests ──────────────────────────────────────────────────────

test "read_bool: true" {
    var s = JsonScanner.init(testing.allocator, "true");
    defer s.deinit();
    try testing.expect(try read_bool(&s));
}

test "read_bool: false" {
    var s = JsonScanner.init(testing.allocator, "false");
    defer s.deinit();
    try testing.expect(!try read_bool(&s));
}

test "read_int32: number" {
    var s = JsonScanner.init(testing.allocator, "42");
    defer s.deinit();
    try testing.expectEqual(@as(i32, 42), try read_int32(&s));
}

test "read_int64: string coercion" {
    var s = JsonScanner.init(testing.allocator, "\"9223372036854775807\"");
    defer s.deinit();
    try testing.expectEqual(@as(i64, 9223372036854775807), try read_int64(&s));
}

test "read_uint64: string coercion" {
    var s = JsonScanner.init(testing.allocator, "\"18446744073709551615\"");
    defer s.deinit();
    try testing.expectEqual(@as(u64, 18446744073709551615), try read_uint64(&s));
}

test "read_float64: number" {
    var s = JsonScanner.init(testing.allocator, "3.14");
    defer s.deinit();
    try testing.expectEqual(@as(f64, 3.14), try read_float64(&s));
}

test "read_float64: NaN string" {
    var s = JsonScanner.init(testing.allocator, "\"NaN\"");
    defer s.deinit();
    try testing.expect(std.math.isNan(try read_float64(&s)));
}

test "read_float64: Infinity string" {
    var s = JsonScanner.init(testing.allocator, "\"Infinity\"");
    defer s.deinit();
    try testing.expect(std.math.isInf(try read_float64(&s)));
}

test "read_float64: -Infinity string" {
    var s = JsonScanner.init(testing.allocator, "\"-Infinity\"");
    defer s.deinit();
    const val = try read_float64(&s);
    try testing.expect(std.math.isInf(val) and val < 0);
}

test "read_float32: number" {
    var s = JsonScanner.init(testing.allocator, "1.5");
    defer s.deinit();
    try testing.expectEqual(@as(f32, 1.5), try read_float32(&s));
}

test "read_string: plain" {
    var s = JsonScanner.init(testing.allocator, "\"test\"");
    defer s.deinit();
    try testing.expectEqualStrings("test", try read_string(&s));
}

test "read_enum_int: number" {
    var s = JsonScanner.init(testing.allocator, "2");
    defer s.deinit();
    try testing.expectEqual(@as(i32, 2), try read_enum_int(&s));
}

test "read_enum_int: string" {
    var s = JsonScanner.init(testing.allocator, "\"3\"");
    defer s.deinit();
    try testing.expectEqual(@as(i32, 3), try read_enum_int(&s));
}

test "read_bytes: base64" {
    var s = JsonScanner.init(testing.allocator, "\"aGVsbG8=\"");
    defer s.deinit();
    const decoded = try read_bytes(&s, testing.allocator);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("hello", decoded);
}

test "read_bytes: empty" {
    var s = JsonScanner.init(testing.allocator, "\"\"");
    defer s.deinit();
    const decoded = try read_bytes(&s, testing.allocator);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 0), decoded.len);
}

test "read_int32: wrong token type" {
    var s = JsonScanner.init(testing.allocator, "true");
    defer s.deinit();
    try testing.expectError(JsonError.UnexpectedToken, read_int32(&s));
}

test "read_bool: wrong token type" {
    var s = JsonScanner.init(testing.allocator, "42");
    defer s.deinit();
    try testing.expectError(JsonError.UnexpectedToken, read_bool(&s));
}
