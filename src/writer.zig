//! Reusable encode buffer. `reset` keeps the allocation.

const std = @import("std");
const builtin = @import("builtin");
const Error = @import("error.zig").Error;
const limit = @import("limit.zig");
const Reader = @import("reader.zig").Reader;

pub const Writer = struct {
    list: std.ArrayList(u8) = .empty,
    cap: u64 = limit.default_cap,
    depth: u32 = 0,

    pub fn deinit(self: *Writer, gpa: std.mem.Allocator) void {
        self.list.deinit(gpa);
    }

    pub fn reset(self: *Writer) void {
        self.list.clearRetainingCapacity();
        self.depth = 0;
    }

    pub fn slice(self: *const Writer) []const u8 {
        return self.list.items;
    }

    pub fn toOwned(self: *Writer, gpa: std.mem.Allocator) Error![]u8 {
        return self.list.toOwnedSlice(gpa);
    }

    pub fn raw(self: *Writer, gpa: std.mem.Allocator, data: []const u8) Error!void {
        try self.list.appendSlice(gpa, data);
    }

    pub fn int(self: *Writer, gpa: std.mem.Allocator, comptime T: type, value: T) Error!void {
        const dest = try self.list.addManyAsSlice(gpa, @sizeOf(T));
        std.mem.writeInt(T, dest[0..@sizeOf(T)], value, .little);
    }

    pub fn boolean(self: *Writer, gpa: std.mem.Allocator, value: bool) Error!void {
        try self.int(gpa, u8, if (value) 1 else 0);
    }

    pub fn float32(self: *Writer, gpa: std.mem.Allocator, value: f32) Error!void {
        try self.int(gpa, u32, @bitCast(value));
    }

    pub fn float64(self: *Writer, gpa: std.mem.Allocator, value: f64) Error!void {
        try self.int(gpa, u64, @bitCast(value));
    }

    pub fn bytes(self: *Writer, gpa: std.mem.Allocator, value: []const u8) Error!void {
        if (value.len > self.cap) return error.LIMIT;
        const len = std.math.cast(u32, value.len) orelse return error.LIMIT;
        const dest = try self.list.addManyAsSlice(gpa, 4 + value.len);
        std.mem.writeInt(u32, dest[0..4], len, .little);
        @memcpy(dest[4..], value);
    }

    pub fn str(self: *Writer, gpa: std.mem.Allocator, value: []const u8) Error!void {
        try self.bytes(gpa, value);
    }

    pub fn narrow(self: *Writer, gpa: std.mem.Allocator, comptime T: type, value: i64) Error!void {
        if (value < std.math.minInt(T) or value > std.math.maxInt(T)) return error.TYPE;
        try self.int(gpa, T, @intCast(value));
    }

    pub fn narrowUnsigned(self: *Writer, gpa: std.mem.Allocator, comptime T: type, value: u64) Error!void {
        if (value > std.math.maxInt(T)) return error.TYPE;
        try self.int(gpa, T, @intCast(value));
    }

    pub fn pod(self: *Writer, gpa: std.mem.Allocator, comptime T: type, values: []const T) Error!void {
        if (comptime builtin.cpu.arch.endian() == .little) {
            try self.raw(gpa, std.mem.sliceAsBytes(values));
            return;
        }
        for (values) |item| try self.int(gpa, T, item);
    }

    pub fn float32s(self: *Writer, gpa: std.mem.Allocator, values: []const f32) Error!void {
        if (comptime builtin.cpu.arch.endian() == .little) {
            try self.raw(gpa, std.mem.sliceAsBytes(values));
            return;
        }
        for (values) |item| try self.float32(gpa, item);
    }

    pub fn float64s(self: *Writer, gpa: std.mem.Allocator, values: []const f64) Error!void {
        if (comptime builtin.cpu.arch.endian() == .little) {
            try self.raw(gpa, std.mem.sliceAsBytes(values));
            return;
        }
        for (values) |item| try self.float64(gpa, item);
    }

    pub fn descend(self: *Writer) Error!void {
        if (self.depth > limit.max_depth) return error.LIMIT;
        self.depth += 1;
    }

    pub fn ascend(self: *Writer) void {
        self.depth -= 1;
    }
};

test "scalar bits round-trip" {
    const gpa = std.testing.allocator;
    var writer = Writer{};
    defer writer.deinit(gpa);
    try writer.int(gpa, i32, -4);
    try writer.float64(gpa, -0.0);
    try writer.float64(gpa, @bitCast(@as(u64, 0x7FF8000000000001)));
    try writer.boolean(gpa, true);
    var reader = Reader.init(writer.slice(), .{});
    try std.testing.expectEqual(@as(i32, -4), try reader.int(i32));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), @as(u64, @bitCast(try reader.float64())));
    try std.testing.expectEqual(@as(u64, 0x7FF8000000000001), @as(u64, @bitCast(try reader.float64())));
    try std.testing.expect(try reader.boolean());
    try reader.finish();
}
