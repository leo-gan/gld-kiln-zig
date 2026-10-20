# Examples

`Point` has two `i32` fields. Kiln writes them in that order. Eight little-endian bytes, and no names.

```zig
const schema = try kiln.parseTypeText(arena, "struct{x:i32,y:i32}");
const fields = [_]kiln.FieldValue{
    .{ .name = "x", .value = .{ .int = 9 } },
    .{ .name = "y", .value = .{ .int = -4 } },
};
const raw = try kiln.encode(gpa, schema, .{ .structure = &fields }, .{});
defer gpa.free(raw);
```

`raw` is 8 bytes. `examples/roundtrip.zig` is the same shape.

A tensor directory keeps the numeric payload as the array. `data` is a slice of the input buffer.

```zig
var shape = [_]u64{0} ** 8;
shape[0] = 2;
const data = [_]u8{ 0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x00, 0xc0 };
const tensors = [_]kiln.Tensor{.{ .dtype = 2, .rank = 1, .shape = shape, .data = &data }};
const block = try kiln.encodeTensors(gpa, &tensors);
defer gpa.free(block);
var slot: [1]kiln.Tensor = undefined;
const directory = try kiln.decodeTensorsInto(block, &slot, .{});
```

`directory.block_length` is 200. `slot[0].data` is the eight payload bytes inside `block`.
