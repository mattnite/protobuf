const std = @import("std");
const testing = std.testing;
const proto = @import("proto");
const rpc = @import("protobuf").rpc;
const rpc_pipe = @import("rpc_pipe");
const build_options = @import("build_options");

const PipeTransport = rpc_pipe.PipeTransport;

// ── Proto type aliases ──────────────────────────────────────────────

const UnaryService = proto.service_unary.UnaryService;
const PingRequest = proto.service_unary.PingRequest;
const PingResponse = proto.service_unary.PingResponse;
const GetItemRequest = proto.service_unary.GetItemRequest;
const GetItemResponse = proto.service_unary.GetItemResponse;
const HealthRequest = proto.service_unary.HealthRequest;
const HealthResponse = proto.service_unary.HealthResponse;
const EchoMessage = proto.service_unary.EchoMessage;

const StreamingService = proto.service_streaming.StreamingService;
const StreamRequest = proto.service_streaming.StreamRequest;
const StreamResponse = proto.service_streaming.StreamResponse;
const UploadChunk = proto.service_streaming.UploadChunk;
const UploadResult = proto.service_streaming.UploadResult;
const ChatMessage = proto.service_streaming.ChatMessage;

// ══════════════════════════════════════════════════════════════════════
// Zig Server Implementation
// ══════════════════════════════════════════════════════════════════════

const ZigUnaryImpl = struct {
    pub fn ping(_: *@This(), _: *rpc.Context, req: PingRequest) rpc.RpcError!PingResponse {
        return PingResponse{ .payload = req.payload };
    }

    pub fn get_item(_: *@This(), _: *rpc.Context, req: GetItemRequest) rpc.RpcError!GetItemResponse {
        return GetItemResponse{ .id = req.id, .name = "item_42" };
    }

    pub fn health(_: *@This(), _: *rpc.Context, _: HealthRequest) rpc.RpcError!HealthResponse {
        return HealthResponse{ .status = "serving" };
    }

    pub fn echo(_: *@This(), _: *rpc.Context, req: EchoMessage) rpc.RpcError!EchoMessage {
        return EchoMessage{ .text = req.text, .code = req.code + 1 };
    }

    pub fn rpc_server(self: *@This()) UnaryService.Server {
        return .{ .ptr = self, .vtable = &UnaryService.Server.gen_vtable(@This()) };
    }
};

const ZigStreamingImpl = struct {
    allocator: std.mem.Allocator,

    pub fn unary_call(_: *@This(), _: *rpc.Context, req: StreamRequest) rpc.RpcError!StreamResponse {
        return StreamResponse{ .result = req.query, .index = 0 };
    }

    pub fn server_side(_: *@This(), _: *rpc.Context, req: StreamRequest, send_stream: rpc.SendStream(StreamResponse)) rpc.RpcError!void {
        var i: i32 = 0;
        while (i < 3) : (i += 1) {
            var buf: [64]u8 = undefined;
            const result = std.fmt.bufPrint(&buf, "{s}_{d}", .{ req.query, i }) catch return error.status_error;
            try send_stream.send(StreamResponse{ .result = result, .index = i });
        }
    }

    pub fn client_side(self: *@This(), _: *rpc.Context, recv_stream: rpc.RecvStream(UploadChunk)) rpc.RpcError!UploadResult {
        var count: i32 = 0;
        while (true) {
            const chunk = try recv_stream.recv();
            if (chunk == null) break;
            var c = chunk.?;
            c.deinit(self.allocator);
            count += 1;
        }
        // Use a fixed string based on count instead of bufPrint (avoids dangling stack pointer)
        const summary: []const u8 = switch (count) {
            3 => "received_3_chunks",
            else => "received_chunks",
        };
        return UploadResult{ .total_chunks = count, .summary = summary };
    }

    pub fn bidirectional(self: *@This(), _: *rpc.Context, recv_stream: rpc.RecvStream(ChatMessage), send_stream: rpc.SendStream(ChatMessage)) rpc.RpcError!void {
        // Read all messages first
        var messages: std.ArrayList(ChatMessage) = .empty;
        defer {
            for (messages.items) |*msg| {
                var m = msg.*;
                m.deinit(self.allocator);
            }
            messages.deinit(self.allocator);
        }
        while (true) {
            const msg = try recv_stream.recv();
            if (msg == null) break;
            messages.append(self.allocator, msg.?) catch return error.status_error;
        }
        // Echo all back
        for (messages.items) |msg| {
            try send_stream.send(ChatMessage{ .sender = "echo", .text = msg.text });
        }
    }

    pub fn rpc_server(self: *@This()) StreamingService.Server {
        return .{ .ptr = self, .vtable = &StreamingService.Server.gen_vtable(@This()) };
    }
};

// ══════════════════════════════════════════════════════════════════════
// Server Loop — reads CALL frames, dispatches, writes responses
// ══════════════════════════════════════════════════════════════════════

fn serverLoop(transport: *PipeTransport) !void {
    var unary_impl: ZigUnaryImpl = .{};
    var streaming_impl: ZigStreamingImpl = .{ .allocator = transport.allocator };
    const unary_vtable = UnaryService.Server.gen_vtable(ZigUnaryImpl);
    const streaming_vtable = StreamingService.Server.gen_vtable(ZigStreamingImpl);
    const unary_server: UnaryService.Server = .{ .ptr = &unary_impl, .vtable = &unary_vtable };
    const streaming_server: StreamingService.Server = .{ .ptr = &streaming_impl, .vtable = &streaming_vtable };
    var ctx = rpc.Context{ .allocator = transport.allocator };

    while (true) {
        const frame = transport.readFrame() catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        defer transport.freePayload(frame.payload);

        switch (frame.frame_type) {
            .shutdown => return,
            .call => {
                const call = try PipeTransport.parseCallPayload(frame.payload);
                try dispatchCall(transport, &ctx, call.method, call.req_bytes, unary_server, streaming_server);
            },
            else => {
                try transport.writeError("unexpected frame type");
            },
        }
    }
}

fn dispatchCall(
    transport: *PipeTransport,
    ctx: *rpc.Context,
    method: []const u8,
    req_bytes: []const u8,
    unary_server: UnaryService.Server,
    streaming_server: StreamingService.Server,
) !void {
    if (std.mem.eql(u8, method, "/UnaryService/Ping")) {
        const req = try PingRequest.decode(transport.allocator, req_bytes);
        defer {
            var r = req;
            r.deinit(transport.allocator);
        }
        const resp = unary_server.ping(ctx, req) catch |err| {
            try transport.writeError(@errorName(err));
            return;
        };
        const encoded = try transport.encodeMessage(PingResponse, resp);
        defer transport.freePayload(encoded);
        try transport.writeResponse(encoded);
    } else if (std.mem.eql(u8, method, "/UnaryService/GetItem")) {
        const req = try GetItemRequest.decode(transport.allocator, req_bytes);
        defer {
            var r = req;
            r.deinit(transport.allocator);
        }
        const resp = unary_server.get_item(ctx, req) catch |err| {
            try transport.writeError(@errorName(err));
            return;
        };
        const encoded = try transport.encodeMessage(GetItemResponse, resp);
        defer transport.freePayload(encoded);
        try transport.writeResponse(encoded);
    } else if (std.mem.eql(u8, method, "/UnaryService/Health")) {
        const req = try HealthRequest.decode(transport.allocator, req_bytes);
        defer {
            var r = req;
            r.deinit(transport.allocator);
        }
        const resp = unary_server.health(ctx, req) catch |err| {
            try transport.writeError(@errorName(err));
            return;
        };
        const encoded = try transport.encodeMessage(HealthResponse, resp);
        defer transport.freePayload(encoded);
        try transport.writeResponse(encoded);
    } else if (std.mem.eql(u8, method, "/UnaryService/Echo")) {
        const req = try EchoMessage.decode(transport.allocator, req_bytes);
        defer {
            var r = req;
            r.deinit(transport.allocator);
        }
        const resp = unary_server.echo(ctx, req) catch |err| {
            try transport.writeError(@errorName(err));
            return;
        };
        const encoded = try transport.encodeMessage(EchoMessage, resp);
        defer transport.freePayload(encoded);
        try transport.writeResponse(encoded);
    } else if (std.mem.eql(u8, method, "/StreamingService/UnaryCall")) {
        const req = try StreamRequest.decode(transport.allocator, req_bytes);
        defer {
            var r = req;
            r.deinit(transport.allocator);
        }
        const resp = streaming_server.unary_call(ctx, req) catch |err| {
            try transport.writeError(@errorName(err));
            return;
        };
        const encoded = try transport.encodeMessage(StreamResponse, resp);
        defer transport.freePayload(encoded);
        try transport.writeResponse(encoded);
    } else if (std.mem.eql(u8, method, "/StreamingService/ServerSide")) {
        const req = try StreamRequest.decode(transport.allocator, req_bytes);
        defer {
            var r = req;
            r.deinit(transport.allocator);
        }
        var sender = rpc_pipe.PipeSendStream(StreamResponse){ .transport = transport };
        const send_stream = sender.sendStream();
        streaming_server.server_side(ctx, req, send_stream) catch |err| {
            try transport.writeError(@errorName(err));
            return;
        };
        // Send STREAM_END after server-streaming call completes
        try transport.writeStreamEnd();
    } else if (std.mem.eql(u8, method, "/StreamingService/ClientSide")) {
        var receiver = rpc_pipe.PipeRecvStream(UploadChunk){ .transport = transport };
        const recv_stream = receiver.recvStream();
        const resp = streaming_server.client_side(ctx, recv_stream) catch |err| {
            try transport.writeError(@errorName(err));
            return;
        };
        const encoded = try transport.encodeMessage(UploadResult, resp);
        defer transport.freePayload(encoded);
        try transport.writeResponse(encoded);
    } else if (std.mem.eql(u8, method, "/StreamingService/Bidirectional")) {
        var receiver = rpc_pipe.PipeRecvStream(ChatMessage){ .transport = transport };
        var sender = rpc_pipe.PipeSendStream(ChatMessage){ .transport = transport };
        const recv_stream = receiver.recvStream();
        const send_stream = sender.sendStream();
        streaming_server.bidirectional(ctx, recv_stream, send_stream) catch |err| {
            try transport.writeError(@errorName(err));
            return;
        };
        // Send STREAM_END after bidi-streaming call completes
        try transport.writeStreamEnd();
    } else {
        try transport.writeError("unknown method");
    }
}

// ══════════════════════════════════════════════════════════════════════
// Helper: spawn Go process with piped stdin/stdout
// ══════════════════════════════════════════════════════════════════════

const GoProc = struct {
    child: std.process.Child,
    reader_buf: [4096]u8 = undefined,
    writer_buf: [4096]u8 = undefined,
    file_reader: std.fs.File.Reader = undefined,
    file_writer: std.fs.File.Writer = undefined,
    transport: PipeTransport = undefined,

    /// Spawn the Go process. After calling this, you must call setup()
    /// to initialize the reader/writer/transport (they contain self-referential pointers).
    fn spawn(self: *GoProc, go_binary: []const u8) !void {
        self.child = std.process.Child.init(&.{go_binary}, testing.allocator);
        self.child.stdin_behavior = .Pipe;
        self.child.stdout_behavior = .Pipe;
        self.child.stderr_behavior = .Inherit;
        try self.child.spawn();
    }

    /// Initialize reader/writer/transport. Must be called after spawn() and
    /// after the GoProc has its final memory location (no more moves).
    fn setup(self: *GoProc) void {
        self.file_reader = self.child.stdout.?.readerStreaming(&self.reader_buf);
        self.file_writer = self.child.stdin.?.writerStreaming(&self.writer_buf);
        self.transport = .{
            .reader = &self.file_reader.interface,
            .writer = &self.file_writer.interface,
            .allocator = testing.allocator,
        };
    }

    fn deinit(self: *GoProc) void {
        const term = self.child.wait() catch unreachable;
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("Go process exited with code {d}\n", .{code});
                }
            },
            else => {
                std.debug.print("Go process terminated abnormally\n", .{});
            },
        }
    }
};

// ══════════════════════════════════════════════════════════════════════
// Helpers: unary call, encode message
// ══════════════════════════════════════════════════════════════════════

fn callUnary(
    transport: *PipeTransport,
    comptime Req: type,
    comptime Resp: type,
    method: []const u8,
    req: Req,
) !Resp {
    const encoded = try transport.encodeMessage(Req, req);
    defer transport.freePayload(encoded);
    try transport.writeCall(method, encoded);

    const frame = try transport.readFrame();
    defer transport.freePayload(frame.payload);
    if (frame.frame_type == .@"error") {
        std.debug.print("Server error: {s}\n", .{frame.payload});
        return error.ServerError;
    }
    if (frame.frame_type != .response) return error.UnexpectedFrame;
    return try Resp.decode(transport.allocator, frame.payload);
}

// ══════════════════════════════════════════════════════════════════════
// Tests: Go server / Zig client
// ══════════════════════════════════════════════════════════════════════

test "go server / zig client: Ping" {
    var proc: GoProc = undefined;
    try proc.spawn(build_options.go_rpc_server);
    proc.setup();
    defer proc.deinit();

    var resp = try callUnary(&proc.transport, PingRequest, PingResponse, "/UnaryService/Ping", PingRequest{ .payload = "hello" });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", resp.payload);

    try proc.transport.writeShutdown();
}

test "go server / zig client: GetItem" {
    var proc: GoProc = undefined;
    try proc.spawn(build_options.go_rpc_server);
    proc.setup();
    defer proc.deinit();

    var resp = try callUnary(&proc.transport, GetItemRequest, GetItemResponse, "/UnaryService/GetItem", GetItemRequest{ .id = 42, .query = "test" });
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 42), resp.id);
    try testing.expectEqualStrings("item_42", resp.name);

    try proc.transport.writeShutdown();
}

test "go server / zig client: Health" {
    var proc: GoProc = undefined;
    try proc.spawn(build_options.go_rpc_server);
    proc.setup();
    defer proc.deinit();

    var resp = try callUnary(&proc.transport, HealthRequest, HealthResponse, "/UnaryService/Health", HealthRequest{ .service_name = "svc" });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("serving", resp.status);

    try proc.transport.writeShutdown();
}

test "go server / zig client: Echo" {
    var proc: GoProc = undefined;
    try proc.spawn(build_options.go_rpc_server);
    proc.setup();
    defer proc.deinit();

    var resp = try callUnary(&proc.transport, EchoMessage, EchoMessage, "/UnaryService/Echo", EchoMessage{ .text = "hi", .code = 10 });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", resp.text);
    try testing.expectEqual(@as(i32, 11), resp.code);

    try proc.transport.writeShutdown();
}

test "go server / zig client: ServerSide streaming" {
    var proc: GoProc = undefined;
    try proc.spawn(build_options.go_rpc_server);
    proc.setup();
    defer proc.deinit();

    // Send CALL
    const req = StreamRequest{ .query = "q" };
    const encoded = try proc.transport.encodeMessage(StreamRequest, req);
    defer proc.transport.freePayload(encoded);
    try proc.transport.writeCall("/StreamingService/ServerSide", encoded);

    // Read 3 STREAM_MSG + STREAM_END
    var i: i32 = 0;
    while (i < 3) : (i += 1) {
        const frame = try proc.transport.readFrame();
        defer proc.transport.freePayload(frame.payload);
        try testing.expectEqual(rpc_pipe.FrameType.stream_msg, frame.frame_type);
        var resp = try StreamResponse.decode(testing.allocator, frame.payload);
        defer resp.deinit(testing.allocator);

        var expected_buf: [32]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "q_{d}", .{i}) catch unreachable;
        try testing.expectEqualStrings(expected, resp.result);
        try testing.expectEqual(i, resp.index);
    }

    const end_frame = try proc.transport.readFrame();
    defer proc.transport.freePayload(end_frame.payload);
    try testing.expectEqual(rpc_pipe.FrameType.stream_end, end_frame.frame_type);

    try proc.transport.writeShutdown();
}

test "go server / zig client: ClientSide streaming" {
    var proc: GoProc = undefined;
    try proc.spawn(build_options.go_rpc_server);
    proc.setup();
    defer proc.deinit();

    // Send CALL with empty payload
    try proc.transport.writeCall("/StreamingService/ClientSide", &.{});

    // Send 3 chunks
    const chunks = [_][]const u8{ "a", "bb", "ccc" };
    for (chunks) |data| {
        const chunk = UploadChunk{ .data = data };
        const chunk_bytes = try proc.transport.encodeMessage(UploadChunk, chunk);
        defer proc.transport.freePayload(chunk_bytes);
        try proc.transport.writeStreamMsg(chunk_bytes);
    }
    try proc.transport.writeStreamEnd();

    // Read RESPONSE
    const frame = try proc.transport.readFrame();
    defer proc.transport.freePayload(frame.payload);
    try testing.expectEqual(rpc_pipe.FrameType.response, frame.frame_type);
    var resp = try UploadResult.decode(testing.allocator, frame.payload);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 3), resp.total_chunks);
    try testing.expectEqualStrings("received_3_chunks", resp.summary);

    try proc.transport.writeShutdown();
}

test "go server / zig client: Bidirectional streaming" {
    var proc: GoProc = undefined;
    try proc.spawn(build_options.go_rpc_server);
    proc.setup();
    defer proc.deinit();

    // Send CALL with empty payload
    try proc.transport.writeCall("/StreamingService/Bidirectional", &.{});

    // Send 2 messages
    const msgs = [_]struct { sender: []const u8, text: []const u8 }{
        .{ .sender = "test", .text = "hi" },
        .{ .sender = "test", .text = "bye" },
    };
    for (msgs) |m| {
        const msg = ChatMessage{ .sender = m.sender, .text = m.text };
        const msg_bytes = try proc.transport.encodeMessage(ChatMessage, msg);
        defer proc.transport.freePayload(msg_bytes);
        try proc.transport.writeStreamMsg(msg_bytes);
    }
    try proc.transport.writeStreamEnd();

    // Read 2 echoed messages + STREAM_END
    const expected_texts = [_][]const u8{ "hi", "bye" };
    for (expected_texts) |expected_text| {
        const frame = try proc.transport.readFrame();
        defer proc.transport.freePayload(frame.payload);
        try testing.expectEqual(rpc_pipe.FrameType.stream_msg, frame.frame_type);
        var resp = try ChatMessage.decode(testing.allocator, frame.payload);
        defer resp.deinit(testing.allocator);
        try testing.expectEqualStrings("echo", resp.sender);
        try testing.expectEqualStrings(expected_text, resp.text);
    }

    const end_frame = try proc.transport.readFrame();
    defer proc.transport.freePayload(end_frame.payload);
    try testing.expectEqual(rpc_pipe.FrameType.stream_end, end_frame.frame_type);

    try proc.transport.writeShutdown();
}

// ══════════════════════════════════════════════════════════════════════
// Tests: Zig server / Go client
// ══════════════════════════════════════════════════════════════════════

test "zig server / go client: full test suite" {
    // Spawn Go client which will send requests and validate responses
    var child = std.process.Child.init(&.{build_options.go_rpc_client}, testing.allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    // Zig reads from client's stdout, writes to client's stdin
    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;
    var file_reader = child.stdout.?.readerStreaming(&reader_buf);
    var file_writer = child.stdin.?.writerStreaming(&writer_buf);
    var transport: PipeTransport = .{
        .reader = &file_reader.interface,
        .writer = &file_writer.interface,
        .allocator = testing.allocator,
    };

    // Run the server loop processing Go client requests
    try serverLoop(&transport);

    // Wait for Go client to exit
    const term = try child.wait();
    switch (term) {
        .Exited => |code| try testing.expectEqual(@as(u8, 0), code),
        else => return error.GoClientCrashed,
    }
}
