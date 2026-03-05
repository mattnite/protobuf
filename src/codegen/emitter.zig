const std = @import("std");
const testing = std.testing;

/// Small helper for indentation-aware code emission into an in-memory buffer.
pub const Emitter = struct {
    output: std.ArrayList(u8),
    indent_level: u32,
    allocator: std.mem.Allocator,

    /// Create an emitter backed by `allocator`.
    pub fn init(allocator: std.mem.Allocator) Emitter {
        return .{
            .output = .empty,
            .indent_level = 0,
            .allocator = allocator,
        };
    }

    /// Free the backing output buffer.
    pub fn deinit(self: *Emitter) void {
        self.output.deinit(self.allocator);
    }

    /// Return the currently-emitted output slice.
    pub fn get_output(self: *const Emitter) []const u8 {
        return self.output.items;
    }

    /// Print a formatted line at the current indentation.
    pub fn print(self: *Emitter, comptime fmt: []const u8, args: anytype) !void {
        try self.indent();
        try self.output.writer(self.allocator).print(fmt, args);
    }

    /// Print formatted output without automatic indentation.
    pub fn print_raw(self: *Emitter, comptime fmt: []const u8, args: anytype) !void {
        try self.output.writer(self.allocator).print(fmt, args);
    }

    /// Emit an opening brace and increase indentation.
    pub fn open_brace(self: *Emitter) !void {
        try self.print_raw(" {{\n", .{});
        self.indent_level += 1;
    }

    /// Emit a closing brace with trailing semicolon and decrease indentation.
    pub fn close_brace(self: *Emitter) !void {
        self.indent_level -= 1;
        try self.indent();
        try self.print_raw("}};\n", .{});
    }

    /// Emit a closing brace without semicolon and decrease indentation.
    pub fn close_brace_nosemi(self: *Emitter) !void {
        self.indent_level -= 1;
        try self.indent();
        try self.print_raw("}}\n", .{});
    }

    /// Close a brace with trailing comma — used for switch arm blocks
    pub fn close_brace_comma(self: *Emitter) !void {
        self.indent_level -= 1;
        try self.indent();
        try self.print_raw("}},\n", .{});
    }

    /// Emit a blank line.
    pub fn blank_line(self: *Emitter) !void {
        try self.print_raw("\n", .{});
    }

    /// Write indentation spaces for the current indentation level.
    pub fn indent(self: *Emitter) !void {
        for (0..self.indent_level) |_| {
            try self.print_raw("    ", .{});
        }
    }
};

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

test "Emitter: basic print" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try e.print("hello {s}\n", .{"world"});
    try testing.expectEqualStrings("hello world\n", e.get_output());
}

test "Emitter: print_raw no indent" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    e.indent_level = 2;
    try e.print_raw("no indent\n", .{});
    try testing.expectEqualStrings("no indent\n", e.get_output());
}

test "Emitter: indentation levels" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try e.print("level0\n", .{});
    e.indent_level = 1;
    try e.print("level1\n", .{});
    e.indent_level = 2;
    try e.print("level2\n", .{});
    try testing.expectEqualStrings(
        \\level0
        \\    level1
        \\        level2
        \\
    , e.get_output());
}

test "Emitter: open/close brace nesting" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try e.print("pub const Foo = struct", .{});
    try e.open_brace();
    try e.print("x: i32,\n", .{});
    try e.close_brace();
    try testing.expectEqualStrings(
        \\pub const Foo = struct {
        \\    x: i32,
        \\};
        \\
    , e.get_output());
}

test "Emitter: close_brace_nosemi for function bodies" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try e.print("pub fn foo() void", .{});
    try e.open_brace();
    try e.print("return;\n", .{});
    try e.close_brace_nosemi();
    try testing.expectEqualStrings(
        \\pub fn foo() void {
        \\    return;
        \\}
        \\
    , e.get_output());
}

test "Emitter: blank_line" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try e.print("a\n", .{});
    try e.blank_line();
    try e.print("b\n", .{});
    try testing.expectEqualStrings("a\n\nb\n", e.get_output());
}

test "Emitter: nested braces" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try e.print("outer", .{});
    try e.open_brace();
    try e.print("inner", .{});
    try e.open_brace();
    try e.print("deep: bool,\n", .{});
    try e.close_brace();
    try e.close_brace();
    try testing.expectEqualStrings(
        \\outer {
        \\    inner {
        \\        deep: bool,
        \\    };
        \\};
        \\
    , e.get_output());
}
