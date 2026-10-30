//! macaw_data's native kernels (spec/04 §1.7): each reads a column's packed Arrow
//! buffers (spec/01 §1.1) in place and answers exactly what the step's Elixir path
//! answers. Built ReleaseSafe in every environment, so a bounds or overflow fault panics
//! loudly, with its message, rather than reading past a buffer. Floating point is in
//! Zig's strict mode, its default: no operation is reordered, contracted into a fused
//! multiply-add or assumed finite, so an expression rounds as the Elixir path's does.

const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");

/// The kernels' interface version, read once at start (`Macaw.Data.Native`): the library
/// answers only when it is the version the Elixir side was compiled against.
pub fn abi() u32 {
    return 2;
}

// -- buffers --------------------------------------------------------------------------------

const KernelError = error{ NotABinary, ShortBuffer, UnknownForm };

/// A binary's bytes, in place: the term's own data, never copied.
fn bytes(term: beam.term) KernelError![]const u8 {
    var bin: e.ErlNifBinary = undefined;
    if (e.enif_inspect_binary(beam.context.env, term.v, &bin) == 0) return error.NotABinary;
    if (bin.size == 0) return &[_]u8{};
    return bin.data[0..bin.size];
}

/// Bit `i` of an LSB-first bitmap (Arrow's): bit `i % 8` of byte `i / 8`.
inline fn bit(bitmap: []const u8, i: usize) bool {
    return (bitmap[i >> 3] >> @as(u3, @intCast(i & 7))) & 1 == 1;
}

inline fn readI64(data: []const u8, i: usize) i64 {
    return std.mem.readInt(i64, data[i * 8 ..][0..8], .little);
}

inline fn readF64(data: []const u8, i: usize) f64 {
    return @bitCast(std.mem.readInt(u64, data[i * 8 ..][0..8], .little));
}

inline fn readI32(data: []const u8, i: usize) i32 {
    return std.mem.readInt(i32, data[i * 4 ..][0..4], .little);
}

/// A growing list of `T` in the BEAM's memory, doubled as it fills, so its cost follows
/// what it holds, not the rows read. Raw `enif_realloc`: the `std.mem.Allocator` interface
/// fills new memory with 0xAA in a safe build, a write per byte that would cost more than
/// a walk.
fn Grow(comptime T: type) type {
    return struct {
        items: [*]T,
        len: usize = 0,
        cap: usize,

        const Self = @This();

        fn init(cap: usize) error{OutOfMemory}!Self {
            const raw = e.enif_alloc(cap * @sizeOf(T)) orelse return error.OutOfMemory;
            return .{ .items = @ptrCast(@alignCast(raw)), .cap = cap };
        }

        fn deinit(self: *Self) void {
            e.enif_free(@ptrCast(self.items));
        }

        fn push(self: *Self, value: T) error{OutOfMemory}!void {
            if (self.len == self.cap) {
                const cap = self.cap * 2;
                const raw = e.enif_realloc(@ptrCast(self.items), cap * @sizeOf(T)) orelse return error.OutOfMemory;
                self.items = @ptrCast(@alignCast(raw));
                self.cap = cap;
            }
            self.items[self.len] = value;
            self.len += 1;
        }

        fn slice(self: *const Self) []T {
            return self.items[0..self.len];
        }
    };
}

// -- the ladder partial (spec/04 §4.5.1) ------------------------------------------------------

/// The x column's form: int64, float64, timestamp[us] (a UTC, zoned or naive instant's
/// microseconds) or date32 (days).
const XForm = enum(u8) { int64 = 0, float64 = 1, micros = 2, days = 3 };
/// The y column's form: int64 or float64.
const YForm = enum(u8) { int64 = 0, float64 = 1 };
/// The scale's kind: linear (x as a number, a time in seconds) or time (microseconds).
const Kind = enum(u8) { linear = 0, time = 1 };

/// The space's value type for an x form under a kind, as the Elixir path's `space/3`
/// answers it: an integer where it stays one, else a float.
fn SpaceOf(comptime xf: XForm, comptime kind: Kind) type {
    return switch (xf) {
        .int64 => i64,
        .float64 => f64,
        .micros, .days => if (kind == .time) i64 else f64,
    };
}

fn YOf(comptime yf: YForm) type {
    return if (yf == .int64) i64 else f64;
}

/// A view's piece of the ladder partial, as `Ladder.partial/4`'s Elixir walk computes it:
/// its segments in row order, each run's buckets ascending, each once, every point's row
/// counted within the view; `:fallback` where the Elixir path would answer with an integer
/// past 64 bits or raise, so it answers instead.
pub fn ladder(
    xform: u8,
    xdata: beam.term,
    xvalid: beam.term,
    yform: u8,
    ydata: beam.term,
    yvalid: beam.term,
    first: usize,
    count: usize,
    kind: u8,
    k: i64,
) !beam.term {
    const xf = std.enums.fromInt(XForm, xform) orelse return error.UnknownForm;
    const yf = std.enums.fromInt(YForm, yform) orelse return error.UnknownForm;
    const kd = std.enums.fromInt(Kind, kind) orelse return error.UnknownForm;
    const buffers = Buffers{
        .x = try bytes(xdata),
        .xv = try bytes(xvalid),
        .y = try bytes(ydata),
        .yv = try bytes(yvalid),
        .first = first,
        .count = count,
    };

    switch (xf) {
        inline else => |cxf| switch (kd) {
            inline else => |ckd| switch (yf) {
                inline else => |cyf| return Walk(cxf, ckd, cyf).run(buffers, k),
            },
        },
    }
}

const Buffers = struct {
    x: []const u8,
    xv: []const u8,
    y: []const u8,
    yv: []const u8,
    first: usize,
    count: usize,
};

fn Walk(comptime xf: XForm, comptime kind: Kind, comptime yf: YForm) type {
    const S = SpaceOf(xf, kind);
    const Y = YOf(yf);

    return struct {
        const Point = struct { row: u32, s: S, y: Y };
        const Bucket = struct { b: i64, first: Point, last: Point, low: Point, high: Point };
        const Segment = struct { gap: bool, row: u32, start: usize, len: usize };

        const Fallback = error{Fallback};

        fn run(buf: Buffers, k: i64) !beam.term {
            const end = std.math.add(usize, buf.first, buf.count) catch return error.ShortBuffer;
            const xw: usize = if (xf == .days) 4 else 8;
            if (buf.x.len < end * xw or buf.y.len < end * 8) return error.ShortBuffer;
            if (buf.xv.len * 8 < end or buf.yv.len * 8 < end) return error.ShortBuffer;
            if (buf.count > std.math.maxInt(u32)) return error.ShortBuffer;

            const width = widthOf(k) catch return fallback();
            var buckets = try Grow(Bucket).init(64);
            defer buckets.deinit();
            var segments = try Grow(Segment).init(8);
            defer segments.deinit();

            walk(buf, k, width, &buckets, &segments) catch |err| switch (err) {
                error.Fallback => return fallback(),
                error.OutOfMemory => return error.OutOfMemory,
            };
            return build(segments.slice(), buckets.slice());
        }

        fn fallback() beam.term {
            return .{ .v = e.enif_make_atom(beam.context.env, "fallback") };
        }

        /// The bucket's width at level `k` as a float (`2^k`), for a float `s`; an
        /// integer `s` shifts instead. Outside a float's exact powers of two the Elixir path
        /// raises or answers past 64 bits.
        fn widthOf(k: i64) Fallback!f64 {
            if (S == i64) return 0;
            if (k < -1022 or k > 1023) return error.Fallback;
            return std.math.ldexp(@as(f64, 1.0), @as(i32, @intCast(k)));
        }

        /// x at row `r` in the scale's space, as `Ladder.space/3` reads it.
        inline fn space(buf: Buffers, r: usize) Fallback!S {
            switch (xf) {
                .int64 => {
                    const x = readI64(buf.x, r);
                    if (kind == .linear) return x;
                    const m = @mulWithOverflow(x, @as(i64, 1_000_000));
                    if (m[1] != 0) return error.Fallback;
                    return m[0];
                },
                .float64 => {
                    const x = readF64(buf.x, r);
                    const s = if (kind == .linear) x else x * 1_000_000.0;
                    if (!std.math.isFinite(s)) return error.Fallback;
                    return s;
                },
                .micros => {
                    const us = readI64(buf.x, r);
                    if (kind == .time) return us;
                    return @as(f64, @floatFromInt(us)) / 1_000_000.0;
                },
                .days => {
                    const d: i64 = readI32(buf.x, r);
                    if (kind == .linear) return @as(f64, @floatFromInt(d)) * 86_400.0;
                    const m = @mulWithOverflow(d, @as(i64, 86_400_000_000));
                    if (m[1] != 0) return error.Fallback;
                    return m[0];
                },
            }
        }

        inline fn yAt(buf: Buffers, r: usize) Y {
            return if (Y == i64) readI64(buf.y, r) else readF64(buf.y, r);
        }

        /// `floor(s / 2^k)`, exactly, as `Ladder.bucket/2`: an arithmetic shift for an
        /// integer, a floor of the quotient for a float.
        inline fn bucketOf(s: S, k: i64, width: f64) Fallback!i64 {
            if (S == i64) {
                if (k >= 0) return s >> @as(u6, @intCast(@min(k, 63)));
                if (s == 0) return 0;
                if (k <= -63) return error.Fallback;
                const shifted = @shlWithOverflow(s, @as(u6, @intCast(-k)));
                if (shifted[1] != 0) return error.Fallback;
                return shifted[0];
            } else {
                const q = @floor(s / width);
                if (!(q >= -9.223372036854775808e18 and q < 9.223372036854775808e18)) return error.Fallback;
                return @intFromFloat(q);
            }
        }

        /// One pass over the rows: the buckets of each run in `buckets`, the segments in
        /// `segments`. A run whose buckets did not close in ascending order (x not sorted)
        /// is made ascending, a bucket's summaries merged.
        fn walk(buf: Buffers, k: i64, width: f64, buckets: *Grow(Bucket), segments: *Grow(Segment)) (Fallback || error{OutOfMemory})!void {
            var open: ?Bucket = null;
            var run_start: usize = 0;
            var ordered = true;

            var i: usize = 0;
            while (i < buf.count) : (i += 1) {
                const r = buf.first + i;
                const row: u32 = @intCast(i);

                if (!bit(buf.xv, r) or !bit(buf.yv, r)) {
                    if (open) |o| {
                        try close(buckets, o, run_start, &ordered);
                        try closeRun(buckets, segments, run_start, ordered);
                        open = null;
                    }
                    const n = segments.len;
                    if (n == 0 or !segments.items[n - 1].gap) {
                        try segments.push(.{ .gap = true, .row = row, .start = 0, .len = 0 });
                    }
                    continue;
                }

                const s = try space(buf, r);
                const y = yAt(buf, r);
                const b = try bucketOf(s, k, width);
                const p = Point{ .row = row, .s = s, .y = y };

                if (open) |*o| {
                    if (b == o.b) {
                        o.last = p;
                        if (y < o.low.y) o.low = p;
                        if (y > o.high.y) o.high = p;
                    } else {
                        try close(buckets, o.*, run_start, &ordered);
                        o.* = .{ .b = b, .first = p, .last = p, .low = p, .high = p };
                    }
                } else {
                    run_start = buckets.len;
                    ordered = true;
                    open = .{ .b = b, .first = p, .last = p, .low = p, .high = p };
                }
            }

            if (open) |o| {
                try close(buckets, o, run_start, &ordered);
                try closeRun(buckets, segments, run_start, ordered);
            }
        }

        /// A bucket closed into its run: the run stays ordered while each bucket closed is
        /// above the one before, as the walk's `put_open/2` keeps it.
        inline fn close(buckets: *Grow(Bucket), o: Bucket, run_start: usize, ordered: *bool) error{OutOfMemory}!void {
            const n = buckets.len;
            if (n > run_start and !(o.b > buckets.items[n - 1].b)) ordered.* = false;
            try buckets.push(o);
        }

        fn lessByBucket(_: void, a: Bucket, b: Bucket) bool {
            return a.b < b.b;
        }

        /// A run closed into its segment, its buckets made ascending, each once where they
        /// are not: sorted by bucket, then each bucket's summaries merged (`Ladder.summary/2`,
        /// commutative, so their order is free).
        fn closeRun(buckets: *Grow(Bucket), segments: *Grow(Segment), start: usize, ordered: bool) error{OutOfMemory}!void {
            if (!ordered) {
                const held = buckets.items[start..buckets.len];
                std.sort.pdq(Bucket, held, {}, lessByBucket);
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
            try segments.push(.{ .gap = false, .row = 0, .start = start, .len = buckets.len - start });
        }

        /// `Ladder.summary/2`: the first and last by row, the least and greatest by y, the
        /// earlier row on a tie.
        fn merge(a: Bucket, b: Bucket) Bucket {
            return .{
                .b = a.b,
                .first = if (a.first.row <= b.first.row) a.first else b.first,
                .last = if (a.last.row >= b.last.row) a.last else b.last,
                .low = if (a.low.y < b.low.y or (a.low.y == b.low.y and a.low.row <= b.low.row)) a.low else b.low,
                .high = if (a.high.y > b.high.y or (a.high.y == b.high.y and a.high.row <= b.high.row)) a.high else b.high,
            };
        }

        // -- the terms ------------------------------------------------------------------------

        inline fn number(env: beam.env, comptime T: type, v: T) e.ErlNifTerm {
            return if (T == i64) e.enif_make_int64(env, v) else e.enif_make_double(env, v);
        }

        fn point(env: beam.env, p: Point) e.ErlNifTerm {
            var parts = [3]e.ErlNifTerm{ e.enif_make_int64(env, p.row), number(env, S, p.s), number(env, Y, p.y) };
            return e.enif_make_tuple_from_array(env, &parts, 3);
        }

        /// A bucket's four points, each row's point built once: a row that is the bucket's
        /// first and its least, say, is one term in both places, as the walk shares it.
        fn summary(env: beam.env, bk: Bucket) [4]e.ErlNifTerm {
            const ps = [4]Point{ bk.first, bk.last, bk.low, bk.high };
            var terms: [4]e.ErlNifTerm = undefined;
            for (ps, 0..) |p, j| {
                terms[j] = for (ps[0..j], 0..) |q, m| {
                    if (q.row == p.row) break terms[m];
                } else point(env, p);
            }
            return terms;
        }

        /// The segments as the Elixir walk answers them: `{:run, [{b, {first, last, low,
        /// high}}]}` and `{:gap, row}`, built from the end so each list is made in one pass.
        fn build(segments: []const Segment, buckets: []const Bucket) beam.term {
            const env = beam.context.env;
            const run_atom = e.enif_make_atom(env, "run");
            const gap_atom = e.enif_make_atom(env, "gap");
            var out = e.enif_make_list(env, 0);

            var si = segments.len;
            while (si > 0) {
                si -= 1;
                const seg = segments[si];
                var pair: [2]e.ErlNifTerm = undefined;
                if (seg.gap) {
                    pair = .{ gap_atom, e.enif_make_int64(env, seg.row) };
                } else {
                    var list = e.enif_make_list(env, 0);
                    var bi = seg.start + seg.len;
                    while (bi > seg.start) {
                        bi -= 1;
                        const bk = buckets[bi];
                        var points = summary(env, bk);
                        var entry = [2]e.ErlNifTerm{ e.enif_make_int64(env, bk.b), e.enif_make_tuple_from_array(env, &points, 4) };
                        list = e.enif_make_list_cell(env, e.enif_make_tuple_from_array(env, &entry, 2), list);
                    }
                    pair = .{ run_atom, list };
                }
                out = e.enif_make_list_cell(env, e.enif_make_tuple_from_array(env, &pair, 2), out);
            }
            return .{ .v = out };
        }
    };
}
