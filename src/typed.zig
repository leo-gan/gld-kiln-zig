//! Comptime-specialized typed Kiln codec.
//! Encodes and decodes native Zig structs and slices directly in positional
//! little-endian Kiln wire order without allocating a dynamic `Value` tree.

const std = @import("std");
const builtin = @import("builtin");
const Error = @import("error.zig").Error;
const limit = @import("limit.zig");
const Writer = @import("writer.zig").Writer;
const Reader = @import("reader.zig").Reader;
const Options = @import("reader.zig").Options;
const bulk = @import("bulk.zig").copy;

fn isPodScalar(comptime T: type) bool {
    return switch (T) {
        i8, i16, i32, i64, u16, u32, u64, f32, f64 => true,
        else => false,
    };
}

/// Minimum wire byte length of a valid value of type `T`.
pub fn minWireSize(comptime T: type) u64 {
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |info| blk: {
            if (info.bits != 8 and info.bits != 16 and info.bits != 32 and info.bits != 64) {
                @compileError("unsupported int width in Kiln typed codec: " ++ @typeName(T));
            }
            break :blk @sizeOf(T);
        },
        .float => |info| blk: {
            if (info.bits != 32 and info.bits != 64) {
                @compileError("unsupported float width in Kiln typed codec: " ++ @typeName(T));
            }
            break :blk @sizeOf(T);
        },
        .optional => 1,
        .pointer => |info| blk: {
            if (info.size != .slice) {
                @compileError("unsupported pointer in Kiln typed codec: " ++ @typeName(T));
            }
            break :blk 4;
        },
        .@"struct" => |info| blk: {
            var total: u64 = 0;
            inline for (info.fields) |f| total += minWireSize(f.type);
            break :blk total;
        },
        else => @compileError("unsupported type in Kiln typed codec: " ++ @typeName(T)),
    };
}

fn fixedWireSize(comptime T: type) ?usize {
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |info| blk: {
            if (info.bits != 8 and info.bits != 16 and info.bits != 32 and info.bits != 64) {
                @compileError("unsupported int width in Kiln typed codec: " ++ @typeName(T));
            }
            break :blk @sizeOf(T);
        },
        .float => |info| blk: {
            if (info.bits != 32 and info.bits != 64) {
                @compileError("unsupported float width in Kiln typed codec: " ++ @typeName(T));
            }
            break :blk @sizeOf(T);
        },
        .optional, .pointer => null,
        .@"struct" => |info| blk: {
            var total: usize = 0;
            inline for (info.fields) |f| {
                const sub = fixedWireSize(f.type) orelse break :blk null;
                total += sub;
            }
            break :blk total;
        },
        else => @compileError("unsupported type in Kiln typed codec: " ++ @typeName(T)),
    };
}

/// Exact wire byte length of `value`, checking depth and count caps.
pub fn encodedSize(value: anytype, cap: u64) Error!usize {
    const n = try encodedSizeDepth(value, cap, 0);
    return std.math.cast(usize, n) orelse error.LIMIT;
}

fn encodedSizeDepth(value: anytype, cap: u64, depth: u32) Error!u64 {
    if (depth > limit.max_depth) return error.LIMIT;
    const T = @TypeOf(value);
    if (comptime fixedWireSize(T)) |fixed| {
        return fixed;
    }
    return switch (@typeInfo(T)) {
        .optional => {
            if (value) |inner| {
                return try limit.add(1, try encodedSizeDepth(inner, cap, depth + 1));
            }
            return 1;
        },
        .pointer => |info| blk: {
            if (info.size != .slice) {
                @compileError("unsupported pointer in Kiln typed codec: " ++ @typeName(T));
            }
            if (@as(u64, value.len) > cap) return error.LIMIT;
            if (value.len > std.math.maxInt(u32)) return error.LIMIT;
            if (info.child == u8) {
                break :blk try limit.add(4, value.len);
            }
            if (comptime fixedWireSize(info.child)) |elem_size| {
                if (value.len != 0 and depth >= limit.max_depth) return error.LIMIT;
                break :blk try limit.add(4, try limit.mul(value.len, elem_size));
            }
            var total: u64 = 4;
            for (value) |item| {
                total = try limit.add(total, try encodedSizeDepth(item, cap, depth + 1));
            }
            break :blk total;
        },
        .@"struct" => |info| blk: {
            var total: u64 = 0;
            inline for (info.fields) |f| {
                if (comptime fixedWireSize(f.type)) |fixed| {
                    if (depth + 1 > limit.max_depth) return error.LIMIT;
                    total = try limit.add(total, fixed);
                } else {
                    total = try limit.add(total, try encodedSizeDepth(@field(value, f.name), cap, depth + 1));
                }
            }
            break :blk total;
        },
        else => @compileError("unsupported type in Kiln typed codec: " ++ @typeName(T)),
    };
}

/// Write `value` into `dest`, which must have at least `encodedSize(value, cap)` bytes.
/// Returns the number of bytes written.
pub fn writeTypedUnchecked(dest: []u8, value: anytype) usize {
    var pos: usize = 0;
    writeAt(dest.ptr, &pos, value);
    return pos;
}

fn writeAt(base: [*]u8, pos: *usize, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => {
            base[pos.*] = if (value) 1 else 0;
            pos.* += 1;
        },
        .int => {
            const n = @sizeOf(T);
            std.mem.writeInt(T, @ptrCast(base + pos.*), value, .little);
            pos.* += n;
        },
        .float => |info| {
            const U = std.meta.Int(.unsigned, info.bits);
            const n = @sizeOf(U);
            std.mem.writeInt(U, @ptrCast(base + pos.*), @bitCast(value), .little);
            pos.* += n;
        },
        .optional => {
            if (value) |inner| {
                base[pos.*] = 1;
                pos.* += 1;
                writeAt(base, pos, inner);
            } else {
                base[pos.*] = 0;
                pos.* += 1;
            }
        },
        .pointer => |info| {
            if (info.size != .slice) {
                @compileError("unsupported pointer in Kiln typed codec: " ++ @typeName(T));
            }
            const count: u32 = @intCast(value.len);
            std.mem.writeInt(u32, @ptrCast(base + pos.*), count, .little);
            pos.* += 4;
            if (info.child == u8) {
                if (value.len != 0) {
                    bulk(base[pos.* .. pos.* + value.len], value);
                    pos.* += value.len;
                }
            } else if (comptime isPodScalar(info.child) and builtin.cpu.arch.endian() == .little) {
                if (value.len != 0) {
                    const body = std.mem.sliceAsBytes(value);
                    bulk(base[pos.* .. pos.* + body.len], body);
                    pos.* += body.len;
                }
            } else {
                for (value) |item| {
                    writeAt(base, pos, item);
                }
            }
        },
        .@"struct" => |info| {
            inline for (info.fields) |f| {
                writeAt(base, pos, @field(value, f.name));
            }
        },
        else => @compileError("unsupported type in Kiln typed codec: " ++ @typeName(T)),
    }
}

/// Encode `value` into a caller-provided slice, checking caps and capacity.
pub fn encodeTypedInto(dest: []u8, value: anytype, cap: u64) Error![]u8 {
    const need = try encodedSize(value, cap);
    if (dest.len < need) return error.LIMIT;
    _ = writeTypedUnchecked(dest[0..need], value);
    return dest[0..need];
}

/// Encode `value` into a reused `Writer` with one capacity reservation.
pub fn encodeTypedReuse(writer: *Writer, gpa: std.mem.Allocator, value: anytype) Error![]const u8 {
    writer.reset();
    const need = try encodedSize(value, writer.cap);
    const dest = try writer.list.addManyAsSlice(gpa, need);
    _ = writeTypedUnchecked(dest, value);
    return writer.slice();
}

/// Encode `value` into a newly allocated buffer sized once up front.
pub fn encodeTyped(gpa: std.mem.Allocator, value: anytype, opts: Options) Error![]u8 {
    const need = try encodedSize(value, opts.cap);
    const dest = try gpa.alloc(u8, need);
    _ = writeTypedUnchecked(dest, value);
    return dest;
}

/// Decode a complete Kiln payload into a native Zig value of type `T`.
pub fn decodeTyped(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8, opts: Options) Error!T {
    var reader = Reader.init(bytes, opts);
    const out = try readTyped(T, &reader, allocator);
    try reader.finish();
    return out;
}

/// Decode one value of type `T` from an active `Reader`.
pub fn readTyped(comptime T: type, r: *Reader, allocator: std.mem.Allocator) Error!T {
    return readTypedDepth(T, r, allocator, 0);
}

fn readTypedDepth(comptime T: type, r: *Reader, allocator: std.mem.Allocator, depth: u32) Error!T {
    if (depth > limit.max_depth) return error.LIMIT;
    return switch (@typeInfo(T)) {
        .bool => try r.boolean(),
        .int => try r.int(T),
        .float => |info| switch (info.bits) {
            32 => try r.float32(),
            64 => try r.float64(),
            else => @compileError("unsupported float width in Kiln typed codec: " ++ @typeName(T)),
        },
        .optional => |info| blk: {
            if (!try r.optTag()) break :blk null;
            break :blk try readTypedDepth(info.child, r, allocator, depth + 1);
        },
        .pointer => |info| blk: {
            if (info.size != .slice) {
                @compileError("unsupported pointer in Kiln typed codec: " ++ @typeName(T));
            }
            if (info.child == u8) {
                const raw = try r.str();
                break :blk try allocator.dupe(u8, raw);
            }
            const each = comptime minWireSize(info.child);
            const count: usize = @intCast(try r.listHeader(each));
            if (count == 0) break :blk try allocator.alloc(info.child, 0);
            if (depth >= limit.max_depth) return error.LIMIT;
            const out = try allocator.alloc(info.child, count);
            if (comptime info.child == f32) {
                try r.float32s(out);
            } else if (comptime info.child == f64) {
                try r.float64s(out);
            } else if (comptime isPodScalar(info.child)) {
                try r.pod(info.child, out);
            } else {
                for (out) |*slot| {
                    slot.* = try readTypedDepth(info.child, r, allocator, depth + 1);
                }
            }
            break :blk out;
        },
        .@"struct" => |info| blk: {
            const min_bytes = comptime minWireSize(T);
            if (r.buf.len - r.i < min_bytes) return error.EOF;
            var out: T = undefined;
            inline for (info.fields) |f| {
                @field(out, f.name) = try readTypedDepth(f.type, r, allocator, depth + 1);
            }
            break :blk out;
        },
        else => @compileError("unsupported type in Kiln typed codec: " ++ @typeName(T)),
    };
}

test "typed codec matches dynamic wire format and enforces limits" {
    const Item = struct {
        sku: []const u8,
        qty: i32,
        price: i64,
    };
    const Doc = struct {
        ok: bool,
        id: []const u8,
        scores: []const f64,
        note: ?[]const u8,
        items: []const Item,
    };

    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Item{
        .{ .sku = "A-1", .qty = 2, .price = 1999 },
        .{ .sku = "héllo-🚀", .qty = -3, .price = 0 },
    };
    const scores = [_]f64{ 1.5, -0.0, 42.25 };
    const doc = Doc{
        .ok = true,
        .id = "doc-0123456789abcdef-extra",
        .scores = &scores,
        .note = "present",
        .items = &items,
    };

    var writer = Writer{};
    defer writer.deinit(gpa);
    const wire = try encodeTypedReuse(&writer, gpa, doc);
    const wire2 = try encodeTyped(gpa, doc, .{});
    defer gpa.free(wire2);
    try std.testing.expectEqualSlices(u8, wire, wire2);

    // Compare byte-for-byte with dynamic schema encoder.
    const schema = try @import("schema.zig").parseTypeText(
        alloc,
        "struct{ok:bool,id:str,scores:list<f64>,note:opt<str>,items:list<struct{sku:str,qty:i32,price:i64}>}",
    );
    const item0 = [_]@import("value.zig").FieldValue{
        .{ .name = "sku", .value = .{ .str = "A-1" } },
        .{ .name = "qty", .value = .{ .int = 2 } },
        .{ .name = "price", .value = .{ .int = 1999 } },
    };
    const item1 = [_]@import("value.zig").FieldValue{
        .{ .name = "sku", .value = .{ .str = "héllo-🚀" } },
        .{ .name = "qty", .value = .{ .int = -3 } },
        .{ .name = "price", .value = .{ .int = 0 } },
    };
    const list_vals = [_]@import("value.zig").Value{
        .{ .structure = &item0 },
        .{ .structure = &item1 },
    };
    const root_fields = [_]@import("value.zig").FieldValue{
        .{ .name = "ok", .value = .{ .boolean = true } },
        .{ .name = "id", .value = .{ .str = doc.id } },
        .{ .name = "scores", .value = .{ .f64s = .{ .items = &scores } } },
        .{ .name = "note", .value = .{ .str = "present" } },
        .{ .name = "items", .value = .{ .list = &list_vals } },
    };
    const dyn = try @import("frozen_enc.zig").encode(gpa, schema, .{ .structure = &root_fields }, .{});
    defer gpa.free(dyn);
    try std.testing.expectEqualSlices(u8, dyn, wire);

    // Decode round-trip.
    const back = try decodeTyped(Doc, alloc, wire, .{});
    try std.testing.expectEqual(doc.ok, back.ok);
    try std.testing.expectEqualStrings(doc.id, back.id);
    try std.testing.expectEqualSlices(f64, doc.scores, back.scores);
    try std.testing.expectEqualStrings("present", back.note.?);
    try std.testing.expectEqual(@as(usize, 2), back.items.len);
    try std.testing.expectEqualStrings("héllo-🚀", back.items[1].sku);

    // Reject trailing bytes, bad UTF-8, bad bool, and hostile list counts.
    var trailing = try gpa.alloc(u8, wire.len + 1);
    defer gpa.free(trailing);
    @memcpy(trailing[0..wire.len], wire);
    trailing[wire.len] = 0;
    try std.testing.expectError(error.TRAILING, decodeTyped(Doc, alloc, trailing, .{}));

    const bad_bool = [_]u8{2};
    try std.testing.expectError(error.TYPE, decodeTyped(bool, alloc, &bad_bool, .{}));

    const bad_utf8 = [_]u8{ 2, 0, 0, 0, 0xFF, 0xFE };
    try std.testing.expectError(error.UTF8, decodeTyped([]const u8, alloc, &bad_utf8, .{}));

    const hostile = [_]u8{ 0xFF, 0xFF, 0xFF, 0x7F };
    try std.testing.expectError(error.LIMIT, decodeTyped([]const i64, alloc, &hostile, .{}));
}
