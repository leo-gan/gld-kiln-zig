//! Positional little-endian Kiln codec for Zig.
const std = @import("std");

pub const version = "0.2.0";
pub const default_cap = @import("limit.zig").default_cap;
pub const Error = @import("error.zig").Error;
pub const errorName = @import("error.zig").name;
pub const typeHash = @import("hashing.zig").typeHash;
pub const Schema = @import("schema.zig").Schema;
pub const Field = @import("schema.zig").Field;
pub const Kind = @import("schema.zig").Kind;
pub const parseTypeText = @import("schema.zig").parseTypeText;
pub const minSize = @import("schema.zig").minSize;
pub const Value = @import("value.zig").Value;
pub const FieldValue = @import("value.zig").FieldValue;
pub const DictEntry = @import("value.zig").DictEntry;
pub const PodList = @import("value.zig").PodList;
pub const ListReuse = @import("value.zig").ListReuse;
pub const Tensor = @import("value.zig").Tensor;
pub const TensorDirectory = @import("value.zig").TensorDirectory;
pub const Writer = @import("writer.zig").Writer;
pub const Reader = @import("reader.zig").Reader;
pub const Options = @import("reader.zig").Options;
pub const encode = @import("frozen_enc.zig").encode;
pub const decode = @import("frozen_dec.zig").decode;
pub const encodeFramed = @import("frozen_enc.zig").encodeFramed;
pub const decodeFramed = @import("frozen_dec.zig").decodeFramed;
pub const encodeReuse = @import("frozen_enc.zig").encodeReuse;
pub const encodeTensors = @import("tensor_enc.zig").encodeTensors;
pub const encodeTensorsTo = @import("tensor_enc.zig").encodeTensorsTo;
pub const decodeTensors = @import("tensor_dec.zig").decodeTensors;
pub const decodeTensorsInto = @import("tensor_dec.zig").decodeTensorsInto;
pub const dtypeCode = @import("tensor.zig").dtypeCode;
pub const schemaFromJson = @import("schema_json.zig").schemaFromJson;
pub const emit = @import("codegen.zig").emit;

test "error names" {
    try std.testing.expectEqualStrings("EOF", errorName(error.EOF));
    try std.testing.expect(version.len > 0);
}

test {
    _ = @import("hashing.zig");
    _ = @import("reader.zig");
    _ = @import("writer.zig");
    _ = @import("tensor_enc.zig");
    _ = @import("frozen_test.zig");
    _ = @import("wire_test.zig");
    _ = @import("schema_json.zig");
    _ = @import("codegen_test.zig");
}
