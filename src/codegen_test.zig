const std = @import("std");
const emit = @import("codegen.zig").emit;

fn readText(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
}

test "generator text is stable" {
    const gpa = std.testing.allocator;
    const point = try readText(gpa, "testdata/schema/point.json");
    defer gpa.free(point);
    const once = try emit(gpa, point);
    defer gpa.free(once);
    const twice = try emit(gpa, point);
    defer gpa.free(twice);
    try std.testing.expectEqualSlices(u8, once, twice);
    try std.testing.expect(std.mem.indexOf(u8, once, "pub const Point") != null);
    try std.testing.expect(std.mem.indexOf(u8, once, "pub fn encode(") != null);
    try std.testing.expect(std.mem.indexOf(u8, once, "pub fn decode(") != null);
    try std.testing.expect(std.mem.indexOf(u8, once, "pub fn encodedSize(") != null);
    try std.testing.expect(std.mem.indexOf(u8, once, "label: ?[]const u8") != null);

    const message = try readText(gpa, "testdata/schema/message.json");
    defer gpa.free(message);
    const generated = try emit(gpa, message);
    defer gpa.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const Meta") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const Message") != null);
}

test "generated structs round-trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const point = try readText(gpa, "testdata/schema/point.json");
    defer gpa.free(point);
    const message = try readText(gpa, "testdata/schema/message.json");
    defer gpa.free(message);
    const point_src = try emit(gpa, point);
    defer gpa.free(point_src);
    const message_src = try emit(gpa, message);
    defer gpa.free(message_src);
    const bag_text =
        \\{"title":"Bag","type":"object","properties":{"scores":{"type":"array","items":{"type":"integer","format":"int32"}},"tags":{"type":"object","additionalProperties":{"type":"integer","format":"int32"}}},"required":["scores","tags"]}
    ;
    const bag_src = try emit(gpa, bag_text);
    defer gpa.free(bag_src);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/tmp/kiln-point.zig", .data = point_src });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/tmp/kiln-message.zig", .data = message_src });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/tmp/kiln-bag.zig", .data = bag_src });
    const driver =
        \\const std = @import("std");
        \\const point = @import("kiln-point.zig");
        \\const message = @import("kiln-message.zig");
        \\const bag = @import("kiln-bag.zig");
        \\test "point" {
        \\    const gpa = std.testing.allocator;
        \\    const value = point.Point{ .x = 3, .y = -1, .label = "n" };
        \\    const raw = try value.encode(gpa);
        \\    defer gpa.free(raw);
        \\    const back = try point.Point.decode(gpa, raw);
        \\    try std.testing.expectEqual(@as(i32, 3), back.x);
        \\    try std.testing.expectEqual(@as(i32, -1), back.y);
        \\    try std.testing.expectEqualStrings("n", back.label.?);
        \\    try std.testing.expectEqual(value.encodedSize(), raw.len);
        \\    const absent = point.Point{ .x = 1, .y = 2 };
        \\    const raw2 = try absent.encode(gpa);
        \\    defer gpa.free(raw2);
        \\    const back2 = try point.Point.decode(gpa, raw2);
        \\    try std.testing.expect(back2.label == null);
        \\}
        \\test "message" {
        \\    const gpa = std.testing.allocator;
        \\    const value = message.Message{
        \\        .f_bool = true,
        \\        .f_int32 = -2,
        \\        .f_int64 = 99,
        \\        .f_float64 = 1.5,
        \\        .f_string = "hello",
        \\        .f_bool_2 = false,
        \\        .f_int32_2 = 7,
        \\        .f_string_2 = "world",
        \\        .meta = .{ .region = "us", .flag = true },
        \\    };
        \\    const raw = try value.encode(gpa);
        \\    defer gpa.free(raw);
        \\    const back = try message.Message.decode(gpa, raw);
        \\    try std.testing.expectEqualStrings("hello", back.f_string);
        \\    try std.testing.expectEqualStrings("us", back.meta.region);
        \\    try std.testing.expect(back.meta.flag);
        \\    try std.testing.expectEqual(value.encodedSize(), raw.len);
        \\}
        \\test "bag" {
        \\    const gpa = std.testing.allocator;
        \\    const value = bag.Bag{
        \\        .scores = &.{ 3, -1, 8 },
        \\        .tags = &.{
        \\            .{ .key = "b", .value = 2 },
        \\            .{ .key = "a", .value = 1 },
        \\        },
        \\    };
        \\    const raw = try value.encode(gpa);
        \\    defer gpa.free(raw);
        \\    var back = try bag.Bag.decode(gpa, raw);
        \\    defer back.deinit(gpa);
        \\    try std.testing.expectEqual(@as(usize, 3), back.scores.len);
        \\    try std.testing.expectEqual(@as(i32, -1), back.scores[1]);
        \\    try std.testing.expectEqualStrings("a", back.tags[0].key);
        \\    try std.testing.expectEqual(@as(i32, 1), back.tags[0].value);
        \\    try std.testing.expectEqualStrings("b", back.tags[1].key);
        \\    try std.testing.expectEqual(value.encodedSize(), raw.len);
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/tmp/kiln-driver.zig", .data = driver });
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const kiln_src = try std.fmt.allocPrint(gpa, "{s}/src/root.zig", .{cwd_buf[0..cwd_len]});
    defer gpa.free(kiln_src);
    const kiln_mod = try std.fmt.allocPrint(gpa, "-Mkiln={s}", .{kiln_src});
    defer gpa.free(kiln_mod);
    const bins = [_][]const u8{ "zig", "/home/leo/.local/zig/zig", "/home/runner/zig-0.16.0/zig" };
    var result: std.process.RunResult = undefined;
    var ran = false;
    for (bins) |bin| {
        result = std.process.run(gpa, io, .{
            .argv = &.{
                bin,
                "test",
                "--dep",
                "kiln",
                "-Mroot=/tmp/kiln-driver.zig",
                kiln_mod,
                "--cache-dir",
                "/tmp/kiln-zig-cache",
            },
        }) catch continue;
        ran = true;
        break;
    }
    if (!ran) return error.TestExpectedError;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
        return error.TestExpectedError;
    }
}
