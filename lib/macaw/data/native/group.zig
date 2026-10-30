//! The exact sum by group (spec/04 §5, `Macaw.Data.Exact`): one view's readings of an int64
//! or float64 column summed by the dictionary code of its group, each group's state the
//! exact sum the Elixir path's fold builds, integer for integer: the integers' sum, and the
//! floats' signed mantissas summed by biased exponent.

const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const bufs = @import("buffers.zig");

const bytes = bufs.bytes;
const bit = bufs.bit;
const readI64 = bufs.readI64;
const Grow = bufs.Grow;
const KernelError = bufs.KernelError;
const fallbackTerm = bufs.fallbackTerm;

/// The value column's form.
const VForm = enum(u8) { int64 = 0, float64 = 1 };

/// One group: its code (`null`, a missing key), its first row in the view and its count of
/// rows, its count of readings (values present), the integers' sum, and whether a float
/// was added (`Exact`'s floats map, `nil` until one is); and its last float's exponent and
/// where that exponent's sum is held, as a run of readings mostly shares one. Each `i128`
/// is aligned to 8, as `enif_alloc` aligns its memory.
const Group = struct { code: ?u32, first: u32, rows: u32, readings: u32, ints: i128 align(8), floats: bool, exp: u32, at: u32 };

/// A float exponent's sum of a group: `key` the group's index times 2048 plus the biased
/// exponent.
const Mantissas = struct { key: u64, sum: i128 align(8) };

/// `Aggregate.group_chunk/5`'s groups for an exact sum, over `count` rows of the view from
/// `first`: the value column (`vform`, its data and validity) and, when `grouped`, the
/// dictionary codes, their validity and the dictionary's size. A list of the groups in
/// order of first appearance, each `{code | nil, first, rows, readings, ints, floats}`,
/// `floats` `nil` or a map of biased exponent to mantissa sum; `:fallback` where the
/// Elixir path raises (a code past the dictionary, a value not a finite float); `:dirty`
/// past `limit` entries, groups and their exponents' sums (0: no limit), for the call to
/// be made on a dirty scheduler.
pub fn group_sum(vform: u8, vdata: beam.term, vvalid: beam.term, grouped: bool, codes: beam.term, cvalid: beam.term, ncodes: usize, first: usize, count: usize, limit: usize) !beam.term {
    const vf = std.enums.fromInt(VForm, vform) orelse return error.UnknownForm;
    const v = try bytes(vdata);
    const vv = try bytes(vvalid);
    const c = try bytes(codes);
    const cv = try bytes(cvalid);
    const end = std.math.add(usize, first, count) catch return error.ShortBuffer;
    if (v.len < end * 8 or vv.len * 8 < end) return error.ShortBuffer;
    if (grouped and (c.len < end * 4 or cv.len * 8 < end)) return error.ShortBuffer;
    if (count > std.math.maxInt(u32) or ncodes > std.math.maxInt(u32)) return error.ShortBuffer;

    // A code's group index, `none` until it appears; the last slot is a missing key's.
    const none = std.math.maxInt(u32);
    const slots = if (grouped) ncodes + 1 else 1;
    const raw = e.enif_alloc(slots * @sizeOf(u32)) orelse return error.OutOfMemory;
    defer e.enif_free(raw);
    const slot: [*]u32 = @ptrCast(@alignCast(raw));
    @memset(slot[0..slots], none);

    var groups = try Grow(Group).init(16);
    defer groups.deinit();
    var table = try Table.init();
    defer table.deinit();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const r = first + i;
        var key: usize = 0;
        var code: ?u32 = null;
        if (grouped) {
            if (bit(cv, r)) {
                const cd = std.mem.readInt(u32, c[r * 4 ..][0..4], .little);
                if (cd >= ncodes) return fallbackTerm();
                code = cd;
                key = cd;
            } else key = ncodes;
        }
        var g = slot[key];
        if (g == none) {
            g = @intCast(groups.len);
            slot[key] = g;
            try groups.push(.{ .code = code, .first = @intCast(i), .rows = 0, .readings = 0, .ints = 0, .floats = false, .exp = none, .at = 0 });
        }
        const grp = &groups.items[g];
        grp.rows += 1;
        if (!bit(vv, r)) continue;
        grp.readings += 1;
        switch (vf) {
            .int64 => grp.ints += readI64(v, r),
            .float64 => {
                const w = std.mem.readInt(u64, v[r * 8 ..][0..8], .little);
                const exp: u32 = @intCast((w >> 52) & 0x7FF);
                if (exp == 0x7FF) return fallbackTerm();
                const frac: i128 = @intCast(w & 0xF_FFFF_FFFF_FFFF);
                const mag = if (exp == 0) frac else frac | (@as(i128, 1) << 52);
                const m = if (w >> 63 == 1) -mag else mag;
                grp.floats = true;
                if (exp == grp.exp) {
                    table.sums.items[grp.at].sum += m;
                } else {
                    grp.at = try table.add(@as(u64, g) * 2048 + exp, m);
                    grp.exp = exp;
                }
            },
        }
    }
    // The answer's terms, tens of nanoseconds each, are what a call past `limit` entries
    // spends past 1 ms: it is handed to a dirty scheduler before any is built.
    if (limit > 0 and groups.len + table.sums.len > limit) return .{ .v = e.enif_make_atom(beam.context.env, "dirty") };
    return build(groups.slice(), &table);
}

/// The groups' mantissa sums by `key`: an open-addressed index into a list of sums, in the
/// BEAM's memory, doubled at half full. Its cost follows the (group, exponent) pairs seen,
/// a handful a group, not the rows.
const Table = struct {
    index: [*]u32,
    cap: usize,
    sums: Grow(Mantissas),

    const empty = std.math.maxInt(u32);

    fn init() error{OutOfMemory}!Table {
        const cap: usize = 64;
        const raw = e.enif_alloc(cap * @sizeOf(u32)) orelse return error.OutOfMemory;
        const index: [*]u32 = @ptrCast(@alignCast(raw));
        @memset(index[0..cap], empty);
        return .{ .index = index, .cap = cap, .sums = try Grow(Mantissas).init(32) };
    }

    fn deinit(self: *Table) void {
        e.enif_free(@ptrCast(self.index));
        self.sums.deinit();
    }

    inline fn hash(key: u64, mask: usize) usize {
        return @as(usize, @truncate((key *% 0x9E37_79B9_7F4A_7C15) >> 32)) & mask;
    }

    /// `m` added to `key`'s sum; answers where that sum is held.
    fn add(self: *Table, key: u64, m: i128) error{OutOfMemory}!u32 {
        const mask = self.cap - 1;
        var h = hash(key, mask);
        while (true) : (h = (h + 1) & mask) {
            const at = self.index[h];
            if (at == empty) break;
            if (self.sums.items[at].key == key) {
                self.sums.items[at].sum += m;
                return at;
            }
        }
        const at: u32 = @intCast(self.sums.len);
        self.index[h] = at;
        try self.sums.push(.{ .key = key, .sum = m });
        if (self.sums.len * 2 > self.cap) try self.grow();
        return at;
    }

    fn grow(self: *Table) error{OutOfMemory}!void {
        const cap = self.cap * 2;
        const raw = e.enif_alloc(cap * @sizeOf(u32)) orelse return error.OutOfMemory;
        const index: [*]u32 = @ptrCast(@alignCast(raw));
        @memset(index[0..cap], empty);
        const mask = cap - 1;
        for (self.sums.slice(), 0..) |s, at| {
            var h = hash(s.key, mask);
            while (index[h] != empty) h = (h + 1) & mask;
            index[h] = @intCast(at);
        }
        e.enif_free(@ptrCast(self.index));
        self.index = index;
        self.cap = cap;
    }
};

/// The groups as terms, built from the end: each group's floats map made from its
/// exponents' sums, which the table holds grouped by nothing in particular, so they are
/// first sorted by key.
fn build(groups: []const Group, table: *Table) !beam.term {
    const env = beam.context.env;
    const sums = table.sums.slice();
    std.sort.pdq(Mantissas, sums, {}, lessByKey);

    var keys = try Grow(e.ErlNifTerm).init(64);
    defer keys.deinit();
    var values = try Grow(e.ErlNifTerm).init(64);
    defer values.deinit();

    // Each group's run of sums, from the end of the sorted list backwards.
    var at = sums.len;
    var out = e.enif_make_list(env, 0);
    var g = groups.len;
    while (g > 0) {
        g -= 1;
        const grp = groups[g];
        var floats = e.enif_make_atom(env, "nil");
        if (grp.floats) {
            keys.len = 0;
            values.len = 0;
            const base: u64 = @as(u64, g) * 2048;
            while (at > 0 and sums[at - 1].key >= base) {
                at -= 1;
                try keys.push(e.enif_make_uint(env, @intCast(sums[at].key - base)));
                try values.push(try integer(sums[at].sum));
            }
            if (e.enif_make_map_from_arrays(env, keys.items, values.items, keys.len, &floats) == 0) return error.UnknownForm;
        }
        const code = if (grp.code) |cd| e.enif_make_uint(env, cd) else e.enif_make_atom(env, "nil");
        var tuple = [6]e.ErlNifTerm{
            code,
            e.enif_make_uint(env, grp.first),
            e.enif_make_uint(env, grp.rows),
            e.enif_make_uint(env, grp.readings),
            try integer(grp.ints),
            floats,
        };
        out = e.enif_make_list_cell(env, e.enif_make_tuple_from_array(env, &tuple, 6), out);
    }
    return .{ .v = out };
}

fn lessByKey(_: void, a: Mantissas, b: Mantissas) bool {
    return a.key < b.key;
}

/// An integer term for an `i128`: a small one directly; one past int64 as the bignum its
/// external term format spells (`SMALL_BIG_EXT`: sign, then little-endian bytes).
fn integer(n: i128) error{OutOfMemory}!e.ErlNifTerm {
    const env = beam.context.env;
    if (n >= std.math.minInt(i64) and n <= std.math.maxInt(i64)) return e.enif_make_int64(env, @intCast(n));
    var buf: [4 + 16]u8 = undefined;
    buf[0] = 131;
    buf[1] = 110;
    buf[3] = if (n < 0) 1 else 0;
    var mag: u128 = @abs(n);
    var len: usize = 0;
    while (mag != 0) : (mag >>= 8) {
        buf[4 + len] = @truncate(mag);
        len += 1;
    }
    buf[2] = @intCast(len);
    var term: e.ErlNifTerm = undefined;
    if (e.enif_binary_to_term(env, &buf, 4 + len, &term, 0) == 0) return error.OutOfMemory;
    return term;
}
