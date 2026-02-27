const std = @import("std");
const testing = std.testing;
const proto = @import("proto");
const rpc = @import("protobuf").rpc;

// ── Module aliases ──────────────────────────────────────────────────

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

const FirstService = proto.service_multi.FirstService;
const SecondService = proto.service_multi.SecondService;
const ThirdService = proto.service_multi.ThirdService;
const RequestA = proto.service_multi.RequestA;
const ResponseA = proto.service_multi.ResponseA;
const RequestB = proto.service_multi.RequestB;
const ResponseB = proto.service_multi.ResponseB;

const PackagedService = proto.service_package.PackagedService;
const LookupRequest = proto.service_package.LookupRequest;
const LookupResponse = proto.service_package.LookupResponse;

const SingleMethodService = proto.service_edge.SingleMethodService;
const ManyMethodsService = proto.service_edge.ManyMethodsService;
const EdgeRequest = proto.service_edge.EdgeRequest;
const EdgeResponse = proto.service_edge.EdgeResponse;

const TypesService = proto.service_types.TypesService;
const ComplexRequest = proto.service_types.ComplexRequest;
const ComplexResponse = proto.service_types.ComplexResponse;
const Priority = proto.service_types.Priority;

const NamingService = proto.service_names.NamingService;
const NameRequest = proto.service_names.NameRequest;
const NameResponse = proto.service_names.NameResponse;

// ══════════════════════════════════════════════════════════════════════
// Descriptor Tests
// ══════════════════════════════════════════════════════════════════════

test "unary: service descriptor name and method count" {
    const desc = UnaryService.service_descriptor;
    try testing.expectEqualStrings("UnaryService", desc.name);
    try testing.expectEqual(@as(usize, 4), desc.methods.len);
}

test "unary: method names in descriptor" {
    const methods = UnaryService.service_descriptor.methods;
    try testing.expectEqualStrings("Ping", methods[0].name);
    try testing.expectEqualStrings("GetItem", methods[1].name);
    try testing.expectEqualStrings("Health", methods[2].name);
    try testing.expectEqualStrings("Echo", methods[3].name);
}

test "unary: full paths in descriptor" {
    const methods = UnaryService.service_descriptor.methods;
    try testing.expectEqualStrings("/UnaryService/Ping", methods[0].full_path);
    try testing.expectEqualStrings("/UnaryService/GetItem", methods[1].full_path);
    try testing.expectEqualStrings("/UnaryService/Health", methods[2].full_path);
    try testing.expectEqualStrings("/UnaryService/Echo", methods[3].full_path);
}

test "unary: all methods are non-streaming" {
    for (UnaryService.service_descriptor.methods) |m| {
        try testing.expect(!m.client_streaming);
        try testing.expect(!m.server_streaming);
    }
}

test "streaming: descriptor streaming flags" {
    const methods = StreamingService.service_descriptor.methods;
    // UnaryCall
    try testing.expect(!methods[0].client_streaming);
    try testing.expect(!methods[0].server_streaming);
    // ServerSide
    try testing.expect(!methods[1].client_streaming);
    try testing.expect(methods[1].server_streaming);
    // ClientSide
    try testing.expect(methods[2].client_streaming);
    try testing.expect(!methods[2].server_streaming);
    // Bidirectional
    try testing.expect(methods[3].client_streaming);
    try testing.expect(methods[3].server_streaming);
}

test "streaming: method names in descriptor" {
    const methods = StreamingService.service_descriptor.methods;
    try testing.expectEqualStrings("UnaryCall", methods[0].name);
    try testing.expectEqualStrings("ServerSide", methods[1].name);
    try testing.expectEqualStrings("ClientSide", methods[2].name);
    try testing.expectEqualStrings("Bidirectional", methods[3].name);
}

test "multi: three services exist as separate types" {
    const d1 = FirstService.service_descriptor;
    const d2 = SecondService.service_descriptor;
    const d3 = ThirdService.service_descriptor;
    try testing.expectEqualStrings("FirstService", d1.name);
    try testing.expectEqualStrings("SecondService", d2.name);
    try testing.expectEqualStrings("ThirdService", d3.name);
}

test "multi: independent method counts" {
    try testing.expectEqual(@as(usize, 2), FirstService.service_descriptor.methods.len);
    try testing.expectEqual(@as(usize, 2), SecondService.service_descriptor.methods.len);
    try testing.expectEqual(@as(usize, 1), ThirdService.service_descriptor.methods.len);
}

test "multi: ThirdService uses bidi streaming" {
    const m = ThirdService.service_descriptor.methods[0];
    try testing.expectEqualStrings("StreamExchange", m.name);
    try testing.expect(m.client_streaming);
    try testing.expect(m.server_streaming);
}

test "package: descriptor name includes full package" {
    const desc = PackagedService.service_descriptor;
    try testing.expectEqualStrings("myapp.services.v1.PackagedService", desc.name);
}

test "package: full paths include package" {
    const methods = PackagedService.service_descriptor.methods;
    try testing.expectEqualStrings("/myapp.services.v1.PackagedService/Lookup", methods[0].full_path);
    try testing.expectEqualStrings("/myapp.services.v1.PackagedService/ReverseLookup", methods[1].full_path);
}

test "edge: single method service" {
    const desc = SingleMethodService.service_descriptor;
    try testing.expectEqual(@as(usize, 1), desc.methods.len);
    try testing.expectEqualStrings("OnlyMethod", desc.methods[0].name);
}

test "edge: many methods service has 8 methods" {
    const desc = ManyMethodsService.service_descriptor;
    try testing.expectEqual(@as(usize, 8), desc.methods.len);
}

test "edge: many methods names correct" {
    const methods = ManyMethodsService.service_descriptor.methods;
    const expected = [_][]const u8{ "Create", "Read", "Update", "Delete", "List", "Count", "Exists", "Validate" };
    for (expected, 0..) |name, i| {
        try testing.expectEqualStrings(name, methods[i].name);
    }
}

test "types: descriptor method count and streaming" {
    const desc = TypesService.service_descriptor;
    try testing.expectEqual(@as(usize, 2), desc.methods.len);
    try testing.expect(!desc.methods[0].server_streaming);
    try testing.expect(desc.methods[1].server_streaming);
}

test "names: descriptor preserves PascalCase" {
    const methods = NamingService.service_descriptor.methods;
    const expected = [_][]const u8{ "A", "AB", "GetHTTPResponse", "DoXMLParsing", "SimpleCall", "X", "GetUserByID" };
    for (expected, 0..) |name, i| {
        try testing.expectEqualStrings(name, methods[i].name);
    }
}

test "names: full_path uses PascalCase" {
    const methods = NamingService.service_descriptor.methods;
    try testing.expectEqualStrings("/NamingService/A", methods[0].full_path);
    try testing.expectEqualStrings("/NamingService/AB", methods[1].full_path);
    try testing.expectEqualStrings("/NamingService/GetHTTPResponse", methods[2].full_path);
    try testing.expectEqualStrings("/NamingService/DoXMLParsing", methods[3].full_path);
    try testing.expectEqualStrings("/NamingService/SimpleCall", methods[4].full_path);
    try testing.expectEqualStrings("/NamingService/X", methods[5].full_path);
    try testing.expectEqualStrings("/NamingService/GetUserByID", methods[6].full_path);
}

// ══════════════════════════════════════════════════════════════════════
// Server VTable Init & Dispatch Tests
// ══════════════════════════════════════════════════════════════════════

test "unary: server dispatch Ping" {
    const MockImpl = struct {
        last_payload: []const u8 = "",

        pub fn ping(self: *@This(), _: *rpc.Context, req: PingRequest) rpc.RpcError!PingResponse {
            self.last_payload = req.payload;
            return PingResponse{ .payload = req.payload };
        }

        pub fn get_item(_: *@This(), _: *rpc.Context, _: GetItemRequest) rpc.RpcError!GetItemResponse {
            return GetItemResponse{};
        }

        pub fn health(_: *@This(), _: *rpc.Context, _: HealthRequest) rpc.RpcError!HealthResponse {
            return HealthResponse{};
        }

        pub fn echo(_: *@This(), _: *rpc.Context, _: EchoMessage) rpc.RpcError!EchoMessage {
            return EchoMessage{};
        }

        pub fn rpc_server(self: *@This()) UnaryService.Server {
            return .{ .ptr = self, .vtable = &UnaryService.Server.gen_vtable(@This()) };
        }
    };

    var mock = MockImpl{};
    const server = mock.rpc_server();
    var ctx = rpc.Context{ .allocator = testing.allocator };

    const resp = try server.ping(&ctx, PingRequest{ .payload = "hello" });
    try testing.expectEqualStrings("hello", resp.payload);
    try testing.expectEqualStrings("hello", mock.last_payload);
}

test "unary: server dispatch GetItem" {
    const MockImpl = struct {
        pub fn ping(_: *@This(), _: *rpc.Context, _: PingRequest) rpc.RpcError!PingResponse {
            return PingResponse{};
        }

        pub fn get_item(_: *@This(), _: *rpc.Context, req: GetItemRequest) rpc.RpcError!GetItemResponse {
            return GetItemResponse{ .id = req.id, .name = "found" };
        }

        pub fn health(_: *@This(), _: *rpc.Context, _: HealthRequest) rpc.RpcError!HealthResponse {
            return HealthResponse{};
        }

        pub fn echo(_: *@This(), _: *rpc.Context, _: EchoMessage) rpc.RpcError!EchoMessage {
            return EchoMessage{};
        }

        pub fn rpc_server(self: *@This()) UnaryService.Server {
            return .{ .ptr = self, .vtable = &UnaryService.Server.gen_vtable(@This()) };
        }
    };

    var mock = MockImpl{};
    const server = mock.rpc_server();
    var ctx = rpc.Context{ .allocator = testing.allocator };

    const resp = try server.get_item(&ctx, GetItemRequest{ .id = 42 });
    try testing.expectEqual(@as(i32, 42), resp.id);
    try testing.expectEqualStrings("found", resp.name);
}

test "unary: server dispatch Health" {
    const MockImpl = struct {
        health_called: bool = false,

        pub fn ping(_: *@This(), _: *rpc.Context, _: PingRequest) rpc.RpcError!PingResponse {
            return PingResponse{};
        }

        pub fn get_item(_: *@This(), _: *rpc.Context, _: GetItemRequest) rpc.RpcError!GetItemResponse {
            return GetItemResponse{};
        }

        pub fn health(self: *@This(), _: *rpc.Context, _: HealthRequest) rpc.RpcError!HealthResponse {
            self.health_called = true;
            return HealthResponse{ .status = "serving" };
        }

        pub fn echo(_: *@This(), _: *rpc.Context, _: EchoMessage) rpc.RpcError!EchoMessage {
            return EchoMessage{};
        }

        pub fn rpc_server(self: *@This()) UnaryService.Server {
            return .{ .ptr = self, .vtable = &UnaryService.Server.gen_vtable(@This()) };
        }
    };

    var mock = MockImpl{};
    const server = mock.rpc_server();
    var ctx = rpc.Context{ .allocator = testing.allocator };

    const resp = try server.health(&ctx, HealthRequest{});
    try testing.expect(mock.health_called);
    try testing.expectEqualStrings("serving", resp.status);
}

test "unary: server dispatch Echo (same type req/resp)" {
    const MockImpl = struct {
        pub fn ping(_: *@This(), _: *rpc.Context, _: PingRequest) rpc.RpcError!PingResponse {
            return PingResponse{};
        }

        pub fn get_item(_: *@This(), _: *rpc.Context, _: GetItemRequest) rpc.RpcError!GetItemResponse {
            return GetItemResponse{};
        }

        pub fn health(_: *@This(), _: *rpc.Context, _: HealthRequest) rpc.RpcError!HealthResponse {
            return HealthResponse{};
        }

        pub fn echo(_: *@This(), _: *rpc.Context, req: EchoMessage) rpc.RpcError!EchoMessage {
            return EchoMessage{ .text = req.text, .code = req.code + 1 };
        }

        pub fn rpc_server(self: *@This()) UnaryService.Server {
            return .{ .ptr = self, .vtable = &UnaryService.Server.gen_vtable(@This()) };
        }
    };

    var mock = MockImpl{};
    const server = mock.rpc_server();
    var ctx = rpc.Context{ .allocator = testing.allocator };

    const resp = try server.echo(&ctx, EchoMessage{ .text = "test", .code = 10 });
    try testing.expectEqualStrings("test", resp.text);
    try testing.expectEqual(@as(i32, 11), resp.code);
}

test "streaming: server dispatch unary method" {
    const MockImpl = struct {
        pub fn unary_call(_: *@This(), _: *rpc.Context, req: StreamRequest) rpc.RpcError!StreamResponse {
            return StreamResponse{ .result = req.query, .index = 1 };
        }

        pub fn server_side(_: *@This(), _: *rpc.Context, _: StreamRequest, _: rpc.SendStream(StreamResponse)) rpc.RpcError!void {}

        pub fn client_side(_: *@This(), _: *rpc.Context, _: rpc.RecvStream(UploadChunk)) rpc.RpcError!UploadResult {
            return UploadResult{};
        }

        pub fn bidirectional(_: *@This(), _: *rpc.Context, _: rpc.RecvStream(ChatMessage), _: rpc.SendStream(ChatMessage)) rpc.RpcError!void {}

        pub fn rpc_server(self: *@This()) StreamingService.Server {
            return .{ .ptr = self, .vtable = &StreamingService.Server.gen_vtable(@This()) };
        }
    };

    var mock = MockImpl{};
    const server = mock.rpc_server();
    var ctx = rpc.Context{ .allocator = testing.allocator };

    const resp = try server.unary_call(&ctx, StreamRequest{ .query = "search" });
    try testing.expectEqualStrings("search", resp.result);
    try testing.expectEqual(@as(i32, 1), resp.index);
}

test "multi: FirstService server dispatch MethodOne" {
    const MockImpl = struct {
        pub fn method_one(_: *@This(), _: *rpc.Context, req: RequestA) rpc.RpcError!ResponseA {
            return ResponseA{ .greeting = req.name };
        }

        pub fn method_two(_: *@This(), _: *rpc.Context, _: RequestB) rpc.RpcError!ResponseB {
            return ResponseB{};
        }

        pub fn rpc_server(self: *@This()) FirstService.Server {
            return .{ .ptr = self, .vtable = &FirstService.Server.gen_vtable(@This()) };
        }
    };

    var mock = MockImpl{};
    const server = mock.rpc_server();
    var ctx = rpc.Context{ .allocator = testing.allocator };

    const r1 = try server.method_one(&ctx, RequestA{ .name = "world" });
    try testing.expectEqualStrings("world", r1.greeting);
}

test "multi: FirstService server dispatch MethodTwo" {
    const MockImpl = struct {
        pub fn method_one(_: *@This(), _: *rpc.Context, _: RequestA) rpc.RpcError!ResponseA {
            return ResponseA{};
        }

        pub fn method_two(_: *@This(), _: *rpc.Context, req: RequestB) rpc.RpcError!ResponseB {
            return ResponseB{ .result = req.value * 2 };
        }

        pub fn rpc_server(self: *@This()) FirstService.Server {
            return .{ .ptr = self, .vtable = &FirstService.Server.gen_vtable(@This()) };
        }
    };

    var mock = MockImpl{};
    const server = mock.rpc_server();
    var ctx = rpc.Context{ .allocator = testing.allocator };

    const r2 = try server.method_two(&ctx, RequestB{ .value = 21 });
    try testing.expectEqual(@as(i32, 42), r2.result);
}

test "multi: SecondService server dispatch Reverse" {
    const MockImpl = struct {
        pub fn reverse(_: *@This(), _: *rpc.Context, req: ResponseA) rpc.RpcError!RequestA {
            return RequestA{ .name = req.greeting };
        }

        pub fn transform(_: *@This(), _: *rpc.Context, _: RequestB) rpc.RpcError!ResponseB {
            return ResponseB{};
        }

        pub fn rpc_server(self: *@This()) SecondService.Server {
            return .{ .ptr = self, .vtable = &SecondService.Server.gen_vtable(@This()) };
        }
    };

    var mock = MockImpl{};
    const server = mock.rpc_server();
    var ctx = rpc.Context{ .allocator = testing.allocator };

    const r1 = try server.reverse(&ctx, ResponseA{ .greeting = "hi" });
    try testing.expectEqualStrings("hi", r1.name);
}

test "multi: SecondService server dispatch Transform" {
    const MockImpl = struct {
        pub fn reverse(_: *@This(), _: *rpc.Context, _: ResponseA) rpc.RpcError!RequestA {
            return RequestA{};
        }

        pub fn transform(_: *@This(), _: *rpc.Context, req: RequestB) rpc.RpcError!ResponseB {
            return ResponseB{ .result = req.value + 100 };
        }

        pub fn rpc_server(self: *@This()) SecondService.Server {
            return .{ .ptr = self, .vtable = &SecondService.Server.gen_vtable(@This()) };
        }
    };

    var mock = MockImpl{};
    const server = mock.rpc_server();
    var ctx = rpc.Context{ .allocator = testing.allocator };

    const r2 = try server.transform(&ctx, RequestB{ .value = 5 });
    try testing.expectEqual(@as(i32, 105), r2.result);
}

test "package: server dispatch Lookup" {
    const MockImpl = struct {
        pub fn lookup(_: *@This(), _: *rpc.Context, _: LookupRequest) rpc.RpcError!LookupResponse {
            return LookupResponse{ .value = "found_value", .found = true };
        }

        pub fn reverse_lookup(_: *@This(), _: *rpc.Context, _: LookupResponse) rpc.RpcError!LookupRequest {
            return LookupRequest{};
        }

        pub fn rpc_server(self: *@This()) PackagedService.Server {
            return .{ .ptr = self, .vtable = &PackagedService.Server.gen_vtable(@This()) };
        }
    };

    var mock = MockImpl{};
    const server = mock.rpc_server();
    var ctx = rpc.Context{ .allocator = testing.allocator };

    const resp = try server.lookup(&ctx, LookupRequest{ .key = "test" });
    try testing.expectEqualStrings("found_value", resp.value);
    try testing.expect(resp.found);
}

test "edge: single method server dispatch" {
    const MockImpl = struct {
        pub fn only_method(_: *@This(), _: *rpc.Context, req: EdgeRequest) rpc.RpcError!EdgeResponse {
            return EdgeResponse{ .id = req.id, .status = "ok" };
        }

        pub fn rpc_server(self: *@This()) SingleMethodService.Server {
            return .{ .ptr = self, .vtable = &SingleMethodService.Server.gen_vtable(@This()) };
        }
    };

    var mock = MockImpl{};
    const server = mock.rpc_server();
    var ctx = rpc.Context{ .allocator = testing.allocator };

    const resp = try server.only_method(&ctx, EdgeRequest{ .id = 99 });
    try testing.expectEqual(@as(i32, 99), resp.id);
    try testing.expectEqualStrings("ok", resp.status);
}

test "types: server dispatch with complex types" {
    const MockImpl = struct {
        pub fn process_complex(_: *@This(), _: *rpc.Context, req: ComplexRequest) rpc.RpcError!ComplexResponse {
            return ComplexResponse{ .id = 1, .priority = req.priority };
        }

        pub fn stream_complex(_: *@This(), _: *rpc.Context, _: ComplexRequest, _: rpc.SendStream(ComplexResponse)) rpc.RpcError!void {}

        pub fn rpc_server(self: *@This()) TypesService.Server {
            return .{ .ptr = self, .vtable = &TypesService.Server.gen_vtable(@This()) };
        }
    };

    var mock = MockImpl{};
    const server = mock.rpc_server();
    var ctx = rpc.Context{ .allocator = testing.allocator };

    const resp = try server.process_complex(&ctx, ComplexRequest{ .name = "test", .priority = .HIGH });
    try testing.expectEqual(@as(i32, 1), resp.id);
    try testing.expectEqual(Priority.HIGH, resp.priority);
}

// ══════════════════════════════════════════════════════════════════════
// Client & Server Comptime Checks (@hasDecl)
// ══════════════════════════════════════════════════════════════════════

test "unary: Client has expected methods" {
    try testing.expect(@hasDecl(UnaryService.Client, "ping"));
    try testing.expect(@hasDecl(UnaryService.Client, "get_item"));
    try testing.expect(@hasDecl(UnaryService.Client, "health"));
    try testing.expect(@hasDecl(UnaryService.Client, "echo"));
    try testing.expect(@hasDecl(UnaryService.Client, "init"));
}

test "unary: Server has expected methods" {
    try testing.expect(@hasDecl(UnaryService.Server, "ping"));
    try testing.expect(@hasDecl(UnaryService.Server, "get_item"));
    try testing.expect(@hasDecl(UnaryService.Server, "health"));
    try testing.expect(@hasDecl(UnaryService.Server, "echo"));
    try testing.expect(@hasDecl(UnaryService.Server, "gen_vtable"));
}

test "streaming: Client has expected methods" {
    try testing.expect(@hasDecl(StreamingService.Client, "unary_call"));
    try testing.expect(@hasDecl(StreamingService.Client, "server_side"));
    try testing.expect(@hasDecl(StreamingService.Client, "client_side"));
    try testing.expect(@hasDecl(StreamingService.Client, "bidirectional"));
}

test "streaming: Server has expected methods" {
    try testing.expect(@hasDecl(StreamingService.Server, "unary_call"));
    try testing.expect(@hasDecl(StreamingService.Server, "server_side"));
    try testing.expect(@hasDecl(StreamingService.Server, "client_side"));
    try testing.expect(@hasDecl(StreamingService.Server, "bidirectional"));
}

test "edge: Client has all 8 methods" {
    try testing.expect(@hasDecl(ManyMethodsService.Client, "create"));
    try testing.expect(@hasDecl(ManyMethodsService.Client, "update"));
    try testing.expect(@hasDecl(ManyMethodsService.Client, "delete"));
    try testing.expect(@hasDecl(ManyMethodsService.Client, "list"));
    try testing.expect(@hasDecl(ManyMethodsService.Client, "count"));
    try testing.expect(@hasDecl(ManyMethodsService.Client, "exists"));
    try testing.expect(@hasDecl(ManyMethodsService.Client, "validate"));
}

test "edge: Server has all 8 methods" {
    try testing.expect(@hasDecl(ManyMethodsService.Server, "create"));
    try testing.expect(@hasDecl(ManyMethodsService.Server, "update"));
    try testing.expect(@hasDecl(ManyMethodsService.Server, "delete"));
    try testing.expect(@hasDecl(ManyMethodsService.Server, "list"));
    try testing.expect(@hasDecl(ManyMethodsService.Server, "count"));
    try testing.expect(@hasDecl(ManyMethodsService.Server, "exists"));
    try testing.expect(@hasDecl(ManyMethodsService.Server, "validate"));
}

test "names: Client has snake_case methods" {
    try testing.expect(@hasDecl(NamingService.Client, "a"));
    try testing.expect(@hasDecl(NamingService.Client, "a_b"));
    try testing.expect(@hasDecl(NamingService.Client, "get_h_t_t_p_response"));
    try testing.expect(@hasDecl(NamingService.Client, "do_x_m_l_parsing"));
    try testing.expect(@hasDecl(NamingService.Client, "simple_call"));
    try testing.expect(@hasDecl(NamingService.Client, "x"));
    try testing.expect(@hasDecl(NamingService.Client, "get_user_by_i_d"));
}

test "names: Server has snake_case methods" {
    try testing.expect(@hasDecl(NamingService.Server, "a"));
    try testing.expect(@hasDecl(NamingService.Server, "a_b"));
    try testing.expect(@hasDecl(NamingService.Server, "get_h_t_t_p_response"));
    try testing.expect(@hasDecl(NamingService.Server, "do_x_m_l_parsing"));
    try testing.expect(@hasDecl(NamingService.Server, "simple_call"));
    try testing.expect(@hasDecl(NamingService.Server, "x"));
    try testing.expect(@hasDecl(NamingService.Server, "get_user_by_i_d"));
}

// ══════════════════════════════════════════════════════════════════════
// Server Error Propagation
// ══════════════════════════════════════════════════════════════════════

test "unary: server error propagation" {
    const MockImpl = struct {
        pub fn ping(_: *@This(), _: *rpc.Context, _: PingRequest) rpc.RpcError!PingResponse {
            return error.status_error;
        }

        pub fn get_item(_: *@This(), _: *rpc.Context, _: GetItemRequest) rpc.RpcError!GetItemResponse {
            return GetItemResponse{};
        }

        pub fn health(_: *@This(), _: *rpc.Context, _: HealthRequest) rpc.RpcError!HealthResponse {
            return HealthResponse{};
        }

        pub fn echo(_: *@This(), _: *rpc.Context, _: EchoMessage) rpc.RpcError!EchoMessage {
            return EchoMessage{};
        }

        pub fn rpc_server(self: *@This()) UnaryService.Server {
            return .{ .ptr = self, .vtable = &UnaryService.Server.gen_vtable(@This()) };
        }
    };

    var mock = MockImpl{};
    const server = mock.rpc_server();
    var ctx = rpc.Context{ .allocator = testing.allocator };

    const result = server.ping(&ctx, PingRequest{ .payload = "fail" });
    try testing.expectError(error.status_error, result);
}
