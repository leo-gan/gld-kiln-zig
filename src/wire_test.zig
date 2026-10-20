const std = @import("std");
const schemaFromCase = @import("schema.zig").schemaFromCase;
const encode = @import("frozen_enc.zig").encode;
const encodeFramed = @import("frozen_enc.zig").encodeFramed;
const decode = @import("frozen_dec.zig").decode;
const decodeFramed = @import("frozen_dec.zig").decodeFramed;
const errorName = @import("error.zig").name;
const typeHash = @import("hashing.zig").typeHash;
const same = @import("wire_cmp.zig").same;

test "kiln-v2 cases" {
    const gpa = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/kiln-v2-cases.json", gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 46), cases.len);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    for (cases) |case| try oneCase(gpa, arena.allocator(), case);
}

fn oneCase(gpa: std.mem.Allocator, arena: std.mem.Allocator, case: std.json.Value) !void {
    const object = case.object;
    const id = object.get("id").?.string;
    const schema = try schemaFromCase(arena, object.get("schema").?);
    const hex = object.get("input").?.string;
    const raw = try gpa.alloc(u8, hex.len / 2);
    defer gpa.free(raw);
    _ = std.fmt.hexToBytes(raw, hex) catch unreachable;
    const framed = object.get("schema").? == .string and std.mem.eql(u8, object.get("schema").?.string, "frame");
    if (std.mem.eql(u8, object.get("expect").?.string, "reject")) {
        const failed = if (framed) decodeFramed(gpa, schema, raw, .{}) else decode(gpa, schema, raw, .{});
        if (failed) |_| {
            std.debug.print("{s}: expected {s}\n", .{ id, object.get("error").?.string });
            return error.TestExpectedError;
        } else |err| {
            if (!std.mem.eql(u8, errorName(err), object.get("error").?.string)) {
                std.debug.print("{s}: got {s} want {s}\n", .{ id, errorName(err), object.get("error").?.string });
                return error.TestExpectedError;
            }
        }
        return;
    }
    var value = if (framed) try decodeFramed(gpa, schema, raw, .{}) else try decode(gpa, schema, raw, .{});
    defer value.deinit(gpa);
    if (object.get("decoded")) |want| {
        if (framed) {
            const hash = try typeHash(schema);
            const recorded = want.object.get("hash").?;
            const text_hash = switch (recorded) {
                .integer => |n| @as(u64, @intCast(n)),
                .number_string => |s| try std.fmt.parseInt(u64, s, 10),
                else => return error.TestUnexpectedResult,
            };
            if (hash != text_hash) {
                std.debug.print("{s}: hash {x} != {x}\n", .{ id, hash, text_hash });
                return error.TestExpectedError;
            }
        }
        if (!same(value, want)) {
            std.debug.print("{s}: decoded value mismatch\n", .{id});
            return error.TestExpectedError;
        }
    }
    const again = if (framed) try encodeFramed(gpa, schema, value, .{}) else try encode(gpa, schema, value, .{});
    defer gpa.free(again);
    if (!std.mem.eql(u8, again, raw)) {
        std.debug.print("{s}: re-encode {d} bytes, input {d}\n", .{ id, again.len, raw.len });
        return error.TestExpectedError;
    }
}
