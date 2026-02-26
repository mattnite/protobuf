const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");

// ── Types ─────────────────────────────────────────────────────────────

pub const ResolvedFileSet = struct {
    files: []ResolvedFile,

    pub const ResolvedFile = struct {
        source: ast.File,
        type_registry: std.StringHashMap(TypeInfo),
    };

    pub const TypeInfo = union(enum) {
        message: *const ast.Message,
        @"enum": *const ast.Enum,
    };
};

pub const LinkError = error{
    OutOfMemory,
    LinkFailed,
};

// ── Linker ────────────────────────────────────────────────────────────

pub const Linker = struct {
    allocator: std.mem.Allocator,
    diagnostics: *parser_mod.DiagnosticList,
    file_loader: *const fn ([]const u8, std.mem.Allocator) LinkError![]const u8,

    // Internal state
    loaded_files: std.StringHashMap(ast.File),
    loading_stack: std.ArrayList([]const u8),
    global_types: std.StringHashMap(ResolvedFileSet.TypeInfo),

    pub fn init(
        allocator: std.mem.Allocator,
        diagnostics: *parser_mod.DiagnosticList,
        file_loader: *const fn ([]const u8, std.mem.Allocator) LinkError![]const u8,
    ) Linker {
        return .{
            .allocator = allocator,
            .diagnostics = diagnostics,
            .file_loader = file_loader,
            .loaded_files = std.StringHashMap(ast.File).init(allocator),
            .loading_stack = .empty,
            .global_types = std.StringHashMap(ResolvedFileSet.TypeInfo).init(allocator),
        };
    }

    pub fn link(self: *Linker, files: []const ast.File) LinkError!ResolvedFileSet {
        // Phase 1: Load imports
        for (files) |file| {
            try self.load_imports(file);
        }

        // Phase 2: Register all types from all files (input + loaded)
        for (files) |file| {
            try self.register_file_types(file);
        }
        var loaded_iter = self.loaded_files.valueIterator();
        while (loaded_iter.next()) |file| {
            try self.register_file_types(file.*);
        }

        // Phase 3: Resolve type references in input files
        // Phase 4: Validate
        var result_files: std.ArrayList(ResolvedFileSet.ResolvedFile) = .empty;
        for (files) |file| {
            var registry = std.StringHashMap(ResolvedFileSet.TypeInfo).init(self.allocator);

            // Build per-file type registry
            try self.build_file_registry(file, &registry);

            // Validate
            try self.validate_file(file);

            try result_files.append(self.allocator, .{
                .source = file,
                .type_registry = registry,
            });
        }

        return .{ .files = try result_files.toOwnedSlice(self.allocator) };
    }

    // ── Import Resolution ─────────────────────────────────────────────

    fn load_imports(self: *Linker, file: ast.File) LinkError!void {
        for (file.imports) |import_decl| {
            if (self.loaded_files.contains(import_decl.path)) continue;

            // Check for circular imports
            const is_circular = blk: {
                for (self.loading_stack.items) |stack_path| {
                    if (std.mem.eql(u8, stack_path, import_decl.path)) break :blk true;
                }
                break :blk false;
            };
            if (is_circular) {
                try self.add_error(import_decl.location, "circular import detected");
                continue;
            }

            try self.loading_stack.append(self.allocator, import_decl.path);

            // Load and parse
            const source = self.file_loader(import_decl.path, self.allocator) catch {
                try self.add_error(import_decl.location, "import not found");
                _ = self.loading_stack.pop();
                continue;
            };

            const lex = lexer_mod.Lexer.init(source, import_decl.path);
            var parser = parser_mod.Parser.init(lex, self.allocator, self.diagnostics);
            const imported_file = parser.parse_file() catch {
                _ = self.loading_stack.pop();
                continue;
            };

            // Recursively load imports of the imported file BEFORE marking as loaded
            // so circular imports are detected via the loading stack.
            try self.load_imports(imported_file);

            try self.loaded_files.put(import_decl.path, imported_file);
            _ = self.loading_stack.pop();
        }
    }

    // ── Type Registration ─────────────────────────────────────────────

    fn register_file_types(self: *Linker, file: ast.File) LinkError!void {
        const prefix = file.package orelse "";
        for (file.messages) |*msg| {
            try self.register_message(msg, prefix);
        }
        for (file.enums) |*e| {
            try self.register_enum(e, prefix);
        }
    }

    fn register_message(self: *Linker, msg: *const ast.Message, scope: []const u8) LinkError!void {
        const fqn = try self.make_fqn(scope, msg.name);
        try self.global_types.put(fqn, .{ .message = msg });

        for (msg.nested_messages) |*nested| {
            try self.register_message(nested, fqn);
        }
        for (msg.nested_enums) |*e| {
            try self.register_enum(e, fqn);
        }
    }

    fn register_enum(self: *Linker, e: *const ast.Enum, scope: []const u8) LinkError!void {
        const fqn = try self.make_fqn(scope, e.name);
        try self.global_types.put(fqn, .{ .@"enum" = e });
    }

    fn make_fqn(self: *Linker, scope: []const u8, name: []const u8) LinkError![]const u8 {
        if (scope.len == 0) {
            // Just ".name"
            const result = try self.allocator.alloc(u8, 1 + name.len);
            result[0] = '.';
            @memcpy(result[1..], name);
            return result;
        }
        // ".scope.name"
        const needs_dot = scope[0] != '.';
        const total = (if (needs_dot) @as(usize, 1) else 0) + scope.len + 1 + name.len;
        const result = try self.allocator.alloc(u8, total);
        var pos: usize = 0;
        if (needs_dot) {
            result[0] = '.';
            pos = 1;
        }
        @memcpy(result[pos..][0..scope.len], scope);
        pos += scope.len;
        result[pos] = '.';
        pos += 1;
        @memcpy(result[pos..][0..name.len], name);
        return result;
    }

    // ── Per-file Type Registry ────────────────────────────────────────

    fn build_file_registry(self: *Linker, file: ast.File, registry: *std.StringHashMap(ResolvedFileSet.TypeInfo)) LinkError!void {
        const prefix = file.package orelse "";
        for (file.messages) |*msg| {
            try self.build_message_registry(msg, prefix, registry);
        }
        for (file.enums) |*e| {
            const fqn = try self.make_fqn(prefix, e.name);
            try registry.put(fqn, .{ .@"enum" = e });
        }
    }

    fn build_message_registry(self: *Linker, msg: *const ast.Message, scope: []const u8, registry: *std.StringHashMap(ResolvedFileSet.TypeInfo)) LinkError!void {
        const fqn = try self.make_fqn(scope, msg.name);
        try registry.put(fqn, .{ .message = msg });
        for (msg.nested_messages) |*nested| {
            try self.build_message_registry(nested, fqn, registry);
        }
        for (msg.nested_enums) |*e| {
            const efqn = try self.make_fqn(fqn, e.name);
            try registry.put(efqn, .{ .@"enum" = e });
        }
    }

    // ── Name Resolution ───────────────────────────────────────────────

    pub fn resolve_type_name(self: *Linker, name: []const u8, scope: []const u8) ?[]const u8 {
        // Absolute reference: starts with dot
        if (name.len > 0 and name[0] == '.') {
            if (self.global_types.contains(name)) return name;
            return null;
        }

        // Relative reference: walk up scope chain
        // scope is like ".package.Outer.Inner"
        var current_scope = scope;
        while (true) {
            const candidate = self.make_fqn_sync(current_scope, name) orelse return null;
            if (self.global_types.contains(candidate)) return candidate;

            // Walk up: remove last component from scope
            if (current_scope.len == 0) break;
            if (std.mem.lastIndexOfScalar(u8, current_scope, '.')) |last_dot| {
                current_scope = current_scope[0..last_dot];
            } else {
                break;
            }
        }

        // Try at root level
        const root_candidate = self.make_fqn_sync("", name) orelse return null;
        if (self.global_types.contains(root_candidate)) return root_candidate;

        return null;
    }

    fn make_fqn_sync(self: *Linker, scope: []const u8, name: []const u8) ?[]const u8 {
        // Non-error version for lookups (uses allocator, returns null on OOM)
        return self.make_fqn(scope, name) catch return null;
    }

    // ── Validation ────────────────────────────────────────────────────

    fn validate_file(self: *Linker, file: ast.File) LinkError!void {
        for (file.messages) |msg| {
            try self.validate_message(msg, file);
        }
        for (file.enums) |e| {
            try self.validate_enum(e, file);
        }
    }

    fn validate_message(self: *Linker, msg: ast.Message, file: ast.File) LinkError!void {
        // Check field number uniqueness
        try self.validate_field_numbers(msg.fields, msg.name);

        // Check reserved range conflicts
        for (msg.fields) |field| {
            for (msg.reserved_ranges) |range| {
                if (field.number >= range.start and field.number <= range.end) {
                    try self.add_error(field.location, "field number in reserved range");
                }
            }
            for (msg.reserved_names) |reserved_name| {
                if (std.mem.eql(u8, field.name, reserved_name)) {
                    try self.add_error(field.location, "field name is reserved");
                }
            }
        }

        // Validate map key types
        for (msg.maps) |map_field| {
            switch (map_field.key_type) {
                .float, .double, .bytes => {
                    try self.add_error(map_field.location, "invalid map key type");
                },
                else => {},
            }
        }

        // Resolve named type references
        const scope = try self.file_scope(file, msg.name);
        for (msg.fields) |field| {
            if (field.type_name == .named) {
                if (self.resolve_type_name(field.type_name.named, scope) == null) {
                    try self.add_error(field.location, "unresolved type reference");
                }
            }
        }

        // Recurse into nested messages
        for (msg.nested_messages) |nested| {
            try self.validate_message(nested, file);
        }
        for (msg.nested_enums) |e| {
            try self.validate_enum(e, file);
        }
    }

    fn validate_enum(self: *Linker, e: ast.Enum, file: ast.File) LinkError!void {
        _ = file;
        // Proto3: first enum value must be 0
        if (e.values.len > 0 and e.values[0].number != 0) {
            // Only for proto3, but we don't track syntax per-enum.
            // Add a check that can be refined when we have syntax context.
            // For now, we'll check all enums — the proto3 constraint.
            try self.add_error(e.values[0].location, "first enum value must be 0 in proto3");
        }
    }

    fn validate_field_numbers(self: *Linker, fields: []const ast.Field, msg_name: []const u8) LinkError!void {
        _ = msg_name;
        for (fields, 0..) |field, i| {
            for (fields[i + 1 ..]) |other| {
                if (field.number == other.number) {
                    try self.add_error(other.location, "duplicate field number");
                }
            }
        }
    }

    fn file_scope(self: *Linker, file: ast.File, msg_name: []const u8) LinkError![]const u8 {
        if (file.package) |pkg| {
            return try self.make_fqn(pkg, msg_name);
        }
        return try self.make_fqn("", msg_name);
    }

    // ── Helpers ───────────────────────────────────────────────────────

    fn add_error(self: *Linker, location: ast.SourceLocation, message: []const u8) LinkError!void {
        try self.diagnostics.append(self.allocator, .{
            .location = location,
            .severity = .err,
            .message = message,
        });
    }
};

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

fn no_loader(_: []const u8, _: std.mem.Allocator) LinkError![]const u8 {
    return error.LinkFailed;
}

fn parse_source(arena: std.mem.Allocator, source: []const u8, diags: *parser_mod.DiagnosticList) !ast.File {
    const lex = lexer_mod.Lexer.init(source, "test.proto");
    var parser = parser_mod.Parser.init(lex, arena, diags);
    return parser.parse_file();
}

fn count_errors(diags: *const parser_mod.DiagnosticList) usize {
    var count: usize = 0;
    for (diags.items) |d| {
        if (d.severity == .err) count += 1;
    }
    return count;
}

// ── Single file type resolution ───────────────────────────────────────

test "Linker: single file, field type resolves" {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var diags: parser_mod.DiagnosticList = .empty;
    const file = try parse_source(arena,
        \\syntax = "proto3";
        \\package test;
        \\message Foo { int32 id = 1; }
        \\message Bar { Foo foo = 1; }
    , &diags);

    var linker = Linker.init(arena, &diags, &no_loader);
    const files: [1]ast.File = .{file};
    const result = try linker.link(&files);

    try testing.expectEqual(@as(usize, 1), result.files.len);
    // Foo should resolve — no error for unresolved type
    const err_count = count_errors(&diags);
    try testing.expectEqual(@as(usize, 0), err_count);
}

test "Linker: nested type resolution" {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var diags: parser_mod.DiagnosticList = .empty;
    const file = try parse_source(arena,
        \\syntax = "proto3";
        \\package test;
        \\message Outer {
        \\  message Inner { int32 x = 1; }
        \\  Inner inner = 1;
        \\}
    , &diags);

    var linker = Linker.init(arena, &diags, &no_loader);
    const files: [1]ast.File = .{file};
    _ = try linker.link(&files);

    try testing.expectEqual(@as(usize, 0), count_errors(&diags));
}

test "Linker: scope walking resolves sibling message" {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var diags: parser_mod.DiagnosticList = .empty;
    const file = try parse_source(arena,
        \\syntax = "proto3";
        \\package test;
        \\message A { int32 x = 1; }
        \\message B {
        \\  message C { A a = 1; }
        \\}
    , &diags);

    var linker = Linker.init(arena, &diags, &no_loader);
    const files: [1]ast.File = .{file};
    _ = try linker.link(&files);

    try testing.expectEqual(@as(usize, 0), count_errors(&diags));
}

test "Linker: absolute reference" {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var diags: parser_mod.DiagnosticList = .empty;
    const file = try parse_source(arena,
        \\syntax = "proto3";
        \\package test;
        \\message Foo { int32 x = 1; }
        \\message Bar { .test.Foo foo = 1; }
    , &diags);

    var linker = Linker.init(arena, &diags, &no_loader);
    const files: [1]ast.File = .{file};
    _ = try linker.link(&files);

    try testing.expectEqual(@as(usize, 0), count_errors(&diags));
}

// ── Import resolution ─────────────────────────────────────────────────

test "Linker: import resolution" {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const dep_source =
        \\syntax = "proto3";
        \\package dep;
        \\message Dep { int32 id = 1; }
    ;

    const loader = struct {
        fn load(_: []const u8, _: std.mem.Allocator) LinkError![]const u8 {
            return dep_source;
        }
    }.load;

    var diags: parser_mod.DiagnosticList = .empty;
    const file = try parse_source(arena,
        \\syntax = "proto3";
        \\package main;
        \\import "dep.proto";
        \\message Msg { dep.Dep dep = 1; }
    , &diags);

    var linker = Linker.init(arena, &diags, &loader);
    const files: [1]ast.File = .{file};
    _ = try linker.link(&files);

    try testing.expectEqual(@as(usize, 0), count_errors(&diags));
}

// ── Validation: duplicate field numbers ───────────────────────────────

test "Linker: duplicate field numbers" {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var diags: parser_mod.DiagnosticList = .empty;
    const file = try parse_source(arena,
        \\syntax = "proto3";
        \\message Bad {
        \\  int32 a = 1;
        \\  int32 b = 1;
        \\}
    , &diags);

    var linker = Linker.init(arena, &diags, &no_loader);
    const files: [1]ast.File = .{file};
    _ = try linker.link(&files);

    try testing.expect(count_errors(&diags) > 0);
}

// ── Validation: reserved range conflict ───────────────────────────────

test "Linker: reserved range conflict" {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var diags: parser_mod.DiagnosticList = .empty;
    const file = try parse_source(arena,
        \\syntax = "proto3";
        \\message Bad {
        \\  reserved 1 to 5;
        \\  int32 x = 3;
        \\}
    , &diags);

    var linker = Linker.init(arena, &diags, &no_loader);
    const files: [1]ast.File = .{file};
    _ = try linker.link(&files);

    try testing.expect(count_errors(&diags) > 0);
}

// ── Validation: reserved name conflict ────────────────────────────────

test "Linker: reserved name conflict" {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var diags: parser_mod.DiagnosticList = .empty;
    const file = try parse_source(arena,
        \\syntax = "proto3";
        \\message Bad {
        \\  reserved "foo";
        \\  string foo = 1;
        \\}
    , &diags);

    var linker = Linker.init(arena, &diags, &no_loader);
    const files: [1]ast.File = .{file};
    _ = try linker.link(&files);

    try testing.expect(count_errors(&diags) > 0);
}

// ── Validation: proto3 enum first value must be 0 ─────────────────────

test "Linker: proto3 enum first value not zero" {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var diags: parser_mod.DiagnosticList = .empty;
    const file = try parse_source(arena,
        \\syntax = "proto3";
        \\enum Bad {
        \\  FIRST = 1;
        \\}
    , &diags);

    var linker = Linker.init(arena, &diags, &no_loader);
    const files: [1]ast.File = .{file};
    _ = try linker.link(&files);

    try testing.expect(count_errors(&diags) > 0);
}

// ── Validation: unresolved type ───────────────────────────────────────

test "Linker: unresolved type reference" {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var diags: parser_mod.DiagnosticList = .empty;
    const file = try parse_source(arena,
        \\syntax = "proto3";
        \\message Msg {
        \\  NonExistent x = 1;
        \\}
    , &diags);

    var linker = Linker.init(arena, &diags, &no_loader);
    const files: [1]ast.File = .{file};
    _ = try linker.link(&files);

    try testing.expect(count_errors(&diags) > 0);
}

// ── Validation: invalid map key type ──────────────────────────────────

test "Linker: invalid map key type" {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var diags: parser_mod.DiagnosticList = .empty;
    const file = try parse_source(arena,
        \\syntax = "proto3";
        \\message Msg {
        \\  map<float, string> bad = 1;
        \\}
    , &diags);

    var linker = Linker.init(arena, &diags, &no_loader);
    const files: [1]ast.File = .{file};
    _ = try linker.link(&files);

    try testing.expect(count_errors(&diags) > 0);
}

// ── Circular import detection ─────────────────────────────────────────

test "Linker: circular import detected" {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // a.proto imports b.proto, b.proto imports a.proto
    const b_source =
        \\syntax = "proto3";
        \\import "a.proto";
        \\message B { int32 x = 1; }
    ;

    const loader = struct {
        fn load(path: []const u8, _: std.mem.Allocator) LinkError![]const u8 {
            if (std.mem.eql(u8, path, "b.proto")) return b_source;
            // If trying to load a.proto from b.proto, that's the circular case.
            // Return the source so the parser can parse it (it also imports b.proto).
            if (std.mem.eql(u8, path, "a.proto")) return
                \\syntax = "proto3";
                \\import "b.proto";
                \\message A { int32 y = 1; }
            ;
            return error.LinkFailed;
        }
    }.load;

    var diags: parser_mod.DiagnosticList = .empty;
    const file = try parse_source(arena,
        \\syntax = "proto3";
        \\import "b.proto";
        \\message A { int32 y = 1; }
    , &diags);

    var linker = Linker.init(arena, &diags, &loader);
    const files: [1]ast.File = .{file};
    _ = try linker.link(&files);

    try testing.expect(count_errors(&diags) > 0);
}

// ── Type registry contents ────────────────────────────────────────────

test "Linker: type registry contains all types" {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var diags: parser_mod.DiagnosticList = .empty;
    const file = try parse_source(arena,
        \\syntax = "proto3";
        \\package test;
        \\message Outer {
        \\  message Inner { int32 x = 1; }
        \\  enum Status { UNKNOWN = 0; }
        \\}
        \\enum TopEnum { ZERO = 0; }
    , &diags);

    var linker = Linker.init(arena, &diags, &no_loader);
    const files: [1]ast.File = .{file};
    const result = try linker.link(&files);

    const reg = result.files[0].type_registry;
    try testing.expect(reg.contains(".test.Outer"));
    try testing.expect(reg.contains(".test.Outer.Inner"));
    try testing.expect(reg.contains(".test.Outer.Status"));
    try testing.expect(reg.contains(".test.TopEnum"));
}
