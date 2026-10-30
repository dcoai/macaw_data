defmodule Macaw.Data.Operations.Transforms.Bin do
  @moduledoc """
  `bin` (spec/04 §4.9): the readings of `field`, `nil`s dropped, in bins over their
  extent: `n` equal-width bins for an integer `thresholds`, else at the inner thresholds
  given. A reading belongs to the first bin `[x0, x1)` holding it, or to the last when it
  is the extent's maximum. One row per bin: `x0`, `x1`, `y0` (`0`), `as` (the bin's count,
  or with `fn` the named aggregate of its readings) and `values`.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.{Operations, Table}
  alias Macaw.Data.Operations.{Option, Step, Transforms}
  alias Macaw.Data.Operations.Transforms.Aggregate

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
  def run(node, table, context), do: Step.run(__MODULE__, node, table, context)

  # A combine (spec/04 §1.4) counting, or reducing by an aggregate with the combining form:
  # the bins are bound over the whole input's extent once, each chunk's readings are
  # binned into per-bin states, and the states merge. With any other aggregate (median,
  # quantile, distinct, …), a global step: each chunk's readings binned, and every bin's
  # readings reduced at once in the merge.
  @impl true
  def class(%{"fn" => nil}), do: :combine
  def class(%{"fn" => aggregate}), do: Aggregate.group_class(aggregate)

  @impl true
  def reads, do: []

  @impl true
  def bind(%{"field" => field, "thresholds" => thresholds}, table, _context) do
    name = Transforms.name_in(Table.names(table), field)

    extent =
      table
      |> Table.chunks()
      |> Enum.reduce(nil, fn view, extent ->
        view
        |> Transforms.view_values(name)
        |> Enum.reduce(extent, fn
          nil, extent -> extent
          v, nil -> {Transforms.number!(v, field, name()), v}
          v, {lo, hi} -> {min(lo, Transforms.number!(v, field, name())), max(hi, v)}
        end)
      end)

    %{name: name, field: field, edges: edges(extent, thresholds)}
  end

  @impl true
  def resolve(_node, _view, bound), do: bound

  # One chunk's bins, under the edges they were binned by: per bin its state (a count, or
  # the aggregate's) and its readings in order, reversed.
  @impl true
  def chunk(node, view, %{name: name, field: field, edges: edges}) do
    {first, rest} = bin_state(node)
    last = tuple_size(edges) - 1

    bins =
      view
      |> Transforms.view_values(name)
      |> Enum.reduce(%{}, fn
        nil, bins ->
          bins

        value, bins ->
          value = Transforms.number!(value, field, name())

          case bin_of(edges, value, last) do
            nil ->
              bins

            i ->
              Map.update(bins, i, {rest.(first, value), [value]}, fn {state, values} ->
                {rest.(state, value), [value | values]}
              end)
          end
      end)

    {edges, bins}
  end

  @impl true
  def combine(node, {edges, a}, {_edges, b}) do
    merge = bin_merge(node)

    {edges,
     Map.merge(a, b, fn _i, {state_a, values_a}, {state_b, values_b} ->
       {merge.(state_a, state_b), values_b ++ values_a}
     end)}
  end

  @impl true
  def finish(node, partial, %{input: input, key: key}) do
    merged =
      case {class(node), partial} do
        {:global, []} -> nil
        {:global, [first | rest]} -> Enum.reduce(rest, first, &combine(node, &2, &1))
        {:combine, merged} -> merged
      end

    {edges, merged} = merged || {{}, %{}}
    {first, _step} = bin_state(node)
    value = bin_value(node)

    bins =
      for i <- 0..(tuple_size(edges) - 1)//1 do
        {x0, x1} = elem(edges, i)
        {state, values} = Map.get(merged, i, {first, []})
        values = Enum.reverse(values)
        {x0, x1, value.(state, values), values}
      end

    columns = outputs(node, Operations.columns(input))

    values = [
      Enum.map(bins, &elem(&1, 0)),
      Enum.map(bins, &elem(&1, 1)),
      Enum.map(bins, fn _ -> 0 end),
      Enum.map(bins, &elem(&1, 2)),
      Enum.map(bins, &elem(&1, 3))
    ]

    Step.output(input, key, Enum.zip_with(columns, values, fn {n, t}, v -> {n, t, v} end))
  end

  # The bins over the extent `{d0, d1}`: `n` equal-width ones, or at the inner thresholds
  # given, as a tuple of `{x0, x1}`; none without readings.
  defp edges(nil, _thresholds), do: {}

  defp edges({d0, d1}, thresholds) do
    inner =
      case thresholds do
        n when is_integer(n) -> for i <- 1..(n - 1)//1, do: d0 + i * (d1 - d0) / n
        list -> list
      end

    ([d0] ++ inner ++ [d1])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [x0, x1] -> {x0, x1} end)
    |> List.to_tuple()
  end

  # The first bin `[x0, x1)` holding the value, or the last when it is the last bin's x1.
  defp bin_of(edges, value, last) do
    Enum.find(0..last//1, fn i ->
      {x0, x1} = elem(edges, i)
      value >= x0 and value < x1
    end) || if(last >= 0 and value == elem(elem(edges, last), 1), do: last)
  end

  # A bin's state: its first state and the state after one more reading; none for an
  # aggregate without the combining form, whose bins keep their readings alone.
  defp bin_state(%{"fn" => nil}), do: {0, fn n, _value -> n + 1 end}

  defp bin_state(%{"fn" => aggregate} = node) do
    case Aggregate.group_class(aggregate) do
      :combine ->
        options = options(node, aggregate)
        {aggregate.init(options), &aggregate.step(&1, &2, options)}

      :global ->
        {nil, fn nil, _value -> nil end}
    end
  end

  defp bin_merge(%{"fn" => nil}), do: &(&1 + &2)

  defp bin_merge(%{"fn" => aggregate} = node) do
    case Aggregate.group_class(aggregate) do
      :combine ->
        options = options(node, aggregate)
        &aggregate.merge(&1, &2, options)

      :global ->
        fn nil, nil -> nil end
    end
  end

  # A bin's value: its count, its state finished, or its readings reduced at once.
  defp bin_value(%{"fn" => nil}), do: fn n, _values -> n end

  defp bin_value(%{"fn" => aggregate} = node) do
    options = options(node, aggregate)

    case Aggregate.group_class(aggregate) do
      :combine -> fn state, _values -> aggregate.finish(state, options) end
      :global -> fn nil, values -> aggregate.reduce(values, options) end
    end
  end

  defp options(node, aggregate), do: Map.take(node, Enum.map(aggregate.options(), &elem(&1, 0)))
end

defmodule Macaw.Data.Operations.Transforms.Stack do
  @moduledoc """
  `stack` (spec/04 §4.8): d3-shape's stack (`Macaw.Data.Stack`) over the series `fields`,
  in the order and with the offset given, a `nil` reading `0`. One row per series in
  `fields` order, per datum in data order: the datum's columns plus `key`, `series` (its
  stacking position, 0 the bottom), `value`, `y0` and `y1`.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.{Operations, Table}
  alias Macaw.Data.Operations.{Option, Step, Transforms}

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
  def run(node, table, context), do: Step.run(__MODULE__, node, table, context)

  # A global step and a reshape (spec/04 §1.4): each chunk's part is its readings of the
  # series; the offsets are stacked across every row, and the datum's columns gathered at
  # repeated indexes, one row per series per datum, beside the added ones.
  @impl true
  def class(_node), do: :global

  @impl true
  def reads, do: []

  @impl true
  def bind(%{"fields" => fields}, table, _context) do
    names = Table.names(table)
    %{fields: Enum.map(fields, &{&1, Transforms.name_in(names, &1)})}
  end

  @impl true
  def resolve(_node, _view, %{fields: fields}), do: fields

  @impl true
  def chunk(_node, view, fields) do
    for {field, name} <- fields do
      view
      |> Transforms.view_values(name)
      |> Enum.map(fn
        nil -> nil
        reading -> Transforms.number!(reading, field, name())
      end)
    end
  end

  @impl true
  def finish(%{"fields" => fields, "order" => order, "offset" => offset} = node, partials, at) do
    %{input: input, key: key} = at
    sizes = Enum.map(partials, fn [first | _] -> length(first) end)
    readings = Enum.zip_with([List.duplicate([], length(fields)) | partials], &Enum.concat/1)
    by_field = fields |> Enum.zip(Enum.map(readings, &List.to_tuple/1)) |> Map.new()
    count = Enum.sum(sizes)
    {keys, order} = order(order, fields, by_field, count)

    series =
      Macaw.Data.Stack.new()
      |> Macaw.Data.Stack.keys(keys)
      |> Macaw.Data.Stack.value(fn j, field -> elem(by_field[field], j) || 0 end)
      |> Macaw.Data.Stack.order(order)
      |> Macaw.Data.Stack.offset(offset)
      |> Macaw.Data.Stack.series(Enum.to_list(0..(count - 1)//1))

    by_key = Map.new(series, &{&1.key, &1})
    places = places(sizes)

    stacked =
      for key <- fields,
          s = Map.get(by_key, key),
          s != nil,
          point <- s.points,
          do: {elem(places, point.data), key, s.index, point}

    added = %{
      "key" => Enum.map(stacked, &elem(&1, 1)),
      "series" => Enum.map(stacked, &elem(&1, 2)),
      "value" => Enum.map(stacked, &elem(&1, 3).value),
      "y0" => Enum.map(stacked, &elem(&1, 3).y0),
      "y1" => Enum.map(stacked, &elem(&1, 3).y1)
    }

    columns = outputs(node, Operations.columns(input))
    Step.gather(input, Enum.map(stacked, &elem(&1, 0)), columns, added, key)
  end

  # Each row of the input as `{view, row}`, by its place.
  defp places(sizes) do
    sizes
    |> Enum.with_index()
    |> Enum.flat_map(fn {n, v} -> for i <- 0..(n - 1)//1, do: {v, i} end)
    |> List.to_tuple()
  end

  defp order(:inside_out, fields, _by_field, _count), do: {fields, :insideout}

  # d3's stackOrderAppearance: series in ascending order of the index of their peak.
  defp order(:appearance, fields, by_field, count),
    do: {Enum.sort_by(fields, &peak(by_field[&1], count)), :none}

  # A fixed order names the keys by spelling; the stack matches them as `fields` spells them.
  defp order({:keys, listed}, fields, _by_field, _count) do
    spelled = Map.new(fields, &{Transforms.spell(&1), &1})
    {fields, {:keys, for(key <- listed, field = spelled[Transforms.spell(key)], do: field)}}
  end

  defp order(order, fields, _by_field, _count), do: {fields, order}

  defp peak(_readings, 0), do: 0

  defp peak(readings, count) do
    0..(count - 1)
    |> Enum.map(&{elem(readings, &1) || 0, &1})
    |> Enum.max_by(fn {v, _i} -> v end)
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

  alias Macaw.Data.{FFT, Table}
  alias Macaw.Data.Operations.{Option, Step, Transforms}

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
  def run(node, table, context), do: Step.run(__MODULE__, node, table, context)

  # A global step (spec/04 §1.4): each chunk's part is its readings of the field and the
  # time column; the FFT runs over the newest samples of every chunk.
  @impl true
  def class(_node), do: :global

  @impl true
  def reads, do: []

  @impl true
  def bind(%{"field" => field, "time" => time}, table, _context) do
    names = Table.names(table)
    %{field: Transforms.name_in(names, field), time: time && Transforms.name_in(names, time)}
  end

  @impl true
  def resolve(_node, _view, bound), do: bound

  @impl true
  def chunk(_node, view, %{field: field, time: time}) do
    times = if time, do: Transforms.view_values(view, time), else: nil
    {Transforms.view_values(view, field), times}
  end

  @impl true
  def finish(node, partials, %{input: input, key: key}) do
    {frequency, magnitude, phase} = names(node["as"])
    readings = Enum.flat_map(partials, &elem(&1, 0))

    times =
      if node["time"],
        do: Enum.flat_map(partials, &(elem(&1, 1) || List.duplicate(nil, length(elem(&1, 0))))),
        else: List.duplicate(nil, length(readings))

    sampled = for {v, t} <- Enum.zip(readings, times), is_number(v), do: {v, t}
    every = node["every"] || median_gap(Enum.map(sampled, &elem(&1, 1)), node["time"]) || 1

    options =
      Enum.reject(
        [samples: node["samples"], window: node["window"], detrend: node["detrend"]],
        fn {_key, value} -> value == nil end
      )

    lines = sampled |> Enum.map(&elem(&1, 0)) |> FFT.spectrum(every, options)

    columns =
      [{frequency, Enum.map(lines, & &1.frequency)}, {magnitude, Enum.map(lines, & &1.magnitude)}] ++
        if(phase, do: [{phase, Enum.map(lines, & &1.phase)}], else: [])

    Step.output(input, key, for({name, values} <- columns, do: {name, :number, values}))
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
  defp median_gap(_times, nil), do: nil

  defp median_gap(times, _time) do
    gaps =
      times
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
