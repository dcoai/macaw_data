//! The buffers a kernel reads and the memory it grows: a binary's bytes in place, an
//! Arrow bitmap's bits, little-endian values, and lists in the BEAM's own memory.

const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");

pub const KernelError = error{ NotABinary, NotAPiece, ShortBuffer, UnknownForm };

/// A binary's bytes, in place: the term's own data, never copied.
pub fn bytes(term: beam.term) KernelError![]const u8 {
    var bin: e.ErlNifBinary = undefined;
    if (e.enif_inspect_binary(beam.context.env, term.v, &bin) == 0) return error.NotABinary;
    if (bin.size == 0) return &[_]u8{};
    return bin.data[0..bin.size];
}

/// Bit `i` of an LSB-first bitmap (Arrow's): bit `i % 8` of byte `i / 8`.
pub inline fn bit(bitmap: []const u8, i: usize) bool {
    return (bitmap[i >> 3] >> @as(u3, @intCast(i & 7))) & 1 == 1;
}

pub inline fn readI64(data: []const u8, i: usize) i64 {
    return std.mem.readInt(i64, data[i * 8 ..][0..8], .little);
}

pub inline fn readF64(data: []const u8, i: usize) f64 {
    return @bitCast(std.mem.readInt(u64, data[i * 8 ..][0..8], .little));
}

pub inline fn readI32(data: []const u8, i: usize) i32 {
    return std.mem.readInt(i32, data[i * 4 ..][0..4], .little);
}

/// A probe of one kernel call's allocations (macaw_data#101): how many were asked for, how
/// many are live, and which one fails (the `fail_at`th, `0` none). Set only by a probe NIF,
/// for its own call on its own thread, and cleared before it returns; every other call
/// finds it null.
pub const Probe = struct { fail_at: usize, calls: usize = 0, live: isize = 0 };
pub threadlocal var probe: ?*Probe = null;

/// Every kernel allocation is made here, so a probe counts each and can fail any one.
pub fn alloc(size: usize) ?*anyopaque {
    if (probe) |p| {
        p.calls += 1;
        if (p.calls == p.fail_at) return null;
        const raw = e.enif_alloc(size) orelse return null;
        p.live += 1;
        return raw;
    }
    return e.enif_alloc(size);
}

/// A reallocation keeps the block live, moved or not; a failed one leaves it as it was.
pub fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    if (probe) |p| {
        p.calls += 1;
        if (p.calls == p.fail_at) return null;
    }
    return e.enif_realloc(ptr, size);
}

pub fn free(ptr: ?*anyopaque) void {
    if (probe) |p| p.live -= 1;
    e.enif_free(ptr);
}

/// A growing list of `T` in the BEAM's memory, doubled as it fills, so its cost follows
/// what it holds, not the rows read. Raw `enif_realloc`: the `std.mem.Allocator` interface
/// fills new memory with 0xAA in a safe build, a write per byte that would cost more than
/// a walk.
pub fn Grow(comptime T: type) type {
    return struct {
        items: [*]T,
        len: usize = 0,
        cap: usize,

        const Self = @This();

        pub fn init(cap: usize) error{OutOfMemory}!Self {
            const raw = alloc(cap * @sizeOf(T)) orelse return error.OutOfMemory;
            return .{ .items = @ptrCast(@alignCast(raw)), .cap = cap };
        }

        pub fn deinit(self: *Self) void {
            free(@ptrCast(self.items));
        }

        pub fn push(self: *Self, value: T) error{OutOfMemory}!void {
            if (self.len == self.cap) {
                const cap = self.cap * 2;
                const raw = realloc(@ptrCast(self.items), cap * @sizeOf(T)) orelse return error.OutOfMemory;
                self.items = @ptrCast(@alignCast(raw));
                self.cap = cap;
            }
            self.items[self.len] = value;
            self.len += 1;
        }

        pub fn slice(self: *const Self) []T {
            return self.items[0..self.len];
        }
    };
}

/// Where the Elixir path would answer otherwise than a kernel can (an integer past 64 bits,
/// a raise, a form it doesn't read): the kernel answers `:fallback`, and the Elixir path
/// answers instead.
pub const Fallback = error{Fallback};

pub fn fallbackTerm() beam.term {
    return .{ .v = e.enif_make_atom(beam.context.env, "fallback") };
}

pub inline fn put(comptime T: type, out: []u8, at: usize, v: T) void {
    std.mem.writeInt(T, out[at..][0..@sizeOf(T)], v, .little);
}
