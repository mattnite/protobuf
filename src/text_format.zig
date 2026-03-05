const std = @import("std");
const testing = std.testing;

const Writer = std.Io.Writer;
const Error = Writer.Error;

// ══════════════════════════════════════════════════════════════════════
// Text Format Write Helpers
// ══════════════════════════════════════════════════════════════════════

/// Write indentation (2 spaces per level) for text format output
pub fn write_indent(writer: *Writer, indent_level: usize) Error!void {
    for (0..indent_level) |_| {
        try writer.writeAll("  ");
    }
}

/// Write a C-style quoted string with escape handling
pub fn write_string(writer: *Writer, value: []const u8) Error!void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20 or c >= 0x7F) {
                    try writer.writeAll("\\x");
                    const hex = "0123456789abcdef";
                    try writer.writeByte(hex[c >> 4]);
                    try writer.writeByte(hex[c & 0x0F]);
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

/// Write a byte slice as a C-style quoted string
pub fn write_bytes(writer: *Writer, value: []const u8) Error!void {
    // Text format uses same quoted string syntax for bytes
    try write_string(writer, value);
}

/// Write a signed integer as a decimal number
pub fn write_int(writer: *Writer, value: i64) Error!void {
    try writer.print("{d}", .{value});
}

/// Write an unsigned integer as a decimal number
pub fn write_uint(writer: *Writer, value: u64) Error!void {
    try writer.print("{d}", .{value});
}

/// Write a float value, using bare nan/inf for special values
pub fn write_float(writer: *Writer, value: anytype) Error!void {
    const T = @TypeOf(value);
    if (T != f32 and T != f64) @compileError("write_float expects f32 or f64");
    if (std.math.isNan(value)) {
        try writer.writeAll("nan");
    } else if (std.math.isInf(value)) {
        if (value < 0) {
            try writer.writeAll("-inf");
        } else {
            try writer.writeAll("inf");
        }
    } else if (value == 0 and std.math.signbit(value)) {
        // Negative zero: write explicitly so the sign is preserved
        try writer.writeAll("-0");
    } else {
        try writer.print("{d}", .{value});
    }
}

/// Write a boolean as `true` or `false`
pub fn write_bool(writer: *Writer, value: bool) Error!void {
    try writer.writeAll(if (value) "true" else "false");
}

/// Write an enum value as its bare identifier name
pub fn write_enum_name(writer: *Writer, name: []const u8) Error!void {
    try writer.writeAll(name);
}

/// Write an enum value as its identifier name when known, or as an integer.
/// This is required for proto2/closed-enum unknown values, which may be held
/// as raw numeric enum payloads and do not have a tag name.
pub fn write_enum_value(writer: *Writer, value: anytype) Error!void {
    const T = @TypeOf(value);
    const ti = @typeInfo(T);
    if (ti != .@"enum") @compileError("write_enum_value expects an enum value");

    const int_value = @intFromEnum(value);
    inline for (ti.@"enum".fields) |field| {
        if (field.value == int_value) {
            try writer.writeAll(field.name);
            return;
        }
    }

    try writer.print("{d}", .{int_value});
}

// ══════════════════════════════════════════════════════════════════════
// Text Format Scanner (Deserialization)
// ══════════════════════════════════════════════════════════════════════

/// Error set for text format parsing operations
pub const TextError = error{
    UnexpectedToken,
    UnexpectedEndOfInput,
    InvalidNumber,
    InvalidEscape,
    InvalidUtf8,
    Overflow,
    OutOfMemory,
};

/// Complete error set for generated from_text_scanner_inner methods (TextError + recursion)
pub const DecodeError = TextError || error{RecursionLimitExceeded};

/// Tagged union of text format token types from the scanner
pub const TextToken = union(enum) {
    identifier: []const u8,
    string_literal: []const u8,
    integer: []const u8,
    float_literal: []const u8,
    colon,
    open_brace,
    close_brace,
    comma,
    semicolon,
    open_bracket,
    close_bracket,
    open_angle,
    close_angle,
};

/// Pull-based tokenizer for protobuf text format input
pub const TextScanner = struct {
    source: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    peeked: ?TextToken,
    allocated_strings: std.ArrayListUnmanaged([]const u8),

    /// Create a scanner over a text format byte slice
    pub fn init(allocator: std.mem.Allocator, source: []const u8) TextScanner {
        return .{
            .source = source,
            .pos = 0,
            .allocator = allocator,
            .peeked = null,
            .allocated_strings = .empty,
        };
    }

    /// Free all scanner-allocated memory
    pub fn deinit(self: *TextScanner) void {
        for (self.allocated_strings.items) |s| {
            self.allocator.free(s);
        }
        self.allocated_strings.deinit(self.allocator);
    }

    /// Consume and return the next token, or null at end of input
    pub fn next(self: *TextScanner) TextError!?TextToken {
        if (self.peeked) |tok| {
            self.peeked = null;
            return tok;
        }
        return self.next_inner();
    }

    /// Return the next token without consuming it
    pub fn peek(self: *TextScanner) TextError!?TextToken {
        if (self.peeked) |tok| {
            return tok;
        }
        self.peeked = try self.next_inner();
        return self.peeked;
    }

    /// Expect and consume a colon token.
    pub fn expect_colon(self: *TextScanner) TextError!void {
        const tok = try self.next() orelse return TextError.UnexpectedEndOfInput;
        switch (tok) {
            .colon => {},
            else => return TextError.UnexpectedToken,
        }
    }

    /// Expect and consume an open brace token.
    pub fn expect_open_brace(self: *TextScanner) TextError!void {
        const tok = try self.next() orelse return TextError.UnexpectedEndOfInput;
        switch (tok) {
            .open_brace => {},
            else => return TextError.UnexpectedToken,
        }
    }

    /// Expect and consume a close brace token.
    pub fn expect_close_brace(self: *TextScanner) TextError!void {
        const tok = try self.next() orelse return TextError.UnexpectedEndOfInput;
        switch (tok) {
            .close_brace => {},
            else => return TextError.UnexpectedToken,
        }
    }

    fn next_inner(self: *TextScanner) TextError!?TextToken {
        self.skip_whitespace_and_comments();
        if (self.pos >= self.source.len) return null;

        const c = self.source[self.pos];
        switch (c) {
            ':' => {
                self.pos += 1;
                return .colon;
            },
            '{' => {
                self.pos += 1;
                return .open_brace;
            },
            '}' => {
                self.pos += 1;
                return .close_brace;
            },
            ',' => {
                self.pos += 1;
                return .comma;
            },
            ';' => {
                self.pos += 1;
                return .semicolon;
            },
            '[' => {
                self.pos += 1;
                return .open_bracket;
            },
            ']' => {
                self.pos += 1;
                return .close_bracket;
            },
            '<' => {
                self.pos += 1;
                return .open_angle;
            },
            '>' => {
                self.pos += 1;
                return .close_angle;
            },
            '"', '\'' => return try self.scan_string_with_concat(),
            '.' => return self.scan_number(), // no-leading-zero: .5
            else => {
                if (c == '-') {
                    // Could be negative number or -.5 etc
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '.') {
                        return self.scan_number();
                    }
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] >= '0' and self.source[self.pos + 1] <= '9') {
                        return self.scan_number();
                    }
                    // Bare '-' followed by identifier (e.g., "-inf")
                    // Don't consume, let it be handled as unexpected
                    return self.scan_number();
                }
                if (c >= '0' and c <= '9') {
                    return self.scan_number();
                }
                if (is_ident_start(c)) {
                    return self.scan_identifier();
                }
                return TextError.UnexpectedToken;
            },
        }
    }

    fn skip_whitespace_and_comments(self: *TextScanner) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (c == '#') {
                // Skip to end of line
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn scan_single_string(self: *TextScanner) TextError![]const u8 {
        const quote = self.source[self.pos];
        self.pos += 1;
        const start = self.pos;
        var has_escapes = false;

        while (self.pos < self.source.len and self.source[self.pos] != quote) {
            if (self.source[self.pos] == '\n') {
                // Raw LF in string literal is a parse error
                return TextError.InvalidEscape;
            }
            if (self.source[self.pos] == '\\') {
                has_escapes = true;
                self.pos += 1; // skip backslash
                if (self.pos >= self.source.len) return TextError.InvalidEscape;
                // Skip the escaped character
                const esc = self.source[self.pos];
                if (esc == 'x') {
                    self.pos += 1; // skip 'x'
                    // Skip 2 hex digits
                    if (self.pos + 2 > self.source.len) return TextError.InvalidEscape;
                    self.pos += 2;
                } else if (esc == 'U') {
                    self.pos += 1; // skip 'U'
                    // 8 hex digits
                    if (self.pos + 8 > self.source.len) return TextError.InvalidEscape;
                    self.pos += 8;
                } else if (esc == 'u') {
                    self.pos += 1; // skip 'u'
                    // 4 hex digits
                    if (self.pos + 4 > self.source.len) return TextError.InvalidEscape;
                    self.pos += 4;
                } else if (esc >= '0' and esc <= '7') {
                    // Octal: up to 3 digits
                    self.pos += 1;
                    if (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '7') {
                        self.pos += 1;
                        if (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '7') {
                            self.pos += 1;
                        }
                    }
                } else {
                    self.pos += 1;
                }
            } else {
                self.pos += 1;
            }
        }

        if (self.pos >= self.source.len) return TextError.UnexpectedEndOfInput;
        const end = self.pos;
        self.pos += 1; // skip closing quote

        if (!has_escapes) {
            return self.source[start..end];
        }

        // Need to resolve escapes
        return try self.resolve_escapes(self.source[start..end]);
    }

    /// Scan a string, then check for adjacent string literals and concatenate them
    fn scan_string_with_concat(self: *TextScanner) TextError!TextToken {
        const first = try self.scan_single_string();

        // Check for adjacent string literals (string concatenation)
        self.skip_whitespace_and_comments();
        if (self.pos < self.source.len and (self.source[self.pos] == '"' or self.source[self.pos] == '\'')) {
            // Concatenate strings
            var parts = std.ArrayListUnmanaged([]const u8).empty;
            defer parts.deinit(self.allocator);
            parts.append(self.allocator, first) catch return TextError.OutOfMemory;
            var total_len: usize = first.len;

            while (self.pos < self.source.len and (self.source[self.pos] == '"' or self.source[self.pos] == '\'')) {
                const part = try self.scan_single_string();
                parts.append(self.allocator, part) catch return TextError.OutOfMemory;
                total_len += part.len;
                self.skip_whitespace_and_comments();
            }

            // Allocate concatenated result
            const result = self.allocator.alloc(u8, total_len) catch return TextError.OutOfMemory;
            var offset: usize = 0;
            for (parts.items) |part| {
                @memcpy(result[offset..][0..part.len], part);
                offset += part.len;
            }
            self.allocated_strings.append(self.allocator, result) catch {
                self.allocator.free(result);
                return TextError.OutOfMemory;
            };
            return .{ .string_literal = result };
        }

        return .{ .string_literal = first };
    }

    fn resolve_escapes(self: *TextScanner, raw: []const u8) TextError![]const u8 {
        // Allocate extra for potential UTF-8 expansions from \u/\U escapes
        var result = self.allocator.alloc(u8, raw.len * 4) catch return TextError.OutOfMemory;
        var out: usize = 0;
        var i: usize = 0;

        while (i < raw.len) {
            if (raw[i] == '\\') {
                i += 1;
                if (i >= raw.len) {
                    self.allocator.free(result);
                    return TextError.InvalidEscape;
                }
                switch (raw[i]) {
                    'n' => {
                        result[out] = '\n';
                        out += 1;
                        i += 1;
                    },
                    'r' => {
                        result[out] = '\r';
                        out += 1;
                        i += 1;
                    },
                    't' => {
                        result[out] = '\t';
                        out += 1;
                        i += 1;
                    },
                    'a' => {
                        result[out] = 0x07; // bell
                        out += 1;
                        i += 1;
                    },
                    'b' => {
                        result[out] = 0x08; // backspace
                        out += 1;
                        i += 1;
                    },
                    'f' => {
                        result[out] = 0x0C; // form feed
                        out += 1;
                        i += 1;
                    },
                    'v' => {
                        result[out] = 0x0B; // vertical tab
                        out += 1;
                        i += 1;
                    },
                    '\\' => {
                        result[out] = '\\';
                        out += 1;
                        i += 1;
                    },
                    '"' => {
                        result[out] = '"';
                        out += 1;
                        i += 1;
                    },
                    '\'' => {
                        result[out] = '\'';
                        out += 1;
                        i += 1;
                    },
                    'x' => {
                        i += 1;
                        if (i + 2 > raw.len) {
                            self.allocator.free(result);
                            return TextError.InvalidEscape;
                        }
                        const hi = hex_digit(raw[i]) orelse {
                            self.allocator.free(result);
                            return TextError.InvalidEscape;
                        };
                        const lo = hex_digit(raw[i + 1]) orelse {
                            self.allocator.free(result);
                            return TextError.InvalidEscape;
                        };
                        result[out] = (hi << 4) | lo;
                        out += 1;
                        i += 2;
                    },
                    'u' => {
                        // \uHHHH — 4-digit unicode
                        i += 1;
                        if (i + 4 > raw.len) {
                            self.allocator.free(result);
                            return TextError.InvalidEscape;
                        }
                        var codepoint: u21 = 0;
                        for (0..4) |_| {
                            const d = hex_digit(raw[i]) orelse {
                                self.allocator.free(result);
                                return TextError.InvalidEscape;
                            };
                            codepoint = codepoint * 16 + d;
                            i += 1;
                        }
                        const len = std.unicode.utf8Encode(codepoint, result[out..][0..4]) catch {
                            self.allocator.free(result);
                            return TextError.InvalidEscape;
                        };
                        out += len;
                    },
                    'U' => {
                        // \UHHHHHHHH — 8-digit unicode
                        i += 1;
                        if (i + 8 > raw.len) {
                            self.allocator.free(result);
                            return TextError.InvalidEscape;
                        }
                        var codepoint: u32 = 0;
                        for (0..8) |_| {
                            const d = hex_digit(raw[i]) orelse {
                                self.allocator.free(result);
                                return TextError.InvalidEscape;
                            };
                            codepoint = codepoint * 16 + d;
                            i += 1;
                        }
                        if (codepoint > 0x10FFFF) {
                            self.allocator.free(result);
                            return TextError.InvalidEscape;
                        }
                        const len = std.unicode.utf8Encode(@intCast(codepoint), result[out..][0..4]) catch {
                            self.allocator.free(result);
                            return TextError.InvalidEscape;
                        };
                        out += len;
                    },
                    '0'...'7' => {
                        // Octal escape
                        var val: u8 = raw[i] - '0';
                        i += 1;
                        if (i < raw.len and raw[i] >= '0' and raw[i] <= '7') {
                            val = val * 8 + (raw[i] - '0');
                            i += 1;
                            if (i < raw.len and raw[i] >= '0' and raw[i] <= '7') {
                                val = val * 8 + (raw[i] - '0');
                                i += 1;
                            }
                        }
                        result[out] = val;
                        out += 1;
                    },
                    else => {
                        // Unknown escape: just pass through
                        result[out] = raw[i];
                        out += 1;
                        i += 1;
                    },
                }
            } else {
                result[out] = raw[i];
                out += 1;
                i += 1;
            }
        }

        // Shrink to actual size
        if (out < result.len) {
            const shrunk = self.allocator.realloc(result, out) catch result;
            self.allocated_strings.append(self.allocator, shrunk[0..out]) catch {
                self.allocator.free(shrunk);
                return TextError.OutOfMemory;
            };
            return shrunk[0..out];
        }
        self.allocated_strings.append(self.allocator, result) catch {
            self.allocator.free(result);
            return TextError.OutOfMemory;
        };
        return result;
    }

    fn scan_number(self: *TextScanner) TextToken {
        const start = self.pos;
        var is_float = false;

        // Optional leading minus
        if (self.pos < self.source.len and self.source[self.pos] == '-') {
            self.pos += 1;
            // Check if next is identifier (e.g., -inf, -infinity, -nan)
            if (self.pos < self.source.len and is_ident_start(self.source[self.pos])) {
                while (self.pos < self.source.len and is_ident_char(self.source[self.pos])) {
                    self.pos += 1;
                }
                return .{ .float_literal = self.source[start..self.pos] };
            }
        }

        // Check for no-leading-zero: starts with '.'
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            is_float = true;
            self.pos += 1;
            while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
                self.pos += 1;
            }
            // Exponent after no-leading-zero
            if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
                self.pos += 1;
                if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                    self.pos += 1;
                }
                while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
                    self.pos += 1;
                }
            }
            // Consume trailing F/f suffix
            if (self.pos < self.source.len and (self.source[self.pos] == 'F' or self.source[self.pos] == 'f')) {
                self.pos += 1;
            }
            return .{ .float_literal = self.source[start..self.pos] };
        }

        // Check for hex (0x/0X) or octal (leading 0) prefix
        if (self.pos < self.source.len and self.source[self.pos] == '0') {
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == 'x' or self.source[self.pos] == 'X')) {
                // Hex literal
                self.pos += 1;
                while (self.pos < self.source.len and is_hex_char(self.source[self.pos])) {
                    self.pos += 1;
                }
                return .{ .integer = self.source[start..self.pos] };
            }
            // Could be octal (leading 0), or just "0", or "0.5" float
            // Consume remaining octal/decimal digits
            while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
                self.pos += 1;
            }
            // Check for decimal point (it's a float, not octal)
            if (self.pos < self.source.len and self.source[self.pos] == '.') {
                is_float = true;
                self.pos += 1;
                while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
                    self.pos += 1;
                }
            }
            // Check for exponent
            if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
                is_float = true;
                self.pos += 1;
                if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                    self.pos += 1;
                }
                while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
                    self.pos += 1;
                }
            }
            // Consume trailing F/f suffix for floats
            if (self.pos < self.source.len and (self.source[self.pos] == 'F' or self.source[self.pos] == 'f')) {
                is_float = true;
                self.pos += 1;
            }
            const text = self.source[start..self.pos];
            if (is_float) return .{ .float_literal = text };
            return .{ .integer = text };
        }

        // Regular digits
        while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
            self.pos += 1;
        }

        // Decimal point
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            is_float = true;
            self.pos += 1;
            while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
                self.pos += 1;
            }
        }

        // Exponent
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.pos += 1;
            }
            while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
                self.pos += 1;
            }
        }

        // Consume trailing F/f suffix for floats
        if (self.pos < self.source.len and (self.source[self.pos] == 'F' or self.source[self.pos] == 'f')) {
            is_float = true;
            self.pos += 1;
        }

        const text = self.source[start..self.pos];
        if (is_float) {
            return .{ .float_literal = text };
        }
        return .{ .integer = text };
    }

    fn is_hex_char(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn scan_identifier(self: *TextScanner) TextToken {
        const start = self.pos;
        while (self.pos < self.source.len and is_ident_char(self.source[self.pos])) {
            self.pos += 1;
        }
        return .{ .identifier = self.source[start..self.pos] };
    }

    fn is_ident_start(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn is_ident_char(c: u8) bool {
        return is_ident_start(c) or (c >= '0' and c <= '9');
    }

    fn hex_digit(c: u8) ?u8 {
        if (c >= '0' and c <= '9') return c - '0';
        if (c >= 'a' and c <= 'f') return c - 'a' + 10;
        if (c >= 'A' and c <= 'F') return c - 'A' + 10;
        return null;
    }
};

// ── Scanner Read Helpers ──────────────────────────────────────────────

/// Read and return a text format string literal (concatenation is handled by the scanner)
pub fn read_string(scanner: *TextScanner) TextError![]const u8 {
    const tok = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
    switch (tok) {
        .string_literal => |s| return s,
        else => return TextError.UnexpectedToken,
    }
}

/// Validate that a string contains valid UTF-8 (for proto3 string fields)
pub fn validate_utf8(s: []const u8) TextError!void {
    if (!std.unicode.utf8ValidateSlice(s)) {
        return TextError.InvalidUtf8;
    }
}

/// Skip optional field separator (comma or semicolon) between fields
pub fn skip_separator(scanner: *TextScanner) TextError!void {
    if (try scanner.peek()) |tok| {
        switch (tok) {
            .comma, .semicolon => {
                _ = try scanner.next();
            },
            else => {},
        }
    }
}

/// Read a text format boolean identifier (true/false)
pub fn read_bool(scanner: *TextScanner) TextError!bool {
    const tok = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
    switch (tok) {
        .identifier => |name| {
            if (std.mem.eql(u8, name, "true")) return true;
            if (std.mem.eql(u8, name, "false")) return false;
            return TextError.UnexpectedToken;
        },
        else => return TextError.UnexpectedToken,
    }
}

/// Read a text format integer as an i32
pub fn read_int32(scanner: *TextScanner) TextError!i32 {
    const tok = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .integer => |n| n,
        .float_literal => |n| n,
        else => return TextError.UnexpectedToken,
    };
    return parse_proto_int(i32, text);
}

/// Read a text format integer as an i64
pub fn read_int64(scanner: *TextScanner) TextError!i64 {
    const tok = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .integer => |n| n,
        .float_literal => |n| n,
        else => return TextError.UnexpectedToken,
    };
    return parse_proto_int(i64, text);
}

/// Read a text format integer as a u32
pub fn read_uint32(scanner: *TextScanner) TextError!u32 {
    const tok = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .integer => |n| n,
        .float_literal => |n| n,
        else => return TextError.UnexpectedToken,
    };
    return parse_proto_int(u32, text);
}

/// Read a text format integer as a u64
pub fn read_uint64(scanner: *TextScanner) TextError!u64 {
    const tok = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
    const text = switch (tok) {
        .integer => |n| n,
        .float_literal => |n| n,
        else => return TextError.UnexpectedToken,
    };
    return parse_proto_int(u64, text);
}

/// Read a text format number or identifier (nan/inf) as an f32
pub fn read_float32(scanner: *TextScanner) TextError!f32 {
    const tok = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
    switch (tok) {
        .identifier => |name| {
            if (eql_case_insensitive(name, "nan")) return std.math.nan(f32);
            if (eql_case_insensitive(name, "inf") or eql_case_insensitive(name, "infinity")) return std.math.inf(f32);
            return TextError.UnexpectedToken;
        },
        .integer => |text| return parse_text_float(f32, text),
        .float_literal => |text| {
            // Check for -inf/-nan/-infinity (produced by scan_number when '-' precedes an identifier)
            if (text.len > 1 and text[0] == '-') {
                const ident = text[1..];
                if (eql_case_insensitive(ident, "inf") or eql_case_insensitive(ident, "infinity")) {
                    return -std.math.inf(f32);
                }
                if (eql_case_insensitive(ident, "nan")) {
                    return std.math.nan(f32); // NaN sign is irrelevant
                }
            }
            return parse_text_float(f32, text);
        },
        else => return TextError.UnexpectedToken,
    }
}

/// Read a text format number or identifier (nan/inf) as an f64
pub fn read_float64(scanner: *TextScanner) TextError!f64 {
    const tok = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
    switch (tok) {
        .identifier => |name| {
            if (eql_case_insensitive(name, "nan")) return std.math.nan(f64);
            if (eql_case_insensitive(name, "inf") or eql_case_insensitive(name, "infinity")) return std.math.inf(f64);
            return TextError.UnexpectedToken;
        },
        .integer => |text| return parse_text_float(f64, text),
        .float_literal => |text| {
            // Check for -inf/-nan/-infinity (produced by scan_number when '-' precedes an identifier)
            if (text.len > 1 and text[0] == '-') {
                const ident = text[1..];
                if (eql_case_insensitive(ident, "inf") or eql_case_insensitive(ident, "infinity")) {
                    return -std.math.inf(f64);
                }
                if (eql_case_insensitive(ident, "nan")) {
                    return std.math.nan(f64); // NaN sign is irrelevant
                }
            }
            return parse_text_float(f64, text);
        },
        else => return TextError.UnexpectedToken,
    }
}

/// Parse a text format number string as a float, stripping F/f suffix
/// Note: hex (0x...) and octal (0-prefix) are NOT valid for float fields in text format
fn parse_text_float(comptime T: type, text: []const u8) TextError!T {
    // Strip trailing F/f suffix
    var s = text;
    if (s.len > 0 and (s[s.len - 1] == 'F' or s[s.len - 1] == 'f')) {
        s = s[0 .. s.len - 1];
    }
    // Reject hex literals for float fields
    const check = if (s.len > 0 and s[0] == '-') s[1..] else s;
    if (check.len > 1 and check[0] == '0' and (check[1] == 'x' or check[1] == 'X')) {
        return TextError.InvalidNumber;
    }
    // Reject octal literals for float fields (leading 0 followed by digits, no decimal/exponent)
    if (check.len > 1 and check[0] == '0' and check[1] >= '0' and check[1] <= '7') {
        var is_pure_octal = true;
        for (check[1..]) |c| {
            if (c == '.' or c == 'e' or c == 'E') {
                is_pure_octal = false;
                break;
            }
        }
        if (is_pure_octal) {
            return TextError.InvalidNumber;
        }
    }
    const val = std.fmt.parseFloat(T, s) catch return TextError.InvalidNumber;
    // Preserve negative zero: if parseFloat returned +0 but the input was negative, return -0
    if (val == 0 and !std.math.signbit(val) and s.len > 0 and s[0] == '-') {
        return -val;
    }
    return val;
}

/// Parse a protobuf text format integer, handling C-style hex (0x) and octal (0-prefix)
fn parse_proto_int(comptime T: type, text: []const u8) TextError!T {
    if (text.len == 0) return TextError.InvalidNumber;

    const is_neg = text[0] == '-';
    const abs = if (is_neg) text[1..] else text;

    // Hex: 0x / 0X — pass to parseInt with base 0 (handles the 0x prefix natively)
    if (abs.len >= 2 and abs[0] == '0' and (abs[1] == 'x' or abs[1] == 'X')) {
        return std.fmt.parseInt(T, text, 0) catch return TextError.Overflow;
    }

    // C-style octal: leading 0 followed by octal digits (no decimal point or exponent)
    if (abs.len >= 2 and abs[0] == '0' and abs[1] >= '0' and abs[1] <= '7') {
        const u_val = std.fmt.parseInt(u64, abs, 8) catch return TextError.Overflow;
        if (is_neg) {
            const neg_val: i128 = -@as(i128, u_val);
            return std.math.cast(T, neg_val) orelse return TextError.Overflow;
        } else {
            return std.math.cast(T, u_val) orelse return TextError.Overflow;
        }
    }

    // Decimal (positive or negative)
    return std.fmt.parseInt(T, text, 10) catch return TextError.Overflow;
}

/// Case-insensitive string comparison
fn eql_case_insensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// Read a text format identifier as an enum name
pub fn read_enum_name(scanner: *TextScanner) TextError![]const u8 {
    const tok = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
    switch (tok) {
        .identifier => |name| return name,
        else => return TextError.UnexpectedToken,
    }
}

/// Read a bracketed extension/type-url name, stripping inner whitespace/comments.
/// Example: `[foo .bar # c\n .baz]` -> `foo.bar.baz`
pub fn read_bracketed_name(scanner: *TextScanner) TextError![]const u8 {
    const tok = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
    if (tok != .open_bracket) return TextError.UnexpectedToken;

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(scanner.allocator);

    while (true) {
        if (scanner.pos >= scanner.source.len) return TextError.UnexpectedEndOfInput;
        const c = scanner.source[scanner.pos];

        switch (c) {
            ']' => {
                scanner.pos += 1;
                if (out.items.len == 0) return TextError.UnexpectedToken;
                const owned = out.toOwnedSlice(scanner.allocator) catch return TextError.OutOfMemory;
                scanner.allocated_strings.append(scanner.allocator, owned) catch {
                    scanner.allocator.free(owned);
                    return TextError.OutOfMemory;
                };
                return owned;
            },
            '#'=> {
                // Skip to end-of-line comment inside bracketed names.
                scanner.pos += 1;
                while (scanner.pos < scanner.source.len and scanner.source[scanner.pos] != '\n') {
                    scanner.pos += 1;
                }
            },
            ' ', '\t', '\n', '\r' => {
                scanner.pos += 1;
            },
            else => {
                out.append(scanner.allocator, c) catch return TextError.OutOfMemory;
                scanner.pos += 1;
            },
        }
    }
}

/// Return final component of an extension name.
/// Example: `pkg.sub.ext_name` -> `ext_name`
pub fn extension_name_tail(full_name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, full_name, '.')) |idx| full_name[idx + 1 ..] else full_name;
}

/// Validate an Any type URL's percent-escapes and that it includes a type name.
pub fn is_valid_any_type_url(type_url: []const u8) bool {
    if (type_url.len == 0) return false;
    var i: usize = 0;
    while (i < type_url.len) : (i += 1) {
        if (type_url[i] == '%') {
            if (i + 2 >= type_url.len) return false;
            const c1 = type_url[i + 1];
            const c2 = type_url[i + 2];
            const c1_hex = (c1 >= '0' and c1 <= '9') or (c1 >= 'a' and c1 <= 'f') or (c1 >= 'A' and c1 <= 'F');
            const c2_hex = (c2 >= '0' and c2 <= '9') or (c2 >= 'a' and c2 <= 'f') or (c2 >= 'A' and c2 <= 'F');
            if (!c1_hex or !c2_hex) return false;
            i += 2;
        }
    }
    const slash = std.mem.lastIndexOfScalar(u8, type_url, '/') orelse return false;
    return slash + 1 < type_url.len;
}

/// Return the message type name suffix from an Any type URL.
/// Example: `type.googleapis.com/pkg.Message` -> `pkg.Message`
pub fn any_type_name(type_url: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, type_url, '/') orelse return null;
    if (slash + 1 >= type_url.len) return null;
    return type_url[slash + 1 ..];
}

/// Skip a field value: if the next token is `{` or `<`, skip to matching closer;
/// otherwise skip one value token.
pub fn skip_field(scanner: *TextScanner) TextError!void {
    // Check if next is colon — consume it if so
    if (try scanner.peek()) |tok| {
        switch (tok) {
            .colon => {
                _ = try scanner.next();
            },
            else => {},
        }
    }
    // After colon, check for bracket list syntax [...]
    if (try scanner.peek()) |tok| {
        if (tok == .open_bracket) {
            _ = try scanner.next();
            while (true) {
                const inner = try scanner.peek() orelse return TextError.UnexpectedEndOfInput;
                if (inner == .close_bracket) {
                    _ = try scanner.next();
                    return;
                }
                // Skip value and optional comma
                try skip_field_value(scanner);
                if (try scanner.peek()) |sep| {
                    if (sep == .comma) _ = try scanner.next();
                }
            }
        }
    }
    try skip_field_value(scanner);
}

fn skip_field_value(scanner: *TextScanner) TextError!void {
    const tok = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
    switch (tok) {
        .open_brace => {
            var depth: usize = 1;
            while (depth > 0) {
                const inner = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
                switch (inner) {
                    .open_brace => depth += 1,
                    .close_brace => depth -= 1,
                    else => {},
                }
            }
        },
        .open_angle => {
            var depth: usize = 1;
            while (depth > 0) {
                const inner = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
                switch (inner) {
                    .open_angle => depth += 1,
                    .close_angle => depth -= 1,
                    else => {},
                }
            }
        },
        .identifier, .string_literal, .integer, .float_literal => {},
        .colon, .close_brace, .close_angle, .comma, .semicolon,
        .open_bracket, .close_bracket,
        => return TextError.UnexpectedToken,
    }
}

/// Read a text-format enum literal as either a symbolic name or numeric value.
pub fn read_enum_or_int(scanner: *TextScanner) TextError!EnumOrInt {
    const tok = try scanner.next() orelse return TextError.UnexpectedEndOfInput;
    switch (tok) {
        .identifier => |name| return .{ .name = name },
        .integer => |text| {
            const val = try parse_proto_int(i32, text);
            return .{ .number = val };
        },
        else => return TextError.UnexpectedToken,
    }
}

/// Result of parsing an enum literal in text format.
/// Open enums may be represented as either symbolic names or numeric values.
pub const EnumOrInt = union(enum) {
    name: []const u8,
    number: i32,
};

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

fn test_write(comptime f: anytype, args: anytype) ![]const u8 {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try @call(.auto, f, .{&writer} ++ args);
    return writer.buffered();
}

// ── Write Helper Tests ────────────────────────────────────────────────

test "write_indent: zero" {
    const result = try test_write(write_indent, .{@as(usize, 0)});
    try testing.expectEqualStrings("", result);
}

test "write_indent: two levels" {
    const result = try test_write(write_indent, .{@as(usize, 2)});
    try testing.expectEqualStrings("    ", result);
}

test "write_string: simple" {
    const result = try test_write(write_string, .{"hello"});
    try testing.expectEqualStrings("\"hello\"", result);
}

test "write_string: escaping" {
    const result = try test_write(write_string, .{"a\"b\\c\nd\re\tf"});
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\re\\tf\"", result);
}

test "write_string: non-printable bytes" {
    const result = try test_write(write_string, .{"\x00\x01\x7f\xff"});
    try testing.expectEqualStrings("\"\\x00\\x01\\x7f\\xff\"", result);
}

test "write_bytes: same as write_string" {
    const result = try test_write(write_bytes, .{"hello\x00"});
    try testing.expectEqualStrings("\"hello\\x00\"", result);
}

test "write_int: positive" {
    const result = try test_write(write_int, .{@as(i64, 42)});
    try testing.expectEqualStrings("42", result);
}

test "write_int: negative" {
    const result = try test_write(write_int, .{@as(i64, -42)});
    try testing.expectEqualStrings("-42", result);
}

test "write_uint" {
    const result = try test_write(write_uint, .{@as(u64, 123)});
    try testing.expectEqualStrings("123", result);
}

test "write_float: normal" {
    const result = try test_write(write_float, .{@as(f64, 3.14)});
    try testing.expectEqualStrings("3.14", result);
}

test "write_float: NaN" {
    const result = try test_write(write_float, .{std.math.nan(f64)});
    try testing.expectEqualStrings("nan", result);
}

test "write_float: inf" {
    const result = try test_write(write_float, .{std.math.inf(f64)});
    try testing.expectEqualStrings("inf", result);
}

test "write_float: -inf" {
    const result = try test_write(write_float, .{-std.math.inf(f64)});
    try testing.expectEqualStrings("-inf", result);
}

test "write_float: f32 NaN" {
    const result = try test_write(write_float, .{std.math.nan(f32)});
    try testing.expectEqualStrings("nan", result);
}

test "write_float: f32 inf" {
    const result = try test_write(write_float, .{std.math.inf(f32)});
    try testing.expectEqualStrings("inf", result);
}

test "write_bool: true" {
    const result = try test_write(write_bool, .{true});
    try testing.expectEqualStrings("true", result);
}

test "write_bool: false" {
    const result = try test_write(write_bool, .{false});
    try testing.expectEqualStrings("false", result);
}

test "write_enum_name: bare identifier" {
    const result = try test_write(write_enum_name, .{"ACTIVE"});
    try testing.expectEqualStrings("ACTIVE", result);
}

test "write_enum_value: known enum name" {
    const E = enum(i32) { UNKNOWN = 0, ACTIVE = 1, _ };
    const result = try test_write(write_enum_value, .{@as(E, @enumFromInt(1))});
    try testing.expectEqualStrings("ACTIVE", result);
}

test "write_enum_value: unknown enum numeric fallback" {
    const E = enum(i32) { UNKNOWN = 0, ACTIVE = 1, _ };
    const result = try test_write(write_enum_value, .{@as(E, @enumFromInt(12345))});
    try testing.expectEqualStrings("12345", result);
}

// ── Scanner Tests ─────────────────────────────────────────────────────

test "scanner: empty input" {
    var s = TextScanner.init(testing.allocator, "");
    defer s.deinit();
    try testing.expect(try s.next() == null);
}

test "scanner: colon/brace tokens" {
    var s = TextScanner.init(testing.allocator, ": { }");
    defer s.deinit();
    try testing.expect((try s.next()).? == .colon);
    try testing.expect((try s.next()).? == .open_brace);
    try testing.expect((try s.next()).? == .close_brace);
    try testing.expect(try s.next() == null);
}

test "scanner: identifier" {
    var s = TextScanner.init(testing.allocator, "my_field");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("my_field", tok.identifier);
}

test "scanner: plain string" {
    var s = TextScanner.init(testing.allocator, "\"hello\"");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("hello", tok.string_literal);
}

test "scanner: escaped string" {
    var s = TextScanner.init(testing.allocator, "\"a\\\"b\\\\c\\nd\"");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("a\"b\\c\nd", tok.string_literal);
}

test "scanner: hex escape" {
    var s = TextScanner.init(testing.allocator, "\"\\x41\"");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("A", tok.string_literal);
}

test "scanner: octal escape" {
    var s = TextScanner.init(testing.allocator, "\"\\101\"");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("A", tok.string_literal);
}

test "scanner: integer" {
    var s = TextScanner.init(testing.allocator, "42");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("42", tok.integer);
}

test "scanner: negative integer" {
    var s = TextScanner.init(testing.allocator, "-17");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("-17", tok.integer);
}

test "scanner: float" {
    var s = TextScanner.init(testing.allocator, "3.14");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("3.14", tok.float_literal);
}

test "scanner: float with exponent" {
    var s = TextScanner.init(testing.allocator, "1e10");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("1e10", tok.float_literal);
}

test "scanner: skip comments" {
    var s = TextScanner.init(testing.allocator, "# comment\nfield");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("field", tok.identifier);
}

test "scanner: peek then next" {
    var s = TextScanner.init(testing.allocator, "42");
    defer s.deinit();
    const peeked = (try s.peek()).?;
    try testing.expectEqualStrings("42", peeked.integer);
    const next_tok = (try s.next()).?;
    try testing.expectEqualStrings("42", next_tok.integer);
    try testing.expect(try s.next() == null);
}

test "scanner: single-quoted string" {
    var s = TextScanner.init(testing.allocator, "'hello'");
    defer s.deinit();
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("hello", tok.string_literal);
}

// ── Read Helper Tests ─────────────────────────────────────────────────

test "read_string: text format" {
    var s = TextScanner.init(testing.allocator, "\"test\"");
    defer s.deinit();
    try testing.expectEqualStrings("test", try read_string(&s));
}

test "read_bool: true" {
    var s = TextScanner.init(testing.allocator, "true");
    defer s.deinit();
    try testing.expect(try read_bool(&s));
}

test "read_bool: false" {
    var s = TextScanner.init(testing.allocator, "false");
    defer s.deinit();
    try testing.expect(!try read_bool(&s));
}

test "read_int32" {
    var s = TextScanner.init(testing.allocator, "42");
    defer s.deinit();
    try testing.expectEqual(@as(i32, 42), try read_int32(&s));
}

test "read_int32: negative" {
    var s = TextScanner.init(testing.allocator, "-7");
    defer s.deinit();
    try testing.expectEqual(@as(i32, -7), try read_int32(&s));
}

test "read_int64" {
    var s = TextScanner.init(testing.allocator, "9223372036854775807");
    defer s.deinit();
    try testing.expectEqual(@as(i64, 9223372036854775807), try read_int64(&s));
}

test "read_uint32" {
    var s = TextScanner.init(testing.allocator, "200");
    defer s.deinit();
    try testing.expectEqual(@as(u32, 200), try read_uint32(&s));
}

test "read_uint64" {
    var s = TextScanner.init(testing.allocator, "18446744073709551615");
    defer s.deinit();
    try testing.expectEqual(@as(u64, 18446744073709551615), try read_uint64(&s));
}

test "read_float64: number" {
    var s = TextScanner.init(testing.allocator, "3.14");
    defer s.deinit();
    try testing.expectEqual(@as(f64, 3.14), try read_float64(&s));
}

test "read_float64: nan" {
    var s = TextScanner.init(testing.allocator, "nan");
    defer s.deinit();
    try testing.expect(std.math.isNan(try read_float64(&s)));
}

test "read_float64: inf" {
    var s = TextScanner.init(testing.allocator, "inf");
    defer s.deinit();
    try testing.expect(std.math.isInf(try read_float64(&s)));
}

test "read_float64: negative inf identifier forms" {
    var s1 = TextScanner.init(testing.allocator, "-inf");
    defer s1.deinit();
    const v1 = try read_float64(&s1);
    try testing.expect(std.math.isInf(v1) and v1 < 0);

    var s2 = TextScanner.init(testing.allocator, "-INF");
    defer s2.deinit();
    const v2 = try read_float64(&s2);
    try testing.expect(std.math.isInf(v2) and v2 < 0);
}

test "read_float32: nan" {
    var s = TextScanner.init(testing.allocator, "nan");
    defer s.deinit();
    try testing.expect(std.math.isNan(try read_float32(&s)));
}

test "read_float32: negative mixed-case inf" {
    var s = TextScanner.init(testing.allocator, "-iNF");
    defer s.deinit();
    const v = try read_float32(&s);
    try testing.expect(std.math.isInf(v) and v < 0);
}

test "read_enum_name" {
    var s = TextScanner.init(testing.allocator, "ACTIVE");
    defer s.deinit();
    try testing.expectEqualStrings("ACTIVE", try read_enum_name(&s));
}

test "skip_field: scalar value" {
    var s = TextScanner.init(testing.allocator, ": 42 next");
    defer s.deinit();
    try skip_field(&s);
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("next", tok.identifier);
}

test "skip_field: message block" {
    var s = TextScanner.init(testing.allocator, "{ inner { x: 1 } } next");
    defer s.deinit();
    try skip_field(&s);
    const tok = (try s.next()).?;
    try testing.expectEqualStrings("next", tok.identifier);
}

test "read_bool: wrong token" {
    var s = TextScanner.init(testing.allocator, "42");
    defer s.deinit();
    try testing.expectError(TextError.UnexpectedToken, read_bool(&s));
}

test "read_int32: wrong token" {
    var s = TextScanner.init(testing.allocator, "true");
    defer s.deinit();
    try testing.expectError(TextError.UnexpectedToken, read_int32(&s));
}

test "read_float64: integer token" {
    var s = TextScanner.init(testing.allocator, "42");
    defer s.deinit();
    try testing.expectEqual(@as(f64, 42.0), try read_float64(&s));
}

test "fuzz: TextScanner handles arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            var scanner = TextScanner.init(std.testing.allocator, input);
            defer scanner.deinit();
            while (scanner.next() catch return) |_| {}
        }
    }.run, .{});
}
