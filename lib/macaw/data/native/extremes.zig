//! A column's least and greatest reading (`Macaw.Data.Derived.Columns`' `min/2` and
//! `max/2`, spec/02 §2.2): one view's slots of an int64, float64 or int32 buffer read in
//! place where the validity bit is set, and the first least and the first greatest slot
//! answered by index, so the Elixir side decodes one slot each, whatever its type.

const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const bufs = @import("buffers.zig");

const bytes = bufs.bytes;
const bit = bufs.bit;
const readI64 = bufs.readI64;
const readF64 = bufs.readF64;
const readI32 = bufs.readI32;
const fallbackTerm = bufs.fallbackTerm;

/// The buffer's form: int64 (numbers, and a time's microseconds), float64 (floats, and an
/// integral column's values), int32 (a date's days).
const Form = enum(u8) { int64 = 0, float64 = 1, int32 = 2 };

/// The first least and the first greatest present slot of the `count` rows of the view
/// from `first`, each counted from `first`: `{least, greatest}`, `nil` when no slot is
/// present, `:fallback` where a float is not finite (the Elixir path reads it as it is).
pub fn extremes(form: u8, data: beam.term, validity: beam.term, first: usize, count: usize) !beam.term {
    const f = std.enums.fromInt(Form, form) orelse return error.UnknownForm;
    const d = try bytes(data);
    const v = try bytes(validity);
    const end = std.math.add(usize, first, count) catch return error.ShortBuffer;
    const width: usize = if (f == .int32) 4 else 8;
    if (d.len < end * width or v.len * 8 < end) return error.ShortBuffer;
    return switch (f) {
        .int64 => scan(i64, readI64, d, v, first, count),
        .float64 => scan(f64, readF64, d, v, first, count),
        .int32 => scan(i32, readI32, d, v, first, count),
    };
}

fn scan(comptime T: type, comptime read: anytype, d: []const u8, v: []const u8, first: usize, count: usize) beam.term {
    var lo: usize = 0;
    var hi: usize = 0;
    var least: T = undefined;
    var greatest: T = undefined;
    var seen = false;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const r = first + i;
        if (!bit(v, r)) continue;
        const x = read(d, r);
        if (T == f64 and !std.math.isFinite(x)) return fallbackTerm();
        if (!seen) {
            least = x;
            greatest = x;
            lo = i;
            hi = i;
            seen = true;
            continue;
        }
        // Strictly: a tie keeps the first, as the Elixir path's `<` and `>` do.
        if (x < least) {
            least = x;
            lo = i;
        }
        if (x > greatest) {
            greatest = x;
            hi = i;
        }
    }
    const env = beam.context.env;
    if (!seen) return .{ .v = e.enif_make_atom(env, "nil") };
    var pair = [2]e.ErlNifTerm{ e.enif_make_uint64(env, lo), e.enif_make_uint64(env, hi) };
    return .{ .v = e.enif_make_tuple_from_array(env, &pair, 2) };
}
