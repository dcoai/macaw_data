//! The ladder partial (spec/04 §4.5.1): one view's walk over its x and y buffers into the
//! packed piece `Ladder.Packed` writes.

const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const bufs = @import("buffers.zig");

const bytes = bufs.bytes;
const bit = bufs.bit;
const readI64 = bufs.readI64;
const readF64 = bufs.readF64;
const readI32 = bufs.readI32;
const Grow = bufs.Grow;
const Fallback = bufs.Fallback;
const put = bufs.put;

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

/// A view's piece of the ladder partial, as `Ladder.partial/4`'s Elixir walk computes it and
/// `Ladder.Packed.pack/1` packs it, byte for byte: its segments in row order, each run's
/// buckets ascending, each once, every point's row counted within the view; `:fallback`
/// where the Elixir path would answer with an integer past 64 bits or raise, so it answers
/// instead.
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

        // -- the packed piece (`Ladder.Packed`) ------------------------------------------------

        /// The piece as `Ladder.Packed.pack/1` writes the walk's segments, byte for byte: a
        /// header with the points' types, a head per segment, then 88 bytes a bucket. One
        /// binary, off the process heap past 64 bytes; no term is built a bucket.
        fn build(segments: []const Segment, buckets: []const Bucket) !beam.term {
            const env = beam.context.env;
            const size = packed_header + segments.len * packed_head + buckets.len * packed_bucket;
            var term: e.ErlNifTerm = undefined;
            const raw = e.enif_make_new_binary(env, size, &term);
            if (raw == null) return error.OutOfMemory;
            const out = raw[0..size];

            // With no bucket there is no point to type, and the walk's packing writes 0, 0.
            out[0] = 1;
            out[1] = if (buckets.len == 0 or S == i64) 0 else 1;
            out[2] = if (buckets.len == 0 or Y == i64) 0 else 1;
            out[3] = 0;
            put(u32, out, 4, @intCast(segments.len));

            var at: usize = packed_header;
            for (segments) |seg| {
                out[at] = if (seg.gap) 0 else 1;
                out[at + 1] = 0;
                out[at + 2] = 0;
                out[at + 3] = 0;
                put(u32, out, at + 4, if (seg.gap) seg.row else @intCast(seg.len));
                at += packed_head;
            }

            for (segments) |seg| {
                if (seg.gap) continue;
                for (buckets[seg.start .. seg.start + seg.len]) |bk| {
                    put(i64, out, at, bk.b);
                    at += 8;
                    for ([4]Point{ bk.first, bk.last, bk.low, bk.high }) |p| {
                        put(u32, out, at, p.row);
                        putNumber(S, out, at + 4, p.s);
                        putNumber(Y, out, at + 12, p.y);
                        at += 20;
                    }
                }
            }
            return .{ .v = term };
        }

        inline fn putNumber(comptime T: type, out: []u8, at: usize, v: T) void {
            if (T == i64) put(i64, out, at, v) else put(u64, out, at, @bitCast(v));
        }
    };
}

/// `Ladder.Packed`'s sizes: the header, a segment's head and a bucket's record.
pub const packed_header: usize = 8;
pub const packed_head: usize = 8;
pub const packed_bucket: usize = 8 + 4 * (4 + 8 + 8);
