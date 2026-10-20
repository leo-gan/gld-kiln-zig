//! Encode one Frozen value into a reusable buffer.

const std = @import("std");
const Error = @import("error.zig").Error;
const Schema = @import("schema.zig").Schema;
const limit = @import("limit.zig");
const Options = @import("reader.zig").Options;
const Value = @import("value.zig").Value;
const FieldValue = @import("value.zig").FieldValue;
const DictEntry = @import("value.zig").DictEntry;
const Writer = @import("writer.zig").Writer;
const encodeTensorsTo = @import("tensor_enc.zig").encodeTensorsTo;
const typeHash = @import("hashing.zig").typeHash;

pub fn encode(gpa: std.mem.Allocator, schema: *const Schema, value: Value, opts: Options) Error![]u8 {
    var writer = Writer{ .cap = opts.cap };
    errdefer writer.deinit(gpa);
    try writeValue(&writer, gpa, schema, value, 0);
    return writer.toOwned(gpa);
}

pub fn encodeFramed(gpa: std.mem.Allocator, schema: *const Schema, value: Value, opts: Options) Error![]u8 {
    var writer = Writer{ .cap = opts.cap };
    errdefer writer.deinit(gpa);
    try writer.raw(gpa, "KLN0");
    try writer.int(gpa, u32, 0);
    try writer.int(gpa, u64, try typeHash(schema));
    try writeValue(&writer, gpa, schema, value, 0);
    return writer.toOwned(gpa);
}

pub fn encodeReuse(writer: *Writer, gpa: std.mem.Allocator, schema: *const Schema, value: Value) Error![]const u8 {
    const cap = writer.cap;
    writer.reset();
    writer.cap = cap;
    try writeValue(writer, gpa, schema, value, 0);
    return writer.slice();
}

pub fn writeValue(w: *Writer, gpa: std.mem.Allocator, schema: *const Schema, value: Value, depth: u32) Error!void {
    if (depth > limit.max_depth) return error.LIMIT;
    switch (schema.kind) {
        .boolean => try w.boolean(gpa, value.boolean),
        .i8 => try w.narrow(gpa, i8, try signed(value)),
        .i16 => try w.narrow(gpa, i16, try signed(value)),
        .i32 => try w.narrow(gpa, i32, try signed(value)),
        .i64, .int => try w.int(gpa, i64, try signed(value)),
        .u8 => try w.narrowUnsigned(gpa, u8, try unsigned(value)),
        .u16 => try w.narrowUnsigned(gpa, u16, try unsigned(value)),
        .u32 => try w.narrowUnsigned(gpa, u32, try unsigned(value)),
        .u64, .uint => try w.int(gpa, u64, try unsigned(value)),
        .f32 => try w.float32(gpa, value.f32),
        .f64 => try w.float64(gpa, value.f64),
        .str => try w.str(gpa, value.str),
        .bytes => try w.bytes(gpa, value.bytes),
        .tensors => try encodeTensorsTo(w, gpa, value.tensors.tensors),
        .opt => {
            if (value == .none) {
                try w.int(gpa, u8, 0);
                return;
            }
            try w.int(gpa, u8, 1);
            try writeValue(w, gpa, schema.child.?, value, depth + 1);
        },
        .list => try writeList(w, gpa, schema.child.?, value, depth),
        .dict => try writeDict(w, gpa, schema.child.?, value, depth),
        .structure => {
            for (schema.fields) |field| {
                try writeValue(w, gpa, field.schema, try lookup(value.structure, field.name), depth + 1);
            }
        },
    }
}

fn signed(value: Value) Error!i64 {
    return switch (value) {
        .int => |n| n,
        .uint => |n| std.math.cast(i64, n) orelse error.TYPE,
        else => error.TYPE,
    };
}

fn unsigned(value: Value) Error!u64 {
    return switch (value) {
        .uint => |n| n,
        .int => |n| if (n < 0) error.TYPE else @intCast(n),
        else => error.TYPE,
    };
}

fn writeList(w: *Writer, gpa: std.mem.Allocator, elem: *const Schema, value: Value, depth: u32) Error!void {
    if (elem.kind == .u8 and value == .bytes) {
        try w.bytes(gpa, value.bytes);
        return;
    }
    const items = value.list;
    if (items.len > w.cap) return error.LIMIT;
    const count = std.math.cast(u32, items.len) orelse return error.LIMIT;
    try w.int(gpa, u32, count);
    for (items) |item| try writeValue(w, gpa, elem, item, depth + 1);
}

fn writeDict(w: *Writer, gpa: std.mem.Allocator, elem: *const Schema, value: Value, depth: u32) Error!void {
    const items = value.dict;
    if (items.len > w.cap) return error.LIMIT;
    const copy = try gpa.alloc(DictEntry, items.len);
    defer gpa.free(copy);
    @memcpy(copy, items);
    std.sort.pdq(DictEntry, copy, {}, struct {
        fn less(_: void, a: DictEntry, b: DictEntry) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.less);
    try w.int(gpa, u32, std.math.cast(u32, copy.len) orelse return error.LIMIT);
    const key_schema = Schema{ .kind = .str };
    for (copy) |entry| {
        try writeValue(w, gpa, &key_schema, .{ .str = entry.key }, depth + 1);
        try writeValue(w, gpa, elem, entry.value, depth + 1);
    }
}

fn lookup(fields: []const FieldValue, name: []const u8) Error!Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.TYPE;
}
