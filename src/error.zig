//! Kiln error codes. The names match the wire specification.

pub const Error = error{
    FRAME,
    LIMIT,
    EOF,
    TYPE,
    UTF8,
    TRAILING,
    SCHEMA,
    OutOfMemory,
};

pub fn name(err: Error) []const u8 {
    return switch (err) {
        error.FRAME => "FRAME",
        error.LIMIT => "LIMIT",
        error.EOF => "EOF",
        error.TYPE => "TYPE",
        error.UTF8 => "UTF8",
        error.TRAILING => "TRAILING",
        error.SCHEMA => "SCHEMA",
        error.OutOfMemory => "OutOfMemory",
    };
}
