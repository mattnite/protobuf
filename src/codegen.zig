const std = @import("std");
const testing = std.testing;
const ast = @import("proto/ast.zig");

pub const emitter = @import("codegen/emitter.zig");
pub const types = @import("codegen/types.zig");
pub const enums = @import("codegen/enums.zig");
pub const messages = @import("codegen/messages.zig");

const Emitter = emitter.Emitter;

/// Generate a complete Zig source file from a proto AST File.
pub fn generate_file(allocator: std.mem.Allocator, file: ast.File) ![]const u8 {
    var e = Emitter.init(allocator);
    defer e.deinit();

    // Imports header
    try e.print("const std = @import(\"std\");\n", .{});
    try e.print("const protobuf = @import(\"protobuf\");\n", .{});
    try e.print("const encoding = protobuf.encoding;\n", .{});
    try e.print("const message = protobuf.message;\n", .{});
    try e.blank_line();

    // Top-level enums
    for (file.enums) |en| {
        try enums.emit_enum(&e, en, file.syntax);
        try e.blank_line();
    }

    // Top-level messages
    for (file.messages) |msg| {
        try messages.emit_message(&e, msg, file.syntax);
        try e.blank_line();
    }

    return try allocator.dupe(u8, e.get_output());
}

/// Convert a protobuf package name and proto filename to a Zig output path.
/// "a.b.c" with any filename → "a/b/c.zig"
/// null package with "foo.proto" → "foo.zig"
/// null package with "path/to/bar.proto" → "bar.zig"
pub fn package_to_path(allocator: std.mem.Allocator, package: ?[]const u8, proto_filename: []const u8) ![]u8 {
    if (package) |pkg| {
        if (pkg.len > 0) {
            // Count dots to determine buffer size
            var len: usize = 0;
            for (pkg) |c| {
                if (c == '.') {
                    len += 1; // '/' replaces '.'
                } else {
                    len += 1;
                }
            }
            len += 4; // ".zig"

            var result = try allocator.alloc(u8, len);
            var idx: usize = 0;
            for (pkg) |c| {
                if (c == '.') {
                    result[idx] = '/';
                } else {
                    result[idx] = c;
                }
                idx += 1;
            }
            @memcpy(result[idx..][0..4], ".zig");
            return result;
        }
    }

    // No package: use proto filename stem
    const basename = std.fs.path.basename(proto_filename);
    const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot|
        basename[0..dot]
    else
        basename;

    var result = try allocator.alloc(u8, stem.len + 4);
    @memcpy(result[0..stem.len], stem);
    @memcpy(result[stem.len..][0..4], ".zig");
    return result;
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

test {
    _ = emitter;
    _ = types;
    _ = enums;
    _ = messages;
}

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

fn make_file(syntax: ast.Syntax) ast.File {
    return .{
        .syntax = syntax,
        .package = null,
        .imports = &.{},
        .options = &.{},
        .messages = &.{},
        .enums = &.{},
        .services = &.{},
        .extensions = &.{},
    };
}

fn expect_contains(output: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, output, expected) == null) {
        std.debug.print("\n=== EXPECTED (not found) ===\n{s}\n=== IN OUTPUT ===\n{s}\n=== END ===\n", .{ expected, output });
        return error.TestExpectedEqual;
    }
}

test "generate_file: proto3 file with enum and message" {
    var enum_values = [_]ast.EnumValue{
        .{ .name = "UNKNOWN", .number = 0, .options = &.{}, .location = loc },
        .{ .name = "ACTIVE", .number = 1, .options = &.{}, .location = loc },
    };
    var file_enums = [_]ast.Enum{.{
        .name = "Status",
        .values = &enum_values,
        .options = &.{},
        .allow_alias = false,
        .reserved_ranges = &.{},
        .reserved_names = &.{},
        .location = loc,
    }};

    var msg_fields = [_]ast.Field{
        make_field("name", 1, .implicit, .{ .scalar = .string }),
        make_field("id", 2, .implicit, .{ .scalar = .int32 }),
    };
    var file_msgs = [_]ast.Message{blk: {
        var m = make_msg("Person");
        m.fields = &msg_fields;
        break :blk m;
    }};

    var file = make_file(.proto3);
    file.enums = &file_enums;
    file.messages = &file_msgs;

    const output = try generate_file(testing.allocator, file);
    defer testing.allocator.free(output);

    // Verify imports
    try expect_contains(output, "const std = @import(\"std\");");
    try expect_contains(output, "const protobuf = @import(\"protobuf\");");
    try expect_contains(output, "const encoding = protobuf.encoding;");
    try expect_contains(output, "const message = protobuf.message;");

    // Verify enum
    try expect_contains(output, "pub const Status = enum(i32) {");
    try expect_contains(output, "    UNKNOWN = 0,");
    try expect_contains(output, "    _,");

    // Verify message
    try expect_contains(output, "pub const Person = struct {");
    try expect_contains(output, "    name: []const u8 = \"\",");
    try expect_contains(output, "    id: i32 = 0,");

    // Verify methods
    try expect_contains(output, "pub fn encode(");
    try expect_contains(output, "pub fn decode(");
    try expect_contains(output, "pub fn calc_size(");
    try expect_contains(output, "pub fn deinit(");
}

test "generate_file: proto2 file with required/optional fields" {
    var msg_fields = [_]ast.Field{
        make_field("name", 1, .required, .{ .scalar = .string }),
        make_field("email", 2, .optional, .{ .scalar = .string }),
    };
    var file_msgs = [_]ast.Message{blk: {
        var m = make_msg("LegacyUser");
        m.fields = &msg_fields;
        break :blk m;
    }};

    var file = make_file(.proto2);
    file.messages = &file_msgs;

    const output = try generate_file(testing.allocator, file);
    defer testing.allocator.free(output);

    try expect_contains(output, "pub const LegacyUser = struct {");
    try expect_contains(output, "    name: []const u8 = \"\",");
    try expect_contains(output, "    email: ?[]const u8 = null,");
    // Required field encode: always write
    try expect_contains(output, "try mw.write_len_field(1, self.name);");
}

test "generate_file: nested messages and enums" {
    var inner_fields = [_]ast.Field{
        make_field("x", 1, .implicit, .{ .scalar = .int32 }),
    };

    var enum_values = [_]ast.EnumValue{
        .{ .name = "A", .number = 0, .options = &.{}, .location = loc },
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

    var nested_msgs = [_]ast.Message{blk: {
        var m = make_msg("Inner");
        m.fields = &inner_fields;
        break :blk m;
    }};

    var outer_fields = [_]ast.Field{
        make_field("inner", 1, .implicit, .{ .named = "Inner" }),
    };
    var file_msgs = [_]ast.Message{blk: {
        var m = make_msg("Outer");
        m.nested_enums = &nested_enums;
        m.nested_messages = &nested_msgs;
        m.fields = &outer_fields;
        break :blk m;
    }};

    var file = make_file(.proto3);
    file.messages = &file_msgs;

    const output = try generate_file(testing.allocator, file);
    defer testing.allocator.free(output);

    try expect_contains(output, "pub const Outer = struct {");
    try expect_contains(output, "pub const Kind = enum(i32)");
    try expect_contains(output, "pub const Inner = struct {");
    try expect_contains(output, "    inner: ?Inner = null,");
}

test "generate_file: map fields, oneofs, repeated fields" {
    var maps = [_]ast.MapField{.{
        .name = "labels",
        .number = 3,
        .key_type = .string,
        .value_type = .{ .scalar = .string },
        .options = &.{},
        .location = loc,
    }};

    var oneof_fields = [_]ast.Field{
        make_field("text", 4, .implicit, .{ .scalar = .string }),
        make_field("count", 5, .implicit, .{ .scalar = .int32 }),
    };
    var oneofs = [_]ast.Oneof{.{
        .name = "payload",
        .fields = &oneof_fields,
        .options = &.{},
        .location = loc,
    }};

    var msg_fields = [_]ast.Field{
        make_field("id", 1, .implicit, .{ .scalar = .int32 }),
        make_field("tags", 2, .repeated, .{ .scalar = .string }),
    };

    var file_msgs = [_]ast.Message{blk: {
        var m = make_msg("Complex");
        m.fields = &msg_fields;
        m.maps = &maps;
        m.oneofs = &oneofs;
        break :blk m;
    }};

    var file = make_file(.proto3);
    file.messages = &file_msgs;

    const output = try generate_file(testing.allocator, file);
    defer testing.allocator.free(output);

    // Map field
    try expect_contains(output, "    labels: std.StringArrayHashMapUnmanaged([]const u8) = .empty,");
    // Oneof type
    try expect_contains(output, "pub const Payload = union(enum)");
    // Oneof field
    try expect_contains(output, "    payload: ?Payload = null,");
    // Repeated
    try expect_contains(output, "    tags: []const []const u8 = &.{},");
}

// ── package_to_path tests ──────────────────────────────────────────────

test "package_to_path: dotted package" {
    const result = try package_to_path(testing.allocator, "a.b.c", "anything.proto");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a/b/c.zig", result);
}

test "package_to_path: single segment package" {
    const result = try package_to_path(testing.allocator, "mypackage", "foo.proto");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("mypackage.zig", result);
}

test "package_to_path: no package uses filename" {
    const result = try package_to_path(testing.allocator, null, "foo.proto");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("foo.zig", result);
}

test "package_to_path: no package strips path" {
    const result = try package_to_path(testing.allocator, null, "path/to/bar.proto");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("bar.zig", result);
}

test "package_to_path: empty package uses filename" {
    const result = try package_to_path(testing.allocator, "", "test.proto");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("test.zig", result);
}
