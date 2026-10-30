defmodule Macaw.Data.Operations.Transforms.Ladder do
  @moduledoc """
  The bucket ladder `m4` and `lttb` reduce on (spec/04 §4.4, §4.5; macaw_data#9 §5): one
  absolute ladder of buckets in the space the x scale maps through, so a chunk's partial
  depends on its rows, the scale's kind and the level alone, never on the data first read
  or on the extent.

  - **The space** is the scale's kind (`scale:` in the context): `:linear`, x as a number,
    a time in seconds; `:time`, a time in microseconds since the Unix epoch; `:log`, the
    base-2 logarithm of x, which is above 0. A step reads `:time` for a time column and
    `:linear` otherwise when the context names none.
  - **A bucket** at level `k` is `2^k` wide, `k` any integer, from origin 0: the value `s`
    lies in bucket `floor(s / 2^k)`.
  - **The level** is the coarsest whose bucket is at most an ideal width the step derives
    from the span and its count, `floor(log2(ideal))`. **Hysteresis:** the previous level,
    given as `level:` in the context, is kept while its bucket is within a factor of 2 of
    the ideal width, so a span drifting near a power of two keeps one level.
  - **A partial** holds a piece a view, in chunk order: the view's runs of rows, split by
    gaps (a row whose x or y is `nil`, each run of gap rows kept as its first), each run
    its buckets **ascending by bucket**, per bucket the first, the last, the least and the
    greatest point, each `{row, s, y}`, packed into one binary a piece (`Ladder.Packed`),
    off the process heap, so a cache of partials costs its holder a few words each. Partials merge associatively in chunk order by
    concatenation (`combine/2`), so a merge costs the chunks, not the buckets; the chunk
    edges are joined once, when the merged partial is read (`runs/1`): a bucket
    straddling an edge merges its two summaries and a gap on an edge stays one gap. A
    finer partial folds into a coarser level exactly (`coarsen/2`), so a zoom out reuses
    finer partials.
  """

  import Bitwise

  alias Macaw.Data.Native
  alias Macaw.Data.Native.Kernels
  alias Macaw.Data.Table
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Operations.Transforms
  alias Macaw.Data.Operations.Transforms.Ladder.Packed

  @kinds [:linear, :time, :log]
  @epoch_naive ~N[1970-01-01 00:00:00]

  @typedoc "A row of a merged partial: `{view, row}`, in input order."
  @type ref :: {non_neg_integer(), non_neg_integer()}

  @typedoc """
  A point of a bucket: `{row, s, y}` in a piece, `row` the row of its view; `{ref, s, y}`
  as `runs/1` reads it.
  """
  @type point :: {non_neg_integer() | ref(), number(), number()}

  @typedoc "A bucket's first, last, least and greatest points."
  @type summary :: {point(), point(), point(), point()}

  @typedoc "A run's buckets, ascending by bucket, each once."
  @type run :: [{integer(), summary()}]

  @typedoc "A view's segments in row order: its runs, and each run of gap rows as its first row."
  @type segments :: [{:run, run()} | {:gap, non_neg_integer()}]

  @typedoc """
  One view's segments packed into one binary (`Ladder.Packed`), under the view's index
  among the partial's views: off the process heap, so a cache of partials costs its holder
  a few words a piece, whatever the buckets.
  """
  @type piece :: {non_neg_integer(), binary()}

  @typedoc """
  A bucket's summary as `runs/1` reads it, `{view, summary}`: its points are rows of that
  view, or, `view` `nil`, they carry their `{view, row}` (a bucket straddling a chunk edge).
  """
  @type located :: {non_neg_integer() | nil, summary()}

  @typedoc "A partial: its level, the views its pieces index, and a piece a view, in order."
  @type partial :: {integer(), [Table.view()], [piece()]}

  # -- binding ------------------------------------------------------------------------------

  @doc """
  The step's fields, the scale's kind and the x extent over the whole input, once:
  `%{x, y, x_name, y_name, kind, extent}`, `extent` `{lo, hi}` in the space or `nil`.
  A sorted x column is read at its ends, any other scanned.
  """
  @spec bind([Table.name()], Table.t(), map(), String.t()) :: map()
  def bind([x, y], table, context, op) do
    names = Table.names(table)
    x_name = Transforms.name_in(names, x)
    y_name = Transforms.name_in(names, y)
    kind = kind!(Map.get(context, :scale), x_name && Table.column_type(table, x_name), op)
    sorted? = x_name != nil and Table.sorted(table) == x_name
    bound = %{x: x, y: y, x_name: x_name, y_name: y_name, kind: kind}
    Map.put(bound, :extent, extent(Table.chunks(table), bound, sorted?, op))
  end

  defp kind!(nil, :time, _op), do: :time
  defp kind!(nil, _type, _op), do: :linear
  defp kind!(kind, _type, _op) when kind in @kinds, do: kind

  defp kind!(kind, type, op) when is_binary(kind) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == kind)) do
      nil -> kind!(:unknown, type, op)
      found -> found
    end
  end

  defp kind!(kind, _type, op) do
    raise ArgumentError,
          "transform #{inspect(op)}: scale #{inspect(kind)} is not one of linear, time or " <>
            "log (spec/04 §4.4)"
  end

  defp extent(_views, %{x_name: nil}, _sorted?, _op), do: nil

  defp extent(views, bound, true, op) do
    present = for view <- views, (k = present_count(view, bound.x_name)) > 0, do: {view, k}

    case present do
      [] ->
        nil

      _ ->
        {first_view, _} = hd(present)
        {last_view, k} = List.last(present)
        {space_at(first_view, 0, bound, op), space_at(last_view, k - 1, bound, op)}
    end
  end

  defp extent(views, bound, false, op) do
    Enum.reduce(views, nil, fn view, extent ->
      view
      |> Transforms.view_values(bound.x_name)
      |> Enum.reduce(extent, fn
        nil, extent -> extent
        x, nil -> {space(x, bound, op), space(x, bound, op)}
        x, {lo, hi} -> {min(lo, space(x, bound, op)), max(hi, space(x, bound, op))}
      end)
    end)
  end

  # The rows of a view of a sorted column before its gaps, which come last.
  defp present_count({chunk, first, count}, name),
    do: first_where(0, count, &(Chunk.at(chunk, name, first + &1) == nil))

  defp space_at({chunk, first, _count}, i, bound, op),
    do: chunk |> Chunk.at(bound.x_name, first + i) |> space(bound, op)

  defp first_where(lo, hi, _true?) when lo >= hi, do: hi

  defp first_where(lo, hi, true?) do
    mid = div(lo + hi, 2)
    if true?.(mid), do: first_where(lo, mid, true?), else: first_where(mid + 1, hi, true?)
  end

  @doc """
  An x reading in the scale's space: seconds (a time) or the number itself for `:linear`;
  microseconds since the Unix epoch for `:time`, a number read as seconds; `log2` of a
  number above 0 for `:log`. Any other reading raises `ArgumentError` naming the step.
  """
  @spec space(term(), map(), String.t()) :: number()
  def space(value, %{kind: :linear, x: x}, op), do: Transforms.seconds!(value, x, op)

  def space(%DateTime{} = t, %{kind: :time}, _op), do: DateTime.to_unix(t, :microsecond)

  def space(%NaiveDateTime{} = t, %{kind: :time}, _op),
    do: NaiveDateTime.diff(t, @epoch_naive, :microsecond)

  def space(%Date{} = d, %{kind: :time}, _op), do: Date.diff(d, ~D[1970-01-01]) * 86_400_000_000

  def space(value, %{kind: :time, x: x}, op), do: Transforms.seconds!(value, x, op) * 1_000_000

  def space(value, %{kind: :log, x: x}, op) do
    case Transforms.number!(value, x, op) do
      n when n > 0 -> :math.log2(n)
      n -> Transforms.not_a!(n, x, op, "above 0, as a log scale reads x")
    end
  end

  # -- levels ---------------------------------------------------------------------------------

  @doc """
  The level for an ideal bucket width: the previous level while its bucket is within a
  factor of 2 of it, else the coarsest whose bucket is at most it; the previous level, or
  0, with no width (a single point or none).
  """
  @spec level(number() | nil, integer() | nil) :: integer()
  def level(nil, previous), do: previous || 0
  def level(ideal, _previous) when ideal <= 0, do: 0

  def level(ideal, previous) when is_integer(previous) do
    width = pow2(previous)
    if width <= 2 * ideal and width >= ideal / 2, do: previous, else: level(ideal, nil)
  end

  def level(ideal, nil) do
    k = floor(:math.log2(ideal))

    cond do
      pow2(k) > ideal -> k - 1
      pow2(k + 1) <= ideal -> k + 1
      true -> k
    end
  end

  @doc "A bucket's width at level `k`, `2^k`."
  @spec pow2(integer()) :: number()
  def pow2(k) when k >= 0, do: Integer.pow(2, k)
  def pow2(k), do: :math.pow(2, k)

  @doc "The bucket of `s` at level `k`: `floor(s / 2^k)`, exactly."
  @spec bucket(number(), integer()) :: integer()
  def bucket(s, k), do: at_bucket(s, k, pow2(k))

  # -- partials -------------------------------------------------------------------------------

  @doc """
  One view's partial at level `k`: its rows' buckets, run by run between gaps, as the one
  piece of view 0. A run's buckets are ascending by bucket, each once. Where the native
  kernels are loaded and both columns are in a form the kernel reads, on a linear or time
  scale, the kernel computes the piece from the columns' buffers in place, equal term for
  term to the Elixir walk's (spec/04 §4.5.2).
  """
  @spec partial(Table.view(), map(), integer(), String.t()) :: partial()
  def partial(view, bound, k, op) do
    case native(view, bound, k) do
      :fallback -> partial_elixir(view, bound, k, op)
      piece -> {k, [view], [{0, piece}]}
    end
  end

  @doc false
  # The partial by the Elixir walk alone, whatever the kernels: the path a build without
  # them runs, and the reference the native kernel is held equal to (spec/04 §4.5.2).
  @spec partial_elixir(Table.view(), map(), integer(), String.t()) :: partial()
  def partial_elixir(view, %{x_name: x_name, y_name: y_name, kind: kind} = bound, k, op) do
    xs = Transforms.view_values(view, x_name)
    ys = Transforms.view_values(view, y_name)
    segments = walk(xs, ys, 0, {kind, k, pow2(k), bound, op}, nil, nil, [])
    {k, [view], [{0, Packed.pack(segments)}]}
  end

  # The piece by the native kernel (spec/04 §4.5.2), reading the view's x and y buffers in
  # place, where the kernels are loaded and both columns are in a form it reads, on a
  # linear or time scale; else, or where the kernel hands it back, `:fallback`.
  defp native({chunk, first, count}, %{x_name: x, y_name: y, kind: kind}, k)
       when x != nil and y != nil and kind in [:linear, :time] do
    with true <- Native.active?(),
         {xf, xd, xv} <- x_buffers(Chunk.packed(chunk, x)),
         {yf, yd, yv} <- y_buffers(Chunk.packed(chunk, y)) do
      kd = if kind == :time, do: 1, else: 0

      case Native.scheduler(count) do
        :normal -> Kernels.ladder(xf, xd, xv, yf, yd, yv, first, count, kd, k)
        :dirty -> Kernels.ladder_dirty(xf, xd, xv, yf, yd, yv, first, count, kd, k)
      end
    else
      _ -> :fallback
    end
  end

  defp native(_view, _bound, _k), do: :fallback

  # An x column's buffers and the kernel's code for its form: int64, float64, an instant's
  # microseconds (UTC, zoned or naive) or date32's days; any other form is the Elixir path's.
  defp x_buffers({:int64, data, validity}), do: {0, data, validity}
  defp x_buffers({:float64, data, validity}), do: {1, data, validity}
  defp x_buffers({:utc, us, validity, _precision}), do: {2, us, validity}
  defp x_buffers({:naive, us, validity, _precision}), do: {2, us, validity}
  defp x_buffers({:zoned, us, validity, _precision, _zones, _codes}), do: {2, us, validity}
  defp x_buffers({:date, days, validity}), do: {3, days, validity}
  defp x_buffers(_column), do: :elixir

  defp y_buffers({:int64, data, validity}), do: {0, data, validity}
  defp y_buffers({:float64, data, validity}), do: {1, data, validity}
  defp y_buffers(_column), do: :elixir

  # One pass over the rows, `at` the scale's kind, the level, its bucket's width, the
  # bound context and the step's name, read once. Between gaps, `open/12` carries the
  # open bucket's first point, its last row, space and y, and its least and greatest
  # points as arguments, so a row that lands in the open bucket allocates nothing unless it
  # is a new extreme. The run's closed buckets are kept newest first, `{entries,
  # ordered?}`, `ordered?` while each bucket closed is above the one before (rows in x
  # order), so a run in x order is reversed and any other made ascending through a map
  # once.
  defp walk([], [], _i, _at, open, run, segments),
    do: Enum.reverse(close_run(put_open(open, run), segments))

  defp walk([x | xs], [y | ys], i, at, open, run, segments) when x == nil or y == nil do
    segments =
      case close_run(put_open(open, run), segments) do
        [{:gap, _} | _] = segments -> segments
        segments -> [{:gap, i} | segments]
      end

    walk(xs, ys, i + 1, at, nil, nil, segments)
  end

  defp walk([x | xs], [y | ys], i, {kind, k, w, bound, op} = at, open, run, segments) do
    s = at_space(x, kind, bound, op)
    y = if is_number(y), do: y, else: Transforms.number!(y, bound.y, op)
    point = {i, s, y}
    run = put_open(open, run)
    open(xs, ys, i + 1, at, at_bucket(s, k, w), point, i, s, y, point, point, run, segments)
  end

  # The rows while a bucket is open: `b` its bucket, `first` its first point, `li`, `ls`
  # and `ly` its last row's, `low` and `high` its least and greatest points.
  defp open(
         [x | xs],
         [y | ys],
         i,
         {kind, k, w, bound, op} = at,
         b,
         first,
         li,
         ls,
         ly,
         low,
         high,
         run,
         segments
       )
       when x != nil and y != nil do
    s = at_space(x, kind, bound, op)
    y = if is_number(y), do: y, else: Transforms.number!(y, bound.y, op)

    case at_bucket(s, k, w) do
      ^b ->
        low = if y < elem(low, 2), do: {i, s, y}, else: low
        high = if y > elem(high, 2), do: {i, s, y}, else: high
        open(xs, ys, i + 1, at, b, first, i, s, y, low, high, run, segments)

      next ->
        run = put_open({b, {first, {li, ls, ly}, low, high}}, run)
        point = {i, s, y}
        open(xs, ys, i + 1, at, next, point, i, s, y, point, point, run, segments)
    end
  end

  defp open(xs, ys, i, at, b, first, li, ls, ly, low, high, run, segments),
    do: walk(xs, ys, i, at, {b, {first, {li, ls, ly}, low, high}}, run, segments)

  # `space/3` for a number on a linear or time scale, read without a call; any other
  # reading through it.
  defp at_space(x, :linear, _bound, _op) when is_number(x), do: x
  defp at_space(x, :time, _bound, _op) when is_number(x), do: x * 1_000_000
  defp at_space(x, _kind, bound, op), do: space(x, bound, op)

  # `bucket/2` with the bucket's width `w` (`2^k`) computed once.
  defp at_bucket(s, k, _w) when is_integer(s) and k >= 0, do: s >>> k
  defp at_bucket(s, k, _w) when is_integer(s), do: s <<< -k
  defp at_bucket(s, _k, w), do: floor(s / w)

  defp put_open(nil, run), do: run
  defp put_open(entry, nil), do: {[entry], true}

  defp put_open({b, _summary} = entry, {[{last, _} | _] = entries, ordered?}),
    do: {[entry | entries], ordered? and b > last}

  defp close_run(nil, segments), do: segments
  defp close_run({entries, true}, segments), do: [{:run, Enum.reverse(entries)} | segments]

  defp close_run({entries, false}, segments),
    do: [{:run, ascending(entries, &summary/2)} | segments]

  # Buckets in any order made ascending, each once, a bucket's summaries merged.
  defp ascending(entries, merge) do
    entries
    |> Enum.reduce(%{}, fn {b, s}, acc -> Map.update(acc, b, s, &merge.(&1, s)) end)
    |> Map.to_list()
    |> List.keysort(0)
  end

  @doc """
  Two summaries of one bucket merged: the first and last by input order, the least and
  greatest by y, the earlier on a tie. Commutative and associative, whether the points'
  refs are rows of one view or `{view, row}`.
  """
  @spec summary(summary(), summary()) :: summary()
  def summary({f1, l1, lo1, hi1}, {f2, l2, lo2, hi2}) do
    {earlier(f1, f2), later(l1, l2), least(lo1, lo2), greatest(hi1, hi2)}
  end

  defp earlier({r1, _, _} = a, {r2, _, _} = b), do: if(r1 <= r2, do: a, else: b)
  defp later({r1, _, _} = a, {r2, _, _} = b), do: if(r1 >= r2, do: a, else: b)

  defp least({r1, _, y1} = a, {r2, _, y2} = b),
    do: if(y1 < y2 or (y1 == y2 and r1 <= r2), do: a, else: b)

  defp greatest({r1, _, y1} = a, {r2, _, y2} = b),
    do: if(y1 > y2 or (y1 == y2 and r1 <= r2), do: a, else: b)

  @doc """
  Two partials merged, the first's chunks before the second's, at the coarser of their
  levels: the views and the pieces concatenated, the second's view indexes moved past the
  first's. No bucket is read, so a combine costs the chunks, never the buckets; a run or
  a gap continuing across the chunk edge, and a bucket straddling it, are joined once, by
  `runs/1`. Any grouping of the same partials gives the same partial.
  """
  @spec combine(partial(), partial()) :: partial()
  def combine({ka, views_a, pieces_a}, {kb, views_b, pieces_b}) do
    k = max(ka, kb)
    by = length(views_a)
    moved = for {v, segments} <- coarsen_pieces(pieces_b, kb, k), do: {v + by, segments}
    {k, views_a ++ views_b, coarsen_pieces(pieces_a, ka, k) ++ moved}
  end

  @doc """
  A partial folded into a level at or above its own: each bucket into the coarser bucket
  holding it, one pass a run, exactly as computing the partial at that level would give it.
  """
  @spec coarsen(partial(), integer()) :: partial()
  def coarsen({k, views, pieces}, to) when to >= k,
    do: {to, views, coarsen_pieces(pieces, k, to)}

  defp coarsen_pieces(pieces, k, k), do: pieces

  defp coarsen_pieces(pieces, k, to) do
    d = Integer.pow(2, to - k)

    for {v, piece} <- pieces do
      segments =
        piece
        |> Packed.unpack()
        |> Enum.map(fn
          {:run, [{b, s} | rest]} -> {:run, fold_run(rest, d, Integer.floor_div(b, d), s, [])}
          gap -> gap
        end)

      {v, Packed.pack(segments)}
    end
  end

  # Ascending buckets into coarser ones, still ascending: a run of them sharing a coarser
  # bucket is consecutive.
  defp fold_run([], _d, c, s, acc), do: Enum.reverse([{c, s} | acc])

  defp fold_run([{b, s} | rest], d, c, held, acc) do
    case Integer.floor_div(b, d) do
      ^c -> fold_run(rest, d, c, summary(held, s), acc)
      next -> fold_run(rest, d, next, s, [{c, held} | acc])
    end
  end

  @doc """
  A merged partial read once, in input order: its gaps, `{:gap, {view, row}}`, and its
  runs, `{:run, buckets}`, each run's buckets `{b, located}` ascending, each once (a
  `t:located/0` summary). A run ending one piece and one starting the next are one run, a
  bucket they share merged; a gap ending one and one starting the next are one gap, the
  first. Buckets out of order across pieces (an x not sorted) are merged through a map.
  No point is copied but a bucket's that straddles a chunk edge.
  """
  @spec runs(partial()) :: [{:gap, ref()} | {:run, [{integer(), located()}]}]
  def runs({_k, _views, pieces}) do
    pieces
    |> Enum.reduce([], fn {v, piece}, acc ->
      piece |> Packed.located(v) |> Enum.reduce(acc, &join/2)
    end)
    |> Enum.reduce([], fn
      {:run, frags}, out -> [{:run, run_buckets(frags)} | out]
      gap, out -> [gap | out]
    end)
  end

  # Segments joined newest first, each read as its view's (`Packed.located/2`); a run's
  # fragments, its located buckets, newest first too.
  defp join({:run, run}, [{:run, frags} | acc]), do: [{:run, [run | frags]} | acc]
  defp join({:run, run}, acc), do: [{:run, [run]} | acc]
  defp join({:gap, _ref}, [{:gap, _} | _] = acc), do: acc
  defp join({:gap, _ref} = gap, acc), do: [gap | acc]

  defp run_buckets([run]), do: run

  defp run_buckets(frags) do
    {entries, ordered?} =
      frags
      |> Enum.reverse()
      |> Enum.reduce({[], true}, fn run, acc -> Enum.reduce(run, acc, &add/2) end)

    if ordered?, do: Enum.reverse(entries), else: ascending(entries, &located/2)
  end

  defp add({b, s}, {[{b, held} | rest], ordered?}),
    do: {[{b, located(held, s)} | rest], ordered?}

  defp add({b, _s} = entry, {[{last, _} | _] = entries, ordered?}),
    do: {[entry | entries], ordered? and b > last}

  defp add(entry, {[], ordered?}), do: {[entry], ordered?}

  @doc """
  Two located summaries of one bucket merged (`summary/2`): within one view they stay
  that view's rows; across two, every point is given its `{view, row}`.
  """
  @spec located(located(), located()) :: located()
  def located({v, a}, {v, b}), do: {v, summary(a, b)}
  def located({va, a}, {vb, b}), do: {nil, summary(points(va, a), points(vb, b))}

  defp points(nil, summary), do: summary
  defp points(v, {f, l, lo, hi}), do: {point(v, f), point(v, l), point(v, lo), point(v, hi)}

  @doc "A located point with its ref `{view, row}`, given its summary's view (`nil`: it has it)."
  @spec point(non_neg_integer() | nil, point()) :: {ref(), number(), number()}
  def point(nil, point), do: point
  def point(v, {i, s, y}), do: {{v, i}, s, y}

  @doc "A located point's ref, `{view, row}`, given its summary's view (`nil`: it has it)."
  @spec ref(non_neg_integer() | nil, point()) :: ref()
  def ref(nil, {ref, _s, _y}), do: ref
  def ref(v, {i, _s, _y}), do: {v, i}

  @doc """
  The rows at `refs` (`{view, row}`, any order) gathered from their views, in input order,
  each view's run named by `key` and the rows taken: a table of the input's columns.
  """
  @spec gather([Table.view()], [{non_neg_integer(), non_neg_integer()}], Table.t(), term()) ::
          Table.t()
  def gather(views, refs, input, key) do
    # Sorted once, each once (a natural merge sort, so refs nearly in order cost about a
    # pass), then split by view.
    by_view =
      refs
      |> :lists.usort()
      |> Enum.chunk_by(&elem(&1, 0))
      |> Map.new(fn [{v, _} | _] = refs -> {v, Enum.map(refs, &elem(&1, 1))} end)

    kept =
      for {{chunk, first, count}, v} <- Enum.with_index(views),
          rows = by_view[v],
          rows != nil do
        {Chunk.gather(chunk, first, count, rows, {key, rows}), 0, length(rows)}
      end

    header = for name <- Table.names(input), do: {name, Table.column_type(input, name)}
    {:ok, table} = Table.from_chunks(header, kept, sorted: Table.sorted(input))
    table
  end
end
