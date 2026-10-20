//! Dynamic values. String, byte, and tensor payloads borrow the input buffer.

const std = @import("std");

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

pub const Value = union(enum) {
    boolean: bool,
    int: i64,
    uint: u64,
    f32: f32,
    f64: f64,
    str: []const u8,
    bytes: []const u8,
    list: []const Value,
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
            else => {},
        }
        self.* = .none;
    }
};
