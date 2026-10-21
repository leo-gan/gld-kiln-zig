//! Checked cursor. `*Fast` reads do not test the buffer length.

const std = @import("std");
const builtin = @import("builtin");
const Error = @import("error.zig").Error;
const limit = @import("limit.zig");
const ListReuse = @import("value.zig").ListReuse;
const bulk = @import("bulk.zig").copy;

pub const Options = struct {
    cap: u64 = limit.default_cap,
    standalone: bool = true,
    check_utf8: bool = true,
    check_quant: bool = true,
    /// When set, numeric lists are copied here instead of borrowed.
    reuse: ?*ListReuse = null,
};

pub const Reader = struct {
    buf: []const u8,
    i: usize = 0,
    cap: u64 = limit.default_cap,
    check_utf8: bool = true,
    check_quant: bool = true,
    depth: u32 = 0,
    reuse: ?*ListReuse = null,

    pub fn init(buf: []const u8, opts: Options) Reader {
        return .{
            .buf = buf,
            .cap = opts.cap,
            .check_utf8 = opts.check_utf8,
            .check_quant = opts.check_quant,
            .reuse = opts.reuse,
        };
    }

    pub fn remaining(self: Reader) u64 {
        return @intCast(self.buf.len - self.i);
    }

    pub fn finish(self: Reader) Error!void {
        if (self.i != self.buf.len) return error.TRAILING;
    }

    pub fn descend(self: *Reader) Error!void {
        if (self.depth > limit.max_depth) return error.LIMIT;
        self.depth += 1;
    }

    pub fn ascend(self: *Reader) void {
        self.depth -= 1;
    }

    pub fn int(self: *Reader, comptime T: type) Error!T {
        const n = @sizeOf(T);
        if (self.buf.len - self.i < n) return error.EOF;
        const value = std.mem.readInt(T, self.buf[self.i..][0..n], .little);
        self.i += n;
        return value;
    }

    pub fn boolean(self: *Reader) Error!bool {
        const byte = try self.int(u8);
        if (byte > 1) return error.TYPE;
        return byte == 1;
    }

    pub fn float32(self: *Reader) Error!f32 {
        return @bitCast(try self.int(u32));
    }

    pub fn float64(self: *Reader) Error!f64 {
        return @bitCast(try self.int(u64));
    }

    pub fn bytes(self: *Reader) Error![]const u8 {
        const len = try self.int(u32);
        if (len > self.cap) return error.LIMIT;
        if (len > self.remaining()) return error.EOF;
        const start = self.i;
        self.i += len;
        return self.buf[start..self.i];
    }

    pub fn str(self: *Reader) Error![]const u8 {
        const raw = try self.bytes();
        if (self.check_utf8 and !std.unicode.utf8ValidateSlice(raw)) return error.UTF8;
        return raw;
    }

    pub fn optTag(self: *Reader) Error!bool {
        const tag = try self.int(u8);
        if (tag > 1) return error.TYPE;
        return tag == 1;
    }

    /// Count check. Callers allocate only after this returns.
    pub fn listHeader(self: *Reader, each: u64) Error!u32 {
        const count = try self.int(u32);
        try limit.fit(count, each, self.remaining(), self.cap);
        return count;
    }

    pub fn pod(self: *Reader, comptime T: type, dest: []T) Error!void {
        const nbytes: u64 = try limit.mul(dest.len, @sizeOf(T));
        if (nbytes > self.remaining()) return error.EOF;
        if (comptime builtin.cpu.arch.endian() == .little) {
            const raw = std.mem.sliceAsBytes(dest);
            bulk(raw, self.buf[self.i..][0..raw.len]);
            self.i += raw.len;
            return;
        }
        for (dest) |*slot| slot.* = try self.int(T);
    }

    pub fn float32s(self: *Reader, dest: []f32) Error!void {
        const nbytes: u64 = try limit.mul(dest.len, 4);
        if (nbytes > self.remaining()) return error.EOF;
        if (comptime builtin.cpu.arch.endian() == .little) {
            const raw = std.mem.sliceAsBytes(dest);
            bulk(raw, self.buf[self.i..][0..raw.len]);
            self.i += raw.len;
            return;
        }
        for (dest) |*slot| slot.* = try self.float32();
    }

    pub fn float64s(self: *Reader, dest: []f64) Error!void {
        const nbytes: u64 = try limit.mul(dest.len, 8);
        if (nbytes > self.remaining()) return error.EOF;
        if (comptime builtin.cpu.arch.endian() == .little) {
            const raw = std.mem.sliceAsBytes(dest);
            bulk(raw, self.buf[self.i..][0..raw.len]);
            self.i += raw.len;
            return;
        }
        for (dest) |*slot| slot.* = try self.float64();
    }

    pub fn u8Fast(self: *Reader) u8 {
        const byte = self.buf.ptr[self.i];
        self.i += 1;
        return byte;
    }

    pub fn u32Fast(self: *Reader) u32 {
        const p: *const [4]u8 = @ptrCast(self.buf.ptr + self.i);
        self.i += 4;
        return std.mem.readInt(u32, p, .little);
    }

    pub fn u64Fast(self: *Reader) u64 {
        const p: *const [8]u8 = @ptrCast(self.buf.ptr + self.i);
        self.i += 8;
        return std.mem.readInt(u64, p, .little);
    }

    pub fn strFast(self: *Reader) []const u8 {
        const n = self.u32Fast();
        const start = self.i;
        self.i += n;
        return self.buf.ptr[start..self.i];
    }
};

test "list header rejects a short body before a caller could allocate" {
    var reader = Reader.init(&[_]u8{ 0x01, 0x00, 0x00, 0x00 }, .{});
    try std.testing.expectError(error.EOF, reader.listHeader(8));
}
