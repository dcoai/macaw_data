//! macaw_data's native kernels (spec/04 §1.7): each reads a column's packed Arrow
//! buffers (spec/01 §1.1) in place and answers exactly what the step's Elixir path
//! answers. Built ReleaseSafe in every environment, so a bounds or overflow fault panics
//! loudly, with its message, rather than reading past a buffer. Floating point is in
//! Zig's strict mode, its default: no operation is reordered, contracted into a fused
//! multiply-add or assumed finite, so an expression rounds as the Elixir path's does.
//!
//! This file is the NIFs' surface alone; each family lives in its own file:
//! - `buffers.zig`: binaries in place, bitmaps, little-endian reads, growing lists;
//! - `ladder.zig`: the ladder partial (spec/04 §4.5.1);
//! - `finish.zig`: m4's columns and lttb's selection over packed pieces (§4.5.4).
//! - `group.zig`: the exact sum by group over dictionary codes (spec/04 §5.1);
//! - `filter.zig`: filter's mask and the gather of fixed-width slots and bits (§4.1.1);
//! - `extremes.zig`: a column's first least and greatest slot (spec/02 §2.2).

const beam = @import("beam");
const ladder_walk = @import("ladder.zig");
const finishes = @import("finish.zig");
const grouping = @import("group.zig");
const filtering = @import("filter.zig");
const extremity = @import("extremes.zig");
const bufs = @import("buffers.zig");
const e = @import("erl_nif");

/// The kernels' interface version, read once at start (`Macaw.Data.Native`): the library
/// answers only when it is the version the Elixir side was compiled against.
pub fn abi() u32 {
    comptime noErrorUnions();
    return 8;
}

/// A kernel's answer as a term, never an error (macaw_data#101). Zigler turns an error
/// return into an `ErlangError` through its error-return trace, whose debug-info globals
/// are initialized lazily and without a lock, so no error is returned to it. A buffer,
/// piece or form a kernel can't read is `{:fault, reason}`, which the Elixir side raises
/// as a defect in its own packing (`Macaw.Data.Native.answer/3`); `{:fault,
/// :out_of_memory}` is answered by the Elixir path instead.
fn answer(result: anyerror!beam.term) beam.term {
    return result catch |err| fault(err);
}

fn fault(err: anyerror) beam.term {
    if (err == error.Fallback) return bufs.fallbackTerm();
    const reason = switch (err) {
        error.ShortBuffer => "short_buffer",
        error.NotABinary => "not_a_binary",
        error.NotAPiece => "not_a_piece",
        error.UnknownForm => "unknown_form",
        error.OutOfMemory => "out_of_memory",
        else => "unexpected",
    };
    const env = beam.context.env;
    var pair = [_]e.ErlNifTerm{ e.enif_make_atom(env, "fault"), e.enif_make_atom(env, reason) };
    return .{ .v = e.enif_make_tuple_from_array(env, &pair, 2) };
}

/// No surface function returns an error union: each answers a term through `answer`.
/// Evaluated at compile time from `abi`, which every build compiles.
fn noErrorUnions() void {
    for (@typeInfo(@This()).@"struct".decls) |decl| {
        const T = @TypeOf(@field(@This(), decl.name));
        if (@typeInfo(T) == .@"fn") {
            const returned = @typeInfo(T).@"fn".return_type.?;
            if (@typeInfo(returned) == .error_union)
                @compileError("kernel " ++ decl.name ++ " returns an error union: answer a fault term through answer (macaw_data#101)");
        }
    }
}

/// A view's piece of the ladder partial (`ladder.zig`).
pub fn ladder(xform: u8, xdata: beam.term, xvalid: beam.term, yform: u8, ydata: beam.term, yvalid: beam.term, first: usize, count: usize, kind: u8, k: i64) beam.term {
    return answer(ladder_walk.ladder(xform, xdata, xvalid, yform, ydata, yvalid, first, count, kind, k));
}

/// `M4.finish/3`'s refs from the merged partial's pieces (`finish.zig`).
pub fn m4_finish(pieces: beam.term, k: i64, extent: u8, lo: beam.term, hi: beam.term, width: i64) beam.term {
    return answer(finishes.m4_finish(pieces, k, extent, lo, hi, width));
}

/// `Lttb.finish/3`'s refs from the merged partial's pieces (`finish.zig`).
pub fn lttb_finish(pieces: beam.term, n: i64) beam.term {
    return answer(finishes.lttb_finish(pieces, n));
}

/// `Aggregate.group_chunk/5`'s groups of an exact sum over dictionary codes (`group.zig`).
pub fn group_sum(vform: u8, vdata: beam.term, vvalid: beam.term, grouped: bool, codes: beam.term, cvalid: beam.term, ncodes: usize, first: usize, count: usize, limit: usize) beam.term {
    return answer(grouping.group_sum(vform, vdata, vvalid, grouped, codes, cvalid, ncodes, first, count, limit));
}

/// `Filter.chunk/3`'s selection of a view's rows (`filter.zig`).
pub fn filter_mask(mode: u8, data: beam.term, validity: beam.term, first: usize, count: usize, cmp: u8, value: beam.term, present: bool, missing: bool, pass: beam.term, ncodes: usize) beam.term {
    return answer(filtering.filter_mask(mode, data, validity, first, count, cmp, value, present, missing, pass, ncodes));
}

/// The `width`-byte slots of a buffer at a list of indexes (`filter.zig`).
pub fn take(data: beam.term, width: usize, indexes: beam.term) beam.term {
    return answer(filtering.take(data, width, indexes));
}

/// The bits of a bitmap at a list of indexes, packed (`filter.zig`).
pub fn take_bits(bitmap: beam.term, indexes: beam.term) beam.term {
    return answer(filtering.take_bits(bitmap, indexes));
}

/// The first least and greatest present slot of a view (`extremes.zig`).
pub fn extremes(form: u8, data: beam.term, validity: beam.term, first: usize, count: usize) beam.term {
    return answer(extremity.extremes(form, data, validity, first, count));
}
