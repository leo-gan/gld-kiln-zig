# Why Kiln

A Zig program that sends a struct to another process, or stores it in a file, has to pick an encoding. Many encodings write a name or a numeric tag in front of every value. That name helps a reader that does not know which field comes next. When both programs were generated from the same struct, the order is already fixed, and the name on the wire repeats it.

Kiln is for the case where the struct is the schema. `gld-kilngen-zig` reads a JSON Schema file and writes a Zig struct whose fields are the schema. `encodeTo` stores those fields in declaration order: little-endian integers and floats, then a `u32` length and the bytes of each string. The bytes do not carry field names.

One small record is a handful of stores plus the copy of its strings. A batch is that record repeated, so a branch or an allocation per field is paid once per record. `Writer` keeps its buffer, and the next `encodeTo` reuses the allocation. A large numeric array is a third case. It is a tensor directory inside a Frozen value: a fixed-width table, then 64-byte-aligned payloads. The numeric bytes stay the array. A scale is another tensor in that directory.

`decode` rejects a length that would read past the buffer, and it checks UTF-8. A hostile count fails before Kiln allocates element storage. A tensor payload is returned as a slice of the input buffer.

This version is for programs that share one struct definition. An optional frame stores a hash of the type and rejects the buffer when the struct no longer matches.

The normative wire rules are the Kiln wire specification published with the Mojo library: [Kiln wire v2](https://leo-gan.github.io/gld-kiln/spec/). This Zig library follows that text. It does not publish a second specification.
