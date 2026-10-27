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
  alias Macaw.Data.Operations.{Option, Transforms}

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
  def run(
        %{"field" => field, "from" => from, "to" => to, "latest" => latest} = node,
        table,
        context
      ) do
    read =
      for row <- Table.rows(table),
          reading = Table.get(row, field),
          do: {row, Transforms.seconds!(reading, field, name())}

    selected =
      case read do
        [] ->
          []

        read ->
          now = now(Map.get(context, :now), read, field)
          lo = if from, do: now - seconds(from), else: :open
          hi = if to, do: {:below, now - seconds(to)}, else: {:through, now}
          for {_row, at} = pair <- read, lo == :open or at >= lo, within?(at, hi), do: pair
      end

    selected
    |> latest(latest, Map.get(context, :schema))
    |> Transforms.answer(__MODULE__, node, table)
  end

  defp within?(at, {:through, hi}), do: at <= hi
  defp within?(at, {:below, hi}), do: at < hi

  defp now(nil, read, _field), do: read |> Enum.map(&elem(&1, 1)) |> Enum.max()
  defp now(given, _read, field), do: Transforms.seconds!(given, field, name())

  defp seconds([n, unit]), do: n * Keyword.fetch!(Option.units(), unit)

  defp latest(selected, false, _schema), do: Enum.map(selected, &elem(&1, 0))

  # Each identity the schema declares, never an inferred one (spec/04 §4.3).
  defp latest(selected, true, %Schema{} = schema) do
    Schema.identity(schema) != [] ||
      raise ArgumentError,
            "transform \"window\": latest over a schema that declares no identity (spec/04 §4.3)"

    selected
    |> Macaw.Data.Window.latest_rows(&elem(&1, 1), &Schema.identity(schema, elem(&1, 0)))
    |> Enum.map(&elem(&1, 0))
  end

  defp latest(_selected, true, _no_schema) do
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
