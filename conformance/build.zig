const std = @import("std");
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const proto_dep = b.dependency("protobuf", .{});
    const proto_mod = protobuf.generate(b, proto_dep, .{
        .proto_sources = b.path("proto"),
    });

    const testee = b.addExecutable(.{
        .name = "conformance_testee",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_mod },
                .{ .name = "protobuf", .module = proto_dep.module("protobuf") },
            },
        }),
    });

    b.installArtifact(testee);

    const runner_path = b.option([]const u8, "conformance-runner", "Path to conformance_test_runner binary");
    if (runner_path) |path| {
        const run_step = b.addSystemCommand(&.{path});
        run_step.addArtifactArg(testee);

        const run = b.step("run", "Run conformance tests");
        run.dependOn(&run_step.step);
    }
}
