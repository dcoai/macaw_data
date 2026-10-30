//! `filter`'s mask and the gather of the rows it keeps (spec/04 §4.1.1): a view's rows
//! tested from a column's packed buffers in place, and fixed-width slots and bitmap bits
//! copied at a list of indexes, as `Column.gather/2` copies them.

const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const bufs = @import("buffers.zig");

const bytes = bufs.bytes;
const bit = bufs.bit;
const readI64 = bufs.readI64;
const readF64 = bufs.readF64;
const Grow = bufs.Grow;
const fallbackTerm = bufs.fallbackTerm;

/// How a row is tested: `constant`, a present row passes as `present` says (the test's
/// answer for every reading of the column's kind, decided once in Elixir); `int64` and
/// `float64`, the reading compared with a number; `codes`, a dictionary code's answer
/// read from a bitmap over the dictionary. A missing row passes as `missing` says, in
/// every mode.
const Mode = enum(u8) { constant = 0, int64 = 1, float64 = 2, codes = 3 };

/// The test of a reading against the value, as Erlang compares numbers.
const Test = enum(u8) { eq = 0, ne = 1, lt = 2, lte = 3, gt = 4, gte = 5 };

/// The value a number is compared with: an integer within int64 or a float.
const Value = union(enum) { int: i64, float: f64 };

/// `Filter.chunk/3`'s selection of `count` rows of the view from `first`: `:all`, `:none`,
/// `{:run, a, n}` where the rows kept are consecutive, else `{:rows, indexes}`, ascending;
/// `:fallback` where a float in the column is not finite (the Elixir path raises reading
/// it). `data` is the values (int64 or float64) or the codes (`codes`), `pass` the
/// dictionary's bitmap of passing codes and `ncodes` its size.
pub fn filter_mask(mode: u8, data: beam.term, validity: beam.term, first: usize, count: usize, cmp: u8, value: beam.term, present: bool, missing: bool, pass: beam.term, ncodes: usize) !beam.term {
    const md = std.enums.fromInt(Mode, mode) orelse return error.UnknownForm;
    const t = std.enums.fromInt(Test, cmp) orelse return error.UnknownForm;
    const d = try bytes(data);
    const v = try bytes(validity);
    const p = try bytes(pass);
    const end = std.math.add(usize, first, count) catch return error.ShortBuffer;
    if (v.len * 8 < end) return error.ShortBuffer;
    if (count > std.math.maxInt(u32)) return error.ShortBuffer;
    switch (md) {
        .constant => {},
        .int64, .float64 => if (d.len < end * 8) return error.ShortBuffer,
        .codes => if (d.len < end * 4 or p.len * 8 < ncodes) return error.ShortBuffer,
    }
    const x = valueOf(value) orelse if (md == .int64 or md == .float64) return error.UnknownForm else Value{ .int = 0 };

    var kept = try Grow(u32).init(256);
    defer kept.deinit();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const r = first + i;
        const passes = if (!bit(v, r)) missing else switch (md) {
            .constant => present,
            .int64 => cmpInt(readI64(d, r), x).holds(t),
            .float64 => blk: {
                const f = readF64(d, r);
                if (!std.math.isFinite(f)) return fallbackTerm();
                break :blk cmpFloat(f, x).holds(t);
            },
            .codes => blk: {
                const c = std.mem.readInt(u32, d[r * 4 ..][0..4], .little);
                if (c >= ncodes) return fallbackTerm();
                break :blk bit(p, c);
            },
        };
        if (passes) try kept.push(@intCast(i));
    }
    return selection(kept.slice(), count);
}

fn valueOf(term: beam.term) ?Value {
    var i: i64 = 0;
    if (e.enif_get_int64(beam.context.env, term.v, &i) != 0) return .{ .int = i };
    var f: f64 = 0;
    if (e.enif_get_double(beam.context.env, term.v, &f) != 0) return .{ .float = f };
    return null;
}

/// An ordering of a reading against the value.
const Order = enum {
    lt,
    eq,
    gt,

    fn holds(o: Order, t: Test) bool {
        return switch (t) {
            .eq => o == .eq,
            .ne => o != .eq,
            .lt => o == .lt,
            .lte => o != .gt,
            .gt => o == .gt,
            .gte => o != .lt,
        };
    }

    fn flip(o: Order) Order {
        return switch (o) {
            .lt => .gt,
            .eq => .eq,
            .gt => .lt,
        };
    }
};

fn order(comptime T: type, a: T, b: T) Order {
    return if (a < b) .lt else if (a > b) .gt else .eq;
}

/// An integer against a number, exactly, as Erlang compares an integer with a float (the
/// less precise converted to the other, which for every pair answers the exact order).
fn cmpInt(a: i64, x: Value) Order {
    return switch (x) {
        .int => |b| order(i64, a, b),
        .float => |f| intFloat(a, f),
    };
}

fn cmpFloat(a: f64, x: Value) Order {
    return switch (x) {
        .float => |b| order(f64, a, b),
        .int => |b| intFloat(b, a).flip(),
    };
}

/// `i` against a finite float `f`, exactly: against `f`'s floor, then its fraction.
fn intFloat(i: i64, f: f64) Order {
    if (f >= 9.223372036854775808e18) return .lt;
    if (f < -9.223372036854775808e18) return .gt;
    const fl = @floor(f);
    const t: i64 = @intFromFloat(fl);
    if (i < t) return .lt;
    if (i > t) return .gt;
    return if (f > fl) .lt else .eq;
}

/// The rows kept as `Filter`'s `selected/2` answers them, built from the end.
fn selection(kept: []const u32, count: usize) beam.term {
    const env = beam.context.env;
    if (kept.len == 0) return .{ .v = e.enif_make_atom(env, "none") };
    if (kept.len == count) return .{ .v = e.enif_make_atom(env, "all") };
    if (kept[kept.len - 1] == kept[0] + kept.len - 1) {
        var run = [3]e.ErlNifTerm{ e.enif_make_atom(env, "run"), e.enif_make_uint(env, kept[0]), e.enif_make_uint(env, @intCast(kept.len)) };
        return .{ .v = e.enif_make_tuple_from_array(env, &run, 3) };
    }
    var list = e.enif_make_list(env, 0);
    var i = kept.len;
    while (i > 0) {
        i -= 1;
        list = e.enif_make_list_cell(env, e.enif_make_uint(env, kept[i]), list);
    }
    var rows = [2]e.ErlNifTerm{ e.enif_make_atom(env, "rows"), list };
    return .{ .v = e.enif_make_tuple_from_array(env, &rows, 2) };
}

// -- the gather (`Column.gather/2`) ----------------------------------------------------------

/// The indexes of a list, each checked against `limit` slots.
fn indexesOf(list: beam.term, limit: usize, out: *Grow(u32)) !void {
    const env = beam.context.env;
    var cell = list.v;
    var head: e.ErlNifTerm = undefined;
    var tail: e.ErlNifTerm = undefined;
    while (e.enif_get_list_cell(env, cell, &head, &tail) != 0) : (cell = tail) {
        var i: c_uint = 0;
        if (e.enif_get_uint(env, head, &i) == 0 or i >= limit) return error.ShortBuffer;
        try out.push(@intCast(i));
    }
    if (e.enif_is_empty_list(env, cell) == 0) return error.NotAPiece;
}

/// The `width`-byte slots of `data` at `indexes`, in order, as `Column`'s `take/3`.
pub fn take(data: beam.term, width: usize, indexes: beam.term) !beam.term {
    const d = try bytes(data);
    if (width == 0) return error.UnknownForm;
    var at = try Grow(u32).init(256);
    defer at.deinit();
    try indexesOf(indexes, d.len / width, &at);
    const env = beam.context.env;
    var term: e.ErlNifTerm = undefined;
    const size = at.len * width;
    const raw = e.enif_make_new_binary(env, size, &term) orelse return error.OutOfMemory;
    const out = raw[0..size];
    var o: usize = 0;
    for (at.slice()) |i| {
        @memcpy(out[o .. o + width], d[i * width ..][0..width]);
        o += width;
    }
    return .{ .v = term };
}

/// The bits of an LSB-first bitmap at `indexes`, in order, packed LSB-first with zero
/// padding, as `Bitmap.take/3`.
pub fn take_bits(bitmap: beam.term, indexes: beam.term) !beam.term {
    const b = try bytes(bitmap);
    var at = try Grow(u32).init(256);
    defer at.deinit();
    try indexesOf(indexes, b.len * 8, &at);
    const env = beam.context.env;
    var term: e.ErlNifTerm = undefined;
    const size = (at.len + 7) / 8;
    const raw = e.enif_make_new_binary(env, size, &term) orelse return error.OutOfMemory;
    const out = raw[0..size];
    @memset(out, 0);
    for (at.slice(), 0..) |i, j| {
        if (bit(b, i)) out[j >> 3] |= @as(u8, 1) << @as(u3, @intCast(j & 7));
    }
    return .{ .v = term };
}
