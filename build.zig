const std = @import("std");
pub const GenerateStep = @import("src/GenerateStep.zig");

comptime {
    _ = &GenerateStep.create;
    _ = &GenerateStep.getModule;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("protobuf", .{
        .root_source_file = b.path("src/protobuf.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protobuf.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
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
