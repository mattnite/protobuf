const std = @import("std");
const testing = std.testing;
const ast = @import("proto/ast.zig");

pub const emitter = @import("codegen/emitter.zig");
pub const types = @import("codegen/types.zig");
pub const enums = @import("codegen/enums.zig");
pub const messages = @import("codegen/messages.zig");
pub const services = @import("codegen/services.zig");

const Emitter = emitter.Emitter;

/// Generate a complete Zig source file from a proto AST File.
pub fn generate_file(allocator: std.mem.Allocator, file: ast.File, proto_filename: []const u8) ![]const u8 {
    // Same-file extension flattening: merge extend blocks into target messages.
    try flatten_extensions(allocator, file.messages, file.extensions);
    for (file.messages) |*msg| {
        try flatten_message_extensions(allocator, msg);
    }

    // Resolve enum type references before codegen.
    // Collect file-level enum names, then walk all messages to replace
    // .named TypeRefs with .enum_ref where the name matches an enum.
    var file_enum_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer file_enum_names.deinit(allocator);
    for (file.enums) |en| {
        try file_enum_names.append(allocator, en.name);
    }
    for (file.messages) |*msg| {
        resolve_message_enum_refs(msg, file_enum_names.items);
    }

    var e = Emitter.init(allocator);
    defer e.deinit();

    // Imports header
    try e.print("const std = @import(\"std\");\n", .{});
    try e.print("const protobuf = @import(\"protobuf\");\n", .{});
    try e.print("const encoding = protobuf.encoding;\n", .{});
    try e.print("const message = protobuf.message;\n", .{});
    if (file.messages.len > 0) {
        try e.print("const json = protobuf.json;\n", .{});
        try e.print("const text_format = protobuf.text_format;\n", .{});
    }
    try e.blank_line();

    // Top-level enums
    for (file.enums) |en| {
        var name_buf: [512]u8 = undefined;
        const full_name = qualified_name(file.package, en.name, &name_buf);
        try enums.emit_enum(&e, en, file.syntax, full_name);
        try e.blank_line();
    }

    // Top-level messages
    for (file.messages) |msg| {
        var name_buf: [512]u8 = undefined;
        const full_name = qualified_name(file.package, msg.name, &name_buf);
        try messages.emit_message(&e, msg, file.syntax, full_name);
        try e.blank_line();
    }

    // Services
    if (file.services.len > 0) {
        try e.print("const rpc = protobuf.rpc;\n", .{});
        try e.blank_line();
    }
    for (file.services) |service| {
        try services.emit_service(&e, service, file.package);
        try e.blank_line();
    }

    // File descriptor
    if (file.messages.len > 0 or file.enums.len > 0) {
        try emit_file_descriptor(&e, file, proto_filename);
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

// ── Name Helpers ──────────────────────────────────────────────────────

fn qualified_name(package: ?[]const u8, name: []const u8, buf: []u8) []const u8 {
    if (package) |pkg| {
        if (pkg.len > 0) {
            return std.fmt.bufPrint(buf, "{s}.{s}", .{ pkg, name }) catch unreachable;
        }
    }
    return name;
}

fn emit_file_descriptor(e: *Emitter, file: ast.File, proto_filename: []const u8) !void {
    try e.print("pub const _file_descriptor = protobuf.descriptor.FileDescriptor{{\n", .{});
    e.indent_level += 1;
    try e.print(".name = \"{s}\",\n", .{proto_filename});
    if (file.package) |pkg| {
        if (pkg.len > 0) {
            try e.print(".package = \"{s}\",\n", .{pkg});
        } else {
            try e.print(".package = null,\n", .{});
        }
    } else {
        try e.print(".package = null,\n", .{});
    }
    try e.print(".syntax = {s},\n", .{switch (file.syntax) {
        .proto2 => ".proto2",
        .proto3 => ".proto3",
    }});

    // Messages
    try e.print(".messages = &.{{\n", .{});
    e.indent_level += 1;
    for (file.messages) |msg| {
        try e.print("{s}.descriptor,\n", .{msg.name});
    }
    e.indent_level -= 1;
    try e.print("}},\n", .{});

    // Enums
    try e.print(".enums = &.{{\n", .{});
    e.indent_level += 1;
    for (file.enums) |en| {
        try e.print("{s}.descriptor,\n", .{en.name});
    }
    e.indent_level -= 1;
    try e.print("}},\n", .{});

    e.indent_level -= 1;
    try e.print("}};\n", .{});
}

// ── Extension Flattening ──────────────────────────────────────────────

/// Flatten extensions from a list of Extend blocks into target messages.
fn flatten_extensions(allocator: std.mem.Allocator, msgs: []ast.Message, extensions: []const ast.Extend) !void {
    for (extensions) |ext| {
        // Find the target message by name (simple name match within the file)
        for (msgs) |*msg| {
            if (std.mem.eql(u8, msg.name, ext.type_name)) {
                try merge_extension_fields(allocator, msg, ext);
                break;
            }
            // Also check nested messages
            if (try find_and_merge_nested(allocator, msg.nested_messages, ext)) break;
        }
    }
}

/// Recursively walk nested messages to find extension target.
fn find_and_merge_nested(allocator: std.mem.Allocator, nested: []ast.Message, ext: ast.Extend) !bool {
    for (nested) |*msg| {
        if (std.mem.eql(u8, msg.name, ext.type_name)) {
            try merge_extension_fields(allocator, msg, ext);
            return true;
        }
        if (try find_and_merge_nested(allocator, msg.nested_messages, ext)) return true;
    }
    return false;
}

/// Merge extension fields into the target message, validating field numbers
/// fall within the message's declared extension_ranges.
fn merge_extension_fields(allocator: std.mem.Allocator, msg: *ast.Message, ext: ast.Extend) !void {
    // Collect valid extension fields
    var valid_fields: std.ArrayListUnmanaged(ast.Field) = .empty;
    defer valid_fields.deinit(allocator);

    for (ext.fields) |field| {
        if (field_in_extension_ranges(field.number, msg.extension_ranges)) {
            try valid_fields.append(allocator, field);
        }
    }

    if (valid_fields.items.len == 0) return;

    // Create new combined fields slice
    const new_fields = try allocator.alloc(ast.Field, msg.fields.len + valid_fields.items.len);
    @memcpy(new_fields[0..msg.fields.len], msg.fields);
    @memcpy(new_fields[msg.fields.len..], valid_fields.items);
    msg.fields = new_fields;
}

fn field_in_extension_ranges(number: i32, ranges: []const ast.ExtensionRange) bool {
    // If no extension ranges declared, accept any field (permissive)
    if (ranges.len == 0) return true;
    for (ranges) |range| {
        if (number >= range.start and number <= range.end) return true;
    }
    return false;
}

/// Flatten extensions declared within a message (msg.extensions).
fn flatten_message_extensions(allocator: std.mem.Allocator, msg: *ast.Message) !void {
    // Process extensions within this message
    if (msg.extensions.len > 0) {
        // Extensions within a message can target the message itself or its nested messages
        try flatten_extensions(allocator, msg.nested_messages, msg.extensions);
    }
    // Recurse into nested messages
    for (msg.nested_messages) |*nested| {
        try flatten_message_extensions(allocator, nested);
    }
}

// ── Enum Reference Resolution ─────────────────────────────────────────

/// Walk a message and its children, replacing .named TypeRefs with .enum_ref
/// where the name matches a known enum (from file-level or nested scope).
fn resolve_message_enum_refs(msg: *ast.Message, parent_enum_names: []const []const u8) void {
    // Build combined set: parent enums + this message's nested enums
    var buf: [256][]const u8 = undefined;
    var count: usize = 0;
    for (parent_enum_names) |name| {
        buf[count] = name;
        count += 1;
    }
    for (msg.nested_enums) |en| {
        buf[count] = en.name;
        count += 1;
    }
    const enum_names = buf[0..count];

    // Resolve regular fields
    for (msg.fields) |*field| {
        resolve_type_ref(&field.type_name, enum_names);
    }

    // Resolve oneof fields
    for (msg.oneofs) |*oneof| {
        for (oneof.fields) |*field| {
            resolve_type_ref(&field.type_name, enum_names);
        }
    }

    // Resolve map value types
    for (msg.maps) |*map_field| {
        resolve_type_ref(&map_field.value_type, enum_names);
    }

    // Recurse into nested messages
    for (msg.nested_messages) |*nested| {
        resolve_message_enum_refs(nested, enum_names);
    }
}

fn resolve_type_ref(type_ref: *ast.TypeRef, enum_names: []const []const u8) void {
    switch (type_ref.*) {
        .named => |name| {
            for (enum_names) |en| {
                if (std.mem.eql(u8, name, en)) {
                    type_ref.* = .{ .enum_ref = name };
                    return;
                }
            }
        },
        else => {},
    }
}

fn is_enum_name(name: []const u8, enum_names: []const []const u8) bool {
    for (enum_names) |en| {
        if (std.mem.eql(u8, name, en)) return true;
    }
    return false;
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

test {
    _ = emitter;
    _ = types;
    _ = enums;
    _ = messages;
    _ = services;
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

    const output = try generate_file(testing.allocator, file, "test.proto");
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

    const output = try generate_file(testing.allocator, file, "test.proto");
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

    const output = try generate_file(testing.allocator, file, "test.proto");
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

    const output = try generate_file(testing.allocator, file, "test.proto");
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

// ── Service integration tests ──────────────────────────────────────

test "generate_file: service with unary method" {
    var methods = [_]ast.Method{.{
        .name = "GetFeature",
        .input_type = "Point",
        .output_type = "Feature",
        .client_streaming = false,
        .server_streaming = false,
        .options = &.{},
        .location = loc,
    }};
    var file_services = [_]ast.Service{.{
        .name = "RouteGuide",
        .methods = &methods,
        .options = &.{},
        .location = loc,
    }};

    var file = make_file(.proto3);
    file.package = "routeguide";
    file.services = &file_services;

    const output = try generate_file(testing.allocator, file, "test.proto");
    defer testing.allocator.free(output);

    // rpc import
    try expect_contains(output, "const rpc = protobuf.rpc;");
    // Service struct
    try expect_contains(output, "pub const RouteGuide = struct");
    // Descriptor
    try expect_contains(output, "pub const service_descriptor = rpc.ServiceDescriptor{");
    try expect_contains(output, ".name = \"routeguide.RouteGuide\"");
    try expect_contains(output, ".full_path = \"/routeguide.RouteGuide/GetFeature\"");
    // Server and Client
    try expect_contains(output, "pub const Server = struct");
    try expect_contains(output, "pub const Client = struct");
}

test "generate_file: all streaming modes" {
    var methods = [_]ast.Method{
        .{ .name = "Unary", .input_type = "Req", .output_type = "Resp", .client_streaming = false, .server_streaming = false, .options = &.{}, .location = loc },
        .{ .name = "ServerStream", .input_type = "Req", .output_type = "Resp", .client_streaming = false, .server_streaming = true, .options = &.{}, .location = loc },
        .{ .name = "ClientStream", .input_type = "Req", .output_type = "Resp", .client_streaming = true, .server_streaming = false, .options = &.{}, .location = loc },
        .{ .name = "BidiStream", .input_type = "Req", .output_type = "Resp", .client_streaming = true, .server_streaming = true, .options = &.{}, .location = loc },
    };
    var file_services = [_]ast.Service{.{
        .name = "TestService",
        .methods = &methods,
        .options = &.{},
        .location = loc,
    }};

    var file = make_file(.proto3);
    file.services = &file_services;

    const output = try generate_file(testing.allocator, file, "test.proto");
    defer testing.allocator.free(output);

    // Server VTable
    try expect_contains(output, "unary: *const fn (*anyopaque, *rpc.Context, Req) rpc.RpcError!Resp,");
    try expect_contains(output, "server_stream: *const fn (*anyopaque, *rpc.Context, Req, rpc.SendStream(Resp)) rpc.RpcError!void,");
    try expect_contains(output, "client_stream: *const fn (*anyopaque, *rpc.Context, rpc.RecvStream(Req)) rpc.RpcError!Resp,");
    try expect_contains(output, "bidi_stream: *const fn (*anyopaque, *rpc.Context, rpc.RecvStream(Req), rpc.SendStream(Resp)) rpc.RpcError!void,");

    // Client
    try expect_contains(output, "pub fn unary(self: Client, ctx: *rpc.Context, req: Req) rpc.RpcError!Resp");
    try expect_contains(output, "pub fn server_stream(self: Client, ctx: *rpc.Context, req: Req) rpc.RpcError!rpc.RecvStream(Resp)");
    try expect_contains(output, "pub fn client_stream(self: Client, ctx: *rpc.Context) rpc.RpcError!rpc.ClientStreamCall(Req, Resp)");
    try expect_contains(output, "pub fn bidi_stream(self: Client, ctx: *rpc.Context) rpc.RpcError!rpc.BidiStreamCall(Req, Resp)");
}

test "generate_file: service with package path" {
    var methods = [_]ast.Method{.{
        .name = "DoThing",
        .input_type = "Req",
        .output_type = "Resp",
        .client_streaming = false,
        .server_streaming = false,
        .options = &.{},
        .location = loc,
    }};
    var file_services = [_]ast.Service{.{
        .name = "Svc",
        .methods = &methods,
        .options = &.{},
        .location = loc,
    }};

    var file = make_file(.proto3);
    file.package = "pkg";
    file.services = &file_services;

    const output = try generate_file(testing.allocator, file, "test.proto");
    defer testing.allocator.free(output);

    try expect_contains(output, ".name = \"pkg.Svc\"");
    try expect_contains(output, ".full_path = \"/pkg.Svc/DoThing\"");
}

test "generate_file: service without package" {
    var methods = [_]ast.Method{.{
        .name = "DoThing",
        .input_type = "Req",
        .output_type = "Resp",
        .client_streaming = false,
        .server_streaming = false,
        .options = &.{},
        .location = loc,
    }};
    var file_services = [_]ast.Service{.{
        .name = "Svc",
        .methods = &methods,
        .options = &.{},
        .location = loc,
    }};

    var file = make_file(.proto3);
    file.services = &file_services;

    const output = try generate_file(testing.allocator, file, "test.proto");
    defer testing.allocator.free(output);

    try expect_contains(output, ".name = \"Svc\"");
    try expect_contains(output, ".full_path = \"/Svc/DoThing\"");
}

test "generate_file: multiple services" {
    var methods1 = [_]ast.Method{.{
        .name = "Do",
        .input_type = "A",
        .output_type = "B",
        .client_streaming = false,
        .server_streaming = false,
        .options = &.{},
        .location = loc,
    }};
    var methods2 = [_]ast.Method{.{
        .name = "Run",
        .input_type = "C",
        .output_type = "D",
        .client_streaming = false,
        .server_streaming = false,
        .options = &.{},
        .location = loc,
    }};
    var file_services = [_]ast.Service{
        .{ .name = "Svc1", .methods = &methods1, .options = &.{}, .location = loc },
        .{ .name = "Svc2", .methods = &methods2, .options = &.{}, .location = loc },
    };

    var file = make_file(.proto3);
    file.services = &file_services;

    const output = try generate_file(testing.allocator, file, "test.proto");
    defer testing.allocator.free(output);

    try expect_contains(output, "pub const Svc1 = struct");
    try expect_contains(output, "pub const Svc2 = struct");
}

test "generate_file: no rpc import without services" {
    const file = make_file(.proto3);

    const output = try generate_file(testing.allocator, file, "test.proto");
    defer testing.allocator.free(output);

    // Should NOT contain rpc import when there are no services
    if (std.mem.indexOf(u8, output, "const rpc = protobuf.rpc;") != null) {
        return error.TestExpectedEqual;
    }
}

test "generate_file: json import when messages present" {
    var msg_fields = [_]ast.Field{
        make_field("name", 1, .implicit, .{ .scalar = .string }),
    };
    var file_msgs = [_]ast.Message{blk: {
        var m = make_msg("Msg");
        m.fields = &msg_fields;
        break :blk m;
    }};

    var file = make_file(.proto3);
    file.messages = &file_msgs;

    const output = try generate_file(testing.allocator, file, "test.proto");
    defer testing.allocator.free(output);

    try expect_contains(output, "const json = protobuf.json;");
    try expect_contains(output, "pub fn to_json(");
}

test "generate_file: no json import without messages" {
    const file = make_file(.proto3);

    const output = try generate_file(testing.allocator, file, "test.proto");
    defer testing.allocator.free(output);

    if (std.mem.indexOf(u8, output, "const json = protobuf.json;") != null) {
        return error.TestExpectedEqual;
    }
}

// ── Descriptor Tests ──────────────────────────────────────────────────

test "generate_file: file descriptor with package" {
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
    file.package = "mypackage";
    file.enums = &file_enums;
    file.messages = &file_msgs;

    const output = try generate_file(testing.allocator, file, "test.proto");
    defer testing.allocator.free(output);

    // File descriptor
    try expect_contains(output, "pub const _file_descriptor = protobuf.descriptor.FileDescriptor{");
    try expect_contains(output, ".name = \"test.proto\",");
    try expect_contains(output, ".package = \"mypackage\",");
    try expect_contains(output, ".syntax = .proto3,");
    try expect_contains(output, "Person.descriptor,");
    try expect_contains(output, "Status.descriptor,");

    // Enum descriptor with full_name including package
    try expect_contains(output, ".full_name = \"mypackage.Status\",");

    // Message descriptor with full_name including package
    try expect_contains(output, ".full_name = \"mypackage.Person\",");
}

test "generate_file: file descriptor without package" {
    var msg_fields = [_]ast.Field{
        make_field("x", 1, .implicit, .{ .scalar = .int32 }),
    };
    var file_msgs = [_]ast.Message{blk: {
        var m = make_msg("Point");
        m.fields = &msg_fields;
        break :blk m;
    }};

    var file = make_file(.proto3);
    file.messages = &file_msgs;

    const output = try generate_file(testing.allocator, file, "point.proto");
    defer testing.allocator.free(output);

    try expect_contains(output, ".name = \"point.proto\",");
    try expect_contains(output, ".package = null,");
    try expect_contains(output, ".full_name = \"Point\",");
}

test "generate_file: no file descriptor when no messages or enums" {
    const file = make_file(.proto3);

    const output = try generate_file(testing.allocator, file, "empty.proto");
    defer testing.allocator.free(output);

    if (std.mem.indexOf(u8, output, "_file_descriptor") != null) {
        return error.TestExpectedEqual;
    }
}

test "generate_file: message descriptor with nested types" {
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
    file.package = "pkg";
    file.messages = &file_msgs;

    const output = try generate_file(testing.allocator, file, "test.proto");
    defer testing.allocator.free(output);

    // Nested messages and enums referenced in descriptor
    try expect_contains(output, ".nested_messages = &.{");
    try expect_contains(output, "Inner.descriptor,");
    try expect_contains(output, ".nested_enums = &.{");
    try expect_contains(output, "Kind.descriptor,");
    // Full names include parent
    try expect_contains(output, ".full_name = \"pkg.Outer.Inner\",");
    try expect_contains(output, ".full_name = \"pkg.Outer.Kind\",");
}

test "generate_file: message descriptor with map and oneof" {
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

    const output = try generate_file(testing.allocator, file, "test.proto");
    defer testing.allocator.free(output);

    // Map descriptor
    try expect_contains(output, ".maps = &.{");
    try expect_contains(output, ".name = \"labels\", .number = 3");
    try expect_contains(output, ".key_type = .string, .value_type = .string");

    // Oneof descriptor
    try expect_contains(output, ".oneofs = &.{");
    try expect_contains(output, ".name = \"payload\"");
    // Oneof fields have oneof_index
    try expect_contains(output, ".name = \"text\", .number = 4");
    try expect_contains(output, ".oneof_index = 0");
    try expect_contains(output, ".name = \"count\", .number = 5");
}

test "generate_file: field descriptor with enum and message refs" {
    var enum_values = [_]ast.EnumValue{
        .{ .name = "A", .number = 0, .options = &.{}, .location = loc },
    };
    var nested_enums = [_]ast.Enum{.{
        .name = "Status",
        .values = &enum_values,
        .options = &.{},
        .allow_alias = false,
        .reserved_ranges = &.{},
        .reserved_names = &.{},
        .location = loc,
    }};
    var nested_msgs_inner = [_]ast.Message{blk: {
        break :blk make_msg("SubMsg");
    }};
    var msg_fields = [_]ast.Field{
        make_field("status", 1, .implicit, .{ .enum_ref = "Status" }),
        make_field("sub", 2, .optional, .{ .named = "SubMsg" }),
    };
    var file_msgs = [_]ast.Message{blk: {
        var m = make_msg("MyMsg");
        m.fields = &msg_fields;
        m.nested_enums = &nested_enums;
        m.nested_messages = &nested_msgs_inner;
        break :blk m;
    }};

    var file = make_file(.proto3);
    file.messages = &file_msgs;

    const output = try generate_file(testing.allocator, file, "test.proto");
    defer testing.allocator.free(output);

    // Enum field
    try expect_contains(output, ".field_type = .enum_type, .label = .implicit, .type_name = \"Status\"");
    // Message field
    try expect_contains(output, ".field_type = .message, .label = .optional, .type_name = \"SubMsg\"");
}
