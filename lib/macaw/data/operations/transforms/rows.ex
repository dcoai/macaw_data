defmodule Macaw.Data.Operations.Transforms.Filter do
  @moduledoc """
  `filter` (spec/04 §4.1): the rows, in order, whose reading of `field` passes `test`
  against `value`. `present` and `absent` test `nil`; `eq` and `ne` compare with a
  category one value whichever spelling it has (`Macaw.Data.Operations.same?/2`); the
  orderings compare under term order, and a `nil` reading never passes one.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.{Operations, Table}
  alias Macaw.Data.Operations.{Option, Transforms}

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
  def run(%{"field" => field, "test" => test, "value" => value} = node, table, _context) do
    table
    |> Table.rows()
    |> Enum.filter(&passes?(test, Table.get(&1, field), value))
    |> Transforms.answer(__MODULE__, node, table)
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

  alias Macaw.Data.Operations.{Option, Transforms}
  alias Macaw.Data.Table

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
  def run(%{"n" => n, "side" => side} = node, table, _context) do
    rows = Table.rows(table)
    taken = if side == :end, do: Enum.take(rows, -n), else: Enum.take(rows, n)
    Transforms.answer(taken, __MODULE__, node, table)
  end
end

defmodule Macaw.Data.Operations.Transforms.Sort do
  @moduledoc """
  `sort` (spec/04 §4.6): the rows stably sorted by the reading of `field` under term
  order, ascending or descending.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.Operations.{Option, Transforms}
  alias Macaw.Data.Table

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
  def run(%{"field" => field, "order" => order} = node, table, _context) do
    direction = if order == :descending, do: :desc, else: :asc

    table
    |> Table.rows()
    |> Enum.sort_by(&Table.get(&1, field), direction)
    |> Transforms.answer(__MODULE__, node, table)
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

  alias Macaw.Data.Operations.{Option, Transforms}
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
  def run(%{"fields" => fields, "as" => [key, value]} = node, table, _context) do
    folded = MapSet.new(fields, &Transforms.spell/1)

    rows =
      for row <- Table.rows(table), field <- fields, (reading = Table.get(row, field)) != nil do
        row
        |> Map.reject(fn {k, _v} -> MapSet.member?(folded, Transforms.spell(k)) end)
        |> Map.put(key, field)
        |> Map.put(value, reading)
      end

    Transforms.answer(rows, __MODULE__, node, table)
  end
end
