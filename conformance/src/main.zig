const std = @import("std");
const proto = @import("proto");
const protobuf = @import("protobuf");

const ConformanceRequest = proto.conformance.ConformanceRequest;
const ConformanceResponse = proto.conformance.ConformanceResponse;
const WireFormat = proto.conformance.WireFormat;
const TestAllTypesProto3 = proto.test_messages_proto3.TestAllTypesProto3;
const TestAllTypesProto2 = proto.test_messages_proto2.TestAllTypesProto2;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    var tests_run: usize = 0;
    while (true) {
        // Read 4-byte LE length prefix
        var len_buf: [4]u8 = undefined;
        const bytes_read = stdin.readAll(&len_buf) catch |err| {
            std.debug.print("error reading from stdin: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        if (bytes_read == 0) break; // EOF → exit
        if (bytes_read != 4) {
            std.debug.print("unexpected EOF reading length prefix\n", .{});
            std.process.exit(1);
        }

        const msg_len = std.mem.readInt(u32, &len_buf, .little);

        // Read the request payload
        const request_bytes = allocator.alloc(u8, msg_len) catch {
            std.debug.print("OOM allocating request buffer\n", .{});
            std.process.exit(1);
        };
        defer allocator.free(request_bytes);

        const payload_read = stdin.readAll(request_bytes) catch |err| {
            std.debug.print("error reading request payload: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        if (payload_read != msg_len) {
            std.debug.print("unexpected EOF reading request payload\n", .{});
            std.process.exit(1);
        }

        // Decode the ConformanceRequest
        var request = ConformanceRequest.decode(allocator, request_bytes) catch |err| {
            std.debug.print("error decoding ConformanceRequest: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer request.deinit(allocator);

        // Process the request and get a response
        const response = do_test(allocator, &request);
        defer {
            var resp = response;
            resp.deinit(allocator);
        }

        // Encode the response
        const response_bytes = encode_message(ConformanceResponse, response, allocator) catch {
            std.debug.print("error encoding ConformanceResponse\n", .{});
            std.process.exit(1);
        };
        defer allocator.free(response_bytes);

        // Write 4-byte LE length prefix + response bytes
        var out_len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &out_len_buf, @intCast(response_bytes.len), .little);
        stdout.writeAll(&out_len_buf) catch |err| {
            std.debug.print("error writing to stdout: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        stdout.writeAll(response_bytes) catch |err| {
            std.debug.print("error writing to stdout: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };

        tests_run += 1;
    }

    std.debug.print("conformance_testee: completed {d} tests\n", .{tests_run});
}

fn do_test(allocator: std.mem.Allocator, request: *ConformanceRequest) ConformanceResponse {
    // Dispatch based on message_type
    if (std.mem.eql(u8, request.message_type, "protobuf_test_messages.proto3.TestAllTypesProto3")) {
        return do_test_typed(TestAllTypesProto3, allocator, request);
    } else if (std.mem.eql(u8, request.message_type, "protobuf_test_messages.proto2.TestAllTypesProto2")) {
        return do_test_typed(TestAllTypesProto2, allocator, request);
    } else {
        return skipped(allocator, "unsupported message type");
    }
}

fn do_test_typed(comptime T: type, allocator: std.mem.Allocator, request: *ConformanceRequest) ConformanceResponse {
    // Parse input from the payload oneof
    const payload = request.payload orelse return skipped(allocator, "no payload");
    var msg: T = switch (payload) {
        .protobuf_payload => |bytes| T.decode(allocator, bytes) catch |err| {
            return parse_error(allocator, @errorName(err));
        },
        .json_payload => |json_bytes| blk: {
            const prev_ignore = protobuf.json.ignore_unknown_enum_values;
            protobuf.json.ignore_unknown_enum_values = request.test_category == .JSON_IGNORE_UNKNOWN_PARSING_TEST;
            defer protobuf.json.ignore_unknown_enum_values = prev_ignore;
            break :blk T.from_json(allocator, json_bytes) catch |err| {
                return parse_error(allocator, @errorName(err));
            };
        },
        .text_payload => |text_bytes| T.from_text(allocator, text_bytes) catch |err| {
            return parse_error(allocator, @errorName(err));
        },
        .jspb_payload => return skipped(allocator, "JSPB not supported"),
    };
    defer msg.deinit(allocator);

    // Serialize to requested output format
    return switch (request.requested_output_format) {
        .PROTOBUF => blk: {
            const encoded = encode_message(T, msg, allocator) catch |err| {
                break :blk serialize_error(allocator, @errorName(err));
            };
            break :blk .{ .result = .{ .protobuf_payload = encoded } };
        },
        .JSON => blk: {
            const encoded = encode_json(T, msg, allocator) catch |err| {
                break :blk serialize_error(allocator, @errorName(err));
            };
            break :blk .{ .result = .{ .json_payload = encoded } };
        },
        .TEXT_FORMAT => blk: {
            const encoded = encode_text(T, msg, request.print_unknown_fields, allocator) catch |err| {
                break :blk serialize_error(allocator, @errorName(err));
            };
            break :blk .{ .result = .{ .text_payload = encoded } };
        },
        .JSPB => skipped(allocator, "JSPB not supported"),
        else => skipped(allocator, "unknown output format"),
    };
}

fn encode_message(comptime T: type, msg: T, allocator: std.mem.Allocator) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    try msg.encode(&alloc_writer.writer);
    return try alloc_writer.toOwnedSlice();
}

fn encode_json(comptime T: type, msg: T, allocator: std.mem.Allocator) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    try msg.to_json(&alloc_writer.writer);
    return try alloc_writer.toOwnedSlice();
}

fn encode_text(comptime T: type, msg: T, print_unknown_fields: bool, allocator: std.mem.Allocator) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    try msg.to_text(&alloc_writer.writer);
    if (print_unknown_fields and msg._unknown_fields.len > 0) {
        try protobuf.text_format.write_unknown_fields(&alloc_writer.writer, msg._unknown_fields, 0);
    }
    return try alloc_writer.toOwnedSlice();
}

fn skipped(allocator: std.mem.Allocator, reason: []const u8) ConformanceResponse {
    return .{ .result = .{ .skipped = allocator.dupe(u8, reason) catch @panic("OOM") } };
}

fn parse_error(allocator: std.mem.Allocator, reason: []const u8) ConformanceResponse {
    return .{ .result = .{ .parse_error = allocator.dupe(u8, reason) catch @panic("OOM") } };
}

fn serialize_error(allocator: std.mem.Allocator, reason: []const u8) ConformanceResponse {
    return .{ .result = .{ .serialize_error = allocator.dupe(u8, reason) catch @panic("OOM") } };
}
