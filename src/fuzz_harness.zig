const std = @import("std");
const protobuf = @import("protobuf");
const encoding = protobuf.encoding;
const message = protobuf.message;
const descriptor = protobuf.descriptor;

const FuzzTarget = enum {
    lexer,
    resolve_string,
    parser,
    varint_decode,
    varint_roundtrip,
    zigzag32_roundtrip,
    zigzag64_roundtrip,
    tag_decode,
    tag_roundtrip,
    fixed32_roundtrip,
    fixed64_roundtrip,
    int32_roundtrip,
    sint32_roundtrip,
    sint64_roundtrip,
    field_iterator,
    skip_field,
    skip_group,
    packed_varint,
    packed_fixed32,
    packed_fixed64,
    message_roundtrip,
    json_scanner,
    text_scanner,
    dynamic_decode,
};

const active = std.meta.stringToEnum(FuzzTarget, @import("build_options").fuzz_target) orelse
    @compileError("unknown fuzz target: " ++ @import("build_options").fuzz_target);

pub var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
pub var arena: std.heap.ArenaAllocator = undefined;

export fn zig_fuzz_init() void {
    arena = .init(gpa.allocator());
}

export fn zig_fuzz_test(buf: [*]u8, len_raw: isize) void {
    const len: usize = if (len_raw > 0) @intCast(len_raw) else 0;
    const input: []const u8 = if (len > 0) buf[0..len] else &.{};
    _ = arena.reset(.retain_capacity);
    runFuzz(input);
}

pub fn runFuzz(input: []const u8) void {
    switch (active) {
        .lexer => fuzzLexer(input),
        .resolve_string => fuzzResolveString(input),
        .parser => fuzzParser(input),
        .varint_decode => fuzzVarintDecode(input),
        .varint_roundtrip => fuzzVarintRoundtrip(input),
        .zigzag32_roundtrip => fuzzZigzag32Roundtrip(input),
        .zigzag64_roundtrip => fuzzZigzag64Roundtrip(input),
        .tag_decode => fuzzTagDecode(input),
        .tag_roundtrip => fuzzTagRoundtrip(input),
        .fixed32_roundtrip => fuzzFixed32Roundtrip(input),
        .fixed64_roundtrip => fuzzFixed64Roundtrip(input),
        .int32_roundtrip => fuzzInt32Roundtrip(input),
        .sint32_roundtrip => fuzzSint32Roundtrip(input),
        .sint64_roundtrip => fuzzSint64Roundtrip(input),
        .field_iterator => fuzzFieldIterator(input),
        .skip_field => fuzzSkipField(input),
        .skip_group => fuzzSkipGroup(input),
        .packed_varint => fuzzPackedVarint(input),
        .packed_fixed32 => fuzzPackedFixed32(input),
        .packed_fixed64 => fuzzPackedFixed64(input),
        .message_roundtrip => fuzzMessageRoundtrip(input),
        .json_scanner => fuzzJsonScanner(input),
        .text_scanner => fuzzTextScanner(input),
        .dynamic_decode => fuzzDynamicDecode(input),
    }
}

// ── Lexer / Parser targets ───────────────────────────────────────────

fn fuzzLexer(input: []const u8) void {
    var lex = protobuf.proto.lexer.Lexer.init(input, "fuzz.proto");
    while (true) {
        const tok = lex.next() catch return;
        if (tok.kind == .eof) break;
    }
}

fn fuzzResolveString(input: []const u8) void {
    const result = protobuf.proto.lexer.resolve_string(input, arena.allocator()) catch return;
    _ = result;
}

fn fuzzParser(input: []const u8) void {
    const allocator = arena.allocator();
    var diags: protobuf.proto.parser.DiagnosticList = .empty;
    const lex = protobuf.proto.lexer.Lexer.init(input, "fuzz.proto");
    var p = protobuf.proto.parser.Parser.init(lex, allocator, &diags);
    _ = p.parse_file() catch return;
}

// ── Encoding targets ─────────────────────────────────────────────────

fn fuzzVarintDecode(input: []const u8) void {
    var r: std.Io.Reader = .fixed(input);
    _ = encoding.decode_varint(&r) catch return;
}

fn fuzzVarintRoundtrip(input: []const u8) void {
    if (input.len < 8) return;
    const value: u64 = @bitCast(input[0..8].*);
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    encoding.encode_varint(&w, value) catch return;
    var r: std.Io.Reader = .fixed(w.buffered());
    const decoded = encoding.decode_varint(&r) catch @panic("decode failed after successful encode");
    if (decoded != value) @panic("varint round-trip mismatch");
}

fn fuzzZigzag32Roundtrip(input: []const u8) void {
    if (input.len < 4) return;
    const value: i32 = @bitCast(input[0..4].*);
    const decoded = encoding.zigzag_decode(encoding.zigzag_encode(value));
    if (decoded != value) @panic("zigzag32 round-trip mismatch");
}

fn fuzzZigzag64Roundtrip(input: []const u8) void {
    if (input.len < 8) return;
    const value: i64 = @bitCast(input[0..8].*);
    const decoded = encoding.zigzag_decode_64(encoding.zigzag_encode_64(value));
    if (decoded != value) @panic("zigzag64 round-trip mismatch");
}

fn fuzzTagDecode(input: []const u8) void {
    var r: std.Io.Reader = .fixed(input);
    _ = encoding.decode_tag(&r) catch return;
}

fn fuzzTagRoundtrip(input: []const u8) void {
    if (input.len < 4) return;
    const raw_field: u32 = @bitCast(input[0..4].*);
    const wire_raw = raw_field % 6;
    const field_raw = (raw_field >> 3);
    if (field_raw == 0 or field_raw > std.math.maxInt(u29)) return;
    const tag = encoding.Tag{
        .field_number = @intCast(field_raw % std.math.maxInt(u29) + 1),
        .wire_type = @enumFromInt(@as(u3, @intCast(wire_raw))),
    };
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    encoding.encode_tag(&w, tag) catch return;
    var r: std.Io.Reader = .fixed(w.buffered());
    const decoded = encoding.decode_tag(&r) catch @panic("tag decode failed after successful encode");
    if (decoded.field_number != tag.field_number) @panic("tag field number mismatch");
    if (decoded.wire_type != tag.wire_type) @panic("tag wire type mismatch");
}

fn fuzzFixed32Roundtrip(input: []const u8) void {
    if (input.len < 4) return;
    const value: u32 = @bitCast(input[0..4].*);
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    encoding.encode_fixed32(&w, value) catch @panic("fixed32 encode failed");
    var r: std.Io.Reader = .fixed(w.buffered());
    const decoded = encoding.decode_fixed32(&r) catch @panic("fixed32 decode failed");
    if (decoded != value) @panic("fixed32 round-trip mismatch");
}

fn fuzzFixed64Roundtrip(input: []const u8) void {
    if (input.len < 8) return;
    const value: u64 = @bitCast(input[0..8].*);
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    encoding.encode_fixed64(&w, value) catch @panic("fixed64 encode failed");
    var r: std.Io.Reader = .fixed(w.buffered());
    const decoded = encoding.decode_fixed64(&r) catch @panic("fixed64 decode failed");
    if (decoded != value) @panic("fixed64 round-trip mismatch");
}

fn fuzzInt32Roundtrip(input: []const u8) void {
    if (input.len < 4) return;
    const value: i32 = @bitCast(input[0..4].*);
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    encoding.encode_int32(&w, value) catch @panic("int32 encode failed");
    var r: std.Io.Reader = .fixed(w.buffered());
    const decoded = encoding.decode_int32(&r) catch @panic("int32 decode failed");
    if (decoded != value) @panic("int32 round-trip mismatch");
}

fn fuzzSint32Roundtrip(input: []const u8) void {
    if (input.len < 4) return;
    const value: i32 = @bitCast(input[0..4].*);
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    encoding.encode_sint32(&w, value) catch @panic("sint32 encode failed");
    var r: std.Io.Reader = .fixed(w.buffered());
    const decoded = encoding.decode_sint32(&r) catch @panic("sint32 decode failed");
    if (decoded != value) @panic("sint32 round-trip mismatch");
}

fn fuzzSint64Roundtrip(input: []const u8) void {
    if (input.len < 8) return;
    const value: i64 = @bitCast(input[0..8].*);
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    encoding.encode_sint64(&w, value) catch @panic("sint64 encode failed");
    var r: std.Io.Reader = .fixed(w.buffered());
    const decoded = encoding.decode_sint64(&r) catch @panic("sint64 decode failed");
    if (decoded != value) @panic("sint64 round-trip mismatch");
}

// ── Message targets ──────────────────────────────────────────────────

fn fuzzFieldIterator(input: []const u8) void {
    var iter = message.iterate_fields(input);
    while (iter.next() catch return) |_| {}
}

fn fuzzSkipField(input: []const u8) void {
    inline for (.{ encoding.WireType.varint, encoding.WireType.i64, encoding.WireType.i32, encoding.WireType.len, encoding.WireType.egroup }) |wt| {
        var pos: usize = 0;
        _ = message.skip_field(input, &pos, wt) catch {};
    }
}

fn fuzzSkipGroup(input: []const u8) void {
    if (input.len < 1) return;
    const field_num: u29 = @as(u29, input[0] % 255) + 1;
    var pos: usize = 1;
    _ = message.skip_group(input, &pos, field_num) catch {};
}

fn fuzzPackedVarint(input: []const u8) void {
    var iter = message.PackedVarintIterator.init(input);
    while (iter.next() catch return) |_| {}
}

fn fuzzPackedFixed32(input: []const u8) void {
    var iter = message.PackedFixed32Iterator.init(input);
    while (iter.next() catch return) |_| {}
}

fn fuzzPackedFixed64(input: []const u8) void {
    var iter = message.PackedFixed64Iterator.init(input);
    while (iter.next() catch return) |_| {}
}

fn fuzzMessageRoundtrip(input: []const u8) void {
    if (input.len < 2) return;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mw = message.MessageWriter.init(&w);

    var i: usize = 0;
    var field_count: usize = 0;
    while (i + 1 < input.len) {
        const wire_choice = input[i] % 4;
        const field_number: u29 = @as(u29, input[i + 1] % 255) + 1;
        i += 2;

        switch (wire_choice) {
            0 => {
                if (i + 8 > input.len) return;
                const val: u64 = @bitCast(input[i..][0..8].*);
                mw.write_varint_field(field_number, val) catch return;
                i += 8;
            },
            1 => {
                if (i + 4 > input.len) return;
                const val: u32 = @bitCast(input[i..][0..4].*);
                mw.write_i32_field(field_number, val) catch return;
                i += 4;
            },
            2 => {
                if (i + 8 > input.len) return;
                const val: u64 = @bitCast(input[i..][0..8].*);
                mw.write_i64_field(field_number, val) catch return;
                i += 8;
            },
            3 => {
                if (i >= input.len) return;
                const len: usize = @min(input[i], 64);
                i += 1;
                if (i + len > input.len) return;
                mw.write_len_field(field_number, input[i..][0..len]) catch return;
                i += len;
            },
            else => unreachable,
        }
        field_count += 1;
    }

    const encoded = w.buffered();
    var iter = message.iterate_fields(encoded);
    var decoded_count: usize = 0;
    while (iter.next() catch @panic("field iterator failed on valid encoded data")) |_| {
        decoded_count += 1;
    }
    if (decoded_count != field_count) @panic("message round-trip field count mismatch");
}

// ── JSON / Text / Dynamic targets ────────────────────────────────────

fn fuzzJsonScanner(input: []const u8) void {
    const allocator = arena.allocator();
    var scanner = protobuf.json.JsonScanner.init(allocator, input);
    defer scanner.deinit();
    while (scanner.next() catch return) |_| {}
}

fn fuzzTextScanner(input: []const u8) void {
    const allocator = arena.allocator();
    var scanner = protobuf.text_format.TextScanner.init(allocator, input);
    defer scanner.deinit();
    while (scanner.next() catch return) |_| {}
}

fn fuzzDynamicDecode(input: []const u8) void {
    const allocator = arena.allocator();
    const desc = descriptor.MessageDescriptor{
        .name = "FuzzMsg",
        .full_name = "FuzzMsg",
        .fields = &.{
            .{ .name = "f_int32", .number = 1, .field_type = .int32, .label = .implicit },
            .{ .name = "f_int64", .number = 2, .field_type = .int64, .label = .implicit },
            .{ .name = "f_uint32", .number = 3, .field_type = .uint32, .label = .implicit },
            .{ .name = "f_uint64", .number = 4, .field_type = .uint64, .label = .implicit },
            .{ .name = "f_sint32", .number = 5, .field_type = .sint32, .label = .implicit },
            .{ .name = "f_sint64", .number = 6, .field_type = .sint64, .label = .implicit },
            .{ .name = "f_bool", .number = 7, .field_type = .bool, .label = .implicit },
            .{ .name = "f_fixed32", .number = 8, .field_type = .fixed32, .label = .implicit },
            .{ .name = "f_fixed64", .number = 9, .field_type = .fixed64, .label = .implicit },
            .{ .name = "f_sfixed32", .number = 10, .field_type = .sfixed32, .label = .implicit },
            .{ .name = "f_sfixed64", .number = 11, .field_type = .sfixed64, .label = .implicit },
            .{ .name = "f_float", .number = 12, .field_type = .float, .label = .implicit },
            .{ .name = "f_double", .number = 13, .field_type = .double, .label = .implicit },
            .{ .name = "f_string", .number = 14, .field_type = .string, .label = .implicit },
            .{ .name = "f_bytes", .number = 15, .field_type = .bytes, .label = .implicit },
            .{ .name = "f_repeated", .number = 16, .field_type = .int32, .label = .repeated },
        },
    };
    var msg = protobuf.dynamic.DynamicMessage.decode(allocator, &desc, input) catch return;
    msg.deinit();
}
