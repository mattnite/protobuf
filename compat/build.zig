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

    const test_step = b.step("test", "Run compat tests");
    test_step.dependOn(&b.addRunArtifact(compat_test).step);
    test_step.dependOn(&b.addRunArtifact(service_test).step);
}
