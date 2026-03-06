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

    // AFL++ fuzz harness (only configured when -Dfuzz-target is provided)
    const fuzz_target = b.option([]const u8, "fuzz-target", "Fuzz target to build (e.g. lexer, parser, varint_decode)");
    const llvm_config_path = b.option([]const u8, "llvm-config-path", "Path to llvm-config (default: search PATH)");

    const fuzz_step = b.step("fuzz", "Build AFL++ fuzz harness");

    if (fuzz_target) |ft| {
        const fuzz_options = b.addOptions();
        fuzz_options.addOption([]const u8, "fuzz_target", ft);

        const fuzz_obj = b.addObject(.{
            .name = "protobuf-fuzz",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/fuzz_harness.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "protobuf", .module = protobuf_mod },
                    .{ .name = "build_options", .module = fuzz_options.createModule() },
                },
            }),
        });
        fuzz_obj.root_module.stack_check = false;
        fuzz_obj.root_module.link_libc = true;

        if (b.findProgram(&.{"afl-cc"}, &.{})) |_| {
            const afl = @import("afl_kit");
            const llvm_cfg: ?[]const []const u8 = if (llvm_config_path) |p| &.{p} else null;
            if (afl.addInstrumentedExe(b, target, optimize, llvm_cfg, true, fuzz_obj, &.{})) |fuzz_exe| {
                const install = b.addInstallBinFile(fuzz_exe, "protobuf-fuzz");
                fuzz_step.dependOn(&install.step);
            }
        } else |_| {}

        // Plain replay binary (no AFL instrumentation) for crash triage
        const replay_options = b.addOptions();
        replay_options.addOption([]const u8, "fuzz_target", ft);

        const replay_exe = b.addExecutable(.{
            .name = "fuzz-replay",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/fuzz_harness.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "protobuf", .module = protobuf_mod },
                    .{ .name = "build_options", .module = replay_options.createModule() },
                },
            }),
        });
        const replay_step = b.step("fuzz-replay", "Build replay binary for crash triage");
        replay_step.dependOn(&b.addInstallArtifact(replay_exe, .{}).step);
    }
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
