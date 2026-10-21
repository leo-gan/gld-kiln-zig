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

    const n_f32: usize = 1_048_576;
    const floats = try gpa.alloc(f32, n_f32);
    defer gpa.free(floats);
    for (floats, 0..) |*slot_f, i| slot_f.* = @bitCast(@as(u32, @truncate(i *% 0x9E3779B1)));
    floats[0] = @bitCast(@as(u32, 0x80000000));
    floats[1] = @bitCast(@as(u32, 0x7fc00000));
    var pod_writer = kiln.Writer{};
    defer pod_writer.deinit(gpa);
    var pod_write = struct {
        writer: *kiln.Writer,
        gpa: std.mem.Allocator,
        values: []const f32,
        sink: u64 = 0,
        fn run(self: *@This()) void {
            self.writer.reset();
            self.writer.int(self.gpa, i32, 1024) catch unreachable;
            self.writer.int(self.gpa, i32, 1024) catch unreachable;
            self.writer.int(self.gpa, u32, @intCast(self.values.len)) catch unreachable;
            self.writer.float32s(self.gpa, self.values) catch unreachable;
            const encoded = self.writer.slice();
            self.sink +%= encoded[encoded.len - 1];
            consume(encoded);
        }
    }{ .writer = &pod_writer, .gpa = gpa, .values = floats };
    const pod_write_best = bestNanos(init.io, 6, 20, &pod_write);
    const wire = try gpa.dupe(u8, pod_writer.slice());
    defer gpa.free(wire);
    const read_dest = try gpa.alloc(f32, n_f32);
    defer gpa.free(read_dest);
    var pod_read = struct {
        bytes: []const u8,
        dest: []f32,
        sink: u64 = 0,
        fn run(self: *@This()) void {
            var reader = kiln.Reader.init(self.bytes, .{});
            const rows = reader.int(i32) catch unreachable;
            const cols = reader.int(i32) catch unreachable;
            const n = reader.listHeader(4) catch unreachable;
            reader.float32s(self.dest[0..n]) catch unreachable;
            self.sink +%= @as(u32, @bitCast(self.dest[0]));
            self.sink +%= @as(u32, @bitCast(self.dest[n - 1]));
            self.sink +%= @as(u32, @intCast(rows));
            self.sink +%= @as(u32, @intCast(cols));
            consume(std.mem.sliceAsBytes(self.dest));
        }
    }{ .bytes = wire, .dest = read_dest };
    const pod_read_best = bestNanos(init.io, 6, 20, &pod_read);

    var schema_arena = std.heap.ArenaAllocator.init(gpa);
    defer schema_arena.deinit();
    const schema = try kiln.parseTypeText(schema_arena.allocator(), "struct{rows:i32,cols:i32,values:list<f32>}");
    const fields = [_]kiln.FieldValue{
        .{ .name = "rows", .value = .{ .int = 1024 } },
        .{ .name = "cols", .value = .{ .int = 1024 } },
        .{ .name = "values", .value = .{ .f32s = .{ .items = floats } } },
    };
    const root = kiln.Value{ .structure = &fields };
    var value_write = struct {
        writer: *kiln.Writer,
        gpa: std.mem.Allocator,
        schema: *const kiln.Schema,
        value: kiln.Value,
        sink: u64 = 0,
        fn run(self: *@This()) void {
            const encoded = kiln.encodeReuse(self.writer, self.gpa, self.schema, self.value) catch unreachable;
            self.sink +%= encoded[encoded.len - 1];
            consume(encoded);
        }
    }{ .writer = &pod_writer, .gpa = gpa, .schema = schema, .value = root };
    const value_write_best = bestNanos(init.io, 4, 12, &value_write);
    var list_reuse = kiln.ListReuse{};
    defer list_reuse.deinit(gpa);
    var value_read = struct {
        gpa: std.mem.Allocator,
        schema: *const kiln.Schema,
        bytes: []const u8,
        reuse: *kiln.ListReuse,
        sink: u64 = 0,
        fn run(self: *@This()) void {
            var decoded = kiln.decode(self.gpa, self.schema, self.bytes, .{ .reuse = self.reuse }) catch unreachable;
            const items = decoded.structure[2].value.f32s.items;
            self.sink +%= @as(u32, @bitCast(items[0]));
            self.sink +%= @as(u32, @bitCast(items[items.len - 1]));
            consume(std.mem.sliceAsBytes(items));
            decoded.deinit(self.gpa);
        }
    }{ .gpa = gpa, .schema = schema, .bytes = wire, .reuse = &list_reuse };
    const value_read_best = bestNanos(init.io, 4, 12, &value_read);
    var borrow_read = struct {
        gpa: std.mem.Allocator,
        schema: *const kiln.Schema,
        bytes: []const u8,
        sink: u64 = 0,
        fn run(self: *@This()) void {
            var decoded = kiln.decode(self.gpa, self.schema, self.bytes, .{}) catch unreachable;
            const items = decoded.structure[2].value.f32s.items;
            self.sink +%= @as(u32, @bitCast(items[0]));
            self.sink +%= items.len;
            decoded.deinit(self.gpa);
        }
    }{ .gpa = gpa, .schema = schema, .bytes = wire };
    const borrow_best = bestNanos(init.io, 4, 20, &borrow_read);

    try out.print("f32_n {d}\n", .{n_f32});
    try out.print("f32_write_ns {d}\n", .{pod_write_best});
    try out.print("f32_read_ns {d}\n", .{pod_read_best});
    try out.print("f32_value_write_ns {d}\n", .{value_write_best});
    try out.print("f32_value_read_ns {d}\n", .{value_read_best});
    try out.print("f32_borrow_read_ns {d}\n", .{borrow_best});
    try out.print("f32_bits_ok {d}\n", .{@as(u32, @intFromBool(@as(u32, @bitCast(read_dest[0])) == 0x80000000 and @as(u32, @bitCast(read_dest[1])) == 0x7fc00000))});
    try out.flush();
}

fn bestNanos(io: std.Io, comptime rounds: usize, n: usize, body: anytype) i64 {
    var best: i64 = std.math.maxInt(i64);
    for (0..rounds) |_| {
        const per: i64 = @intCast(nanos(io, 2, n, body));
        if (per < best) best = per;
    }
    return best;
}
