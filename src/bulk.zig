//! Byte copy for numeric payloads.
//! On Linux with libc, copies of at least 2 KiB go through glibc `memcpy`
//! (non-temporal for a multi-megabyte buffer). Smaller copies stay `@memcpy`.

const std = @import("std");
const builtin = @import("builtin");

const use_libc = builtin.link_libc and builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;
const libc_min: usize = 2048;

const Memcpy = *const fn ([*]u8, [*]const u8, usize) callconv(.c) ?*anyopaque;

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// 0 = unset, 1 = no libc symbol, otherwise the glibc function address.
var resolved = std.atomic.Value(usize).init(0);

pub fn copy(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len == src.len);
    if (src.len == 0) return;
    if (comptime use_libc) {
        if (src.len >= libc_min) {
            if (glibc()) |memcpy| {
                _ = memcpy(dst.ptr, src.ptr, src.len);
                return;
            }
        }
    }
    @memcpy(dst, src);
}

fn glibc() ?Memcpy {
    if (comptime !use_libc) return null;
    const now = resolved.load(.acquire);
    if (now == 1) return null;
    if (now != 0) return @ptrFromInt(now);
    const next: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    const sym = dlsym(next, "memcpy") orelse {
        resolved.store(1, .release);
        return null;
    };
    const memcpy: Memcpy = @ptrCast(@alignCast(sym));
    resolved.store(@intFromPtr(memcpy), .release);
    return memcpy;
}
