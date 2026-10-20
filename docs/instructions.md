# Instructions

Zig 0.16.0 or newer.

```bash
zig fetch --save git+https://github.com/leo-gan/gld-kiln-zig
```

In `build.zig`, import the module as `kiln`.

From a git checkout:

```bash
zig build test
zig build
./zig-out/bin/gld-kilngen-zig testdata/schema/point.json -o point.zig
```

The import name is `kiln`. `encode` and `decode` take a schema and a value. `Writer` reuses one buffer across calls. `schemaFromJson` reads the JSON Schema subset: booleans, integers with an optional `format`, numbers, strings, binary strings, arrays, objects, `$ref` of the form `#/$defs/Name`, and `additionalProperties` as a dict. A property omitted from `required` is optional. `gld-kilngen-zig` writes one Zig file of structs with `encode`, `decode`, and `encodedSize`. A `tensors` field is not produced from that JSON subset. Build a tensor directory with `encodeTensors` and read it with `decodeTensors` or `decodeTensorsInto`.
