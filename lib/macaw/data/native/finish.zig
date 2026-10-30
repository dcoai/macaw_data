//! The finishes over packed pieces (spec/04 §4.5.4): m4's pixel columns and lttb's
//! selection, read from the merged partial's `Ladder.Packed` pieces.

const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const bufs = @import("buffers.zig");
const packing = @import("ladder.zig");

const bytes = bufs.bytes;
const Grow = bufs.Grow;
const KernelError = bufs.KernelError;
const Fallback = bufs.Fallback;
const fallbackTerm = bufs.fallbackTerm;
const packed_header = packing.packed_header;
const packed_head = packing.packed_head;
const packed_bucket = packing.packed_bucket;

/// A number as the BEAM holds it: an integer, exact, or a float. Its arithmetic is Erlang's:
/// two integers stay an exact integer (here within int64); otherwise the integer is first
/// converted to the nearest float; `/` is a float's division. Where Erlang would go past
/// what this holds (an integer past int64), or raise (a result that is not a finite float, a
/// division by zero), it is `error.Fallback`, and the Elixir path answers.
const Num = union(enum) {
    int: i64,
    float: f64,

    inline fn of(comptime T: type, v: T) Num {
        return if (T == i64) .{ .int = v } else .{ .float = v };
    }

    /// The nearest float, as Erlang converts an integer within int64: a fixnum by a C cast,
    /// a one-digit bignum likewise, each rounded to nearest, ties to even.
    inline fn toFloat(self: Num) Fallback!f64 {
        return switch (self) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
        };
    }

    fn finite(f: f64) Fallback!Num {
        if (!std.math.isFinite(f)) return error.Fallback;
        return .{ .float = f };
    }

    fn add(a: Num, b: Num) Fallback!Num {
        if (a == .int and b == .int) {
            const r = @addWithOverflow(a.int, b.int);
            if (r[1] != 0) return error.Fallback;
            return .{ .int = r[0] };
        }
        return finite(try a.toFloat() + try b.toFloat());
    }

    fn sub(a: Num, b: Num) Fallback!Num {
        if (a == .int and b == .int) {
            const r = @subWithOverflow(a.int, b.int);
            if (r[1] != 0) return error.Fallback;
            return .{ .int = r[0] };
        }
        return finite(try a.toFloat() - try b.toFloat());
    }

    fn mul(a: Num, b: Num) Fallback!Num {
        if (a == .int and b == .int) {
            const r = @mulWithOverflow(a.int, b.int);
            if (r[1] != 0) return error.Fallback;
            return .{ .int = r[0] };
        }
        return finite(try a.toFloat() * try b.toFloat());
    }

    /// `/`: both converted to floats; a zero divisor raises in Erlang.
    fn div(a: Num, b: Num) Fallback!f64 {
        const d = try b.toFloat();
        if (d == 0) return error.Fallback;
        return (try finite(try a.toFloat() / d)).float;
    }

    /// `floor/1` of a float, as an integer that fits; Erlang's floor answers any integer.
    fn floorOf(f: f64) Fallback!i64 {
        const q = @floor(f);
        if (!(q >= -9.223372036854775808e18 and q < 9.223372036854775808e18)) return error.Fallback;
        return @intFromFloat(q);
    }

    /// `a > b`, exactly, as Erlang compares numbers of either type.
    fn gt(a: Num, b: Num) Fallback!bool {
        if (a == .int and b == .int) return a.int > b.int;
        if (a == .float and b == .float) return a.float > b.float;
        // An integer and a float: exact while the integer is a float exactly.
        const limit: i64 = 1 << 53;
        const i = if (a == .int) a.int else b.int;
        if (i > limit or i < -limit) return error.Fallback;
        return (try a.toFloat()) > (try b.toFloat());
    }
};

/// A piece of a merged partial: its view and its packed bytes, read once for their counts.
const Piece = struct { v: u32, bytes: []const u8, nseg: usize, buckets: usize };

/// The pieces of `{v, binary}` terms, checked: each `Ladder.Packed`'s packed form, its size
/// what its heads say. A piece kept as a term (mixed or past int64), or two pieces whose
/// points are of different types, is the Elixir path's. Answers the points' types, `null`
/// with no bucket in any piece.
fn readPieces(list: beam.term, out: *Grow(Piece)) (KernelError || Fallback || error{OutOfMemory})!?[2]u8 {
    const env = beam.context.env;
    var types: ?[2]u8 = null;
    var cell = list.v;
    var head: e.ErlNifTerm = undefined;
    var tail: e.ErlNifTerm = undefined;
    while (e.enif_get_list_cell(env, cell, &head, &tail) != 0) : (cell = tail) {
        var arity: c_int = 0;
        var items: [*c]const e.ErlNifTerm = undefined;
        if (e.enif_get_tuple(env, head, &arity, &items) == 0 or arity != 2) return error.NotAPiece;
        var v: c_uint = 0;
        if (e.enif_get_uint(env, items[0], &v) == 0) return error.NotAPiece;
        const b = try bytes(.{ .v = items[1] });
        if (b.len < packed_header) return error.ShortBuffer;
        if (b[0] == 2) return error.Fallback;
        if (b[0] != 1 or b[1] > 1 or b[2] > 1) return error.UnknownForm;
        const nseg: usize = std.mem.readInt(u32, b[4..8], .little);
        const body = std.math.add(usize, packed_header, std.math.mul(usize, nseg, packed_head) catch return error.ShortBuffer) catch return error.ShortBuffer;
        if (b.len < body) return error.ShortBuffer;
        var n: usize = 0;
        for (0..nseg) |h| {
            const at = packed_header + h * packed_head;
            if (b[at] == 1) n += std.mem.readInt(u32, b[at + 4 ..][0..4], .little) else if (b[at] != 0) return error.UnknownForm;
        }
        if (b.len != body + n * packed_bucket) return error.ShortBuffer;
        if (n > 0) {
            const t = [2]u8{ b[1], b[2] };
            if (types) |held| {
                if (held[0] != t[0] or held[1] != t[1]) return error.Fallback;
            } else types = t;
        }
        try out.push(.{ .v = @intCast(v), .bytes = b, .nseg = nseg, .buckets = n });
    }
    return types;
}

/// The buckets and segments the pieces hold, at least 1 each: what a finish's arrays hold
/// at most, allocated once.
fn sizes(pieces: []const Piece) [2]usize {
    var b: usize = 1;
    var s: usize = 1;
    for (pieces) |pc| {
        b += pc.buckets;
        s += pc.nseg;
    }
    return .{ b, s };
}

/// The finishes for points whose `s` is `S` and `y` is `Y`.
fn Finish(comptime S: type, comptime Y: type) type {
    return struct {
        /// A point with its ref, `view << 32 | row`: refs order as `{view, row}` does.
        const P = struct { ref: u64, s: S, y: Y };
        const B = struct { b: i64, first: P, last: P, low: P, high: P };
        const Seg = struct { gap: bool, ref: u64, start: usize, len: usize };

        inline fn num(comptime T: type, b: []const u8, at: usize) T {
            return if (T == i64) std.mem.readInt(i64, b[at..][0..8], .little) else @bitCast(std.mem.readInt(u64, b[at..][0..8], .little));
        }

        fn bucketAt(pc: Piece, at: usize) B {
            var ps: [4]P = undefined;
            for (0..4) |j| {
                const p = at + 8 + j * 20;
                const row = std.mem.readInt(u32, pc.bytes[p..][0..4], .little);
                ps[j] = .{ .ref = (@as(u64, pc.v) << 32) | row, .s = num(S, pc.bytes, p + 4), .y = num(Y, pc.bytes, p + 12) };
            }
            return .{ .b = std.mem.readInt(i64, pc.bytes[at..][0..8], .little), .first = ps[0], .last = ps[1], .low = ps[2], .high = ps[3] };
        }

        /// `Ladder.summary/2` over refs: the first and last by ref, the least and greatest by
        /// y, the earlier ref on a tie.
        fn merge(a: B, b: B) B {
            return .{
                .b = a.b,
                .first = if (a.first.ref <= b.first.ref) a.first else b.first,
                .last = if (a.last.ref >= b.last.ref) a.last else b.last,
                .low = if (a.low.y < b.low.y or (a.low.y == b.low.y and a.low.ref <= b.low.ref)) a.low else b.low,
                .high = if (a.high.y > b.high.y or (a.high.y == b.high.y and a.high.ref <= b.high.ref)) a.high else b.high,
            };
        }

        fn lessByBucket(_: void, a: B, b: B) bool {
            return a.b < b.b;
        }

        /// The merged partial read once, as `Ladder.runs/1` reads it: a gap ending one piece
        /// and one starting the next are one gap, the first; a run ending one and one
        /// starting the next are one run, the bucket they share merged; a run whose buckets
        /// fell out of order across pieces is made ascending, each bucket once.
        fn join(pieces: []const Piece, buckets: *Grow(B), segs: *Grow(Seg)) error{OutOfMemory}!void {
            var open = false;
            var ordered = true;
            var start: usize = 0;
            for (pieces) |pc| {
                var at = packed_header + pc.nseg * packed_head;
                for (0..pc.nseg) |h| {
                    const hd = packed_header + h * packed_head;
                    const value = std.mem.readInt(u32, pc.bytes[hd + 4 ..][0..4], .little);
                    if (pc.bytes[hd] == 0) {
                        if (open) {
                            try closeRun(buckets, segs, start, ordered);
                            open = false;
                        }
                        const n = segs.len;
                        if (n == 0 or !segs.items[n - 1].gap)
                            try segs.push(.{ .gap = true, .ref = (@as(u64, pc.v) << 32) | value, .start = 0, .len = 0 });
                        continue;
                    }
                    if (!open) {
                        open = true;
                        ordered = true;
                        start = buckets.len;
                    }
                    for (0..value) |_| {
                        const bk = bucketAt(pc, at);
                        at += packed_bucket;
                        const n = buckets.len;
                        if (n > start and buckets.items[n - 1].b == bk.b) {
                            buckets.items[n - 1] = merge(buckets.items[n - 1], bk);
                        } else {
                            if (n > start and !(bk.b > buckets.items[n - 1].b)) ordered = false;
                            try buckets.push(bk);
                        }
                    }
                }
            }
            if (open) try closeRun(buckets, segs, start, ordered);
        }

        fn closeRun(buckets: *Grow(B), segs: *Grow(Seg), start: usize, ordered: bool) error{OutOfMemory}!void {
            if (!ordered) {
                const held = buckets.items[start..buckets.len];
                std.sort.pdq(B, held, {}, lessByBucket);
                var w: usize = 0;
                for (held[1..]) |bk| {
                    if (bk.b == held[w].b) {
                        held[w] = merge(held[w], bk);
                    } else {
                        w += 1;
                        held[w] = bk;
                    }
                }
                buckets.len = start + w + 1;
            }
            try segs.push(.{ .gap = false, .ref = 0, .start = start, .len = buckets.len - start });
        }

        // -- m4 ---------------------------------------------------------------------------

        const Columns = struct { k: i64, lo: Num, hi: Num, extent: bool, width: i64 };

        /// `M4`'s `column_of/3`: the pixel column bucket `b`'s start lies in, `floor((b *
        /// 2^k - lo) / (hi - lo) * width)` clamped to the columns, operation for operation;
        /// 0 for every bucket where the extent is a point or none.
        fn column(b: i64, at: Columns) Fallback!i64 {
            if (!at.extent) return 0;
            const start = if (at.k >= 0) blk: {
                if (at.k > 62) return error.Fallback;
                break :blk try Num.mul(.{ .int = b }, .{ .int = @as(i64, 1) << @intCast(at.k) });
            } else blk: {
                if (at.k < -1074) return error.Fallback;
                break :blk try Num.mul(.{ .int = b }, .{ .float = std.math.ldexp(@as(f64, 1.0), @intCast(at.k)) });
            };
            const q = try Num.mul(.{ .float = try Num.div(try start.sub(at.lo), try at.hi.sub(at.lo)) }, .{ .int = at.width });
            const f = q.float;
            if (f < 0) return 0;
            if (f >= @as(f64, @floatFromInt(at.width))) return at.width - 1;
            return Num.floorOf(f);
        }

        /// Each run's buckets folded into their pixel columns in one pass, each column's
        /// first, least, greatest and last refs kept, and each gap's ref, as `M4.finish/3`.
        fn m4(pieces: []const Piece, at: Columns) (Fallback || error{OutOfMemory})!beam.term {
            const size = sizes(pieces);
            var buckets = try Grow(B).init(size[0]);
            defer buckets.deinit();
            var segs = try Grow(Seg).init(size[1]);
            defer segs.deinit();
            try join(pieces, &buckets, &segs);

            var refs = try Grow(u64).init(256);
            defer refs.deinit();
            for (segs.slice()) |seg| {
                if (seg.gap) {
                    try refs.push(seg.ref);
                    continue;
                }
                const run = buckets.items[seg.start .. seg.start + seg.len];
                var held = run[0];
                var c = try column(held.b, at);
                for (run[1..]) |bk| {
                    const next = try column(bk.b, at);
                    if (next == c) {
                        held = merge(held, bk);
                    } else {
                        try keepColumn(&refs, held);
                        held = bk;
                        c = next;
                    }
                }
                try keepColumn(&refs, held);
            }
            return refList(refs.slice());
        }

        fn keepColumn(refs: *Grow(u64), held: B) error{OutOfMemory}!void {
            try refs.push(held.first.ref);
            try refs.push(held.low.ref);
            try refs.push(held.high.ref);
            try refs.push(held.last.ref);
        }

        // -- lttb ---------------------------------------------------------------------------

        /// A candidate: a gap's first row, or a point.
        const C = struct { gap: bool, ref: u64, s: S, y: Y };

        fn lessByRef(_: void, a: C, b: C) bool {
            return a.ref < b.ref;
        }

        /// `Lttb.candidates/1` for every segment: a gap as itself; a run's first and last
        /// points and each bucket's least and greatest, each once, in input order.
        fn candidates(segs: []const Seg, buckets: []const B, out: *Grow(C)) error{OutOfMemory}!void {
            for (segs) |seg| {
                if (seg.gap) {
                    try out.push(.{ .gap = true, .ref = seg.ref, .s = 0, .y = 0 });
                    continue;
                }
                const run = buckets[seg.start .. seg.start + seg.len];
                const from = out.len;
                var first = run[0].first;
                var last = run[0].last;
                for (run) |bk| {
                    if (bk.first.ref < first.ref) first = bk.first;
                    if (bk.last.ref > last.ref) last = bk.last;
                    try out.push(point(bk.low));
                    try out.push(point(bk.high));
                }
                try out.push(point(first));
                try out.push(point(last));
                const held = out.items[from..out.len];
                std.sort.pdq(C, held, {}, lessByRef);
                var w: usize = 0;
                for (held[1..]) |c| {
                    if (c.ref != held[w].ref) {
                        w += 1;
                        held[w] = c;
                    }
                }
                out.len = from + w + 1;
            }
        }

        inline fn point(p: P) C {
            return .{ .gap = false, .ref = p.ref, .s = p.s, .y = p.y };
        }

        /// `Reduce.lttb/3` over the candidates, `n` the rows kept, accessor `{s, y}`: the
        /// refs of the candidates it keeps, in order.
        fn lttb(pieces: []const Piece, n: i64) (Fallback || error{OutOfMemory})!beam.term {
            const size = sizes(pieces);
            var buckets = try Grow(B).init(size[0]);
            defer buckets.deinit();
            var segs = try Grow(Seg).init(size[1]);
            defer segs.deinit();
            try join(pieces, &buckets, &segs);

            var cands = try Grow(C).init(2 * size[0] + 2 * size[1]);
            defer cands.deinit();
            try candidates(segs.slice(), buckets.slice(), &cands);
            const cs = cands.slice();

            var refs = try Grow(u64).init(@max(1, @min(cs.len, @as(usize, @intCast(n)) + 16)));
            defer refs.deinit();

            if (cs.len <= n) {
                for (cs) |c| try refs.push(c.ref);
                return refList(refs.slice());
            }

            // The defined points, counted over every run, a run of gaps its first only.
            var defined: i64 = 0;
            for (cs) |c| {
                if (!c.gap) defined += 1;
            }

            var i: usize = 0;
            while (i < cs.len) {
                if (cs[i].gap) {
                    try refs.push(cs[i].ref);
                    i += 1;
                    while (i < cs.len and cs[i].gap) i += 1;
                    continue;
                }
                var j = i;
                while (j < cs.len and !cs[j].gap) j += 1;
                try segment(cs[i..j], n, defined, &refs);
                i = j;
            }
            return refList(refs.slice());
        }

        /// One run's share: `max(min(len, 2), floor(n * len / defined))` points, all of
        /// them, its two ends, or the canonical algorithm's.
        fn segment(pts: []const C, n: i64, defined: i64, refs: *Grow(u64)) (Fallback || error{OutOfMemory})!void {
            const len: i64 = @intCast(pts.len);
            const share = try Num.floorOf(try Num.div(try Num.mul(.{ .int = n }, .{ .int = len }), .{ .int = defined }));
            const budget = @max(@min(len, 2), share);
            if (budget >= len) {
                for (pts) |p| try refs.push(p.ref);
            } else if (budget == 2) {
                try refs.push(pts[0].ref);
                try refs.push(pts[pts.len - 1].ref);
            } else {
                try selectRun(pts, len, budget, refs);
            }
        }

        inline fn sOf(p: C) Num {
            return Num.of(S, p.s);
        }

        inline fn yOf(p: C) Num {
            return Num.of(Y, p.y);
        }

        /// `Reduce.lttb_run/3`: the ends kept, the interior in `count - 2` buckets of
        /// `every` points, each bucket's point making the largest triangle with the point
        /// kept before it and the next bucket's mean point, earliest on a tie.
        fn selectRun(pts: []const C, len: i64, count: i64, refs: *Grow(u64)) (Fallback || error{OutOfMemory})!void {
            const every = Num{ .float = try Num.div(.{ .int = len - 2 }, .{ .int = count - 2 }) };
            try refs.push(pts[0].ref);
            var a: usize = 0;
            var i: i64 = 0;
            while (i < count - 2) : (i += 1) {
                const from: usize = @intCast((try Num.floorOf((try Num.mul(.{ .int = i }, every)).float)) + 1);
                const to: usize = @intCast((try Num.floorOf((try Num.mul(.{ .int = i + 1 }, every)).float)) + 1);
                const next_to: usize = @intCast(@min((try Num.floorOf((try Num.mul(.{ .int = i + 2 }, every)).float)) + 1, len));

                // The mean point of [to, next_to), summed from the integer 0.
                var sx = Num{ .int = 0 };
                var sy = Num{ .int = 0 };
                if (next_to > pts.len or to > next_to) return error.Fallback;
                for (pts[to..next_to]) |p| {
                    sx = try sx.add(sOf(p));
                    sy = try sy.add(yOf(p));
                }
                const k = Num{ .int = @intCast(next_to - to) };
                const cx = Num{ .float = try sx.div(k) };
                const cy = Num{ .float = try sy.div(k) };

                const ax = sOf(pts[a]);
                const ay = yOf(pts[a]);
                var best = from;
                var best_area = Num{ .int = -1 };
                if (to > pts.len or from > to) return error.Fallback;
                for (pts[from..to], from..) |p, j| {
                    // abs((ax - cx) * (y - ay) - (ax - x) * (cy - ay))
                    const left = try (try ax.sub(cx)).mul(try yOf(p).sub(ay));
                    const right = try (try ax.sub(sOf(p))).mul(try cy.sub(ay));
                    const area = Num{ .float = @abs((try left.sub(right)).float) };
                    if (try area.gt(best_area)) {
                        best = j;
                        best_area = area;
                    }
                }
                try refs.push(pts[best].ref);
                a = best;
            }
            try refs.push(pts[pts.len - 1].ref);
        }
    };
}

/// The refs as `[{view, row}]`, built from the end.
fn refList(refs: []const u64) beam.term {
    const env = beam.context.env;
    var out = e.enif_make_list(env, 0);
    var i = refs.len;
    while (i > 0) {
        i -= 1;
        var pair = [2]e.ErlNifTerm{ e.enif_make_uint(env, @intCast(refs[i] >> 32)), e.enif_make_uint(env, @intCast(refs[i] & 0xFFFF_FFFF)) };
        out = e.enif_make_list_cell(env, e.enif_make_tuple_from_array(env, &pair, 2), out);
    }
    return .{ .v = out };
}

/// A number term as a `Num`: an integer within int64 or a float; any other is `null`.
fn numOf(term: beam.term) ?Num {
    var i: i64 = 0;
    if (e.enif_get_int64(beam.context.env, term.v, &i) != 0) return .{ .int = i };
    var f: f64 = 0;
    if (e.enif_get_double(beam.context.env, term.v, &f) != 0) return .{ .float = f };
    return null;
}


/// The pieces of a merged partial, read and checked, and their points' types; with no
/// bucket in any piece, the gaps alone, typed as integers.
fn piecesOf(pieces: beam.term, list: *Grow(Piece)) (KernelError || Fallback || error{OutOfMemory})![2]u8 {
    return (try readPieces(pieces, list)) orelse .{ 0, 0 };
}

/// `M4.finish/3`'s refs from the merged partial's pieces (`[{view, binary}]`) at level `k`:
/// each run's buckets folded into the pixel column their start lies in, over `[lo, hi]` in
/// `width` columns (`extent` 0: every bucket column 0), each column's first, least,
/// greatest and last rows, and each gap's first; `:fallback` where the Elixir path would
/// answer otherwise than a kernel can (a piece kept as a term, an integer past 64 bits, a
/// raise), so it answers.
pub fn m4_finish(pieces: beam.term, k: i64, extent: u8, lo: beam.term, hi: beam.term, width: i64) !beam.term {
    var list = try Grow(Piece).init(16);
    defer list.deinit();
    const types = piecesOf(pieces, &list) catch |err| switch (err) {
        error.Fallback => return fallbackTerm(),
        else => |other| return other,
    };
    const at_lo = numOf(lo) orelse return fallbackTerm();
    const at_hi = numOf(hi) orelse return fallbackTerm();
    switch (types[0] * 2 + types[1]) {
        inline 0...3 => |t| {
            const F = Finish(if (t / 2 == 0) i64 else f64, if (t % 2 == 0) i64 else f64);
            const at = F.Columns{ .k = k, .lo = at_lo, .hi = at_hi, .extent = extent == 1, .width = width };
            return F.m4(list.slice(), at) catch |err| switch (err) {
                error.Fallback => fallbackTerm(),
                error.OutOfMemory => error.OutOfMemory,
            };
        },
        else => return error.UnknownForm,
    }
}

/// `Lttb.finish/3`'s refs from the merged partial's pieces: the candidates (each run's
/// first and last, each bucket's least and greatest, each gap), then `Reduce.lttb/3` to `n`
/// over them, operation for operation, the refs it keeps in order; `:fallback` as
/// `m4_finish/6`.
pub fn lttb_finish(pieces: beam.term, n: i64) !beam.term {
    var list = try Grow(Piece).init(16);
    defer list.deinit();
    const types = piecesOf(pieces, &list) catch |err| switch (err) {
        error.Fallback => return fallbackTerm(),
        else => |other| return other,
    };
    if (n < 3) return error.UnknownForm;
    switch (types[0] * 2 + types[1]) {
        inline 0...3 => |t| {
            const F = Finish(if (t / 2 == 0) i64 else f64, if (t % 2 == 0) i64 else f64);
            return F.lttb(list.slice(), n) catch |err| switch (err) {
                error.Fallback => fallbackTerm(),
                error.OutOfMemory => error.OutOfMemory,
            };
        },
        else => return error.UnknownForm,
    }
}
