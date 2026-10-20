//! Runtime schema. Nodes are owned by the caller, usually an arena.

const std = @import("std");
const Error = @import("error.zig").Error;
const limit = @import("limit.zig");

pub const Kind = enum {
    boolean,
    i8,
    i16,
    i32,
    i64,
    int,
    u8,
    u16,
    u32,
    u64,
    uint,
    f32,
    f64,
    str,
    bytes,
    tensors,
    list,
    opt,
    dict,
    structure,
};

pub const Field = struct {
    name: []const u8,
    schema: *const Schema,
};

pub const Schema = struct {
    kind: Kind,
    child: ?*const Schema = null,
    fields: []const Field = &.{},
    label: []const u8 = "",
};

pub fn minSize(schema: *const Schema) Error!u64 {
    return switch (schema.kind) {
        .boolean, .i8, .u8 => 1,
        .i16, .u16 => 2,
        .i32, .u32, .f32 => 4,
        .i64, .u64, .int, .uint, .f64 => 8,
        .str, .bytes, .list, .dict => 4,
        .tensors => limit.tensor_header,
        .opt => 1,
        .structure => blk: {
            var sum: u64 = 0;
            for (schema.fields) |field| {
                sum = try limit.add(sum, try minSize(field.schema));
            }
            break :blk sum;
        },
    };
}

pub fn create(arena: std.mem.Allocator, schema: Schema) Error!*Schema {
    const node = try arena.create(Schema);
    node.* = schema;
    return node;
}

pub fn leaf(arena: std.mem.Allocator, kind: Kind) Error!*Schema {
    return create(arena, .{ .kind = kind });
}

pub fn parseTypeText(arena: std.mem.Allocator, text: []const u8) Error!*Schema {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "struct{") and std.mem.endsWith(u8, trimmed, "}")) {
        const body = trimmed["struct{".len .. trimmed.len - 1];
        var fields: std.ArrayList(Field) = .empty;
        errdefer fields.deinit(arena);
        var rest = body;
        while (rest.len > 0) {
            const part = splitTop(rest);
            rest = part.rest;
            if (part.item.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, part.item, ':') orelse return error.SCHEMA;
            const name = std.mem.trim(u8, part.item[0..colon], " ");
            const typ = std.mem.trim(u8, part.item[colon + 1 ..], " ");
            if (name.len == 0 or typ.len == 0) return error.SCHEMA;
            const child = try parseTypeText(arena, typ);
            try fields.append(arena, .{ .name = name, .schema = child });
        }
        return create(arena, .{
            .kind = .structure,
            .fields = try fields.toOwnedSlice(arena),
        });
    }
    if (wrapped(trimmed, "list<")) |inner| {
        const child = try parseTypeText(arena, inner);
        return create(arena, .{ .kind = .list, .child = child });
    }
    if (wrapped(trimmed, "opt<")) |inner| {
        const child = try parseTypeText(arena, inner);
        return create(arena, .{ .kind = .opt, .child = child });
    }
    if (wrapped(trimmed, "dict<str,")) |inner| {
        const child = try parseTypeText(arena, inner);
        return create(arena, .{ .kind = .dict, .child = child });
    }
    const kind = kindFromName(trimmed) orelse return error.SCHEMA;
    return leaf(arena, kind);
}

fn wrapped(text: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, prefix) or !std.mem.endsWith(u8, text, ">")) return null;
    return text[prefix.len .. text.len - 1];
}

const Split = struct { item: []const u8, rest: []const u8 };

fn splitTop(text: []const u8) Split {
    var depth: i32 = 0;
    for (text, 0..) |byte, i| {
        switch (byte) {
            '<', '{' => depth += 1,
            '>', '}' => depth -= 1,
            ',' => if (depth == 0) return .{ .item = text[0..i], .rest = text[i + 1 ..] },
            else => {},
        }
    }
    return .{ .item = text, .rest = &.{} };
}

pub fn kindFromName(name: []const u8) ?Kind {
    const pairs = .{
        .{ "bool", Kind.boolean },    .{ "i8", Kind.i8 },     .{ "i16", Kind.i16 },
        .{ "i32", Kind.i32 },         .{ "i64", Kind.i64 },   .{ "int", Kind.int },
        .{ "u8", Kind.u8 },           .{ "u16", Kind.u16 },   .{ "u32", Kind.u32 },
        .{ "u64", Kind.u64 },         .{ "uint", Kind.uint }, .{ "f32", Kind.f32 },
        .{ "f64", Kind.f64 },         .{ "str", Kind.str },   .{ "bytes", Kind.bytes },
        .{ "tensors", Kind.tensors },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return null;
}

pub fn schemaFromCase(arena: std.mem.Allocator, value: std.json.Value) Error!*Schema {
    switch (value) {
        .string => |text| {
            if (std.mem.eql(u8, text, "tensor-v2")) return leaf(arena, .tensors);
            if (std.mem.eql(u8, text, "frame")) {
                return parseTypeText(arena, "struct{id:i64,batch:tensors}");
            }
            return error.SCHEMA;
        },
        .object => |object| {
            const typ = object.get("type") orelse return error.SCHEMA;
            if (typ != .string) return error.SCHEMA;
            if (std.mem.eql(u8, typ.string, "list")) {
                const element = object.get("element") orelse return error.SCHEMA;
                if (element != .string) return error.SCHEMA;
                const child = try parseTypeText(arena, element.string);
                return create(arena, .{ .kind = .list, .child = child });
            }
            if (std.mem.eql(u8, typ.string, "struct")) {
                const fields_value = object.get("fields") orelse return error.SCHEMA;
                if (fields_value != .array) return error.SCHEMA;
                var fields: std.ArrayList(Field) = .empty;
                errdefer fields.deinit(arena);
                for (fields_value.array.items) |item| {
                    if (item != .string) return error.SCHEMA;
                    const colon = std.mem.indexOfScalar(u8, item.string, ':') orelse return error.SCHEMA;
                    const name = item.string[0..colon];
                    const typ_text = item.string[colon + 1 ..];
                    const child = try parseTypeText(arena, typ_text);
                    try fields.append(arena, .{ .name = name, .schema = child });
                }
                return create(arena, .{
                    .kind = .structure,
                    .fields = try fields.toOwnedSlice(arena),
                });
            }
            return error.SCHEMA;
        },
        else => return error.SCHEMA,
    }
}
