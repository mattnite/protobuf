const std = @import("std");
const testing = std.testing;

const Writer = std.Io.Writer;
const Error = Writer.Error;

/// Special JSON encoding/decoding for Google protobuf well-known types
pub const well_known_types = @import("well_known_types.zig");

/// When true, unknown enum string values are ignored by generated from_json parsers.
/// The conformance testee toggles this for JSON_IGNORE_UNKNOWN_PARSING_TEST cases.
pub var ignore_unknown_enum_values: bool = false;

/// Write a JSON object opening brace
pub fn write_object_start(writer: *Writer) Error!void {
    try writer.writeByte('{');
}

/// Write a JSON object closing brace
pub fn write_object_end(writer: *Writer) Error!void {
    try writer.writeByte('}');
}

/// Write a JSON array opening bracket
pub fn write_array_start(writer: *Writer) Error!void {
    try writer.writeByte('[');
}

/// Write a JSON array closing bracket
pub fn write_array_end(writer: *Writer) Error!void {
    try writer.writeByte(']');
}

/// Writes a field separator (`,`) if not the first field. Returns false (for use as `first = ...`).
pub fn write_field_sep(writer: *Writer, first: bool) Error!bool {
    if (!first) try writer.writeByte(',');
    return false;
}

/// Write a JSON field name with quotes and colon
pub fn write_field_name(writer: *Writer, name: []const u8) Error!void {
    try writer.writeByte('"');
    try writer.writeAll(name);
    try writer.writeAll("\":");
}

/// Write a JSON string with escape handling
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

/// Write a signed integer as a JSON number
pub fn write_int(writer: *Writer, value: i64) Error!void {
    try writer.print("{d}", .{value});
}

/// Write an unsigned integer as a JSON number
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

/// Write a float as a JSON number, or a quoted string for NaN/Infinity
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

/// Write a JSON boolean literal
pub fn write_bool(writer: *Writer, value: bool) Error!void {
    try writer.writeAll(if (value) "true" else "false");
}

/// Write a byte slice as a base64-encoded JSON string
pub fn write_bytes(writer: *Writer, value: []const u8) Error!void {
    try writer.writeByte('"');
    try std.base64.standard.Encoder.encodeWriter(writer, value);
    try writer.writeByte('"');
}

/// Write the JSON null literal
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

/// Error set for JSON parsing operations
pub const JsonError = error{
    UnexpectedToken,
    UnexpectedEndOfInput,
    InvalidNumber,
    InvalidEscape,
    InvalidBase64,
    Overflow,
    OutOfMemory,
};

/// Complete error set for generated from_json_scanner_inner methods (JsonError + recursion)
pub const DecodeError = JsonError || error{RecursionLimitExceeded};

/// Tagged union of JSON token types from the scanner
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

/// Pull-based tokenizer for JSON input
pub const JsonScanner = struct {
    inner: std.json.Scanner,
    allocator: std.mem.Allocator,
    peeked: ?JsonToken,
    allocated_strings: std.ArrayListUnmanaged([]const u8),

    /// Create a scanner over a JSON byte slice
    pub fn init(allocator: std.mem.Allocator, source: []const u8) JsonScanner {
        return .{
            .inner = std.json.Scanner.initCompleteInput(allocator, source),
            .allocator = allocator,
            .peeked = null,
            .allocated_strings = .empty,
        };
    }

    /// Free all scanner-allocated memory
    pub fn deinit(self: *JsonScanner) void {
        for (self.allocated_strings.items) |s| {
            self.allocator.free(s);
        }
        self.allocated_strings.deinit(self.allocator);
        self.inner.deinit();
    }

    /// Consume and return the next token, or null at end of input
    pub fn next(self: *JsonScanner) JsonError!?JsonToken {
        if (self.peeked) |tok| {
            self.peeked = null;
            return tok;
        }
        return self.next_inner();
    }

    /// Return the next token without consuming it
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

/// Skip over a complete JSON value, including nested objects and arrays
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

/// Consume the next JSON value from `scanner` and return a canonical JSON
/// encoding of that value. Used by Any parsing to buffer payload fragments.
pub fn capture_value(scanner: *JsonScanner, allocator: std.mem.Allocator) JsonError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try write_captured_value(&out.writer, scanner);
    return out.toOwnedSlice() catch return JsonError.OutOfMemory;
}

fn write_captured_value(writer: *Writer, scanner: *JsonScanner) JsonError!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .object_start => {
            writer.writeByte('{') catch return JsonError.OutOfMemory;
            var first = true;
            while (true) {
                const next_tok = try scanner.peek() orelse return JsonError.UnexpectedEndOfInput;
                if (next_tok == .object_end) {
                    _ = try scanner.next();
                    writer.writeByte('}') catch return JsonError.OutOfMemory;
                    return;
                }
                const key_tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
                const key = switch (key_tok) {
                    .string => |s| s,
                    else => return JsonError.UnexpectedToken,
                };
                if (!first) {
                    writer.writeByte(',') catch return JsonError.OutOfMemory;
                }
                first = false;
                write_string(writer, key) catch return JsonError.OutOfMemory;
                writer.writeByte(':') catch return JsonError.OutOfMemory;
                try write_captured_value(writer, scanner);
            }
        },
        .array_start => {
            writer.writeByte('[') catch return JsonError.OutOfMemory;
            var first = true;
            while (true) {
                const next_tok = try scanner.peek() orelse return JsonError.UnexpectedEndOfInput;
                if (next_tok == .array_end) {
                    _ = try scanner.next();
                    writer.writeByte(']') catch return JsonError.OutOfMemory;
                    return;
                }
                if (!first) {
                    writer.writeByte(',') catch return JsonError.OutOfMemory;
                }
                first = false;
                try write_captured_value(writer, scanner);
            }
        },
        .string => |s| write_string(writer, s) catch return JsonError.OutOfMemory,
        .number => |n| writer.writeAll(n) catch return JsonError.OutOfMemory,
        .true_value => writer.writeAll("true") catch return JsonError.OutOfMemory,
        .false_value => writer.writeAll("false") catch return JsonError.OutOfMemory,
        .null_value => writer.writeAll("null") catch return JsonError.OutOfMemory,
        .object_end, .array_end => return JsonError.UnexpectedToken,
    }
}

/// Read and return a JSON string token
pub fn read_string(scanner: *JsonScanner) JsonError![]const u8 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .string => |s| return s,
        else => return JsonError.UnexpectedToken,
    }
}

/// Record a canonical field name in a seen set.
/// Returns true if the field name is already present.
pub fn mark_field_seen(
    seen: *std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,
    field_name: []const u8,
) JsonError!bool {
    const gop = seen.getOrPut(allocator, field_name) catch return JsonError.OutOfMemory;
    return gop.found_existing;
}

/// Read a base64-encoded JSON string and decode it to bytes
pub fn read_bytes(scanner: *JsonScanner, allocator: std.mem.Allocator) JsonError![]const u8 {
    const b64_str = try read_string(scanner);
    if (b64_str.len == 0) {
        return allocator.alloc(u8, 0) catch return JsonError.OutOfMemory;
    }
    return decode_base64_relaxed(allocator, b64_str);
}

/// Permissive base64 decode for proto-JSON bytes:
/// accepts standard and URL-safe alphabets, with or without padding.
/// Trailing non-zero bits in short final quanta are tolerated for conformance.
fn decode_base64_relaxed(allocator: std.mem.Allocator, text: []const u8) JsonError![]const u8 {
    var trimmed_len = text.len;
    while (trimmed_len > 0 and text[trimmed_len - 1] == '=') {
        trimmed_len -= 1;
    }
    if (trimmed_len == 0) return allocator.alloc(u8, 0) catch return JsonError.OutOfMemory;
    if (std.mem.indexOfScalar(u8, text[0..trimmed_len], '=')) |_| return JsonError.InvalidBase64;

    const rem = trimmed_len % 4;
    if (rem == 1) return JsonError.InvalidBase64;

    const out_len = (trimmed_len / 4) * 3 + switch (rem) {
        0 => @as(usize, 0),
        2 => @as(usize, 1),
        3 => @as(usize, 2),
        else => unreachable,
    };
    const out = allocator.alloc(u8, out_len) catch return JsonError.OutOfMemory;

    var src_idx: usize = 0;
    var dst_idx: usize = 0;

    while (src_idx + 4 <= trimmed_len) : (src_idx += 4) {
        const a = base64_value(text[src_idx]) orelse {
            allocator.free(out);
            return JsonError.InvalidBase64;
        };
        const b = base64_value(text[src_idx + 1]) orelse {
            allocator.free(out);
            return JsonError.InvalidBase64;
        };
        const c = base64_value(text[src_idx + 2]) orelse {
            allocator.free(out);
            return JsonError.InvalidBase64;
        };
        const d = base64_value(text[src_idx + 3]) orelse {
            allocator.free(out);
            return JsonError.InvalidBase64;
        };

        out[dst_idx] = (@as(u8, a) << 2) | (@as(u8, b) >> 4);
        out[dst_idx + 1] = (@as(u8, b) << 4) | (@as(u8, c) >> 2);
        out[dst_idx + 2] = (@as(u8, c) << 6) | @as(u8, d);
        dst_idx += 3;
    }

    switch (rem) {
        0 => {},
        2 => {
            const a = base64_value(text[src_idx]) orelse {
                allocator.free(out);
                return JsonError.InvalidBase64;
            };
            const b = base64_value(text[src_idx + 1]) orelse {
                allocator.free(out);
                return JsonError.InvalidBase64;
            };
            out[dst_idx] = (@as(u8, a) << 2) | (@as(u8, b) >> 4);
        },
        3 => {
            const a = base64_value(text[src_idx]) orelse {
                allocator.free(out);
                return JsonError.InvalidBase64;
            };
            const b = base64_value(text[src_idx + 1]) orelse {
                allocator.free(out);
                return JsonError.InvalidBase64;
            };
            const c = base64_value(text[src_idx + 2]) orelse {
                allocator.free(out);
                return JsonError.InvalidBase64;
            };
            out[dst_idx] = (@as(u8, a) << 2) | (@as(u8, b) >> 4);
            out[dst_idx + 1] = (@as(u8, b) << 4) | (@as(u8, c) >> 2);
        },
        else => unreachable,
    }

    return out;
}

fn base64_value(c: u8) ?u6 {
    return switch (c) {
        'A'...'Z' => @intCast(c - 'A'),
        'a'...'z' => @intCast(c - 'a' + 26),
        '0'...'9' => @intCast(c - '0' + 52),
        '+', '-' => 62,
        '/', '_' => 63,
        else => null,
    };
}

/// Read a JSON boolean value
pub fn read_bool(scanner: *JsonScanner) JsonError!bool {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .true_value => return true,
        .false_value => return false,
        else => return JsonError.UnexpectedToken,
    }
}

/// Read a JSON number or string as an i32
pub fn read_int32(scanner: *JsonScanner) JsonError!i32 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .number => |n| n,
        .string => |s| s,
        else => return JsonError.UnexpectedToken,
    };
    if (std.fmt.parseInt(i32, text, 10)) |v| return v else |_| {}
    const f = std.fmt.parseFloat(f64, text) catch return JsonError.Overflow;
    if (!std.math.isFinite(f)) return JsonError.Overflow;
    if (@trunc(f) != f) return JsonError.Overflow;
    if (f < @as(f64, @floatFromInt(std.math.minInt(i32))) or f > @as(f64, @floatFromInt(std.math.maxInt(i32)))) {
        return JsonError.Overflow;
    }
    return @intFromFloat(f);
}

/// Read a JSON number or string as an i64
pub fn read_int64(scanner: *JsonScanner) JsonError!i64 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .number => |n| n,
        .string => |s| s,
        else => return JsonError.UnexpectedToken,
    };
    return std.fmt.parseInt(i64, text, 10) catch return JsonError.Overflow;
}

/// Read a JSON number or string as a u32
pub fn read_uint32(scanner: *JsonScanner) JsonError!u32 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .number => |n| n,
        .string => |s| s,
        else => return JsonError.UnexpectedToken,
    };
    if (std.fmt.parseInt(u32, text, 10)) |v| return v else |_| {}
    const f = std.fmt.parseFloat(f64, text) catch return JsonError.Overflow;
    if (!std.math.isFinite(f)) return JsonError.Overflow;
    if (@trunc(f) != f) return JsonError.Overflow;
    if (f < 0 or f > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return JsonError.Overflow;
    return @intFromFloat(f);
}

/// Read a JSON number or string as a u64
pub fn read_uint64(scanner: *JsonScanner) JsonError!u64 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .number => |n| n,
        .string => |s| s,
        else => return JsonError.UnexpectedToken,
    };
    return std.fmt.parseInt(u64, text, 10) catch return JsonError.Overflow;
}

/// Read a JSON number or string as an f32, handling NaN/Infinity
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
    const f = std.fmt.parseFloat(f32, text) catch return JsonError.InvalidNumber;
    if (std.math.isInf(f)) return JsonError.Overflow;
    if (f == 0 and !number_text_is_zero(text)) return JsonError.Overflow;
    return f;
}

/// Read a JSON number or string as an f64, handling NaN/Infinity
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
    const f = std.fmt.parseFloat(f64, text) catch return JsonError.InvalidNumber;
    if (std.math.isInf(f)) return JsonError.Overflow;
    if (f == 0 and !number_text_is_zero(text)) return JsonError.Overflow;
    return f;
}

fn number_text_is_zero(text: []const u8) bool {
    var saw_digit = false;
    for (text) |c| {
        if (c >= '0' and c <= '9') {
            saw_digit = true;
            if (c != '0') return false;
            continue;
        }
        switch (c) {
            '+', '-', '.', 'e', 'E' => {},
            else => return false,
        }
    }
    return saw_digit;
}

/// Read an enum value as an i32 from a JSON number or string.
/// When the token is a string, first tries to parse it as a number;
/// if that fails, falls through to let the caller do name-based lookup.
pub fn read_enum_int(scanner: *JsonScanner) JsonError!i32 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .number => |n| n,
        .string => |s| s,
        else => return JsonError.UnexpectedToken,
    };
    return std.fmt.parseInt(i32, text, 10) catch return JsonError.Overflow;
}

const descriptor = @import("descriptor.zig");

/// Read an enum value from JSON, supporting both numeric values and string
/// names (proto-JSON canonical form). Looks up string names in the provided
/// EnumDescriptor.
pub fn read_enum_value(scanner: *JsonScanner, enum_desc: *const descriptor.EnumDescriptor) JsonError!i32 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .number => |n| return std.fmt.parseInt(i32, n, 10) catch return JsonError.Overflow,
        .string => |s| {
            // First try parsing as a numeric string
            if (std.fmt.parseInt(i32, s, 10)) |num| {
                return num;
            } else |_| {}
            // Look up by enum value name
            for (enum_desc.values) |v| {
                if (std.mem.eql(u8, v.name, s)) {
                    return v.number;
                }
            }
            return JsonError.UnexpectedToken;
        },
        .null_value => return 0, // null maps to default value (0) per proto-JSON spec
        else => return JsonError.UnexpectedToken,
    }
}

/// Parsed timestamp components in normalized seconds/nanos form.
pub const TimestampValue = struct {
    seconds: i64,
    nanos: i32,
};

/// Parsed duration components in normalized seconds/nanos form.
pub const DurationValue = struct {
    seconds: i64,
    nanos: i32,
};

const TIMESTAMP_MIN_SECONDS: i64 = -62_135_596_800;
const TIMESTAMP_MAX_SECONDS: i64 = 253_402_300_799;
const DURATION_ABS_MAX_SECONDS: i64 = 315_576_000_000;
const DURATION_MAX_NANOS: i32 = 999_999_999;

fn timestamp_is_valid(seconds: i64, nanos: i32) bool {
    if (seconds < TIMESTAMP_MIN_SECONDS or seconds > TIMESTAMP_MAX_SECONDS) return false;
    if (nanos < 0 or nanos > DURATION_MAX_NANOS) return false;
    return true;
}

fn duration_is_valid(seconds: i64, nanos: i32) bool {
    if (seconds < -DURATION_ABS_MAX_SECONDS or seconds > DURATION_ABS_MAX_SECONDS) return false;
    if (nanos < -DURATION_MAX_NANOS or nanos > DURATION_MAX_NANOS) return false;
    if (seconds < 0 and nanos > 0) return false;
    if (seconds > 0 and nanos < 0) return false;
    return true;
}

/// Read a protobuf Timestamp JSON value.
/// Accepts RFC 3339 strings with `Z` or `±HH:MM` offsets, or `null`.
pub fn read_timestamp_value(scanner: *JsonScanner) JsonError!?TimestampValue {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    return switch (tok) {
        .null_value => null,
        .string => |s| parse_timestamp_text(s) orelse JsonError.InvalidNumber,
        else => JsonError.UnexpectedToken,
    };
}

/// Write a protobuf Timestamp JSON value in canonical UTC RFC 3339 form.
pub fn write_timestamp_value(writer: *Writer, seconds: i64, nanos: i32) Error!void {
    if (!timestamp_is_valid(seconds, nanos)) return error.WriteFailed;

    const days = @divFloor(seconds, 86400);
    const sod = seconds - days * 86400;
    const date = days_to_civil(days);
    const hour: i64 = @divFloor(sod, 3600);
    const minute: i64 = @divFloor(sod - hour * 3600, 60);
    const second: i64 = sod - hour * 3600 - minute * 60;

    try writer.writeByte('"');
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(date.year)),
        @as(u64, @intCast(date.month)),
        @as(u64, @intCast(date.day)),
        @as(u64, @intCast(hour)),
        @as(u64, @intCast(minute)),
        @as(u64, @intCast(second)),
    });

    if (nanos != 0) {
        const abs_nanos: u32 = @intCast(if (nanos < 0) -nanos else nanos);
        if (abs_nanos % 1_000_000 == 0) {
            try writer.print(".{d:0>3}", .{abs_nanos / 1_000_000});
        } else if (abs_nanos % 1_000 == 0) {
            try writer.print(".{d:0>6}", .{abs_nanos / 1_000});
        } else {
            try writer.print(".{d:0>9}", .{abs_nanos});
        }
    }

    try writer.writeAll("Z\"");
}

/// Read a protobuf Duration JSON value (`"<seconds>[.<frac>]s"`), or `null`.
pub fn read_duration_value(scanner: *JsonScanner) JsonError!?DurationValue {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    return switch (tok) {
        .null_value => null,
        .string => |s| parse_duration_text(s) orelse JsonError.InvalidNumber,
        else => JsonError.UnexpectedToken,
    };
}

/// Write a protobuf Duration JSON value in canonical form.
pub fn write_duration_value(writer: *Writer, seconds: i64, nanos: i32) Error!void {
    if (!duration_is_valid(seconds, nanos)) return error.WriteFailed;

    const negative = seconds < 0 or nanos < 0;
    const abs_seconds: u64 = @intCast(if (seconds < 0) -seconds else seconds);
    const abs_nanos: u32 = @intCast(if (nanos < 0) -nanos else nanos);

    try writer.writeByte('"');
    if (negative) try writer.writeByte('-');
    try writer.print("{d}", .{abs_seconds});

    if (abs_nanos != 0) {
        if (abs_nanos % 1_000_000 == 0) {
            try writer.print(".{d:0>3}", .{abs_nanos / 1_000_000});
        } else if (abs_nanos % 1_000 == 0) {
            try writer.print(".{d:0>6}", .{abs_nanos / 1_000});
        } else {
            try writer.print(".{d:0>9}", .{abs_nanos});
        }
    }

    try writer.writeAll("s\"");
}

/// Read a protobuf FieldMask JSON value as snake_case path strings.
/// Accepts a comma-separated string or `null`.
pub fn read_field_mask_paths(scanner: *JsonScanner, allocator: std.mem.Allocator) JsonError![]const []const u8 {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .null_value => return allocator.alloc([]const u8, 0) catch return JsonError.OutOfMemory,
        .string => |s| s,
        else => return JsonError.UnexpectedToken,
    };

    if (text.len == 0) {
        return allocator.alloc([]const u8, 0) catch return JsonError.OutOfMemory;
    }

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |path| allocator.free(path);
        list.deinit(allocator);
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == ',') {
            const part = text[start..i];
            if (part.len == 0) return JsonError.UnexpectedToken;
            const snake = camel_to_snake_alloc(allocator, part) catch return JsonError.OutOfMemory;
            try list.append(allocator, snake);
            start = i + 1;
        }
    }

    return try list.toOwnedSlice(allocator);
}

/// Write protobuf FieldMask paths to JSON comma-separated lowerCamelCase string.
pub fn write_field_mask_paths(writer: *Writer, paths: []const []const u8) Error!void {
    try writer.writeByte('"');
    for (paths, 0..) |path, idx| {
        if (idx > 0) try writer.writeByte(',');
        try write_snake_as_camel(writer, path);
    }
    try writer.writeByte('"');
}

const CivilDate = struct {
    year: i64,
    month: i64,
    day: i64,
};

fn is_digit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn parse_2_digits(s: []const u8) ?u8 {
    if (s.len != 2 or !is_digit(s[0]) or !is_digit(s[1])) return null;
    return @intCast((s[0] - '0') * 10 + (s[1] - '0'));
}

fn parse_4_digits(s: []const u8) ?u16 {
    if (s.len != 4) return null;
    for (s) |c| if (!is_digit(c)) return null;
    return std.fmt.parseInt(u16, s, 10) catch return null;
}

fn is_leap_year(year: i64) bool {
    if (@mod(year, 4) != 0) return false;
    if (@mod(year, 100) != 0) return true;
    return @mod(year, 400) == 0;
}

fn days_in_month(year: i64, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (is_leap_year(year)) 29 else 28,
        else => 0,
    };
}

fn civil_to_days(year: i64, month: u8, day: u8) ?i64 {
    if (month < 1 or month > 12) return null;
    const dim = days_in_month(year, month);
    if (day < 1 or day > dim) return null;

    var y = year;
    const m: i64 = month;
    const d: i64 = day;
    y -= if (m <= 2) 1 else 0;

    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = m + (if (m > 2) @as(i64, -3) else @as(i64, 9));
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn days_to_civil(days: i64) CivilDate {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    y += if (m <= 2) 1 else 0;
    return .{ .year = y, .month = m, .day = d };
}

fn parse_timestamp_text(text: []const u8) ?TimestampValue {
    if (text.len < 20) return null;

    const year_u16 = parse_4_digits(text[0..4]) orelse return null;
    if (year_u16 == 0) return null;
    if (text[4] != '-') return null;
    const month = parse_2_digits(text[5..7]) orelse return null;
    if (text[7] != '-') return null;
    const day = parse_2_digits(text[8..10]) orelse return null;
    if (text[10] != 'T') return null;
    const hour = parse_2_digits(text[11..13]) orelse return null;
    if (text[13] != ':') return null;
    const minute = parse_2_digits(text[14..16]) orelse return null;
    if (text[16] != ':') return null;
    const second = parse_2_digits(text[17..19]) orelse return null;

    if (hour > 23 or minute > 59 or second > 59) return null;

    var pos: usize = 19;
    var nanos: i32 = 0;
    if (pos < text.len and text[pos] == '.') {
        pos += 1;
        const frac_start = pos;
        var frac_digits: u32 = 0;
        var frac: u32 = 0;
        while (pos < text.len and is_digit(text[pos])) : (pos += 1) {
            if (frac_digits == 9) return null;
            frac = frac * 10 + (text[pos] - '0');
            frac_digits += 1;
        }
        if (pos == frac_start) return null;
        while (frac_digits < 9) : (frac_digits += 1) frac *= 10;
        nanos = @intCast(frac);
    }

    var offset_seconds: i64 = 0;
    if (pos >= text.len) return null;
    if (text[pos] == 'Z') {
        pos += 1;
    } else if (text[pos] == '+' or text[pos] == '-') {
        const sign: i64 = if (text[pos] == '-') -1 else 1;
        pos += 1;
        if (pos + 5 > text.len) return null;
        const off_hour = parse_2_digits(text[pos .. pos + 2]) orelse return null;
        pos += 2;
        if (text[pos] != ':') return null;
        pos += 1;
        const off_min = parse_2_digits(text[pos .. pos + 2]) orelse return null;
        pos += 2;
        if (off_hour > 23 or off_min > 59) return null;
        offset_seconds = sign * (@as(i64, off_hour) * 3600 + @as(i64, off_min) * 60);
    } else {
        return null;
    }

    if (pos != text.len) return null;

    const year: i64 = year_u16;
    const days = civil_to_days(year, month, day) orelse return null;
    const local_seconds = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    return .{
        .seconds = local_seconds - offset_seconds,
        .nanos = nanos,
    };
}

fn parse_duration_text(text: []const u8) ?DurationValue {
    if (text.len < 2) return null;
    if (text[text.len - 1] != 's') return null;
    var body = text[0 .. text.len - 1];
    if (body.len == 0) return null;

    var negative = false;
    if (body[0] == '+' or body[0] == '-') {
        negative = body[0] == '-';
        body = body[1..];
        if (body.len == 0) return null;
    }

    var i: usize = 0;
    while (i < body.len and is_digit(body[i])) : (i += 1) {}
    if (i == 0) return null;
    const sec_text = body[0..i];
    const sec_u = std.fmt.parseInt(u64, sec_text, 10) catch return null;

    var nanos_u: u32 = 0;
    if (i < body.len) {
        if (body[i] != '.') return null;
        i += 1;
        const frac_start = i;
        var frac_digits: u32 = 0;
        while (i < body.len and is_digit(body[i])) : (i += 1) {
            if (frac_digits == 9) return null;
            nanos_u = nanos_u * 10 + (body[i] - '0');
            frac_digits += 1;
        }
        if (i == frac_start) return null;
        while (frac_digits < 9) : (frac_digits += 1) nanos_u *= 10;
    }
    if (i != body.len) return null;

    const max_seconds: u64 = 315_576_000_000;
    if (sec_u > max_seconds) return null;

    var seconds_i = std.math.cast(i64, sec_u) orelse return null;
    var nanos_i: i32 = @intCast(nanos_u);
    if (negative) {
        seconds_i = -seconds_i;
        if (nanos_i != 0) nanos_i = -nanos_i;
    }
    return .{ .seconds = seconds_i, .nanos = nanos_i };
}

fn camel_to_snake_alloc(allocator: std.mem.Allocator, camel: []const u8) std.mem.Allocator.Error![]const u8 {
    var extra: usize = 0;
    for (camel) |c| {
        if (std.ascii.isUpper(c)) extra += 1;
    }
    const out = try allocator.alloc(u8, camel.len + extra);
    var j: usize = 0;
    for (camel) |c| {
        if (std.ascii.isUpper(c)) {
            out[j] = '_';
            j += 1;
            out[j] = std.ascii.toLower(c);
            j += 1;
        } else {
            out[j] = c;
            j += 1;
        }
    }
    return out[0..j];
}

fn write_snake_as_camel(writer: *Writer, snake: []const u8) Error!void {
    var capitalize = false;
    for (snake) |c| {
        if (c == '_') {
            capitalize = true;
            continue;
        }
        if (capitalize) {
            try writer.writeByte(std.ascii.toUpper(c));
            capitalize = false;
        } else {
            try writer.writeByte(c);
        }
    }
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

test "read_bytes: base64 url-safe no padding" {
    var s = JsonScanner.init(testing.allocator, "\"-_\"");
    defer s.deinit();
    const decoded = try read_bytes(&s, testing.allocator);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 1), decoded.len);
    try testing.expectEqual(@as(u8, 0xfb), decoded[0]);
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

test "read_enum_value: numeric" {
    const enum_desc = descriptor.EnumDescriptor{
        .name = "Status",
        .full_name = "pkg.Status",
        .values = &.{
            .{ .name = "UNKNOWN", .number = 0 },
            .{ .name = "ACTIVE", .number = 1 },
            .{ .name = "INACTIVE", .number = 2 },
        },
    };
    var s = JsonScanner.init(testing.allocator, "1");
    defer s.deinit();
    try testing.expectEqual(@as(i32, 1), try read_enum_value(&s, &enum_desc));
}

test "read_enum_value: string name" {
    const enum_desc = descriptor.EnumDescriptor{
        .name = "Status",
        .full_name = "pkg.Status",
        .values = &.{
            .{ .name = "UNKNOWN", .number = 0 },
            .{ .name = "ACTIVE", .number = 1 },
            .{ .name = "INACTIVE", .number = 2 },
        },
    };
    var s = JsonScanner.init(testing.allocator, "\"ACTIVE\"");
    defer s.deinit();
    try testing.expectEqual(@as(i32, 1), try read_enum_value(&s, &enum_desc));
}

test "read_enum_value: numeric string" {
    const enum_desc = descriptor.EnumDescriptor{
        .name = "Status",
        .full_name = "pkg.Status",
        .values = &.{
            .{ .name = "UNKNOWN", .number = 0 },
        },
    };
    var s = JsonScanner.init(testing.allocator, "\"42\"");
    defer s.deinit();
    try testing.expectEqual(@as(i32, 42), try read_enum_value(&s, &enum_desc));
}

test "read_enum_value: null returns 0" {
    const enum_desc = descriptor.EnumDescriptor{
        .name = "Status",
        .full_name = "pkg.Status",
        .values = &.{
            .{ .name = "UNKNOWN", .number = 0 },
        },
    };
    var s = JsonScanner.init(testing.allocator, "null");
    defer s.deinit();
    try testing.expectEqual(@as(i32, 0), try read_enum_value(&s, &enum_desc));
}

test "read_enum_value: unknown name returns error" {
    const enum_desc = descriptor.EnumDescriptor{
        .name = "Status",
        .full_name = "pkg.Status",
        .values = &.{
            .{ .name = "UNKNOWN", .number = 0 },
        },
    };
    var s = JsonScanner.init(testing.allocator, "\"NOPE\"");
    defer s.deinit();
    try testing.expectError(JsonError.UnexpectedToken, read_enum_value(&s, &enum_desc));
}

test "fuzz: JsonScanner handles arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            var scanner = JsonScanner.init(std.testing.allocator, input);
            defer scanner.deinit();
            while (scanner.next() catch return) |_| {}
        }
    }.run, .{});
}
