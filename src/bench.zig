const std = @import("std");
const encoding = @import("encoding.zig");
const message = @import("message.zig");

const BenchResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    bytes_per_iter: usize,

    fn throughput_mb_s(self: BenchResult) f64 {
        if (self.total_ns == 0) return 0;
        const total_bytes: f64 = @floatFromInt(self.bytes_per_iter * self.iterations);
        const secs: f64 = @as(f64, @floatFromInt(self.total_ns)) / 1_000_000_000.0;
        return total_bytes / secs / (1024.0 * 1024.0);
    }

    fn ns_per_op(self: BenchResult) f64 {
        if (self.iterations == 0) return 0;
        return @as(f64, @floatFromInt(self.total_ns)) / @as(f64, @floatFromInt(self.iterations));
    }
};

/// Build a test message with N varint fields into buf, return the written slice.
fn build_varint_message(buf: []u8, num_fields: usize) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    const mw = message.MessageWriter.init(&writer);
    for (0..num_fields) |i| {
        const field_num: u29 = @intCast(i + 1);
        const value: u64 = @intCast(i * 127 + 42);
        mw.write_varint_field(field_num, value) catch unreachable;
    }
    return writer.buffered();
}

/// Build a test message with N fixed64 fields into buf.
fn build_fixed64_message(buf: []u8, num_fields: usize) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    const mw = message.MessageWriter.init(&writer);
    for (0..num_fields) |i| {
        const field_num: u29 = @intCast(i + 1);
        mw.write_i64_field(field_num, @intCast(i * 1000)) catch unreachable;
    }
    return writer.buffered();
}

/// Build a packed varint field: tag + length + N varints.
fn build_packed_varint_message(buf: []u8, num_elements: usize) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    const mw = message.MessageWriter.init(&writer);

    // Calculate packed data size
    var packed_size: usize = 0;
    for (0..num_elements) |i| {
        packed_size += encoding.varint_size(@as(u64, @intCast(i * 127 + 42)));
    }
    mw.write_len_prefix(1, packed_size) catch unreachable;
    for (0..num_elements) |i| {
        encoding.encode_varint(&writer, @as(u64, @intCast(i * 127 + 42))) catch unreachable;
    }
    return writer.buffered();
}

/// Build an unpacked varint message: N separate tagged varint fields (same field number).
fn build_unpacked_varint_message(buf: []u8, num_elements: usize) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    const mw = message.MessageWriter.init(&writer);
    for (0..num_elements) |i| {
        mw.write_varint_field(1, @as(u64, @intCast(i * 127 + 42))) catch unreachable;
    }
    return writer.buffered();
}

fn bench_encode_varints(comptime num_fields: usize, iters: u64) BenchResult {
    var timer = std.time.Timer.start() catch return .{ .name = "encode_varints", .iterations = 0, .total_ns = 0, .bytes_per_iter = 0 };
    var discard_buf: [65536]u8 = undefined;
    var encoded_size: usize = 0;

    for (0..iters) |_| {
        var discard = std.Io.Writer.Discarding.init(&discard_buf);
        const mw = message.MessageWriter.init(&discard.writer);
        for (0..num_fields) |i| {
            const field_num: u29 = @intCast(i + 1);
            const value: u64 = @intCast(i * 127 + 42);
            mw.write_varint_field(field_num, value) catch unreachable;
        }
        encoded_size = @intCast(discard.fullCount());
    }

    const elapsed = timer.read();
    return .{
        .name = std.fmt.comptimePrint("encode {d} varint fields", .{num_fields}),
        .iterations = iters,
        .total_ns = elapsed,
        .bytes_per_iter = encoded_size,
    };
}

fn bench_decode_varints(comptime num_fields: usize, iters: u64) BenchResult {
    var msg_buf: [65536]u8 = undefined;
    const msg_data = build_varint_message(&msg_buf, num_fields);

    var timer = std.time.Timer.start() catch return .{ .name = "decode_varints", .iterations = 0, .total_ns = 0, .bytes_per_iter = 0 };

    for (0..iters) |_| {
        var iter = message.iterate_fields(msg_data);
        while (iter.next() catch unreachable) |_| {}
    }

    const elapsed = timer.read();
    return .{
        .name = std.fmt.comptimePrint("decode {d} varint fields", .{num_fields}),
        .iterations = iters,
        .total_ns = elapsed,
        .bytes_per_iter = msg_data.len,
    };
}

fn bench_encode_fixed64(comptime num_fields: usize, iters: u64) BenchResult {
    var timer = std.time.Timer.start() catch return .{ .name = "encode_fixed64", .iterations = 0, .total_ns = 0, .bytes_per_iter = 0 };
    var discard_buf: [65536]u8 = undefined;
    var encoded_size: usize = 0;

    for (0..iters) |_| {
        var discard = std.Io.Writer.Discarding.init(&discard_buf);
        const mw = message.MessageWriter.init(&discard.writer);
        for (0..num_fields) |i| {
            const field_num: u29 = @intCast(i + 1);
            mw.write_i64_field(field_num, @intCast(i * 1000)) catch unreachable;
        }
        encoded_size = @intCast(discard.fullCount());
    }

    const elapsed = timer.read();
    return .{
        .name = std.fmt.comptimePrint("encode {d} fixed64 fields", .{num_fields}),
        .iterations = iters,
        .total_ns = elapsed,
        .bytes_per_iter = encoded_size,
    };
}

fn bench_decode_fixed64(comptime num_fields: usize, iters: u64) BenchResult {
    var msg_buf: [65536]u8 = undefined;
    const msg_data = build_fixed64_message(&msg_buf, num_fields);

    var timer = std.time.Timer.start() catch return .{ .name = "decode_fixed64", .iterations = 0, .total_ns = 0, .bytes_per_iter = 0 };

    for (0..iters) |_| {
        var iter = message.iterate_fields(msg_data);
        while (iter.next() catch unreachable) |_| {}
    }

    const elapsed = timer.read();
    return .{
        .name = std.fmt.comptimePrint("decode {d} fixed64 fields", .{num_fields}),
        .iterations = iters,
        .total_ns = elapsed,
        .bytes_per_iter = msg_data.len,
    };
}

fn bench_packed_vs_unpacked(comptime num_elements: usize) struct { packed_size: usize, unpacked_size: usize } {
    var packed_buf: [65536]u8 = undefined;
    var unpacked_buf: [65536]u8 = undefined;
    const packed_data = build_packed_varint_message(&packed_buf, num_elements);
    const unpacked_data = build_unpacked_varint_message(&unpacked_buf, num_elements);
    return .{ .packed_size = packed_data.len, .unpacked_size = unpacked_data.len };
}

fn print_result(result: BenchResult) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.print("  {s:<40} {d:>10.0} ns/op  {d:>8.1} MB/s  ({d} bytes)\n", .{
        result.name,
        result.ns_per_op(),
        result.throughput_mb_s(),
        result.bytes_per_iter,
    }) catch {};
}

pub fn main() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.writeAll("\n=== Protobuf Zig Benchmarks ===\n\n");

    // Warmup
    _ = bench_encode_varints(10, 1000);
    _ = bench_decode_varints(10, 1000);

    const iters: u64 = 100_000;

    try stdout.writeAll("Encode:\n");
    print_result(bench_encode_varints(10, iters));
    print_result(bench_encode_varints(100, iters));
    print_result(bench_encode_fixed64(10, iters));
    print_result(bench_encode_fixed64(100, iters));

    try stdout.writeAll("\nDecode:\n");
    print_result(bench_decode_varints(10, iters));
    print_result(bench_decode_varints(100, iters));
    print_result(bench_decode_fixed64(10, iters));
    print_result(bench_decode_fixed64(100, iters));

    try stdout.writeAll("\nPacked vs Unpacked wire size (repeated varint field):\n");
    inline for ([_]usize{ 10, 100, 1000 }) |n| {
        const sizes = bench_packed_vs_unpacked(n);
        const savings: f64 = 1.0 - @as(f64, @floatFromInt(sizes.packed_size)) / @as(f64, @floatFromInt(sizes.unpacked_size));
        try stdout.print("  {d:>5} elements: packed={d:>6} bytes, unpacked={d:>6} bytes ({d:.1}% smaller)\n", .{
            n,
            sizes.packed_size,
            sizes.unpacked_size,
            savings * 100.0,
        });
    }

    try stdout.writeAll("\n");
}
