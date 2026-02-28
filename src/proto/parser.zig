const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");

// ── Types ─────────────────────────────────────────────────────────────

/// A parser diagnostic message with severity and location
pub const Diagnostic = struct {
    location: ast.SourceLocation,
    severity: Severity,
    message: []const u8,

    /// Diagnostic severity level
    pub const Severity = enum { err, warning };
};

/// Managed list of parser diagnostics
pub const DiagnosticList = std.ArrayList(Diagnostic);

// ── Parser ────────────────────────────────────────────────────────────

/// Parser that produces an AST from .proto tokens
pub const Parser = struct {
    lexer: lexer_mod.Lexer,
    allocator: std.mem.Allocator,
    diagnostics: *DiagnosticList,

    /// Create a parser for the given source text
    pub fn init(lexer: lexer_mod.Lexer, allocator: std.mem.Allocator, diagnostics: *DiagnosticList) Parser {
        return .{ .lexer = lexer, .allocator = allocator, .diagnostics = diagnostics };
    }

    /// Parse a complete .proto file into an AST
    pub fn parse_file(self: *Parser) !ast.File {
        const syntax = try self.parse_syntax_decl();

        var imports: std.ArrayList(ast.Import) = .empty;
        var options: std.ArrayList(ast.Option) = .empty;
        var messages: std.ArrayList(ast.Message) = .empty;
        var enums: std.ArrayList(ast.Enum) = .empty;
        var services: std.ArrayList(ast.Service) = .empty;
        var extensions: std.ArrayList(ast.Extend) = .empty;
        var package: ?[]const u8 = null;

        while (true) {
            const tok = try self.lexer.peek();
            if (tok.kind == .eof) break;

            if (tok.kind == .semicolon) {
                _ = try self.lexer.next();
                continue;
            }

            if (tok.kind != .identifier) {
                try self.add_error(tok.location, "expected declaration");
                try self.skip_statement();
                continue;
            }

            if (std.mem.eql(u8, tok.text, "import")) {
                try imports.append(self.allocator, try self.parse_import_decl());
            } else if (std.mem.eql(u8, tok.text, "package")) {
                package = try self.parse_package_decl();
            } else if (std.mem.eql(u8, tok.text, "option")) {
                try options.append(self.allocator, try self.parse_option_decl());
            } else if (std.mem.eql(u8, tok.text, "message")) {
                try messages.append(self.allocator, try self.parse_message_def(syntax));
            } else if (std.mem.eql(u8, tok.text, "enum")) {
                try enums.append(self.allocator, try self.parse_enum_def());
            } else if (std.mem.eql(u8, tok.text, "service")) {
                try services.append(self.allocator, try self.parse_service_def());
            } else if (std.mem.eql(u8, tok.text, "extend")) {
                try extensions.append(self.allocator, try self.parse_extend_def(syntax));
            } else {
                try self.add_error(tok.location, "unexpected token in file scope");
                try self.skip_statement();
            }
        }

        return .{
            .syntax = syntax,
            .package = package,
            .imports = try imports.toOwnedSlice(self.allocator),
            .options = try options.toOwnedSlice(self.allocator),
            .messages = try messages.toOwnedSlice(self.allocator),
            .enums = try enums.toOwnedSlice(self.allocator),
            .services = try services.toOwnedSlice(self.allocator),
            .extensions = try extensions.toOwnedSlice(self.allocator),
        };
    }

    // ── Top-Level Declarations ────────────────────────────────────────

    fn parse_syntax_decl(self: *Parser) !ast.Syntax {
        try self.expect_keyword("syntax");
        try self.expect_punct(.equals);
        const str_tok = try self.expect_kind(.string_literal);
        try self.expect_punct(.semicolon);

        const resolved = try lexer_mod.resolve_string(str_tok.text, self.allocator);
        defer self.allocator.free(resolved);

        if (std.mem.eql(u8, resolved, "proto2")) return .proto2;
        if (std.mem.eql(u8, resolved, "proto3")) return .proto3;

        try self.add_error(str_tok.location, "expected \"proto2\" or \"proto3\"");
        return .proto3;
    }

    fn parse_import_decl(self: *Parser) !ast.Import {
        try self.expect_keyword("import");
        const loc = (try self.lexer.peek()).location;

        var kind: @TypeOf(@as(ast.Import, undefined).kind) = .default;
        const next = try self.lexer.peek();
        if (next.kind == .identifier) {
            if (std.mem.eql(u8, next.text, "public")) {
                kind = .public;
                _ = try self.lexer.next();
            } else if (std.mem.eql(u8, next.text, "weak")) {
                kind = .weak;
                _ = try self.lexer.next();
            }
        }

        const path_tok = try self.expect_kind(.string_literal);
        try self.expect_punct(.semicolon);

        const path = try lexer_mod.resolve_string(path_tok.text, self.allocator);
        return .{ .path = path, .kind = kind, .location = loc };
    }

    fn parse_package_decl(self: *Parser) ![]const u8 {
        try self.expect_keyword("package");
        const name = try self.parse_full_ident();
        try self.expect_punct(.semicolon);
        return name;
    }

    fn parse_option_decl(self: *Parser) !ast.Option {
        try self.expect_keyword("option");
        const loc = (try self.lexer.peek()).location;
        const name = try self.parse_option_name();
        try self.expect_punct(.equals);
        const value = try self.parse_constant();
        try self.expect_punct(.semicolon);
        return .{ .name = name, .value = value, .location = loc };
    }

    // ── Enum ──────────────────────────────────────────────────────────

    fn parse_enum_def(self: *Parser) !ast.Enum {
        try self.expect_keyword("enum");
        const loc = (try self.lexer.peek()).location;
        const name = (try self.expect_kind(.identifier)).text;
        try self.expect_punct(.open_brace);

        var values: std.ArrayList(ast.EnumValue) = .empty;
        var options: std.ArrayList(ast.Option) = .empty;
        var reserved_ranges: std.ArrayList(ast.ReservedRange) = .empty;
        var reserved_names: std.ArrayList([]const u8) = .empty;
        var allow_alias = false;

        while (true) {
            const tok = try self.lexer.peek();
            if (tok.kind == .close_brace) {
                _ = try self.lexer.next();
                break;
            }
            if (tok.kind == .eof) {
                try self.add_error(tok.location, "unexpected EOF in enum");
                break;
            }
            if (tok.kind == .semicolon) {
                _ = try self.lexer.next();
                continue;
            }
            if (tok.kind == .identifier and std.mem.eql(u8, tok.text, "option")) {
                const opt = try self.parse_option_decl();
                // Check for allow_alias
                if (opt.name.parts.len == 1 and std.mem.eql(u8, opt.name.parts[0].name, "allow_alias")) {
                    if (opt.value == .bool_value and opt.value.bool_value) {
                        allow_alias = true;
                    }
                }
                try options.append(self.allocator, opt);
                continue;
            }
            if (tok.kind == .identifier and std.mem.eql(u8, tok.text, "reserved")) {
                const reserved = try self.parse_reserved_decl();
                for (reserved.ranges) |r| try reserved_ranges.append(self.allocator, r);
                for (reserved.names) |n| try reserved_names.append(self.allocator, n);
                continue;
            }
            // Enum value
            try values.append(self.allocator, try self.parse_enum_value());
        }

        return .{
            .name = name,
            .values = try values.toOwnedSlice(self.allocator),
            .options = try options.toOwnedSlice(self.allocator),
            .allow_alias = allow_alias,
            .reserved_ranges = try reserved_ranges.toOwnedSlice(self.allocator),
            .reserved_names = try reserved_names.toOwnedSlice(self.allocator),
            .location = loc,
        };
    }

    fn parse_enum_value(self: *Parser) !ast.EnumValue {
        const loc = (try self.lexer.peek()).location;
        const name = (try self.expect_kind(.identifier)).text;
        try self.expect_punct(.equals);

        const negative = (try self.lexer.peek()).kind == .minus;
        if (negative) _ = try self.lexer.next();

        const num_tok = try self.expect_kind(.integer);
        const num = try parse_int(num_tok.text);
        const number: i32 = if (negative) -@as(i32, @intCast(num)) else @intCast(num);

        var options: []ast.FieldOption = &.{};
        if ((try self.lexer.peek()).kind == .open_bracket) {
            options = try self.parse_field_options();
        }

        try self.expect_punct(.semicolon);

        return .{
            .name = name,
            .number = number,
            .options = options,
            .location = loc,
        };
    }

    // ── Message ───────────────────────────────────────────────────────

    fn parse_message_def(self: *Parser, syntax: ast.Syntax) Error!ast.Message {
        try self.expect_keyword("message");
        const loc = (try self.lexer.peek()).location;
        const name = (try self.expect_kind(.identifier)).text;
        try self.expect_punct(.open_brace);

        var fields: std.ArrayList(ast.Field) = .empty;
        var oneofs: std.ArrayList(ast.Oneof) = .empty;
        var nested_messages: std.ArrayList(ast.Message) = .empty;
        var nested_enums: std.ArrayList(ast.Enum) = .empty;
        var maps: std.ArrayList(ast.MapField) = .empty;
        var reserved_ranges: std.ArrayList(ast.ReservedRange) = .empty;
        var reserved_names: std.ArrayList([]const u8) = .empty;
        var extension_ranges: std.ArrayList(ast.ExtensionRange) = .empty;
        var extensions_list: std.ArrayList(ast.Extend) = .empty;
        var groups: std.ArrayList(ast.Group) = .empty;
        var options: std.ArrayList(ast.Option) = .empty;

        while (true) {
            const tok = try self.lexer.peek();
            if (tok.kind == .close_brace) {
                _ = try self.lexer.next();
                break;
            }
            if (tok.kind == .eof) {
                try self.add_error(tok.location, "unexpected EOF in message");
                break;
            }
            if (tok.kind == .semicolon) {
                _ = try self.lexer.next();
                continue;
            }

            if (tok.kind == .identifier) {
                if (std.mem.eql(u8, tok.text, "message")) {
                    try nested_messages.append(self.allocator, try self.parse_message_def(syntax));
                    continue;
                }
                if (std.mem.eql(u8, tok.text, "enum")) {
                    try nested_enums.append(self.allocator, try self.parse_enum_def());
                    continue;
                }
                if (std.mem.eql(u8, tok.text, "oneof")) {
                    try oneofs.append(self.allocator, try self.parse_oneof_def(syntax));
                    continue;
                }
                if (std.mem.eql(u8, tok.text, "map")) {
                    try maps.append(self.allocator, try self.parse_map_field());
                    continue;
                }
                if (std.mem.eql(u8, tok.text, "reserved")) {
                    const reserved = try self.parse_reserved_decl();
                    for (reserved.ranges) |r| try reserved_ranges.append(self.allocator, r);
                    for (reserved.names) |n| try reserved_names.append(self.allocator, n);
                    continue;
                }
                if (std.mem.eql(u8, tok.text, "extensions")) {
                    const ext = try self.parse_extensions_decl();
                    for (ext) |e| try extension_ranges.append(self.allocator, e);
                    continue;
                }
                if (std.mem.eql(u8, tok.text, "extend")) {
                    try extensions_list.append(self.allocator, try self.parse_extend_def(syntax));
                    continue;
                }
                if (std.mem.eql(u8, tok.text, "option")) {
                    try options.append(self.allocator, try self.parse_option_decl());
                    continue;
                }
                if (std.mem.eql(u8, tok.text, "group")) {
                    // Group without explicit label
                    try groups.append(self.allocator, try self.parse_group_def(.implicit));
                    continue;
                }
                // Check for label + group
                if (is_label(tok.text)) {
                    const label = label_from_text(tok.text, syntax);
                    // Peek ahead to see if this is a group
                    if (try self.is_group_coming()) {
                        _ = try self.lexer.next(); // consume label
                        try groups.append(self.allocator, try self.parse_group_def(label));
                        continue;
                    }
                }
            }

            // Must be a field
            try fields.append(self.allocator, try self.parse_field(syntax));
        }

        return .{
            .name = name,
            .fields = try fields.toOwnedSlice(self.allocator),
            .oneofs = try oneofs.toOwnedSlice(self.allocator),
            .nested_messages = try nested_messages.toOwnedSlice(self.allocator),
            .nested_enums = try nested_enums.toOwnedSlice(self.allocator),
            .maps = try maps.toOwnedSlice(self.allocator),
            .reserved_ranges = try reserved_ranges.toOwnedSlice(self.allocator),
            .reserved_names = try reserved_names.toOwnedSlice(self.allocator),
            .extension_ranges = try extension_ranges.toOwnedSlice(self.allocator),
            .extensions = try extensions_list.toOwnedSlice(self.allocator),
            .groups = try groups.toOwnedSlice(self.allocator),
            .options = try options.toOwnedSlice(self.allocator),
            .location = loc,
        };
    }

    fn parse_field(self: *Parser, syntax: ast.Syntax) Error!ast.Field {
        const loc = (try self.lexer.peek()).location;

        // Determine label: check for optional/required/repeated, with lookahead
        var label: ast.FieldLabel = if (syntax == .proto3) .implicit else .required;
        const tok = try self.lexer.peek();
        if (tok.kind == .identifier and is_label(tok.text)) {
            if (try self.is_label_coming()) {
                label = label_from_text(tok.text, syntax);
                _ = try self.lexer.next(); // consume label
            }
        }

        const type_ref = try self.parse_type_ref();
        const name = (try self.expect_kind(.identifier)).text;
        try self.expect_punct(.equals);
        const num_tok = try self.expect_kind(.integer);
        const number: i32 = @intCast(try parse_int(num_tok.text));

        var options: []ast.FieldOption = &.{};
        if ((try self.lexer.peek()).kind == .open_bracket) {
            options = try self.parse_field_options();
        }

        try self.expect_punct(.semicolon);

        return .{
            .name = name,
            .number = number,
            .label = label,
            .type_name = type_ref,
            .options = options,
            .location = loc,
        };
    }

    fn parse_type_ref(self: *Parser) !ast.TypeRef {
        const tok = try self.lexer.peek();

        // Fully-qualified: starts with dot
        if (tok.kind == .dot) {
            return .{ .named = try self.parse_qualified_name() };
        }

        if (tok.kind != .identifier) {
            try self.add_error(tok.location, "expected type name");
            return .{ .named = "" };
        }

        // Check if it's a scalar type
        if (ast.ScalarType.from_string(tok.text)) |scalar| {
            _ = try self.lexer.next();
            return .{ .scalar = scalar };
        }

        // Named type (possibly qualified)
        return .{ .named = try self.parse_qualified_name() };
    }

    fn parse_qualified_name(self: *Parser) ![]const u8 {
        var parts: std.ArrayList(u8) = .empty;

        // Optional leading dot
        if ((try self.lexer.peek()).kind == .dot) {
            _ = try self.lexer.next();
            try parts.append(self.allocator, '.');
        }

        const first = (try self.expect_kind(.identifier)).text;
        try parts.appendSlice(self.allocator, first);

        while ((try self.lexer.peek()).kind == .dot) {
            _ = try self.lexer.next();
            try parts.append(self.allocator, '.');
            const seg = (try self.expect_kind(.identifier)).text;
            try parts.appendSlice(self.allocator, seg);
        }

        return try parts.toOwnedSlice(self.allocator);
    }

    // ── Oneof ─────────────────────────────────────────────────────────

    fn parse_oneof_def(self: *Parser, syntax: ast.Syntax) !ast.Oneof {
        try self.expect_keyword("oneof");
        const loc = (try self.lexer.peek()).location;
        const name = (try self.expect_kind(.identifier)).text;
        try self.expect_punct(.open_brace);

        var fields: std.ArrayList(ast.Field) = .empty;
        var options: std.ArrayList(ast.Option) = .empty;

        while (true) {
            const tok = try self.lexer.peek();
            if (tok.kind == .close_brace) {
                _ = try self.lexer.next();
                break;
            }
            if (tok.kind == .eof) {
                try self.add_error(tok.location, "unexpected EOF in oneof");
                break;
            }
            if (tok.kind == .semicolon) {
                _ = try self.lexer.next();
                continue;
            }
            if (tok.kind == .identifier and std.mem.eql(u8, tok.text, "option")) {
                try options.append(self.allocator, try self.parse_option_decl());
                continue;
            }

            // Oneof field: type name = number [options] ;
            const field_loc = tok.location;
            const type_ref = try self.parse_type_ref();
            const field_name = (try self.expect_kind(.identifier)).text;
            try self.expect_punct(.equals);
            const num_tok = try self.expect_kind(.integer);
            const number: i32 = @intCast(try parse_int(num_tok.text));

            var field_options: []ast.FieldOption = &.{};
            if ((try self.lexer.peek()).kind == .open_bracket) {
                field_options = try self.parse_field_options();
            }
            try self.expect_punct(.semicolon);

            try fields.append(self.allocator, .{
                .name = field_name,
                .number = number,
                .label = if (syntax == .proto3) .implicit else .optional,
                .type_name = type_ref,
                .options = field_options,
                .location = field_loc,
            });
        }

        return .{
            .name = name,
            .fields = try fields.toOwnedSlice(self.allocator),
            .options = try options.toOwnedSlice(self.allocator),
            .location = loc,
        };
    }

    // ── Map ───────────────────────────────────────────────────────────

    fn parse_map_field(self: *Parser) !ast.MapField {
        try self.expect_keyword("map");
        const loc = (try self.lexer.peek()).location;
        try self.expect_punct(.open_angle);

        // Key type must be a scalar
        const key_tok = try self.expect_kind(.identifier);
        const key_type = ast.ScalarType.from_string(key_tok.text) orelse {
            try self.add_error(key_tok.location, "invalid map key type");
            return error.ParseFailed;
        };

        try self.expect_punct(.comma);
        const value_type = try self.parse_type_ref();
        try self.expect_punct(.close_angle);

        const name = (try self.expect_kind(.identifier)).text;
        try self.expect_punct(.equals);
        const num_tok = try self.expect_kind(.integer);
        const number: i32 = @intCast(try parse_int(num_tok.text));

        var options: []ast.FieldOption = &.{};
        if ((try self.lexer.peek()).kind == .open_bracket) {
            options = try self.parse_field_options();
        }
        try self.expect_punct(.semicolon);

        return .{
            .name = name,
            .number = number,
            .key_type = key_type,
            .value_type = value_type,
            .options = options,
            .location = loc,
        };
    }

    // ── Reserved / Extensions ─────────────────────────────────────────

    const ReservedResult = struct {
        ranges: []ast.ReservedRange,
        names: [][]const u8,
    };

    fn parse_reserved_decl(self: *Parser) !ReservedResult {
        try self.expect_keyword("reserved");
        const tok = try self.lexer.peek();

        // If it starts with a string literal, it's reserved names
        if (tok.kind == .string_literal) {
            var names: std.ArrayList([]const u8) = .empty;
            const first = try lexer_mod.resolve_string((try self.lexer.next()).text, self.allocator);
            try names.append(self.allocator, first);
            while ((try self.lexer.peek()).kind == .comma) {
                _ = try self.lexer.next();
                const name_tok = try self.expect_kind(.string_literal);
                try names.append(self.allocator, try lexer_mod.resolve_string(name_tok.text, self.allocator));
            }
            try self.expect_punct(.semicolon);
            return .{ .ranges = &.{}, .names = try names.toOwnedSlice(self.allocator) };
        }

        // Otherwise it's ranges
        const ranges = try self.parse_ranges();
        try self.expect_punct(.semicolon);
        return .{ .ranges = ranges, .names = &.{} };
    }

    fn parse_ranges(self: *Parser) ![]ast.ReservedRange {
        var ranges: std.ArrayList(ast.ReservedRange) = .empty;

        try ranges.append(self.allocator, try self.parse_single_range());
        while ((try self.lexer.peek()).kind == .comma) {
            _ = try self.lexer.next();
            try ranges.append(self.allocator, try self.parse_single_range());
        }

        return try ranges.toOwnedSlice(self.allocator);
    }

    fn parse_single_range(self: *Parser) !ast.ReservedRange {
        const start_tok = try self.expect_kind(.integer);
        const start: i32 = @intCast(try parse_int(start_tok.text));

        const next = try self.lexer.peek();
        if (next.kind == .identifier and std.mem.eql(u8, next.text, "to")) {
            _ = try self.lexer.next(); // consume "to"
            const end_tok = try self.lexer.peek();
            if (end_tok.kind == .identifier and std.mem.eql(u8, end_tok.text, "max")) {
                _ = try self.lexer.next();
                return .{ .start = start, .end = 536870911 }; // 2^29 - 1
            }
            const end_num_tok = try self.expect_kind(.integer);
            return .{ .start = start, .end = @intCast(try parse_int(end_num_tok.text)) };
        }

        return .{ .start = start, .end = start };
    }

    fn parse_extensions_decl(self: *Parser) ![]ast.ExtensionRange {
        try self.expect_keyword("extensions");

        var ext_ranges: std.ArrayList(ast.ExtensionRange) = .empty;

        // Parse first range
        const first = try self.parse_single_range();
        var options: []ast.FieldOption = &.{};

        // Check for more ranges
        while ((try self.lexer.peek()).kind == .comma) {
            _ = try self.lexer.next();
            const r = try self.parse_single_range();
            try ext_ranges.append(self.allocator, .{ .start = first.start, .end = first.end, .options = &.{} });
            // Actually we need to rewrite: collect all ranges first, then options
            try ext_ranges.append(self.allocator, .{ .start = r.start, .end = r.end, .options = &.{} });
        }

        // Check for field options
        if ((try self.lexer.peek()).kind == .open_bracket) {
            options = try self.parse_field_options();
        }

        try self.expect_punct(.semicolon);

        // If we didn't have multiple ranges, just return the single one
        if (ext_ranges.items.len == 0) {
            var result: std.ArrayList(ast.ExtensionRange) = .empty;
            try result.append(self.allocator, .{ .start = first.start, .end = first.end, .options = options });
            return try result.toOwnedSlice(self.allocator);
        }

        // Apply options to all ranges
        for (ext_ranges.items) |*r| r.options = options;
        return try ext_ranges.toOwnedSlice(self.allocator);
    }

    // ── Extend ────────────────────────────────────────────────────────

    fn parse_extend_def(self: *Parser, syntax: ast.Syntax) Error!ast.Extend {
        try self.expect_keyword("extend");
        const loc = (try self.lexer.peek()).location;
        const type_name = try self.parse_qualified_name();
        try self.expect_punct(.open_brace);

        var fields: std.ArrayList(ast.Field) = .empty;
        var groups: std.ArrayList(ast.Group) = .empty;

        while (true) {
            const tok = try self.lexer.peek();
            if (tok.kind == .close_brace) {
                _ = try self.lexer.next();
                break;
            }
            if (tok.kind == .eof) {
                try self.add_error(tok.location, "unexpected EOF in extend");
                break;
            }
            if (tok.kind == .semicolon) {
                _ = try self.lexer.next();
                continue;
            }
            if (tok.kind == .identifier and std.mem.eql(u8, tok.text, "group")) {
                try groups.append(self.allocator, try self.parse_group_def(.implicit));
                continue;
            }
            if (tok.kind == .identifier and is_label(tok.text)) {
                if (try self.is_group_coming()) {
                    const label = label_from_text(tok.text, syntax);
                    _ = try self.lexer.next();
                    try groups.append(self.allocator, try self.parse_group_def(label));
                    continue;
                }
            }
            try fields.append(self.allocator, try self.parse_field(syntax));
        }

        return .{
            .type_name = type_name,
            .fields = try fields.toOwnedSlice(self.allocator),
            .groups = try groups.toOwnedSlice(self.allocator),
            .location = loc,
        };
    }

    // ── Group ─────────────────────────────────────────────────────────

    fn parse_group_def(self: *Parser, label: ast.FieldLabel) Error!ast.Group {
        try self.expect_keyword("group");
        const loc = (try self.lexer.peek()).location;
        const name = (try self.expect_kind(.identifier)).text;
        try self.expect_punct(.equals);
        const num_tok = try self.expect_kind(.integer);
        const number: i32 = @intCast(try parse_int(num_tok.text));
        try self.expect_punct(.open_brace);

        var fields: std.ArrayList(ast.Field) = .empty;
        var nested_messages: std.ArrayList(ast.Message) = .empty;
        var nested_enums: std.ArrayList(ast.Enum) = .empty;

        while (true) {
            const tok = try self.lexer.peek();
            if (tok.kind == .close_brace) {
                _ = try self.lexer.next();
                break;
            }
            if (tok.kind == .eof) {
                try self.add_error(tok.location, "unexpected EOF in group");
                break;
            }
            if (tok.kind == .semicolon) {
                _ = try self.lexer.next();
                continue;
            }
            if (tok.kind == .identifier and std.mem.eql(u8, tok.text, "message")) {
                try nested_messages.append(self.allocator, try self.parse_message_def(.proto2));
                continue;
            }
            if (tok.kind == .identifier and std.mem.eql(u8, tok.text, "enum")) {
                try nested_enums.append(self.allocator, try self.parse_enum_def());
                continue;
            }
            try fields.append(self.allocator, try self.parse_field(.proto2));
        }

        return .{
            .name = name,
            .number = number,
            .label = label,
            .fields = try fields.toOwnedSlice(self.allocator),
            .nested_messages = try nested_messages.toOwnedSlice(self.allocator),
            .nested_enums = try nested_enums.toOwnedSlice(self.allocator),
            .location = loc,
        };
    }

    // ── Service ───────────────────────────────────────────────────────

    fn parse_service_def(self: *Parser) !ast.Service {
        try self.expect_keyword("service");
        const loc = (try self.lexer.peek()).location;
        const name = (try self.expect_kind(.identifier)).text;
        try self.expect_punct(.open_brace);

        var methods: std.ArrayList(ast.Method) = .empty;
        var options: std.ArrayList(ast.Option) = .empty;

        while (true) {
            const tok = try self.lexer.peek();
            if (tok.kind == .close_brace) {
                _ = try self.lexer.next();
                break;
            }
            if (tok.kind == .eof) {
                try self.add_error(tok.location, "unexpected EOF in service");
                break;
            }
            if (tok.kind == .semicolon) {
                _ = try self.lexer.next();
                continue;
            }
            if (tok.kind == .identifier and std.mem.eql(u8, tok.text, "option")) {
                try options.append(self.allocator, try self.parse_option_decl());
                continue;
            }
            if (tok.kind == .identifier and std.mem.eql(u8, tok.text, "rpc")) {
                try methods.append(self.allocator, try self.parse_method_def());
                continue;
            }
            try self.add_error(tok.location, "unexpected token in service");
            try self.skip_statement();
        }

        return .{
            .name = name,
            .methods = try methods.toOwnedSlice(self.allocator),
            .options = try options.toOwnedSlice(self.allocator),
            .location = loc,
        };
    }

    fn parse_method_def(self: *Parser) !ast.Method {
        try self.expect_keyword("rpc");
        const loc = (try self.lexer.peek()).location;
        const name = (try self.expect_kind(.identifier)).text;

        try self.expect_punct(.open_paren);
        var client_streaming = false;
        if ((try self.lexer.peek()).kind == .identifier and std.mem.eql(u8, (try self.lexer.peek()).text, "stream")) {
            client_streaming = true;
            _ = try self.lexer.next();
        }
        const input_type = try self.parse_qualified_name();
        try self.expect_punct(.close_paren);

        try self.expect_keyword("returns");

        try self.expect_punct(.open_paren);
        var server_streaming = false;
        if ((try self.lexer.peek()).kind == .identifier and std.mem.eql(u8, (try self.lexer.peek()).text, "stream")) {
            server_streaming = true;
            _ = try self.lexer.next();
        }
        const output_type = try self.parse_qualified_name();
        try self.expect_punct(.close_paren);

        // Optional body or semicolon
        var options: std.ArrayList(ast.Option) = .empty;
        const next = try self.lexer.peek();
        if (next.kind == .open_brace) {
            _ = try self.lexer.next();
            while (true) {
                const tok = try self.lexer.peek();
                if (tok.kind == .close_brace) {
                    _ = try self.lexer.next();
                    break;
                }
                if (tok.kind == .eof) {
                    try self.add_error(tok.location, "unexpected EOF in rpc body");
                    break;
                }
                if (tok.kind == .semicolon) {
                    _ = try self.lexer.next();
                    continue;
                }
                if (tok.kind == .identifier and std.mem.eql(u8, tok.text, "option")) {
                    try options.append(self.allocator, try self.parse_option_decl());
                    continue;
                }
                try self.add_error(tok.location, "unexpected token in rpc body");
                try self.skip_statement();
            }
        } else {
            try self.expect_punct(.semicolon);
        }

        return .{
            .name = name,
            .input_type = input_type,
            .output_type = output_type,
            .client_streaming = client_streaming,
            .server_streaming = server_streaming,
            .options = try options.toOwnedSlice(self.allocator),
            .location = loc,
        };
    }

    // ── Shared Helpers ────────────────────────────────────────────────

    fn parse_option_name(self: *Parser) !ast.OptionName {
        var parts: std.ArrayList(ast.OptionName.Part) = .empty;

        const tok = try self.lexer.peek();
        if (tok.kind == .open_paren) {
            // Extension name: (name)
            _ = try self.lexer.next();
            const ext_name = try self.parse_full_ident();
            try self.expect_punct(.close_paren);
            try parts.append(self.allocator, .{ .name = ext_name, .is_extension = true });
        } else {
            const name = (try self.expect_kind(.identifier)).text;
            try parts.append(self.allocator, .{ .name = name, .is_extension = false });
        }

        // Optional additional parts: .name
        while ((try self.lexer.peek()).kind == .dot) {
            _ = try self.lexer.next();
            const part_name = (try self.expect_kind(.identifier)).text;
            try parts.append(self.allocator, .{ .name = part_name, .is_extension = false });
        }

        return .{ .parts = try parts.toOwnedSlice(self.allocator) };
    }

    fn parse_constant(self: *Parser) !ast.Constant {
        const tok = try self.lexer.peek();

        if (tok.kind == .string_literal) {
            _ = try self.lexer.next();
            // Handle adjacent string concatenation
            var resolved = try lexer_mod.resolve_string(tok.text, self.allocator);
            while ((try self.lexer.peek()).kind == .string_literal) {
                const next_tok = try self.lexer.next();
                const next_resolved = try lexer_mod.resolve_string(next_tok.text, self.allocator);
                const new_str = try self.allocator.alloc(u8, resolved.len + next_resolved.len);
                @memcpy(new_str[0..resolved.len], resolved);
                @memcpy(new_str[resolved.len..], next_resolved);
                self.allocator.free(resolved);
                self.allocator.free(next_resolved);
                resolved = new_str;
            }
            return .{ .string_value = resolved };
        }

        if (tok.kind == .integer) {
            _ = try self.lexer.next();
            return .{ .unsigned_integer = try parse_int(tok.text) };
        }

        if (tok.kind == .float_literal) {
            _ = try self.lexer.next();
            const val = std.fmt.parseFloat(f64, tok.text) catch 0.0;
            return .{ .float_value = val };
        }

        if (tok.kind == .open_brace) {
            // Aggregate: capture raw text between braces
            return .{ .aggregate = try self.parse_aggregate() };
        }

        if (tok.kind == .minus) {
            _ = try self.lexer.next();
            const next = try self.lexer.peek();
            if (next.kind == .integer) {
                _ = try self.lexer.next();
                const val = try parse_int(next.text);
                return .{ .integer = -@as(i64, @intCast(val)) };
            }
            if (next.kind == .float_literal) {
                _ = try self.lexer.next();
                const val = std.fmt.parseFloat(f64, next.text) catch 0.0;
                return .{ .float_value = -val };
            }
            if (next.kind == .identifier and std.mem.eql(u8, next.text, "inf")) {
                _ = try self.lexer.next();
                return .{ .float_value = -std.math.inf(f64) };
            }
            try self.add_error(next.location, "expected number after '-'");
            return .{ .integer = 0 };
        }

        if (tok.kind == .plus) {
            _ = try self.lexer.next();
            const next = try self.lexer.peek();
            if (next.kind == .integer) {
                _ = try self.lexer.next();
                return .{ .unsigned_integer = try parse_int(next.text) };
            }
            if (next.kind == .float_literal) {
                _ = try self.lexer.next();
                const val = std.fmt.parseFloat(f64, next.text) catch 0.0;
                return .{ .float_value = val };
            }
            try self.add_error(next.location, "expected number after '+'");
            return .{ .unsigned_integer = 0 };
        }

        if (tok.kind == .identifier) {
            _ = try self.lexer.next();
            if (std.mem.eql(u8, tok.text, "true")) return .{ .bool_value = true };
            if (std.mem.eql(u8, tok.text, "false")) return .{ .bool_value = false };
            if (std.mem.eql(u8, tok.text, "inf")) return .{ .float_value = std.math.inf(f64) };
            if (std.mem.eql(u8, tok.text, "nan")) return .{ .float_value = std.math.nan(f64) };
            return .{ .identifier = tok.text };
        }

        try self.add_error(tok.location, "expected constant value");
        return .{ .integer = 0 };
    }

    fn parse_aggregate(self: *Parser) ![]const u8 {
        try self.expect_punct(.open_brace);
        const start = self.lexer.pos;
        var depth: u32 = 1;
        while (depth > 0) {
            const tok = try self.lexer.next();
            if (tok.kind == .open_brace) depth += 1;
            if (tok.kind == .close_brace) depth -= 1;
            if (tok.kind == .eof) {
                try self.add_error(tok.location, "unexpected EOF in aggregate");
                break;
            }
        }
        // Return the raw text between the braces
        const end = self.lexer.pos - 1; // before the closing brace
        return self.lexer.source[start..end];
    }

    fn parse_field_options(self: *Parser) ![]ast.FieldOption {
        try self.expect_punct(.open_bracket);
        var options: std.ArrayList(ast.FieldOption) = .empty;

        try options.append(self.allocator, try self.parse_single_field_option());
        while ((try self.lexer.peek()).kind == .comma) {
            _ = try self.lexer.next();
            try options.append(self.allocator, try self.parse_single_field_option());
        }

        try self.expect_punct(.close_bracket);
        return try options.toOwnedSlice(self.allocator);
    }

    fn parse_single_field_option(self: *Parser) !ast.FieldOption {
        const name = try self.parse_option_name();
        try self.expect_punct(.equals);
        const value = try self.parse_constant();
        return .{ .name = name, .value = value };
    }

    fn parse_full_ident(self: *Parser) ![]const u8 {
        const first = (try self.expect_kind(.identifier)).text;
        if ((try self.lexer.peek()).kind != .dot) return first;

        var parts: std.ArrayList(u8) = .empty;
        try parts.appendSlice(self.allocator, first);

        while ((try self.lexer.peek()).kind == .dot) {
            _ = try self.lexer.next();
            try parts.append(self.allocator, '.');
            const seg = (try self.expect_kind(.identifier)).text;
            try parts.appendSlice(self.allocator, seg);
        }

        return try parts.toOwnedSlice(self.allocator);
    }

    // ── Lookahead Helpers ─────────────────────────────────────────────

    fn is_label_coming(self: *Parser) !bool {
        // Current token is a potential label keyword.
        // We need to determine if the NEXT token starts a type (making current a label)
        // or if the current token IS the type.
        // Peek at the token after the potential label.
        // Save state and do a lookahead.
        const saved_peeked = self.lexer.peeked;
        const saved_pos = self.lexer.pos;
        const saved_line = self.lexer.line;
        const saved_col = self.lexer.column;

        // Consume the label candidate
        _ = try self.lexer.next();
        const after_label = try self.lexer.peek();

        // Restore state
        self.lexer.peeked = saved_peeked;
        self.lexer.pos = saved_pos;
        self.lexer.line = saved_line;
        self.lexer.column = saved_col;

        // If the next token after the label is a type-starting token, it's a label
        // Types start with: identifier (type name or scalar), dot (qualified name)
        return after_label.kind == .identifier or after_label.kind == .dot;
    }

    fn is_group_coming(self: *Parser) !bool {
        // Current token is a label keyword. Check if the token after it is "group".
        const saved_peeked = self.lexer.peeked;
        const saved_pos = self.lexer.pos;
        const saved_line = self.lexer.line;
        const saved_col = self.lexer.column;

        _ = try self.lexer.next(); // consume label
        const after = try self.lexer.peek();

        self.lexer.peeked = saved_peeked;
        self.lexer.pos = saved_pos;
        self.lexer.line = saved_line;
        self.lexer.column = saved_col;

        return after.kind == .identifier and std.mem.eql(u8, after.text, "group");
    }

    // ── Token Helpers ─────────────────────────────────────────────────

    fn expect_keyword(self: *Parser, keyword: []const u8) !void {
        const tok = try self.lexer.next();
        if (tok.kind != .identifier or !std.mem.eql(u8, tok.text, keyword)) {
            try self.add_error(tok.location, "expected keyword");
            return error.ParseFailed;
        }
    }

    fn expect_kind(self: *Parser, kind: lexer_mod.TokenKind) !lexer_mod.Token {
        const tok = try self.lexer.next();
        if (tok.kind != kind) {
            try self.add_error(tok.location, "unexpected token");
            return error.ParseFailed;
        }
        return tok;
    }

    fn expect_punct(self: *Parser, kind: lexer_mod.TokenKind) !void {
        const tok = try self.lexer.next();
        if (tok.kind != kind) {
            try self.add_error(tok.location, "expected punctuation");
            return error.ParseFailed;
        }
    }

    fn add_error(self: *Parser, location: ast.SourceLocation, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .location = location,
            .severity = .err,
            .message = message,
        });
    }

    fn skip_statement(self: *Parser) !void {
        while (true) {
            const tok = try self.lexer.next();
            if (tok.kind == .semicolon or tok.kind == .eof) return;
            if (tok.kind == .close_brace) return;
            if (tok.kind == .open_brace) {
                try self.skip_braces();
                return;
            }
        }
    }

    fn skip_braces(self: *Parser) !void {
        var depth: u32 = 1;
        while (depth > 0) {
            const tok = try self.lexer.next();
            if (tok.kind == .open_brace) depth += 1;
            if (tok.kind == .close_brace) depth -= 1;
            if (tok.kind == .eof) return;
        }
    }

    pub const Error = error{
        ParseFailed,
        InvalidCharacter,
        UnterminatedBlockComment,
        UnterminatedString,
        InvalidEscape,
        InvalidNumber,
        OutOfMemory,
        Overflow,
    };
};

// ── Utility Functions ─────────────────────────────────────────────────

fn is_label(text: []const u8) bool {
    return std.mem.eql(u8, text, "optional") or
        std.mem.eql(u8, text, "required") or
        std.mem.eql(u8, text, "repeated");
}

fn label_from_text(text: []const u8, syntax: ast.Syntax) ast.FieldLabel {
    _ = syntax;
    if (std.mem.eql(u8, text, "required")) return .required;
    if (std.mem.eql(u8, text, "optional")) return .optional;
    if (std.mem.eql(u8, text, "repeated")) return .repeated;
    return .implicit;
}

fn parse_int(text: []const u8) !u64 {
    if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        // Hex
        return std.fmt.parseInt(u64, text[2..], 16) catch return error.Overflow;
    }
    if (text.len >= 2 and text[0] == '0') {
        // Octal
        return std.fmt.parseInt(u64, text[1..], 8) catch return error.Overflow;
    }
    return std.fmt.parseInt(u64, text, 10) catch return error.Overflow;
}

// ── Helper for tests ──────────────────────────────────────────────────

// Test infrastructure: we use an arena so we don't need to free individual AST nodes.
// The arena is leaked from the testing allocator's perspective, but that's intentional
// for test-only code (the arena owns everything).
var test_arena: ?std.heap.ArenaAllocator = null;

fn get_test_arena() std.mem.Allocator {
    if (test_arena) |*a| {
        _ = a.reset(.retain_capacity);
    } else {
        test_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    return test_arena.?.allocator();
}

fn parse_test(source: []const u8) !ast.File {
    return parse_test_with_diags(source, null);
}

fn parse_test_with_diags(source: []const u8, diag_out: ?*DiagnosticList) !ast.File {
    const arena = get_test_arena();
    var owned_diags: DiagnosticList = .empty;
    const diags = diag_out orelse &owned_diags;
    const lex = lexer_mod.Lexer.init(source, "test.proto");
    var parser = Parser.init(lex, arena, diags);
    return parser.parse_file();
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

// ── Syntax tests ──────────────────────────────────────────────────────

test "Parser: syntax proto3" {
    const file = try parse_test("syntax = \"proto3\";");
    try testing.expectEqual(ast.Syntax.proto3, file.syntax);
}

test "Parser: syntax proto2" {
    const file = try parse_test("syntax = \"proto2\";");
    try testing.expectEqual(ast.Syntax.proto2, file.syntax);
}

// ── Import tests ──────────────────────────────────────────────────────

test "Parser: simple import" {
    const file = try parse_test("syntax = \"proto3\"; import \"foo.proto\";");
    try testing.expectEqual(@as(usize, 1), file.imports.len);
    try testing.expectEqualStrings("foo.proto", file.imports[0].path);
    try testing.expectEqual(@as(@TypeOf(file.imports[0].kind), .default), file.imports[0].kind);
}

test "Parser: import public" {
    const file = try parse_test("syntax = \"proto3\"; import public \"foo.proto\";");
    try testing.expectEqual(@as(usize, 1), file.imports.len);
    try testing.expectEqual(@as(@TypeOf(file.imports[0].kind), .public), file.imports[0].kind);
}

test "Parser: import weak" {
    const file = try parse_test("syntax = \"proto3\"; import weak \"foo.proto\";");
    try testing.expectEqual(@as(usize, 1), file.imports.len);
    try testing.expectEqual(@as(@TypeOf(file.imports[0].kind), .weak), file.imports[0].kind);
}

// ── Package tests ─────────────────────────────────────────────────────

test "Parser: package" {
    const file = try parse_test("syntax = \"proto3\"; package foo.bar;");
    try testing.expectEqualStrings("foo.bar", file.package.?);
}

// ── Option tests ──────────────────────────────────────────────────────

test "Parser: simple option" {
    const file = try parse_test("syntax = \"proto3\"; option java_package = \"com.example\";");
    try testing.expectEqual(@as(usize, 1), file.options.len);
    try testing.expectEqualStrings("java_package", file.options[0].name.parts[0].name);
    try testing.expectEqualStrings("com.example", file.options[0].value.string_value);
}

test "Parser: option with identifier constant" {
    const file = try parse_test("syntax = \"proto3\"; option optimize_for = SPEED;");
    try testing.expectEqual(@as(usize, 1), file.options.len);
    try testing.expectEqualStrings("SPEED", file.options[0].value.identifier);
}

test "Parser: extension option" {
    const file = try parse_test("syntax = \"proto3\"; option (custom_option) = 42;");
    try testing.expectEqual(@as(usize, 1), file.options.len);
    try testing.expect(file.options[0].name.parts[0].is_extension);
    try testing.expectEqualStrings("custom_option", file.options[0].name.parts[0].name);
    try testing.expectEqual(@as(u64, 42), file.options[0].value.unsigned_integer);
}

test "Parser: bool option" {
    const file = try parse_test("syntax = \"proto3\"; option deprecated = true;");
    try testing.expect(file.options[0].value.bool_value);
}

// ── Enum tests ────────────────────────────────────────────────────────

test "Parser: simple enum" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\enum Status {
        \\  UNKNOWN = 0;
        \\  ACTIVE = 1;
        \\  INACTIVE = 2;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), file.enums.len);
    const e = file.enums[0];
    try testing.expectEqualStrings("Status", e.name);
    try testing.expectEqual(@as(usize, 3), e.values.len);
    try testing.expectEqualStrings("UNKNOWN", e.values[0].name);
    try testing.expectEqual(@as(i32, 0), e.values[0].number);
    try testing.expectEqualStrings("ACTIVE", e.values[1].name);
    try testing.expectEqual(@as(i32, 1), e.values[1].number);
}

test "Parser: enum with negative value" {
    const file = try parse_test(
        \\syntax = "proto2";
        \\enum Neg {
        \\  MINUS_ONE = -1;
        \\  ZERO = 0;
        \\}
    );
    try testing.expectEqual(@as(i32, -1), file.enums[0].values[0].number);
}

test "Parser: enum with field options" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\enum Status {
        \\  UNKNOWN = 0;
        \\  ACTIVE = 1 [deprecated = true];
        \\}
    );
    try testing.expectEqual(@as(usize, 1), file.enums[0].values[1].options.len);
}

test "Parser: enum with allow_alias" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\enum Status {
        \\  option allow_alias = true;
        \\  UNKNOWN = 0;
        \\  STARTED = 1;
        \\  RUNNING = 1;
        \\}
    );
    try testing.expect(file.enums[0].allow_alias);
}

test "Parser: enum with reserved" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\enum Status {
        \\  UNKNOWN = 0;
        \\  reserved 2, 15, 9 to 11;
        \\  reserved "FOO", "BAR";
        \\}
    );
    try testing.expectEqual(@as(usize, 3), file.enums[0].reserved_ranges.len);
    try testing.expectEqual(@as(usize, 2), file.enums[0].reserved_names.len);
    try testing.expectEqualStrings("FOO", file.enums[0].reserved_names[0]);
}

// ── Message tests ─────────────────────────────────────────────────────

test "Parser: simple proto3 message" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\message Person {
        \\  string name = 1;
        \\  int32 id = 2;
        \\  string email = 3;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), file.messages.len);
    const msg = file.messages[0];
    try testing.expectEqualStrings("Person", msg.name);
    try testing.expectEqual(@as(usize, 3), msg.fields.len);
    try testing.expectEqualStrings("name", msg.fields[0].name);
    try testing.expectEqual(ast.FieldLabel.implicit, msg.fields[0].label);
    try testing.expectEqual(ast.ScalarType.string, msg.fields[0].type_name.scalar);
    try testing.expectEqual(@as(i32, 1), msg.fields[0].number);
}

test "Parser: proto2 with labels" {
    const file = try parse_test(
        \\syntax = "proto2";
        \\message Person {
        \\  required string name = 1;
        \\  optional int32 id = 2;
        \\  repeated string phones = 3;
        \\}
    );
    const msg = file.messages[0];
    try testing.expectEqual(ast.FieldLabel.required, msg.fields[0].label);
    try testing.expectEqual(ast.FieldLabel.optional, msg.fields[1].label);
    try testing.expectEqual(ast.FieldLabel.repeated, msg.fields[2].label);
}

test "Parser: nested messages" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\message Outer {
        \\  message Inner {
        \\    int32 value = 1;
        \\  }
        \\  Inner inner = 1;
        \\}
    );
    const msg = file.messages[0];
    try testing.expectEqualStrings("Outer", msg.name);
    try testing.expectEqual(@as(usize, 1), msg.nested_messages.len);
    try testing.expectEqualStrings("Inner", msg.nested_messages[0].name);
    try testing.expectEqual(@as(usize, 1), msg.fields.len);
    try testing.expectEqualStrings("Inner", msg.fields[0].type_name.named);
}

test "Parser: oneof" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\message Sample {
        \\  oneof test_oneof {
        \\    string name = 4;
        \\    int32 id = 5;
        \\  }
        \\}
    );
    const msg = file.messages[0];
    try testing.expectEqual(@as(usize, 1), msg.oneofs.len);
    try testing.expectEqualStrings("test_oneof", msg.oneofs[0].name);
    try testing.expectEqual(@as(usize, 2), msg.oneofs[0].fields.len);
    try testing.expectEqualStrings("name", msg.oneofs[0].fields[0].name);
}

test "Parser: map field" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\message MapMessage {
        \\  map<string, int32> counts = 1;
        \\}
    );
    const msg = file.messages[0];
    try testing.expectEqual(@as(usize, 1), msg.maps.len);
    try testing.expectEqualStrings("counts", msg.maps[0].name);
    try testing.expectEqual(ast.ScalarType.string, msg.maps[0].key_type);
    try testing.expectEqual(ast.ScalarType.int32, msg.maps[0].value_type.scalar);
}

test "Parser: field options" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\message Msg {
        \\  int32 old_field = 1 [deprecated = true];
        \\}
    );
    try testing.expectEqual(@as(usize, 1), file.messages[0].fields[0].options.len);
}

test "Parser: reserved ranges and names" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\message Msg {
        \\  reserved 2, 15, 9 to 11;
        \\  reserved "foo", "bar";
        \\}
    );
    const msg = file.messages[0];
    try testing.expectEqual(@as(usize, 3), msg.reserved_ranges.len);
    try testing.expectEqual(@as(i32, 2), msg.reserved_ranges[0].start);
    try testing.expectEqual(@as(i32, 2), msg.reserved_ranges[0].end);
    try testing.expectEqual(@as(i32, 9), msg.reserved_ranges[2].start);
    try testing.expectEqual(@as(i32, 11), msg.reserved_ranges[2].end);
    try testing.expectEqual(@as(usize, 2), msg.reserved_names.len);
    try testing.expectEqualStrings("foo", msg.reserved_names[0]);
}

test "Parser: extensions (proto2)" {
    const file = try parse_test(
        \\syntax = "proto2";
        \\message Msg {
        \\  extensions 100 to 199;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), file.messages[0].extension_ranges.len);
    try testing.expectEqual(@as(i32, 100), file.messages[0].extension_ranges[0].start);
    try testing.expectEqual(@as(i32, 199), file.messages[0].extension_ranges[0].end);
}

test "Parser: extend block (proto2)" {
    const file = try parse_test(
        \\syntax = "proto2";
        \\message Msg {
        \\  extensions 100 to 199;
        \\}
        \\extend Msg {
        \\  optional string extra = 100;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), file.extensions.len);
    try testing.expectEqualStrings("Msg", file.extensions[0].type_name);
    try testing.expectEqual(@as(usize, 1), file.extensions[0].fields.len);
}

test "Parser: qualified type names" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\message Msg {
        \\  .fully.qualified.Type field1 = 1;
        \\  relative.Type field2 = 2;
        \\}
    );
    try testing.expectEqualStrings(".fully.qualified.Type", file.messages[0].fields[0].type_name.named);
    try testing.expectEqualStrings("relative.Type", file.messages[0].fields[1].type_name.named);
}

test "Parser: nested enum in message" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\message Msg {
        \\  enum Status { UNKNOWN = 0; }
        \\  Status status = 1;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), file.messages[0].nested_enums.len);
    try testing.expectEqualStrings("Status", file.messages[0].nested_enums[0].name);
}

// ── Service tests ─────────────────────────────────────────────────────

test "Parser: simple service" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\service Greeter {
        \\  rpc SayHello (HelloRequest) returns (HelloReply);
        \\}
    );
    try testing.expectEqual(@as(usize, 1), file.services.len);
    const svc = file.services[0];
    try testing.expectEqualStrings("Greeter", svc.name);
    try testing.expectEqual(@as(usize, 1), svc.methods.len);
    try testing.expectEqualStrings("SayHello", svc.methods[0].name);
    try testing.expectEqualStrings("HelloRequest", svc.methods[0].input_type);
    try testing.expectEqualStrings("HelloReply", svc.methods[0].output_type);
    try testing.expect(!svc.methods[0].client_streaming);
    try testing.expect(!svc.methods[0].server_streaming);
}

test "Parser: server streaming" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\service Svc {
        \\  rpc ListFeatures (Rectangle) returns (stream Feature);
        \\}
    );
    try testing.expect(!file.services[0].methods[0].client_streaming);
    try testing.expect(file.services[0].methods[0].server_streaming);
}

test "Parser: client streaming" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\service Svc {
        \\  rpc RecordRoute (stream Point) returns (RouteSummary);
        \\}
    );
    try testing.expect(file.services[0].methods[0].client_streaming);
    try testing.expect(!file.services[0].methods[0].server_streaming);
}

test "Parser: bidi streaming" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\service Svc {
        \\  rpc RouteChat (stream RouteNote) returns (stream RouteNote);
        \\}
    );
    try testing.expect(file.services[0].methods[0].client_streaming);
    try testing.expect(file.services[0].methods[0].server_streaming);
}

test "Parser: rpc with options body" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\service Greeter {
        \\  rpc SayHello (HelloRequest) returns (HelloReply) {
        \\    option deprecated = true;
        \\  }
        \\}
    );
    try testing.expectEqual(@as(usize, 1), file.services[0].methods[0].options.len);
}

// ── Empty statements ──────────────────────────────────────────────────

test "Parser: empty statements" {
    const file = try parse_test("syntax = \"proto3\";;");
    try testing.expectEqual(ast.Syntax.proto3, file.syntax);
}

// ── Full integration test ─────────────────────────────────────────────

test "Parser: full realistic file" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\package example.v1;
        \\import "google/protobuf/timestamp.proto";
        \\option java_package = "com.example.v1";
        \\enum Status {
        \\  STATUS_UNSPECIFIED = 0;
        \\  STATUS_ACTIVE = 1;
        \\}
        \\message Person {
        \\  string name = 1;
        \\  int32 id = 2;
        \\  repeated PhoneNumber phones = 3;
        \\  Status status = 4;
        \\  message PhoneNumber {
        \\    string number = 1;
        \\  }
        \\  oneof contact {
        \\    string phone = 5;
        \\    string email_alt = 6;
        \\  }
        \\  map<string, string> attributes = 7;
        \\}
        \\service PersonService {
        \\  rpc GetPerson (GetPersonRequest) returns (Person);
        \\  rpc ListPersons (ListPersonsRequest) returns (stream Person);
        \\}
    );
    try testing.expectEqual(ast.Syntax.proto3, file.syntax);
    try testing.expectEqualStrings("example.v1", file.package.?);
    try testing.expectEqual(@as(usize, 1), file.imports.len);
    try testing.expectEqual(@as(usize, 1), file.options.len);
    try testing.expectEqual(@as(usize, 1), file.enums.len);
    try testing.expectEqual(@as(usize, 1), file.messages.len);
    try testing.expectEqual(@as(usize, 1), file.services.len);

    const msg = file.messages[0];
    try testing.expectEqual(@as(usize, 4), msg.fields.len);
    try testing.expectEqual(@as(usize, 1), msg.nested_messages.len);
    try testing.expectEqual(@as(usize, 1), msg.oneofs.len);
    try testing.expectEqual(@as(usize, 1), msg.maps.len);

    const svc = file.services[0];
    try testing.expectEqual(@as(usize, 2), svc.methods.len);
    try testing.expect(svc.methods[1].server_streaming);
}

// ── Adjacent string concatenation ─────────────────────────────────────

test "Parser: adjacent string concatenation in option" {
    const file = try parse_test(
        \\syntax = "proto3";
        \\option foo = "hello "
        \\             "world";
    );
    try testing.expectEqualStrings("hello world", file.options[0].value.string_value);
}

// ── Constant types ────────────────────────────────────────────────────

test "Parser: negative integer constant" {
    const file = try parse_test("syntax = \"proto3\"; option foo = -42;");
    try testing.expectEqual(@as(i64, -42), file.options[0].value.integer);
}

test "Parser: float constant" {
    const file = try parse_test("syntax = \"proto3\"; option foo = 3.14;");
    try testing.expectEqual(@as(f64, 3.14), file.options[0].value.float_value);
}

test "fuzz: Parser handles arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var diags: DiagnosticList = .empty;
            const lex = lexer_mod.Lexer.init(input, "fuzz.proto");
            var p = Parser.init(lex, allocator, &diags);
            _ = p.parse_file() catch return;
        }
    }.run, .{});
}
