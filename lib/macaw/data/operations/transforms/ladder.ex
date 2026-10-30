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
  - **A partial** is a run of rows' buckets: per bucket the first, the last, the least
    and the greatest point, each `{ref, s, y}`, `ref` `{view, row}`; runs are split by
    gaps (a row whose x or y is `nil`), each run of gap rows kept as its first. Partials
    merge associatively in chunk order (a bucket straddling a chunk edge merges its two
    summaries; a gap on a chunk edge stays one gap), and a finer partial folds into a
    coarser level exactly (`coarsen/2`), so a zoom out reuses finer partials.
  """

  alias Macaw.Data.Table
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Operations.Transforms

  @kinds [:linear, :time, :log]
  @epoch_naive ~N[1970-01-01 00:00:00]

  @typedoc "A point of a bucket: `{ref, s, y}`, `ref` `{view, row}` in input order."
  @type point :: {{non_neg_integer(), non_neg_integer()}, number(), number()}

  @typedoc "A bucket's first, last, least and greatest points."
  @type summary :: {point(), point(), point(), point()}

  @typedoc "A partial: its level, the views its refs index, and its segments in order."
  @type partial ::
          {integer(), [Table.view()],
           [{:run, %{integer() => summary()}} | {:gap, {non_neg_integer(), non_neg_integer()}}]}

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
  def bucket(s, k) when is_integer(s) and k >= 0, do: Integer.floor_div(s, Integer.pow(2, k))
  def bucket(s, k) when is_integer(s), do: s * Integer.pow(2, -k)
  def bucket(s, k), do: floor(s / pow2(k))

  # -- partials -------------------------------------------------------------------------------

  @doc """
  One view's partial at level `k`: its rows' buckets, run by run between gaps, the view
  its points' refs name as view 0.
  """
  @spec partial(Table.view(), map(), integer(), String.t()) :: partial()
  def partial(view, %{x_name: x_name, y_name: y_name} = bound, k, op) do
    xs = Transforms.view_values(view, x_name)
    ys = Transforms.view_values(view, y_name)
    {k, [view], walk(xs, ys, 0, bound, k, op, nil, [])}
  end

  # One pass over the rows. The open bucket, `{b, summary}`, is carried until a row lands
  # in another, so rows in x order touch the run's map once a bucket.
  defp walk([], [], _i, _bound, _k, _op, open, segments),
    do: Enum.reverse(close(open, segments))

  defp walk([x | xs], [y | ys], i, bound, k, op, open, segments) when x == nil or y == nil do
    segments =
      case close(open, segments) do
        [{:gap, _} | _] = segments -> segments
        segments -> [{:gap, {0, i}} | segments]
      end

    walk(xs, ys, i + 1, bound, k, op, nil, segments)
  end

  defp walk([x | xs], [y | ys], i, bound, k, op, open, segments) do
    s = space(x, bound, op)
    point = {{0, i}, s, Transforms.number!(y, bound.y, op)}
    b = bucket(s, k)

    case open do
      {^b, {first, _last, low, high}} ->
        low = if elem(point, 2) < elem(low, 2), do: point, else: low
        high = if elem(point, 2) > elem(high, 2), do: point, else: high
        walk(xs, ys, i + 1, bound, k, op, {b, {first, point, low, high}}, segments)

      _other_or_none ->
        segments = put_open(open, segments)
        walk(xs, ys, i + 1, bound, k, op, {b, {point, point, point, point}}, segments)
    end
  end

  # The open bucket into the current run, a run started if the last segment is a gap.
  defp put_open(nil, segments), do: segments

  defp put_open({b, summary}, [{:run, buckets} | rest]),
    do: [{:run, Map.update(buckets, b, summary, &summary(&1, summary))} | rest]

  defp put_open({b, summary}, segments), do: [{:run, %{b => summary}} | segments]

  defp close(open, segments), do: put_open(open, segments)

  @doc """
  Two summaries of one bucket merged: the first and last by input order, the least and
  greatest by y, the earlier on a tie. Commutative and associative.
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
  levels: a run ending the first and a run starting the second are one run, their shared
  buckets merged; a gap ending the first and one starting the second are one gap.
  """
  @spec combine(partial(), partial()) :: partial()
  def combine({ka, views_a, segments_a}, {kb, views_b, segments_b}) do
    k = max(ka, kb)
    segments_a = coarsen_segments(segments_a, ka, k)
    segments_b = segments_b |> coarsen_segments(kb, k) |> shift(length(views_a))
    {k, views_a ++ views_b, join(segments_a, segments_b)}
  end

  defp join(a, []), do: a
  defp join([], b), do: b

  defp join(a, [first | rest] = b) do
    case {List.last(a), first} do
      {{:run, x}, {:run, y}} ->
        Enum.drop(a, -1) ++ [{:run, Map.merge(x, y, fn _b, s, t -> summary(s, t) end)} | rest]

      {{:gap, _}, {:gap, _}} ->
        a ++ rest

      _ ->
        a ++ b
    end
  end

  defp shift(segments, 0), do: segments

  defp shift(segments, by) do
    Enum.map(segments, fn
      {:gap, {v, i}} ->
        {:gap, {v + by, i}}

      {:run, buckets} ->
        {:run,
         Map.new(buckets, fn {b, {f, l, lo, hi}} ->
           {b, {move(f, by), move(l, by), move(lo, by), move(hi, by)}}
         end)}
    end)
  end

  defp move({{v, i}, s, y}, by), do: {{v + by, i}, s, y}

  @doc """
  A partial folded into a level at or above its own: each bucket into the coarser bucket
  holding it, exactly as computing the partial at that level would give it.
  """
  @spec coarsen(partial(), integer()) :: partial()
  def coarsen({k, views, segments}, to) when to >= k,
    do: {to, views, coarsen_segments(segments, k, to)}

  defp coarsen_segments(segments, k, k), do: segments

  defp coarsen_segments(segments, k, to) do
    d = Integer.pow(2, to - k)

    Enum.map(segments, fn
      {:run, buckets} ->
        {:run,
         Enum.reduce(buckets, %{}, fn {b, s}, acc ->
           Map.update(acc, Integer.floor_div(b, d), s, &summary(&1, s))
         end)}

      gap ->
        gap
    end)
  end

  @doc """
  The rows at `refs` (`{view, row}`, any order) gathered from their views, in input order,
  each view's run named by `key` and the rows taken: a table of the input's columns.
  """
  @spec gather([Table.view()], [{non_neg_integer(), non_neg_integer()}], Table.t(), term()) ::
          Table.t()
  def gather(views, refs, input, key) do
    by_view = refs |> Enum.uniq() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    kept =
      for {{chunk, first, count}, v} <- Enum.with_index(views),
          rows = by_view[v],
          rows != nil do
        rows = Enum.sort(rows)
        {Chunk.gather(chunk, first, count, rows, {key, rows}), 0, length(rows)}
      end

    header = for name <- Table.names(input), do: {name, Table.column_type(input, name)}
    {:ok, table} = Table.from_chunks(header, kept, sorted: Table.sorted(input))
    table
  end
end
