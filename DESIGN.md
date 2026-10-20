# Kiln for Zig

Kiln is a positional little-endian codec. The caller passes the schema. `Writer` owns a buffer and reuses it. `decode` is checked. A tensor payload is a slice of the input buffer.

The normative text is [Kiln wire v2](https://leo-gan.github.io/gld-kiln/spec/). This repo does not copy that text into a Spec page.

| Topic | Choice |
| --- | --- |
| Wire | Frozen layout and the version-2 tensor directory |
| API | `encode` / `decode`, `Writer`, `encodeTensors` / `decodeTensors`, `schemaFromJson`, `gld-kilngen-zig` |
| Lengths | `u32` byte counts. Dict keys are sorted. Default cap 16777216 |
| Errors | `error.FRAME`, `LIMIT`, `EOF`, `TYPE`, `UTF8`, `TRAILING`, or `SCHEMA` |
| Package | module `kiln`, generator `gld-kilngen-zig`, Zig 0.16.0, MIT |

`Reader.u8Fast`, `u32Fast`, `u64Fast`, and `strFast` do not check the buffer length. `Options.check_utf8 = false` and `Options.check_quant = false` skip those checks. A length past the buffer is still `EOF` or `LIMIT`.
