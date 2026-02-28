const std = @import("std");
const rpc = @import("protobuf").rpc;

// ── Frame Types ──────────────────────────────────────────────────────

pub const FrameType = enum(u8) {
    call = 0x01,
    response = 0x02,
    stream_msg = 0x03,
    stream_end = 0x04,
    @"error" = 0x05,
    shutdown = 0x06,
};

pub const Frame = struct {
    frame_type: FrameType,
    payload: []const u8,
};

// ── Pipe Transport ──────────────────────────────────────────────────

pub const PipeTransport = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,

    pub const ReadError = std.Io.Reader.Error;
    pub const WriteError = std.Io.Writer.Error;

    pub fn readFrame(self: *PipeTransport) ReadError!Frame {
        // Read 5-byte header: [1B type][4B BE payload_len]
        const header = try self.reader.takeArray(5);
        const frame_type: FrameType = @enumFromInt(header[0]);
        const payload_len = std.mem.bigToNative(u32, @bitCast(header[1..5].*));

        if (payload_len == 0) {
            return .{ .frame_type = frame_type, .payload = &.{} };
        }

        const payload = self.allocator.alloc(u8, payload_len) catch return error.EndOfStream;
        self.reader.readSliceAll(payload) catch |err| {
            self.allocator.free(payload);
            return err;
        };
        return .{ .frame_type = frame_type, .payload = payload };
    }

    pub fn writeFrame(self: *PipeTransport, frame_type: FrameType, payload: []const u8) WriteError!void {
        var header: [5]u8 = undefined;
        header[0] = @intFromEnum(frame_type);
        header[1..5].* = @bitCast(std.mem.nativeToBig(u32, @intCast(payload.len)));
        try self.writer.writeAll(&header);
        if (payload.len > 0) {
            try self.writer.writeAll(payload);
        }
        try self.writer.flush();
    }

    pub fn freePayload(self: *PipeTransport, payload: []const u8) void {
        if (payload.len > 0) {
            self.allocator.free(payload);
        }
    }

    // ── Convenience write methods ────────────────────────────────

    pub fn writeCall(self: *PipeTransport, method: []const u8, req_bytes: []const u8) WriteError!void {
        const payload = self.allocator.alloc(u8, 4 + method.len + req_bytes.len) catch return error.WriteFailed;
        defer self.allocator.free(payload);
        payload[0..4].* = @bitCast(std.mem.nativeToBig(u32, @intCast(method.len)));
        @memcpy(payload[4..][0..method.len], method);
        @memcpy(payload[4 + method.len ..], req_bytes);
        try self.writeFrame(.call, payload);
    }

    pub fn writeResponse(self: *PipeTransport, resp_bytes: []const u8) WriteError!void {
        try self.writeFrame(.response, resp_bytes);
    }

    pub fn writeStreamMsg(self: *PipeTransport, msg_bytes: []const u8) WriteError!void {
        try self.writeFrame(.stream_msg, msg_bytes);
    }

    pub fn writeStreamEnd(self: *PipeTransport) WriteError!void {
        try self.writeFrame(.stream_end, &.{});
    }

    pub fn writeError(self: *PipeTransport, msg: []const u8) WriteError!void {
        try self.writeFrame(.@"error", msg);
    }

    pub fn writeShutdown(self: *PipeTransport) WriteError!void {
        try self.writeFrame(.shutdown, &.{});
    }

    // ── CALL payload parsing ────────────────────────────────────

    pub const CallPayload = struct {
        method: []const u8,
        req_bytes: []const u8,
    };

    pub fn parseCallPayload(payload: []const u8) !CallPayload {
        if (payload.len < 4) return error.InvalidCallPayload;
        const method_len = std.mem.bigToNative(u32, @bitCast(payload[0..4].*));
        if (4 + method_len > payload.len) return error.InvalidCallPayload;
        return .{
            .method = payload[4..][0..method_len],
            .req_bytes = payload[4 + method_len ..],
        };
    }

    // ── Encode helper ───────────────────────────────────────────

    pub fn encodeMessage(self: *PipeTransport, comptime T: type, msg: T) ![]const u8 {
        const size = msg.calc_size();
        const buf = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buf);
        var w: std.Io.Writer = .fixed(buf);
        try msg.encode(&w);
        return w.buffered();
    }
};

// ── PipeSendStream ──────────────────────────────────────────────────

pub fn PipeSendStream(comptime T: type) type {
    return struct {
        transport: *PipeTransport,

        const Self = @This();

        pub fn sendStream(self: *Self) rpc.SendStream(T) {
            return .{
                .ptr = @ptrCast(self),
                .vtable = &.{
                    .send = sendFn,
                    .close = closeFn,
                },
            };
        }

        fn sendFn(ptr: *anyopaque, msg: T) rpc.RpcError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const encoded = self.transport.encodeMessage(T, msg) catch return error.connection_closed;
            defer self.transport.freePayload(encoded);
            self.transport.writeStreamMsg(encoded) catch return error.connection_closed;
        }

        fn closeFn(ptr: *anyopaque) rpc.RpcError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.transport.writeStreamEnd() catch return error.connection_closed;
        }
    };
}

// ── PipeRecvStream ──────────────────────────────────────────────────

pub fn PipeRecvStream(comptime T: type) type {
    return struct {
        transport: *PipeTransport,

        const Self = @This();

        pub fn recvStream(self: *Self) rpc.RecvStream(T) {
            return .{
                .ptr = @ptrCast(self),
                .vtable = &.{
                    .recv = recvFn,
                },
            };
        }

        fn recvFn(ptr: *anyopaque) rpc.RpcError!?T {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const frame = self.transport.readFrame() catch return error.connection_closed;
            defer self.transport.freePayload(frame.payload);
            switch (frame.frame_type) {
                .stream_end => return null,
                .stream_msg => {
                    return T.decode(self.transport.allocator, frame.payload) catch return error.status_error;
                },
                .@"error" => return error.status_error,
                else => return error.status_error,
            }
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────

test "parseCallPayload: valid" {
    var payload: [4 + 5 + 3]u8 = undefined;
    payload[0..4].* = @bitCast(std.mem.nativeToBig(u32, 5));
    @memcpy(payload[4..9], "hello");
    @memcpy(payload[9..12], "req");
    const result = try PipeTransport.parseCallPayload(&payload);
    try std.testing.expectEqualStrings("hello", result.method);
    try std.testing.expectEqualStrings("req", result.req_bytes);
}

test "parseCallPayload: empty request" {
    var payload: [4 + 3]u8 = undefined;
    payload[0..4].* = @bitCast(std.mem.nativeToBig(u32, 3));
    @memcpy(payload[4..7], "foo");
    const result = try PipeTransport.parseCallPayload(&payload);
    try std.testing.expectEqualStrings("foo", result.method);
    try std.testing.expectEqual(@as(usize, 0), result.req_bytes.len);
}

test "parseCallPayload: too short" {
    try std.testing.expectError(error.InvalidCallPayload, PipeTransport.parseCallPayload("ab"));
}
