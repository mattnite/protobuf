const std = @import("std");
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const proto_dep = b.dependency("protobuf", .{});
    const proto_mod = protobuf.generate(b, proto_dep, .{
        .proto_sources = b.path("proto"),
    });

    const compat_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compat_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_mod },
                .{ .name = "protobuf", .module = proto_dep.module("protobuf") },
            },
        }),
    });

    const service_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/service_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_mod },
                .{ .name = "protobuf", .module = proto_dep.module("protobuf") },
            },
        }),
    });

    // ── Go binary builds ─────────────────────────────────────────
    const go_server = b.addSystemCommand(&.{ "go", "build", "-o" });
    const go_server_path = go_server.addOutputFileArg("rpcserver");
    go_server.addArg("./cmd/rpcserver");
    go_server.setCwd(b.path("go"));

    const go_client = b.addSystemCommand(&.{ "go", "build", "-o" });
    const go_client_path = go_client.addOutputFileArg("rpcclient");
    go_client.addArg("./cmd/rpcclient");
    go_client.setCwd(b.path("go"));

    // ── RPC pipe module ──────────────────────────────────────────
    const rpc_pipe_mod = b.createModule(.{
        .root_source_file = b.path("src/rpc_pipe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = proto_dep.module("protobuf") },
        },
    });

    // ── Build options for Go binary paths ────────────────────────
    const build_options = b.addOptions();
    build_options.addOptionPath("go_rpc_server", go_server_path);
    build_options.addOptionPath("go_rpc_client", go_client_path);

    // ── RPC integration test ────────────────────────────────────
    const rpc_integ_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rpc_integ_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_mod },
                .{ .name = "protobuf", .module = proto_dep.module("protobuf") },
                .{ .name = "rpc_pipe", .module = rpc_pipe_mod },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });

    const run_rpc_test = b.addRunArtifact(rpc_integ_test);
    const rpc_test_step = b.step("rpc-test", "Run RPC integration tests");
    rpc_test_step.dependOn(&run_rpc_test.step);

    const test_step = b.step("test", "Run compat tests");
    test_step.dependOn(&b.addRunArtifact(compat_test).step);
    test_step.dependOn(&b.addRunArtifact(service_test).step);
    test_step.dependOn(&run_rpc_test.step);
}
