//! Build step that generates Zig source files from .proto definitions
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

/// Configuration options for the protobuf code generation step
pub const Options = struct {
    /// Directory containing .proto sources (e.g., b.path("proto/"))
    proto_sources: std.Build.LazyPath,
    /// Additional import search paths for resolving proto imports
    import_paths: []const std.Build.LazyPath = &.{},
};

/// Create a GenerateStep that compiles .proto files into a Zig module
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

/// Return the generated Zig module for use as an import in downstream code
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
    var src_dir = src_path.root_dir.handle.openDir(src_path.sub_path, .{ .iterate = true }) catch |err| {
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

    // Collect all fully-qualified enum names from all files (for cross-file enum resolution)
    var global_enum_names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (resolved.files) |rf| {
        try collectFileEnumNames(arena, &global_enum_names, rf.source);
    }
    for (resolved.imported_files) |imp| {
        try collectFileEnumNames(arena, &global_enum_names, imp.source);
    }

    // Generate Zig source for each resolved file
    const OutputFile = struct { path: []const u8, content: []const u8, mod_name: []const u8 };
    var outputs: std.ArrayListUnmanaged(OutputFile) = .empty;

    for (resolved.files, 0..) |rf, i| {
        const content = try codegen_mod.generate_file(arena, rf.source, sources.items[i].filename, global_enum_names.items);
        const out_path = try codegen_mod.package_to_path(arena, rf.source.package, sources.items[i].filename);
        const mod_name = deriveModuleName(sources.items[i].filename);
        try outputs.append(arena, .{ .path = out_path, .content = content, .mod_name = mod_name });
    }

    // Generate code for imported files (e.g. well-known types)
    // Group by package, generating a namespace file that re-exports all types
    const ImportedOutput = struct { path: []const u8, content: []const u8 };
    var imported_outputs: std.ArrayListUnmanaged(ImportedOutput) = .empty;
    var package_files = std.StringHashMap(std.ArrayListUnmanaged(ImportedOutput)).init(arena);

    for (resolved.imported_files) |imp| {
        const content = try codegen_mod.generate_file(arena, imp.source, imp.path, global_enum_names.items);
        // Use package + filename for unique path: google/protobuf/wrappers.zig
        const out_path = try imported_file_path(arena, imp.source.package, imp.path);
        try imported_outputs.append(arena, .{ .path = out_path, .content = content });

        // Track by package for namespace files
        if (imp.source.package) |pkg| {
            if (pkg.len > 0) {
                const gop = try package_files.getOrPut(pkg);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                }
                try gop.value_ptr.append(arena, .{ .path = out_path, .content = content });
            }
        }
    }

    // Generate package namespace files that re-export types from sub-files
    var pkg_namespace_files: std.ArrayListUnmanaged(ImportedOutput) = .empty;
    var pkg_iter = package_files.iterator();
    while (pkg_iter.next()) |entry| {
        const pkg = entry.key_ptr.*;
        const files_in_pkg = entry.value_ptr.items;

        // Compute namespace file path first so we can derive relative imports
        // e.g. google.protobuf -> google/protobuf.zig (sits in google/ directory)
        const ns_path = try codegen_mod.package_to_path(arena, pkg, "");
        const ns_dir = std.fs.path.dirname(ns_path);

        var ns_content: std.ArrayListUnmanaged(u8) = .empty;
        try ns_content.appendSlice(arena, "// Generated namespace re-exports for package: ");
        try ns_content.appendSlice(arena, pkg);
        try ns_content.appendSlice(arena, "\n");
        try ns_content.appendSlice(arena, "const std = @import(\"std\");\n");
        try ns_content.appendSlice(arena, "const protobuf = @import(\"protobuf\");\n\n");

        for (files_in_pkg) |f| {
            // Generate: const _mod = @import("relative_path");
            const basename = std.fs.path.basename(f.path);
            // Compute import path relative to namespace file's directory
            // e.g. f.path="google/protobuf/wrappers.zig", ns_dir="google"
            //   -> relative="protobuf/wrappers.zig"
            const import_path = if (ns_dir) |dir|
                f.path[dir.len + 1 ..]
            else
                f.path;
            try ns_content.appendSlice(arena, "const _");
            // Use stem of basename as identifier
            const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot|
                basename[0..dot]
            else
                basename;
            try ns_content.appendSlice(arena, stem);
            try ns_content.appendSlice(arena, " = @import(\"");
            try ns_content.appendSlice(arena, import_path);
            try ns_content.appendSlice(arena, "\");\n");
        }
        try ns_content.appendSlice(arena, "\n");

        // Re-export all public declarations from each sub-file
        for (files_in_pkg) |f| {
            // Find the imported file source to get type names
            for (resolved.imported_files) |imp| {
                const imp_path = try imported_file_path(arena, imp.source.package, imp.path);
                if (std.mem.eql(u8, imp_path, f.path)) {
                    const basename = std.fs.path.basename(f.path);
                    const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot|
                        basename[0..dot]
                    else
                        basename;

                    for (imp.source.messages) |msg| {
                        try ns_content.appendSlice(arena, "pub const ");
                        try ns_content.appendSlice(arena, msg.name);
                        try ns_content.appendSlice(arena, " = _");
                        try ns_content.appendSlice(arena, stem);
                        try ns_content.appendSlice(arena, ".");
                        try ns_content.appendSlice(arena, msg.name);
                        try ns_content.appendSlice(arena, ";\n");
                    }
                    for (imp.source.enums) |en| {
                        try ns_content.appendSlice(arena, "pub const ");
                        try ns_content.appendSlice(arena, en.name);
                        try ns_content.appendSlice(arena, " = _");
                        try ns_content.appendSlice(arena, stem);
                        try ns_content.appendSlice(arena, ".");
                        try ns_content.appendSlice(arena, en.name);
                        try ns_content.appendSlice(arena, ";\n");
                    }
                    break;
                }
            }
        }

        try pkg_namespace_files.append(arena, .{ .path = ns_path, .content = ns_content.items });
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

    // Add package namespace imports to root.zig
    // e.g.: pub const google = struct { pub const protobuf = @import("google/protobuf.zig"); };
    var root_packages = std.StringHashMap(void).init(arena);
    var pkg_iter2 = package_files.iterator();
    while (pkg_iter2.next()) |entry| {
        const pkg = entry.key_ptr.*;
        // Get the top-level namespace (first component before '.')
        const top = if (std.mem.indexOfScalar(u8, pkg, '.')) |dot| pkg[0..dot] else pkg;
        if (!root_packages.contains(top)) {
            try root_packages.put(top, {});
            // Build nested struct for package hierarchy
            try appendPackageImport(&root, arena, pkg);
        }
    }

    // Compute content hash for output directory name
    var hasher = std.hash.Wyhash.init(0);
    for (sources.items) |src| {
        hasher.update(src.filename);
        hasher.update(src.content);
    }
    for (resolved.imported_files) |imp| {
        hasher.update(imp.path);
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

    // Write imported files (well-known types etc.)
    for (imported_outputs.items) |of| {
        if (std.fs.path.dirname(of.path)) |dir| {
            out_dir.makePath(dir) catch |err| {
                return step.fail("cannot create directory '{s}': {s}", .{ dir, @errorName(err) });
            };
        }
        out_dir.writeFile(.{ .sub_path = of.path, .data = of.content }) catch |err| {
            return step.fail("cannot write '{s}': {s}", .{ of.path, @errorName(err) });
        };
    }

    // Write package namespace files
    for (pkg_namespace_files.items) |of| {
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

/// Collect fully-qualified enum names from a file (top-level and nested in messages).
fn collectFileEnumNames(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), file: ast.File) !void {
    const pkg = file.package orelse "";
    for (file.enums) |en| {
        try list.append(allocator, try qualifiedEnumName(allocator, pkg, en.name));
    }
    for (file.messages) |msg| {
        try collectMessageEnumNames(allocator, list, msg, pkg);
    }
}

fn collectMessageEnumNames(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), msg: ast.Message, scope: []const u8) !void {
    const msg_scope = try qualifiedEnumName(allocator, scope, msg.name);
    for (msg.nested_enums) |en| {
        try list.append(allocator, try qualifiedEnumName(allocator, msg_scope, en.name));
    }
    for (msg.nested_messages) |nested| {
        try collectMessageEnumNames(allocator, list, nested, msg_scope);
    }
}

fn qualifiedEnumName(allocator: std.mem.Allocator, scope: []const u8, name: []const u8) ![]const u8 {
    if (scope.len == 0) return name;
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ scope, name });
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

/// Generate unique output path for an imported file using package + filename.
/// e.g. package="google.protobuf", path="google/protobuf/wrappers.proto"
/// → "google/protobuf/wrappers.zig"
fn imported_file_path(allocator: std.mem.Allocator, package: ?[]const u8, import_path: []const u8) ![]const u8 {
    if (package) |pkg| {
        if (pkg.len > 0) {
            // Build: package_as_dir/filename_stem.zig
            // e.g. google.protobuf + wrappers.proto → google/protobuf/wrappers.zig
            const basename = std.fs.path.basename(import_path);
            const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot|
                basename[0..dot]
            else
                basename;

            // Count package path length (dots become slashes)
            var pkg_len: usize = 0;
            for (pkg) |c| {
                _ = c;
                pkg_len += 1;
            }

            var result = try allocator.alloc(u8, pkg_len + 1 + stem.len + 4); // pkg/ + stem + .zig
            var idx: usize = 0;
            for (pkg) |c| {
                if (c == '.') {
                    result[idx] = '/';
                } else {
                    result[idx] = c;
                }
                idx += 1;
            }
            result[idx] = '/';
            idx += 1;
            @memcpy(result[idx..][0..stem.len], stem);
            idx += stem.len;
            @memcpy(result[idx..][0..4], ".zig");
            return result;
        }
    }

    // Fallback: use import path with .zig extension
    const basename = std.fs.path.basename(import_path);
    const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot|
        basename[0..dot]
    else
        basename;
    var result = try allocator.alloc(u8, stem.len + 4);
    @memcpy(result[0..stem.len], stem);
    @memcpy(result[stem.len..][0..4], ".zig");
    return result;
}

/// Append a package import declaration to root.zig content.
/// For "google.protobuf" → pub const google = struct { pub const protobuf = @import("google/protobuf.zig"); };
fn appendPackageImport(
    root: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    pkg: []const u8,
) !void {
    // Split package into components: "google.protobuf" → ["google", "protobuf"]
    // Build nested struct: pub const google = struct { pub const protobuf = @import("google/protobuf.zig"); };
    var components: std.ArrayListUnmanaged([]const u8) = .empty;
    var start: usize = 0;
    for (pkg, 0..) |c, i| {
        if (c == '.') {
            try components.append(allocator, pkg[start..i]);
            start = i + 1;
        }
    }
    try components.append(allocator, pkg[start..]);

    // Build opening: pub const google = struct {
    for (components.items, 0..) |comp, i| {
        if (i == components.items.len - 1) {
            // Last component: import the namespace file
            try root.appendSlice(allocator, "pub const @\"");
            try root.appendSlice(allocator, comp);
            try root.appendSlice(allocator, "\" = @import(\"");
            // Build path: google/protobuf.zig
            for (components.items[0..i]) |prev| {
                try root.appendSlice(allocator, prev);
                try root.appendSlice(allocator, "/");
            }
            try root.appendSlice(allocator, comp);
            try root.appendSlice(allocator, ".zig\");\n");
        } else {
            try root.appendSlice(allocator, "pub const @\"");
            try root.appendSlice(allocator, comp);
            try root.appendSlice(allocator, "\" = struct {\n");
        }
    }

    // Close nested structs
    if (components.items.len > 1) {
        var i = components.items.len - 2;
        while (true) : (i -= 1) {
            try root.appendSlice(allocator, "};\n");
            if (i == 0) break;
        }
    }
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
