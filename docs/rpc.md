# RPC Stub Generation

Design for generating transport-agnostic RPC service interfaces from protobuf
`service` definitions.

## Philosophy

This package generates **interfaces**, not implementations. The generated code
defines the method signatures, message types, streaming types, and service
metadata. The actual transport (gRPC over HTTP/2, Connect, custom IPC, test
mocks) is a separate concern that implements these interfaces.

The interface pattern follows Zig standard library conventions: `ptr: *anyopaque`
+ `vtable: *const VTable`, matching `std.mem.Allocator`, `std.io.AnyWriter`,
etc.

## Shared RPC Types (`src/rpc.zig`)

These types are part of the runtime library, not generated per-service.

### Status Codes

```zig
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

pub const Status = struct {
    code: StatusCode,
    message: []const u8 = "",
};

pub const RpcError = error{
    status_error,
    connection_closed,
    timeout,
    cancelled,
};
```

### Streaming Interfaces

```zig
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
```

### Context

```zig
pub const Metadata = struct {
    entries: []const Entry,

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn get(self: Metadata, key: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

pub const Context = struct {
    /// Metadata from the caller (headers).
    metadata: Metadata = .{ .entries = &.{} },
    /// Deadline as nanosecond timestamp (null = no deadline).
    deadline_ns: ?i128 = null,
    /// Allocator for the lifetime of this RPC call.
    allocator: std.mem.Allocator,
};
```

### Method Descriptor

```zig
pub const MethodDescriptor = struct {
    /// Short method name (e.g., "GetFeature").
    name: []const u8,
    /// Full path for routing (e.g., "/routeguide.RouteGuide/GetFeature").
    full_path: []const u8,
    client_streaming: bool,
    server_streaming: bool,
};

pub const ServiceDescriptor = struct {
    /// Fully qualified service name (e.g., "routeguide.RouteGuide").
    name: []const u8,
    methods: []const MethodDescriptor,
};
```

## Generated Code Per Service

### Example Proto

```protobuf
syntax = "proto3";
package routeguide;

service RouteGuide {
    rpc GetFeature(Point) returns (Feature);
    rpc ListFeatures(Rectangle) returns (stream Feature);
    rpc RecordRoute(stream Point) returns (RouteSummary);
    rpc RouteChat(stream RouteNote) returns (stream RouteNote);
}
```

### Generated Server Interface

```zig
pub const RouteGuide = struct {
    /// Service metadata, available at comptime.
    pub const service_descriptor = rpc.ServiceDescriptor{
        .name = "routeguide.RouteGuide",
        .methods = &.{
            .{ .name = "GetFeature",   .full_path = "/routeguide.RouteGuide/GetFeature",   .client_streaming = false, .server_streaming = false },
            .{ .name = "ListFeatures", .full_path = "/routeguide.RouteGuide/ListFeatures", .client_streaming = false, .server_streaming = true  },
            .{ .name = "RecordRoute",  .full_path = "/routeguide.RouteGuide/RecordRoute",  .client_streaming = true,  .server_streaming = false },
            .{ .name = "RouteChat",    .full_path = "/routeguide.RouteGuide/RouteChat",    .client_streaming = true,  .server_streaming = true  },
        },
    };

    /// Server-side interface. Implement this to handle RPCs.
    pub const Server = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            /// Unary: single request → single response.
            get_feature: *const fn (
                *anyopaque,
                *rpc.Context,
                Point,
            ) rpc.RpcError!Feature,

            /// Server streaming: single request → stream of responses.
            list_features: *const fn (
                *anyopaque,
                *rpc.Context,
                Rectangle,
                rpc.SendStream(Feature),
            ) rpc.RpcError!void,

            /// Client streaming: stream of requests → single response.
            record_route: *const fn (
                *anyopaque,
                *rpc.Context,
                rpc.RecvStream(Point),
            ) rpc.RpcError!RouteSummary,

            /// Bidi streaming: stream of requests ↔ stream of responses.
            route_chat: *const fn (
                *anyopaque,
                *rpc.Context,
                rpc.RecvStream(RouteNote),
                rpc.SendStream(RouteNote),
            ) rpc.RpcError!void,
        };

        // Typed dispatch methods
        pub fn get_feature(self: Server, ctx: *rpc.Context, req: Point) rpc.RpcError!Feature {
            return self.vtable.get_feature(self.ptr, ctx, req);
        }

        pub fn list_features(self: Server, ctx: *rpc.Context, req: Rectangle, stream: rpc.SendStream(Feature)) rpc.RpcError!void {
            return self.vtable.list_features(self.ptr, ctx, req, stream);
        }

        pub fn record_route(self: Server, ctx: *rpc.Context, stream: rpc.RecvStream(Point)) rpc.RpcError!RouteSummary {
            return self.vtable.record_route(self.ptr, ctx, stream);
        }

        pub fn route_chat(self: Server, ctx: *rpc.Context, recv: rpc.RecvStream(RouteNote), send: rpc.SendStream(RouteNote)) rpc.RpcError!void {
            return self.vtable.route_chat(self.ptr, ctx, recv, send);
        }

        /// Wrap any type that implements the required methods into a Server.
        pub fn init(impl: anytype) Server {
            const Ptr = @TypeOf(impl);
            const Impl = @typeInfo(Ptr).pointer.child;

            return .{
                .ptr = impl,
                .vtable = &gen_vtable(Impl),
            };
        }

        fn gen_vtable(comptime Impl: type) VTable {
            return .{
                .get_feature = struct {
                    fn call(p: *anyopaque, ctx: *rpc.Context, req: Point) rpc.RpcError!Feature {
                        const self: *Impl = @ptrCast(@alignCast(p));
                        return self.get_feature(ctx, req);
                    }
                }.call,
                .list_features = struct {
                    fn call(p: *anyopaque, ctx: *rpc.Context, req: Rectangle, s: rpc.SendStream(Feature)) rpc.RpcError!void {
                        const self: *Impl = @ptrCast(@alignCast(p));
                        return self.list_features(ctx, req, s);
                    }
                }.call,
                .record_route = struct {
                    fn call(p: *anyopaque, ctx: *rpc.Context, s: rpc.RecvStream(Point)) rpc.RpcError!RouteSummary {
                        const self: *Impl = @ptrCast(@alignCast(p));
                        return self.record_route(ctx, s);
                    }
                }.call,
                .route_chat = struct {
                    fn call(p: *anyopaque, ctx: *rpc.Context, recv: rpc.RecvStream(RouteNote), send: rpc.SendStream(RouteNote)) rpc.RpcError!void {
                        const self: *Impl = @ptrCast(@alignCast(p));
                        return self.route_chat(ctx, recv, send);
                    }
                }.call,
            };
        }
    };

    /// Client-side stub. Wraps a transport channel.
    pub const Client = struct {
        channel: rpc.Channel,

        pub fn init(channel: rpc.Channel) Client {
            return .{ .channel = channel };
        }

        pub fn get_feature(self: Client, ctx: *rpc.Context, req: Point) rpc.RpcError!Feature {
            return self.channel.unary_call(
                Feature,
                "/routeguide.RouteGuide/GetFeature",
                ctx,
                req,
            );
        }

        pub fn list_features(self: Client, ctx: *rpc.Context, req: Rectangle) rpc.RpcError!rpc.RecvStream(Feature) {
            return self.channel.server_stream_call(
                Feature,
                "/routeguide.RouteGuide/ListFeatures",
                ctx,
                req,
            );
        }

        pub fn record_route(self: Client, ctx: *rpc.Context) rpc.RpcError!rpc.ClientStreamCall(Point, RouteSummary) {
            return self.channel.client_stream_call(
                Point,
                RouteSummary,
                "/routeguide.RouteGuide/RecordRoute",
                ctx,
            );
        }

        pub fn route_chat(self: Client, ctx: *rpc.Context) rpc.RpcError!rpc.BidiStreamCall(RouteNote, RouteNote) {
            return self.channel.bidi_stream_call(
                RouteNote,
                RouteNote,
                "/routeguide.RouteGuide/RouteChat",
                ctx,
            );
        }
    };
};
```

## Channel Interface

The `Channel` is the transport abstraction that client stubs call into. It's
another vtable interface, implemented by the transport layer.

```zig
pub const Channel = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Make a unary RPC call. Serializes the request, sends it,
        /// receives and deserializes the response.
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
};
```

The client methods handle serialization/deserialization of the typed messages,
then delegate to the `Channel` for raw bytes transport.

## Streaming Call Types

For streaming RPCs, the client needs compound return types:

```zig
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
```

## The Four Method Shapes

| Method Type | Server Fn Signature | Client Return Type |
|-------------|--------------------|--------------------|
| Unary | `fn(*anyopaque, *Context, Req) Error!Resp` | `Error!Resp` |
| Server stream | `fn(*anyopaque, *Context, Req, SendStream(Resp)) Error!void` | `Error!RecvStream(Resp)` |
| Client stream | `fn(*anyopaque, *Context, RecvStream(Req)) Error!Resp` | `Error!ClientStreamCall(Req, Resp)` |
| Bidi stream | `fn(*anyopaque, *Context, RecvStream(Req), SendStream(Resp)) Error!void` | `Error!BidiStreamCall(Req, Resp)` |

Note the inversion: what the server **receives** (RecvStream), the client
**sends** (SendStream), and vice versa.

## Server Registration

A transport framework uses the `Server` interface and `service_descriptor` to
route incoming RPCs:

```zig
// Example: a hypothetical gRPC server framework
var server = grpc.Server.init(allocator);

// Register the service implementation
const my_impl = MyRouteGuideImpl.init();
server.register_service(
    RouteGuide.service_descriptor,
    RouteGuide.Server.init(&my_impl),
);

try server.serve("0.0.0.0:50051");
```

The `service_descriptor` provides the method paths for routing. The `Server`
interface provides the dispatch functions. The transport framework handles
HTTP/2 framing, length-prefix framing, compression, and metadata.

## User Implementation Example

```zig
const RouteGuideImpl = struct {
    db: *FeatureDatabase,

    pub fn get_feature(self: *RouteGuideImpl, ctx: *rpc.Context, point: Point) rpc.RpcError!Feature {
        _ = ctx;
        return self.db.find_feature(point) orelse {
            return rpc.RpcError.status_error; // NOT_FOUND
        };
    }

    pub fn list_features(self: *RouteGuideImpl, ctx: *rpc.Context, rect: Rectangle, stream: rpc.SendStream(Feature)) rpc.RpcError!void {
        _ = ctx;
        for (self.db.features) |feature| {
            if (in_range(feature.location, rect)) {
                try stream.send(feature);
            }
        }
        // Stream closes automatically when function returns
    }

    pub fn record_route(self: *RouteGuideImpl, ctx: *rpc.Context, stream: rpc.RecvStream(Point)) rpc.RpcError!RouteSummary {
        _ = ctx;
        var count: i32 = 0;
        while (try stream.recv()) |point| {
            _ = self.db.find_feature(point);
            count += 1;
        }
        return .{ .point_count = count };
    }

    pub fn route_chat(self: *RouteGuideImpl, ctx: *rpc.Context, recv: rpc.RecvStream(RouteNote), send: rpc.SendStream(RouteNote)) rpc.RpcError!void {
        _ = ctx;
        _ = self;
        while (try recv.recv()) |note| {
            try send.send(note);
        }
    }
};
```

The user implements a struct with methods matching the service definition.
`Server.init(&impl)` wraps it into the vtable interface at comptime.
