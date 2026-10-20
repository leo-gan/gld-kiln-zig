const std = @import("std");
const kiln = @import("kiln");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema = try kiln.parseTypeText(arena, "struct{x:i32,y:i32}");
    const fields = [_]kiln.FieldValue{
        .{ .name = "x", .value = .{ .int = 9 } },
        .{ .name = "y", .value = .{ .int = -4 } },
    };
    const raw = try kiln.encode(init.gpa, schema, .{ .structure = &fields }, .{});
    defer init.gpa.free(raw);
    var value = try kiln.decode(init.gpa, schema, raw, .{});
    defer value.deinit(init.gpa);

    var stdout_buffer: [64]u8 = undefined;
    var stdout_writer = std.Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    try stdout_writer.interface.print("{d} {d}\n", .{ raw.len, value.structure[0].value.int });
    try stdout_writer.interface.flush();
}
