const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");

// ── Types ─────────────────────────────────────────────────────────────

pub const TokenKind = enum {
    // Literals
    identifier,
    integer,
    float_literal,
    string_literal,

    // Punctuation
    semicolon,
    comma,
    dot,
    equals,
    minus,
    plus,
    open_brace,
    close_brace,
    open_bracket,
    close_bracket,
    open_paren,
    close_paren,
    open_angle,
    close_angle,
    slash,

    // Special
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    location: ast.SourceLocation,
};

pub const LexError = error{
    InvalidCharacter,
    UnterminatedBlockComment,
    UnterminatedString,
    InvalidEscape,
    InvalidNumber,
};

// ── Lexer ─────────────────────────────────────────────────────────────

pub const Lexer = struct {
    source: []const u8,
    file_name: []const u8,
    pos: usize,
    line: u32,
    column: u32,
    peeked: ?Token,

    pub fn init(source: []const u8, file_name: []const u8) Lexer {
        return .{
            .source = source,
            .file_name = file_name,
            .pos = 0,
            .line = 1,
            .column = 1,
            .peeked = null,
        };
    }

    pub fn next(self: *Lexer) LexError!Token {
        if (self.peeked) |tok| {
            self.peeked = null;
            return tok;
        }
        return self.scan();
    }

    pub fn peek(self: *Lexer) LexError!Token {
        if (self.peeked) |tok| return tok;
        const tok = try self.scan();
        self.peeked = tok;
        return tok;
    }

    fn scan(self: *Lexer) LexError!Token {
        try self.skip_whitespace_and_comments();

        if (self.pos >= self.source.len) {
            return .{ .kind = .eof, .text = "", .location = self.make_location() };
        }

        const ch = self.source[self.pos];

        // Identifiers: [a-zA-Z_]
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            return self.read_identifier();
        }

        // Numbers: [0-9]
        if (std.ascii.isDigit(ch)) {
            return self.read_number();
        }

        // String literals: " or '
        if (ch == '"' or ch == '\'') {
            return self.read_string();
        }

        // Punctuation
        const punct_kind: ?TokenKind = switch (ch) {
            ';' => .semicolon,
            ',' => .comma,
            '.' => .dot,
            '=' => .equals,
            '-' => .minus,
            '+' => .plus,
            '{' => .open_brace,
            '}' => .close_brace,
            '[' => .open_bracket,
            ']' => .close_bracket,
            '(' => .open_paren,
            ')' => .close_paren,
            '<' => .open_angle,
            '>' => .close_angle,
            '/' => .slash,
            else => null,
        };

        if (punct_kind) |kind| {
            const loc = self.make_location();
            const text = self.source[self.pos .. self.pos + 1];
            self.advance();
            return .{ .kind = kind, .text = text, .location = loc };
        }

        return error.InvalidCharacter;
    }

    fn skip_whitespace_and_comments(self: *Lexer) LexError!void {
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
                self.advance();
                continue;
            }
            // Check for comments
            if (ch == '/' and self.pos + 1 < self.source.len) {
                if (self.source[self.pos + 1] == '/') {
                    // Line comment: skip to end of line
                    self.advance(); // skip first /
                    self.advance(); // skip second /
                    while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                        self.advance();
                    }
                    continue;
                }
                if (self.source[self.pos + 1] == '*') {
                    // Block comment: skip to */
                    self.advance(); // skip /
                    self.advance(); // skip *
                    while (self.pos < self.source.len) {
                        if (self.source[self.pos] == '*' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                            self.advance(); // skip *
                            self.advance(); // skip /
                            break;
                        }
                        self.advance();
                    } else {
                        return error.UnterminatedBlockComment;
                    }
                    continue;
                }
            }
            break;
        }
    }

    fn advance(self: *Lexer) void {
        if (self.pos < self.source.len) {
            if (self.source[self.pos] == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.pos += 1;
        }
    }

    fn make_location(self: *Lexer) ast.SourceLocation {
        return .{
            .file = self.file_name,
            .line = self.line,
            .column = self.column,
        };
    }

    fn read_identifier(self: *Lexer) Token {
        const loc = self.make_location();
        const start = self.pos;
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (std.ascii.isAlphanumeric(ch) or ch == '_') {
                self.advance();
            } else {
                break;
            }
        }
        return .{ .kind = .identifier, .text = self.source[start..self.pos], .location = loc };
    }

    fn read_number(self: *Lexer) LexError!Token {
        const loc = self.make_location();
        const start = self.pos;

        // Check for hex (0x/0X) or octal (0 followed by octal digit)
        if (self.source[self.pos] == '0' and self.pos + 1 < self.source.len) {
            const next_ch = self.source[self.pos + 1];
            if (next_ch == 'x' or next_ch == 'X') {
                // Hex integer
                self.advance(); // 0
                self.advance(); // x
                if (self.pos >= self.source.len or !std.ascii.isHex(self.source[self.pos])) {
                    return error.InvalidNumber;
                }
                while (self.pos < self.source.len and std.ascii.isHex(self.source[self.pos])) {
                    self.advance();
                }
                return .{ .kind = .integer, .text = self.source[start..self.pos], .location = loc };
            }
            if (next_ch >= '0' and next_ch <= '7') {
                // Octal integer
                self.advance(); // 0
                while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '7') {
                    self.advance();
                }
                return .{ .kind = .integer, .text = self.source[start..self.pos], .location = loc };
            }
        }

        // Decimal integer or float
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
            self.advance();
        }

        // Check for float: . or e/E
        var is_float = false;
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            is_float = true;
            self.advance(); // .
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                self.advance();
            }
        }
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            is_float = true;
            self.advance(); // e/E
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.advance(); // sign
            }
            if (self.pos >= self.source.len or !std.ascii.isDigit(self.source[self.pos])) {
                return error.InvalidNumber;
            }
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                self.advance();
            }
        }

        return .{
            .kind = if (is_float) .float_literal else .integer,
            .text = self.source[start..self.pos],
            .location = loc,
        };
    }

    fn read_string(self: *Lexer) LexError!Token {
        const loc = self.make_location();
        const start = self.pos;
        const quote = self.source[self.pos];
        self.advance(); // opening quote

        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == '\n') return error.UnterminatedString;
            if (ch == '\\') {
                self.advance(); // backslash
                if (self.pos >= self.source.len) return error.UnterminatedString;
                self.advance(); // escaped char
                continue;
            }
            if (ch == quote) {
                self.advance(); // closing quote
                return .{ .kind = .string_literal, .text = self.source[start..self.pos], .location = loc };
            }
            self.advance();
        }

        return error.UnterminatedString;
    }
};

// ── String Resolution ─────────────────────────────────────────────────

pub fn resolve_string(raw: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (raw.len < 2) return error.InvalidEscape;
    const quote = raw[0];
    if (raw[raw.len - 1] != quote) return error.InvalidEscape;
    const inner = raw[1 .. raw.len - 1];

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] != '\\') {
            try result.append(allocator, inner[i]);
            i += 1;
            continue;
        }
        // Escape sequence
        i += 1; // skip backslash
        if (i >= inner.len) return error.InvalidEscape;
        const esc = inner[i];
        i += 1;
        switch (esc) {
            'a' => try result.append(allocator, 0x07),
            'b' => try result.append(allocator, 0x08),
            'f' => try result.append(allocator, 0x0C),
            'n' => try result.append(allocator, 0x0A),
            'r' => try result.append(allocator, 0x0D),
            't' => try result.append(allocator, 0x09),
            'v' => try result.append(allocator, 0x0B),
            '\\' => try result.append(allocator, '\\'),
            '\'' => try result.append(allocator, '\''),
            '"' => try result.append(allocator, '"'),
            'x' => {
                // Hex escape: 1-2 hex digits
                if (i >= inner.len or !std.ascii.isHex(inner[i])) return error.InvalidEscape;
                var val: u8 = hex_digit(inner[i]);
                i += 1;
                if (i < inner.len and std.ascii.isHex(inner[i])) {
                    val = val * 16 + hex_digit(inner[i]);
                    i += 1;
                }
                try result.append(allocator, val);
            },
            '0'...'7' => {
                // Octal escape: 1-3 octal digits (first already consumed)
                var val: u16 = esc - '0';
                if (i < inner.len and inner[i] >= '0' and inner[i] <= '7') {
                    val = val * 8 + (inner[i] - '0');
                    i += 1;
                }
                if (i < inner.len and inner[i] >= '0' and inner[i] <= '7') {
                    val = val * 8 + (inner[i] - '0');
                    i += 1;
                }
                if (val > 255) return error.InvalidEscape;
                try result.append(allocator, @intCast(val));
            },
            'u' => {
                // Unicode escape: exactly 4 hex digits
                if (i + 4 > inner.len) return error.InvalidEscape;
                var codepoint: u21 = 0;
                for (0..4) |_| {
                    if (!std.ascii.isHex(inner[i])) return error.InvalidEscape;
                    codepoint = codepoint * 16 + hex_digit(inner[i]);
                    i += 1;
                }
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidEscape;
                try result.appendSlice(allocator, buf[0..len]);
            },
            'U' => {
                // Long unicode escape: exactly 8 hex digits
                if (i + 8 > inner.len) return error.InvalidEscape;
                var codepoint: u32 = 0;
                for (0..8) |_| {
                    if (!std.ascii.isHex(inner[i])) return error.InvalidEscape;
                    codepoint = codepoint * 16 + hex_digit(inner[i]);
                    i += 1;
                }
                if (codepoint > 0x10FFFF) return error.InvalidEscape;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return error.InvalidEscape;
                try result.appendSlice(allocator, buf[0..len]);
            },
            else => return error.InvalidEscape,
        }
    }

    return result.toOwnedSlice(allocator);
}

fn hex_digit(ch: u8) u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => unreachable,
    };
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

// ── Basic lexer tests ─────────────────────────────────────────────────

test "Lexer: empty input returns EOF" {
    var lex = Lexer.init("", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.eof, tok.kind);
}

test "Lexer: EOF is idempotent" {
    var lex = Lexer.init("", "test.proto");
    _ = try lex.next();
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.eof, tok.kind);
}

test "Lexer: single identifier" {
    var lex = Lexer.init("message", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.identifier, tok.kind);
    try testing.expectEqualStrings("message", tok.text);
}

test "Lexer: identifier with underscores and digits" {
    var lex = Lexer.init("field_name_2", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.identifier, tok.kind);
    try testing.expectEqualStrings("field_name_2", tok.text);
}

test "Lexer: all punctuation tokens" {
    const cases = .{
        .{ ";", TokenKind.semicolon },
        .{ ",", TokenKind.comma },
        .{ ".", TokenKind.dot },
        .{ "=", TokenKind.equals },
        .{ "-", TokenKind.minus },
        .{ "+", TokenKind.plus },
        .{ "{", TokenKind.open_brace },
        .{ "}", TokenKind.close_brace },
        .{ "[", TokenKind.open_bracket },
        .{ "]", TokenKind.close_bracket },
        .{ "(", TokenKind.open_paren },
        .{ ")", TokenKind.close_paren },
        .{ "<", TokenKind.open_angle },
        .{ ">", TokenKind.close_angle },
        .{ "/", TokenKind.slash },
    };
    inline for (cases) |case| {
        var lex = Lexer.init(case[0], "test.proto");
        const tok = try lex.next();
        try testing.expectEqual(case[1], tok.kind);
        try testing.expectEqualStrings(case[0], tok.text);
    }
}

test "Lexer: consecutive punctuation" {
    var lex = Lexer.init("{}[]<>()", "test.proto");
    try testing.expectEqual(TokenKind.open_brace, (try lex.next()).kind);
    try testing.expectEqual(TokenKind.close_brace, (try lex.next()).kind);
    try testing.expectEqual(TokenKind.open_bracket, (try lex.next()).kind);
    try testing.expectEqual(TokenKind.close_bracket, (try lex.next()).kind);
    try testing.expectEqual(TokenKind.open_angle, (try lex.next()).kind);
    try testing.expectEqual(TokenKind.close_angle, (try lex.next()).kind);
    try testing.expectEqual(TokenKind.open_paren, (try lex.next()).kind);
    try testing.expectEqual(TokenKind.close_paren, (try lex.next()).kind);
    try testing.expectEqual(TokenKind.eof, (try lex.next()).kind);
}

test "Lexer: mixed identifiers and punctuation" {
    var lex = Lexer.init("message Foo {", "test.proto");
    const t1 = try lex.next();
    try testing.expectEqual(TokenKind.identifier, t1.kind);
    try testing.expectEqualStrings("message", t1.text);
    const t2 = try lex.next();
    try testing.expectEqual(TokenKind.identifier, t2.kind);
    try testing.expectEqualStrings("Foo", t2.text);
    const t3 = try lex.next();
    try testing.expectEqual(TokenKind.open_brace, t3.kind);
    try testing.expectEqual(TokenKind.eof, (try lex.next()).kind);
}

// ── Comment tests ─────────────────────────────────────────────────────

test "Lexer: line comment skipping" {
    var lex = Lexer.init("// comment\nmessage", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.identifier, tok.kind);
    try testing.expectEqualStrings("message", tok.text);
}

test "Lexer: block comment skipping" {
    var lex = Lexer.init("/* comment */message", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.identifier, tok.kind);
    try testing.expectEqualStrings("message", tok.text);
}

test "Lexer: block comment with newlines" {
    var lex = Lexer.init("/* multi\nline\ncomment */foo", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.identifier, tok.kind);
    try testing.expectEqualStrings("foo", tok.text);
}

test "Lexer: unterminated block comment" {
    var lex = Lexer.init("/* no end", "test.proto");
    try testing.expectError(error.UnterminatedBlockComment, lex.next());
}

test "Lexer: nested-looking block comment consumes to first */" {
    var lex = Lexer.init("/* /* */foo", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.identifier, tok.kind);
    try testing.expectEqualStrings("foo", tok.text);
}

// ── Whitespace and location tests ─────────────────────────────────────

test "Lexer: various whitespace" {
    var lex = Lexer.init("  \t\r\n  foo", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.identifier, tok.kind);
    try testing.expectEqualStrings("foo", tok.text);
}

test "Lexer: source location tracking" {
    var lex = Lexer.init("foo\nbar\n  baz", "test.proto");
    const t1 = try lex.next();
    try testing.expectEqual(@as(u32, 1), t1.location.line);
    try testing.expectEqual(@as(u32, 1), t1.location.column);

    const t2 = try lex.next();
    try testing.expectEqual(@as(u32, 2), t2.location.line);
    try testing.expectEqual(@as(u32, 1), t2.location.column);

    const t3 = try lex.next();
    try testing.expectEqual(@as(u32, 3), t3.location.line);
    try testing.expectEqual(@as(u32, 3), t3.location.column);
}

// ── Peek tests ────────────────────────────────────────────────────────

test "Lexer: peek does not consume" {
    var lex = Lexer.init("foo bar", "test.proto");
    const p1 = try lex.peek();
    const p2 = try lex.peek();
    try testing.expectEqualStrings("foo", p1.text);
    try testing.expectEqualStrings("foo", p2.text);
    const n = try lex.next();
    try testing.expectEqualStrings("foo", n.text);
    const n2 = try lex.next();
    try testing.expectEqualStrings("bar", n2.text);
}

// ── Number literal tests ──────────────────────────────────────────────

test "Lexer: decimal integer" {
    var lex = Lexer.init("123", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.integer, tok.kind);
    try testing.expectEqualStrings("123", tok.text);
}

test "Lexer: zero" {
    var lex = Lexer.init("0", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.integer, tok.kind);
    try testing.expectEqualStrings("0", tok.text);
}

test "Lexer: hex integer" {
    var lex = Lexer.init("0xFF", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.integer, tok.kind);
    try testing.expectEqualStrings("0xFF", tok.text);
}

test "Lexer: hex uppercase" {
    var lex = Lexer.init("0XAB", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.integer, tok.kind);
    try testing.expectEqualStrings("0XAB", tok.text);
}

test "Lexer: octal integer" {
    var lex = Lexer.init("0755", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.integer, tok.kind);
    try testing.expectEqualStrings("0755", tok.text);
}

test "Lexer: float with decimal" {
    var lex = Lexer.init("1.5", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.float_literal, tok.kind);
    try testing.expectEqualStrings("1.5", tok.text);
}

test "Lexer: float with exponent" {
    var lex = Lexer.init("1e10", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.float_literal, tok.kind);
    try testing.expectEqualStrings("1e10", tok.text);
}

test "Lexer: float with negative exponent" {
    var lex = Lexer.init("1.5e-3", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.float_literal, tok.kind);
    try testing.expectEqualStrings("1.5e-3", tok.text);
}

test "Lexer: float 123.456" {
    var lex = Lexer.init("123.456", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.float_literal, tok.kind);
    try testing.expectEqualStrings("123.456", tok.text);
}

// ── String literal tests ──────────────────────────────────────────────

test "Lexer: double-quoted string" {
    var lex = Lexer.init("\"hello\"", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.string_literal, tok.kind);
    try testing.expectEqualStrings("\"hello\"", tok.text);
}

test "Lexer: single-quoted string" {
    var lex = Lexer.init("'hello'", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.string_literal, tok.kind);
    try testing.expectEqualStrings("'hello'", tok.text);
}

test "Lexer: empty string" {
    var lex = Lexer.init("\"\"", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.string_literal, tok.kind);
    try testing.expectEqualStrings("\"\"", tok.text);
}

test "Lexer: string with escape" {
    var lex = Lexer.init("\"hello\\nworld\"", "test.proto");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.string_literal, tok.kind);
    try testing.expectEqualStrings("\"hello\\nworld\"", tok.text);
}

test "Lexer: unterminated string" {
    var lex = Lexer.init("\"hello", "test.proto");
    try testing.expectError(error.UnterminatedString, lex.next());
}

test "Lexer: string with newline" {
    var lex = Lexer.init("\"hello\nworld\"", "test.proto");
    try testing.expectError(error.UnterminatedString, lex.next());
}

// ── resolve_string tests ──────────────────────────────────────────────

test "resolve_string: no escapes" {
    const result = try resolve_string("\"hello\"", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "resolve_string: single-quoted" {
    const result = try resolve_string("'hello'", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "resolve_string: empty" {
    const result = try resolve_string("\"\"", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "resolve_string: newline escape" {
    const result = try resolve_string("\"hello\\nworld\"", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello\nworld", result);
}

test "resolve_string: all simple escapes" {
    const result = try resolve_string("\"\\a\\b\\f\\n\\r\\t\\v\\\\\\'\\\"\"", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x07, 0x08, 0x0C, 0x0A, 0x0D, 0x09, 0x0B, '\\', '\'', '"' }, result);
}

test "resolve_string: hex escape" {
    const result = try resolve_string("\"\\x41\"", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("A", result);
}

test "resolve_string: hex escape single digit" {
    const result = try resolve_string("\"\\x9\"", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, &[_]u8{0x09}, result);
}

test "resolve_string: octal escape" {
    const result = try resolve_string("\"\\101\"", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("A", result);
}

test "resolve_string: unicode escape" {
    const result = try resolve_string("\"\\u0041\"", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("A", result);
}

test "resolve_string: long unicode escape" {
    const result = try resolve_string("\"\\U0001F600\"", testing.allocator);
    defer testing.allocator.free(result);
    // U+1F600 = grinning face, UTF-8: F0 9F 98 80
    try testing.expectEqualSlices(u8, &[_]u8{ 0xF0, 0x9F, 0x98, 0x80 }, result);
}

test "resolve_string: invalid escape" {
    try testing.expectError(error.InvalidEscape, resolve_string("\"\\z\"", testing.allocator));
}

test "resolve_string: mixed escapes" {
    const result = try resolve_string("\"hello\\n\\x41\\\"world\"", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello\nA\"world", result);
}

test "fuzz: Lexer handles arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            var lex = Lexer.init(input, "fuzz.proto");
            while (true) {
                const tok = lex.next() catch return;
                if (tok.kind == .eof) break;
            }
        }
    }.run, .{});
}
