defmodule Macaw.Data.Source.Finish do
  @moduledoc """
  Finishing (spec/01 §2.4): Macaw does what a source did not.

  Every capability is optional. Where a source's description does not list one the
  request asks, `finish/3` does it to the delivery and reports it in `served`:

  1. `:window`: rows trimmed to the window field's range, the served window intersected;
  2. `:box`: rows trimmed to the box over the `:point` window field;
  3. `:region`: rows trimmed to each ranged field's range;
  4. `:latest`: each identity's latest row by the window field (spec/01 §1.4);
  5. `:budget`: the rows reduced to the budget by a registered reducer (`reduce/5`, spec/04
     §7), `reduced_by: :runtime`.

  The budget never widens the window: finishing only removes rows. A delivery that needs
  none of it comes back as it is.

  The pure rules of running sources (spec/01 §6) are here too: `ceiling/2` clamps a
  budget to the host's ceiling, and `pooled/1` is the one budget a pooled fetch asks for,
  the largest among its readers, each reader then reduced to its own by `reduce/5`.

  Ported from visualize's `Visualize.Feed.finish/3` and `reduce/4`.
  """

  alias Macaw.Data.{Delivery, Operations, Schema, Table, Window}
  alias Macaw.Data.Operations.{Option, Registry}
  alias Macaw.Data.Source.{Description, Request}

  @doc """
  The delivery finished for the request, each step where the description's `supports`
  lacks it. `reduce:` names the budget's reducer by spelling, a registered transform that
  declares `reduces/0` (`"lttb"`, the default, or `"m4"` in `macaw_data`'s own package),
  and `operations:` is the registry it is found in (`macaw_data`'s own by default). A name
  that is no registered reducer raises `ArgumentError` naming it (spec/04 §7).

  Raises `ArgumentError` for a request the schema cannot answer (`Window.check/2`): the
  request is the caller's.
  """
  @spec finish(Delivery.t(), Description.t(), Request.t(), keyword()) :: Delivery.t()
  def finish(delivery, description, request, opts \\ [])

  def finish(%Delivery{} = delivery, %Description{} = description, %Request{} = request, opts) do
    opts =
      opts
      |> Keyword.put_new_lazy(:operations, &Operations.registry/0)
      |> Keyword.validate!(reduce: "lttb", operations: nil)

    reducer!(opts[:operations], opts[:reduce])
    schema = description.schema

    case Window.check(request, schema) do
      :ok ->
        :ok

      {:error, faults} ->
        raise ArgumentError, "a request the schema cannot answer: #{inspect(faults)}"
    end

    supports = description.supports
    field = Schema.window_field(schema)

    delivery
    |> step(:window in supports or request.window == nil or field == nil, fn d ->
      rows = Window.trim(Delivery.named_rows(d), field, request.window)
      d |> rebuild(rows) |> serve(:window, Window.intersect(d.served.window, request.window))
    end)
    |> step(:box in supports or request.box == nil, fn d ->
      d
      |> rebuild(Window.trim_box(Delivery.named_rows(d), field, request.box))
      |> serve(:window, request.box)
    end)
    |> step(:region in supports or request.region == nil, fn d ->
      rebuild(d, Window.trim_region(Delivery.named_rows(d), request.region))
    end)
    |> step(:latest in supports or not request.latest, fn d ->
      rows =
        Window.latest_rows(
          Delivery.named_rows(d),
          &Window.position(Table.get(&1, field)),
          &Schema.identity(schema, &1)
        )

      rebuild(d, rows)
    end)
    |> step(
      :budget in supports,
      &reduce(&1, schema, request.budget, opts[:reduce], opts[:operations])
    )
  end

  defp step(delivery, true, _fun), do: delivery
  defp step(delivery, false, fun), do: fun.(delivery)

  defp serve(delivery, key, value), do: %{delivery | served: Map.put(delivery.served, key, value)}

  # Fewer rows, in the delivery's form: a table the same columns in their order and of
  # their types; any other source the rows themselves, named (macaw#185).
  defp rebuild(%Delivery{rows: %Table{} = table} = delivery, rows) do
    columns =
      for name <- Table.names(table),
          do: {name, Table.column_type(table, name), Enum.map(rows, &Map.get(&1, name))}

    %{delivery | rows: Table.new!(columns)}
  end

  defp rebuild(%Delivery{} = delivery, rows), do: %{delivery | rows: rows, names: nil}

  @doc """
  The delivery reduced to `budget` rows by the reducer `method` names in `registry`
  (spec/04 §7): `"lttb"` by default, `"m4"`, or any registered transform declaring
  `reduces/0`, by spelling; `macaw_data`'s own registry by default. It records
  `reduced_by: :runtime`. Each series (the rows sharing every `:category` field's value)
  is reduced field by field against the window field, or the row's place without one, by
  the reducer's node `%{fields: [x, y], count => c}`, `c` the budget's share in the units
  `reduces/0` counts, never below the least its option takes, and
  the union of the kept rows returned whole, in their order, never more than the budget.
  A `nil` budget, a delivery within it, and a schema with no `:number` field to reduce by
  come back as they are.

      iex> alias Macaw.Data.{Delivery, Schema, Source.Finish}
      iex> schema = Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number}})
      iex> reduced = Finish.reduce(Delivery.new(for t <- 1..100, do: %{t: t, v: rem(t * 7, 5)}), schema, 10)
      iex> {length(Delivery.rows(reduced)), reduced.served.reduced_by}
      {10, :runtime}
  """
  @spec reduce(Delivery.t(), Schema.t(), pos_integer() | nil, String.t() | atom(), Registry.t()) ::
          Delivery.t()
  def reduce(delivery, schema, budget, method \\ "lttb", registry \\ Operations.registry())

  def reduce(%Delivery{} = delivery, %Schema{}, nil, method, registry) do
    reducer!(registry, method)
    delivery
  end

  def reduce(%Delivery{} = delivery, %Schema{} = schema, budget, method, %Registry{} = registry)
      when is_integer(budget) and budget > 0 do
    method = reducer!(registry, method)
    rows = Delivery.named_rows(delivery)
    clock = Schema.window_field(schema)
    numbers = for {name, %{type: :number}} <- schema.fields, name != clock, do: name

    if length(rows) <= budget or numbers == [] do
      delivery
    else
      kept =
        rows
        |> reduced(schema, Enum.sort_by(numbers, &to_string/1), budget, method, registry)
        |> at_most(budget)

      delivery |> rebuild(kept) |> serve(:reduced_by, :runtime)
    end
  end

  defp reduced(rows, schema, numbers, budget, method, registry) do
    categories =
      Enum.sort_by(for({name, %{type: :category}} <- schema.fields, do: name), &to_string/1)

    time = Schema.window_field(schema)

    groups =
      rows
      |> Enum.with_index()
      |> Enum.group_by(fn {row, _i} -> Enum.map(categories, &Table.get(row, &1)) end)
      |> Map.values()

    share = length(groups) * length(numbers)
    node = node!(method, budget, share, registry)

    kept =
      for group <- groups, field <- numbers, reduce: MapSet.new() do
        kept ->
          group
          |> Enum.with_index()
          |> pick(time, field, node, method)
          |> Enum.reduce(kept, fn {{_row, i}, _place}, acc -> MapSet.put(acc, i) end)
      end

    for {row, i} <- Enum.with_index(rows), MapSet.member?(kept, i), do: row
  end

  # The reducer's node, checked as any node is, its defaults filled in: `fields` the x and
  # y columns, the count the budget's share in the units it counts, never below its least.
  defp node!({module, count, per, least}, budget, share, registry) do
    node = %{
      "op" => module.name(),
      "fields" => ["x", "y"],
      count => max(least, div(budget, per * share))
    }

    {:ok, [checked]} = Operations.validate(registry, [node], %{})
    checked
  end

  # One series' readings of one field, as the reducer's [x, y], reduced by its node: the
  # kept points, each with its row's index.
  defp pick(points, time, field, node, {module, _count, _per, _least}) do
    table =
      Table.new!([
        {"x", :number, Enum.map(points, &x(&1, time))},
        {"y", :term, Enum.map(points, fn {{row, _i}, _place} -> Table.get(row, field) end)},
        {"i", :number, Enum.map(points, fn {{_row, i}, _place} -> i end)}
      ])

    kept = node |> module.run(table, %{}) |> Table.column("i") |> MapSet.new()
    Enum.filter(points, fn {{_row, i}, _place} -> MapSet.member?(kept, i) end)
  end

  defp x({{_row, _i}, place}, nil), do: place
  defp x({{row, _i}, _place}, time), do: Window.position(Table.get(row, time))

  # The registered reducer `method` names: its module, its count option, the rows each unit
  # keeps and the least count its option takes; else ArgumentError naming it.
  defp reducer!(%Registry{} = registry, method) do
    name = if is_atom(method), do: Atom.to_string(method), else: method

    with true <- is_binary(name),
         {:ok, module} <- Registry.transform(registry, name),
         true <- function_exported?(module, :reduces, 0) do
      {count, per} = module.reduces()
      {^count, %Option{type: type}} = List.keyfind(module.options(), count, 0)
      {module, count, per, least(type)}
    else
      _not_a_reducer ->
        raise ArgumentError,
              "reduce: #{inspect(method)} names no registered reducer, a transform " <>
                "declaring reduces/0 (spec/04 §7)"
    end
  end

  defp least({:integer, min}), do: min
  defp least(_type), do: 1

  # Many series each keep a few rows; when their union is still over the budget, an even
  # stride over it keeps the first and the last.
  defp at_most(rows, budget) when length(rows) <= budget, do: rows

  defp at_most(rows, 1), do: [hd(rows)]

  defp at_most(rows, budget) do
    n = length(rows)
    picks = MapSet.new(0..(budget - 1), &round(&1 * (n - 1) / (budget - 1)))
    for {row, i} <- Enum.with_index(rows), MapSet.member?(picks, i), do: row
  end

  @doc """
  A budget clamped to the host's ceiling (spec/01 §6, macaw_compose 05 §1.2): `{budget,
  clamped?}`. A `nil` budget reads at the ceiling; a page's ceiling, given as `page:`,
  may lower the host's, never raise it.

      iex> Macaw.Data.Source.Finish.ceiling(50_000, host: 10_000)
      {10_000, true}
      iex> Macaw.Data.Source.Finish.ceiling(nil, host: 10_000, page: 2_000)
      {2_000, false}
  """
  @spec ceiling(pos_integer() | nil, keyword()) :: {pos_integer(), boolean()}
  def ceiling(budget, opts) do
    host = Keyword.fetch!(opts, :host)
    limit = min(host, Keyword.get(opts, :page, host))

    case budget do
      nil -> {limit, false}
      n when n > limit -> {limit, true}
      n -> {n, false}
    end
  end

  @doc """
  The budget a pooled fetch asks for: the largest among its readers' (spec/01 §6), `nil`
  when any reader wants every row.

      iex> Macaw.Data.Source.Finish.pooled([100, 4_000, 250])
      4000
  """
  @spec pooled([pos_integer() | nil, ...]) :: pos_integer() | nil
  def pooled([_ | _] = budgets),
    do: if(Enum.member?(budgets, nil), do: nil, else: Enum.max(budgets))
end
