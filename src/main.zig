const std = @import("std");
const kiln = @import("kiln");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var schema_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "-o") or std.mem.eql(u8, args[index], "--output")) {
            index += 1;
            if (index >= args.len) return usage();
            output_path = args[index];
        } else if (std.mem.eql(u8, args[index], "-h") or std.mem.eql(u8, args[index], "--help")) {
            return usage();
        } else {
            schema_path = args[index];
        }
    }
    const schema = schema_path orelse return usage();
    const output = output_path orelse return usage();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, schema, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(text);
    const source = try kiln.emit(gpa, text);
    defer gpa.free(source);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = source });
}

fn usage() error{InvalidArgument} {
    std.debug.print("usage: gld-kilngen-zig <schema.json> -o <output.zig>\n", .{});
    return error.InvalidArgument;
}
