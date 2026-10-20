//! Count and size checks. A failing check happens before element storage is allocated.

const Error = @import("error.zig").Error;

pub const default_cap: u64 = 16_777_216;
pub const max_depth: u32 = 64;
pub const tensor_header: u64 = 64;

pub fn add(a: u64, b: u64) Error!u64 {
    const sum, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return error.LIMIT;
    return sum;
}

pub fn mul(a: u64, b: u64) Error!u64 {
    const product, const overflow = @mulWithOverflow(a, b);
    if (overflow != 0) return error.LIMIT;
    return product;
}

pub fn align64(n: u64) Error!u64 {
    const rem = n & 63;
    if (rem == 0) return n;
    return add(n, 64 - rem);
}

/// `each == 0` skips the byte check. The cap still bounds the count.
pub fn fit(count: u64, each: u64, unread: u64, cap: u64) Error!void {
    if (count > cap) return error.LIMIT;
    if (each == 0) return;
    const need = try mul(count, each);
    if (need > unread) return error.EOF;
}
