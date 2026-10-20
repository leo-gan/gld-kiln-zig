//! Canonical version-2 tensor directory encoder.

const std = @import("std");
const Error = @import("error.zig").Error;
const limit = @import("limit.zig");
const Tensor = @import("value.zig").Tensor;
const Writer = @import("writer.zig").Writer;
const t = @import("tensor.zig");

pub fn encodeTensors(gpa: std.mem.Allocator, tensors: []const Tensor) Error![]u8 {
    var writer = Writer{};
    errdefer writer.deinit(gpa);
    try encodeTensorsTo(&writer, gpa, tensors);
    return writer.toOwned(gpa);
}

pub fn encodeTensorsTo(writer: *Writer, gpa: std.mem.Allocator, tensors: []const Tensor) Error!void {
    if (tensors.len > std.math.maxInt(u32)) return error.LIMIT;
    const count: u32 = @intCast(tensors.len);
    var names_len: u64 = 0;
    var layouts_len: u64 = 0;
    var payload_bytes: u64 = 0;
    var any_name = false;
    for (tensors) |tensor| {
        if (tensor.name) |name| if (name.len != 0) {
            any_name = true;
            names_len = try limit.add(names_len, name.len);
        };
        if (tensor.layout) |layout| if (layout.len != 0) {
            layouts_len = try limit.add(layouts_len, layout.len);
        };
        const aligned = try limit.align64(payload_bytes);
        payload_bytes = try limit.add(aligned, tensor.data.len);
    }
    const name_bytes = try limit.add(names_len, layouts_len);
    if (name_bytes > std.math.maxInt(u32) or names_len > std.math.maxInt(u16)) return error.LIMIT;
    const directory_bytes = try limit.add(try limit.mul(count, t.desc_len), name_bytes);
    const directory_end = try limit.add(t.header_len, directory_bytes);
    const payload_base = try limit.align64(directory_end);
    const block = try limit.add(payload_base, payload_bytes);
    const dest = try writer.list.addManyAsSlice(gpa, std.math.cast(usize, block) orelse return error.LIMIT);
    const prefix: usize = @intCast(payload_base);
    @memset(dest[0..prefix], 0);
    @memcpy(dest[0..4], "KLNT");
    dest[4] = 2;
    dest[5] = t.flag_le | if (any_name) t.flag_name else 0;
    t.putU32(dest, 8, count);
    t.putU32(dest, 12, @intCast(name_bytes));
    t.putU64(dest, 16, payload_bytes);
    t.putU64(dest, 24, directory_bytes);

    var name_cursor: u64 = 0;
    var layout_cursor: u64 = names_len;
    var payload_cursor: u64 = 0;
    for (tensors, 0..) |tensor, index| {
        const base = t.header_len + index * t.desc_len;
        const name = nonempty(tensor.name);
        const layout = nonempty(tensor.layout);
        const name_off: u16 = if (name != null) std.math.cast(u16, name_cursor) orelse return error.LIMIT else 0xFFFF;
        const name_len: u16 = if (name) |s| std.math.cast(u16, s.len) orelse return error.LIMIT else 0;
        const layout_off: u16 = if (layout != null) std.math.cast(u16, layout_cursor) orelse return error.LIMIT else 0xFFFF;
        const layout_len: u16 = if (layout) |s| std.math.cast(u16, s.len) orelse return error.LIMIT else 0;
        if (name) |s| name_cursor += s.len;
        if (layout) |s| layout_cursor += s.len;
        const off = try limit.align64(payload_cursor);
        payload_cursor = try limit.add(off, tensor.data.len);
        t.putU16(dest, base, tensor.dtype);
        dest[base + 2] = tensor.rank;
        t.putU16(dest, base + 4, name_off);
        t.putU16(dest, base + 6, name_len);
        t.putU16(dest, base + 8, layout_off);
        t.putU16(dest, base + 10, layout_len);
        t.putU32(dest, base + 12, tensor.block_size);
        t.putU16(dest, base + 16, tensor.quant_scheme);
        t.putU16(dest, base + 18, tensor.quant_axis);
        t.putU32(dest, base + 20, tensor.group_size);
        t.putU32(dest, base + 24, tensor.scale_index);
        t.putU32(dest, base + 28, tensor.outer_index);
        t.putU64(dest, base + 32, off);
        t.putU64(dest, base + 40, tensor.data.len);
        for (0..8) |dim| t.putU64(dest, base + 48 + dim * 8, tensor.shape[dim]);
    }
    var heap_at: usize = t.header_len + @as(usize, count) * t.desc_len;
    for (tensors) |tensor| if (nonempty(tensor.name)) |name| {
        @memcpy(dest[heap_at..][0..name.len], name);
        heap_at += name.len;
    };
    for (tensors) |tensor| if (nonempty(tensor.layout)) |layout| {
        @memcpy(dest[heap_at..][0..layout.len], layout);
        heap_at += layout.len;
    };
    payload_cursor = 0;
    for (tensors) |tensor| {
        const off = try limit.align64(payload_cursor);
        if (off > payload_cursor) {
            const gap_at: usize = @intCast(payload_base + payload_cursor);
            const gap_end: usize = @intCast(payload_base + off);
            @memset(dest[gap_at..gap_end], 0);
        }
        const at: usize = @intCast(payload_base + off);
        @memcpy(dest[at..][0..tensor.data.len], tensor.data);
        payload_cursor = off + tensor.data.len;
    }
}

fn nonempty(text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    if (value.len == 0) return null;
    return value;
}

test "empty directory and one f32 vector" {
    const gpa = std.testing.allocator;
    const empty = try encodeTensors(gpa, &.{});
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 64), empty.len);
    try std.testing.expectEqualSlices(u8, "KLNT", empty[0..4]);
    try std.testing.expectEqual(@as(u8, 2), empty[5]);

    var shape = [_]u64{0} ** 8;
    shape[0] = 2;
    const data = [_]u8{ 0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x00, 0xc0 };
    const tensors = [_]Tensor{.{ .dtype = 2, .rank = 1, .shape = shape, .data = &data }};
    const encoded = try encodeTensors(gpa, &tensors);
    defer gpa.free(encoded);
    var slot: [1]Tensor = undefined;
    const directory = try @import("tensor_dec.zig").decodeTensorsInto(encoded, &slot, .{});
    try std.testing.expectEqual(@as(u64, 200), directory.block_length);
    try std.testing.expectEqualSlices(u8, &data, slot[0].data);
    const again = try encodeTensors(gpa, directory.tensors);
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, encoded, again);
}

test "payload overflow does not allocate" {
    var buf = [_]u8{0} ** 64;
    @memcpy(buf[0..4], "KLNT");
    buf[4] = 2;
    buf[5] = 2;
    std.mem.writeInt(u64, buf[16..24], std.math.maxInt(u64), .little);
    try std.testing.expectError(error.LIMIT, @import("tensor_dec.zig").decodeTensors(std.testing.allocator, &buf, .{}));
}
