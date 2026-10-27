defmodule Macaw.Data.Operations.Transforms.Aggregate do
  @moduledoc """
  `aggregate` (spec/04 §4.10): one row per distinct value of `by`, in order of first
  appearance (a list of fields groups by every one, a `nil` value a group of its own),
  holding `by`'s columns and, under `as`, the named aggregate (`fn`) of the group's
  readings of `field`, `nil`s dropped; without `by`, one row of `as` alone. A pair field
  `[x, y]` reads each row as the point `[x, y]`, `x` in seconds when it is a time.

  The columns are read from the table's own storage, a packed numeric column without
  building a row list.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.Operations
  alias Macaw.Data.Operations.{Option, Transforms}

  @impl true
  def name, do: "aggregate"

  @impl true
  def options do
    [
      {"field",
       %Option{
         type: {:one_of, [:field, {:pair, :field}]},
         required: true,
         doc: "the column, or [x, y]"
       }},
      {"fn", %Option{type: :aggregate, required: true, doc: "the aggregate"}},
      {"by", %Option{type: {:one_of, [:field, {:list, :field}]}, default: nil, doc: "the group"}},
      {"as",
       %Option{
         type: :name,
         default: nil,
         doc: "the value's column; the aggregate's name by default"
       }}
    ]
  end

  @impl true
  def needs, do: []

  @impl true
  def outputs(node, columns), do: group_outputs(node, node["fn"], columns)

  @impl true
  def run(node, table, _context), do: group(node, node["fn"], table, name())

  @doc false
  # The columns of a grouping step: `by`'s, with their types, then the value's.
  def group_outputs(%{"field" => field, "by" => by, "as" => as}, aggregate, columns) do
    by_columns = for name <- by_list(by), do: {name, Transforms.type_of(columns, name)}
    input = if is_list(field), do: :term, else: Transforms.type_of(columns, field)
    by_columns ++ [{as || aggregate.name(), aggregate.output(input, %{})}]
  end

  @doc false
  def group(%{"field" => field, "by" => by, "as" => as} = node, aggregate, table, op) do
    options = Map.take(node, Enum.map(aggregate.options(), &elem(&1, 0)))
    readings = readings(table, field, op)
    by_names = by_list(by)
    keys = by_names |> Enum.map(&Transforms.column(table, &1)) |> Enum.zip_with(& &1)
    keys = if by_names == [], do: List.duplicate([], length(readings)), else: keys

    {order, groups} =
      keys
      |> Enum.zip(readings)
      |> Enum.reduce({[], %{}}, fn {key, reading}, {order, groups} ->
        order = if Map.has_key?(groups, key), do: order, else: [key | order]
        {order, Map.update(groups, key, [reading], &[reading | &1])}
      end)

    order = if order == [] and by_names == [], do: [[]], else: Enum.reverse(order)

    rows =
      for key <- order do
        values = groups |> Map.get(key, []) |> Enum.reverse() |> Enum.reject(&is_nil/1)

        by_names
        |> Enum.zip(key)
        |> Map.new()
        |> Map.put(as || aggregate.name(), aggregate.reduce(values, options))
      end

    Operations.table(rows, group_outputs(node, aggregate, Operations.columns(table)))
  end

  defp by_list(nil), do: []
  defp by_list(by) when is_list(by), do: by
  defp by_list(by), do: [by]

  # A column's readings, or each row's point [x, y], nil where either is nil.
  defp readings(table, [x, y], op) do
    Enum.zip_with(Transforms.column(table, x), Transforms.column(table, y), fn
      nil, _y -> nil
      _x, nil -> nil
      x_reading, y_reading -> [Transforms.seconds!(x_reading, x, op), y_reading]
    end)
  end

  defp readings(table, field, _op), do: Transforms.column(table, field)
end

defmodule Macaw.Data.Operations.Transforms.Sum do
  @moduledoc """
  `sum` (spec/04 §4.10): `aggregate` with `fn: "sum"`, `as` `"sum"` by default. It is
  vocabulary a design writes, not a deprecated alias.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.Operations.Aggregates
  alias Macaw.Data.Operations.Option
  alias Macaw.Data.Operations.Transforms.Aggregate

  @impl true
  def name, do: "sum"

  @impl true
  def options do
    [
      {"field", %Option{type: :field, required: true, doc: "the column summed"}},
      {"by", %Option{type: {:one_of, [:field, {:list, :field}]}, default: nil, doc: "the group"}},
      {"as", %Option{type: :name, default: "sum", doc: "the sum's column"}}
    ]
  end

  @impl true
  def needs, do: []

  @impl true
  def outputs(node, columns), do: Aggregate.group_outputs(node, Aggregates.Sum, columns)

  @impl true
  def run(node, table, _context), do: Aggregate.group(node, Aggregates.Sum, table, name())
end
