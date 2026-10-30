defmodule Macaw.Data.Operations.Transforms.Filter do
  @moduledoc """
  `filter` (spec/04 §4.1): the rows, in order, whose reading of `field` passes `test`
  against `value`. `present` and `absent` test `nil`; `eq` and `ne` compare with a
  category one value whichever spelling it has (`Macaw.Data.Operations.same?/2`); the
  orderings compare under term order, and a `nil` reading never passes one.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.{Operations, Table}
  alias Macaw.Data.Operations.{Option, Step, Transforms}

  @tests [:eq, :ne, :lt, :lte, :gt, :gte, :present, :absent]

  @impl true
  def name, do: "filter"

  @impl true
  def options do
    [
      {"field", %Option{type: :field, required: true, doc: "the column tested"}},
      {"test",
       %Option{type: {:enum, @tests}, default: :present, doc: "how the reading is tested"}},
      {"value", %Option{type: :term, default: nil, doc: "what the reading is tested against"}}
    ]
  end

  @impl true
  def needs, do: []

  @impl true
  def outputs(_node, columns), do: columns

  @impl true
  def run(node, table, context), do: Step.run(__MODULE__, node, table, context)

  # A per-row step (spec/04 §1.4): each chunk decided from the one column it reads.
  @impl true
  def class(_node), do: :row

  @impl true
  def reads, do: []

  @impl true
  def bind(%{"field" => field}, table, _context),
    do: %{name: Transforms.name_in(Table.names(table), field)}

  @impl true
  def resolve(_node, _view, %{name: name}), do: name

  @impl true
  def chunk(%{"test" => test, "value" => value}, {_chunk, _first, count} = view, name) do
    view
    |> Transforms.view_values(name)
    |> Enum.with_index()
    |> Enum.flat_map(fn {reading, i} -> if passes?(test, reading, value), do: [i], else: [] end)
    |> Transforms.selection(count)
  end

  defp passes?(:present, reading, _value), do: reading != nil
  defp passes?(:absent, reading, _value), do: reading == nil
  defp passes?(:eq, reading, value), do: Operations.same?(reading, value)
  defp passes?(:ne, reading, value), do: not Operations.same?(reading, value)
  defp passes?(_ordering, nil, _value), do: false
  defp passes?(:lt, reading, value), do: reading < value
  defp passes?(:lte, reading, value), do: reading <= value
  defp passes?(:gt, reading, value), do: reading > value
  defp passes?(:gte, reading, value), do: reading >= value
end

defmodule Macaw.Data.Operations.Transforms.Take do
  @moduledoc """
  `take` (spec/04 §4.2): the last `n` rows, or the first with `side: :start`; `n` at or
  above the count is every row and zero is none.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.Operations.{Option, Step}

  @impl true
  def name, do: "take"

  @impl true
  def options do
    [
      {"n", %Option{type: {:integer, 0}, required: true, doc: "the row count"}},
      {"side", %Option{type: {:enum, [:end, :start]}, default: :end, doc: "which end"}}
    ]
  end

  @impl true
  def needs, do: []

  @impl true
  def outputs(_node, columns), do: columns

  @impl true
  def run(node, table, context), do: Step.run(__MODULE__, node, table, context)

  # A per-row step (spec/04 §1.4) that reads no column: each chunk's run is decided by
  # where the chunk sits, so a chunk it does not return is never read.
  @impl true
  def class(_node), do: :row

  @impl true
  def reads, do: []

  @impl true
  def resolve(%{"n" => n, "side" => side}, {_chunk, _first, count}, %{at: at, rows: rows}) do
    {lo, hi} = if side == :end, do: {max(rows - n, 0), rows}, else: {0, min(n, rows)}
    a = max(lo, at) - at
    b = min(hi, at + count) - at

    cond do
      b <= a -> :none
      a == 0 and b == count -> :all
      true -> {:run, a, b - a}
    end
  end

  @impl true
  def chunk(_node, _view, selection), do: selection
end

defmodule Macaw.Data.Operations.Transforms.Sort do
  @moduledoc """
  `sort` (spec/04 §4.6): the rows stably sorted by the reading of `field` under term
  order, ascending or descending.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.{Operations, Table}
  alias Macaw.Data.Operations.{Option, Step, Transforms}

  @impl true
  def name, do: "sort"

  @impl true
  def options do
    [
      {"field", %Option{type: :field, required: true, doc: "the column sorted by"}},
      {"order",
       %Option{
         type: {:enum, [:ascending, :descending]},
         default: :ascending,
         doc: "the direction"
       }}
    ]
  end

  @impl true
  def needs, do: []

  @impl true
  def outputs(_node, columns), do: columns

  @impl true
  def run(node, table, context), do: Step.run(__MODULE__, node, table, context)

  # A global step (spec/04 §1.4): each chunk's part is its readings of the field; the
  # merge sorts every row of every chunk stably and gathers them across the chunks.
  @impl true
  def class(_node), do: :global

  @impl true
  def reads, do: []

  @impl true
  def bind(%{"field" => field}, table, _context),
    do: %{name: Transforms.name_in(Table.names(table), field)}

  @impl true
  def resolve(_node, _view, %{name: name}), do: name

  @impl true
  def chunk(_node, view, name), do: Transforms.view_values(view, name)

  @impl true
  def finish(%{"order" => order} = node, partials, %{input: input, key: key}) do
    direction = if order == :descending, do: :desc, else: :asc

    picks =
      partials
      |> Enum.with_index()
      |> Enum.flat_map(fn {readings, v} ->
        readings |> Enum.with_index() |> Enum.map(fn {reading, i} -> {reading, {v, i}} end)
      end)
      |> Enum.sort_by(&elem(&1, 0), direction)
      |> Enum.map(&elem(&1, 1))

    columns = outputs(node, Operations.columns(input))
    Step.gather(input, picks, columns, %{}, key)
  end
end

defmodule Macaw.Data.Operations.Transforms.Fold do
  @moduledoc """
  `fold` (spec/04 §4.7): wide columns to long rows, one per input row per listed column
  the row has, in row then `fields` order; the row's other columns carried, the folded
  ones dropped by spelling; the column's name under the first name of `as`, its value
  under the second. A listed column the rows lack, and a `nil` reading, yield no row.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.Operations.{Option, Step, Transforms}
  alias Macaw.Data.Table

  @impl true
  def name, do: "fold"

  @impl true
  def options do
    [
      {"fields", %Option{type: {:list, :field}, required: true, doc: "the columns folded"}},
      {"as",
       %Option{type: {:pair, :name}, default: ["key", "value"], doc: "the key and value columns"}}
    ]
  end

  @impl true
  def needs, do: []

  @impl true
  def outputs(%{"fields" => fields, "as" => [key, value]}, columns) do
    folded = MapSet.new(fields, &Transforms.spell/1)

    {gone, kept} =
      Enum.split_with(columns, fn {name, _} -> MapSet.member?(folded, Transforms.spell(name)) end)

    value_type =
      case gone |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
        [type] -> type
        _none_or_many -> :term
      end

    Transforms.put_columns(kept, [{key, :category}, {value, value_type}])
  end

  @impl true
  def run(node, table, context), do: Step.run(__MODULE__, node, table, context)

  # A per-row reshape (spec/04 §1.4): each chunk's rows repeated once per listed column
  # each holds, the carried columns gathered at the repeated indexes and the key and
  # value columns added.
  @impl true
  def class(_node), do: :row

  @impl true
  def reads, do: []

  @impl true
  def bind(%{"fields" => fields}, table, _context) do
    names = Table.names(table)
    %{fields: for(field <- fields, name = Transforms.name_in(names, field), do: {field, name})}
  end

  @impl true
  def resolve(_node, _view, %{fields: fields}), do: fields

  @impl true
  def chunk(%{"as" => [key, value]}, view, fields) do
    columns =
      for {field, name} <- fields, do: {field, List.to_tuple(Transforms.view_values(view, name))}

    {_chunk, _first, count} = view

    picked =
      for i <- 0..(count - 1)//1,
          {field, readings} <- columns,
          (reading = elem(readings, i)) != nil,
          do: {i, field, reading}

    {:reshape, Enum.map(picked, &elem(&1, 0)),
     %{key => Enum.map(picked, &elem(&1, 1)), value => Enum.map(picked, &elem(&1, 2))}}
  end
end
