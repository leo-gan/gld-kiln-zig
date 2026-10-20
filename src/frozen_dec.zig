//! Decode one Frozen value. Containers are checked before their storage is allocated.

const std = @import("std");
const Error = @import("error.zig").Error;
const Schema = @import("schema.zig").Schema;
const minSize = @import("schema.zig").minSize;
const limit = @import("limit.zig");
const Reader = @import("reader.zig").Reader;
const Options = @import("reader.zig").Options;
const Value = @import("value.zig").Value;
const FieldValue = @import("value.zig").FieldValue;
const DictEntry = @import("value.zig").DictEntry;
const decodeTensors = @import("tensor_dec.zig").decodeTensors;
const typeHash = @import("hashing.zig").typeHash;

const str_schema = Schema{ .kind = .str };

pub fn decode(gpa: std.mem.Allocator, schema: *const Schema, buf: []const u8, opts: Options) Error!Value {
    var reader = Reader.init(buf, opts);
    const value = try readValue(&reader, gpa, schema, 0);
    if (opts.standalone and reader.i != buf.len) {
        var doomed = value;
        doomed.deinit(gpa);
        return error.TRAILING;
    }
    return value;
}

pub fn decodeFramed(gpa: std.mem.Allocator, schema: *const Schema, buf: []const u8, opts: Options) Error!Value {
    if (buf.len < 16) return error.EOF;
    if (!std.mem.eql(u8, buf[0..4], "KLN0") or !std.mem.allEqual(u8, buf[4..8], 0)) return error.FRAME;
    const hash = std.mem.readInt(u64, buf[8..16], .little);
    if (hash != try typeHash(schema)) return error.SCHEMA;
    var reader = Reader.init(buf, opts);
    reader.i = 16;
    const value = try readValue(&reader, gpa, schema, 0);
    if (reader.i != buf.len) {
        var doomed = value;
        doomed.deinit(gpa);
        return error.TRAILING;
    }
    return value;
}

pub fn readValue(r: *Reader, gpa: std.mem.Allocator, schema: *const Schema, depth: u32) Error!Value {
    if (depth > limit.max_depth) return error.LIMIT;
    return switch (schema.kind) {
        .boolean => .{ .boolean = try r.boolean() },
        .i8 => .{ .int = try r.int(i8) },
        .i16 => .{ .int = try r.int(i16) },
        .i32 => .{ .int = try r.int(i32) },
        .i64, .int => .{ .int = try r.int(i64) },
        .u8 => .{ .uint = try r.int(u8) },
        .u16 => .{ .uint = try r.int(u16) },
        .u32 => .{ .uint = try r.int(u32) },
        .u64, .uint => .{ .uint = try r.int(u64) },
        .f32 => .{ .f32 = try r.float32() },
        .f64 => .{ .f64 = try r.float64() },
        .str => .{ .str = try r.str() },
        .bytes => .{ .bytes = try r.bytes() },
        .tensors => try readTensors(r, gpa),
        .opt => if (!try r.optTag()) .none else try readValue(r, gpa, schema.child.?, depth + 1),
        .list => try readList(r, gpa, schema.child.?, depth),
        .dict => try readDict(r, gpa, schema.child.?, depth),
        .structure => try readStruct(r, gpa, schema, depth),
    };
}

fn readTensors(r: *Reader, gpa: std.mem.Allocator) Error!Value {
    const directory = try decodeTensors(gpa, r.buf[r.i..], .{
        .cap = r.cap,
        .standalone = false,
        .check_utf8 = r.check_utf8,
        .check_quant = r.check_quant,
    });
    r.i += std.math.cast(usize, directory.block_length) orelse return error.LIMIT;
    return .{ .tensors = directory };
}

fn readList(r: *Reader, gpa: std.mem.Allocator, elem: *const Schema, depth: u32) Error!Value {
    const count = try r.listHeader(try minSize(elem));
    if (elem.kind == .u8) {
        if (count > r.remaining()) return error.EOF;
        const start = r.i;
        r.i += count;
        return .{ .bytes = r.buf[start..r.i] };
    }
    if (count == 0) return .{ .list = &[_]Value{} };
    const items = try gpa.alloc(Value, count);
    var filled: usize = 0;
    errdefer {
        for (items[0..filled]) |*item| item.deinit(gpa);
        gpa.free(items);
    }
    for (items) |*slot| {
        slot.* = try readValue(r, gpa, elem, depth + 1);
        filled += 1;
    }
    return .{ .list = items };
}

fn readDict(r: *Reader, gpa: std.mem.Allocator, elem: *const Schema, depth: u32) Error!Value {
    const count = try r.listHeader(4);
    if (count == 0) return .{ .dict = &[_]DictEntry{} };
    const items = try gpa.alloc(DictEntry, count);
    var filled: usize = 0;
    errdefer {
        for (items[0..filled]) |*item| item.value.deinit(gpa);
        gpa.free(items);
    }
    var prev: ?[]const u8 = null;
    for (items) |*slot| {
        const key = try readValue(r, gpa, &str_schema, depth + 1);
        if (prev) |seen| if (std.mem.order(u8, key.str, seen) == .lt) return error.TYPE;
        prev = key.str;
        slot.* = .{ .key = key.str, .value = try readValue(r, gpa, elem, depth + 1) };
        filled += 1;
    }
    return .{ .dict = items };
}

fn readStruct(r: *Reader, gpa: std.mem.Allocator, schema: *const Schema, depth: u32) Error!Value {
    if (schema.fields.len == 0) return .{ .structure = &[_]FieldValue{} };
    const fields = try gpa.alloc(FieldValue, schema.fields.len);
    var filled: usize = 0;
    errdefer {
        for (fields[0..filled]) |*field| field.value.deinit(gpa);
        gpa.free(fields);
    }
    for (schema.fields, fields) |spec, *slot| {
        slot.* = .{ .name = spec.name, .value = try readValue(r, gpa, spec.schema, depth + 1) };
        filled += 1;
    }
    return .{ .structure = fields };
}
