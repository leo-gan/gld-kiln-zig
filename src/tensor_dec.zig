//! Decode a version-2 tensor directory. Payload bytes borrow `buf`.

const std = @import("std");
const Error = @import("error.zig").Error;
const limit = @import("limit.zig");
const Options = @import("reader.zig").Options;
const Tensor = @import("value.zig").Tensor;
const TensorDirectory = @import("value.zig").TensorDirectory;
const t = @import("tensor.zig");

pub fn decodeTensors(gpa: std.mem.Allocator, buf: []const u8, opts: Options) Error!TensorDirectory {
    const info = try t.readHeader(buf, opts.cap);
    const out = try gpa.alloc(Tensor, info.count);
    errdefer gpa.free(out);
    try validate(buf, info, opts);
    fill(buf, info, out);
    if (opts.standalone and info.block_end != @as(u64, buf.len)) return error.TRAILING;
    return .{
        .version = 2,
        .flags = info.flags,
        .tensors = out,
        .block_length = info.block_end,
    };
}

pub fn decodeTensorsInto(buf: []const u8, out: []Tensor, opts: Options) Error!TensorDirectory {
    const info = try t.readHeader(buf, opts.cap);
    if (out.len < info.count) return error.LIMIT;
    try validate(buf, info, opts);
    fill(buf, info, out[0..info.count]);
    if (opts.standalone and info.block_end != @as(u64, buf.len)) return error.TRAILING;
    return .{
        .version = 2,
        .flags = info.flags,
        .tensors = out[0..info.count],
        .block_length = info.block_end,
    };
}

fn validate(buf: []const u8, info: t.Header, opts: Options) Error!void {
    for (0..info.count) |index| {
        const desc = t.descriptor(buf, index);
        if (!std.mem.allEqual(u8, desc[112..128], 0)) return error.FRAME;
    }
    const named = (info.flags & t.flag_name) != 0;
    var has_name = false;
    var missing_name = false;
    for (0..info.count) |index| {
        const len = t.u16At(t.descriptor(buf, index), 6);
        if (len != 0) has_name = true else missing_name = true;
    }
    if (named != has_name or (named and missing_name)) return error.TYPE;
    try namesAndLayouts(buf, info, opts.check_utf8);
    try packedHeap(buf, info);
    try ranges(buf, info);
    try gaps(buf, info);
    if (opts.check_quant) try quants(buf, info);
}

fn heapSlice(buf: []const u8, info: t.Header) []const u8 {
    const start = t.header_len + @as(usize, info.count) * t.desc_len;
    return buf[start..@intCast(info.directory_end)];
}

fn sliceAt(heap: []const u8, off: u16, len: u16) Error![]const u8 {
    const end = try limit.add(off, len);
    if (end > heap.len) return error.TYPE;
    return heap[@intCast(off)..@intCast(end)];
}

fn namesAndLayouts(buf: []const u8, info: t.Header, utf8: bool) Error!void {
    const heap = heapSlice(buf, info);
    for (0..info.count) |index| {
        const desc = t.descriptor(buf, index);
        if (desc[3] != 0) return error.FRAME;
        const name_off = t.u16At(desc, 4);
        const name_len = t.u16At(desc, 6);
        if (name_len == 0) {
            if (name_off != 0xFFFF) return error.TYPE;
        } else {
            if (name_off == 0xFFFF) return error.TYPE;
            const name = try sliceAt(heap, name_off, name_len);
            if (utf8 and !std.unicode.utf8ValidateSlice(name)) return error.UTF8;
            for (0..index) |prev| {
                const older = t.descriptor(buf, prev);
                const older_len = t.u16At(older, 6);
                if (older_len == 0) continue;
                const prev_name = try sliceAt(heap, t.u16At(older, 4), older_len);
                if (std.mem.eql(u8, name, prev_name)) return error.TYPE;
            }
        }
        const layout_off = t.u16At(desc, 8);
        const layout_len = t.u16At(desc, 10);
        if (layout_len == 0) {
            if (layout_off != 0xFFFF) return error.TYPE;
        } else {
            if (layout_off == 0xFFFF) return error.TYPE;
            const layout = try sliceAt(heap, layout_off, layout_len);
            if (utf8 and !std.unicode.utf8ValidateSlice(layout)) return error.UTF8;
        }
    }
}

fn packedHeap(buf: []const u8, info: t.Header) Error!void {
    var cursor: u64 = 0;
    for (0..info.count) |index| {
        const desc = t.descriptor(buf, index);
        const len = t.u16At(desc, 6);
        if (len == 0) continue;
        if (t.u16At(desc, 4) != cursor) return error.TYPE;
        cursor = try limit.add(cursor, len);
    }
    for (0..info.count) |index| {
        const desc = t.descriptor(buf, index);
        const len = t.u16At(desc, 10);
        if (len == 0) continue;
        if (t.u16At(desc, 8) != cursor) return error.TYPE;
        cursor = try limit.add(cursor, len);
    }
    if (cursor != info.name_bytes) return error.TYPE;
}

fn payload(buf: []const u8, info: t.Header) []const u8 {
    return buf[@intCast(info.payload_base)..@intCast(info.block_end)];
}

fn ranges(buf: []const u8, info: t.Header) Error!void {
    const bytes = payload(buf, info);
    for (0..info.count) |index| {
        const desc = t.descriptor(buf, index);
        const off = t.u64At(desc, 32);
        const len = t.u64At(desc, 40);
        const end = try limit.add(off, len);
        if (end > info.payload_bytes) return error.TYPE;
        const shape = t.shapeOf(desc);
        try t.checkTensor(t.u16At(desc, 0), desc[2], &shape, t.u16At(desc, 10), t.u32At(desc, 12), len);
    }
    for (0..info.count) |left| {
        const a_desc = t.descriptor(buf, left);
        const a0 = t.u64At(a_desc, 32);
        const a1 = try limit.add(a0, t.u64At(a_desc, 40));
        for (left + 1..info.count) |right| {
            const b_desc = t.descriptor(buf, right);
            const b0 = t.u64At(b_desc, 32);
            const b1 = try limit.add(b0, t.u64At(b_desc, 40));
            if (a0 == a1 or b0 == b1) continue;
            if (a0 < b1 and b0 < a1) return error.TYPE;
        }
    }
    var cursor: u64 = 0;
    for (0..info.count) |index| {
        const desc = t.descriptor(buf, index);
        const off = t.u64At(desc, 32);
        const len = t.u64At(desc, 40);
        if (off != try limit.align64(cursor)) return error.TYPE;
        cursor = try limit.add(off, len);
    }
    if (cursor != info.payload_bytes) return error.TYPE;
    for (0..info.count) |index| {
        const desc = t.descriptor(buf, index);
        const dtype = t.u16At(desc, 0);
        const off: usize = @intCast(t.u64At(desc, 32));
        const len: usize = @intCast(t.u64At(desc, 40));
        const region = bytes[off .. off + len];
        if (dtype >= 16 and dtype <= 18) {
            const shape = t.shapeOf(desc);
            const n = try t.elementCount(desc[2], &shape);
            if (n % 2 == 1 and region.len != 0 and region[region.len - 1] >> 4 != 0) return error.TYPE;
        } else if (dtype == 7) {
            for (region) |byte| if (byte > 1) return error.TYPE;
        }
    }
}

fn gaps(buf: []const u8, info: t.Header) Error!void {
    const bytes = payload(buf, info);
    var cursor: u64 = 0;
    for (0..info.count) |index| {
        const desc = t.descriptor(buf, index);
        const off = t.u64At(desc, 32);
        const len = t.u64At(desc, 40);
        if (off > cursor and !std.mem.allEqual(u8, bytes[@intCast(cursor)..@intCast(off)], 0)) return error.TYPE;
        cursor = try limit.add(off, len);
    }
    if (cursor < bytes.len and !std.mem.allEqual(u8, bytes[@intCast(cursor)..], 0)) return error.TYPE;
}

fn quants(buf: []const u8, info: t.Header) Error!void {
    for (0..info.count) |index| {
        const desc = t.descriptor(buf, index);
        const scheme = t.u16At(desc, 16);
        const axis = t.u16At(desc, 18);
        const group = t.u32At(desc, 20);
        const scale = t.u32At(desc, 24);
        const outer = t.u32At(desc, 28);
        if (scheme == 0) {
            if (group != 0 or axis != 0xFFFF or scale != 0xFFFFFFFF or outer != 0xFFFFFFFF) return error.TYPE;
            continue;
        }
        if (scheme != 1 and scheme != 2) return error.TYPE;
        const rank = desc[2];
        if (rank == 0 or axis >= rank or group == 0) return error.TYPE;
        if (scale == index or scale >= info.count) return error.TYPE;
        const scale_desc = t.descriptor(buf, scale);
        if (t.u16At(scale_desc, 16) != 0) return error.TYPE;
        const shape = t.shapeOf(desc);
        const groups = try t.ceilDiv(shape[axis], group);
        var other_dims: u64 = 1;
        for (0..rank) |dim| if (dim != axis) {
            other_dims = try limit.mul(other_dims, shape[dim]);
        };
        const scale_shape = t.shapeOf(scale_desc);
        const have = try t.elementCount(scale_desc[2], &scale_shape);
        if (have != try limit.mul(groups, other_dims)) return error.TYPE;
        if (scheme == 1) {
            if (outer != 0xFFFFFFFF) return error.TYPE;
            continue;
        }
        if (outer == index or outer == scale or outer >= info.count) return error.TYPE;
        const outer_desc = t.descriptor(buf, outer);
        if (t.u16At(outer_desc, 16) != 0 or t.u16At(outer_desc, 0) != 2) return error.TYPE;
        const outer_shape = t.shapeOf(outer_desc);
        if (try t.elementCount(outer_desc[2], &outer_shape) != 1) return error.TYPE;
    }
}

fn fill(buf: []const u8, info: t.Header, out: []Tensor) void {
    const heap = heapSlice(buf, info);
    const bytes = payload(buf, info);
    for (out, 0..) |*tensor, index| {
        const desc = t.descriptor(buf, index);
        const name_off = t.u16At(desc, 4);
        const name_len = t.u16At(desc, 6);
        const layout_off = t.u16At(desc, 8);
        const layout_len = t.u16At(desc, 10);
        const off: usize = @intCast(t.u64At(desc, 32));
        const len: usize = @intCast(t.u64At(desc, 40));
        tensor.* = .{
            .name = if (name_len == 0) null else heap[name_off..][0..name_len],
            .dtype = t.u16At(desc, 0),
            .rank = desc[2],
            .shape = t.shapeOf(desc),
            .data = bytes[off .. off + len],
            .layout = if (layout_len == 0) null else heap[layout_off..][0..layout_len],
            .block_size = t.u32At(desc, 12),
            .quant_scheme = t.u16At(desc, 16),
            .quant_axis = t.u16At(desc, 18),
            .group_size = t.u32At(desc, 20),
            .scale_index = t.u32At(desc, 24),
            .outer_index = t.u32At(desc, 28),
        };
    }
}
