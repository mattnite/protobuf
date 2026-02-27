const plugin = @import("plugin.zig");

pub fn main() !void {
    try plugin.run();
}
