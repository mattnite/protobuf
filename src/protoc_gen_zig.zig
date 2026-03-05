const plugin = @import("plugin.zig");

/// Entry point for the protoc plugin executable.
pub fn main() !void {
    try plugin.run();
}
