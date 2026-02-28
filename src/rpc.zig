const std = @import("std");
const testing = std.testing;

// ── Status Codes ─────────────────────────────────────────────────────

/// gRPC-compatible status codes
pub const StatusCode = enum(u5) {
    ok = 0,
    cancelled = 1,
    unknown = 2,
    invalid_argument = 3,
    deadline_exceeded = 4,
    not_found = 5,
    already_exists = 6,
    permission_denied = 7,
    resource_exhausted = 8,
    failed_precondition = 9,
    aborted = 10,
    out_of_range = 11,
    unimplemented = 12,
    internal = 13,
    unavailable = 14,
    data_loss = 15,
    unauthenticated = 16,
};

/// RPC status with a code and optional message
pub const Status = struct {
    code: StatusCode,
    message: []const u8 = "",
};

/// Errors that can occur during an RPC call
pub const RpcError = error{
    status_error,
    connection_closed,
    timeout,
    cancelled,
};

// ── Streaming Interfaces ─────────────────────────────────────────────

/// Read stream: yields messages of type T from the remote peer.
pub fn RecvStream(comptime T: type) type {
    return struct {
        const Self = @This();
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            /// Receive the next message. Returns null when the stream ends.
            recv: *const fn (*anyopaque) RpcError!?T,
        };

        pub fn recv(self: Self) RpcError!?T {
            return self.vtable.recv(self.ptr);
        }

        /// Iterate over all messages in the stream.
        pub fn next(self: Self) RpcError!?T {
            return self.recv();
        }
    };
}

/// Write stream: sends messages of type T to the remote peer.
pub fn SendStream(comptime T: type) type {
    return struct {
        const Self = @This();
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            send: *const fn (*anyopaque, T) RpcError!void,
            close: *const fn (*anyopaque) RpcError!void,
        };

        pub fn send(self: Self, msg: T) RpcError!void {
            return self.vtable.send(self.ptr, msg);
        }

        /// Signal that no more messages will be sent.
        pub fn close(self: Self) RpcError!void {
            return self.vtable.close(self.ptr);
        }
    };
}

// ── Context ──────────────────────────────────────────────────────────

/// Collection of key-value metadata entries (headers/trailers)
pub const Metadata = struct {
    entries: []const Entry,

    /// A single metadata key-value pair
    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    /// Return the first metadata value matching a key, or null
    pub fn get(self: Metadata, key: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

/// Per-RPC context carrying metadata, deadline, and allocator
pub const Context = struct {
    /// Metadata from the caller (headers).
    metadata: Metadata = .{ .entries = &.{} },
    /// Deadline as nanosecond timestamp (null = no deadline).
    deadline_ns: ?i128 = null,
    /// Allocator for the lifetime of this RPC call.
    allocator: std.mem.Allocator,
};

// ── Compound Streaming Call Types ────────────────────────────────────

/// Client streaming: caller sends messages, then gets one response.
pub fn ClientStreamCall(comptime Req: type, comptime Resp: type) type {
    return struct {
        send_stream: SendStream(Req),
        /// Call after closing the send stream to get the response.
        recv_response: *const fn (*anyopaque) RpcError!Resp,
        ptr: *anyopaque,

        pub fn send(self: @This(), msg: Req) RpcError!void {
            return self.send_stream.send(msg);
        }

        pub fn close_and_recv(self: @This()) RpcError!Resp {
            try self.send_stream.close();
            return self.recv_response(self.ptr);
        }
    };
}

/// Bidi streaming: caller sends and receives independently.
pub fn BidiStreamCall(comptime Req: type, comptime Resp: type) type {
    return struct {
        send_stream: SendStream(Req),
        recv_stream: RecvStream(Resp),

        pub fn send(self: @This(), msg: Req) RpcError!void {
            return self.send_stream.send(msg);
        }

        pub fn recv(self: @This()) RpcError!?Resp {
            return self.recv_stream.recv();
        }

        pub fn close_send(self: @This()) RpcError!void {
            return self.send_stream.close();
        }
    };
}

// ── Descriptors ──────────────────────────────────────────────────────

/// Descriptor for a single RPC method
pub const MethodDescriptor = struct {
    /// Short method name (e.g., "GetFeature").
    name: []const u8,
    /// Full path for routing (e.g., "/routeguide.RouteGuide/GetFeature").
    full_path: []const u8,
    client_streaming: bool,
    server_streaming: bool,
};

/// Descriptor for an RPC service
pub const ServiceDescriptor = struct {
    /// Fully qualified service name (e.g., "routeguide.RouteGuide").
    name: []const u8,
    methods: []const MethodDescriptor,
};

// ── Channel ──────────────────────────────────────────────────────────

/// Type alias for a byte-level receive stream
pub const RawRecvStream = RecvStream([]const u8);
/// Type alias for a byte-level send stream
pub const RawSendStream = SendStream([]const u8);

/// Bidirectional raw byte stream pair
pub const RawBidiStream = struct {
    recv_stream: RawRecvStream,
    send_stream: RawSendStream,
};

/// Transport abstraction that client stubs call into.
/// The VTable operates on raw bytes; typed convenience methods are provided
/// for generated client code. Phase 7 will add the serialization bridge.
pub const Channel = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Make a unary RPC call with raw bytes.
        unary_call: *const fn (
            *anyopaque,
            method_path: []const u8,
            request_bytes: []const u8,
            allocator: std.mem.Allocator,
        ) RpcError![]const u8,

        /// Open a server-streaming call.
        server_stream_call: *const fn (
            *anyopaque,
            method_path: []const u8,
            request_bytes: []const u8,
        ) RpcError!RawRecvStream,

        /// Open a client-streaming call.
        client_stream_call: *const fn (
            *anyopaque,
            method_path: []const u8,
        ) RpcError!RawBidiStream,

        /// Open a bidirectional streaming call.
        bidi_stream_call: *const fn (
            *anyopaque,
            method_path: []const u8,
        ) RpcError!RawBidiStream,
    };

    /// Typed wrapper for generated client stubs (unary RPC).
    /// Phase 7 will add serialization between typed messages and raw bytes.
    pub fn unary_call(self: Channel, comptime Resp: type, method_path: []const u8, ctx: *Context, req: anytype) RpcError!Resp {
        _ = self;
        _ = method_path;
        _ = ctx;
        _ = req;
        return error.status_error;
    }

    /// Typed wrapper for generated client stubs (server-streaming RPC).
    pub fn server_stream_call(self: Channel, comptime Resp: type, method_path: []const u8, ctx: *Context, req: anytype) RpcError!RecvStream(Resp) {
        _ = self;
        _ = method_path;
        _ = ctx;
        _ = req;
        return error.status_error;
    }

    /// Typed wrapper for generated client stubs (client-streaming RPC).
    pub fn client_stream_call(self: Channel, comptime Req: type, comptime Resp: type, method_path: []const u8, ctx: *Context) RpcError!ClientStreamCall(Req, Resp) {
        _ = self;
        _ = method_path;
        _ = ctx;
        return error.status_error;
    }

    /// Typed wrapper for generated client stubs (bidirectional-streaming RPC).
    pub fn bidi_stream_call(self: Channel, comptime Req: type, comptime Resp: type, method_path: []const u8, ctx: *Context) RpcError!BidiStreamCall(Req, Resp) {
        _ = self;
        _ = method_path;
        _ = ctx;
        return error.status_error;
    }
};

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

test "StatusCode: values match gRPC spec" {
    try testing.expectEqual(@as(u5, 0), @intFromEnum(StatusCode.ok));
    try testing.expectEqual(@as(u5, 1), @intFromEnum(StatusCode.cancelled));
    try testing.expectEqual(@as(u5, 2), @intFromEnum(StatusCode.unknown));
    try testing.expectEqual(@as(u5, 3), @intFromEnum(StatusCode.invalid_argument));
    try testing.expectEqual(@as(u5, 4), @intFromEnum(StatusCode.deadline_exceeded));
    try testing.expectEqual(@as(u5, 5), @intFromEnum(StatusCode.not_found));
    try testing.expectEqual(@as(u5, 6), @intFromEnum(StatusCode.already_exists));
    try testing.expectEqual(@as(u5, 7), @intFromEnum(StatusCode.permission_denied));
    try testing.expectEqual(@as(u5, 8), @intFromEnum(StatusCode.resource_exhausted));
    try testing.expectEqual(@as(u5, 9), @intFromEnum(StatusCode.failed_precondition));
    try testing.expectEqual(@as(u5, 10), @intFromEnum(StatusCode.aborted));
    try testing.expectEqual(@as(u5, 11), @intFromEnum(StatusCode.out_of_range));
    try testing.expectEqual(@as(u5, 12), @intFromEnum(StatusCode.unimplemented));
    try testing.expectEqual(@as(u5, 13), @intFromEnum(StatusCode.internal));
    try testing.expectEqual(@as(u5, 14), @intFromEnum(StatusCode.unavailable));
    try testing.expectEqual(@as(u5, 15), @intFromEnum(StatusCode.data_loss));
    try testing.expectEqual(@as(u5, 16), @intFromEnum(StatusCode.unauthenticated));
}

test "Metadata: get finds existing key" {
    const entries = [_]Metadata.Entry{
        .{ .key = "content-type", .value = "application/grpc" },
        .{ .key = "authorization", .value = "Bearer token" },
    };
    const md = Metadata{ .entries = &entries };
    try testing.expectEqualStrings("application/grpc", md.get("content-type").?);
    try testing.expectEqualStrings("Bearer token", md.get("authorization").?);
}

test "Metadata: get returns null for missing key" {
    const md = Metadata{ .entries = &.{} };
    try testing.expect(md.get("anything") == null);
}

test "RecvStream: dispatch through vtable" {
    const Impl = struct {
        value: u32,
        fn recv_fn(p: *anyopaque) RpcError!?u32 {
            const self: *@This() = @ptrCast(@alignCast(p));
            if (self.value > 0) {
                const v = self.value;
                self.value -= 1;
                return v;
            }
            return null;
        }
    };
    var impl = Impl{ .value = 3 };
    const stream = RecvStream(u32){
        .ptr = @ptrCast(&impl),
        .vtable = &.{ .recv = Impl.recv_fn },
    };
    try testing.expectEqual(@as(?u32, 3), try stream.recv());
    try testing.expectEqual(@as(?u32, 2), try stream.next());
    try testing.expectEqual(@as(?u32, 1), try stream.recv());
    try testing.expectEqual(@as(?u32, null), try stream.recv());
}

test "SendStream: dispatch through vtable" {
    const Impl = struct {
        last_sent: u32 = 0,
        closed: bool = false,
        fn send_fn(p: *anyopaque, msg: u32) RpcError!void {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.last_sent = msg;
        }
        fn close_fn(p: *anyopaque) RpcError!void {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.closed = true;
        }
    };
    var impl: Impl = .{};
    const stream = SendStream(u32){
        .ptr = @ptrCast(&impl),
        .vtable = &.{ .send = Impl.send_fn, .close = Impl.close_fn },
    };
    try stream.send(42);
    try testing.expectEqual(@as(u32, 42), impl.last_sent);
    try stream.send(99);
    try testing.expectEqual(@as(u32, 99), impl.last_sent);
    try stream.close();
    try testing.expect(impl.closed);
}
