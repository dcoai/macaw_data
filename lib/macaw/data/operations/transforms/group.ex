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

  alias Macaw.Data.{Operations, Table}
  alias Macaw.Data.Operations.{Option, Step, Transforms}

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
  def run(node, table, context), do: run_group(__MODULE__, node, node["fn"], table, context)

  # A combine (spec/04 §1.4) when the aggregate has the combining form; any other is
  # run whole until spec/04 §1.4's global steps take it.
  @impl true
  def class(node), do: group_class(node["fn"])

  @impl true
  def reads, do: []

  @impl true
  def bind(node, table, _context), do: group_bind(node, table)

  @impl true
  def resolve(_node, _view, bound), do: bound

  @impl true
  def chunk(node, view, bound), do: group_chunk(node, node["fn"], view, bound, name())

  @impl true
  def combine(node, a, b), do: group_combine(node["fn"], node, a, b)

  @impl true
  def finish(node, merged, at), do: group_finish(node, node["fn"], merged, at)

  # -- the grouping, a combine --------------------------------------------------------------

  @doc false
  def run_group(module, node, aggregate, table, context) do
    case group_class(aggregate) do
      :combine -> Step.run(module, node, table, context)
      :global -> group(node, aggregate, table, module.name())
    end
  end

  @doc false
  def group_class(aggregate) do
    Code.ensure_loaded!(aggregate)
    if function_exported?(aggregate, :merge, 3), do: :combine, else: :global
  end

  @doc false
  # The columns the step reads, by the names the table spells them with: the field (or the
  # pair's two) and `by`'s.
  def group_bind(%{"field" => field, "by" => by}, table) do
    names = Table.names(table)
    found = &Transforms.name_in(names, &1)

    field =
      if is_list(field), do: Enum.map(field, &{&1, found.(&1)}), else: {field, found.(field)}

    %{field: field, by: Enum.map(by_list(by), found)}
  end

  @doc false
  # One chunk's groups: their keys in order of first appearance, and each one's state of
  # the aggregate's streaming form over its readings, `nil`s dropped.
  def group_chunk(node, aggregate, {_chunk, _first, count} = view, bound, op) do
    options = options(node, aggregate)
    readings = view_readings(view, bound.field, op)

    keys =
      case bound.by do
        [] -> List.duplicate([], count)
        by -> by |> Enum.map(&Transforms.view_values(view, &1)) |> Enum.zip_with(& &1)
      end

    {order, groups} =
      keys
      |> Enum.zip(readings)
      |> Enum.reduce({[], %{}}, fn {key, reading}, {order, groups} ->
        {order, state} =
          case groups do
            %{^key => state} -> {order, state}
            _ -> {[key | order], aggregate.init(options)}
          end

        state = if reading == nil, do: state, else: aggregate.step(state, reading, options)
        {order, Map.put(groups, key, state)}
      end)

    {Enum.reverse(order), groups}
  end

  @doc false
  # Two runs' groups, the first's before the second's: keys in order of first appearance,
  # each key's states merged by the aggregate's combining form.
  def group_combine(aggregate, node, {order_a, groups_a}, {order_b, groups_b}) do
    options = options(node, aggregate)

    groups =
      Map.merge(groups_a, groups_b, fn _key, a, b -> aggregate.merge(a, b, options) end)

    {order_a ++ Enum.reject(order_b, &Map.has_key?(groups_a, &1)), groups}
  end

  @doc false
  def group_finish(%{"by" => by} = node, aggregate, merged, %{input: input, key: key}) do
    options = options(node, aggregate)
    by_names = by_list(by)
    {order, groups} = merged || {[], %{}}
    order = if order == [] and by_names == [], do: [[]], else: order
    states = Enum.map(order, &Map.get_lazy(groups, &1, fn -> aggregate.init(options) end))
    columns = group_outputs(node, aggregate, Operations.columns(input))

    values =
      Enum.with_index(by_names, fn _name, i -> Enum.map(order, &Enum.at(&1, i)) end) ++
        [Enum.map(states, &aggregate.finish(&1, options))]

    Step.output(input, key, Enum.zip_with(columns, values, fn {n, t}, v -> {n, t, v} end))
  end

  defp options(node, aggregate), do: Map.take(node, Enum.map(aggregate.options(), &elem(&1, 0)))

  # A view's readings of the field, or of the pair as points `[x, y]`, `nil` where either
  # is `nil`.
  defp view_readings(view, {_field, name}, _op), do: Transforms.view_values(view, name)

  defp view_readings(view, [{x, x_name}, {_y, y_name}], op) do
    Enum.zip_with(Transforms.view_values(view, x_name), Transforms.view_values(view, y_name), fn
      nil, _y -> nil
      _x, nil -> nil
      x_reading, y_reading -> [Transforms.seconds!(x_reading, x, op), y_reading]
    end)
  end

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
  def run(node, table, context),
    do: Aggregate.run_group(__MODULE__, node, Aggregates.Sum, table, context)

  # A combine (spec/04 §1.4): each chunk's groups summed exactly, the sums merged.
  @impl true
  def class(_node), do: :combine

  @impl true
  def reads, do: []

  @impl true
  def bind(node, table, _context), do: Aggregate.group_bind(node, table)

  @impl true
  def resolve(_node, _view, bound), do: bound

  @impl true
  def chunk(node, view, bound),
    do: Aggregate.group_chunk(node, Aggregates.Sum, view, bound, name())

  @impl true
  def combine(node, a, b), do: Aggregate.group_combine(Aggregates.Sum, node, a, b)

  @impl true
  def finish(node, merged, at), do: Aggregate.group_finish(node, Aggregates.Sum, merged, at)
end
