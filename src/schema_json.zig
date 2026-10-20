//! JSON Schema subset from the Kiln dynamic-values section.

const std = @import("std");
const Error = @import("error.zig").Error;
const Schema = @import("schema.zig").Schema;
const Kind = @import("schema.zig").Kind;
const Field = @import("schema.zig").Field;
const create = @import("schema.zig").create;
const leaf = @import("schema.zig").leaf;

pub const JsonSchema = struct {
    title: []const u8,
    root: *const Schema,
};

const Entry = struct { name: []const u8, schema: *Schema };

const Ctx = struct {
    arena: std.mem.Allocator,
    defs: std.json.ObjectMap,
    cache: std.ArrayList(Entry) = .empty,
    pending: std.ArrayList([]const u8) = .empty,

    fn convert(self: *Ctx, node: std.json.Value, label: []const u8) Error!*Schema {
        if (node != .object) return error.SCHEMA;
        if (node.object.get("$ref")) |ref| {
            if (ref != .string or !std.mem.startsWith(u8, ref.string, "#/$defs/")) return error.SCHEMA;
            return self.resolve(ref.string["#/$defs/".len..]);
        }
        const kind = node.object.get("type") orelse return error.SCHEMA;
        if (kind != .string) return error.SCHEMA;
        if (std.mem.eql(u8, kind.string, "boolean")) return leaf(self.arena, .boolean);
        if (std.mem.eql(u8, kind.string, "string")) {
            if (format(node)) |fmt| if (std.mem.eql(u8, fmt, "binary")) return leaf(self.arena, .bytes);
            return leaf(self.arena, .str);
        }
        if (std.mem.eql(u8, kind.string, "integer")) return leaf(self.arena, intKind(format(node) orelse ""));
        if (std.mem.eql(u8, kind.string, "number")) {
            if (format(node)) |fmt| if (std.mem.eql(u8, fmt, "float")) return leaf(self.arena, .f32);
            return leaf(self.arena, .f64);
        }
        if (std.mem.eql(u8, kind.string, "array")) {
            const items = node.object.get("items") orelse return error.SCHEMA;
            const child_label = try std.fmt.allocPrint(self.arena, "{s}Item", .{label});
            const child = try self.convert(items, child_label);
            return create(self.arena, .{ .kind = .list, .child = child });
        }
        if (std.mem.eql(u8, kind.string, "object")) return self.objectSchema(node, label);
        return error.SCHEMA;
    }

    fn objectSchema(self: *Ctx, node: std.json.Value, label: []const u8) Error!*Schema {
        const props = try objectField(node, "properties");
        if (node.object.get("additionalProperties")) |extra| {
            if (extra == .object and props.keys().len == 0) {
                const child_label = try std.fmt.allocPrint(self.arena, "{s}Value", .{label});
                const child = try self.convert(extra, child_label);
                return create(self.arena, .{ .kind = .dict, .child = child });
            }
        }
        var fields: std.ArrayList(Field) = .empty;
        const required = node.object.get("required");
        for (props.keys(), props.values()) |name, body| {
            const child_label = try std.fmt.allocPrint(self.arena, "{s}_{s}", .{ label, name });
            var field = try self.convert(body, child_label);
            if (required) |req| if (req == .array and !listed(req, name)) {
                field = try create(self.arena, .{ .kind = .opt, .child = field });
            };
            try fields.append(self.arena, .{ .name = name, .schema = field });
        }
        return create(self.arena, .{
            .kind = .structure,
            .fields = try fields.toOwnedSlice(self.arena),
            .label = label,
        });
    }

    fn resolve(self: *Ctx, name: []const u8) Error!*Schema {
        for (self.cache.items) |item| if (std.mem.eql(u8, item.name, name)) return item.schema;
        for (self.pending.items) |item| if (std.mem.eql(u8, item, name)) return error.SCHEMA;
        const def = self.defs.get(name) orelse return error.SCHEMA;
        try self.pending.append(self.arena, name);
        const built = try self.convert(def, name);
        _ = self.pending.pop();
        try self.cache.append(self.arena, .{ .name = name, .schema = built });
        return built;
    }
};

fn format(node: std.json.Value) ?[]const u8 {
    const value = node.object.get("format") orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn intKind(fmt: []const u8) Kind {
    if (std.mem.eql(u8, fmt, "int8")) return .i8;
    if (std.mem.eql(u8, fmt, "int16")) return .i16;
    if (std.mem.eql(u8, fmt, "int32")) return .i32;
    if (std.mem.eql(u8, fmt, "int64")) return .i64;
    if (std.mem.eql(u8, fmt, "uint8")) return .u8;
    if (std.mem.eql(u8, fmt, "uint16")) return .u16;
    if (std.mem.eql(u8, fmt, "uint32")) return .u32;
    if (std.mem.eql(u8, fmt, "uint64")) return .u64;
    return .i64;
}

fn objectField(node: std.json.Value, name: []const u8) Error!std.json.ObjectMap {
    const value = node.object.get(name) orelse return .empty;
    if (value != .object) return error.SCHEMA;
    return value.object;
}

fn listed(required: std.json.Value, name: []const u8) bool {
    if (required != .array) return false;
    for (required.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, name)) return true;
    }
    return false;
}

pub fn schemaFromJson(arena: std.mem.Allocator, text: []const u8) Error!JsonSchema {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.SCHEMA;
    if (doc != .object) return error.SCHEMA;
    var ctx = Ctx{ .arena = arena, .defs = try objectField(doc, "$defs") };
    const title = if (doc.object.get("title")) |value| switch (value) {
        .string => |s| s,
        else => "Root",
    } else "Root";
    return .{ .title = title, .root = try ctx.convert(doc, title) };
}

fn readText(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
}

test "point and message schemas" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const point_text = try readText(gpa, "testdata/schema/point.json");
    defer gpa.free(point_text);
    const point = try schemaFromJson(arena.allocator(), point_text);
    try std.testing.expectEqualStrings("Point", point.title);
    try std.testing.expectEqual(Kind.structure, point.root.kind);
    try std.testing.expectEqual(@as(usize, 3), point.root.fields.len);
    try std.testing.expectEqual(Kind.opt, point.root.fields[2].schema.kind);
    try std.testing.expectEqual(Kind.str, point.root.fields[2].schema.child.?.kind);
    const message_text = try readText(gpa, "testdata/schema/message.json");
    defer gpa.free(message_text);
    const message = try schemaFromJson(arena.allocator(), message_text);
    try std.testing.expectEqualStrings("Meta", message.root.fields[8].schema.label);
}
