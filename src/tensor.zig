//! Tensor directory helpers shared by encode and decode.

const std = @import("std");
const Error = @import("error.zig").Error;
const limit = @import("limit.zig");

pub const flag_name: u8 = 0x01;
pub const flag_le: u8 = 0x02;
pub const header_len: usize = 64;
pub const desc_len: usize = 128;
pub const opaque_min: u16 = 4096;
pub const opaque_max: u16 = 32767;

pub const Header = struct {
    flags: u8,
    count: u32,
    name_bytes: u32,
    payload_bytes: u64,
    directory_bytes: u64,
    directory_end: u64,
    payload_base: u64,
    block_end: u64,
};

pub fn u16At(buf: []const u8, i: usize) u16 {
    return std.mem.readInt(u16, buf[i..][0..2], .little);
}

pub fn u32At(buf: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, buf[i..][0..4], .little);
}

pub fn u64At(buf: []const u8, i: usize) u64 {
    return std.mem.readInt(u64, buf[i..][0..8], .little);
}

pub fn putU16(buf: []u8, i: usize, v: u16) void {
    std.mem.writeInt(u16, buf[i..][0..2], v, .little);
}

pub fn putU32(buf: []u8, i: usize, v: u32) void {
    std.mem.writeInt(u32, buf[i..][0..4], v, .little);
}

pub fn putU64(buf: []u8, i: usize, v: u64) void {
    std.mem.writeInt(u64, buf[i..][0..8], v, .little);
}

pub fn descriptor(buf: []const u8, index: usize) []const u8 {
    const start = header_len + index * desc_len;
    return buf[start .. start + desc_len];
}

pub fn shapeOf(desc: []const u8) [8]u64 {
    var shape: [8]u64 = undefined;
    for (0..8) |dim| shape[dim] = u64At(desc, 48 + dim * 8);
    return shape;
}

pub fn readHeader(buf: []const u8, cap: u64) Error!Header {
    if (buf.len < 4) return error.EOF;
    if (!std.mem.eql(u8, buf[0..4], "KLNT")) return error.FRAME;
    if (buf.len < header_len) return error.EOF;
    const version = buf[4];
    const flags = buf[5];
    const reserved16 = u16At(buf, 6);
    const count = u32At(buf, 8);
    const name_bytes = u32At(buf, 12);
    const payload_bytes = u64At(buf, 16);
    const directory_bytes = u64At(buf, 24);
    if (version != 2 or (flags & ~@as(u8, 0x03)) != 0 or (flags & flag_le) == 0) return error.FRAME;
    if (reserved16 != 0 or !std.mem.allEqual(u8, buf[32..header_len], 0)) return error.FRAME;
    if (@as(u64, count) > cap or @as(u64, name_bytes) > cap) return error.LIMIT;
    const expect_dir = try limit.add(try limit.mul(count, desc_len), name_bytes);
    if (directory_bytes != expect_dir) return error.TYPE;
    const directory_end = try limit.add(header_len, directory_bytes);
    if (directory_end > @as(u64, buf.len)) return error.EOF;
    const payload_base = try limit.align64(directory_end);
    const block_end = try limit.add(payload_base, payload_bytes);
    if (block_end > @as(u64, buf.len)) return error.EOF;
    const pad = buf[@intCast(directory_end)..@intCast(payload_base)];
    if (!std.mem.allEqual(u8, pad, 0)) return error.TYPE;
    return .{
        .flags = flags,
        .count = count,
        .name_bytes = name_bytes,
        .payload_bytes = payload_bytes,
        .directory_bytes = directory_bytes,
        .directory_end = directory_end,
        .payload_base = payload_base,
        .block_end = block_end,
    };
}

pub fn elementCount(rank: u8, shape: *const [8]u64) Error!u64 {
    if (rank == 0) return 1;
    var count: u64 = 1;
    for (shape[0..@as(usize, rank)]) |dim| count = try limit.mul(count, dim);
    return count;
}

pub fn expectedBytes(dtype: u16, count: u64) Error!u64 {
    const width: u64 = switch (dtype) {
        1, 14, 15 => 8,
        2, 12, 13 => 4,
        3, 4, 10, 11 => 2,
        5, 6, 7, 8, 9, 19 => 1,
        16, 17, 18 => return ceilDiv(count, 2),
        else => return error.TYPE,
    };
    return limit.mul(count, width);
}

pub fn ceilDiv(n: u64, d: u64) Error!u64 {
    const q = n / d;
    if (n % d == 0) return q;
    return limit.add(q, 1);
}

pub fn checkTensor(
    dtype: u16,
    rank: u8,
    shape: *const [8]u64,
    layout_len: u16,
    block_size: u32,
    byte_length: u64,
) Error!void {
    if (rank > 8) return error.TYPE;
    for (shape[@as(usize, rank)..8]) |dim| if (dim != 0) return error.TYPE;
    if (dtype == 0 or (dtype >= 20 and dtype < opaque_min) or dtype > opaque_max) return error.TYPE;
    const count = try elementCount(rank, shape);
    if (dtype >= opaque_min) {
        if (layout_len == 0 or block_size == 0) return error.TYPE;
        if (byte_length % block_size != 0) return error.TYPE;
        return;
    }
    if (layout_len != 0 or block_size != 0) return error.TYPE;
    if (byte_length != try expectedBytes(dtype, count)) return error.TYPE;
}

pub fn dtypeName(code: u16) ?[]const u8 {
    return switch (code) {
        1 => "f64",
        2 => "f32",
        3 => "f16",
        4 => "bf16",
        5 => "f8e4m3",
        6 => "f8e5m2",
        7 => "bool",
        8 => "i8",
        9 => "u8",
        10 => "i16",
        11 => "u16",
        12 => "i32",
        13 => "u32",
        14 => "i64",
        15 => "u64",
        16 => "i4",
        17 => "u4",
        18 => "e2m1",
        19 => "e8m0",
        else => null,
    };
}

pub fn dtypeCode(name: []const u8) ?u16 {
    const names = [_][]const u8{
        "f64", "f32", "f16", "bf16", "f8e4m3", "f8e5m2", "bool", "i8",   "u8",   "i16",
        "u16", "i32", "u32", "i64",  "u64",    "i4",     "u4",   "e2m1", "e8m0",
    };
    for (names, 0..) |item, i| if (std.mem.eql(u8, item, name)) return @intCast(i + 1);
    return null;
}
