const std = @import("std");
const fuzz = @import("fuzz_harness");

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var r = std.fs.File.stdin().reader(&buf);
    const input = try r.interface.allocRemaining(fuzz.gpa.allocator(), .limited(1024 * 1024));
    defer fuzz.gpa.allocator().free(input);

    fuzz.arena = .init(fuzz.gpa.allocator());
    fuzz.runFuzz(input);
}
