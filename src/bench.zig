const std = @import("std");
const kiln = @import("kiln");

const Point = struct {
    x: i32,
    y: i32,
    label: []const u8,

    fn encodeTo(self: Point, writer: *kiln.Writer, gpa: std.mem.Allocator) !void {
        try writer.int(gpa, i32, self.x);
        try writer.int(gpa, i32, self.y);
        try writer.str(gpa, self.label);
    }
};

fn decodePoint(buf: []const u8) !Point {
    var reader = kiln.Reader.init(buf, .{});
    return .{
        .x = try reader.int(i32),
        .y = try reader.int(i32),
        .label = try reader.str(),
    };
}

noinline fn consume(buf: []const u8) void {
    std.mem.doNotOptimizeAway(buf.len);
    asm volatile (""
        :
        : [p] "r" (buf.ptr),
        : .{ .memory = true });
}

fn nanos(io: std.Io, comptime warm: usize, n: usize, body: anytype) i96 {
    for (0..warm) |_| body.run();
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..n) |_| body.run();
    const elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake));
    std.mem.doNotOptimizeAway(body.sink);
    return @divTrunc(elapsed.nanoseconds, @as(i96, n));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const point = Point{ .x = 9, .y = -4, .label = "item" };
    var writer = kiln.Writer{};
    defer writer.deinit(gpa);
    try point.encodeTo(&writer, gpa);
    const struct_bytes = writer.slice().len;

    var enc = struct {
        point: Point,
        writer: *kiln.Writer,
        gpa: std.mem.Allocator,
        sink: u64 = 0,
        fn run(self: *@This()) void {
            self.sink +%= 1;
            self.point.x = @bitCast(@as(u32, @truncate(self.sink)));
            self.writer.reset();
            self.point.encodeTo(self.writer, self.gpa) catch unreachable;
            consume(self.writer.slice());
            self.sink +%= self.writer.slice()[0];
        }
    }{ .point = point, .writer = &writer, .gpa = gpa };
    var dec = struct {
        writer: *kiln.Writer,
        sink: u64 = 0,
        fn run(self: *@This()) void {
            const value = decodePoint(self.writer.slice()) catch unreachable;
            consume(value.label);
            self.sink +%= @as(u32, @bitCast(value.x));
            self.sink +%= value.label.len;
        }
    }{ .writer = &writer };

    var samples: [1024]f32 = @splat(1);
    var shape = [_]u64{0} ** 8;
    shape[0] = samples.len;
    const tensor = [_]kiln.Tensor{.{
        .dtype = 2,
        .rank = 1,
        .shape = shape,
        .data = std.mem.sliceAsBytes(&samples),
    }};
    const block = try kiln.encodeTensors(gpa, &tensor);
    defer gpa.free(block);
    var slot: [1]kiln.Tensor = undefined;

    var tensor_writer = kiln.Writer{};
    defer tensor_writer.deinit(gpa);
    var tenc = struct {
        gpa: std.mem.Allocator,
        tensor: []const kiln.Tensor,
        sink: u64 = 0,
        fn run(self: *@This()) void {
            const encoded = kiln.encodeTensors(self.gpa, self.tensor) catch unreachable;
            consume(encoded);
            self.sink +%= encoded[encoded.len - 1];
            self.gpa.free(encoded);
        }
    }{ .gpa = gpa, .tensor = &tensor };
    var treuse = struct {
        gpa: std.mem.Allocator,
        writer: *kiln.Writer,
        tensor: []const kiln.Tensor,
        sink: u64 = 0,
        fn run(self: *@This()) void {
            self.writer.reset();
            kiln.encodeTensorsTo(self.writer, self.gpa, self.tensor) catch unreachable;
            consume(self.writer.slice());
            self.sink +%= self.writer.slice()[self.writer.slice().len - 1];
        }
    }{ .gpa = gpa, .writer = &tensor_writer, .tensor = &tensor };
    var tdec = struct {
        block: []const u8,
        slot: *[1]kiln.Tensor,
        sink: u64 = 0,
        fn run(self: *@This()) void {
            const directory = kiln.decodeTensorsInto(self.block, self.slot, .{}) catch unreachable;
            consume(self.slot[0].data);
            self.sink +%= directory.block_length;
            self.sink +%= self.slot[0].data[0];
        }
    }{ .block = block, .slot = &slot };

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("struct_encode_ns {d}\n", .{nanos(init.io, 1000, 200000, &enc)});
    try out.print("struct_decode_ns {d}\n", .{nanos(init.io, 1000, 200000, &dec)});
    try out.print("struct_bytes {d}\n", .{struct_bytes});
    try out.print("tensor_encode_ns {d}\n", .{nanos(init.io, 20, 200, &tenc)});
    try out.print("tensor_encode_reuse_ns {d}\n", .{nanos(init.io, 20, 200, &treuse)});
    try out.print("tensor_decode_ns {d}\n", .{nanos(init.io, 20, 200, &tdec)});
    try out.print("tensor_bytes {d}\n", .{block.len});
    try out.flush();
}
