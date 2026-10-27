defmodule Macaw.Data.Source.Finish do
  @moduledoc """
  Finishing (spec/01 §2.4): Macaw does what a source did not.

  Every capability is optional. Where a source's description does not list one the
  request asks, `finish/3` does it to the delivery and reports it in `served`:

  1. `:window`: rows trimmed to the window field's range, the served window intersected;
  2. `:box`: rows trimmed to the box over the `:point` window field;
  3. `:region`: rows trimmed to each ranged field's range;
  4. `:latest`: each identity's latest row by the window field (spec/01 §1.4);
  5. `:budget`: the rows reduced to the budget (`reduce/4`), `reduced_by: :runtime`.

  The budget never widens the window: finishing only removes rows. A delivery that needs
  none of it comes back as it is.

  The pure rules of running sources (spec/01 §6) are here too: `ceiling/2` clamps a
  budget to the host's ceiling, and `pooled/1` is the one budget a pooled fetch asks for,
  the largest among its readers, each reader then reduced to its own by `reduce/4`.

  Ported from visualize's `Visualize.Feed.finish/3` and `reduce/4`.
  """

  alias Macaw.Data.{Delivery, Reduce, Schema, Table, Window}
  alias Macaw.Data.Source.{Description, Request}

  @doc """
  The delivery finished for the request, each step where the description's `supports`
  lacks it. `reduce:` picks the budget's reducer, `:lttb` (the default) or `:m4`.

  Raises `ArgumentError` for a request the schema cannot answer (`Window.check/2`): the
  request is the caller's.
  """
  @spec finish(Delivery.t(), Description.t(), Request.t(), keyword()) :: Delivery.t()
  def finish(delivery, description, request, opts \\ [])

  def finish(%Delivery{} = delivery, %Description{} = description, %Request{} = request, opts) do
    opts = Keyword.validate!(opts, reduce: :lttb)
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
      rows = Window.trim(Delivery.rows(d), field, request.window)
      d |> rebuild(rows) |> serve(:window, Window.intersect(d.served.window, request.window))
    end)
    |> step(:box in supports or request.box == nil, fn d ->
      d
      |> rebuild(Window.trim_box(Delivery.rows(d), field, request.box))
      |> serve(:window, request.box)
    end)
    |> step(:region in supports or request.region == nil, fn d ->
      rebuild(d, Window.trim_region(Delivery.rows(d), request.region))
    end)
    |> step(:latest in supports or not request.latest, fn d ->
      rows =
        Window.latest_rows(
          Delivery.rows(d),
          &Window.position(Table.get(&1, field)),
          &Schema.identity(schema, &1)
        )

      rebuild(d, rows)
    end)
    |> step(:budget in supports, &reduce(&1, schema, request.budget, opts[:reduce]))
  end

  defp step(delivery, true, _fun), do: delivery
  defp step(delivery, false, fun), do: fun.(delivery)

  defp serve(delivery, key, value), do: %{delivery | served: Map.put(delivery.served, key, value)}

  # The same columns, in their order and of their types; fewer rows.
  defp rebuild(%Delivery{table: table} = delivery, rows) do
    columns =
      for name <- Table.names(table),
          do: {name, Table.column_type(table, name), Enum.map(rows, &Map.get(&1, name))}

    %{delivery | table: Table.new!(columns)}
  end

  @doc """
  The delivery reduced to `budget` rows by `method`, `:lttb` or `:m4`, recording
  `reduced_by: :runtime`. Each series (the rows sharing every `:category` field's value)
  is reduced field by field against the window field, or the row's place without one, and
  the union of the kept rows returned whole, in their order, never more than the budget.
  A `nil` budget, a delivery within it, and a schema with no `:number` field to reduce by
  come back as they are.

      iex> alias Macaw.Data.{Delivery, Schema, Source.Finish}
      iex> schema = Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number}})
      iex> reduced = Finish.reduce(Delivery.new(for t <- 1..100, do: %{t: t, v: rem(t * 7, 5)}), schema, 10)
      iex> {Table.size(reduced.table), reduced.served.reduced_by}
      {10, :runtime}
  """
  @spec reduce(Delivery.t(), Schema.t(), pos_integer() | nil, :lttb | :m4) :: Delivery.t()
  def reduce(delivery, schema, budget, method \\ :lttb)
  def reduce(%Delivery{} = delivery, %Schema{}, nil, _method), do: delivery

  def reduce(%Delivery{} = delivery, %Schema{} = schema, budget, method)
      when is_integer(budget) and budget > 0 and method in [:lttb, :m4] do
    rows = Delivery.rows(delivery)
    clock = Schema.window_field(schema)
    numbers = for {name, %{type: :number}} <- schema.fields, name != clock, do: name

    if length(rows) <= budget or numbers == [] do
      delivery
    else
      kept =
        rows
        |> reduced(schema, Enum.sort_by(numbers, &to_string/1), budget, method)
        |> at_most(budget)

      delivery |> rebuild(kept) |> serve(:reduced_by, :runtime)
    end
  end

  defp reduced(rows, schema, numbers, budget, method) do
    categories =
      Enum.sort_by(for({name, %{type: :category}} <- schema.fields, do: name), &to_string/1)

    time = Schema.window_field(schema)

    groups =
      rows
      |> Enum.with_index()
      |> Enum.group_by(fn {row, _i} -> Enum.map(categories, &Table.get(row, &1)) end)
      |> Map.values()

    share = length(groups) * length(numbers)

    kept =
      for group <- groups, field <- numbers, reduce: MapSet.new() do
        kept ->
          group
          |> Enum.with_index()
          |> pick(time, field, share, budget, method)
          |> Enum.reduce(kept, fn {{_row, i}, _place}, acc -> MapSet.put(acc, i) end)
      end

    for {row, i} <- Enum.with_index(rows), MapSet.member?(kept, i), do: row
  end

  defp pick(points, time, field, share, budget, :lttb),
    do: Reduce.lttb(points, max(3, div(budget, share)), xy(time, field))

  defp pick(points, time, field, share, budget, :m4),
    do: Reduce.m4(points, max(1, div(budget, 4 * share)), xy(time, field))

  defp xy(nil, field), do: fn {{row, _i}, place} -> {place, Table.get(row, field)} end

  defp xy(time, field),
    do: fn {{row, _i}, _place} ->
      {Window.position(Table.get(row, time)), Table.get(row, field)}
    end

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
