//! Special JSON encoding/decoding for Google protobuf well-known types.
//!
//! Implements the custom JSON mappings specified by the protobuf JSON mapping
//! specification for:
//! - google.protobuf.Timestamp  -> RFC 3339 string
//! - google.protobuf.Duration   -> "Ns" string
//! - google.protobuf.FieldMask  -> comma-separated camelCase string
//! - Wrapper types (BoolValue, Int32Value, etc.) -> unwrapped JSON value

const std = @import("std");
const testing = std.testing;
const json = @import("json.zig");
const dynamic = @import("dynamic.zig");
const descriptor = @import("descriptor.zig");

const Writer = std.Io.Writer;
const Error = Writer.Error;
const JsonError = json.JsonError;
const JsonScanner = json.JsonScanner;
const DynamicMessage = dynamic.DynamicMessage;
const DynamicValue = dynamic.DynamicValue;

// ══════════════════════════════════════════════════════════════════════
// Type Detection
// ══════════════════════════════════════════════════════════════════════

/// Well-known type category
pub const WellKnownType = enum {
    timestamp,
    duration,
    field_mask,
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

/// Detect a well-known type from a fully-qualified message name.
/// Returns null if the name does not match a supported well-known type.
pub fn detect(full_name: []const u8) ?WellKnownType {
    const map = std.StaticStringMap(WellKnownType).initComptime(.{
        .{ "google.protobuf.Timestamp", .timestamp },
        .{ "google.protobuf.Duration", .duration },
        .{ "google.protobuf.FieldMask", .field_mask },
        .{ "google.protobuf.BoolValue", .bool_value },
        .{ "google.protobuf.Int32Value", .int32_value },
        .{ "google.protobuf.Int64Value", .int64_value },
        .{ "google.protobuf.UInt32Value", .uint32_value },
        .{ "google.protobuf.UInt64Value", .uint64_value },
        .{ "google.protobuf.FloatValue", .float_value },
        .{ "google.protobuf.DoubleValue", .double_value },
        .{ "google.protobuf.StringValue", .string_value },
        .{ "google.protobuf.BytesValue", .bytes_value },
    });
    return map.get(full_name);
}

/// Returns true if the given fully-qualified name is a supported well-known type.
pub fn is_well_known_type(full_name: []const u8) bool {
    return detect(full_name) != null;
}

// ══════════════════════════════════════════════════════════════════════
// Encoding (Zig -> JSON)
// ══════════════════════════════════════════════════════════════════════

/// Encode a DynamicMessage as its well-known type JSON representation.
/// Returns true if the message was handled as a well-known type, false otherwise.
pub fn encode_well_known(msg: *const DynamicMessage, writer: *Writer) Error!bool {
    const wkt = detect(msg.desc.full_name) orelse return false;
    switch (wkt) {
        .timestamp => try encode_timestamp(msg, writer),
        .duration => try encode_duration(msg, writer),
        .field_mask => try encode_field_mask(msg, writer),
        .bool_value => try encode_wrapper_bool(msg, writer),
        .int32_value => try encode_wrapper_int32(msg, writer),
        .int64_value => try encode_wrapper_int64(msg, writer),
        .uint32_value => try encode_wrapper_uint32(msg, writer),
        .uint64_value => try encode_wrapper_uint64(msg, writer),
        .float_value => try encode_wrapper_float(msg, writer),
        .double_value => try encode_wrapper_double(msg, writer),
        .string_value => try encode_wrapper_string(msg, writer),
        .bytes_value => try encode_wrapper_bytes(msg, writer),
    }
    return true;
}

/// Encode google.protobuf.Timestamp as RFC 3339 string.
/// Format: "YYYY-MM-DDThh:mm:ss[.nnnnnnnnn]Z"
fn encode_timestamp(msg: *const DynamicMessage, writer: *Writer) Error!void {
    const seconds = get_int64_field(msg, 1);
    const nanos = get_int32_field(msg, 2);

    // Convert Unix timestamp to calendar date/time
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@as(u64, @bitCast(seconds))) };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();

    const year = year_day.year;
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;
    const hour = day_secs.getHoursIntoDay();
    const minute = day_secs.getMinutesIntoHour();
    const second = day_secs.getSecondsIntoMinute();

    try writer.writeByte('"');
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        year, month, day, hour, minute, second,
    });

    // Append fractional seconds if nanos != 0
    if (nanos != 0) {
        const abs_nanos: u32 = @intCast(if (nanos < 0) @as(u32, @intCast(-@as(i32, nanos))) else @as(u32, @intCast(nanos)));
        if (abs_nanos % 1_000_000 == 0) {
            // Millisecond precision
            try writer.print(".{d:0>3}", .{abs_nanos / 1_000_000});
        } else if (abs_nanos % 1_000 == 0) {
            // Microsecond precision
            try writer.print(".{d:0>6}", .{abs_nanos / 1_000});
        } else {
            // Nanosecond precision
            try writer.print(".{d:0>9}", .{abs_nanos});
        }
    }

    try writer.writeAll("Z\"");
}

/// Encode google.protobuf.Duration as "Xs" string.
/// Format: "Ns" where N may include fractional seconds.
fn encode_duration(msg: *const DynamicMessage, writer: *Writer) Error!void {
    const seconds = get_int64_field(msg, 1);
    const nanos = get_int32_field(msg, 2);

    try writer.writeByte('"');

    // Handle sign: seconds and nanos should have the same sign (or be zero)
    const negative = seconds < 0 or nanos < 0;
    const abs_seconds: u64 = if (seconds < 0) @intCast(-seconds) else @intCast(seconds);
    const abs_nanos: u32 = if (nanos < 0) @intCast(-@as(i32, nanos)) else @intCast(nanos);

    if (negative) {
        try writer.writeByte('-');
    }

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

/// Encode google.protobuf.FieldMask as comma-separated camelCase string.
fn encode_field_mask(msg: *const DynamicMessage, writer: *Writer) Error!void {
    try writer.writeByte('"');

    // paths is field number 1, repeated string
    if (msg.get(1)) |storage| {
        switch (storage.*) {
            .repeated => |list| {
                for (list.items, 0..) |val, i| {
                    if (i > 0) try writer.writeByte(',');
                    try write_camel_case(writer, val.string_val);
                }
            },
            .singular => |val| {
                try write_camel_case(writer, val.string_val);
            },
            else => {},
        }
    }

    try writer.writeByte('"');
}

/// Convert a snake_case string to camelCase and write it.
fn write_camel_case(writer: *Writer, snake: []const u8) Error!void {
    var capitalize_next = false;
    for (snake) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else {
            if (capitalize_next) {
                try writer.writeByte(std.ascii.toUpper(c));
                capitalize_next = false;
            } else {
                try writer.writeByte(c);
            }
        }
    }
}

// ── Wrapper type encoders ───────────────────────────────────────────

fn encode_wrapper_bool(msg: *const DynamicMessage, writer: *Writer) Error!void {
    try json.write_bool(writer, get_bool_field(msg, 1));
}

fn encode_wrapper_int32(msg: *const DynamicMessage, writer: *Writer) Error!void {
    try json.write_int(writer, @as(i64, get_int32_field(msg, 1)));
}

fn encode_wrapper_int64(msg: *const DynamicMessage, writer: *Writer) Error!void {
    try json.write_int_string(writer, get_int64_field(msg, 1));
}

fn encode_wrapper_uint32(msg: *const DynamicMessage, writer: *Writer) Error!void {
    try json.write_uint(writer, @as(u64, get_uint32_field(msg, 1)));
}

fn encode_wrapper_uint64(msg: *const DynamicMessage, writer: *Writer) Error!void {
    try json.write_uint_string(writer, get_uint64_field(msg, 1));
}

fn encode_wrapper_float(msg: *const DynamicMessage, writer: *Writer) Error!void {
    try json.write_float(writer, get_float_field(msg, 1));
}

fn encode_wrapper_double(msg: *const DynamicMessage, writer: *Writer) Error!void {
    try json.write_float(writer, get_double_field(msg, 1));
}

fn encode_wrapper_string(msg: *const DynamicMessage, writer: *Writer) Error!void {
    try json.write_string(writer, get_string_field(msg, 1));
}

fn encode_wrapper_bytes(msg: *const DynamicMessage, writer: *Writer) Error!void {
    try json.write_bytes(writer, get_bytes_field(msg, 1));
}

// ── Field extraction helpers ────────────────────────────────────────

fn get_int64_field(msg: *const DynamicMessage, field_number: i32) i64 {
    if (msg.get(field_number)) |storage| {
        switch (storage.*) {
            .singular => |val| return val.int64_val,
            else => {},
        }
    }
    return 0;
}

fn get_int32_field(msg: *const DynamicMessage, field_number: i32) i32 {
    if (msg.get(field_number)) |storage| {
        switch (storage.*) {
            .singular => |val| return val.int32_val,
            else => {},
        }
    }
    return 0;
}

fn get_uint32_field(msg: *const DynamicMessage, field_number: i32) u32 {
    if (msg.get(field_number)) |storage| {
        switch (storage.*) {
            .singular => |val| return val.uint32_val,
            else => {},
        }
    }
    return 0;
}

fn get_uint64_field(msg: *const DynamicMessage, field_number: i32) u64 {
    if (msg.get(field_number)) |storage| {
        switch (storage.*) {
            .singular => |val| return val.uint64_val,
            else => {},
        }
    }
    return 0;
}

fn get_bool_field(msg: *const DynamicMessage, field_number: i32) bool {
    if (msg.get(field_number)) |storage| {
        switch (storage.*) {
            .singular => |val| return val.bool_val,
            else => {},
        }
    }
    return false;
}

fn get_float_field(msg: *const DynamicMessage, field_number: i32) f32 {
    if (msg.get(field_number)) |storage| {
        switch (storage.*) {
            .singular => |val| return val.float_val,
            else => {},
        }
    }
    return 0.0;
}

fn get_double_field(msg: *const DynamicMessage, field_number: i32) f64 {
    if (msg.get(field_number)) |storage| {
        switch (storage.*) {
            .singular => |val| return val.double_val,
            else => {},
        }
    }
    return 0.0;
}

fn get_string_field(msg: *const DynamicMessage, field_number: i32) []const u8 {
    if (msg.get(field_number)) |storage| {
        switch (storage.*) {
            .singular => |val| return val.string_val,
            else => {},
        }
    }
    return "";
}

fn get_bytes_field(msg: *const DynamicMessage, field_number: i32) []const u8 {
    if (msg.get(field_number)) |storage| {
        switch (storage.*) {
            .singular => |val| return val.bytes_val,
            else => {},
        }
    }
    return "";
}

// ══════════════════════════════════════════════════════════════════════
// Decoding (JSON -> Zig)
// ══════════════════════════════════════════════════════════════════════

/// Decode a well-known type from JSON into a DynamicMessage.
/// Returns true if the message was handled as a well-known type, false otherwise.
/// The scanner should be positioned at the start of the value token.
pub fn decode_well_known(
    allocator: std.mem.Allocator,
    desc: *const descriptor.MessageDescriptor,
    scanner: *JsonScanner,
    msg: *DynamicMessage,
) (JsonError || std.mem.Allocator.Error || DynamicMessage.Error)!bool {
    const wkt = detect(desc.full_name) orelse return false;
    switch (wkt) {
        .timestamp => try decode_timestamp(allocator, scanner, msg),
        .duration => try decode_duration(allocator, scanner, msg),
        .field_mask => try decode_field_mask(allocator, scanner, msg),
        .bool_value => try decode_wrapper_bool(scanner, msg),
        .int32_value => try decode_wrapper_int32(scanner, msg),
        .int64_value => try decode_wrapper_int64(scanner, msg),
        .uint32_value => try decode_wrapper_uint32(scanner, msg),
        .uint64_value => try decode_wrapper_uint64(scanner, msg),
        .float_value => try decode_wrapper_float(scanner, msg),
        .double_value => try decode_wrapper_double(scanner, msg),
        .string_value => try decode_wrapper_string(allocator, scanner, msg),
        .bytes_value => try decode_wrapper_bytes(allocator, scanner, msg),
    }
    return true;
}

/// Decode google.protobuf.Timestamp from an RFC 3339 string.
fn decode_timestamp(
    _: std.mem.Allocator,
    scanner: *JsonScanner,
    msg: *DynamicMessage,
) (JsonError || std.mem.Allocator.Error || DynamicMessage.Error)!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const str = switch (tok) {
        .string => |s| s,
        .null_value => return, // null -> default message
        else => return JsonError.UnexpectedToken,
    };

    const parsed = parse_rfc3339(str) orelse return JsonError.InvalidNumber;
    try msg.set(1, .{ .int64_val = parsed.seconds });
    try msg.set(2, .{ .int32_val = parsed.nanos });
}

const Rfc3339Result = struct {
    seconds: i64,
    nanos: i32,
};

/// Parse an RFC 3339 timestamp string to seconds + nanos.
fn parse_rfc3339(str: []const u8) ?Rfc3339Result {
    // Minimum: "YYYY-MM-DDThh:mm:ssZ" = 20 chars
    if (str.len < 20) return null;

    const year = std.fmt.parseInt(u16, str[0..4], 10) catch return null;
    if (str[4] != '-') return null;
    const month = std.fmt.parseInt(u8, str[5..7], 10) catch return null;
    if (str[7] != '-') return null;
    const day = std.fmt.parseInt(u8, str[8..10], 10) catch return null;
    if (str[10] != 'T' and str[10] != 't') return null;
    const hour = std.fmt.parseInt(u8, str[11..13], 10) catch return null;
    if (str[13] != ':') return null;
    const minute = std.fmt.parseInt(u8, str[14..16], 10) catch return null;
    if (str[16] != ':') return null;
    const second = std.fmt.parseInt(u8, str[17..19], 10) catch return null;

    // Validate ranges
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour > 23) return null;
    if (minute > 59) return null;
    if (second > 59) return null;

    // Parse fractional seconds
    var nanos: i32 = 0;
    var pos: usize = 19;
    if (pos < str.len and str[pos] == '.') {
        pos += 1;
        var frac: u64 = 0;
        var digits: u32 = 0;
        while (pos < str.len and str[pos] >= '0' and str[pos] <= '9') : (pos += 1) {
            if (digits < 9) {
                frac = frac * 10 + (str[pos] - '0');
                digits += 1;
            }
        }
        // Pad to 9 digits
        while (digits < 9) : (digits += 1) {
            frac *= 10;
        }
        nanos = @intCast(frac);
    }

    // Must end with 'Z' (we only support UTC for simplicity, which is what protobuf requires)
    if (pos >= str.len or (str[pos] != 'Z' and str[pos] != 'z')) return null;

    // Convert to epoch seconds
    const epoch_day = epoch_day_from_civil(year, month, day) orelse return null;
    const day_seconds: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    const seconds: i64 = @as(i64, epoch_day) * 86400 + day_seconds;

    return .{ .seconds = seconds, .nanos = nanos };
}

/// Convert civil date to days since Unix epoch (1970-01-01).
fn epoch_day_from_civil(year: u16, month: u8, day: u8) ?i64 {
    // Use std.time.epoch for the conversion
    const y: i32 = @intCast(year);
    // Algorithm from Howard Hinnant's date library (public domain)
    const m: i32 = @intCast(month);
    const d: i32 = @intCast(day);
    const era_y = if (m <= 2) y - 1 else y;
    const era_m: u32 = @intCast(if (m > 2) m - 3 else m + 9);
    const era_d: u32 = @intCast(d - 1);
    const era: i32 = @divFloor(era_y, 400);
    const yoe: u32 = @intCast(era_y - era * 400);
    const doy: u32 = (153 * era_m + 2) / 5 + era_d;
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    const days: i64 = @as(i64, era) * 146097 + @as(i64, doe) - 719468;
    return days;
}

/// Decode google.protobuf.Duration from a "Ns" string.
fn decode_duration(
    _: std.mem.Allocator,
    scanner: *JsonScanner,
    msg: *DynamicMessage,
) (JsonError || std.mem.Allocator.Error || DynamicMessage.Error)!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const str = switch (tok) {
        .string => |s| s,
        .null_value => return,
        else => return JsonError.UnexpectedToken,
    };

    const parsed = parse_duration(str) orelse return JsonError.InvalidNumber;
    try msg.set(1, .{ .int64_val = parsed.seconds });
    try msg.set(2, .{ .int32_val = parsed.nanos });
}

const DurationResult = struct {
    seconds: i64,
    nanos: i32,
};

/// Parse a duration string of the form "Ns" or "-Ns" where N is a decimal number.
fn parse_duration(str: []const u8) ?DurationResult {
    if (str.len < 2) return null; // at least "0s"

    // Must end with 's'
    if (str[str.len - 1] != 's') return null;
    const body = str[0 .. str.len - 1];
    if (body.len == 0) return null;

    // Check for negative sign
    var negative = false;
    var rest = body;
    if (rest[0] == '-') {
        negative = true;
        rest = rest[1..];
        if (rest.len == 0) return null;
    }

    // Parse integer part
    var seconds: u64 = 0;
    var pos: usize = 0;
    while (pos < rest.len and rest[pos] >= '0' and rest[pos] <= '9') : (pos += 1) {
        seconds = seconds *% 10 +% (rest[pos] - '0');
    }

    // Parse fractional part
    var nanos: u64 = 0;
    if (pos < rest.len and rest[pos] == '.') {
        pos += 1;
        var digits: u32 = 0;
        while (pos < rest.len and rest[pos] >= '0' and rest[pos] <= '9') : (pos += 1) {
            if (digits < 9) {
                nanos = nanos * 10 + (rest[pos] - '0');
                digits += 1;
            }
        }
        // Pad to 9 digits
        while (digits < 9) : (digits += 1) {
            nanos *= 10;
        }
    }

    // Must have consumed everything
    if (pos != rest.len) return null;

    var result_seconds: i64 = @intCast(seconds);
    var result_nanos: i32 = @intCast(nanos);

    if (negative) {
        result_seconds = -result_seconds;
        if (result_nanos != 0) {
            result_nanos = -result_nanos;
        }
    }

    return .{ .seconds = result_seconds, .nanos = result_nanos };
}

/// Decode google.protobuf.FieldMask from a comma-separated camelCase string.
fn decode_field_mask(
    allocator: std.mem.Allocator,
    scanner: *JsonScanner,
    msg: *DynamicMessage,
) (JsonError || std.mem.Allocator.Error || DynamicMessage.Error)!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    const str = switch (tok) {
        .string => |s| s,
        .null_value => return,
        else => return JsonError.UnexpectedToken,
    };

    // Empty string means no paths
    if (str.len == 0) return;

    // Split by comma and convert each path from camelCase to snake_case
    var start: usize = 0;
    for (str, 0..) |c, i| {
        if (c == ',') {
            const snake = camel_to_snake(allocator, str[start..i]) catch return JsonError.OutOfMemory;
            defer allocator.free(snake);
            msg.append(1, .{ .string_val = snake }) catch |e| return e;
            start = i + 1;
        }
    }
    // Last segment
    const snake = camel_to_snake(allocator, str[start..]) catch return JsonError.OutOfMemory;
    defer allocator.free(snake);
    msg.append(1, .{ .string_val = snake }) catch |e| return e;
}

/// Convert a camelCase string to snake_case.
fn camel_to_snake(allocator: std.mem.Allocator, camel: []const u8) std.mem.Allocator.Error![]const u8 {
    if (camel.len == 0) {
        return allocator.alloc(u8, 0);
    }

    // Count how many underscores we need to insert
    var extra: usize = 0;
    for (camel) |c| {
        if (std.ascii.isUpper(c)) extra += 1;
    }

    const result = try allocator.alloc(u8, camel.len + extra);
    var j: usize = 0;
    for (camel) |c| {
        if (std.ascii.isUpper(c)) {
            result[j] = '_';
            j += 1;
            result[j] = std.ascii.toLower(c);
            j += 1;
        } else {
            result[j] = c;
            j += 1;
        }
    }

    return result[0..j];
}

// ── Wrapper type decoders ───────────────────────────────────────────

fn decode_wrapper_bool(
    scanner: *JsonScanner,
    msg: *DynamicMessage,
) (JsonError || std.mem.Allocator.Error || DynamicMessage.Error)!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .true_value => try msg.set(1, .{ .bool_val = true }),
        .false_value => try msg.set(1, .{ .bool_val = false }),
        .null_value => {},
        else => return JsonError.UnexpectedToken,
    }
}

fn decode_wrapper_int32(
    scanner: *JsonScanner,
    msg: *DynamicMessage,
) (JsonError || std.mem.Allocator.Error || DynamicMessage.Error)!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .number => |n| {
            const val = std.fmt.parseInt(i32, n, 10) catch return JsonError.Overflow;
            try msg.set(1, .{ .int32_val = val });
        },
        .string => |s| {
            const val = std.fmt.parseInt(i32, s, 10) catch return JsonError.Overflow;
            try msg.set(1, .{ .int32_val = val });
        },
        .null_value => {},
        else => return JsonError.UnexpectedToken,
    }
}

fn decode_wrapper_int64(
    scanner: *JsonScanner,
    msg: *DynamicMessage,
) (JsonError || std.mem.Allocator.Error || DynamicMessage.Error)!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .number => |n| {
            const val = std.fmt.parseInt(i64, n, 10) catch return JsonError.Overflow;
            try msg.set(1, .{ .int64_val = val });
        },
        .string => |s| {
            const val = std.fmt.parseInt(i64, s, 10) catch return JsonError.Overflow;
            try msg.set(1, .{ .int64_val = val });
        },
        .null_value => {},
        else => return JsonError.UnexpectedToken,
    }
}

fn decode_wrapper_uint32(
    scanner: *JsonScanner,
    msg: *DynamicMessage,
) (JsonError || std.mem.Allocator.Error || DynamicMessage.Error)!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .number => |n| {
            const val = std.fmt.parseInt(u32, n, 10) catch return JsonError.Overflow;
            try msg.set(1, .{ .uint32_val = val });
        },
        .string => |s| {
            const val = std.fmt.parseInt(u32, s, 10) catch return JsonError.Overflow;
            try msg.set(1, .{ .uint32_val = val });
        },
        .null_value => {},
        else => return JsonError.UnexpectedToken,
    }
}

fn decode_wrapper_uint64(
    scanner: *JsonScanner,
    msg: *DynamicMessage,
) (JsonError || std.mem.Allocator.Error || DynamicMessage.Error)!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .number => |n| {
            const val = std.fmt.parseInt(u64, n, 10) catch return JsonError.Overflow;
            try msg.set(1, .{ .uint64_val = val });
        },
        .string => |s| {
            const val = std.fmt.parseInt(u64, s, 10) catch return JsonError.Overflow;
            try msg.set(1, .{ .uint64_val = val });
        },
        .null_value => {},
        else => return JsonError.UnexpectedToken,
    }
}

fn decode_wrapper_float(
    scanner: *JsonScanner,
    msg: *DynamicMessage,
) (JsonError || std.mem.Allocator.Error || DynamicMessage.Error)!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .number => |n| {
            const val = std.fmt.parseFloat(f32, n) catch return JsonError.InvalidNumber;
            try msg.set(1, .{ .float_val = val });
        },
        .string => |s| {
            if (std.mem.eql(u8, s, "NaN")) {
                try msg.set(1, .{ .float_val = std.math.nan(f32) });
            } else if (std.mem.eql(u8, s, "Infinity")) {
                try msg.set(1, .{ .float_val = std.math.inf(f32) });
            } else if (std.mem.eql(u8, s, "-Infinity")) {
                try msg.set(1, .{ .float_val = -std.math.inf(f32) });
            } else {
                const val = std.fmt.parseFloat(f32, s) catch return JsonError.InvalidNumber;
                try msg.set(1, .{ .float_val = val });
            }
        },
        .null_value => {},
        else => return JsonError.UnexpectedToken,
    }
}

fn decode_wrapper_double(
    scanner: *JsonScanner,
    msg: *DynamicMessage,
) (JsonError || std.mem.Allocator.Error || DynamicMessage.Error)!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .number => |n| {
            const val = std.fmt.parseFloat(f64, n) catch return JsonError.InvalidNumber;
            try msg.set(1, .{ .double_val = val });
        },
        .string => |s| {
            if (std.mem.eql(u8, s, "NaN")) {
                try msg.set(1, .{ .double_val = std.math.nan(f64) });
            } else if (std.mem.eql(u8, s, "Infinity")) {
                try msg.set(1, .{ .double_val = std.math.inf(f64) });
            } else if (std.mem.eql(u8, s, "-Infinity")) {
                try msg.set(1, .{ .double_val = -std.math.inf(f64) });
            } else {
                const val = std.fmt.parseFloat(f64, s) catch return JsonError.InvalidNumber;
                try msg.set(1, .{ .double_val = val });
            }
        },
        .null_value => {},
        else => return JsonError.UnexpectedToken,
    }
}

fn decode_wrapper_string(
    _: std.mem.Allocator,
    scanner: *JsonScanner,
    msg: *DynamicMessage,
) (JsonError || std.mem.Allocator.Error || DynamicMessage.Error)!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .string => |s| try msg.set(1, .{ .string_val = s }),
        .null_value => {},
        else => return JsonError.UnexpectedToken,
    }
}

fn decode_wrapper_bytes(
    allocator: std.mem.Allocator,
    scanner: *JsonScanner,
    msg: *DynamicMessage,
) (JsonError || std.mem.Allocator.Error || DynamicMessage.Error)!void {
    const tok = try scanner.next() orelse return JsonError.UnexpectedEndOfInput;
    switch (tok) {
        .string => |b64_str| {
            if (b64_str.len == 0) {
                try msg.set(1, .{ .bytes_val = "" });
                return;
            }
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
            // DynamicMessage.set will dupe the bytes, so free our temp buffer
            msg.set(1, .{ .bytes_val = buf }) catch |e| {
                allocator.free(buf);
                return e;
            };
            allocator.free(buf);
        },
        .null_value => {},
        else => return JsonError.UnexpectedToken,
    }
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

fn test_write_wkt(msg: *const DynamicMessage, buf: *[4096]u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    const handled = try encode_well_known(msg, &writer);
    try testing.expect(handled);
    return writer.buffered();
}

// ── Timestamp Descriptor ────────────────────────────────────────────

const timestamp_desc = descriptor.MessageDescriptor{
    .name = "Timestamp",
    .full_name = "google.protobuf.Timestamp",
    .fields = &.{
        .{ .name = "seconds", .number = 1, .field_type = .int64, .label = .implicit },
        .{ .name = "nanos", .number = 2, .field_type = .int32, .label = .implicit },
    },
};

const duration_desc = descriptor.MessageDescriptor{
    .name = "Duration",
    .full_name = "google.protobuf.Duration",
    .fields = &.{
        .{ .name = "seconds", .number = 1, .field_type = .int64, .label = .implicit },
        .{ .name = "nanos", .number = 2, .field_type = .int32, .label = .implicit },
    },
};

const field_mask_desc = descriptor.MessageDescriptor{
    .name = "FieldMask",
    .full_name = "google.protobuf.FieldMask",
    .fields = &.{
        .{ .name = "paths", .number = 1, .field_type = .string, .label = .repeated },
    },
};

const bool_value_desc = descriptor.MessageDescriptor{
    .name = "BoolValue",
    .full_name = "google.protobuf.BoolValue",
    .fields = &.{
        .{ .name = "value", .number = 1, .field_type = .bool, .label = .implicit },
    },
};

const int32_value_desc = descriptor.MessageDescriptor{
    .name = "Int32Value",
    .full_name = "google.protobuf.Int32Value",
    .fields = &.{
        .{ .name = "value", .number = 1, .field_type = .int32, .label = .implicit },
    },
};

const int64_value_desc = descriptor.MessageDescriptor{
    .name = "Int64Value",
    .full_name = "google.protobuf.Int64Value",
    .fields = &.{
        .{ .name = "value", .number = 1, .field_type = .int64, .label = .implicit },
    },
};

const uint32_value_desc = descriptor.MessageDescriptor{
    .name = "UInt32Value",
    .full_name = "google.protobuf.UInt32Value",
    .fields = &.{
        .{ .name = "value", .number = 1, .field_type = .uint32, .label = .implicit },
    },
};

const uint64_value_desc = descriptor.MessageDescriptor{
    .name = "UInt64Value",
    .full_name = "google.protobuf.UInt64Value",
    .fields = &.{
        .{ .name = "value", .number = 1, .field_type = .uint64, .label = .implicit },
    },
};

const float_value_desc = descriptor.MessageDescriptor{
    .name = "FloatValue",
    .full_name = "google.protobuf.FloatValue",
    .fields = &.{
        .{ .name = "value", .number = 1, .field_type = .float, .label = .implicit },
    },
};

const double_value_desc = descriptor.MessageDescriptor{
    .name = "DoubleValue",
    .full_name = "google.protobuf.DoubleValue",
    .fields = &.{
        .{ .name = "value", .number = 1, .field_type = .double, .label = .implicit },
    },
};

const string_value_desc = descriptor.MessageDescriptor{
    .name = "StringValue",
    .full_name = "google.protobuf.StringValue",
    .fields = &.{
        .{ .name = "value", .number = 1, .field_type = .string, .label = .implicit },
    },
};

const bytes_value_desc = descriptor.MessageDescriptor{
    .name = "BytesValue",
    .full_name = "google.protobuf.BytesValue",
    .fields = &.{
        .{ .name = "value", .number = 1, .field_type = .bytes, .label = .implicit },
    },
};

const not_wkt_desc = descriptor.MessageDescriptor{
    .name = "MyMessage",
    .full_name = "example.MyMessage",
    .fields = &.{},
};

// ── Detection Tests ─────────────────────────────────────────────────

test "detect: identifies all well-known types" {
    try testing.expectEqual(WellKnownType.timestamp, detect("google.protobuf.Timestamp").?);
    try testing.expectEqual(WellKnownType.duration, detect("google.protobuf.Duration").?);
    try testing.expectEqual(WellKnownType.field_mask, detect("google.protobuf.FieldMask").?);
    try testing.expectEqual(WellKnownType.bool_value, detect("google.protobuf.BoolValue").?);
    try testing.expectEqual(WellKnownType.int32_value, detect("google.protobuf.Int32Value").?);
    try testing.expectEqual(WellKnownType.int64_value, detect("google.protobuf.Int64Value").?);
    try testing.expectEqual(WellKnownType.uint32_value, detect("google.protobuf.UInt32Value").?);
    try testing.expectEqual(WellKnownType.uint64_value, detect("google.protobuf.UInt64Value").?);
    try testing.expectEqual(WellKnownType.float_value, detect("google.protobuf.FloatValue").?);
    try testing.expectEqual(WellKnownType.double_value, detect("google.protobuf.DoubleValue").?);
    try testing.expectEqual(WellKnownType.string_value, detect("google.protobuf.StringValue").?);
    try testing.expectEqual(WellKnownType.bytes_value, detect("google.protobuf.BytesValue").?);
}

test "detect: returns null for non-well-known types" {
    try testing.expect(detect("example.MyMessage") == null);
    try testing.expect(detect("google.protobuf.Any") == null);
    try testing.expect(detect("google.protobuf.Struct") == null);
    try testing.expect(detect("") == null);
}

test "is_well_known_type" {
    try testing.expect(is_well_known_type("google.protobuf.Timestamp"));
    try testing.expect(!is_well_known_type("example.Foo"));
}

// ── Timestamp Encode Tests ──────────────────────────────────────────

test "encode_timestamp: epoch zero" {
    var msg = DynamicMessage.init(testing.allocator, &timestamp_desc);
    defer msg.deinit();
    try msg.set(1, .{ .int64_val = 0 });
    try msg.set(2, .{ .int32_val = 0 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"1970-01-01T00:00:00Z\"", result);
}

test "encode_timestamp: with milliseconds" {
    var msg = DynamicMessage.init(testing.allocator, &timestamp_desc);
    defer msg.deinit();
    // 2017-01-15T01:30:15.123Z
    try msg.set(1, .{ .int64_val = 1484443815 });
    try msg.set(2, .{ .int32_val = 123_000_000 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"2017-01-15T01:30:15.123Z\"", result);
}

test "encode_timestamp: with microseconds" {
    var msg = DynamicMessage.init(testing.allocator, &timestamp_desc);
    defer msg.deinit();
    try msg.set(1, .{ .int64_val = 1484443815 });
    try msg.set(2, .{ .int32_val = 123_456_000 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"2017-01-15T01:30:15.123456Z\"", result);
}

test "encode_timestamp: with nanoseconds" {
    var msg = DynamicMessage.init(testing.allocator, &timestamp_desc);
    defer msg.deinit();
    try msg.set(1, .{ .int64_val = 1484443815 });
    try msg.set(2, .{ .int32_val = 123_456_789 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"2017-01-15T01:30:15.123456789Z\"", result);
}

test "encode_timestamp: no nanos" {
    var msg = DynamicMessage.init(testing.allocator, &timestamp_desc);
    defer msg.deinit();
    try msg.set(1, .{ .int64_val = 1484443815 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"2017-01-15T01:30:15Z\"", result);
}

test "encode_timestamp: Y2K" {
    var msg = DynamicMessage.init(testing.allocator, &timestamp_desc);
    defer msg.deinit();
    // 2000-01-01T00:00:00Z = 946684800
    try msg.set(1, .{ .int64_val = 946684800 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"2000-01-01T00:00:00Z\"", result);
}

// ── Timestamp Decode Tests ──────────────────────────────────────────

test "decode_timestamp: epoch zero" {
    var scanner = JsonScanner.init(testing.allocator, "\"1970-01-01T00:00:00Z\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &timestamp_desc);
    defer msg.deinit();
    const handled = try decode_well_known(testing.allocator, &timestamp_desc, &scanner, &msg);
    try testing.expect(handled);
    try testing.expectEqual(@as(i64, 0), get_int64_field(&msg, 1));
    try testing.expectEqual(@as(i32, 0), get_int32_field(&msg, 2));
}

test "decode_timestamp: with fractional seconds" {
    var scanner = JsonScanner.init(testing.allocator, "\"2017-01-15T01:30:15.123Z\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &timestamp_desc);
    defer msg.deinit();
    const handled = try decode_well_known(testing.allocator, &timestamp_desc, &scanner, &msg);
    try testing.expect(handled);
    try testing.expectEqual(@as(i64, 1484443815), get_int64_field(&msg, 1));
    try testing.expectEqual(@as(i32, 123_000_000), get_int32_field(&msg, 2));
}

test "decode_timestamp: with nanoseconds" {
    var scanner = JsonScanner.init(testing.allocator, "\"2017-01-15T01:30:15.123456789Z\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &timestamp_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &timestamp_desc, &scanner, &msg);
    try testing.expectEqual(@as(i64, 1484443815), get_int64_field(&msg, 1));
    try testing.expectEqual(@as(i32, 123_456_789), get_int32_field(&msg, 2));
}

test "decode_timestamp: null value" {
    var scanner = JsonScanner.init(testing.allocator, "null");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &timestamp_desc);
    defer msg.deinit();
    const handled = try decode_well_known(testing.allocator, &timestamp_desc, &scanner, &msg);
    try testing.expect(handled);
    // Fields should remain at defaults (not set)
    try testing.expectEqual(@as(i64, 0), get_int64_field(&msg, 1));
}

test "decode_timestamp: round-trip" {
    // Encode a timestamp, then decode it back
    var msg1 = DynamicMessage.init(testing.allocator, &timestamp_desc);
    defer msg1.deinit();
    try msg1.set(1, .{ .int64_val = 1484443815 });
    try msg1.set(2, .{ .int32_val = 123_000_000 });
    var buf: [4096]u8 = undefined;
    const encoded = try test_write_wkt(&msg1, &buf);

    var scanner = JsonScanner.init(testing.allocator, encoded);
    defer scanner.deinit();
    var msg2 = DynamicMessage.init(testing.allocator, &timestamp_desc);
    defer msg2.deinit();
    _ = try decode_well_known(testing.allocator, &timestamp_desc, &scanner, &msg2);
    try testing.expectEqual(@as(i64, 1484443815), get_int64_field(&msg2, 1));
    try testing.expectEqual(@as(i32, 123_000_000), get_int32_field(&msg2, 2));
}

// ── Duration Encode Tests ───────────────────────────────────────────

test "encode_duration: positive whole seconds" {
    var msg = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg.deinit();
    try msg.set(1, .{ .int64_val = 10 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"10s\"", result);
}

test "encode_duration: positive with nanos" {
    var msg = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg.deinit();
    try msg.set(1, .{ .int64_val = 1 });
    try msg.set(2, .{ .int32_val = 500_000_000 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"1.500s\"", result);
}

test "encode_duration: negative" {
    var msg = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg.deinit();
    try msg.set(1, .{ .int64_val = 0 });
    try msg.set(2, .{ .int32_val = -100_000_000 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"-0.100s\"", result);
}

test "encode_duration: negative seconds with nanos" {
    var msg = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg.deinit();
    try msg.set(1, .{ .int64_val = -5 });
    try msg.set(2, .{ .int32_val = -500_000_000 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"-5.500s\"", result);
}

test "encode_duration: zero" {
    var msg = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg.deinit();
    try msg.set(1, .{ .int64_val = 0 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"0s\"", result);
}

test "encode_duration: nanosecond precision" {
    var msg = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg.deinit();
    try msg.set(1, .{ .int64_val = 3 });
    try msg.set(2, .{ .int32_val = 1 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"3.000000001s\"", result);
}

// ── Duration Decode Tests ───────────────────────────────────────────

test "decode_duration: positive whole seconds" {
    var scanner = JsonScanner.init(testing.allocator, "\"10s\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &duration_desc, &scanner, &msg);
    try testing.expectEqual(@as(i64, 10), get_int64_field(&msg, 1));
    try testing.expectEqual(@as(i32, 0), get_int32_field(&msg, 2));
}

test "decode_duration: positive with nanos" {
    var scanner = JsonScanner.init(testing.allocator, "\"1.5s\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &duration_desc, &scanner, &msg);
    try testing.expectEqual(@as(i64, 1), get_int64_field(&msg, 1));
    try testing.expectEqual(@as(i32, 500_000_000), get_int32_field(&msg, 2));
}

test "decode_duration: negative" {
    var scanner = JsonScanner.init(testing.allocator, "\"-0.100s\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &duration_desc, &scanner, &msg);
    try testing.expectEqual(@as(i64, 0), get_int64_field(&msg, 1));
    try testing.expectEqual(@as(i32, -100_000_000), get_int32_field(&msg, 2));
}

test "decode_duration: negative seconds with nanos" {
    var scanner = JsonScanner.init(testing.allocator, "\"-5.500s\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &duration_desc, &scanner, &msg);
    try testing.expectEqual(@as(i64, -5), get_int64_field(&msg, 1));
    try testing.expectEqual(@as(i32, -500_000_000), get_int32_field(&msg, 2));
}

test "decode_duration: zero" {
    var scanner = JsonScanner.init(testing.allocator, "\"0s\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &duration_desc, &scanner, &msg);
    try testing.expectEqual(@as(i64, 0), get_int64_field(&msg, 1));
    try testing.expectEqual(@as(i32, 0), get_int32_field(&msg, 2));
}

test "decode_duration: null" {
    var scanner = JsonScanner.init(testing.allocator, "null");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &duration_desc, &scanner, &msg);
    try testing.expectEqual(@as(i64, 0), get_int64_field(&msg, 1));
}

test "decode_duration: round-trip" {
    var msg1 = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg1.deinit();
    try msg1.set(1, .{ .int64_val = 100 });
    try msg1.set(2, .{ .int32_val = 500_000_000 });
    var buf: [4096]u8 = undefined;
    const encoded = try test_write_wkt(&msg1, &buf);

    var scanner = JsonScanner.init(testing.allocator, encoded);
    defer scanner.deinit();
    var msg2 = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg2.deinit();
    _ = try decode_well_known(testing.allocator, &duration_desc, &scanner, &msg2);
    try testing.expectEqual(@as(i64, 100), get_int64_field(&msg2, 1));
    try testing.expectEqual(@as(i32, 500_000_000), get_int32_field(&msg2, 2));
}

test "decode_duration: invalid format" {
    // Missing 's' suffix
    var scanner = JsonScanner.init(testing.allocator, "\"10\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &duration_desc);
    defer msg.deinit();
    try testing.expectError(JsonError.InvalidNumber, decode_well_known(testing.allocator, &duration_desc, &scanner, &msg));
}

// ── FieldMask Encode Tests ──────────────────────────────────────────

test "encode_field_mask: single path" {
    var msg = DynamicMessage.init(testing.allocator, &field_mask_desc);
    defer msg.deinit();
    try msg.append(1, .{ .string_val = "foo_bar" });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"fooBar\"", result);
}

test "encode_field_mask: multiple paths" {
    var msg = DynamicMessage.init(testing.allocator, &field_mask_desc);
    defer msg.deinit();
    try msg.append(1, .{ .string_val = "foo_bar" });
    try msg.append(1, .{ .string_val = "baz_qux" });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"fooBar,bazQux\"", result);
}

test "encode_field_mask: no underscore" {
    var msg = DynamicMessage.init(testing.allocator, &field_mask_desc);
    defer msg.deinit();
    try msg.append(1, .{ .string_val = "simple" });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"simple\"", result);
}

test "encode_field_mask: empty" {
    var msg = DynamicMessage.init(testing.allocator, &field_mask_desc);
    defer msg.deinit();
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"\"", result);
}

test "encode_field_mask: nested paths" {
    var msg = DynamicMessage.init(testing.allocator, &field_mask_desc);
    defer msg.deinit();
    try msg.append(1, .{ .string_val = "user_name" });
    try msg.append(1, .{ .string_val = "display_name" });
    try msg.append(1, .{ .string_val = "email_address" });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"userName,displayName,emailAddress\"", result);
}

// ── FieldMask Decode Tests ──────────────────────────────────────────

test "decode_field_mask: single path" {
    var scanner = JsonScanner.init(testing.allocator, "\"fooBar\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &field_mask_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &field_mask_desc, &scanner, &msg);
    const storage = msg.get(1) orelse return error.TestUnexpectedResult;
    switch (storage.*) {
        .repeated => |list| {
            try testing.expectEqual(@as(usize, 1), list.items.len);
            try testing.expectEqualStrings("foo_bar", list.items[0].string_val);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "decode_field_mask: multiple paths" {
    var scanner = JsonScanner.init(testing.allocator, "\"fooBar,bazQux\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &field_mask_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &field_mask_desc, &scanner, &msg);
    const storage = msg.get(1) orelse return error.TestUnexpectedResult;
    switch (storage.*) {
        .repeated => |list| {
            try testing.expectEqual(@as(usize, 2), list.items.len);
            try testing.expectEqualStrings("foo_bar", list.items[0].string_val);
            try testing.expectEqualStrings("baz_qux", list.items[1].string_val);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "decode_field_mask: empty string" {
    var scanner = JsonScanner.init(testing.allocator, "\"\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &field_mask_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &field_mask_desc, &scanner, &msg);
    // No paths should have been added
    try testing.expect(msg.get(1) == null);
}

test "decode_field_mask: null" {
    var scanner = JsonScanner.init(testing.allocator, "null");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &field_mask_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &field_mask_desc, &scanner, &msg);
    try testing.expect(msg.get(1) == null);
}

test "decode_field_mask: no camel case" {
    var scanner = JsonScanner.init(testing.allocator, "\"simple\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &field_mask_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &field_mask_desc, &scanner, &msg);
    const storage = msg.get(1) orelse return error.TestUnexpectedResult;
    switch (storage.*) {
        .repeated => |list| {
            try testing.expectEqual(@as(usize, 1), list.items.len);
            try testing.expectEqualStrings("simple", list.items[0].string_val);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ── Wrapper Type Encode Tests ───────────────────────────────────────

test "encode_wrapper: BoolValue true" {
    var msg = DynamicMessage.init(testing.allocator, &bool_value_desc);
    defer msg.deinit();
    try msg.set(1, .{ .bool_val = true });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("true", result);
}

test "encode_wrapper: BoolValue false" {
    var msg = DynamicMessage.init(testing.allocator, &bool_value_desc);
    defer msg.deinit();
    try msg.set(1, .{ .bool_val = false });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("false", result);
}

test "encode_wrapper: Int32Value" {
    var msg = DynamicMessage.init(testing.allocator, &int32_value_desc);
    defer msg.deinit();
    try msg.set(1, .{ .int32_val = -42 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("-42", result);
}

test "encode_wrapper: Int64Value" {
    var msg = DynamicMessage.init(testing.allocator, &int64_value_desc);
    defer msg.deinit();
    try msg.set(1, .{ .int64_val = 9223372036854775807 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"9223372036854775807\"", result);
}

test "encode_wrapper: UInt32Value" {
    var msg = DynamicMessage.init(testing.allocator, &uint32_value_desc);
    defer msg.deinit();
    try msg.set(1, .{ .uint32_val = 100 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("100", result);
}

test "encode_wrapper: UInt64Value" {
    var msg = DynamicMessage.init(testing.allocator, &uint64_value_desc);
    defer msg.deinit();
    try msg.set(1, .{ .uint64_val = 18446744073709551615 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"18446744073709551615\"", result);
}

test "encode_wrapper: FloatValue" {
    var msg = DynamicMessage.init(testing.allocator, &float_value_desc);
    defer msg.deinit();
    try msg.set(1, .{ .float_val = 1.5 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("1.5", result);
}

test "encode_wrapper: DoubleValue" {
    var msg = DynamicMessage.init(testing.allocator, &double_value_desc);
    defer msg.deinit();
    try msg.set(1, .{ .double_val = 3.14 });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("3.14", result);
}

test "encode_wrapper: StringValue" {
    var msg = DynamicMessage.init(testing.allocator, &string_value_desc);
    defer msg.deinit();
    try msg.set(1, .{ .string_val = "hello world" });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"hello world\"", result);
}

test "encode_wrapper: BytesValue" {
    var msg = DynamicMessage.init(testing.allocator, &bytes_value_desc);
    defer msg.deinit();
    try msg.set(1, .{ .bytes_val = "hello" });
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("\"aGVsbG8=\"", result);
}

test "encode_wrapper: default BoolValue (no field set)" {
    var msg = DynamicMessage.init(testing.allocator, &bool_value_desc);
    defer msg.deinit();
    var buf: [4096]u8 = undefined;
    const result = try test_write_wkt(&msg, &buf);
    try testing.expectEqualStrings("false", result);
}

// ── Wrapper Type Decode Tests ───────────────────────────────────────

test "decode_wrapper: BoolValue true" {
    var scanner = JsonScanner.init(testing.allocator, "true");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &bool_value_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &bool_value_desc, &scanner, &msg);
    const storage = msg.get(1) orelse return error.TestUnexpectedResult;
    try testing.expect(storage.singular.bool_val);
}

test "decode_wrapper: BoolValue false" {
    var scanner = JsonScanner.init(testing.allocator, "false");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &bool_value_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &bool_value_desc, &scanner, &msg);
    const storage = msg.get(1) orelse return error.TestUnexpectedResult;
    try testing.expect(!storage.singular.bool_val);
}

test "decode_wrapper: Int32Value" {
    var scanner = JsonScanner.init(testing.allocator, "-42");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &int32_value_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &int32_value_desc, &scanner, &msg);
    try testing.expectEqual(@as(i32, -42), get_int32_field(&msg, 1));
}

test "decode_wrapper: Int64Value from string" {
    var scanner = JsonScanner.init(testing.allocator, "\"9223372036854775807\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &int64_value_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &int64_value_desc, &scanner, &msg);
    try testing.expectEqual(@as(i64, 9223372036854775807), get_int64_field(&msg, 1));
}

test "decode_wrapper: UInt32Value" {
    var scanner = JsonScanner.init(testing.allocator, "100");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &uint32_value_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &uint32_value_desc, &scanner, &msg);
    try testing.expectEqual(@as(u32, 100), get_uint32_field(&msg, 1));
}

test "decode_wrapper: UInt64Value from string" {
    var scanner = JsonScanner.init(testing.allocator, "\"18446744073709551615\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &uint64_value_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &uint64_value_desc, &scanner, &msg);
    try testing.expectEqual(@as(u64, 18446744073709551615), get_uint64_field(&msg, 1));
}

test "decode_wrapper: FloatValue" {
    var scanner = JsonScanner.init(testing.allocator, "1.5");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &float_value_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &float_value_desc, &scanner, &msg);
    try testing.expectEqual(@as(f32, 1.5), get_float_field(&msg, 1));
}

test "decode_wrapper: DoubleValue" {
    var scanner = JsonScanner.init(testing.allocator, "3.14");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &double_value_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &double_value_desc, &scanner, &msg);
    try testing.expectEqual(@as(f64, 3.14), get_double_field(&msg, 1));
}

test "decode_wrapper: StringValue" {
    var scanner = JsonScanner.init(testing.allocator, "\"hello world\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &string_value_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &string_value_desc, &scanner, &msg);
    try testing.expectEqualStrings("hello world", get_string_field(&msg, 1));
}

test "decode_wrapper: BytesValue" {
    var scanner = JsonScanner.init(testing.allocator, "\"aGVsbG8=\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &bytes_value_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &bytes_value_desc, &scanner, &msg);
    try testing.expectEqualStrings("hello", get_bytes_field(&msg, 1));
}

test "decode_wrapper: null BoolValue" {
    var scanner = JsonScanner.init(testing.allocator, "null");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &bool_value_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &bool_value_desc, &scanner, &msg);
    // null should leave the message at defaults (no field set)
    try testing.expect(msg.get(1) == null);
}

test "decode_wrapper: FloatValue NaN" {
    var scanner = JsonScanner.init(testing.allocator, "\"NaN\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &float_value_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &float_value_desc, &scanner, &msg);
    try testing.expect(std.math.isNan(get_float_field(&msg, 1)));
}

test "decode_wrapper: DoubleValue Infinity" {
    var scanner = JsonScanner.init(testing.allocator, "\"Infinity\"");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &double_value_desc);
    defer msg.deinit();
    _ = try decode_well_known(testing.allocator, &double_value_desc, &scanner, &msg);
    try testing.expect(std.math.isInf(get_double_field(&msg, 1)));
}

// ── Non-WKT passthrough test ────────────────────────────────────────

test "encode_well_known: returns false for non-WKT" {
    var msg = DynamicMessage.init(testing.allocator, &not_wkt_desc);
    defer msg.deinit();
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const handled = try encode_well_known(&msg, &writer);
    try testing.expect(!handled);
}

test "decode_well_known: returns false for non-WKT" {
    var scanner = JsonScanner.init(testing.allocator, "{}");
    defer scanner.deinit();
    var msg = DynamicMessage.init(testing.allocator, &not_wkt_desc);
    defer msg.deinit();
    const handled = try decode_well_known(testing.allocator, &not_wkt_desc, &scanner, &msg);
    try testing.expect(!handled);
}

// ── Internal helper tests ───────────────────────────────────────────

test "camel_to_snake: simple" {
    const result = try camel_to_snake(testing.allocator, "fooBar");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("foo_bar", result);
}

test "camel_to_snake: multiple humps" {
    const result = try camel_to_snake(testing.allocator, "fooBarBaz");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("foo_bar_baz", result);
}

test "camel_to_snake: no uppercase" {
    const result = try camel_to_snake(testing.allocator, "simple");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("simple", result);
}

test "camel_to_snake: empty" {
    const result = try camel_to_snake(testing.allocator, "");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "write_camel_case: simple" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try write_camel_case(&writer, "foo_bar");
    try testing.expectEqualStrings("fooBar", writer.buffered());
}

test "write_camel_case: no underscores" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try write_camel_case(&writer, "simple");
    try testing.expectEqualStrings("simple", writer.buffered());
}

test "write_camel_case: multiple underscores" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try write_camel_case(&writer, "foo_bar_baz");
    try testing.expectEqualStrings("fooBarBaz", writer.buffered());
}

test "parse_rfc3339: valid epoch" {
    const result = parse_rfc3339("1970-01-01T00:00:00Z").?;
    try testing.expectEqual(@as(i64, 0), result.seconds);
    try testing.expectEqual(@as(i32, 0), result.nanos);
}

test "parse_rfc3339: with fractional" {
    const result = parse_rfc3339("2017-01-15T01:30:15.123Z").?;
    try testing.expectEqual(@as(i64, 1484443815), result.seconds);
    try testing.expectEqual(@as(i32, 123_000_000), result.nanos);
}

test "parse_rfc3339: too short" {
    try testing.expect(parse_rfc3339("2017") == null);
}

test "parse_rfc3339: missing Z" {
    try testing.expect(parse_rfc3339("1970-01-01T00:00:00") == null);
}

test "parse_duration: valid" {
    const result = parse_duration("1.5s").?;
    try testing.expectEqual(@as(i64, 1), result.seconds);
    try testing.expectEqual(@as(i32, 500_000_000), result.nanos);
}

test "parse_duration: negative" {
    const result = parse_duration("-3.5s").?;
    try testing.expectEqual(@as(i64, -3), result.seconds);
    try testing.expectEqual(@as(i32, -500_000_000), result.nanos);
}

test "parse_duration: no suffix" {
    try testing.expect(parse_duration("10") == null);
}

test "parse_duration: empty" {
    try testing.expect(parse_duration("") == null);
}

test "parse_duration: just s" {
    try testing.expect(parse_duration("s") == null);
}
