const std = @import("std");
const testing = std.testing;
const descriptor = @import("descriptor.zig");
const encoding = @import("encoding.zig");
const message = @import("message.zig");

/// Tagged union holding a dynamically-typed protobuf field value
pub const DynamicValue = union(enum) {
    double_val: f64,
    float_val: f32,
    int32_val: i32,
    int64_val: i64,
    uint32_val: u32,
    uint64_val: u64,
    bool_val: bool,
    string_val: []const u8,
    bytes_val: []const u8,
    enum_val: i32,
    message_val: *DynamicMessage,
    null_val: void,
};

/// Schema-driven message that stores fields by number without generated code
pub const DynamicMessage = struct {
    desc: *const descriptor.MessageDescriptor,
    fields: std.AutoArrayHashMapUnmanaged(i32, FieldStorage),
    allocator: std.mem.Allocator,

    /// Storage variant for a field: singular, repeated, or map
    pub const FieldStorage = union(enum) {
        singular: DynamicValue,
        repeated: std.ArrayListUnmanaged(DynamicValue),
        map_str: std.StringArrayHashMapUnmanaged(DynamicValue),
        map_int: std.AutoArrayHashMapUnmanaged(i64, DynamicValue),
    };

    /// Create an empty DynamicMessage for the given descriptor
    pub fn init(allocator: std.mem.Allocator, desc: *const descriptor.MessageDescriptor) DynamicMessage {
        return .{
            .desc = desc,
            .fields = .empty,
            .allocator = allocator,
        };
    }

    /// Free all owned memory including nested messages and duplicated strings
    pub fn deinit(self: *DynamicMessage) void {
        var it = self.fields.iterator();
        while (it.next()) |entry| {
            self.freeStorage(entry.value_ptr);
        }
        self.fields.deinit(self.allocator);
    }

    fn freeStorage(self: *DynamicMessage, storage: *FieldStorage) void {
        switch (storage.*) {
            .singular => |*val| self.freeValue(val),
            .repeated => |*list| {
                for (list.items) |*val| {
                    self.freeValue(val);
                }
                list.deinit(self.allocator);
            },
            .map_str => |*m| {
                var map_it = m.iterator();
                while (map_it.next()) |map_entry| {
                    // Free the key string
                    if (map_entry.key_ptr.*.len > 0) self.allocator.free(map_entry.key_ptr.*);
                    self.freeValue(map_entry.value_ptr);
                }
                m.deinit(self.allocator);
            },
            .map_int => |*m| {
                var map_it = m.iterator();
                while (map_it.next()) |map_entry| {
                    self.freeValue(map_entry.value_ptr);
                }
                m.deinit(self.allocator);
            },
        }
    }

    /// Duplicate string/bytes values so DynamicMessage owns all its data.
    fn dupeValue(self: *DynamicMessage, val: DynamicValue) !DynamicValue {
        return switch (val) {
            .string_val => |s| .{ .string_val = if (s.len > 0) try self.allocator.dupe(u8, s) else s },
            .bytes_val => |b| .{ .bytes_val = if (b.len > 0) try self.allocator.dupe(u8, b) else b },
            else => val,
        };
    }

    fn freeValue(self: *DynamicMessage, val: *DynamicValue) void {
        switch (val.*) {
            .string_val => |s| if (s.len > 0) self.allocator.free(s),
            .bytes_val => |b| if (b.len > 0) self.allocator.free(b),
            .message_val => |msg| {
                msg.deinit();
                self.allocator.destroy(msg);
            },
            else => {},
        }
    }

    // ── Field lookup helpers ──────────────────────────────────────────

    /// Look up a field descriptor by name
    pub fn findField(desc: *const descriptor.MessageDescriptor, name: []const u8) ?*const descriptor.FieldDescriptor {
        for (desc.fields) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    /// Look up a field descriptor by field number
    pub fn findFieldByNumber(desc: *const descriptor.MessageDescriptor, number: i32) ?*const descriptor.FieldDescriptor {
        for (desc.fields) |*f| {
            if (f.number == number) return f;
        }
        return null;
    }

    /// Look up a map field descriptor by field number
    pub fn findMapField(desc: *const descriptor.MessageDescriptor, number: i32) ?*const descriptor.MapFieldDescriptor {
        for (desc.maps) |*m| {
            if (m.number == number) return m;
        }
        return null;
    }

    // ── Get/Set ──────────────────────────────────────────────────────

    /// Get the storage for a field by field number
    pub fn get(self: *const DynamicMessage, field_number: i32) ?*const FieldStorage {
        return self.fields.getPtr(field_number);
    }

    /// Get the storage for a field by name
    pub fn getByName(self: *const DynamicMessage, name: []const u8) ?*const FieldStorage {
        const fd = findField(self.desc, name) orelse return null;
        return self.get(fd.number);
    }

    /// Set a singular field value by number, duplicating any strings or bytes
    pub fn set(self: *DynamicMessage, field_number: i32, value: DynamicValue) !void {
        const owned = try self.dupeValue(value);
        return self.setOwned(field_number, owned);
    }

    /// Set a value that is already owned by this message (no duplication).
    fn setOwned(self: *DynamicMessage, field_number: i32, value: DynamicValue) !void {
        const gop = try self.fields.getOrPut(self.allocator, field_number);
        if (gop.found_existing) {
            self.freeStorage(gop.value_ptr);
        }
        gop.value_ptr.* = .{ .singular = value };
    }

    /// Set a singular field value by name, duplicating any strings or bytes
    pub fn setByName(self: *DynamicMessage, name: []const u8, value: DynamicValue) !void {
        const fd = findField(self.desc, name) orelse return error.UnknownField;
        return self.set(fd.number, value);
    }

    /// Append a value to a repeated field, duplicating any strings or bytes
    pub fn append(self: *DynamicMessage, field_number: i32, value: DynamicValue) !void {
        const owned = try self.dupeValue(value);
        return self.appendOwned(field_number, owned);
    }

    /// Append a value that is already owned by this message (no duplication).
    fn appendOwned(self: *DynamicMessage, field_number: i32, value: DynamicValue) !void {
        const gop = try self.fields.getOrPut(self.allocator, field_number);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .repeated = .empty };
        }
        switch (gop.value_ptr.*) {
            .repeated => |*list| try list.append(self.allocator, value),
            else => return error.InvalidFieldType,
        }
    }

    /// Insert a key-value pair into a map field, duplicating any strings or bytes
    pub fn putMap(self: *DynamicMessage, field_number: i32, key: DynamicValue, value: DynamicValue) !void {
        const owned_key = try self.dupeValue(key);
        const owned_val = try self.dupeValue(value);
        return self.putMapOwned(field_number, owned_key, owned_val);
    }

    /// Put a map entry with already-owned key and value (no duplication).
    fn putMapOwned(self: *DynamicMessage, field_number: i32, key: DynamicValue, value: DynamicValue) !void {
        const gop = try self.fields.getOrPut(self.allocator, field_number);
        const map_fd = findMapField(self.desc, field_number);
        if (map_fd) |mfd| {
            if (mfd.entry.key_type == .string) {
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .map_str = .empty };
                }
                switch (gop.value_ptr.*) {
                    .map_str => |*m| try m.put(self.allocator, key.string_val, value),
                    else => return error.InvalidFieldType,
                }
            } else {
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .map_int = .empty };
                }
                switch (gop.value_ptr.*) {
                    .map_int => |*m| {
                        const int_key: i64 = switch (key) {
                            .int32_val => |v| @as(i64, v),
                            .int64_val => |v| v,
                            .uint32_val => |v| @as(i64, @intCast(v)),
                            .uint64_val => |v| @as(i64, @intCast(v)),
                            .bool_val => |v| @as(i64, @intFromBool(v)),
                            else => return error.InvalidFieldType,
                        };
                        try m.put(self.allocator, int_key, value);
                    },
                    else => return error.InvalidFieldType,
                }
            }
        } else {
            return error.UnknownField;
        }
    }

    /// Errors specific to dynamic message operations
    pub const Error = error{
        UnknownField,
        InvalidFieldType,
    };

    // ── Encode ───────────────────────────────────────────────────────

    /// Serialize this message to protobuf binary wire format
    pub fn encode(self: *const DynamicMessage, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const mw = message.MessageWriter.init(writer);

        // Encode regular fields
        for (self.desc.fields) |fd| {
            if (self.fields.getPtr(fd.number)) |storage| {
                try encodeField(self, &fd, storage, &mw, writer);
            }
        }

        // Encode map fields
        for (self.desc.maps) |mfd| {
            if (self.fields.getPtr(mfd.number)) |storage| {
                try encodeMapField(self, &mfd, storage, &mw, writer);
            }
        }
    }

    /// Calculate the serialized size in bytes without encoding
    pub fn calcSize(self: *const DynamicMessage) usize {
        var size: usize = 0;

        for (self.desc.fields) |fd| {
            if (self.fields.getPtr(fd.number)) |storage| {
                size += calcFieldSize(&fd, storage, self);
            }
        }

        for (self.desc.maps) |mfd| {
            if (self.fields.getPtr(mfd.number)) |storage| {
                size += calcMapFieldSize(&mfd, storage, self);
            }
        }

        return size;
    }

    fn encodeField(self: *const DynamicMessage, fd: *const descriptor.FieldDescriptor, storage: *const FieldStorage, mw: *const message.MessageWriter, writer: *std.Io.Writer) !void {
        const field_num: u29 = @intCast(fd.number);
        switch (storage.*) {
            .singular => |val| try encodeScalarValue(fd.field_type, field_num, val, mw, writer, self),
            .repeated => |list| {
                for (list.items) |val| {
                    try encodeScalarValue(fd.field_type, field_num, val, mw, writer, self);
                }
            },
            .map_str, .map_int => {}, // Maps handled separately
        }
    }

    fn encodeScalarValue(ft: descriptor.FieldType, field_num: u29, val: DynamicValue, mw: *const message.MessageWriter, writer: *std.Io.Writer, self: *const DynamicMessage) !void {
        _ = self;
        switch (ft) {
            .double => try mw.write_i64_field(field_num, @bitCast(val.double_val)),
            .float => try mw.write_i32_field(field_num, @bitCast(val.float_val)),
            .int32 => try mw.write_varint_field(field_num, @bitCast(@as(i64, val.int32_val))),
            .int64 => try mw.write_varint_field(field_num, @bitCast(val.int64_val)),
            .uint32 => try mw.write_varint_field(field_num, @as(u64, val.uint32_val)),
            .uint64 => try mw.write_varint_field(field_num, val.uint64_val),
            .sint32 => try mw.write_varint_field(field_num, encoding.zigzag_encode(val.int32_val)),
            .sint64 => try mw.write_varint_field(field_num, encoding.zigzag_encode_64(val.int64_val)),
            .fixed32 => try mw.write_i32_field(field_num, @bitCast(val.uint32_val)),
            .fixed64 => try mw.write_i64_field(field_num, val.uint64_val),
            .sfixed32 => try mw.write_i32_field(field_num, @bitCast(val.int32_val)),
            .sfixed64 => try mw.write_i64_field(field_num, @bitCast(val.int64_val)),
            .bool => try mw.write_varint_field(field_num, @intFromBool(val.bool_val)),
            .string => try mw.write_len_field(field_num, val.string_val),
            .bytes => try mw.write_len_field(field_num, val.bytes_val),
            .enum_type => try mw.write_varint_field(field_num, @bitCast(@as(i64, val.enum_val))),
            .message => {
                const sub_msg = val.message_val;
                const sub_size = sub_msg.calcSize();
                try mw.write_len_prefix(field_num, sub_size);
                try sub_msg.encode(writer);
            },
            .group => {}, // Groups not supported in dynamic messages
        }
    }

    fn encodeMapField(self: *const DynamicMessage, mfd: *const descriptor.MapFieldDescriptor, storage: *const FieldStorage, mw: *const message.MessageWriter, writer: *std.Io.Writer) !void {
        _ = self;
        const field_num: u29 = @intCast(mfd.number);
        switch (storage.*) {
            .map_str => |m| {
                var it = m.iterator();
                while (it.next()) |entry| {
                    const entry_size = calcMapEntrySize(mfd, .{ .string_val = entry.key_ptr.* }, entry.value_ptr.*);
                    try mw.write_len_prefix(field_num, entry_size);
                    // key = field 1, value = field 2
                    try message.MessageWriter.init(writer).write_len_field(1, entry.key_ptr.*);
                    try encodeMapValue(mfd.entry.value_type, 2, entry.value_ptr.*, writer);
                }
            },
            .map_int => |m| {
                var it = m.iterator();
                while (it.next()) |entry| {
                    const key_val = DynamicValue{ .int64_val = entry.key_ptr.* };
                    const entry_size = calcMapEntrySize(mfd, key_val, entry.value_ptr.*);
                    try mw.write_len_prefix(field_num, entry_size);
                    try message.MessageWriter.init(writer).write_varint_field(1, @bitCast(entry.key_ptr.*));
                    try encodeMapValue(mfd.entry.value_type, 2, entry.value_ptr.*, writer);
                }
            },
            else => {},
        }
    }

    fn encodeMapValue(vt: descriptor.FieldType, field_num: u29, val: DynamicValue, writer: *std.Io.Writer) !void {
        const mw = message.MessageWriter.init(writer);
        switch (vt) {
            .string => try mw.write_len_field(field_num, val.string_val),
            .bytes => try mw.write_len_field(field_num, val.bytes_val),
            .int32 => try mw.write_varint_field(field_num, @bitCast(@as(i64, val.int32_val))),
            .int64 => try mw.write_varint_field(field_num, @bitCast(val.int64_val)),
            .uint32 => try mw.write_varint_field(field_num, @as(u64, val.uint32_val)),
            .uint64 => try mw.write_varint_field(field_num, val.uint64_val),
            .bool => try mw.write_varint_field(field_num, @intFromBool(val.bool_val)),
            .double => try mw.write_i64_field(field_num, @bitCast(val.double_val)),
            .float => try mw.write_i32_field(field_num, @bitCast(val.float_val)),
            .enum_type => try mw.write_varint_field(field_num, @bitCast(@as(i64, val.enum_val))),
            .message => {
                const sub_msg = val.message_val;
                const sub_size = sub_msg.calcSize();
                try mw.write_len_prefix(field_num, sub_size);
                try sub_msg.encode(writer);
            },
            else => {},
        }
    }

    fn calcFieldSize(fd: *const descriptor.FieldDescriptor, storage: *const FieldStorage, self: *const DynamicMessage) usize {
        _ = self;
        const field_num: u29 = @intCast(fd.number);
        switch (storage.*) {
            .singular => |val| return calcScalarValueSize(fd.field_type, field_num, val),
            .repeated => |list| {
                var size: usize = 0;
                for (list.items) |val| {
                    size += calcScalarValueSize(fd.field_type, field_num, val);
                }
                return size;
            },
            .map_str, .map_int => return 0, // Maps handled separately
        }
    }

    fn calcScalarValueSize(ft: descriptor.FieldType, field_num: u29, val: DynamicValue) usize {
        return switch (ft) {
            .double => message.i64_field_size(field_num),
            .float => message.i32_field_size(field_num),
            .int32 => message.varint_field_size(field_num, @bitCast(@as(i64, val.int32_val))),
            .int64 => message.varint_field_size(field_num, @bitCast(val.int64_val)),
            .uint32 => message.varint_field_size(field_num, @as(u64, val.uint32_val)),
            .uint64 => message.varint_field_size(field_num, val.uint64_val),
            .sint32 => message.varint_field_size(field_num, encoding.zigzag_encode(val.int32_val)),
            .sint64 => message.varint_field_size(field_num, encoding.zigzag_encode_64(val.int64_val)),
            .fixed32 => message.i32_field_size(field_num),
            .fixed64 => message.i64_field_size(field_num),
            .sfixed32 => message.i32_field_size(field_num),
            .sfixed64 => message.i64_field_size(field_num),
            .bool => message.varint_field_size(field_num, @intFromBool(val.bool_val)),
            .string => message.len_field_size(field_num, val.string_val.len),
            .bytes => message.len_field_size(field_num, val.bytes_val.len),
            .enum_type => message.varint_field_size(field_num, @bitCast(@as(i64, val.enum_val))),
            .message => blk: {
                const sub_size = val.message_val.calcSize();
                break :blk message.len_field_size(field_num, sub_size);
            },
            .group => 0,
        };
    }

    fn calcMapFieldSize(mfd: *const descriptor.MapFieldDescriptor, storage: *const FieldStorage, self: *const DynamicMessage) usize {
        _ = self;
        const field_num: u29 = @intCast(mfd.number);
        var size: usize = 0;
        switch (storage.*) {
            .map_str => |m| {
                var it = m.iterator();
                while (it.next()) |entry| {
                    const entry_size = calcMapEntrySize(mfd, .{ .string_val = entry.key_ptr.* }, entry.value_ptr.*);
                    size += message.len_field_size(field_num, entry_size);
                }
            },
            .map_int => |m| {
                var it = m.iterator();
                while (it.next()) |entry| {
                    const entry_size = calcMapEntrySize(mfd, .{ .int64_val = entry.key_ptr.* }, entry.value_ptr.*);
                    size += message.len_field_size(field_num, entry_size);
                }
            },
            else => {},
        }
        return size;
    }

    fn calcMapEntrySize(mfd: *const descriptor.MapFieldDescriptor, key: DynamicValue, val: DynamicValue) usize {
        var size: usize = 0;
        // key = field 1
        switch (mfd.entry.key_type) {
            .string => size += message.len_field_size(1, key.string_val.len),
            .int32 => size += message.varint_field_size(1, @bitCast(@as(i64, key.int32_val))),
            .int64 => size += message.varint_field_size(1, @bitCast(key.int64_val)),
            .uint32 => size += message.varint_field_size(1, @as(u64, key.uint32_val)),
            .uint64 => size += message.varint_field_size(1, key.uint64_val),
            .bool => size += message.varint_field_size(1, @intFromBool(key.bool_val)),
            .sint32 => size += message.varint_field_size(1, encoding.zigzag_encode(key.int32_val)),
            .sint64 => size += message.varint_field_size(1, encoding.zigzag_encode_64(key.int64_val)),
            .fixed32 => size += message.i32_field_size(1),
            .fixed64 => size += message.i64_field_size(1),
            .sfixed32 => size += message.i32_field_size(1),
            .sfixed64 => size += message.i64_field_size(1),
            else => {},
        }
        // value = field 2
        size += calcScalarValueSize(mfd.entry.value_type, 2, val);
        return size;
    }

    // ── Decode ───────────────────────────────────────────────────────

    /// Deserialize a DynamicMessage from protobuf binary wire format bytes
    pub fn decode(allocator: std.mem.Allocator, desc: *const descriptor.MessageDescriptor, bytes: []const u8) (std.mem.Allocator.Error || message.Error || Error)!DynamicMessage {
        return decode_depth(allocator, desc, bytes, message.default_max_decode_depth);
    }

    /// Deserialize a DynamicMessage with an explicit recursion depth limit
    pub fn decode_depth(allocator: std.mem.Allocator, desc: *const descriptor.MessageDescriptor, bytes: []const u8, depth_remaining: usize) (std.mem.Allocator.Error || message.Error || Error)!DynamicMessage {
        if (depth_remaining == 0) return error.RecursionLimitExceeded;
        var msg = DynamicMessage.init(allocator, desc);
        errdefer msg.deinit();

        var iter = message.FieldIterator{ .data = bytes };
        while (try iter.next()) |field| {
            // Check if it's a map field
            if (findMapFieldByNumber(desc, field.number)) |mfd| {
                try decodeMapEntry(&msg, mfd, field, depth_remaining);
                continue;
            }

            // Regular field
            const fd = findFieldByNumber(desc, field.number) orelse continue;
            try decodeFieldValue(&msg, fd, field, depth_remaining);
        }

        return msg;
    }

    fn findMapFieldByNumber(desc: *const descriptor.MessageDescriptor, number: u29) ?*const descriptor.MapFieldDescriptor {
        for (desc.maps) |*m| {
            if (m.number == @as(i32, number)) return m;
        }
        return null;
    }

    fn decodeFieldValue(msg: *DynamicMessage, fd: *const descriptor.FieldDescriptor, field: message.Field, depth_remaining: usize) !void {
        const val = try wireToValue(msg.allocator, fd.field_type, field, fd, msg.desc, depth_remaining);

        if (fd.label == .repeated) {
            try msg.appendOwned(fd.number, val);
        } else {
            try msg.setOwned(fd.number, val);
        }
    }

    fn wireToValue(allocator: std.mem.Allocator, ft: descriptor.FieldType, field: message.Field, fd: *const descriptor.FieldDescriptor, desc: *const descriptor.MessageDescriptor, depth_remaining: usize) !DynamicValue {
        _ = fd;
        return switch (ft) {
            .double => .{ .double_val = @bitCast(field.value.i64) },
            .float => .{ .float_val = @bitCast(field.value.i32) },
            .int32 => .{ .int32_val = @bitCast(@as(u32, @truncate(field.value.varint))) },
            .int64 => .{ .int64_val = @bitCast(field.value.varint) },
            .uint32 => .{ .uint32_val = @truncate(field.value.varint) },
            .uint64 => .{ .uint64_val = field.value.varint },
            .sint32 => .{ .int32_val = encoding.zigzag_decode(@truncate(field.value.varint)) },
            .sint64 => .{ .int64_val = encoding.zigzag_decode_64(field.value.varint) },
            .fixed32 => .{ .uint32_val = field.value.i32 },
            .fixed64 => .{ .uint64_val = field.value.i64 },
            .sfixed32 => .{ .int32_val = @bitCast(field.value.i32) },
            .sfixed64 => .{ .int64_val = @bitCast(field.value.i64) },
            .bool => .{ .bool_val = field.value.varint != 0 },
            .string => blk: {
                try message.validate_utf8(field.value.len);
                const s = try allocator.dupe(u8, field.value.len);
                break :blk .{ .string_val = s };
            },
            .bytes => blk: {
                const b = try allocator.dupe(u8, field.value.len);
                break :blk .{ .bytes_val = b };
            },
            .enum_type => .{ .enum_val = @bitCast(@as(u32, @truncate(field.value.varint))) },
            .message => blk: {
                // Find the nested message descriptor by type_name
                const sub_desc = findNestedDesc(desc, field.number) orelse
                    return error.UnknownField;
                const sub_msg = try allocator.create(DynamicMessage);
                errdefer allocator.destroy(sub_msg);
                sub_msg.* = try decode_depth(allocator, sub_desc, field.value.len, depth_remaining - 1);
                break :blk .{ .message_val = sub_msg };
            },
            .group => .{ .null_val = {} },
        };
    }

    fn findNestedDesc(desc: *const descriptor.MessageDescriptor, field_number: u29) ?*const descriptor.MessageDescriptor {
        // First find the field to get its type_name
        for (desc.fields) |*f| {
            if (f.number == @as(i32, field_number)) {
                if (f.type_name) |type_name| {
                    // Search nested messages
                    for (desc.nested_messages) |*nm| {
                        if (std.mem.eql(u8, nm.name, type_name) or std.mem.eql(u8, nm.full_name, type_name)) {
                            return nm;
                        }
                    }
                    // Not found in nested — could be a top-level message
                    // For now return null (would need a registry for cross-references)
                    return null;
                }
                return null;
            }
        }
        return null;
    }

    fn decodeMapEntry(msg: *DynamicMessage, mfd: *const descriptor.MapFieldDescriptor, field: message.Field, depth_remaining: usize) !void {
        // Map entries are encoded as length-delimited submessages with field 1 = key, field 2 = value
        var iter = message.FieldIterator{ .data = field.value.len };
        var key_val: ?DynamicValue = null;
        var value_val: ?DynamicValue = null;

        while (try iter.next()) |sub_field| {
            if (sub_field.number == 1) {
                key_val = try wireToMapKeyValue(msg.allocator, mfd.entry.key_type, sub_field);
            } else if (sub_field.number == 2) {
                value_val = try wireToMapValue(msg.allocator, mfd.entry.value_type, sub_field, mfd, msg.desc, depth_remaining);
            }
        }

        if (key_val) |key| {
            const val: DynamicValue = value_val orelse .{ .null_val = {} };
            try msg.putMapOwned(mfd.number, key, val);
        }
    }

    fn wireToMapKeyValue(allocator: std.mem.Allocator, ft: descriptor.FieldType, field: message.Field) !DynamicValue {
        return switch (ft) {
            .string => blk: {
                try message.validate_utf8(field.value.len);
                const s = try allocator.dupe(u8, field.value.len);
                break :blk .{ .string_val = s };
            },
            .int32 => .{ .int32_val = @bitCast(@as(u32, @truncate(field.value.varint))) },
            .int64 => .{ .int64_val = @bitCast(field.value.varint) },
            .uint32 => .{ .uint32_val = @truncate(field.value.varint) },
            .uint64 => .{ .uint64_val = field.value.varint },
            .sint32 => .{ .int32_val = encoding.zigzag_decode(@truncate(field.value.varint)) },
            .sint64 => .{ .int64_val = encoding.zigzag_decode_64(field.value.varint) },
            .bool => .{ .bool_val = field.value.varint != 0 },
            .fixed32 => .{ .uint32_val = field.value.i32 },
            .fixed64 => .{ .uint64_val = field.value.i64 },
            .sfixed32 => .{ .int32_val = @bitCast(field.value.i32) },
            .sfixed64 => .{ .int64_val = @bitCast(field.value.i64) },
            else => .{ .null_val = {} },
        };
    }

    fn wireToMapValue(allocator: std.mem.Allocator, ft: descriptor.FieldType, field: message.Field, mfd: *const descriptor.MapFieldDescriptor, parent_desc: *const descriptor.MessageDescriptor, depth_remaining: usize) !DynamicValue {
        _ = mfd;
        _ = parent_desc;
        return switch (ft) {
            .string => blk: {
                try message.validate_utf8(field.value.len);
                const s = try allocator.dupe(u8, field.value.len);
                break :blk .{ .string_val = s };
            },
            .bytes => blk: {
                const b = try allocator.dupe(u8, field.value.len);
                break :blk .{ .bytes_val = b };
            },
            .int32 => .{ .int32_val = @bitCast(@as(u32, @truncate(field.value.varint))) },
            .int64 => .{ .int64_val = @bitCast(field.value.varint) },
            .uint32 => .{ .uint32_val = @truncate(field.value.varint) },
            .uint64 => .{ .uint64_val = field.value.varint },
            .bool => .{ .bool_val = field.value.varint != 0 },
            .double => .{ .double_val = @bitCast(field.value.i64) },
            .float => .{ .float_val = @bitCast(field.value.i32) },
            .enum_type => .{ .enum_val = @bitCast(@as(u32, @truncate(field.value.varint))) },
            .message => blk: {
                // Without a full registry, we can't resolve cross-references here
                _ = depth_remaining;
                break :blk .{ .null_val = {} };
            },
            else => .{ .null_val = {} },
        };
    }
};

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

test "DynamicMessage: init and deinit" {
    const desc = descriptor.MessageDescriptor{
        .name = "Test",
        .full_name = "Test",
        .fields = &.{
            .{ .name = "x", .number = 1, .field_type = .int32, .label = .implicit },
        },
    };
    var msg = DynamicMessage.init(testing.allocator, &desc);
    defer msg.deinit();
    try testing.expectEqual(@as(usize, 0), msg.fields.count());
}

test "DynamicMessage: set and get scalar" {
    const desc = descriptor.MessageDescriptor{
        .name = "Test",
        .full_name = "Test",
        .fields = &.{
            .{ .name = "x", .number = 1, .field_type = .int32, .label = .implicit },
            .{ .name = "name", .number = 2, .field_type = .string, .label = .implicit },
        },
    };
    var msg = DynamicMessage.init(testing.allocator, &desc);
    defer msg.deinit();

    try msg.set(1, .{ .int32_val = 42 });
    const val = msg.get(1).?;
    try testing.expectEqual(@as(i32, 42), val.singular.int32_val);
}

test "DynamicMessage: set and get by name" {
    const desc = descriptor.MessageDescriptor{
        .name = "Test",
        .full_name = "Test",
        .fields = &.{
            .{ .name = "x", .number = 1, .field_type = .int32, .label = .implicit },
        },
    };
    var msg = DynamicMessage.init(testing.allocator, &desc);
    defer msg.deinit();

    try msg.setByName("x", .{ .int32_val = 99 });
    const val = msg.getByName("x").?;
    try testing.expectEqual(@as(i32, 99), val.singular.int32_val);
    try testing.expect(msg.getByName("unknown") == null);
}

test "DynamicMessage: append repeated" {
    const desc = descriptor.MessageDescriptor{
        .name = "Test",
        .full_name = "Test",
        .fields = &.{
            .{ .name = "items", .number = 1, .field_type = .int32, .label = .repeated },
        },
    };
    var msg = DynamicMessage.init(testing.allocator, &desc);
    defer msg.deinit();

    try msg.append(1, .{ .int32_val = 10 });
    try msg.append(1, .{ .int32_val = 20 });
    try msg.append(1, .{ .int32_val = 30 });
    const val = msg.get(1).?;
    try testing.expectEqual(@as(usize, 3), val.repeated.items.len);
    try testing.expectEqual(@as(i32, 20), val.repeated.items[1].int32_val);
}

test "DynamicMessage: findField and findFieldByNumber" {
    const desc = descriptor.MessageDescriptor{
        .name = "Test",
        .full_name = "Test",
        .fields = &.{
            .{ .name = "x", .number = 1, .field_type = .int32, .label = .implicit },
            .{ .name = "y", .number = 2, .field_type = .string, .label = .implicit },
        },
    };
    const f1 = DynamicMessage.findField(&desc, "x");
    try testing.expect(f1 != null);
    try testing.expectEqual(@as(i32, 1), f1.?.number);

    const f2 = DynamicMessage.findFieldByNumber(&desc, 2);
    try testing.expect(f2 != null);
    try testing.expectEqualStrings("y", f2.?.name);

    try testing.expect(DynamicMessage.findField(&desc, "z") == null);
    try testing.expect(DynamicMessage.findFieldByNumber(&desc, 99) == null);
}

test "DynamicMessage: encode simple message" {
    const desc = descriptor.MessageDescriptor{
        .name = "Test",
        .full_name = "Test",
        .fields = &.{
            .{ .name = "x", .number = 1, .field_type = .int32, .label = .implicit },
            .{ .name = "name", .number = 2, .field_type = .string, .label = .implicit },
        },
    };
    var msg = DynamicMessage.init(testing.allocator, &desc);
    defer msg.deinit();

    try msg.set(1, .{ .int32_val = 150 });
    try msg.set(2, .{ .string_val = "hello" });

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try msg.encode(&writer);
    const encoded = writer.buffered();
    try testing.expect(encoded.len > 0);

    // Verify via decode
    var decoded = try DynamicMessage.decode(testing.allocator, &desc, encoded);
    defer decoded.deinit();

    try testing.expectEqual(@as(i32, 150), decoded.get(1).?.singular.int32_val);
    try testing.expectEqualStrings("hello", decoded.get(2).?.singular.string_val);
}

test "DynamicMessage: encode and decode repeated" {
    const desc = descriptor.MessageDescriptor{
        .name = "Test",
        .full_name = "Test",
        .fields = &.{
            .{ .name = "values", .number = 1, .field_type = .int32, .label = .repeated },
        },
    };
    var msg = DynamicMessage.init(testing.allocator, &desc);
    defer msg.deinit();

    try msg.append(1, .{ .int32_val = 1 });
    try msg.append(1, .{ .int32_val = 2 });
    try msg.append(1, .{ .int32_val = 3 });

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try msg.encode(&writer);
    const encoded = writer.buffered();

    var decoded = try DynamicMessage.decode(testing.allocator, &desc, encoded);
    defer decoded.deinit();

    const vals = decoded.get(1).?.repeated.items;
    try testing.expectEqual(@as(usize, 3), vals.len);
    try testing.expectEqual(@as(i32, 1), vals[0].int32_val);
    try testing.expectEqual(@as(i32, 2), vals[1].int32_val);
    try testing.expectEqual(@as(i32, 3), vals[2].int32_val);
}

test "DynamicMessage: decode unknown fields are skipped" {
    const desc = descriptor.MessageDescriptor{
        .name = "Test",
        .full_name = "Test",
        .fields = &.{
            .{ .name = "x", .number = 1, .field_type = .int32, .label = .implicit },
        },
    };

    // Encode with an extra field (number 2) that's not in the descriptor
    const full_desc = descriptor.MessageDescriptor{
        .name = "Full",
        .full_name = "Full",
        .fields = &.{
            .{ .name = "x", .number = 1, .field_type = .int32, .label = .implicit },
            .{ .name = "y", .number = 2, .field_type = .int32, .label = .implicit },
        },
    };
    var full_msg = DynamicMessage.init(testing.allocator, &full_desc);
    defer full_msg.deinit();
    try full_msg.set(1, .{ .int32_val = 42 });
    try full_msg.set(2, .{ .int32_val = 99 });

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try full_msg.encode(&writer);
    const encoded = writer.buffered();

    // Decode with the partial descriptor — field 2 should be skipped
    var decoded = try DynamicMessage.decode(testing.allocator, &desc, encoded);
    defer decoded.deinit();

    try testing.expectEqual(@as(i32, 42), decoded.get(1).?.singular.int32_val);
    try testing.expect(decoded.get(2) == null);
}

test "DynamicMessage: all scalar types round-trip" {
    const desc = descriptor.MessageDescriptor{
        .name = "AllScalars",
        .full_name = "AllScalars",
        .fields = &.{
            .{ .name = "f_double", .number = 1, .field_type = .double, .label = .implicit },
            .{ .name = "f_float", .number = 2, .field_type = .float, .label = .implicit },
            .{ .name = "f_int32", .number = 3, .field_type = .int32, .label = .implicit },
            .{ .name = "f_int64", .number = 4, .field_type = .int64, .label = .implicit },
            .{ .name = "f_uint32", .number = 5, .field_type = .uint32, .label = .implicit },
            .{ .name = "f_uint64", .number = 6, .field_type = .uint64, .label = .implicit },
            .{ .name = "f_sint32", .number = 7, .field_type = .sint32, .label = .implicit },
            .{ .name = "f_sint64", .number = 8, .field_type = .sint64, .label = .implicit },
            .{ .name = "f_fixed32", .number = 9, .field_type = .fixed32, .label = .implicit },
            .{ .name = "f_fixed64", .number = 10, .field_type = .fixed64, .label = .implicit },
            .{ .name = "f_sfixed32", .number = 11, .field_type = .sfixed32, .label = .implicit },
            .{ .name = "f_sfixed64", .number = 12, .field_type = .sfixed64, .label = .implicit },
            .{ .name = "f_bool", .number = 13, .field_type = .bool, .label = .implicit },
            .{ .name = "f_string", .number = 14, .field_type = .string, .label = .implicit },
            .{ .name = "f_bytes", .number = 15, .field_type = .bytes, .label = .implicit },
        },
    };
    var msg = DynamicMessage.init(testing.allocator, &desc);
    defer msg.deinit();

    try msg.set(1, .{ .double_val = 3.14 });
    try msg.set(2, .{ .float_val = 2.72 });
    try msg.set(3, .{ .int32_val = -42 });
    try msg.set(4, .{ .int64_val = -100000 });
    try msg.set(5, .{ .uint32_val = 42 });
    try msg.set(6, .{ .uint64_val = 100000 });
    try msg.set(7, .{ .int32_val = -7 });
    try msg.set(8, .{ .int64_val = -8 });
    try msg.set(9, .{ .uint32_val = 9 });
    try msg.set(10, .{ .uint64_val = 10 });
    try msg.set(11, .{ .int32_val = -11 });
    try msg.set(12, .{ .int64_val = -12 });
    try msg.set(13, .{ .bool_val = true });
    try msg.set(14, .{ .string_val = "test" });
    try msg.set(15, .{ .bytes_val = "raw" });

    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try msg.encode(&writer);
    const encoded = writer.buffered();

    var decoded = try DynamicMessage.decode(testing.allocator, &desc, encoded);
    defer decoded.deinit();

    try testing.expectEqual(@as(f64, 3.14), decoded.get(1).?.singular.double_val);
    try testing.expectApproxEqAbs(@as(f32, 2.72), decoded.get(2).?.singular.float_val, 0.01);
    try testing.expectEqual(@as(i32, -42), decoded.get(3).?.singular.int32_val);
    try testing.expectEqual(@as(i64, -100000), decoded.get(4).?.singular.int64_val);
    try testing.expectEqual(@as(u32, 42), decoded.get(5).?.singular.uint32_val);
    try testing.expectEqual(@as(u64, 100000), decoded.get(6).?.singular.uint64_val);
    try testing.expectEqual(@as(i32, -7), decoded.get(7).?.singular.int32_val);
    try testing.expectEqual(@as(i64, -8), decoded.get(8).?.singular.int64_val);
    try testing.expectEqual(@as(u32, 9), decoded.get(9).?.singular.uint32_val);
    try testing.expectEqual(@as(u64, 10), decoded.get(10).?.singular.uint64_val);
    try testing.expectEqual(@as(i32, -11), decoded.get(11).?.singular.int32_val);
    try testing.expectEqual(@as(i64, -12), decoded.get(12).?.singular.int64_val);
    try testing.expect(decoded.get(13).?.singular.bool_val);
    try testing.expectEqualStrings("test", decoded.get(14).?.singular.string_val);
    try testing.expectEqualStrings("raw", decoded.get(15).?.singular.bytes_val);
}

test "DynamicMessage: map field encode and decode" {
    const desc = descriptor.MessageDescriptor{
        .name = "Test",
        .full_name = "Test",
        .fields = &.{},
        .maps = &.{
            .{ .name = "labels", .number = 1, .entry = .{ .key_type = .string, .value_type = .string } },
        },
    };
    var msg = DynamicMessage.init(testing.allocator, &desc);
    defer msg.deinit();

    try msg.putMap(1, .{ .string_val = "key1" }, .{ .string_val = "val1" });
    try msg.putMap(1, .{ .string_val = "key2" }, .{ .string_val = "val2" });

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try msg.encode(&writer);
    const encoded = writer.buffered();

    var decoded = try DynamicMessage.decode(testing.allocator, &desc, encoded);
    defer decoded.deinit();

    const map_storage = decoded.get(1).?;
    try testing.expectEqual(@as(usize, 2), map_storage.map_str.count());
    try testing.expectEqualStrings("val1", map_storage.map_str.get("key1").?.string_val);
    try testing.expectEqualStrings("val2", map_storage.map_str.get("key2").?.string_val);
}

test "DynamicMessage: nested message encode and decode" {
    const inner_desc = descriptor.MessageDescriptor{
        .name = "Inner",
        .full_name = "Inner",
        .fields = &.{
            .{ .name = "value", .number = 1, .field_type = .int32, .label = .implicit },
        },
    };
    const outer_desc = descriptor.MessageDescriptor{
        .name = "Outer",
        .full_name = "Outer",
        .fields = &.{
            .{ .name = "name", .number = 1, .field_type = .string, .label = .implicit },
            .{ .name = "inner", .number = 2, .field_type = .message, .label = .optional, .type_name = "Inner" },
        },
        .nested_messages = &.{inner_desc},
    };

    var inner = try testing.allocator.create(DynamicMessage);
    inner.* = DynamicMessage.init(testing.allocator, &inner_desc);
    try inner.set(1, .{ .int32_val = 42 });

    var msg = DynamicMessage.init(testing.allocator, &outer_desc);
    defer msg.deinit();
    try msg.set(1, .{ .string_val = "test" });
    try msg.set(2, .{ .message_val = inner });

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try msg.encode(&writer);
    const encoded = writer.buffered();

    var decoded = try DynamicMessage.decode(testing.allocator, &outer_desc, encoded);
    defer decoded.deinit();

    try testing.expectEqualStrings("test", decoded.get(1).?.singular.string_val);
    const decoded_inner = decoded.get(2).?.singular.message_val;
    try testing.expectEqual(@as(i32, 42), decoded_inner.get(1).?.singular.int32_val);
}

test "DynamicMessage: decode_depth rejects at depth 0" {
    const desc = descriptor.MessageDescriptor{
        .name = "Test",
        .full_name = "Test",
        .fields = &.{
            .{ .name = "x", .number = 1, .field_type = .int32, .label = .implicit },
        },
    };
    // Even a simple message should fail at depth 0
    var buf: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const mw = message.MessageWriter.init(&writer);
    try mw.write_varint_field(1, 42);
    const encoded = writer.buffered();

    try testing.expectError(error.RecursionLimitExceeded, DynamicMessage.decode_depth(testing.allocator, &desc, encoded, 0));
}

test "DynamicMessage: nested decode respects depth limit" {
    const inner_desc = descriptor.MessageDescriptor{
        .name = "Inner",
        .full_name = "Inner",
        .fields = &.{
            .{ .name = "value", .number = 1, .field_type = .int32, .label = .implicit },
        },
    };
    const outer_desc = descriptor.MessageDescriptor{
        .name = "Outer",
        .full_name = "Outer",
        .fields = &.{
            .{ .name = "inner", .number = 1, .field_type = .message, .label = .optional, .type_name = "Inner" },
        },
        .nested_messages = &.{inner_desc},
    };

    // Encode a nested message
    var inner_buf: [32]u8 = undefined;
    var inner_w: std.Io.Writer = .fixed(&inner_buf);
    try message.MessageWriter.init(&inner_w).write_varint_field(1, 42);

    var outer_buf: [64]u8 = undefined;
    var outer_w: std.Io.Writer = .fixed(&outer_buf);
    try message.MessageWriter.init(&outer_w).write_len_field(1, inner_w.buffered());
    const encoded = outer_w.buffered();

    // depth=1 should fail because nested message needs depth=0
    try testing.expectError(error.RecursionLimitExceeded, DynamicMessage.decode_depth(testing.allocator, &outer_desc, encoded, 1));

    // depth=2 should succeed
    var decoded = try DynamicMessage.decode_depth(testing.allocator, &outer_desc, encoded, 2);
    defer decoded.deinit();
    const decoded_inner = decoded.get(1).?.singular.message_val;
    try testing.expectEqual(@as(i32, 42), decoded_inner.get(1).?.singular.int32_val);
}

test "DynamicMessage: decode rejects invalid UTF-8 in string field" {
    const desc = descriptor.MessageDescriptor{
        .name = "Test",
        .full_name = "Test",
        .fields = &.{
            .{ .name = "name", .number = 1, .field_type = .string, .label = .implicit },
        },
    };
    // Encode a string field with invalid UTF-8 bytes
    var buf: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try message.MessageWriter.init(&writer).write_len_field(1, &[_]u8{ 0x80, 0xFF });
    const encoded = writer.buffered();

    try testing.expectError(error.InvalidUtf8, DynamicMessage.decode(testing.allocator, &desc, encoded));
}

test "DynamicMessage: decode accepts valid UTF-8 in string field" {
    const desc = descriptor.MessageDescriptor{
        .name = "Test",
        .full_name = "Test",
        .fields = &.{
            .{ .name = "name", .number = 1, .field_type = .string, .label = .implicit },
        },
    };
    var buf: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try message.MessageWriter.init(&writer).write_len_field(1, "hello");
    const encoded = writer.buffered();

    var decoded = try DynamicMessage.decode(testing.allocator, &desc, encoded);
    defer decoded.deinit();
    try testing.expectEqualStrings("hello", decoded.get(1).?.singular.string_val);
}

test "DynamicMessage: decode allows invalid UTF-8 in bytes field" {
    const desc = descriptor.MessageDescriptor{
        .name = "Test",
        .full_name = "Test",
        .fields = &.{
            .{ .name = "data", .number = 1, .field_type = .bytes, .label = .implicit },
        },
    };
    var buf: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try message.MessageWriter.init(&writer).write_len_field(1, &[_]u8{ 0x80, 0xFF });
    const encoded = writer.buffered();

    var decoded = try DynamicMessage.decode(testing.allocator, &desc, encoded);
    defer decoded.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0xFF }, decoded.get(1).?.singular.bytes_val);
}
