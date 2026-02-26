const std = @import("std");
const testing = std.testing;
const ast = @import("../proto/ast.zig");
const Emitter = @import("emitter.zig").Emitter;
const types = @import("types.zig");

/// Generate a complete service definition including descriptor, Server, and Client.
pub fn emit_service(e: *Emitter, service: ast.Service, package: ?[]const u8) !void {
    try e.print("pub const {s} = struct", .{service.name});
    try e.open_brace();

    try emit_service_descriptor(e, service, package);
    try e.blank_line();

    try emit_server(e, service);
    try e.blank_line();

    try emit_client(e, service, package);

    try e.close_brace();
}

// ── Helpers ──────────────────────────────────────────────────────────

fn pascal_to_snake(name: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    for (name, 0..) |c, j| {
        if (std.ascii.isUpper(c)) {
            if (j > 0) {
                buf[i] = '_';
                i += 1;
            }
            buf[i] = std.ascii.toLower(c);
        } else {
            buf[i] = c;
        }
        i += 1;
    }
    return buf[0..i];
}

fn qualified_service_name(package: ?[]const u8, service_name: []const u8, buf: []u8) []const u8 {
    if (package) |pkg| {
        if (pkg.len > 0) {
            return std.fmt.bufPrint(buf, "{s}.{s}", .{ pkg, service_name }) catch unreachable;
        }
    }
    return service_name;
}

fn full_method_path(package: ?[]const u8, service_name: []const u8, method_name: []const u8, buf: []u8) []const u8 {
    if (package) |pkg| {
        if (pkg.len > 0) {
            return std.fmt.bufPrint(buf, "/{s}.{s}/{s}", .{ pkg, service_name, method_name }) catch unreachable;
        }
    }
    return std.fmt.bufPrint(buf, "/{s}/{s}", .{ service_name, method_name }) catch unreachable;
}

// ── Service Descriptor ──────────────────────────────────────────────

fn emit_service_descriptor(e: *Emitter, service: ast.Service, package: ?[]const u8) !void {
    var name_buf: [512]u8 = undefined;
    const qual_name = qualified_service_name(package, service.name, &name_buf);

    try e.print("pub const service_descriptor = rpc.ServiceDescriptor{{\n", .{});
    e.indent_level += 1;
    try e.print(".name = \"{s}\",\n", .{qual_name});
    try e.print(".methods = &.{{\n", .{});
    e.indent_level += 1;

    for (service.methods) |method| {
        var path_buf: [512]u8 = undefined;
        const fpath = full_method_path(package, service.name, method.name, &path_buf);
        try e.print(".{{ .name = \"{s}\", .full_path = \"{s}\", .client_streaming = {}, .server_streaming = {} }},\n", .{
            method.name,
            fpath,
            method.client_streaming,
            method.server_streaming,
        });
    }

    e.indent_level -= 1;
    try e.print("}},\n", .{});
    e.indent_level -= 1;
    try e.print("}};\n", .{});
}

// ── Server ──────────────────────────────────────────────────────────

fn emit_server(e: *Emitter, service: ast.Service) !void {
    try e.print("pub const Server = struct", .{});
    try e.open_brace();

    try e.print("ptr: *anyopaque,\n", .{});
    try e.print("vtable: *const VTable,\n", .{});
    try e.blank_line();

    try emit_server_vtable(e, service);
    try e.blank_line();

    for (service.methods) |method| {
        try emit_server_dispatch(e, method);
        try e.blank_line();
    }

    try emit_server_init(e);
    try e.blank_line();

    try emit_server_gen_vtable(e, service);

    try e.close_brace();
}

fn emit_server_vtable(e: *Emitter, service: ast.Service) !void {
    try e.print("pub const VTable = struct", .{});
    try e.open_brace();

    for (service.methods) |method| {
        var snake_buf: [256]u8 = undefined;
        const snake_name = pascal_to_snake(method.name, &snake_buf);
        const escaped = types.escape_zig_keyword(snake_name);

        if (!method.client_streaming and !method.server_streaming) {
            // Unary
            try e.print("{f}: *const fn (*anyopaque, *rpc.Context, {s}) rpc.RpcError!{s},\n", .{
                escaped, method.input_type, method.output_type,
            });
        } else if (!method.client_streaming and method.server_streaming) {
            // Server streaming
            try e.print("{f}: *const fn (*anyopaque, *rpc.Context, {s}, rpc.SendStream({s})) rpc.RpcError!void,\n", .{
                escaped, method.input_type, method.output_type,
            });
        } else if (method.client_streaming and !method.server_streaming) {
            // Client streaming
            try e.print("{f}: *const fn (*anyopaque, *rpc.Context, rpc.RecvStream({s})) rpc.RpcError!{s},\n", .{
                escaped, method.input_type, method.output_type,
            });
        } else {
            // Bidi streaming
            try e.print("{f}: *const fn (*anyopaque, *rpc.Context, rpc.RecvStream({s}), rpc.SendStream({s})) rpc.RpcError!void,\n", .{
                escaped, method.input_type, method.output_type,
            });
        }
    }

    try e.close_brace();
}

fn emit_server_dispatch(e: *Emitter, method: ast.Method) !void {
    var snake_buf: [256]u8 = undefined;
    const snake_name = pascal_to_snake(method.name, &snake_buf);
    const escaped = types.escape_zig_keyword(snake_name);

    if (!method.client_streaming and !method.server_streaming) {
        // Unary
        try e.print("pub fn {f}(self: Server, ctx: *rpc.Context, req: {s}) rpc.RpcError!{s}", .{
            escaped, method.input_type, method.output_type,
        });
        try e.open_brace();
        try e.print("return self.vtable.{f}(self.ptr, ctx, req);\n", .{escaped});
        try e.close_brace_nosemi();
    } else if (!method.client_streaming and method.server_streaming) {
        // Server streaming
        try e.print("pub fn {f}(self: Server, ctx: *rpc.Context, req: {s}, stream: rpc.SendStream({s})) rpc.RpcError!void", .{
            escaped, method.input_type, method.output_type,
        });
        try e.open_brace();
        try e.print("return self.vtable.{f}(self.ptr, ctx, req, stream);\n", .{escaped});
        try e.close_brace_nosemi();
    } else if (method.client_streaming and !method.server_streaming) {
        // Client streaming
        try e.print("pub fn {f}(self: Server, ctx: *rpc.Context, stream: rpc.RecvStream({s})) rpc.RpcError!{s}", .{
            escaped, method.input_type, method.output_type,
        });
        try e.open_brace();
        try e.print("return self.vtable.{f}(self.ptr, ctx, stream);\n", .{escaped});
        try e.close_brace_nosemi();
    } else {
        // Bidi streaming
        try e.print("pub fn {f}(self: Server, ctx: *rpc.Context, recv: rpc.RecvStream({s}), send: rpc.SendStream({s})) rpc.RpcError!void", .{
            escaped, method.input_type, method.output_type,
        });
        try e.open_brace();
        try e.print("return self.vtable.{f}(self.ptr, ctx, recv, send);\n", .{escaped});
        try e.close_brace_nosemi();
    }
}

fn emit_server_init(e: *Emitter) !void {
    try e.print("pub fn init(impl: anytype) Server", .{});
    try e.open_brace();
    try e.print("const Ptr = @TypeOf(impl);\n", .{});
    try e.print("const Impl = @typeInfo(Ptr).pointer.child;\n", .{});
    try e.blank_line();
    try e.print("return .{{\n", .{});
    e.indent_level += 1;
    try e.print(".ptr = impl,\n", .{});
    try e.print(".vtable = &gen_vtable(Impl),\n", .{});
    e.indent_level -= 1;
    try e.print("}};\n", .{});
    try e.close_brace_nosemi();
}

fn emit_server_gen_vtable(e: *Emitter, service: ast.Service) !void {
    try e.print("fn gen_vtable(comptime Impl: type) VTable", .{});
    try e.open_brace();
    try e.print("return .{{\n", .{});
    e.indent_level += 1;

    for (service.methods) |method| {
        try emit_gen_vtable_entry(e, method);
    }

    e.indent_level -= 1;
    try e.print("}};\n", .{});
    try e.close_brace_nosemi();
}

fn emit_gen_vtable_entry(e: *Emitter, method: ast.Method) !void {
    var snake_buf: [256]u8 = undefined;
    const snake_name = pascal_to_snake(method.name, &snake_buf);
    const escaped = types.escape_zig_keyword(snake_name);

    // Open: .field_name = struct {
    try e.print(".{f} = struct", .{escaped});
    try e.open_brace();

    if (!method.client_streaming and !method.server_streaming) {
        // Unary
        try e.print("fn call(p: *anyopaque, ctx: *rpc.Context, req: {s}) rpc.RpcError!{s}", .{
            method.input_type, method.output_type,
        });
        try e.open_brace();
        try e.print("const self: *Impl = @ptrCast(@alignCast(p));\n", .{});
        try e.print("return self.{f}(ctx, req);\n", .{escaped});
        try e.close_brace_nosemi();
    } else if (!method.client_streaming and method.server_streaming) {
        // Server streaming
        try e.print("fn call(p: *anyopaque, ctx: *rpc.Context, req: {s}, s: rpc.SendStream({s})) rpc.RpcError!void", .{
            method.input_type, method.output_type,
        });
        try e.open_brace();
        try e.print("const self: *Impl = @ptrCast(@alignCast(p));\n", .{});
        try e.print("return self.{f}(ctx, req, s);\n", .{escaped});
        try e.close_brace_nosemi();
    } else if (method.client_streaming and !method.server_streaming) {
        // Client streaming
        try e.print("fn call(p: *anyopaque, ctx: *rpc.Context, s: rpc.RecvStream({s})) rpc.RpcError!{s}", .{
            method.input_type, method.output_type,
        });
        try e.open_brace();
        try e.print("const self: *Impl = @ptrCast(@alignCast(p));\n", .{});
        try e.print("return self.{f}(ctx, s);\n", .{escaped});
        try e.close_brace_nosemi();
    } else {
        // Bidi streaming
        try e.print("fn call(p: *anyopaque, ctx: *rpc.Context, recv: rpc.RecvStream({s}), send: rpc.SendStream({s})) rpc.RpcError!void", .{
            method.input_type, method.output_type,
        });
        try e.open_brace();
        try e.print("const self: *Impl = @ptrCast(@alignCast(p));\n", .{});
        try e.print("return self.{f}(ctx, recv, send);\n", .{escaped});
        try e.close_brace_nosemi();
    }

    // Close: }.call,
    e.indent_level -= 1;
    try e.indent();
    try e.print_raw("}}.call,\n", .{});
}

// ── Client ──────────────────────────────────────────────────────────

fn emit_client(e: *Emitter, service: ast.Service, package: ?[]const u8) !void {
    try e.print("pub const Client = struct", .{});
    try e.open_brace();

    try e.print("channel: rpc.Channel,\n", .{});
    try e.blank_line();

    try e.print("pub fn init(channel: rpc.Channel) Client", .{});
    try e.open_brace();
    try e.print("return .{{ .channel = channel }};\n", .{});
    try e.close_brace_nosemi();
    try e.blank_line();

    for (service.methods) |method| {
        try emit_client_method(e, method, service.name, package);
        try e.blank_line();
    }

    try e.close_brace();
}

fn emit_client_method(e: *Emitter, method: ast.Method, service_name: []const u8, package: ?[]const u8) !void {
    var snake_buf: [256]u8 = undefined;
    const snake_name = pascal_to_snake(method.name, &snake_buf);
    const escaped = types.escape_zig_keyword(snake_name);
    var path_buf: [512]u8 = undefined;
    const fpath = full_method_path(package, service_name, method.name, &path_buf);

    if (!method.client_streaming and !method.server_streaming) {
        // Unary
        try e.print("pub fn {f}(self: Client, ctx: *rpc.Context, req: {s}) rpc.RpcError!{s}", .{
            escaped, method.input_type, method.output_type,
        });
        try e.open_brace();
        try e.print("return self.channel.unary_call({s}, \"{s}\", ctx, req);\n", .{
            method.output_type, fpath,
        });
        try e.close_brace_nosemi();
    } else if (!method.client_streaming and method.server_streaming) {
        // Server streaming
        try e.print("pub fn {f}(self: Client, ctx: *rpc.Context, req: {s}) rpc.RpcError!rpc.RecvStream({s})", .{
            escaped, method.input_type, method.output_type,
        });
        try e.open_brace();
        try e.print("return self.channel.server_stream_call({s}, \"{s}\", ctx, req);\n", .{
            method.output_type, fpath,
        });
        try e.close_brace_nosemi();
    } else if (method.client_streaming and !method.server_streaming) {
        // Client streaming
        try e.print("pub fn {f}(self: Client, ctx: *rpc.Context) rpc.RpcError!rpc.ClientStreamCall({s}, {s})", .{
            escaped, method.input_type, method.output_type,
        });
        try e.open_brace();
        try e.print("return self.channel.client_stream_call({s}, {s}, \"{s}\", ctx);\n", .{
            method.input_type, method.output_type, fpath,
        });
        try e.close_brace_nosemi();
    } else {
        // Bidi streaming
        try e.print("pub fn {f}(self: Client, ctx: *rpc.Context) rpc.RpcError!rpc.BidiStreamCall({s}, {s})", .{
            escaped, method.input_type, method.output_type,
        });
        try e.open_brace();
        try e.print("return self.channel.bidi_stream_call({s}, {s}, \"{s}\", ctx);\n", .{
            method.input_type, method.output_type, fpath,
        });
        try e.close_brace_nosemi();
    }
}

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

const loc = ast.SourceLocation{ .file = "", .line = 0, .column = 0 };

fn make_method(name: []const u8, input: []const u8, output: []const u8, cs: bool, ss: bool) ast.Method {
    return .{
        .name = name,
        .input_type = input,
        .output_type = output,
        .client_streaming = cs,
        .server_streaming = ss,
        .options = &.{},
        .location = loc,
    };
}

fn expect_contains(output: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, output, expected) == null) {
        std.debug.print("\n=== EXPECTED (not found) ===\n{s}\n=== IN OUTPUT ===\n{s}\n=== END ===\n", .{ expected, output });
        return error.TestExpectedEqual;
    }
}

test "pascal_to_snake: conversions" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("get_feature", pascal_to_snake("GetFeature", &buf));
    try testing.expectEqualStrings("list_features", pascal_to_snake("ListFeatures", &buf));
    try testing.expectEqualStrings("route_chat", pascal_to_snake("RouteChat", &buf));
    try testing.expectEqualStrings("unary", pascal_to_snake("Unary", &buf));
    try testing.expectEqualStrings("do_thing", pascal_to_snake("DoThing", &buf));
    try testing.expectEqualStrings("record_route", pascal_to_snake("RecordRoute", &buf));
}

test "emit_service: unary method" {
    var methods = [_]ast.Method{
        make_method("GetFeature", "Point", "Feature", false, false),
    };
    const service: ast.Service = .{
        .name = "RouteGuide",
        .methods = &methods,
        .options = &.{},
        .location = loc,
    };

    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    try emit_service(&e, service, "routeguide");
    const output = e.get_output();

    // Service struct
    try expect_contains(output, "pub const RouteGuide = struct");

    // Descriptor
    try expect_contains(output, "pub const service_descriptor = rpc.ServiceDescriptor{");
    try expect_contains(output, ".name = \"routeguide.RouteGuide\"");
    try expect_contains(output, ".full_path = \"/routeguide.RouteGuide/GetFeature\"");
    try expect_contains(output, ".client_streaming = false");
    try expect_contains(output, ".server_streaming = false");

    // Server
    try expect_contains(output, "pub const Server = struct");
    try expect_contains(output, "ptr: *anyopaque,");
    try expect_contains(output, "vtable: *const VTable,");
    try expect_contains(output, "get_feature: *const fn (*anyopaque, *rpc.Context, Point) rpc.RpcError!Feature,");
    try expect_contains(output, "pub fn get_feature(self: Server, ctx: *rpc.Context, req: Point) rpc.RpcError!Feature");
    try expect_contains(output, "return self.vtable.get_feature(self.ptr, ctx, req);");
    try expect_contains(output, "pub fn init(impl: anytype) Server");
    try expect_contains(output, "fn gen_vtable(comptime Impl: type) VTable");
    try expect_contains(output, "const self: *Impl = @ptrCast(@alignCast(p));");
    try expect_contains(output, "return self.get_feature(ctx, req);");

    // Client
    try expect_contains(output, "pub const Client = struct");
    try expect_contains(output, "channel: rpc.Channel,");
    try expect_contains(output, "pub fn init(channel: rpc.Channel) Client");
    try expect_contains(output, "pub fn get_feature(self: Client, ctx: *rpc.Context, req: Point) rpc.RpcError!Feature");
    try expect_contains(output, "return self.channel.unary_call(Feature, \"/routeguide.RouteGuide/GetFeature\", ctx, req);");
}

test "emit_service: all streaming modes" {
    var methods = [_]ast.Method{
        make_method("Unary", "Req", "Resp", false, false),
        make_method("ServerStream", "Req", "Resp", false, true),
        make_method("ClientStream", "Req", "Resp", true, false),
        make_method("BidiStream", "Req", "Resp", true, true),
    };
    const service: ast.Service = .{
        .name = "TestService",
        .methods = &methods,
        .options = &.{},
        .location = loc,
    };

    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    try emit_service(&e, service, null);
    const output = e.get_output();

    // Server VTable signatures
    try expect_contains(output, "unary: *const fn (*anyopaque, *rpc.Context, Req) rpc.RpcError!Resp,");
    try expect_contains(output, "server_stream: *const fn (*anyopaque, *rpc.Context, Req, rpc.SendStream(Resp)) rpc.RpcError!void,");
    try expect_contains(output, "client_stream: *const fn (*anyopaque, *rpc.Context, rpc.RecvStream(Req)) rpc.RpcError!Resp,");
    try expect_contains(output, "bidi_stream: *const fn (*anyopaque, *rpc.Context, rpc.RecvStream(Req), rpc.SendStream(Resp)) rpc.RpcError!void,");

    // Server dispatch methods
    try expect_contains(output, "pub fn unary(self: Server, ctx: *rpc.Context, req: Req) rpc.RpcError!Resp");
    try expect_contains(output, "pub fn server_stream(self: Server, ctx: *rpc.Context, req: Req, stream: rpc.SendStream(Resp)) rpc.RpcError!void");
    try expect_contains(output, "pub fn client_stream(self: Server, ctx: *rpc.Context, stream: rpc.RecvStream(Req)) rpc.RpcError!Resp");
    try expect_contains(output, "pub fn bidi_stream(self: Server, ctx: *rpc.Context, recv: rpc.RecvStream(Req), send: rpc.SendStream(Resp)) rpc.RpcError!void");

    // Client return types
    try expect_contains(output, "pub fn unary(self: Client, ctx: *rpc.Context, req: Req) rpc.RpcError!Resp");
    try expect_contains(output, "pub fn server_stream(self: Client, ctx: *rpc.Context, req: Req) rpc.RpcError!rpc.RecvStream(Resp)");
    try expect_contains(output, "pub fn client_stream(self: Client, ctx: *rpc.Context) rpc.RpcError!rpc.ClientStreamCall(Req, Resp)");
    try expect_contains(output, "pub fn bidi_stream(self: Client, ctx: *rpc.Context) rpc.RpcError!rpc.BidiStreamCall(Req, Resp)");

    // Full paths without package
    try expect_contains(output, "/TestService/Unary");
    try expect_contains(output, "/TestService/ServerStream");
    try expect_contains(output, "/TestService/ClientStream");
    try expect_contains(output, "/TestService/BidiStream");
}

test "emit_service: without package" {
    var methods = [_]ast.Method{
        make_method("DoThing", "Req", "Resp", false, false),
    };
    const service: ast.Service = .{
        .name = "Svc",
        .methods = &methods,
        .options = &.{},
        .location = loc,
    };

    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    try emit_service(&e, service, null);
    const output = e.get_output();

    try expect_contains(output, ".name = \"Svc\"");
    try expect_contains(output, ".full_path = \"/Svc/DoThing\"");
}

test "emit_service: with package" {
    var methods = [_]ast.Method{
        make_method("DoThing", "Req", "Resp", false, false),
    };
    const service: ast.Service = .{
        .name = "Svc",
        .methods = &methods,
        .options = &.{},
        .location = loc,
    };

    var e = Emitter.init(testing.allocator);
    defer e.deinit();

    try emit_service(&e, service, "pkg");
    const output = e.get_output();

    try expect_contains(output, ".name = \"pkg.Svc\"");
    try expect_contains(output, ".full_path = \"/pkg.Svc/DoThing\"");
}
