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
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), @as(u64, @bitCast(decoded.f64s.items[0])));
    try std.testing.expectEqual(@as(u64, 0x7FF8000000000001), @as(u64, @bitCast(decoded.f64s.items[1])));
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

test "primitive lists keep width and reuse the destination" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const f32_list = try schema_mod.parseTypeText(arena.allocator(), "list<f32>");
    const neg_zero: f32 = @bitCast(@as(u32, 0x80000000));
    const nan: f32 = @bitCast(@as(u32, 0x7fc00000));
    const floats = [_]f32{ neg_zero, nan, 1.0 };
    const raw = try encode(gpa, f32_list, .{ .f32s = .{ .items = &floats } }, .{});
    defer gpa.free(raw);
    try std.testing.expectEqual(@as(usize, 16), raw.len);
    try std.testing.expectEqual(@as(u32, 0x80000000), std.mem.readInt(u32, raw[4..8], .little));
    try std.testing.expectEqual(@as(u32, 0x7fc00000), std.mem.readInt(u32, raw[8..12], .little));

    var reuse = @import("value.zig").ListReuse{};
    defer reuse.deinit(gpa);
    var first = try decode(gpa, f32_list, raw, .{ .reuse = &reuse });
    defer first.deinit(gpa);
    const kept = first.f32s.items.ptr;
    try std.testing.expect(!first.f32s.owned);
    try std.testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast(first.f32s.items[0])));
    try std.testing.expectEqual(@as(u32, 0x7fc00000), @as(u32, @bitCast(first.f32s.items[1])));
    var second = try decode(gpa, f32_list, raw, .{ .reuse = &reuse });
    defer second.deinit(gpa);
    try std.testing.expectEqual(kept, second.f32s.items.ptr);
    try std.testing.expectEqual(@as(u32, 0x7fc00000), @as(u32, @bitCast(second.f32s.items[1])));

    const pair = try schema_mod.parseTypeText(arena.allocator(), "struct{a:list<f32>,b:list<f32>}");
    const a = [_]f32{ 1, 2 };
    const b = [_]f32{ 3, 4, 5 };
    const fields = [_]FieldValue{
        .{ .name = "a", .value = .{ .f32s = .{ .items = &a } } },
        .{ .name = "b", .value = .{ .f32s = .{ .items = &b } } },
    };
    const packed_raw = try encode(gpa, pair, .{ .structure = &fields }, .{});
    defer gpa.free(packed_raw);
    var both = try decode(gpa, pair, packed_raw, .{ .reuse = &reuse });
    defer both.deinit(gpa);
    try std.testing.expectEqual(@as(f32, 2), both.structure[0].value.f32s.items[1]);
    try std.testing.expectEqual(@as(f32, 5), both.structure[1].value.f32s.items[2]);
    try std.testing.expect(both.structure[0].value.f32s.items.ptr != both.structure[1].value.f32s.items.ptr);

    const i32_list = try schema_mod.parseTypeText(arena.allocator(), "list<i32>");
    const u32_list = try schema_mod.parseTypeText(arena.allocator(), "list<u32>");
    const u64_list = try schema_mod.parseTypeText(arena.allocator(), "list<u64>");
    const i64_list = try schema_mod.parseTypeText(arena.allocator(), "list<i64>");
    const ints = [_]i32{ -1, 2 };
    const i32_raw = try encode(gpa, i32_list, .{ .i32s = .{ .items = &ints } }, .{});
    defer gpa.free(i32_raw);
    try std.testing.expectEqual(@as(usize, 12), i32_raw.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0x02, 0x00, 0x00, 0x00 }, i32_raw[4..]);
    const wide = [_]u32{ 1, 2 };
    try std.testing.expectError(error.TYPE, encode(gpa, u64_list, .{ .u32s = .{ .items = &wide } }, .{}));
    try std.testing.expectError(error.TYPE, encode(gpa, i64_list, .{ .u32s = .{ .items = &wide } }, .{}));
    const u32_raw = try encode(gpa, u32_list, .{ .u32s = .{ .items = &wide } }, .{});
    defer gpa.free(u32_raw);
    try std.testing.expectEqual(@as(usize, 12), u32_raw.len);
    const words = [_]u64{1};
    const u64_raw = try encode(gpa, u64_list, .{ .u64s = .{ .items = &words } }, .{});
    defer gpa.free(u64_raw);
    try std.testing.expectEqual(@as(usize, 12), u64_raw.len);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, u64_raw[4..12], .little));

    // Top-level list<f64> is not 8-aligned after the u32 count, so it is copied.
    const f64_list = try schema_mod.parseTypeText(arena.allocator(), "list<f64>");
    const f64s = [_]f64{@bitCast(@as(u64, 0x7FF8000000000001))};
    const f64_raw = try encode(gpa, f64_list, .{ .f64s = .{ .items = &f64s } }, .{});
    defer gpa.free(f64_raw);
    var owned = try decode(gpa, f64_list, f64_raw, .{});
    defer owned.deinit(gpa);
    const f64_aligned = @intFromPtr(f64_raw.ptr + 4) % 8 == 0;
    try std.testing.expectEqual(!f64_aligned, owned.f64s.owned);
    try std.testing.expectEqual(@as(u64, 0x7FF8000000000001), @as(u64, @bitCast(owned.f64s.items[0])));
}

test "long f32 list reuses one destination" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const schema = try schema_mod.parseTypeText(arena.allocator(), "list<f32>");
    const xs = try gpa.alloc(f32, 2048);
    defer gpa.free(xs);
    for (xs, 0..) |*slot, i| slot.* = @floatFromInt(i);
    xs[0] = @bitCast(@as(u32, 0x80000000));
    xs[1] = @bitCast(@as(u32, 0x7fc00000));
    const raw = try encode(gpa, schema, .{ .f32s = .{ .items = xs } }, .{});
    defer gpa.free(raw);
    var reuse = @import("value.zig").ListReuse{};
    defer reuse.deinit(gpa);
    var first = try decode(gpa, schema, raw, .{ .reuse = &reuse });
    defer first.deinit(gpa);
    var second = try decode(gpa, schema, raw, .{ .reuse = &reuse });
    defer second.deinit(gpa);
    try std.testing.expectEqual(first.f32s.items.ptr, second.f32s.items.ptr);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(xs), std.mem.sliceAsBytes(second.f32s.items));
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
