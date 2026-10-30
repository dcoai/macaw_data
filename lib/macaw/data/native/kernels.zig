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
    return 4;
}

// -- buffers --------------------------------------------------------------------------------

const KernelError = error{ NotABinary, NotAPiece, ShortBuffer, UnknownForm };

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
const packed_header: usize = 8;
const packed_head: usize = 8;
const packed_bucket: usize = 8 + 4 * (4 + 8 + 8);

inline fn put(comptime T: type, out: []u8, at: usize, v: T) void {
    std.mem.writeInt(T, out[at..][0..@sizeOf(T)], v, .little);
}

// -- the finishes over packed pieces (spec/04 §4.5.4) -----------------------------------------

const Fallback = error{Fallback};

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

fn fallbackTerm() beam.term {
    return .{ .v = e.enif_make_atom(beam.context.env, "fallback") };
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
