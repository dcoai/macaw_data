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
//! - `filter.zig`: filter's mask and the gather of fixed-width slots and bits (§4.1.1).

const beam = @import("beam");
const ladder_walk = @import("ladder.zig");
const finishes = @import("finish.zig");
const grouping = @import("group.zig");
const filtering = @import("filter.zig");

/// The kernels' interface version, read once at start (`Macaw.Data.Native`): the library
/// answers only when it is the version the Elixir side was compiled against.
pub fn abi() u32 {
    return 6;
}

/// A view's piece of the ladder partial (`ladder.zig`).
pub fn ladder(xform: u8, xdata: beam.term, xvalid: beam.term, yform: u8, ydata: beam.term, yvalid: beam.term, first: usize, count: usize, kind: u8, k: i64) !beam.term {
    return ladder_walk.ladder(xform, xdata, xvalid, yform, ydata, yvalid, first, count, kind, k);
}

/// `M4.finish/3`'s refs from the merged partial's pieces (`finish.zig`).
pub fn m4_finish(pieces: beam.term, k: i64, extent: u8, lo: beam.term, hi: beam.term, width: i64) !beam.term {
    return finishes.m4_finish(pieces, k, extent, lo, hi, width);
}

/// `Lttb.finish/3`'s refs from the merged partial's pieces (`finish.zig`).
pub fn lttb_finish(pieces: beam.term, n: i64) !beam.term {
    return finishes.lttb_finish(pieces, n);
}

/// `Aggregate.group_chunk/5`'s groups of an exact sum over dictionary codes (`group.zig`).
pub fn group_sum(vform: u8, vdata: beam.term, vvalid: beam.term, grouped: bool, codes: beam.term, cvalid: beam.term, ncodes: usize, first: usize, count: usize, limit: usize) !beam.term {
    return grouping.group_sum(vform, vdata, vvalid, grouped, codes, cvalid, ncodes, first, count, limit);
}

/// `Filter.chunk/3`'s selection of a view's rows (`filter.zig`).
pub fn filter_mask(mode: u8, data: beam.term, validity: beam.term, first: usize, count: usize, cmp: u8, value: beam.term, present: bool, missing: bool, pass: beam.term, ncodes: usize) !beam.term {
    return filtering.filter_mask(mode, data, validity, first, count, cmp, value, present, missing, pass, ncodes);
}

/// The `width`-byte slots of a buffer at a list of indexes (`filter.zig`).
pub fn take(data: beam.term, width: usize, indexes: beam.term) !beam.term {
    return filtering.take(data, width, indexes);
}

/// The bits of a bitmap at a list of indexes, packed (`filter.zig`).
pub fn take_bits(bitmap: beam.term, indexes: beam.term) !beam.term {
    return filtering.take_bits(bitmap, indexes);
}
