const std = @import("std");

/// Test case framing format:
/// [4-byte BE uint32: name length][name bytes][4-byte BE uint32: message length][message bytes]

pub const TestCase = struct {
    name: []const u8,
    data: []const u8,
};

pub fn write_test_case(writer: *std.Io.Writer, name: []const u8, data: []const u8) std.Io.Writer.Error!void {
    // Write name length (4-byte big-endian)
    try writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(name.len))));
    // Write name
    try writer.writeAll(name);
    // Write message length (4-byte big-endian)
    try writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(data.len))));
    // Write message data
    try writer.writeAll(data);
}

pub fn read_test_case(data: []const u8, pos: *usize) ?TestCase {
    if (pos.* + 4 > data.len) return null;

    // Read name length
    const name_len = std.mem.bigToNative(u32, @bitCast(data[pos.*..][0..4].*));
    pos.* += 4;

    if (pos.* + name_len > data.len) return null;
    const name = data[pos.*..][0..name_len];
    pos.* += name_len;

    if (pos.* + 4 > data.len) return null;
    // Read message length
    const msg_len = std.mem.bigToNative(u32, @bitCast(data[pos.*..][0..4].*));
    pos.* += 4;

    if (pos.* + msg_len > data.len) return null;
    const msg_data = data[pos.*..][0..msg_len];
    pos.* += msg_len;

    return .{ .name = name, .data = msg_data };
}

pub fn read_all_test_cases(allocator: std.mem.Allocator, data: []const u8) ![]TestCase {
    var cases: std.ArrayList(TestCase) = .empty;
    var pos: usize = 0;
    while (read_test_case(data, &pos)) |tc| {
        try cases.append(allocator, tc);
    }
    return try cases.toOwnedSlice(allocator);
}

// ── Tests ─────────────────────────────────────────────────────────────

test "framing round-trip: single test case" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write_test_case(&w, "hello", "world");

    var pos: usize = 0;
    const tc = read_test_case(w.buffered(), &pos).?;
    try std.testing.expectEqualStrings("hello", tc.name);
    try std.testing.expectEqualStrings("world", tc.data);
    try std.testing.expectEqual(pos, w.buffered().len);
}

test "framing round-trip: multiple test cases" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write_test_case(&w, "case1", "data1");
    try write_test_case(&w, "case2", "data2data2");
    try write_test_case(&w, "empty", "");

    const cases = try read_all_test_cases(std.testing.allocator, w.buffered());
    defer std.testing.allocator.free(cases);

    try std.testing.expectEqual(@as(usize, 3), cases.len);
    try std.testing.expectEqualStrings("case1", cases[0].name);
    try std.testing.expectEqualStrings("data1", cases[0].data);
    try std.testing.expectEqualStrings("case2", cases[1].name);
    try std.testing.expectEqualStrings("data2data2", cases[1].data);
    try std.testing.expectEqualStrings("empty", cases[2].name);
    try std.testing.expectEqualStrings("", cases[2].data);
}

test "framing: empty data returns null" {
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?TestCase, null), read_test_case("", &pos));
}
