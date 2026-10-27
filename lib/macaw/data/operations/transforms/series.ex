defmodule Macaw.Data.Operations.Transforms.Bin do
  @moduledoc """
  `bin` (spec/04 §4.9): the readings of `field`, `nil`s dropped, in bins over their
  extent: `n` equal-width bins for an integer `thresholds`, else at the inner thresholds
  given. A reading belongs to the first bin `[x0, x1)` holding it, or to the last when it
  is the extent's maximum. One row per bin: `x0`, `x1`, `y0` (`0`), `as` (the bin's count,
  or with `fn` the named aggregate of its readings) and `values`.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.Operations
  alias Macaw.Data.Operations.{Option, Transforms}

  @impl true
  def name, do: "bin"

  @impl true
  def options do
    [
      Transforms.field_option(),
      {"thresholds",
       %Option{
         type: {:one_of, [{:integer, 1}, {:list, :number}]},
         default: 10,
         doc: "a bin count, or the inner thresholds"
       }},
      {"as", %Option{type: :name, default: "count", doc: "the bin value's column"}},
      {"fn",
       %Option{
         type: :aggregate,
         default: nil,
         doc: "the aggregate of each bin's readings; a count without one"
       }}
    ]
  end

  @impl true
  def needs, do: []

  @impl true
  def outputs(%{"as" => as} = node, _columns) do
    value_type = if node["fn"], do: node["fn"].output(:number, %{}), else: :number
    [{"x0", :number}, {"x1", :number}, {"y0", :number}, {as, value_type}, {"values", :term}]
  end

  @impl true
  def run(%{"field" => field, "thresholds" => thresholds, "as" => as} = node, table, _context) do
    values =
      table
      |> Transforms.column(field)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Transforms.number!(&1, field, name()))

    reduce = reducer(node)

    values
    |> bins(thresholds)
    |> Enum.map(fn bin ->
      %{"x0" => bin.x0, "x1" => bin.x1, "y0" => 0, "values" => bin.values}
      |> Map.put(as, reduce.(bin.values))
    end)
    |> Operations.table(outputs(node, Operations.columns(table)))
  end

  defp reducer(%{"fn" => nil}), do: &length/1

  defp reducer(%{"fn" => aggregate} = node) do
    options = Map.take(node, Enum.map(aggregate.options(), &elem(&1, 0)))
    &aggregate.reduce(&1, options)
  end

  # visualize's `Visualize.Data.bin/2`: the bins over the extent, each holding its readings
  # in input order.
  defp bins([], _thresholds), do: []

  defp bins(values, thresholds) do
    {d0, d1} = Enum.min_max(values)

    inner =
      case thresholds do
        n when is_integer(n) -> for i <- 1..(n - 1)//1, do: d0 + i * (d1 - d0) / n
        list -> list
      end

    bins =
      ([d0] ++ inner ++ [d1])
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [x0, x1] -> %{x0: x0, x1: x1, values: []} end)

    last = length(bins) - 1

    values
    |> Enum.reduce(bins, fn value, bins ->
      index =
        Enum.find_index(bins, &(value >= &1.x0 and value < &1.x1)) ||
          if(value == List.last(bins).x1, do: last)

      if index, do: List.update_at(bins, index, &%{&1 | values: [value | &1.values]}), else: bins
    end)
    |> Enum.map(&%{&1 | values: Enum.reverse(&1.values)})
  end
end

defmodule Macaw.Data.Operations.Transforms.Stack do
  @moduledoc """
  `stack` (spec/04 §4.8): d3-shape's stack (`Macaw.Data.Stack`) over the series `fields`,
  in the order and with the offset given, a `nil` reading `0`. One row per series in
  `fields` order, per datum in data order: the datum's columns plus `key`, `series` (its
  stacking position, 0 the bottom), `value`, `y0` and `y1`.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.Operations.{Option, Transforms}
  alias Macaw.Data.Table

  @orders [:none, :ascending, :descending, :inside_out, :reverse, :appearance]
  @offsets [:none, :expand, :silhouette, :wiggle, :diverging]

  @impl true
  def name, do: "stack"

  @impl true
  def options do
    [
      {"fields", %Option{type: {:list, :field}, required: true, doc: "the series' keys"}},
      {"order",
       %Option{
         type: {:one_of, [{:enum, @orders}, {:keys, {:list, :field}}]},
         default: :none,
         doc: "the stacking order"
       }},
      {"offset", %Option{type: {:enum, @offsets}, default: :none, doc: "the baselines"}}
    ]
  end

  @impl true
  def needs, do: []

  @impl true
  def outputs(_node, columns) do
    Transforms.put_columns(columns, [
      {"key", :category},
      {"series", :number},
      {"value", :number},
      {"y0", :number},
      {"y1", :number}
    ])
  end

  @impl true
  def run(%{"fields" => fields, "order" => order, "offset" => offset} = node, table, _context) do
    rows = Table.rows(table)

    Enum.each(rows, fn row ->
      Enum.each(fields, fn field ->
        reading = Table.get(row, field)
        if reading != nil, do: Transforms.number!(reading, field, name())
      end)
    end)

    {keys, order} = order(order, fields, rows)

    series =
      Macaw.Data.Stack.new()
      |> Macaw.Data.Stack.keys(keys)
      |> Macaw.Data.Stack.order(order)
      |> Macaw.Data.Stack.offset(offset)
      |> Macaw.Data.Stack.generate(rows)

    by_key = Map.new(series, &{&1.key, &1})

    stacked =
      for key <- fields, s = Map.get(by_key, key), s != nil, point <- s.points do
        Map.merge(point.data, %{
          "key" => key,
          "series" => s.index,
          "value" => point.value,
          "y0" => point.y0,
          "y1" => point.y1
        })
      end

    Transforms.answer(stacked, __MODULE__, node, table)
  end

  defp order(:inside_out, fields, _rows), do: {fields, :insideout}

  # d3's stackOrderAppearance: series in ascending order of the index of their peak.
  defp order(:appearance, fields, rows), do: {Enum.sort_by(fields, &peak(rows, &1)), :none}

  # A fixed order names the keys by spelling; the stack matches them as `fields` spells them.
  defp order({:keys, listed}, fields, _rows) do
    spelled = Map.new(fields, &{Transforms.spell(&1), &1})
    {fields, {:keys, for(key <- listed, field = spelled[Transforms.spell(key)], do: field)}}
  end

  defp order(order, fields, _rows), do: {fields, order}

  defp peak(rows, key) do
    rows
    |> Enum.map(&(Table.get(&1, key) || 0))
    |> Enum.with_index()
    |> Enum.max_by(fn {v, _i} -> v end, fn -> {0, 0} end)
    |> elem(1)
  end
end

defmodule Macaw.Data.Operations.Transforms.Spectrum do
  @moduledoc """
  `spectrum` (spec/04 §4.11): a time series to its one-sided amplitude spectrum by FFT
  (`Macaw.Data.FFT.spectrum/3`). The interval is `every`, else the median positive gap of
  the `time` column, else 1; the samples are the newest power of two rows with a numeric
  reading of `field`; each row holds `as`'s names for the frequency and the magnitude, and
  a third, when `as` gives one, for the phase.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.{FFT, Operations, Table}
  alias Macaw.Data.Operations.{Option, Transforms}

  @impl true
  def name, do: "spectrum"

  @impl true
  def options do
    [
      {"field", %Option{type: :field, required: true, doc: "the sample column"}},
      {"time",
       %Option{type: :field, default: nil, doc: "the time column the interval is read from"}},
      {"every", %Option{type: :positive, default: nil, doc: "the seconds between samples"}},
      {"samples", %Option{type: :power_of_two, default: nil, doc: "the window, a power of two"}},
      {"window", %Option{type: {:enum, FFT.windows()}, default: :hann, doc: "the taper"}},
      {"detrend", %Option{type: :boolean, default: false, doc: "subtract the mean first"}},
      {"as",
       %Option{
         type: {:one_of, [{:list, :name}, :name]},
         default: ["frequency", "magnitude"],
         doc: "the lines' columns"
       }}
    ]
  end

  @impl true
  def needs, do: []

  @impl true
  def outputs(%{"as" => as}, _columns) do
    {frequency, magnitude, phase} = names(as)
    for name <- [frequency, magnitude, phase], name != nil, do: {name, :number}
  end

  @impl true
  def run(%{"field" => field} = node, table, _context) do
    {frequency, magnitude, phase} = names(node["as"])
    sampled = Enum.filter(Table.rows(table), &is_number(Table.get(&1, field)))
    every = node["every"] || median_gap(sampled, node["time"]) || 1

    options =
      Enum.reject(
        [samples: node["samples"], window: node["window"], detrend: node["detrend"]],
        fn {_key, value} -> value == nil end
      )

    sampled
    |> Enum.map(&Table.get(&1, field))
    |> FFT.spectrum(every, options)
    |> Enum.map(fn line ->
      row = %{frequency => line.frequency, magnitude => line.magnitude}
      if phase, do: Map.put(row, phase, line.phase), else: row
    end)
    |> Operations.table(outputs(node, Operations.columns(table)))
  end

  defp names([frequency, magnitude]), do: {frequency, magnitude, nil}
  defp names([frequency, magnitude, phase]), do: {frequency, magnitude, phase}
  defp names(name) when not is_list(name), do: {name, "magnitude", nil}

  defp names(other) do
    raise ArgumentError,
          "transform \"spectrum\": as names two or three columns, got #{inspect(other)} (spec/04 §4.11)"
  end

  # The median positive gap between consecutive readings of the time column: instants in
  # seconds, numbers as they are; nil without a column or with no positive gap.
  defp median_gap(_rows, nil), do: nil

  defp median_gap(rows, time) do
    gaps =
      rows
      |> Enum.map(&Table.get(&1, time))
      |> Enum.reject(&is_nil/1)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> gap(a, b) end)
      |> Enum.reject(&(is_nil(&1) or &1 <= 0))
      |> Enum.sort()

    case gaps do
      [] -> nil
      gaps -> Enum.at(gaps, div(length(gaps), 2))
    end
  end

  defp gap(%DateTime{} = a, %DateTime{} = b), do: DateTime.diff(b, a, :microsecond) / 1_000_000
  defp gap(a, b) when is_number(a) and is_number(b), do: b - a
  defp gap(_a, _b), do: nil
end
