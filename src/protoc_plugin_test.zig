const std = @import("std");
const testing = std.testing;
const protobuf = @import("protobuf");
const proto = protobuf.proto;
const codegen_mod = protobuf.codegen;
const ast = proto.ast;
const build_options = @import("build_options");

// ── Standalone Pipeline ──────────────────────────────────────────────

fn run_standalone_pipeline(allocator: std.mem.Allocator, proto_source: []const u8, filename: []const u8) ![]const u8 {
    var diags: proto.parser.DiagnosticList = .empty;
    const lex = proto.lexer.Lexer.init(proto_source, filename);
    var parser = proto.parser.Parser.init(lex, allocator, &diags);
    const file = try parser.parse_file();

    // For simple files without imports, link with no-op loader
    var linker = proto.linker.Linker.init(allocator, &diags, proto.linker.FileLoader.wrap(struct {
        fn load(_: []const u8, _: std.mem.Allocator) proto.linker.LinkError![]const u8 {
            return error.LinkFailed;
        }
    }.load));
    var files_arr = [_]ast.File{file};
    const resolved = try linker.link(&files_arr);

    return try codegen_mod.generate_file(allocator, resolved.files[0].source, filename);
}

// ── Protoc Plugin Pipeline ───────────────────────────────────────────

fn run_protoc_plugin(allocator: std.mem.Allocator, proto_dir: []const u8, proto_file: []const u8) ![]const u8 {
    // Create a temp directory for output
    var tmp_dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_dir_path = try make_temp_dir(&tmp_dir_path_buf);
    defer {
        // Clean up temp dir
        std.fs.deleteTreeAbsolute(tmp_dir_path) catch {};
    }

    const plugin_path: []const u8 = build_options.plugin_path;
    const plugin_arg = try std.fmt.allocPrint(allocator, "--plugin=protoc-gen-zig={s}", .{plugin_path});
    defer allocator.free(plugin_arg);

    const zig_out_arg = try std.fmt.allocPrint(allocator, "--zig_out={s}", .{tmp_dir_path});
    defer allocator.free(zig_out_arg);

    const proto_path_arg = try std.fmt.allocPrint(allocator, "--proto_path={s}", .{proto_dir});
    defer allocator.free(proto_path_arg);

    var child = std.process.Child.init(
        &.{ "protoc", plugin_arg, zig_out_arg, proto_path_arg, proto_file },
        allocator,
    );
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    try child.spawn();

    var stdout_buf: std.ArrayList(u8) = .empty;
    var stderr_buf: std.ArrayList(u8) = .empty;
    try child.collectOutput(allocator, &stdout_buf, &stderr_buf, 10 * 1024 * 1024);
    defer stdout_buf.deinit(allocator);
    defer stderr_buf.deinit(allocator);

    const term = try child.wait();
    if (term.Exited != 0) {
        std.debug.print("\nprotoc failed (exit code {d}):\nstderr: {s}\nstdout: {s}\n", .{
            term.Exited,
            stderr_buf.items,
            stdout_buf.items,
        });
        return error.ProtocFailed;
    }

    // Find and read the generated .zig file in the temp directory
    // Walk the temp dir to find any .zig file
    const content = try find_and_read_zig_file(allocator, tmp_dir_path);
    return content;
}

fn make_temp_dir(buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const ts: u64 = @intCast(std.time.nanoTimestamp());
    const path = std.fmt.bufPrint(buf, "/tmp/protoc-zig-test-{d}", .{ts}) catch unreachable;
    std.fs.makeDirAbsolute(path) catch |err| {
        std.debug.print("Failed to create temp dir '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    return path;
}

fn find_and_read_zig_file(allocator: std.mem.Allocator, dir_path: []const u8) ![]const u8 {
    // Try to walk the directory tree to find .zig files
    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zig")) {
            const file = try entry.dir.openFile(entry.basename, .{});
            defer file.close();
            return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
        }
    }

    return error.NoZigFileGenerated;
}

// ── Comparison ───────────────────────────────────────────────────────

fn normalize_output(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    // Strip trailing whitespace from each line and normalize line endings
    var result: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try result.append(allocator, '\n');
        first = false;
        // Strip trailing whitespace
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        try result.appendSlice(allocator, trimmed);
    }
    return try result.toOwnedSlice(allocator);
}

fn compare_outputs(standalone: []const u8, plugin: []const u8, proto_file: []const u8) !void {
    if (std.mem.eql(u8, standalone, plugin)) return;

    // Find first difference
    const min_len = @min(standalone.len, plugin.len);
    var diff_pos: usize = 0;
    for (0..min_len) |i| {
        if (standalone[i] != plugin[i]) {
            diff_pos = i;
            break;
        }
    } else {
        diff_pos = min_len;
    }

    // Find line number
    var line_num: usize = 1;
    for (standalone[0..@min(diff_pos, standalone.len)]) |c| {
        if (c == '\n') line_num += 1;
    }

    // Show context around the diff
    const ctx_start = if (diff_pos > 100) diff_pos - 100 else 0;
    const standalone_ctx_end = @min(diff_pos + 100, standalone.len);
    const plugin_ctx_end = @min(diff_pos + 100, plugin.len);

    std.debug.print(
        \\
        \\=== OUTPUT MISMATCH for {s} ===
        \\First difference at byte {d} (line ~{d})
        \\Standalone length: {d}, Plugin length: {d}
        \\
        \\--- Standalone (around diff) ---
        \\{s}
        \\
        \\--- Plugin (around diff) ---
        \\{s}
        \\=== END ===
        \\
    , .{
        proto_file,
        diff_pos,
        line_num,
        standalone.len,
        plugin.len,
        standalone[ctx_start..standalone_ctx_end],
        plugin[ctx_start..plugin_ctx_end],
    });

    return error.OutputMismatch;
}

// ── Tests ────────────────────────────────────────────────────────────

fn run_comparison_test(proto_file: []const u8) !void {
    const allocator = testing.allocator;

    const proto_dir: []const u8 = build_options.proto_dir;

    // Read the .proto file
    const proto_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ proto_dir, proto_file });
    defer allocator.free(proto_path);

    const proto_source = blk: {
        const file = try std.fs.openFileAbsolute(proto_path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    };
    defer allocator.free(proto_source);

    // Run standalone pipeline
    var standalone_arena = std.heap.ArenaAllocator.init(allocator);
    defer standalone_arena.deinit();
    const standalone_raw = try run_standalone_pipeline(standalone_arena.allocator(), proto_source, proto_file);
    const standalone = try normalize_output(allocator, standalone_raw);
    defer allocator.free(standalone);

    // Run protoc plugin pipeline
    const plugin_raw = try run_protoc_plugin(allocator, proto_dir, proto_file);
    defer allocator.free(plugin_raw);
    const plugin = try normalize_output(allocator, plugin_raw);
    defer allocator.free(plugin);

    // Compare
    try compare_outputs(standalone, plugin, proto_file);
}

test "protoc plugin: scalar3.proto matches standalone" {
    try run_comparison_test("scalar3.proto");
}

test "protoc plugin: enum3.proto matches standalone" {
    try run_comparison_test("enum3.proto");
}

test "protoc plugin: nested3.proto matches standalone" {
    try run_comparison_test("nested3.proto");
}

test "protoc plugin: oneof3.proto matches standalone" {
    try run_comparison_test("oneof3.proto");
}

test "protoc plugin: repeated3.proto matches standalone" {
    try run_comparison_test("repeated3.proto");
}

test "protoc plugin: map3.proto matches standalone" {
    try run_comparison_test("map3.proto");
}

test "protoc plugin: optional3.proto matches standalone" {
    try run_comparison_test("optional3.proto");
}

test "protoc plugin: required2.proto matches standalone" {
    try run_comparison_test("required2.proto");
}

test "protoc plugin: scalar2.proto matches standalone" {
    try run_comparison_test("scalar2.proto");
}
