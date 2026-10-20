const std = @import("std");
const schema_mod = @import("schema.zig");
const Value = @import("value.zig").Value;
const FieldValue = @import("value.zig").FieldValue;
const encode = @import("frozen_enc.zig").encode;
const encodeFramed = @import("frozen_enc.zig").encodeFramed;
const decode = @import("frozen_dec.zig").decode;
const decodeFramed = @import("frozen_dec.zig").decodeFramed;

const point_bytes = [_]u8{ 0x09, 0x00, 0x00, 0x00, 0xfc, 0xff, 0xff, 0xff };
const message_hex = "01feffffff6300000000000000000000000000f83f0500000068656c6c6f000700000005000000776f726c64";

test "reference point and hostile list" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const point = try schema_mod.parseTypeText(arena.allocator(), "struct{x:i32,y:i32}");
    const fields = [_]FieldValue{
        .{ .name = "x", .value = .{ .int = 9 } },
        .{ .name = "y", .value = .{ .int = -4 } },
    };
    const raw = try encode(gpa, point, .{ .structure = &fields }, .{});
    defer gpa.free(raw);
    try std.testing.expectEqualSlices(u8, &point_bytes, raw);
    var decoded = try decode(gpa, point, raw, .{});
    defer decoded.deinit(gpa);
    const again = try encode(gpa, point, decoded, .{});
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, raw, again);

    const framed = try encodeFramed(gpa, point, .{ .structure = &fields }, .{});
    defer gpa.free(framed);
    var round = try decodeFramed(gpa, point, framed, .{});
    defer round.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 9), round.structure[0].value.int);

    const hostile = try schema_mod.parseTypeText(arena.allocator(), "list<struct{a:i64}>");
    try std.testing.expectError(error.EOF, decode(gpa, hostile, &[_]u8{ 0x00, 0x00, 0x00, 0x01 }, .{}));
}

test "negative zero, quiet nan, dict order, and opt" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const list = try schema_mod.parseTypeText(arena.allocator(), "list<f64>");
    const nan: f64 = @bitCast(@as(u64, 0x7FF8000000000001));
    const items = [_]Value{ .{ .f64 = -0.0 }, .{ .f64 = nan } };
    const raw = try encode(gpa, list, .{ .list = &items }, .{});
    defer gpa.free(raw);
    var decoded = try decode(gpa, list, raw, .{});
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), @as(u64, @bitCast(decoded.list[0].f64)));
    try std.testing.expectEqual(@as(u64, 0x7FF8000000000001), @as(u64, @bitCast(decoded.list[1].f64)));
    const again = try encode(gpa, list, decoded, .{});
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, raw, again);

    const dict = try schema_mod.parseTypeText(arena.allocator(), "dict<str,i32>");
    const entries = [_]@import("value.zig").DictEntry{
        .{ .key = "b", .value = .{ .int = 2 } },
        .{ .key = "a", .value = .{ .int = 1 } },
    };
    const encoded = try encode(gpa, dict, .{ .dict = &entries }, .{});
    defer gpa.free(encoded);
    var got = try decode(gpa, dict, encoded, .{});
    defer got.deinit(gpa);
    try std.testing.expectEqualStrings("a", got.dict[0].key);
    try std.testing.expectEqual(@as(i64, 1), got.dict[0].value.int);
    try std.testing.expectEqualStrings("b", got.dict[1].key);

    const opt = try schema_mod.parseTypeText(arena.allocator(), "opt<str>");
    const absent = try encode(gpa, opt, .none, .{});
    defer gpa.free(absent);
    var none = try decode(gpa, opt, absent, .{});
    defer none.deinit(gpa);
    try std.testing.expect(none == .none);
    const present = try encode(gpa, opt, .{ .str = "z" }, .{});
    defer gpa.free(present);
    var some = try decode(gpa, opt, present, .{});
    defer some.deinit(gpa);
    try std.testing.expectEqualStrings("z", some.str);
}

test "reference message bytes" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const schema = try schema_mod.parseTypeText(arena.allocator(), "struct{f_bool:bool,f_int32:i32,f_int64:i64,f_float64:f64,f_string:str,f_bool_2:bool,f_int32_2:i32,f_string_2:str}");
    var storage: [64]u8 = undefined;
    const message_bytes = std.fmt.hexToBytes(&storage, message_hex) catch unreachable;
    var decoded = try decode(gpa, schema, message_bytes, .{});
    defer decoded.deinit(gpa);
    const again = try encode(gpa, schema, decoded, .{});
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, message_bytes, again);
    const framed = try encodeFramed(gpa, schema, decoded, .{});
    defer gpa.free(framed);
    var round = try decodeFramed(gpa, schema, framed, .{});
    defer round.deinit(gpa);
    try std.testing.expectEqualStrings("hello", round.structure[4].value.str);
}
