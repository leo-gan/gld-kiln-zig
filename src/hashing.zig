//! FNV-1a 64 schema hash. Each token is mixed, then a 0x00 step.

const std = @import("std");
const Schema = @import("schema.zig").Schema;

pub const fnv_offset: u64 = 14695981039346656037;
pub const fnv_prime: u64 = 1099511628211;

fn mix(hash_value: u64, data: []const u8) u64 {
    var h = hash_value;
    for (data) |byte| {
        h ^= byte;
        h *%= fnv_prime;
    }
    h *%= fnv_prime;
    return h;
}

fn hashSchema(hash_value: u64, schema: *const Schema) error{TYPE}!u64 {
    var h = hash_value;
    switch (schema.kind) {
        .boolean => return mix(h, "bool"),
        .i8 => return mix(h, "i8"),
        .i16 => return mix(h, "i16"),
        .i32 => return mix(h, "i32"),
        .i64 => return mix(h, "i64"),
        .int => return mix(h, "int"),
        .u8 => return mix(h, "u8"),
        .u16 => return mix(h, "u16"),
        .u32 => return mix(h, "u32"),
        .u64 => return mix(h, "u64"),
        .uint => return mix(h, "uint"),
        .f32 => return mix(h, "f32"),
        .f64 => return mix(h, "f64"),
        .str => return mix(h, "str"),
        .bytes => return mix(h, "bytes"),
        .tensors => return mix(h, "tensors"),
        .list => {
            h = mix(h, "list<");
            h = try hashSchema(h, schema.child.?);
            return mix(h, ">");
        },
        .opt => {
            h = mix(h, "opt<");
            h = try hashSchema(h, schema.child.?);
            return mix(h, ">");
        },
        .dict => {
            h = mix(h, "dict<str,");
            h = try hashSchema(h, schema.child.?);
            return mix(h, ">");
        },
        .structure => {
            h = mix(h, "struct{");
            for (schema.fields) |field| {
                h = mix(h, field.name);
                h = mix(h, ":");
                h = try hashSchema(h, field.schema);
                h = mix(h, ",");
            }
            return mix(h, "}");
        },
    }
}

pub fn typeHash(schema: *const Schema) error{TYPE}!u64 {
    return hashSchema(fnv_offset, schema);
}

test "tensors frame hash" {
    const schema_mod = @import("schema.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try schema_mod.parseTypeText(arena.allocator(), "struct{id:i64,batch:tensors}");
    try std.testing.expectEqual(@as(u64, 0xe58aadc7552f0d82), try typeHash(schema));
}
