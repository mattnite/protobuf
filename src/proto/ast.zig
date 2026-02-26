const std = @import("std");
const testing = std.testing;

// ── Source Location ───────────────────────────────────────────────────

pub const SourceLocation = struct {
    file: []const u8,
    line: u32,
    column: u32,
};

// ── Top-Level Types ───────────────────────────────────────────────────

pub const File = struct {
    syntax: Syntax,
    package: ?[]const u8,
    imports: []Import,
    options: []Option,
    messages: []Message,
    enums: []Enum,
    services: []Service,
    extensions: []Extend,
};

pub const Syntax = enum { proto2, proto3 };

pub const Import = struct {
    path: []const u8,
    kind: enum { default, public, weak },
    location: SourceLocation,
};

// ── Message ───────────────────────────────────────────────────────────

pub const Message = struct {
    name: []const u8,
    fields: []Field,
    oneofs: []Oneof,
    nested_messages: []Message,
    nested_enums: []Enum,
    maps: []MapField,
    reserved_ranges: []ReservedRange,
    reserved_names: [][]const u8,
    extension_ranges: []ExtensionRange,
    extensions: []Extend,
    groups: []Group,
    options: []Option,
    location: SourceLocation,
};

pub const Field = struct {
    name: []const u8,
    number: i32,
    label: FieldLabel,
    type_name: TypeRef,
    options: []FieldOption,
    location: SourceLocation,
};

pub const FieldLabel = enum {
    required,
    optional,
    repeated,
    implicit,
};

pub const TypeRef = union(enum) {
    /// Built-in scalar type.
    scalar: ScalarType,
    /// Reference to a message or enum type (not yet resolved).
    named: []const u8,
};

pub const ScalarType = enum {
    double,
    float,
    int32,
    int64,
    uint32,
    uint64,
    sint32,
    sint64,
    fixed32,
    fixed64,
    sfixed32,
    sfixed64,
    bool,
    string,
    bytes,

    const map = std.StaticStringMap(ScalarType).initComptime(.{
        .{ "double", .double },
        .{ "float", .float },
        .{ "int32", .int32 },
        .{ "int64", .int64 },
        .{ "uint32", .uint32 },
        .{ "uint64", .uint64 },
        .{ "sint32", .sint32 },
        .{ "sint64", .sint64 },
        .{ "fixed32", .fixed32 },
        .{ "fixed64", .fixed64 },
        .{ "sfixed32", .sfixed32 },
        .{ "sfixed64", .sfixed64 },
        .{ "bool", .bool },
        .{ "string", .string },
        .{ "bytes", .bytes },
    });

    pub fn from_string(s: []const u8) ?ScalarType {
        return map.get(s);
    }
};

// ── Oneof ─────────────────────────────────────────────────────────────

pub const Oneof = struct {
    name: []const u8,
    fields: []Field,
    options: []Option,
    location: SourceLocation,
};

// ── Map ───────────────────────────────────────────────────────────────

pub const MapField = struct {
    name: []const u8,
    number: i32,
    key_type: ScalarType,
    value_type: TypeRef,
    options: []FieldOption,
    location: SourceLocation,
};

// ── Enum ──────────────────────────────────────────────────────────────

pub const Enum = struct {
    name: []const u8,
    values: []EnumValue,
    options: []Option,
    allow_alias: bool,
    reserved_ranges: []ReservedRange,
    reserved_names: [][]const u8,
    location: SourceLocation,
};

pub const EnumValue = struct {
    name: []const u8,
    number: i32,
    options: []FieldOption,
    location: SourceLocation,
};

// ── Service ───────────────────────────────────────────────────────────

pub const Service = struct {
    name: []const u8,
    methods: []Method,
    options: []Option,
    location: SourceLocation,
};

pub const Method = struct {
    name: []const u8,
    input_type: []const u8,
    output_type: []const u8,
    client_streaming: bool,
    server_streaming: bool,
    options: []Option,
    location: SourceLocation,
};

// ── Options ───────────────────────────────────────────────────────────

pub const Option = struct {
    name: OptionName,
    value: Constant,
    location: SourceLocation,
};

pub const OptionName = struct {
    parts: []Part,

    pub const Part = struct {
        name: []const u8,
        is_extension: bool,
    };
};

pub const FieldOption = struct {
    name: OptionName,
    value: Constant,
};

pub const Constant = union(enum) {
    identifier: []const u8,
    integer: i64,
    unsigned_integer: u64,
    float_value: f64,
    string_value: []const u8,
    bool_value: bool,
    aggregate: []const u8,
};

// ── Reserved / Extensions ─────────────────────────────────────────────

pub const ReservedRange = struct {
    start: i32,
    end: i32,
};

pub const ExtensionRange = struct {
    start: i32,
    end: i32,
    options: []FieldOption,
};

pub const Extend = struct {
    type_name: []const u8,
    fields: []Field,
    groups: []Group,
    location: SourceLocation,
};

pub const Group = struct {
    name: []const u8,
    number: i32,
    label: FieldLabel,
    fields: []Field,
    nested_messages: []Message,
    nested_enums: []Enum,
    location: SourceLocation,
};

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

test "ScalarType.from_string: all 15 scalar types" {
    const cases = .{
        .{ "double", ScalarType.double },
        .{ "float", ScalarType.float },
        .{ "int32", ScalarType.int32 },
        .{ "int64", ScalarType.int64 },
        .{ "uint32", ScalarType.uint32 },
        .{ "uint64", ScalarType.uint64 },
        .{ "sint32", ScalarType.sint32 },
        .{ "sint64", ScalarType.sint64 },
        .{ "fixed32", ScalarType.fixed32 },
        .{ "fixed64", ScalarType.fixed64 },
        .{ "sfixed32", ScalarType.sfixed32 },
        .{ "sfixed64", ScalarType.sfixed64 },
        .{ "bool", ScalarType.bool },
        .{ "string", ScalarType.string },
        .{ "bytes", ScalarType.bytes },
    };
    inline for (cases) |case| {
        try testing.expectEqual(@as(?ScalarType, case[1]), ScalarType.from_string(case[0]));
    }
}

test "ScalarType.from_string: unknown strings return null" {
    try testing.expectEqual(@as(?ScalarType, null), ScalarType.from_string("message"));
    try testing.expectEqual(@as(?ScalarType, null), ScalarType.from_string("enum"));
    try testing.expectEqual(@as(?ScalarType, null), ScalarType.from_string("foo"));
    try testing.expectEqual(@as(?ScalarType, null), ScalarType.from_string(""));
    try testing.expectEqual(@as(?ScalarType, null), ScalarType.from_string("Int32"));
}

test "TypeRef: can construct scalar and named variants" {
    const scalar_ref: TypeRef = .{ .scalar = .int32 };
    try testing.expectEqual(ScalarType.int32, scalar_ref.scalar);

    const named_ref: TypeRef = .{ .named = "MyMessage" };
    try testing.expectEqualStrings("MyMessage", named_ref.named);
}

test "Constant: can construct all variants" {
    const c1: Constant = .{ .identifier = "FOO" };
    try testing.expectEqualStrings("FOO", c1.identifier);

    const c2: Constant = .{ .integer = -42 };
    try testing.expectEqual(@as(i64, -42), c2.integer);

    const c3: Constant = .{ .unsigned_integer = 100 };
    try testing.expectEqual(@as(u64, 100), c3.unsigned_integer);

    const c4: Constant = .{ .float_value = 3.14 };
    try testing.expectEqual(@as(f64, 3.14), c4.float_value);

    const c5: Constant = .{ .string_value = "hello" };
    try testing.expectEqualStrings("hello", c5.string_value);

    const c6: Constant = .{ .bool_value = true };
    try testing.expect(c6.bool_value);

    const c7: Constant = .{ .aggregate = "{ key: value }" };
    try testing.expectEqualStrings("{ key: value }", c7.aggregate);
}
