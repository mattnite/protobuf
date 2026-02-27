const std = @import("std");
const proto = @import("proto.zig");
const codegen_mod = @import("codegen.zig");
const ast = proto.ast;

const GenerateStep = @This();

step: std.Build.Step,
proto_sources: std.Build.LazyPath,
import_paths: []const std.Build.LazyPath,
well_known_path: std.Build.LazyPath,
generated_directory: std.Build.GeneratedFile,
protobuf_mod: *std.Build.Module,

pub const Options = struct {
    /// Directory containing .proto sources (e.g., b.path("proto/"))
    proto_sources: std.Build.LazyPath,
    /// Additional import search paths for resolving proto imports
    import_paths: []const std.Build.LazyPath = &.{},
};

pub fn create(b: *std.Build, proto_dep: *std.Build.Dependency, options: Options) *GenerateStep {
    const self = b.allocator.create(GenerateStep) catch @panic("OOM");
    self.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = "protobuf generate",
            .owner = b,
            .makeFn = make,
        }),
        .proto_sources = options.proto_sources,
        .import_paths = b.allocator.dupe(std.Build.LazyPath, options.import_paths) catch @panic("OOM"),
        .well_known_path = proto_dep.path("src/well_known_protos"),
        .generated_directory = .{ .step = &self.step },
        .protobuf_mod = undefined,
    };

    self.protobuf_mod = b.createModule(.{
        .root_source_file = .{
            .generated = .{
                .file = &self.generated_directory,
                .sub_path = "root.zig",
            },
        },
        .imports = &.{
            .{
                .name = "protobuf",
                .module = proto_dep.module("protobuf"),
            },
        },
    });

    options.proto_sources.addStepDependencies(&self.step);
    for (options.import_paths) |ip| {
        ip.addStepDependencies(&self.step);
    }
    self.well_known_path.addStepDependencies(&self.step);

    return self;
}

pub fn getModule(self: *GenerateStep) *std.Build.Module {
    return self.protobuf_mod;
}

fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
    _ = options;
    const b = step.owner;
    const arena = b.allocator;
    const self: *GenerateStep = @fieldParentPtr("step", step);

    // Resolve proto source directory
    const src_path = self.proto_sources.getPath3(b, step);
    var src_dir = src_path.root_dir.handle.openDir(src_path.sub_path, .{}) catch |err| {
        return step.fail("cannot open proto source directory: {s}", .{@errorName(err)});
    };
    defer src_dir.close();

    // Discover and read all .proto files
    const ProtoSource = struct { filename: []const u8, content: []const u8 };
    var sources: std.ArrayListUnmanaged(ProtoSource) = .empty;

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".proto")) continue;

        const filename = try arena.dupe(u8, entry.name);
        const file = try src_dir.openFile(entry.name, .{});
        defer file.close();
        const content = try file.readToEndAlloc(arena, 10 * 1024 * 1024);
        try sources.append(arena, .{ .filename = filename, .content = content });
    }

    if (sources.items.len == 0) {
        return step.fail("no .proto files found in source directory", .{});
    }

    // Sort for deterministic ordering
    std.sort.pdq(ProtoSource, sources.items, {}, struct {
        fn f(_: void, a: ProtoSource, b_: ProtoSource) bool {
            return std.mem.order(u8, a.filename, b_.filename) == .lt;
        }
    }.f);

    // Parse all .proto files
    var diags: proto.parser.DiagnosticList = .empty;
    var parsed: std.ArrayListUnmanaged(ast.File) = .empty;

    for (sources.items) |src| {
        const lex = proto.lexer.Lexer.init(src.content, src.filename);
        var parser = proto.parser.Parser.init(lex, arena, &diags);
        const file = parser.parse_file() catch {
            reportErrors(step, diags.items);
            return error.MakeFailed;
        };
        try parsed.append(arena, file);
    }

    if (hasErrors(diags.items)) {
        reportErrors(step, diags.items);
        return error.MakeFailed;
    }

    // Set up search paths for import resolution
    var search_dirs: std.ArrayListUnmanaged(std.fs.Dir) = .empty;
    try search_dirs.append(arena, src_dir);

    var owned_dirs: std.ArrayListUnmanaged(std.fs.Dir) = .empty;
    for (self.import_paths) |ip| {
        const p = ip.getPath3(b, step);
        const dir = p.root_dir.handle.openDir(p.sub_path, .{}) catch continue;
        try owned_dirs.append(arena, dir);
        try search_dirs.append(arena, dir);
    }

    // Add well-known protos path (after user paths, so user overrides take priority)
    {
        const wk = self.well_known_path.getPath3(b, step);
        const wk_dir = wk.root_dir.handle.openDir(wk.sub_path, .{}) catch |err| {
            return step.fail("cannot open well-known protos directory: {s}", .{@errorName(err)});
        };
        try owned_dirs.append(arena, wk_dir);
        try search_dirs.append(arena, wk_dir);
    }

    defer for (owned_dirs.items) |*d| {
        d.close();
    };

    // Link all files
    var loader_ctx = ImportLoader{ .dirs = search_dirs.items };
    var linker = proto.linker.Linker.init(arena, &diags, .{
        .ptr = @ptrCast(&loader_ctx),
        .load_fn = ImportLoader.load,
    });

    const resolved = linker.link(parsed.items) catch {
        reportErrors(step, diags.items);
        return error.MakeFailed;
    };

    if (hasErrors(diags.items)) {
        reportErrors(step, diags.items);
        return error.MakeFailed;
    }

    // Generate Zig source for each resolved file
    const OutputFile = struct { path: []const u8, content: []const u8, mod_name: []const u8 };
    var outputs: std.ArrayListUnmanaged(OutputFile) = .empty;

    for (resolved.files, 0..) |rf, i| {
        const content = try codegen_mod.generate_file(arena, rf.source);
        const out_path = try codegen_mod.package_to_path(arena, rf.source.package, sources.items[i].filename);
        const mod_name = deriveModuleName(sources.items[i].filename);
        try outputs.append(arena, .{ .path = out_path, .content = content, .mod_name = mod_name });
    }

    // Generate root.zig that re-exports all generated modules
    var root: std.ArrayListUnmanaged(u8) = .empty;
    try root.appendSlice(arena, "// Generated by protobuf codegen\n");
    for (outputs.items) |of| {
        // pub const @"name" = @import("path");
        try root.appendSlice(arena, "pub const @\"");
        try root.appendSlice(arena, of.mod_name);
        try root.appendSlice(arena, "\" = @import(\"");
        try root.appendSlice(arena, of.path);
        try root.appendSlice(arena, "\");\n");
    }

    // Compute content hash for output directory name
    var hasher = std.hash.Wyhash.init(0);
    for (sources.items) |src| {
        hasher.update(src.filename);
        hasher.update(src.content);
    }
    const hash = hasher.final();
    var hash_buf: [32]u8 = undefined;
    const hash_hex = std.fmt.bufPrint(&hash_buf, "protobuf-{x:0>16}", .{hash}) catch unreachable;

    // Create output directory and write files
    self.generated_directory.path = try b.cache_root.join(arena, &.{hash_hex});

    var out_dir = b.cache_root.handle.makeOpenPath(hash_hex, .{}) catch |err| {
        return step.fail("cannot create output directory: {s}", .{@errorName(err)});
    };
    defer out_dir.close();

    for (outputs.items) |of| {
        if (std.fs.path.dirname(of.path)) |dir| {
            out_dir.makePath(dir) catch |err| {
                return step.fail("cannot create directory '{s}': {s}", .{ dir, @errorName(err) });
            };
        }
        out_dir.writeFile(.{ .sub_path = of.path, .data = of.content }) catch |err| {
            return step.fail("cannot write '{s}': {s}", .{ of.path, @errorName(err) });
        };
    }

    out_dir.writeFile(.{ .sub_path = "root.zig", .data = root.items }) catch |err| {
        return step.fail("cannot write root.zig: {s}", .{@errorName(err)});
    };
}

fn hasErrors(diags: []const proto.parser.Diagnostic) bool {
    for (diags) |d| {
        if (d.severity == .err) return true;
    }
    return false;
}

fn reportErrors(step: *std.Build.Step, diags: []const proto.parser.Diagnostic) void {
    for (diags) |d| {
        if (d.severity == .err) {
            step.addError("{s}:{d}:{d}: error: {s}", .{
                d.location.file, d.location.line, d.location.column, d.message,
            }) catch {};
        }
    }
}

fn deriveModuleName(proto_filename: []const u8) []const u8 {
    const basename = std.fs.path.basename(proto_filename);
    return if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot|
        basename[0..dot]
    else
        basename;
}

comptime {
    // Verify make matches the expected Step.MakeFn signature
    const F = std.Build.Step.MakeFn;
    const f: F = make;
    _ = f;
}

const ImportLoader = struct {
    dirs: []const std.fs.Dir,

    fn load(ptr: *anyopaque, path: []const u8, allocator: std.mem.Allocator) proto.linker.LinkError![]const u8 {
        const self: *ImportLoader = @ptrCast(@alignCast(ptr));
        for (self.dirs) |dir| {
            const file = dir.openFile(path, .{}) catch continue;
            defer file.close();
            return file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return error.OutOfMemory;
        }
        return error.LinkFailed;
    }
};
