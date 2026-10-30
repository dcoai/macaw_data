defmodule Macaw.Data.Operations.Transforms.Window do
  @moduledoc """
  `window` (spec/04 §4.3): the rows whose reading of `field` lies in
  `[now − from, now − to)`, in order. A given `to` is exclusive, an absent `to` closes the
  window at `now` inclusively, an absent `from` is open, so adjacent windows partition a
  column. `now` is the context's, else the newest reading. With `latest`, each declared
  identity's newest row of them (`Macaw.Data.Window.latest_rows/3`).
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.{Schema, Table}
  alias Macaw.Data.Operations.{Option, Step, Transforms}
  alias Macaw.Data.Table.Chunk

  @impl true
  def name, do: "window"

  @impl true
  def options do
    [
      {"field", %Option{type: :field, required: true, doc: "the time column"}},
      {"from", %Option{type: :duration, default: nil, doc: "the old end, a duration ago"}},
      {"to",
       %Option{type: :duration, default: nil, doc: "the new end, a duration ago, exclusive"}},
      {"latest", %Option{type: :boolean, default: false, doc: "each identity's newest row"}}
    ]
  end

  @impl true
  def needs, do: []

  @impl true
  def outputs(_node, columns), do: columns

  @impl true
  def run(%{"latest" => true} = node, table, context), do: run_latest(node, table, context)
  def run(node, table, context), do: Step.run(__MODULE__, node, table, context)

  # Without `latest`, a per-row step (spec/04 §1.4): a chunk wholly inside the window
  # passes through, one wholly outside is dropped, and only an edge chunk is cut, a sorted
  # window field binary-searched and any other column scanned. With it, a combine.
  @impl true
  def class(%{"latest" => true}), do: :combine
  def class(_node), do: :row

  @impl true
  def reads, do: [:now, :schema]

  # The window's bounds over the whole input, once: `now` the context's, else the newest
  # reading, found from the end of a sorted column or by a scan of any other.
  @impl true
  def bind(%{"field" => field, "from" => from, "to" => to}, table, context) do
    name = Transforms.name_in(Table.names(table), field)
    sorted? = name != nil and Table.sorted(table) == name

    now =
      cond do
        name == nil -> nil
        Map.get(context, :now) == nil -> newest(Table.chunks(table), name, field, sorted?)
        true -> Transforms.seconds!(context.now, field, name())
      end

    if now do
      lo = if from, do: now - seconds(from), else: :open
      hi = if to, do: {:below, now - seconds(to)}, else: {:through, now}
      %{bounds: {lo, hi}, name: name, field: field, sorted?: sorted?}
    else
      %{bounds: nil}
    end
  end

  # The context as it resolves for a chunk: `:all` or `:none` when the chunk lies wholly
  # inside or outside the window, so its key holds no `now`; else its slice bounds, a run
  # of a sorted column, or the window over any other.
  @impl true
  def resolve(_node, _view, %{bounds: nil}), do: :none

  def resolve(_node, {_chunk, _first, count} = view, %{bounds: {lo, hi}, sorted?: true} = bound) do
    read = fn i -> reading_at(view, i, bound) end
    k = first_where(0, count, &(read.(&1) == nil))
    a = if lo == :open, do: 0, else: first_where(0, k, &(read.(&1) >= lo))
    b = first_where(a, k, &(not within?(read.(&1), hi)))

    cond do
      a >= b -> :none
      a == 0 and b == count -> :all
      true -> {:run, a, b - a}
    end
  end

  def resolve(_node, view, %{bounds: {lo, hi}, name: name, field: field}) do
    readings = readings(view, name, field)

    case Enum.reject(readings, &is_nil/1) do
      [] ->
        :none

      present ->
        {least, greatest} = Enum.min_max(present)

        cond do
          not inside?(greatest, lo) or not within?(least, hi) ->
            :none

          length(present) == length(readings) and inside?(least, lo) and within?(greatest, hi) ->
            :all

          true ->
            {:between, name, field, lo, hi}
        end
    end
  end

  @impl true
  def chunk(_node, {_chunk, _first, count} = view, {:between, name, field, lo, hi}) do
    view
    |> readings(name, field)
    |> Enum.with_index()
    |> Enum.flat_map(fn {at, i} ->
      if at != nil and inside?(at, lo) and within?(at, hi), do: [i], else: []
    end)
    |> Transforms.selection(count)
  end

  def chunk(_node, _view, selection), do: selection

  # A sorted column's reading at row `i` of the view, in seconds; `nil` for a gap, which a
  # sorted column holds only after its readings.
  defp reading_at({chunk, first, _count}, i, %{name: name, field: field}) do
    case Chunk.at(chunk, name, first + i) do
      nil -> nil
      value -> Transforms.seconds!(value, field, name())
    end
  end

  # The first index in `lo..hi - 1` where `true?` holds, `hi` when none does; `true?` holds
  # from some index on (a binary search).
  defp first_where(lo, hi, _true?) when lo >= hi, do: hi

  defp first_where(lo, hi, true?) do
    mid = div(lo + hi, 2)
    if true?.(mid), do: first_where(lo, mid, true?), else: first_where(mid + 1, hi, true?)
  end

  defp readings(view, name, field) do
    view
    |> Transforms.view_values(name)
    |> Enum.map(fn
      nil -> nil
      value -> Transforms.seconds!(value, field, name())
    end)
  end

  # The newest reading, in seconds: a sorted column's last before its gaps, read from the
  # last chunk that has one; any other column's greatest, every reading read.
  defp newest(views, name, field, true) do
    bound = %{name: name, field: field}

    views
    |> Enum.reverse()
    |> Enum.find_value(fn {_chunk, _first, count} = view ->
      k = first_where(0, count, &(reading_at(view, &1, bound) == nil))
      if k > 0, do: reading_at(view, k - 1, bound)
    end)
  end

  defp newest(views, name, field, false) do
    views
    |> Enum.flat_map(&readings(&1, name, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp inside?(_at, :open), do: true
  defp inside?(at, lo), do: at >= lo

  defp within?(at, {:through, hi}), do: at <= hi
  defp within?(at, {:below, hi}), do: at < hi

  defp seconds([n, unit]), do: n * Keyword.fetch!(Option.units(), unit)

  # `latest` over the rows the window selects, by the declared identity: the rows' path
  # until the combine of spec/04 §1.4 takes it over.
  defp run_latest(%{"field" => field} = node, table, context) do
    selected = Step.run(__MODULE__, %{node | "latest" => false}, table, context)

    selected
    |> Table.rows()
    |> Enum.flat_map(fn row ->
      case Table.get(row, field) do
        nil -> []
        reading -> [{row, Transforms.seconds!(reading, field, name())}]
      end
    end)
    |> latest(Map.get(context, :schema))
    |> Transforms.answer(__MODULE__, node, table)
  end

  # Each identity the schema declares, never an inferred one (spec/04 §4.3).
  defp latest(selected, %Schema{} = schema) do
    Schema.identity(schema) != [] ||
      raise ArgumentError,
            "transform \"window\": latest over a schema that declares no identity (spec/04 §4.3)"

    selected
    |> Macaw.Data.Window.latest_rows(&elem(&1, 1), &Schema.identity(schema, elem(&1, 0)))
    |> Enum.map(&elem(&1, 0))
  end

  defp latest(_selected, _no_schema) do
    raise ArgumentError,
          "transform \"window\": latest needs the schema of its rows in the context, whose " <>
            "declared identity it groups by (spec/04 §4.3)"
  end
end

defmodule Macaw.Data.Operations.Transforms.Lttb do
  @moduledoc """
  `lttb` (spec/04 §4.4): shape-preserving downsampling by Largest-Triangle-Three-Buckets
  (`Macaw.Data.Reduce.lttb/3`) to `n` rows, whole rows kept, gaps passing through. `n` is
  frame-bound: `"plot"` is the plot's width in whole pixels. A reducer (spec/04 §7).
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.{Reduce, Table}
  alias Macaw.Data.Operations.{Option, Transforms}

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
  def run(%{"fields" => fields, "n" => n} = node, table, _context) do
    table
    |> Table.rows()
    |> Reduce.lttb(n, Transforms.point_reader(name(), fields))
    |> Transforms.answer(__MODULE__, node, table)
  end
end

defmodule Macaw.Data.Operations.Transforms.M4 do
  @moduledoc """
  `m4` (spec/04 §4.5): per pixel column the first, last, least and greatest rows
  (`Macaw.Data.Reduce.m4/3`), deduplicated in order, so every column's extremes survive.
  `width` is frame-bound. A reducer (spec/04 §7).
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.{Reduce, Table}
  alias Macaw.Data.Operations.{Option, Transforms}

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
  def run(%{"fields" => fields, "width" => width} = node, table, _context) do
    table
    |> Table.rows()
    |> Reduce.m4(width, Transforms.point_reader(name(), fields))
    |> Transforms.answer(__MODULE__, node, table)
  end
end
