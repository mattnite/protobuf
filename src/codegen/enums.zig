const std = @import("std");
const testing = std.testing;
const ast = @import("../proto/ast.zig");
const Emitter = @import("emitter.zig").Emitter;

pub fn emit_enum(e: *Emitter, en: ast.Enum, syntax: ast.Syntax, full_name: []const u8) !void {
    try e.print("pub const {s} = enum(i32)", .{en.name});
    try e.open_brace();

    // Track which numbers we've seen to detect aliases
    var seen_numbers = std.AutoArrayHashMap(i32, []const u8).init(e.allocator);
    defer seen_numbers.deinit();

    // First pass: emit primary values (first occurrence of each number)
    for (en.values) |val| {
        const gop = try seen_numbers.getOrPut(val.number);
        if (!gop.found_existing) {
            gop.value_ptr.* = val.name;
            try e.print("{s} = {d},\n", .{ val.name, val.number });
        }
    }

    // Proto3: add non-exhaustive sentinel
    if (syntax == .proto3) {
        try e.print("_,\n", .{});
    }

    // Second pass: emit aliases as pub const
    for (en.values) |val| {
        const primary = seen_numbers.get(val.number).?;
        if (!std.mem.eql(u8, primary, val.name)) {
            try e.print("pub const {s}: {s} = .{s};\n", .{ val.name, en.name, primary });
        }
    }

    // Descriptor
    try emit_enum_descriptor(e, en, full_name);

    try e.close_brace();
}

fn emit_enum_descriptor(e: *Emitter, en: ast.Enum, full_name: []const u8) !void {
    try e.print("pub const descriptor = protobuf.descriptor.EnumDescriptor{{\n", .{});
    e.indent_level += 1;
    try e.print(".name = \"{s}\",\n", .{en.name});
    try e.print(".full_name = \"{s}\",\n", .{full_name});
    try e.print(".values = &.{{\n", .{});
    e.indent_level += 1;
    for (en.values) |val| {
        try e.print(".{{ .name = \"{s}\", .number = {d} }},\n", .{ val.name, val.number });
    }
    e.indent_level -= 1;
    try e.print("}},\n", .{});
    e.indent_level -= 1;
    try e.print("}};\n", .{});
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

const loc = ast.SourceLocation{ .file = "", .line = 0, .column = 0 };

fn make_enum(name: []const u8, values: []ast.EnumValue, allow_alias: bool) ast.Enum {
    return .{
        .name = name,
        .values = values,
        .options = &.{},
        .allow_alias = allow_alias,
        .reserved_ranges = &.{},
        .reserved_names = &.{},
        .location = loc,
    };
}

fn ev(name: []const u8, number: i32) ast.EnumValue {
    return .{ .name = name, .number = number, .options = &.{}, .location = loc };
}

fn expect_contains(output: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, output, expected) == null) {
        std.debug.print("\n=== EXPECTED (not found) ===\n{s}\n=== IN OUTPUT ===\n{s}\n=== END ===\n", .{ expected, output });
        return error.TestExpectedEqual;
    }
}

test "emit_enum: simple proto3 enum is non-exhaustive" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var values = [_]ast.EnumValue{ ev("UNKNOWN", 0), ev("ACTIVE", 1), ev("INACTIVE", 2) };
    try emit_enum(&e, make_enum("Status", &values, false), .proto3, "pkg.Status");
    const output = e.get_output();
    try expect_contains(output, "pub const Status = enum(i32) {");
    try expect_contains(output, "    UNKNOWN = 0,");
    try expect_contains(output, "    ACTIVE = 1,");
    try expect_contains(output, "    INACTIVE = 2,");
    try expect_contains(output, "    _,");
    try expect_contains(output, "pub const descriptor = protobuf.descriptor.EnumDescriptor{");
    try expect_contains(output, ".name = \"Status\",");
    try expect_contains(output, ".full_name = \"pkg.Status\",");
    try expect_contains(output, ".values = &.{");
    try expect_contains(output, ".{ .name = \"UNKNOWN\", .number = 0 },");
    try expect_contains(output, ".{ .name = \"ACTIVE\", .number = 1 },");
    try expect_contains(output, ".{ .name = \"INACTIVE\", .number = 2 },");
}

test "emit_enum: simple proto2 enum is exhaustive" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var values = [_]ast.EnumValue{ ev("RED", 0), ev("GREEN", 1), ev("BLUE", 2) };
    try emit_enum(&e, make_enum("Color", &values, false), .proto2, "Color");
    const output = e.get_output();
    try expect_contains(output, "pub const Color = enum(i32) {");
    try expect_contains(output, "    RED = 0,");
    // No non-exhaustive sentinel for proto2
    if (std.mem.indexOf(u8, output, "    _,") != null) return error.TestExpectedEqual;
    try expect_contains(output, "pub const descriptor = protobuf.descriptor.EnumDescriptor{");
    try expect_contains(output, ".full_name = \"Color\",");
}

test "emit_enum: enum with aliases" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var values = [_]ast.EnumValue{ ev("BAR", 0), ev("BAZ", 0), ev("QUX", 1) };
    try emit_enum(&e, make_enum("Foo", &values, true), .proto3, "Foo");
    const output = e.get_output();
    try expect_contains(output, "pub const Foo = enum(i32) {");
    try expect_contains(output, "    BAR = 0,");
    try expect_contains(output, "    QUX = 1,");
    try expect_contains(output, "    pub const BAZ: Foo = .BAR;");
    // Descriptor includes aliases
    try expect_contains(output, ".{ .name = \"BAR\", .number = 0 },");
    try expect_contains(output, ".{ .name = \"BAZ\", .number = 0 },");
    try expect_contains(output, ".{ .name = \"QUX\", .number = 1 },");
}

test "emit_enum: negative values" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var values = [_]ast.EnumValue{ ev("NEG", -1), ev("ZERO", 0), ev("POS", 1) };
    try emit_enum(&e, make_enum("Signed", &values, false), .proto2, "Signed");
    const output = e.get_output();
    try expect_contains(output, "pub const Signed = enum(i32) {");
    try expect_contains(output, "    NEG = -1,");
    try expect_contains(output, "    ZERO = 0,");
    try expect_contains(output, "    POS = 1,");
    try expect_contains(output, ".{ .name = \"NEG\", .number = -1 },");
}
