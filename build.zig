const std = @import("std");
pub const GenerateStep = @import("src/GenerateStep.zig");

comptime {
    _ = &GenerateStep.create;
    _ = &GenerateStep.getModule;
}

/// Build the protobuf library, protoc-gen-zig plugin, tests, and benchmarks
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protobuf_mod = b.addModule("protobuf", .{
        .root_source_file = b.path("src/protobuf.zig"),
        .target = target,
        .optimize = optimize,
    });

    // protoc-gen-zig executable
    const protoc_gen_zig = b.addExecutable(.{
        .name = "protoc-gen-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protoc_gen_zig.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protobuf", .module = protobuf_mod },
            },
        }),
    });
    b.installArtifact(protoc_gen_zig);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protobuf.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // protoc plugin integration tests
    const protoc_test_options = b.addOptions();
    protoc_test_options.addOptionPath("plugin_path", protoc_gen_zig.getEmittedBin());
    protoc_test_options.addOptionPath("proto_dir", b.path("compat/proto"));

    const protoc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protoc_plugin_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protobuf", .module = protobuf_mod },
                .{ .name = "build_options", .module = protoc_test_options.createModule() },
            },
        }),
    });

    const protoc_test_step = b.step("protoc-test", "Run protoc plugin integration tests");
    protoc_test_step.dependOn(&b.addRunArtifact(protoc_tests).step);

    // Benchmark executable
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench).step);
}

/// Create a GenerateStep that compiles .proto files into importable Zig modules.
/// Call from a downstream project's build.zig:
///
///   const protobuf = @import("protobuf");
///   const proto_dep = b.dependency("protobuf", .{});
///   const proto_mod = protobuf.generate(b, proto_dep, .{
///       .proto_sources = b.path("proto/"),
///   });
///
pub fn generate(b: *std.Build, dep: *std.Build.Dependency, options: GenerateStep.Options) *std.Build.Module {
    const gen = GenerateStep.create(b, dep, options);
    return gen.getModule();
}
