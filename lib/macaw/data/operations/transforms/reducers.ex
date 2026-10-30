defmodule Macaw.Data.Operations.Transforms.Lttb do
  @moduledoc """
  `lttb` (spec/04 §4.4): shape-preserving downsampling to `n` rows by MinMaxLTTB (Van Der
  Donckt et al., 2023), whole rows kept, gaps passing through. `n` is frame-bound:
  `"plot"` is the plot's width in whole pixels. A reducer (spec/04 §7).

  A combine (spec/04 §1.4) on the bucket ladder (`Macaw.Data.Operations.Transforms.Ladder`):
  each chunk's partial is its buckets' least and greatest points (the preselection), at the
  level whose bucket is at most `span / (2n)`, so at least `4n` candidates; the merge
  selects `n` of them, each run's first and last among them, by Largest-Triangle-Three-
  Buckets (`Macaw.Data.Reduce.lttb/3`, the exact algorithm, also its oracle).
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.{Reduce, Table}
  alias Macaw.Data.Operations.{Option, Step}
  alias Macaw.Data.Operations.Transforms.Ladder

  @impl true
  def name, do: "lttb"

  @impl true
  def options do
    [
      {"fields",
       %Option{type: {:pair, :field}, required: true, doc: "[x, y], the columns a line reads"}},
      {"n", %Option{type: {:integer, 3}, required: true, frame: :width, doc: "the rows kept"}}
    ]
  end

  @impl true
  def needs, do: []

  @impl true
  def reduces, do: {"n", 1}

  @impl true
  def outputs(_node, columns), do: columns

  @impl true
  def run(node, table, context), do: Step.run(__MODULE__, node, table, context)

  @impl true
  def class(_node), do: :combine

  @impl true
  def reads, do: [:scale, :level]

  # A chunk's part never depends on n, which only the selection reads.
  @impl true
  def keyed(node), do: Map.delete(node, "n")

  # The ladder's level for the span: buckets at most span / (2n) wide, the previous level
  # kept within a factor of 2. An input of n rows or fewer is answered whole.
  @impl true
  def bind(%{"fields" => fields, "n" => n}, table, context) do
    bound = Ladder.bind(fields, table, context, name())

    ideal =
      case bound.extent do
        {lo, hi} when hi > lo -> (hi - lo) / (2 * n)
        _point_or_none -> nil
      end

    bound
    |> Map.put(:level, Ladder.level(ideal, Map.get(context, :level)))
    |> Map.put(:whole?, Table.size(table) <= n)
  end

  # A chunk's part depends on its rows, the fields, the scale's kind and the level only.
  @impl true
  def resolve(_node, _view, bound),
    do: Map.take(bound, [:x, :y, :x_name, :y_name, :kind, :level, :whole?])

  @impl true
  def chunk(_node, view, %{whole?: true, level: k}), do: {k, [view], []}
  def chunk(_node, view, %{level: k} = bound), do: Ladder.partial(view, bound, k, name())

  @impl true
  def combine(_node, a, b), do: Ladder.combine(a, b)

  @impl true
  def finish(%{"n" => n} = node, merged, %{input: input, key: key} = at) do
    bound = bind(node, input, at.context)

    cond do
      bound.whole? ->
        input

      merged == nil ->
        Ladder.gather([], [], input, key)

      true ->
        {_k, views, segments} = Ladder.coarsen(merged, max(elem(merged, 0), bound.level))

        refs =
          segments
          |> Enum.flat_map(&candidates/1)
          |> Reduce.lttb(n, fn {_ref, s, y} -> {s, y} end)
          |> Enum.map(&elem(&1, 0))

        Ladder.gather(views, refs, input, key)
    end
  end

  # A segment's candidates in input order: a gap as itself; a run's first and last points
  # and each bucket's least and greatest.
  defp candidates({:gap, ref}), do: [{ref, nil, nil}]

  defp candidates({:run, buckets}) do
    summaries = Map.values(buckets)
    first = summaries |> Enum.map(&elem(&1, 0)) |> Enum.min_by(&elem(&1, 0))
    last = summaries |> Enum.map(&elem(&1, 1)) |> Enum.max_by(&elem(&1, 0))

    [first, last | Enum.flat_map(summaries, fn {_f, _l, lo, hi} -> [lo, hi] end)]
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 0))
  end
end

defmodule Macaw.Data.Operations.Transforms.M4 do
  @moduledoc """
  `m4` (spec/04 §4.5): per pixel column the first, last, least and greatest rows,
  deduplicated in order, so every column's extremes survive. `width` is frame-bound. A
  reducer (spec/04 §7).

  A combine (spec/04 §1.4) on the bucket ladder (`Macaw.Data.Operations.Transforms.Ladder`):
  each chunk's partial is its buckets' first, last, least and greatest points at the level
  whose bucket is at most a quarter of a pixel; the merge folds each bucket into the pixel
  column its start lies in, so the answer is exact M4 over pixel columns whose boundaries
  move to a bucket edge, at most one bucket away.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.Table
  alias Macaw.Data.Operations.{Option, Step}
  alias Macaw.Data.Operations.Transforms.Ladder

  @impl true
  def name, do: "m4"

  @impl true
  def options do
    [
      {"fields",
       %Option{type: {:pair, :field}, required: true, doc: "[x, y], the columns a line reads"}},
      {"width",
       %Option{type: {:integer, 1}, required: true, frame: :width, doc: "the pixel columns"}}
    ]
  end

  @impl true
  def needs, do: []

  @impl true
  def reduces, do: {"width", 4}

  @impl true
  def outputs(_node, columns), do: columns

  @impl true
  def run(node, table, context), do: Step.run(__MODULE__, node, table, context)

  @impl true
  def class(_node), do: :combine

  @impl true
  def reads, do: [:scale, :level]

  # A chunk's part never depends on the width, which only the folding into columns reads.
  @impl true
  def keyed(node), do: Map.delete(node, "width")

  # The ladder's level for the pixel: buckets at most a quarter of one wide, the previous
  # level kept within a factor of 2.
  @impl true
  def bind(%{"fields" => fields, "width" => width}, table, context) do
    bound = Ladder.bind(fields, table, context, name())

    ideal =
      case bound.extent do
        {lo, hi} when hi > lo -> (hi - lo) / width / 4
        _point_or_none -> nil
      end

    Map.put(bound, :level, Ladder.level(ideal, Map.get(context, :level)))
  end

  @impl true
  def resolve(_node, _view, bound), do: Map.take(bound, [:x, :y, :x_name, :y_name, :kind, :level])

  @impl true
  def chunk(_node, view, %{level: k} = bound), do: Ladder.partial(view, bound, k, name())

  @impl true
  def combine(_node, a, b), do: Ladder.combine(a, b)

  @impl true
  def finish(_node, nil, %{input: input, key: key}), do: Ladder.gather([], [], input, key)

  def finish(%{"width" => width} = node, merged, %{input: input, key: key} = at) do
    bound = bind(node, input, at.context)
    {k, views, segments} = Ladder.coarsen(merged, max(elem(merged, 0), bound.level))
    column = column_of(bound.extent, width, k)

    refs =
      Enum.flat_map(segments, fn
        {:gap, ref} ->
          [ref]

        {:run, buckets} ->
          buckets
          |> Enum.group_by(fn {b, _summary} -> column.(b) end, &elem(&1, 1))
          |> Enum.flat_map(fn {_column, summaries} ->
            {first, last, low, high} = Enum.reduce(summaries, &Ladder.summary/2)
            Enum.map([first, low, high, last], &elem(&1, 0))
          end)
      end)

    Ladder.gather(views, refs, input, key)
  end

  # The pixel column a bucket folds into: the one its start lies in, over the extent split
  # into `width` columns; every bucket column 0 when the extent is a point.
  defp column_of({lo, hi}, width, k) when hi > lo do
    fn b ->
      start = b * Ladder.pow2(k)
      (start - lo) |> Kernel./(hi - lo) |> Kernel.*(width) |> floor() |> max(0) |> min(width - 1)
    end
  end

  defp column_of(_extent, _width, _k), do: fn _b -> 0 end
end
