//! Dynamic values. String, byte, and tensor payloads borrow the input buffer.
//! Primitive numeric lists borrow the input or a `ListReuse` buffer. `deinit`
//! frees a numeric list only when `owned` is set.

const std = @import("std");
const Error = @import("error.zig").Error;

pub const Tensor = struct {
    name: ?[]const u8 = null,
    dtype: u16,
    rank: u8 = 0,
    shape: [8]u64 = [_]u64{0} ** 8,
    data: []const u8 = &.{},
    layout: ?[]const u8 = null,
    block_size: u32 = 0,
    quant_scheme: u16 = 0,
    quant_axis: u16 = 0xFFFF,
    group_size: u32 = 0,
    scale_index: u32 = 0xFFFFFFFF,
    outer_index: u32 = 0xFFFFFFFF,
};

pub const TensorDirectory = struct {
    version: u8 = 2,
    flags: u8 = 0,
    tensors: []const Tensor,
    block_length: u64 = 0,
};

pub const FieldValue = struct {
    name: []const u8,
    value: Value,
};

pub const DictEntry = struct {
    key: []const u8,
    value: Value,
};

pub fn PodList(comptime T: type) type {
    return struct {
        items: []const T,
        owned: bool = false,
    };
}

/// Buffers for `list<f32>`, `list<f64>`, `list<i32>`, `list<i64>`, `list<u32>`,
/// and `list<u64>`. `decode` resets the cursors and reuses the allocation, so a
/// 4 MiB list is not allocated again on the next call. Slices from the previous
/// decode are then invalid. `deinit` on a value does not free this memory.
pub const ListReuse = struct {
    f32s: []f32 = &.{},
    f64s: []f64 = &.{},
    i32s: []i32 = &.{},
    i64s: []i64 = &.{},
    u32s: []u32 = &.{},
    u64s: []u64 = &.{},
    f32_used: usize = 0,
    f64_used: usize = 0,
    i32_used: usize = 0,
    i64_used: usize = 0,
    u32_used: usize = 0,
    u64_used: usize = 0,
    /// Chunks parked during this decode so an earlier list is not moved.
    f32_extra: [][]f32 = &.{},
    f64_extra: [][]f64 = &.{},
    i32_extra: [][]i32 = &.{},
    i64_extra: [][]i64 = &.{},
    u32_extra: [][]u32 = &.{},
    u64_extra: [][]u64 = &.{},
    f32_extra_len: usize = 0,
    f64_extra_len: usize = 0,
    i32_extra_len: usize = 0,
    i64_extra_len: usize = 0,
    u32_extra_len: usize = 0,
    u64_extra_len: usize = 0,

    pub fn reset(self: *ListReuse, gpa: std.mem.Allocator) void {
        reclaim(f32, gpa, &self.f32s, &self.f32_extra, &self.f32_extra_len);
        reclaim(f64, gpa, &self.f64s, &self.f64_extra, &self.f64_extra_len);
        reclaim(i32, gpa, &self.i32s, &self.i32_extra, &self.i32_extra_len);
        reclaim(i64, gpa, &self.i64s, &self.i64_extra, &self.i64_extra_len);
        reclaim(u32, gpa, &self.u32s, &self.u32_extra, &self.u32_extra_len);
        reclaim(u64, gpa, &self.u64s, &self.u64_extra, &self.u64_extra_len);
        self.f32_used = 0;
        self.f64_used = 0;
        self.i32_used = 0;
        self.i64_used = 0;
        self.u32_used = 0;
        self.u64_used = 0;
    }

    pub fn deinit(self: *ListReuse, gpa: std.mem.Allocator) void {
        self.reset(gpa);
        gpa.free(self.f32s);
        gpa.free(self.f64s);
        gpa.free(self.i32s);
        gpa.free(self.i64s);
        gpa.free(self.u32s);
        gpa.free(self.u64s);
        self.* = .{};
    }

    pub fn take(self: *ListReuse, comptime T: type, gpa: std.mem.Allocator, n: usize) Error![]T {
        if (comptime T == f32) return takeSlot(f32, gpa, &self.f32s, &self.f32_used, &self.f32_extra, &self.f32_extra_len, n);
        if (comptime T == f64) return takeSlot(f64, gpa, &self.f64s, &self.f64_used, &self.f64_extra, &self.f64_extra_len, n);
        if (comptime T == i32) return takeSlot(i32, gpa, &self.i32s, &self.i32_used, &self.i32_extra, &self.i32_extra_len, n);
        if (comptime T == i64) return takeSlot(i64, gpa, &self.i64s, &self.i64_used, &self.i64_extra, &self.i64_extra_len, n);
        if (comptime T == u32) return takeSlot(u32, gpa, &self.u32s, &self.u32_used, &self.u32_extra, &self.u32_extra_len, n);
        if (comptime T == u64) return takeSlot(u64, gpa, &self.u64s, &self.u64_used, &self.u64_extra, &self.u64_extra_len, n);
        @compileError("ListReuse does not store this element type");
    }
};

fn takeSlot(
    comptime T: type,
    gpa: std.mem.Allocator,
    slot: *[]T,
    used: *usize,
    extra: *[][]T,
    extra_len: *usize,
    n: usize,
) Error![]T {
    if (n == 0) return &.{};
    const room = slot.len - used.*;
    if (room >= n) {
        const start = used.*;
        used.* += n;
        return slot.*[start..][0..n];
    }
    if (used.* == 0) {
        // Nothing in this decode points at `slot` yet, so growing it is safe.
        var cap: usize = if (slot.len == 0) n else slot.len;
        while (cap < n) {
            const grown = std.math.add(usize, cap, cap / 2 + 1) catch n;
            cap = if (grown < n) n else grown;
        }
        slot.* = try gpa.realloc(slot.*, cap);
        used.* = n;
        return slot.*[0..n];
    }
    // Earlier lists in this value still point at the current block.
    if (extra_len.* == extra.len) {
        const cap: usize = if (extra.len == 0) 4 else extra.len * 2;
        extra.* = try gpa.realloc(extra.*, cap);
    }
    extra.*[extra_len.*] = slot.*;
    extra_len.* += 1;
    slot.* = &.{};
    used.* = 0;
    const fresh = try gpa.alloc(T, n);
    slot.* = fresh;
    used.* = n;
    return fresh;
}

fn reclaim(
    comptime T: type,
    gpa: std.mem.Allocator,
    slot: *[]T,
    extra: *[][]T,
    extra_len: *usize,
) void {
    var best = slot.*;
    var best_i: ?usize = null;
    for (extra.*[0..extra_len.*], 0..) |chunk, i| {
        if (chunk.len > best.len) {
            best = chunk;
            best_i = i;
        }
    }
    if (best_i) |keep| {
        gpa.free(slot.*);
        for (extra.*[0..extra_len.*], 0..) |chunk, i| {
            if (i != keep) gpa.free(chunk);
        }
        slot.* = best;
    } else {
        for (extra.*[0..extra_len.*]) |chunk| gpa.free(chunk);
    }
    extra_len.* = 0;
    gpa.free(extra.*);
    extra.* = &.{};
}

pub const Value = union(enum) {
    boolean: bool,
    int: i64,
    uint: u64,
    f32: f32,
    f64: f64,
    str: []const u8,
    bytes: []const u8,
    list: []const Value,
    /// Little-endian `list<f32>`. 4 bytes per element. Not a `u32` widened to 8.
    f32s: PodList(f32),
    f64s: PodList(f64),
    i32s: PodList(i32),
    /// `list<i64>` and `list<int>`.
    i64s: PodList(i64),
    u32s: PodList(u32),
    /// `list<u64>` and `list<uint>`.
    u64s: PodList(u64),
    dict: []const DictEntry,
    none,
    structure: []const FieldValue,
    tensors: TensorDirectory,

    pub fn deinit(self: *Value, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .list => |items| {
                for (items) |item| {
                    var child = item;
                    child.deinit(gpa);
                }
                gpa.free(items);
            },
            .dict => |items| {
                for (items) |item| {
                    var child = item.value;
                    child.deinit(gpa);
                }
                gpa.free(items);
            },
            .structure => |fields| {
                for (fields) |field| {
                    var child = field.value;
                    child.deinit(gpa);
                }
                gpa.free(fields);
            },
            .tensors => |dir| gpa.free(dir.tensors),
            .f32s => |pod| freePod(f32, gpa, pod),
            .f64s => |pod| freePod(f64, gpa, pod),
            .i32s => |pod| freePod(i32, gpa, pod),
            .i64s => |pod| freePod(i64, gpa, pod),
            .u32s => |pod| freePod(u32, gpa, pod),
            .u64s => |pod| freePod(u64, gpa, pod),
            else => {},
        }
        self.* = .none;
    }
};

fn freePod(comptime T: type, gpa: std.mem.Allocator, pod: PodList(T)) void {
    if (pod.owned) gpa.free(@constCast(pod.items));
}
