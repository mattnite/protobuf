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
    serialization_error,
};

// ── Streaming Interfaces ─────────────────────────────────────────────

/// Read stream: yields messages of type T from the remote peer.
pub fn RecvStream(comptime T: type) type {
    return struct {
        const Self = @This();
        ptr: *anyopaque,
        vtable: *const VTable,

        /// Function table for untyped receive implementations.
        pub const VTable = struct {
            /// Receive the next message. Returns null when the stream ends.
            recv: *const fn (*anyopaque) RpcError!?T,
        };

        /// Receive the next typed message from the stream.
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

        /// Function table for untyped send implementations.
        pub const VTable = struct {
            send: *const fn (*anyopaque, T) RpcError!void,
            close: *const fn (*anyopaque) RpcError!void,
        };

        /// Send one typed message on the stream.
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

        /// Send one request message on the client-streaming call.
        pub fn send(self: @This(), msg: Req) RpcError!void {
            return self.send_stream.send(msg);
        }

        /// Close the send side and receive the final response.
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

        /// Send one request message on the bidi stream.
        pub fn send(self: @This(), msg: Req) RpcError!void {
            return self.send_stream.send(msg);
        }

        /// Receive the next response message from the bidi stream.
        pub fn recv(self: @This()) RpcError!?Resp {
            return self.recv_stream.recv();
        }

        /// Close only the send side of the bidi stream.
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
/// The VTable operates on raw bytes; typed convenience methods serialize
/// request messages into gRPC-framed protobuf bytes, delegate to the raw
/// VTable, then deserialize the response back into typed messages.
pub const Channel = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Function table for transport-specific raw RPC operations.
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
    /// Serializes the request message to protobuf bytes, wraps in a gRPC frame,
    /// calls the raw VTable, then unwraps and deserializes the response.
    pub fn unary_call(self: Channel, comptime Resp: type, method_path: []const u8, ctx: *Context, req: anytype) RpcError!Resp {
        const request_bytes = serialize_message(req, ctx.allocator) catch return error.serialization_error;
        defer ctx.allocator.free(request_bytes);

        const response_bytes = try self.vtable.unary_call(self.ptr, method_path, request_bytes, ctx.allocator);
        defer ctx.allocator.free(response_bytes);

        return deserialize_message(Resp, response_bytes, ctx.allocator) catch return error.serialization_error;
    }

    /// Typed wrapper for generated client stubs (server-streaming RPC).
    /// Serializes the request and returns a typed RecvStream that deserializes
    /// each incoming raw message.
    pub fn server_stream_call(self: Channel, comptime Resp: type, method_path: []const u8, ctx: *Context, req: anytype) RpcError!RecvStream(Resp) {
        const request_bytes = serialize_message(req, ctx.allocator) catch return error.serialization_error;
        defer ctx.allocator.free(request_bytes);

        const raw_stream = try self.vtable.server_stream_call(self.ptr, method_path, request_bytes);
        return deserializing_recv_stream(Resp, raw_stream);
    }

    /// Typed wrapper for generated client stubs (client-streaming RPC).
    /// Returns a ClientStreamCall with a typed SendStream that serializes
    /// each outgoing message and a recv_response that deserializes the final response.
    pub fn client_stream_call(self: Channel, comptime Req: type, comptime Resp: type, method_path: []const u8, ctx: *Context) RpcError!ClientStreamCall(Req, Resp) {
        const raw_bidi = try self.vtable.client_stream_call(self.ptr, method_path);
        return serializing_client_stream_call(Req, Resp, raw_bidi, ctx.allocator);
    }

    /// Typed wrapper for generated client stubs (bidirectional-streaming RPC).
    /// Returns a BidiStreamCall with typed send/recv streams that handle
    /// serialization and deserialization transparently.
    pub fn bidi_stream_call(self: Channel, comptime Req: type, comptime Resp: type, method_path: []const u8, ctx: *Context) RpcError!BidiStreamCall(Req, Resp) {
        const raw_bidi = try self.vtable.bidi_stream_call(self.ptr, method_path);
        return serializing_bidi_stream_call(Req, Resp, raw_bidi, ctx.allocator);
    }
};

// ── gRPC Frame Encoding ──────────────────────────────────────────────

/// gRPC frame header size: 1 byte compression flag + 4 bytes big-endian length.
pub const grpc_frame_header_size: usize = 5;

/// Encode a gRPC length-prefixed frame: [1 byte compressed=0] [4 bytes big-endian length] [payload].
/// Returns a newly allocated slice containing the complete frame. Caller owns the memory.
pub fn encode_grpc_frame(payload: []const u8, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    const frame = try allocator.alloc(u8, grpc_frame_header_size + payload.len);
    frame[0] = 0; // compression flag: uncompressed
    std.mem.writeInt(u32, frame[1..5], @intCast(payload.len), .big);
    @memcpy(frame[grpc_frame_header_size..], payload);
    return frame;
}

/// Decode a gRPC length-prefixed frame, returning the payload slice within the frame.
/// Returns null if the frame is too short. Does not allocate.
pub fn decode_grpc_frame(frame: []const u8) ?GrpcFrame {
    if (frame.len < grpc_frame_header_size) return null;
    const compressed = frame[0] != 0;
    const length = std.mem.readInt(u32, frame[1..5], .big);
    if (frame.len < grpc_frame_header_size + length) return null;
    return .{
        .compressed = compressed,
        .data = frame[grpc_frame_header_size..][0..length],
    };
}

/// A decoded gRPC frame.
pub const GrpcFrame = struct {
    compressed: bool,
    data: []const u8,
};

// ── Serialization Helpers ────────────────────────────────────────────

/// Serialize a protobuf message to wire format bytes wrapped in a gRPC frame.
/// The message type must have `encode(*std.Io.Writer) std.Io.Writer.Error!void`
/// and `calc_size() usize` methods (as generated by protobuf codegen).
/// Returns a newly allocated gRPC-framed byte slice. Caller owns the memory.
pub fn serialize_message(msg: anytype, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    const msg_size = msg.calc_size();
    const total_size = grpc_frame_header_size + msg_size;
    const buf = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buf);

    // Write gRPC frame header
    buf[0] = 0; // compression flag: uncompressed
    std.mem.writeInt(u32, buf[1..5], @intCast(msg_size), .big);

    // Write protobuf message directly into the frame payload area
    var w: std.Io.Writer = .fixed(buf[grpc_frame_header_size..]);
    msg.encode(&w) catch {
        // std.Io.Writer.Error with a fixed buffer means we miscalculated size;
        // treat as serialization failure. This should not happen with correct calc_size.
        allocator.free(buf);
        return error.OutOfMemory;
    };

    return buf;
}

/// Deserialize a gRPC-framed byte slice into a protobuf message of the given type.
/// The type must have `decode(std.mem.Allocator, []const u8) !T`.
/// The caller is responsible for calling `deinit` on the returned message if applicable.
pub fn deserialize_message(comptime T: type, frame_bytes: []const u8, allocator: std.mem.Allocator) !T {
    const frame = decode_grpc_frame(frame_bytes) orelse return error.serialization_error;
    return T.decode(allocator, frame.data);
}

// ── Stream Adapters ──────────────────────────────────────────────────

/// Create a typed RecvStream that wraps a RawRecvStream, deserializing each
/// incoming raw byte message into a typed protobuf message.
pub fn deserializing_recv_stream(comptime T: type, raw: RawRecvStream) RecvStream(T) {
    const Adapter = struct {
        fn recv(ptr: *anyopaque) RpcError!?T {
            // Re-create the RawRecvStream from the stored pointer pair
            const adapter_ptr: *const RawRecvStream = @ptrCast(@alignCast(ptr));
            const raw_bytes = adapter_ptr.vtable.recv(adapter_ptr.ptr) catch return error.connection_closed;
            const bytes = raw_bytes orelse return null;
            // Decode the gRPC frame and deserialize the protobuf message.
            // We use a fixed-buffer approach: the message decode uses the allocator
            // from the raw bytes (assuming the transport allocated them).
            // For now, decode directly from the raw bytes (no gRPC frame unwrap
            // at stream level — the transport is expected to deliver message payloads).
            return T.decode(std.heap.page_allocator, bytes) catch return error.serialization_error;
        }
    };
    return .{
        .ptr = @constCast(@ptrCast(&raw)),
        .vtable = &.{ .recv = Adapter.recv },
    };
}

/// Create a typed SendStream that wraps a RawSendStream, serializing each
/// outgoing typed protobuf message into raw bytes.
/// The adapter is heap-allocated; calling `close()` on the returned stream
/// will forward to the underlying raw stream AND free the adapter.
pub fn serializing_send_stream(comptime T: type, raw: RawSendStream, allocator: std.mem.Allocator) SendStream(T) {
    const Adapter = struct {
        raw_stream: RawSendStream,
        alloc: std.mem.Allocator,

        fn send(ptr: *anyopaque, msg: T) RpcError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const frame = serialize_message(msg, self.alloc) catch return error.serialization_error;
            defer self.alloc.free(frame);
            return self.raw_stream.send(frame);
        }
        fn close(ptr: *anyopaque) RpcError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const a = self.alloc;
            const result = self.raw_stream.close();
            a.destroy(self);
            return result;
        }
    };
    const adapter = allocator.create(Adapter) catch return .{
        .ptr = undefined,
        .vtable = &.{ .send = Adapter.send, .close = Adapter.close },
    };
    adapter.* = .{ .raw_stream = raw, .alloc = allocator };
    return .{
        .ptr = @ptrCast(adapter),
        .vtable = &.{ .send = Adapter.send, .close = Adapter.close },
    };
}

/// Create a typed ClientStreamCall from a RawBidiStream.
/// The adapter is heap-allocated; calling `close_and_recv` frees it after
/// receiving the final response.
fn serializing_client_stream_call(comptime Req: type, comptime Resp: type, raw_bidi: RawBidiStream, allocator: std.mem.Allocator) ClientStreamCall(Req, Resp) {
    const Adapter = struct {
        raw_bidi: RawBidiStream,
        alloc: std.mem.Allocator,

        fn send_fn(ptr: *anyopaque, msg: Req) RpcError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const frame = serialize_message(msg, self.alloc) catch return error.serialization_error;
            defer self.alloc.free(frame);
            return self.raw_bidi.send_stream.send(frame);
        }
        fn close_fn(ptr: *anyopaque) RpcError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.raw_bidi.send_stream.close();
        }
        fn recv_response(ptr: *anyopaque) RpcError!Resp {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const a = self.alloc;
            const raw_bytes = (self.raw_bidi.recv_stream.recv() catch |e| {
                a.destroy(self);
                return e;
            }) orelse {
                a.destroy(self);
                return error.connection_closed;
            };
            const result = deserialize_message(Resp, raw_bytes, a) catch {
                a.destroy(self);
                return error.serialization_error;
            };
            a.destroy(self);
            return result;
        }
    };
    const adapter = allocator.create(Adapter) catch return .{
        .send_stream = .{
            .ptr = undefined,
            .vtable = &.{ .send = Adapter.send_fn, .close = Adapter.close_fn },
        },
        .recv_response = Adapter.recv_response,
        .ptr = undefined,
    };
    adapter.* = .{ .raw_bidi = raw_bidi, .alloc = allocator };
    const ptr: *anyopaque = @ptrCast(adapter);
    return .{
        .send_stream = .{
            .ptr = ptr,
            .vtable = &.{ .send = Adapter.send_fn, .close = Adapter.close_fn },
        },
        .recv_response = Adapter.recv_response,
        .ptr = ptr,
    };
}

/// Create a typed BidiStreamCall from a RawBidiStream.
/// The adapter is heap-allocated; calling `close_send()` frees it.
/// After close_send, the recv_stream handle is invalidated.
fn serializing_bidi_stream_call(comptime Req: type, comptime Resp: type, raw_bidi: RawBidiStream, allocator: std.mem.Allocator) BidiStreamCall(Req, Resp) {
    const Adapter = struct {
        raw_bidi: RawBidiStream,
        alloc: std.mem.Allocator,

        fn send_fn(ptr: *anyopaque, msg: Req) RpcError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const frame = serialize_message(msg, self.alloc) catch return error.serialization_error;
            defer self.alloc.free(frame);
            return self.raw_bidi.send_stream.send(frame);
        }
        fn close_fn(ptr: *anyopaque) RpcError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const a = self.alloc;
            const result = self.raw_bidi.send_stream.close();
            a.destroy(self);
            return result;
        }
        fn recv_fn(ptr: *anyopaque) RpcError!?Resp {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const raw_bytes = (try self.raw_bidi.recv_stream.recv()) orelse return null;
            return deserialize_message(Resp, raw_bytes, self.alloc) catch return error.serialization_error;
        }
    };
    const adapter = allocator.create(Adapter) catch return .{
        .send_stream = .{
            .ptr = undefined,
            .vtable = &.{ .send = Adapter.send_fn, .close = Adapter.close_fn },
        },
        .recv_stream = .{
            .ptr = undefined,
            .vtable = &.{ .recv = Adapter.recv_fn },
        },
    };
    adapter.* = .{ .raw_bidi = raw_bidi, .alloc = allocator };
    const ptr: *anyopaque = @ptrCast(adapter);
    return .{
        .send_stream = .{
            .ptr = ptr,
            .vtable = &.{ .send = Adapter.send_fn, .close = Adapter.close_fn },
        },
        .recv_stream = .{
            .ptr = ptr,
            .vtable = &.{ .recv = Adapter.recv_fn },
        },
    };
}

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

// ── gRPC Frame Tests ─────────────────────────────────────────────────

test "encode_grpc_frame: empty payload" {
    const frame = try encode_grpc_frame("", testing.allocator);
    defer testing.allocator.free(frame);
    try testing.expectEqual(@as(usize, grpc_frame_header_size), frame.len);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x00, 0x00, 0x00 }, frame);
}

test "encode_grpc_frame: hello payload" {
    const frame = try encode_grpc_frame("hello", testing.allocator);
    defer testing.allocator.free(frame);
    try testing.expectEqual(@as(usize, grpc_frame_header_size + 5), frame.len);
    try testing.expectEqualSlices(u8, &.{
        0x00,                   // not compressed
        0x00, 0x00, 0x00, 0x05, // length = 5
        'h',  'e',  'l',  'l', 'o',
    }, frame);
}

test "decode_grpc_frame: valid frame" {
    const frame_bytes = [_]u8{
        0x00,                   // not compressed
        0x00, 0x00, 0x00, 0x05, // length = 5
        'h',  'e',  'l',  'l', 'o',
    };
    const frame = decode_grpc_frame(&frame_bytes).?;
    try testing.expect(!frame.compressed);
    try testing.expectEqualStrings("hello", frame.data);
}

test "decode_grpc_frame: compressed flag" {
    const frame_bytes = [_]u8{
        0x01,                   // compressed
        0x00, 0x00, 0x00, 0x02, // length = 2
        'h',  'i',
    };
    const frame = decode_grpc_frame(&frame_bytes).?;
    try testing.expect(frame.compressed);
    try testing.expectEqualStrings("hi", frame.data);
}

test "decode_grpc_frame: empty payload" {
    const frame_bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00 };
    const frame = decode_grpc_frame(&frame_bytes).?;
    try testing.expect(!frame.compressed);
    try testing.expectEqual(@as(usize, 0), frame.data.len);
}

test "decode_grpc_frame: too short returns null" {
    try testing.expect(decode_grpc_frame("") == null);
    try testing.expect(decode_grpc_frame(&[_]u8{ 0x00, 0x00, 0x00 }) == null);
}

test "decode_grpc_frame: truncated payload returns null" {
    const frame_bytes = [_]u8{
        0x00,                   // not compressed
        0x00, 0x00, 0x00, 0x05, // length = 5
        'h',  'e',  'l',       // only 3 bytes, expected 5
    };
    try testing.expect(decode_grpc_frame(&frame_bytes) == null);
}

test "grpc frame round-trip" {
    const payload = "The quick brown fox";
    const frame = try encode_grpc_frame(payload, testing.allocator);
    defer testing.allocator.free(frame);

    const decoded = decode_grpc_frame(frame).?;
    try testing.expect(!decoded.compressed);
    try testing.expectEqualStrings(payload, decoded.data);
}

// ── Serialization Bridge Tests ───────────────────────────────────────

/// A minimal test message type that mimics the interface of generated protobuf messages.
const TestMessage = struct {
    value: u32 = 0,
    name: []const u8 = "",

    /// Encode into protobuf wire format: field 1 varint (value), field 2 len (name)
    pub fn encode(self: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.value != 0) {
            // field 1 varint: tag = (1 << 3) | 0 = 0x08
            try w.writeByte(0x08);
            // Simple varint encoding for u32
            var v: u64 = self.value;
            while (v > 0x7F) {
                try w.writeByte(@as(u8, @truncate(v)) | 0x80);
                v >>= 7;
            }
            try w.writeByte(@truncate(v));
        }
        if (self.name.len > 0) {
            // field 2 len: tag = (2 << 3) | 2 = 0x12
            try w.writeByte(0x12);
            // length prefix
            var len: u64 = self.name.len;
            while (len > 0x7F) {
                try w.writeByte(@as(u8, @truncate(len)) | 0x80);
                len >>= 7;
            }
            try w.writeByte(@truncate(len));
            try w.writeAll(self.name);
        }
    }

    /// Return the protobuf-encoded size of this test helper message.
    pub fn calc_size(self: @This()) usize {
        var size: usize = 0;
        if (self.value != 0) {
            size += 1; // tag
            var v: u64 = self.value;
            while (v > 0x7F) {
                size += 1;
                v >>= 7;
            }
            size += 1;
        }
        if (self.name.len > 0) {
            size += 1; // tag
            var len: u64 = self.name.len;
            while (len > 0x7F) {
                size += 1;
                len >>= 7;
            }
            size += 1;
            size += self.name.len;
        }
        return size;
    }

    /// Decode this test helper message from protobuf wire bytes.
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !TestMessage {
        var result: TestMessage = .{};
        var pos: usize = 0;
        while (pos < bytes.len) {
            const tag_byte = bytes[pos];
            pos += 1;
            const field_number = tag_byte >> 3;
            const wire_type = tag_byte & 0x07;

            switch (field_number) {
                1 => {
                    // varint
                    if (wire_type != 0) return error.InvalidWireType;
                    var val: u64 = 0;
                    var shift: u6 = 0;
                    while (pos < bytes.len) {
                        const b = bytes[pos];
                        pos += 1;
                        val |= @as(u64, b & 0x7F) << shift;
                        if (b & 0x80 == 0) break;
                        shift += 7;
                    }
                    result.value = @truncate(val);
                },
                2 => {
                    // len-delimited
                    if (wire_type != 2) return error.InvalidWireType;
                    var len: u64 = 0;
                    var shift: u6 = 0;
                    while (pos < bytes.len) {
                        const b = bytes[pos];
                        pos += 1;
                        len |= @as(u64, b & 0x7F) << shift;
                        if (b & 0x80 == 0) break;
                        shift += 7;
                    }
                    const str_len: usize = @intCast(len);
                    // Copy the string data so it outlives the input buffer
                    // (mimics what generated protobuf decode does)
                    const name_copy = try allocator.alloc(u8, str_len);
                    @memcpy(name_copy, bytes[pos..][0..str_len]);
                    result.name = name_copy;
                    pos += str_len;
                },
                else => return error.InvalidFieldNumber,
            }
        }
        return result;
    }

    /// Free heap-owned fields in this test helper message.
    pub fn deinit(self: *TestMessage, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) {
            allocator.free(self.name);
        }
    }

    const InvalidWireType = error{InvalidWireType};
    const InvalidFieldNumber = error{InvalidFieldNumber};
};

test "serialize_message: round-trip with TestMessage" {
    const msg = TestMessage{ .value = 42, .name = "test" };

    // Serialize to gRPC-framed bytes
    const frame_bytes = try serialize_message(msg, testing.allocator);
    defer testing.allocator.free(frame_bytes);

    // Verify gRPC frame header
    try testing.expectEqual(@as(u8, 0), frame_bytes[0]); // not compressed
    const payload_len = std.mem.readInt(u32, frame_bytes[1..5], .big);
    try testing.expectEqual(msg.calc_size(), @as(usize, payload_len));

    // Deserialize back
    var decoded = try deserialize_message(TestMessage, frame_bytes, testing.allocator);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 42), decoded.value);
    try testing.expectEqualStrings("test", decoded.name);
}

test "serialize_message: empty message round-trip" {
    const msg = TestMessage{};

    const frame_bytes = try serialize_message(msg, testing.allocator);
    defer testing.allocator.free(frame_bytes);

    // Empty message should produce just a gRPC frame header with zero-length payload
    try testing.expectEqual(@as(usize, grpc_frame_header_size), frame_bytes.len);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x00, 0x00, 0x00 }, frame_bytes);

    const decoded = try deserialize_message(TestMessage, frame_bytes, testing.allocator);
    try testing.expectEqual(@as(u32, 0), decoded.value);
    try testing.expectEqualStrings("", decoded.name);
}

test "deserialize_message: invalid frame returns error" {
    // Too short to be a valid gRPC frame
    const result = deserialize_message(TestMessage, &[_]u8{0x00}, testing.allocator);
    try testing.expectError(error.serialization_error, result);
}

test "Channel: unary_call with mock transport round-trip" {
    // A mock transport that echoes the request bytes back as the response.
    const MockTransport = struct {
        fn unary_call_fn(
            _: *anyopaque,
            method_path: []const u8,
            request_bytes: []const u8,
            allocator: std.mem.Allocator,
        ) RpcError![]const u8 {
            _ = method_path;
            // Echo: return a copy of the request bytes as the response
            const copy = allocator.dupe(u8, request_bytes) catch return error.status_error;
            return copy;
        }
        fn server_stream_fn(_: *anyopaque, _: []const u8, _: []const u8) RpcError!RawRecvStream {
            return error.status_error;
        }
        fn client_stream_fn(_: *anyopaque, _: []const u8) RpcError!RawBidiStream {
            return error.status_error;
        }
        fn bidi_stream_fn(_: *anyopaque, _: []const u8) RpcError!RawBidiStream {
            return error.status_error;
        }
    };

    var dummy: u8 = 0;
    const vtable = Channel.VTable{
        .unary_call = MockTransport.unary_call_fn,
        .server_stream_call = MockTransport.server_stream_fn,
        .client_stream_call = MockTransport.client_stream_fn,
        .bidi_stream_call = MockTransport.bidi_stream_fn,
    };
    const channel = Channel{
        .ptr = @ptrCast(&dummy),
        .vtable = &vtable,
    };

    var ctx = Context{
        .allocator = testing.allocator,
    };

    // Send a TestMessage through the channel and get it back
    const request = TestMessage{ .value = 123, .name = "hello" };
    var response = try channel.unary_call(TestMessage, "/test.Service/Echo", &ctx, request);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 123), response.value);
    try testing.expectEqualStrings("hello", response.name);
}

test "Channel: unary_call serializes protobuf correctly" {
    // A mock transport that copies the request bytes for later inspection.
    const CaptureTransport = struct {
        var captured_path: []const u8 = "";
        var captured_request_copy: ?[]u8 = null;

        fn unary_call_fn(
            _: *anyopaque,
            method_path: []const u8,
            request_bytes: []const u8,
            allocator: std.mem.Allocator,
        ) RpcError![]const u8 {
            captured_path = method_path;
            // Copy the request bytes so they survive after the caller frees the original
            captured_request_copy = allocator.dupe(u8, request_bytes) catch return error.status_error;
            // Return a valid gRPC frame with an empty message
            return allocator.dupe(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00 }) catch return error.status_error;
        }
        fn server_stream_fn(_: *anyopaque, _: []const u8, _: []const u8) RpcError!RawRecvStream {
            return error.status_error;
        }
        fn client_stream_fn(_: *anyopaque, _: []const u8) RpcError!RawBidiStream {
            return error.status_error;
        }
        fn bidi_stream_fn(_: *anyopaque, _: []const u8) RpcError!RawBidiStream {
            return error.status_error;
        }
    };

    var dummy: u8 = 0;
    const vtable = Channel.VTable{
        .unary_call = CaptureTransport.unary_call_fn,
        .server_stream_call = CaptureTransport.server_stream_fn,
        .client_stream_call = CaptureTransport.client_stream_fn,
        .bidi_stream_call = CaptureTransport.bidi_stream_fn,
    };
    const channel = Channel{
        .ptr = @ptrCast(&dummy),
        .vtable = &vtable,
    };

    var ctx = Context{ .allocator = testing.allocator };
    const request = TestMessage{ .value = 7 };
    const response = try channel.unary_call(TestMessage, "/pkg.Svc/Method", &ctx, request);

    // Verify the path was passed through
    try testing.expectEqualStrings("/pkg.Svc/Method", CaptureTransport.captured_path);

    // Verify the captured request is a valid gRPC frame containing the serialized message
    const captured = CaptureTransport.captured_request_copy.?;
    defer testing.allocator.free(captured);
    const frame = decode_grpc_frame(captured).?;
    try testing.expect(!frame.compressed);
    // Decode the protobuf payload and verify the value
    var decoded_req = try TestMessage.decode(testing.allocator, frame.data);
    defer decoded_req.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 7), decoded_req.value);

    // Response should be an empty message (from the mock)
    try testing.expectEqual(@as(u32, 0), response.value);
}

test "serializing_send_stream: round-trip through mock raw stream" {
    // Mock raw send stream that captures sent frames
    const MockRawSend = struct {
        var captured_frames: [8]?[]u8 = .{null} ** 8;
        var frame_count: usize = 0;
        var closed: bool = false;

        fn reset() void {
            for (&captured_frames) |*f| {
                if (f.*) |frame| testing.allocator.free(frame);
                f.* = null;
            }
            frame_count = 0;
            closed = false;
        }

        fn send_fn(_: *anyopaque, data: []const u8) RpcError!void {
            captured_frames[frame_count] = testing.allocator.dupe(u8, data) catch return error.status_error;
            frame_count += 1;
        }
        fn close_fn(_: *anyopaque) RpcError!void {
            closed = true;
        }
    };
    defer MockRawSend.reset();

    var dummy: u8 = 0;
    const raw = RawSendStream{
        .ptr = @ptrCast(&dummy),
        .vtable = &.{ .send = MockRawSend.send_fn, .close = MockRawSend.close_fn },
    };

    const typed_stream = serializing_send_stream(TestMessage, raw, testing.allocator);

    // Send a message
    try typed_stream.send(TestMessage{ .value = 42, .name = "hello" });

    // Verify the captured frame is a valid gRPC-framed protobuf
    const frame_bytes = MockRawSend.captured_frames[0].?;
    var decoded = try deserialize_message(TestMessage, frame_bytes, testing.allocator);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 42), decoded.value);
    try testing.expectEqualStrings("hello", decoded.name);

    // Close the stream (also frees the adapter)
    try typed_stream.close();
    try testing.expect(MockRawSend.closed);
}

test "serializing_bidi_stream_call: send and receive through mock" {
    // Mock raw bidi stream
    const MockBidi = struct {
        var sent_data: ?[]u8 = null;
        var send_closed: bool = false;
        var recv_call_count: usize = 0;
        // Pre-built response frame to return on recv
        var response_frame: ?[]u8 = null;

        fn reset() void {
            if (sent_data) |d| testing.allocator.free(d);
            sent_data = null;
            send_closed = false;
            recv_call_count = 0;
            if (response_frame) |f| testing.allocator.free(f);
            response_frame = null;
        }

        fn send_fn(_: *anyopaque, data: []const u8) RpcError!void {
            if (sent_data) |d| testing.allocator.free(d);
            sent_data = testing.allocator.dupe(u8, data) catch return error.status_error;
        }
        fn close_fn(_: *anyopaque) RpcError!void {
            send_closed = true;
        }
        fn recv_fn(_: *anyopaque) RpcError!?[]const u8 {
            recv_call_count += 1;
            if (recv_call_count == 1) {
                return response_frame.?;
            }
            return null; // end of stream
        }
    };
    defer MockBidi.reset();

    // Pre-build a response frame
    const response_msg = TestMessage{ .value = 99, .name = "resp" };
    MockBidi.response_frame = serialize_message(response_msg, testing.allocator) catch unreachable;

    var dummy: u8 = 0;
    const raw_bidi = RawBidiStream{
        .send_stream = .{
            .ptr = @ptrCast(&dummy),
            .vtable = &.{ .send = MockBidi.send_fn, .close = MockBidi.close_fn },
        },
        .recv_stream = .{
            .ptr = @ptrCast(&dummy),
            .vtable = &.{ .recv = MockBidi.recv_fn },
        },
    };

    const bidi = serializing_bidi_stream_call(TestMessage, TestMessage, raw_bidi, testing.allocator);

    // Send a message
    try bidi.send(TestMessage{ .value = 7 });
    // Verify sent data is a valid gRPC frame
    const sent_frame = MockBidi.sent_data.?;
    var decoded_sent = try deserialize_message(TestMessage, sent_frame, testing.allocator);
    defer decoded_sent.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 7), decoded_sent.value);

    // Receive a message
    var received = (try bidi.recv()).?;
    defer received.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 99), received.value);
    try testing.expectEqualStrings("resp", received.name);

    // Close send stream (also frees the adapter, so no more recv after this)
    try bidi.close_send();
    try testing.expect(MockBidi.send_closed);
}

test "serializing_client_stream_call: send multiple then receive response" {
    const MockClientStream = struct {
        var sent_count: usize = 0;
        var send_closed: bool = false;
        var recv_call_count: usize = 0;
        var response_frame: ?[]u8 = null;

        fn reset() void {
            sent_count = 0;
            send_closed = false;
            recv_call_count = 0;
            if (response_frame) |f| testing.allocator.free(f);
            response_frame = null;
        }

        fn send_fn(_: *anyopaque, _: []const u8) RpcError!void {
            sent_count += 1;
        }
        fn close_fn(_: *anyopaque) RpcError!void {
            send_closed = true;
        }
        fn recv_fn(_: *anyopaque) RpcError!?[]const u8 {
            recv_call_count += 1;
            return response_frame.?;
        }
    };
    defer MockClientStream.reset();

    // Pre-build response
    const resp_msg = TestMessage{ .value = 200 };
    MockClientStream.response_frame = serialize_message(resp_msg, testing.allocator) catch unreachable;

    var dummy: u8 = 0;
    const raw_bidi = RawBidiStream{
        .send_stream = .{
            .ptr = @ptrCast(&dummy),
            .vtable = &.{ .send = MockClientStream.send_fn, .close = MockClientStream.close_fn },
        },
        .recv_stream = .{
            .ptr = @ptrCast(&dummy),
            .vtable = &.{ .recv = MockClientStream.recv_fn },
        },
    };

    const call = serializing_client_stream_call(TestMessage, TestMessage, raw_bidi, testing.allocator);

    // Send several messages
    try call.send(TestMessage{ .value = 1 });
    try call.send(TestMessage{ .value = 2 });
    try call.send(TestMessage{ .value = 3 });
    try testing.expectEqual(@as(usize, 3), MockClientStream.sent_count);

    // Close and receive response (also frees the adapter)
    const resp = try call.close_and_recv();
    try testing.expect(MockClientStream.send_closed);
    try testing.expectEqual(@as(u32, 200), resp.value);
}

test "grpc frame: multiple messages in sequence" {
    // Verify that multiple messages can be framed and decoded in sequence
    const messages = [_][]const u8{ "first", "second", "third" };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Encode all messages into a single buffer
    for (messages) |msg| {
        const frame = try encode_grpc_frame(msg, testing.allocator);
        defer testing.allocator.free(frame);
        try buf.appendSlice(testing.allocator, frame);
    }

    // Decode them back
    var pos: usize = 0;
    for (messages) |expected| {
        const frame = decode_grpc_frame(buf.items[pos..]).?;
        try testing.expectEqualStrings(expected, frame.data);
        pos += grpc_frame_header_size + frame.data.len;
    }
    try testing.expectEqual(buf.items.len, pos);
}
