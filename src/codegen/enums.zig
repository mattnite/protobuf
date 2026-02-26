const std = @import("std");
const testing = std.testing;
const ast = @import("../proto/ast.zig");
const Emitter = @import("emitter.zig").Emitter;

pub fn emit_enum(e: *Emitter, en: ast.Enum, syntax: ast.Syntax) !void {
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

    try e.close_brace();
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

test "emit_enum: simple proto3 enum is non-exhaustive" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var values = [_]ast.EnumValue{ ev("UNKNOWN", 0), ev("ACTIVE", 1), ev("INACTIVE", 2) };
    try emit_enum(&e, make_enum("Status", &values, false), .proto3);
    try testing.expectEqualStrings(
        \\pub const Status = enum(i32) {
        \\    UNKNOWN = 0,
        \\    ACTIVE = 1,
        \\    INACTIVE = 2,
        \\    _,
        \\};
        \\
    , e.get_output());
}

test "emit_enum: simple proto2 enum is exhaustive" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var values = [_]ast.EnumValue{ ev("RED", 0), ev("GREEN", 1), ev("BLUE", 2) };
    try emit_enum(&e, make_enum("Color", &values, false), .proto2);
    try testing.expectEqualStrings(
        \\pub const Color = enum(i32) {
        \\    RED = 0,
        \\    GREEN = 1,
        \\    BLUE = 2,
        \\};
        \\
    , e.get_output());
}

test "emit_enum: enum with aliases" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var values = [_]ast.EnumValue{ ev("BAR", 0), ev("BAZ", 0), ev("QUX", 1) };
    try emit_enum(&e, make_enum("Foo", &values, true), .proto3);
    try testing.expectEqualStrings(
        \\pub const Foo = enum(i32) {
        \\    BAR = 0,
        \\    QUX = 1,
        \\    _,
        \\    pub const BAZ: Foo = .BAR;
        \\};
        \\
    , e.get_output());
}

test "emit_enum: negative values" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    var values = [_]ast.EnumValue{ ev("NEG", -1), ev("ZERO", 0), ev("POS", 1) };
    try emit_enum(&e, make_enum("Signed", &values, false), .proto2);
    try testing.expectEqualStrings(
        \\pub const Signed = enum(i32) {
        \\    NEG = -1,
        \\    ZERO = 0,
        \\    POS = 1,
        \\};
        \\
    , e.get_output());
}
