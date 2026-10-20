//! Compare a decoded value with the JSON recorded by a wire case.

const std = @import("std");
const Value = @import("value.zig").Value;
const FieldValue = @import("value.zig").FieldValue;
const Tensor = @import("value.zig").Tensor;
const TensorDirectory = @import("value.zig").TensorDirectory;
const dtypeCode = @import("tensor.zig").dtypeCode;

pub fn same(got: Value, want: std.json.Value) bool {
    return switch (want) {
        .null => got == .none,
        .bool => |bit| got == .boolean and got.boolean == bit,
        .integer => |n| sameInt(got, n),
        .float => |n| sameFloat(got, n),
        .string => |text| (got == .str and std.mem.eql(u8, got.str, text)) or (got == .bytes and std.mem.eql(u8, got.bytes, text)),
        .array => |items| sameList(got, items.items),
        .object => |object| sameObject(got, object),
        .number_string => false,
    };
}

fn sameInt(got: Value, n: i64) bool {
    return switch (got) {
        .int => |v| v == n,
        .uint => |v| std.math.cast(i64, v) != null and @as(i64, @intCast(v)) == n,
        .f32 => |v| @as(f64, v) == @as(f64, @floatFromInt(n)),
        .f64 => |v| v == @as(f64, @floatFromInt(n)),
        else => false,
    };
}

fn sameFloat(got: Value, n: f64) bool {
    const bits = switch (got) {
        .f32 => |v| @as(f64, v),
        .f64 => |v| v,
        .int => |v| @as(f64, @floatFromInt(v)),
        else => return false,
    };
    if (std.math.isNan(bits) and std.math.isNan(n)) return true;
    return bits == n;
}

fn sameList(got: Value, items: []const std.json.Value) bool {
    if (got != .list or got.list.len != items.len) return false;
    for (got.list, items) |item, want| if (!same(item, want)) return false;
    return true;
}

fn sameObject(got: Value, object: std.json.ObjectMap) bool {
    if (got == .tensors) return sameDir(got.tensors, object);
    if (got != .structure) return false;
    var it = object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "hash")) continue;
        const field = lookup(got.structure, entry.key_ptr.*) orelse return false;
        if (!same(field, entry.value_ptr.*)) return false;
    }
    return true;
}

fn lookup(fields: []const FieldValue, name: []const u8) ?Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn sameDir(dir: TensorDirectory, object: std.json.ObjectMap) bool {
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const want = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "version")) {
            if (want != .integer or want.integer != dir.version) return false;
        } else if (std.mem.eql(u8, key, "flags")) {
            if (!sameFlags(dir.flags, want)) return false;
        } else if (std.mem.eql(u8, key, "block_length")) {
            if (!sameU64(want, dir.block_length)) return false;
        } else if (std.mem.eql(u8, key, "tensors")) {
            if (want != .array or want.array.items.len != dir.tensors.len) return false;
            for (dir.tensors, want.array.items) |tensor, item| {
                if (item != .object or !sameTensor(tensor, item.object)) return false;
            }
        } else return false;
    }
    return true;
}

fn sameFlags(flags: u8, want: std.json.Value) bool {
    if (want != .array) return false;
    const items = want.array.items;
    if ((flags & 0x01) != 0) {
        return items.len == 2 and items[0] == .string and items[1] == .string and
            std.mem.eql(u8, items[0].string, "names") and std.mem.eql(u8, items[1].string, "le");
    }
    return items.len == 1 and items[0] == .string and std.mem.eql(u8, items[0].string, "le");
}

fn sameTensor(tensor: Tensor, object: std.json.ObjectMap) bool {
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const want = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "name")) {
            if (want == .null) {
                if (tensor.name != null) return false;
            } else if (want != .string or tensor.name == null or !std.mem.eql(u8, tensor.name.?, want.string)) return false;
        } else if (std.mem.eql(u8, key, "dtype")) {
            if (!sameDtype(tensor.dtype, want)) return false;
        } else if (std.mem.eql(u8, key, "shape")) {
            if (want != .array or want.array.items.len != tensor.rank) return false;
            for (want.array.items, 0..) |dim, i| {
                if (!sameU64(dim, tensor.shape[i])) return false;
            }
        } else if (std.mem.eql(u8, key, "data_hex")) {
            if (want != .string or !hexEql(tensor.data, want.string)) return false;
        } else if (std.mem.eql(u8, key, "quant_scheme")) {
            if (!sameU64(want, tensor.quant_scheme)) return false;
        } else if (std.mem.eql(u8, key, "quant_axis")) {
            if (!sameU64(want, tensor.quant_axis)) return false;
        } else if (std.mem.eql(u8, key, "group_size")) {
            if (!sameU64(want, tensor.group_size)) return false;
        } else return false;
    }
    return true;
}

fn sameDtype(code: u16, want: std.json.Value) bool {
    if (want == .string) return dtypeCode(want.string) == code;
    return sameU64(want, code);
}

fn sameU64(want: std.json.Value, n: u64) bool {
    return switch (want) {
        .integer => |v| v >= 0 and @as(u64, @intCast(v)) == n,
        .number_string => |text| if (std.fmt.parseInt(u64, text, 10)) |v| v == n else |_| false,
        else => false,
    };
}

fn hexEql(bytes: []const u8, hex: []const u8) bool {
    if (hex.len != bytes.len * 2) return false;
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        if (hex[i * 2] != digits[byte >> 4] or hex[i * 2 + 1] != digits[byte & 0xf]) return false;
    }
    return true;
}
