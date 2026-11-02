defmodule Macaw.Data.Source.Finish do
  @moduledoc """
  Finishing (spec/01 §2.4): Macaw does what a source did not.

  Every capability is optional. Where a source's description does not list one the
  request asks, `finish/3` does it to the delivery and reports it in `served`:

  1. `:window`: rows trimmed to the window field's range, the served window intersected;
  2. `:box`: rows trimmed to the box over the `:point` window field;
  3. `:region`: rows trimmed to each ranged field's range;
  4. `:latest`: each identity's latest row by the window field (spec/01 §1.4);
  5. `:order`: the rows sorted by the request's order (`Macaw.Data.Source.Order`),
     `ordered: :runtime`, or `ordered: :sample` where the source had already cut them;
  6. `:budget`: the rows reduced to the budget by a registered reducer (`reduce/5`, spec/04
     §7), or, for an ordered delivery, kept to its first `budget` rows; `reduced_by:
     :runtime`.

  The budget never widens the window: finishing only removes rows. A delivery that needs
  none of it comes back as it is.

  The pure rules of running sources (spec/01 §6) are here too: `ceiling/2` clamps a
  budget to the host's ceiling, and `pooled/1` is the one budget a pooled fetch asks for,
  the largest among its readers, each reader then reduced to its own by `reduce/5`.

  Ported from visualize's `Visualize.Feed.finish/3` and `reduce/4`.
  """

  alias Macaw.Data.{Delivery, Operations, Schema, Table, Window}
  alias Macaw.Data.Operations.{Option, Registry}
  alias Macaw.Data.Source.{Description, Order, Request}

  @doc """
  The delivery finished for the request, each step where the description's `supports`
  lacks it: `{:ok, delivery}`, or `{:error, faults}` (spec/01 §2.4, spec/00 §5). `reduce:`
  names the budget's reducer by spelling, a registered transform that declares
  `reduces/0` (`"lttb"`, the default, or `"m4"` in `macaw_data`'s own package), and
  `operations:` is the registry it is found in (`macaw_data`'s own by default).

  The request is the caller's, so each fault is answered before any step runs:
  `Macaw.Data.Window.check/2`'s faults for a request the schema cannot answer,
  `{[:reduce], {:unknown, :reducer, name}}` for a name that is no registered reducer
  (spec/04 §7), and `{[key], :unknown_key}` for an option `finish/4` does not take. A
  step that must read tuple rows without names answers `Delivery.named_rows/1`'s fault,
  and a reading the reducer cannot place `{[:rows, field], reason}` (`reduce/5`).
  `finish!/4` answers the delivery or raises.
  """
  @spec finish(Delivery.t(), Description.t(), Request.t(), keyword()) ::
          {:ok, Delivery.t()} | {:error, [{list(), term()}, ...]}
  def finish(delivery, description, request, opts \\ [])

  def finish(%Delivery{} = delivery, %Description{} = description, %Request{} = request, opts)
      when is_list(opts) do
    schema = description.schema
    supports = description.supports
    field = Schema.window_field(schema)

    with {:ok, opts} <- options(opts),
         {:ok, reducer} <- reducer(opts[:operations], opts[:reduce]),
         :ok <- Window.check(request, schema),
         {:ok, d} <-
           step(delivery, :window in supports or request.window == nil or field == nil, fn d ->
             with {:ok, rows} <- Delivery.named_rows(d) do
               rows = Window.trim(rows, field, request.window)

               {:ok,
                d
                |> rebuild(rows)
                |> serve(:window, Window.intersect(d.served.window, request.window))}
             end
           end),
         {:ok, d} <-
           step(d, :box in supports or request.box == nil, fn d ->
             with {:ok, rows} <- Delivery.named_rows(d),
                  do:
                    {:ok,
                     d
                     |> rebuild(Window.trim_box(rows, field, request.box))
                     |> serve(:window, request.box)}
           end),
         {:ok, d} <-
           step(d, :region in supports or request.region == nil, fn d ->
             with {:ok, rows} <- Delivery.named_rows(d),
                  do: {:ok, rebuild(d, Window.trim_region(rows, request.region))}
           end),
         {:ok, d} <-
           step(d, :latest in supports or not request.latest, fn d ->
             with {:ok, rows} <- Delivery.named_rows(d) do
               latest =
                 Window.latest_rows(
                   rows,
                   &Window.position(Table.get(&1, field)),
                   &Schema.identity(schema, &1)
                 )

               {:ok, rebuild(d, latest)}
             end
           end),
         {:ok, d} <-
           step(d, :order in supports or request.order == [], fn d ->
             with {:ok, rows} <- Delivery.named_rows(d),
                  {:ok, sorted} <- Order.sort(rows, request.order, schema),
                  do: {:ok, d |> rebuild(sorted) |> serve(:ordered, ordered_by(d.served))}
           end) do
      step(
        d,
        :budget in supports,
        &reduced(&1, schema, request.budget, reducer, opts[:operations])
      )
    end
  end

  def finish(%Delivery{}, %Description{}, %Request{}, _opts),
    do: {:error, [{[:opts], {:type, :keyword}}]}

  @doc "As `finish/4`, the delivery alone, raising `ArgumentError` naming the faults."
  @spec finish!(Delivery.t(), Description.t(), Request.t(), keyword()) :: Delivery.t()
  def finish!(delivery, description, request, opts \\ []) do
    case finish(delivery, description, request, opts) do
      {:ok, finished} ->
        finished

      {:error, faults} ->
        raise ArgumentError, "the delivery cannot be finished: #{inspect(faults)}"
    end
  end

  # The options with their defaults, or every option `finish/4` does not take.
  defp options(opts) do
    case for({key, _} <- opts, key not in [:reduce, :operations], do: {[key], :unknown_key}) do
      [] ->
        {:ok,
         [
           reduce: Keyword.get(opts, :reduce, "lttb"),
           operations: Keyword.get_lazy(opts, :operations, &Operations.registry/0)
         ]}

      faults ->
        {:error, faults}
    end
  end

  # Rows the source cut, to its own budget or short of the window, are a sample: ordered
  # here, they need not be the first rows in the order (spec/01 §2.4).
  defp ordered_by(%{reduced_by: :source}), do: :sample
  defp ordered_by(%{capped: true}), do: :sample
  defp ordered_by(_served), do: :runtime

  defp step(delivery, true, _fun), do: {:ok, delivery}
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

  **An ordered delivery keeps its head** (spec/01 §2.4): one whose `served.ordered` is
  set holds its rows in a reader's order, and a reader that orders rows wants the first
  of them, not a shape, so its first `budget` rows are kept, `reduced_by: :runtime`, with
  any reducer. So a pooled fetch's ordered rows reduce to each reader's own head.

  `{:ok, delivery}`, or `{:error, faults}` (spec/00 §5): `{[:reduce], {:unknown, :reducer,
  name}}` for a name that is no registered reducer, `Delivery.named_rows/1`'s fault for
  tuple rows without names, and `{[:rows, field], reason}` for a field's reading the
  reducer cannot place (a number field holding a string: `{:reads, :number}`).
  `reduce!/5` answers the delivery or raises.

      iex> alias Macaw.Data.{Delivery, Schema, Source.Finish}
      iex> schema = Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number}})
      iex> {:ok, reduced} = Finish.reduce(Delivery.new!(for t <- 1..100, do: %{t: t, v: rem(t * 7, 5)}), schema, 10)
      iex> {length(Delivery.rows(reduced)), reduced.served.reduced_by}
      {10, :runtime}
  """
  @spec reduce(Delivery.t(), Schema.t(), pos_integer() | nil, String.t() | atom(), Registry.t()) ::
          {:ok, Delivery.t()} | {:error, [{list(), term()}, ...]}
  def reduce(delivery, schema, budget, method \\ "lttb", registry \\ Operations.registry())

  def reduce(%Delivery{} = delivery, %Schema{} = schema, budget, method, %Registry{} = registry) do
    with {:ok, reducer} <- reducer(registry, method),
         do: reduced(delivery, schema, budget, reducer, registry)
  end

  @doc "As `reduce/5`, the delivery alone, raising `ArgumentError` naming the faults."
  @spec reduce!(Delivery.t(), Schema.t(), pos_integer() | nil, String.t() | atom(), Registry.t()) ::
          Delivery.t()
  def reduce!(delivery, schema, budget, method \\ "lttb", registry \\ Operations.registry()) do
    case reduce(delivery, schema, budget, method, registry) do
      {:ok, reduced} ->
        reduced

      {:error, faults} ->
        raise ArgumentError, "the delivery cannot be reduced: #{inspect(faults)}"
    end
  end

  defp reduced(%Delivery{} = delivery, _schema, nil, _reducer, _registry), do: {:ok, delivery}

  defp reduced(%Delivery{served: %{ordered: by}} = delivery, _schema, budget, _reducer, _registry)
       when by != nil and is_integer(budget) and budget > 0 do
    with {:ok, rows} <- Delivery.named_rows(delivery) do
      if length(rows) <= budget,
        do: {:ok, delivery},
        else: {:ok, delivery |> rebuild(Enum.take(rows, budget)) |> serve(:reduced_by, :runtime)}
    end
  end

  defp reduced(%Delivery{} = delivery, schema, budget, reducer, registry)
       when is_integer(budget) and budget > 0 do
    clock = Schema.window_field(schema)
    numbers = for {name, %{type: :number}} <- schema.fields, name != clock, do: name

    with {:ok, rows} <- Delivery.named_rows(delivery) do
      if length(rows) <= budget or numbers == [] do
        {:ok, delivery}
      else
        with {:ok, kept} <-
               kept(rows, schema, Enum.sort_by(numbers, &to_string/1), budget, reducer, registry),
             do: {:ok, delivery |> rebuild(at_most(kept, budget)) |> serve(:reduced_by, :runtime)}
      end
    end
  end

  defp kept(rows, schema, numbers, budget, method, registry) do
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

    result =
      for group <- groups, field <- numbers, reduce: {:ok, MapSet.new()} do
        {:ok, kept} ->
          with {:ok, picked} <- pick(Enum.with_index(group), time, field, node, method),
               do:
                 {:ok,
                  Enum.reduce(picked, kept, fn {{_row, i}, _place}, acc -> MapSet.put(acc, i) end)}

        {:error, _faults} = error ->
          error
      end

    with {:ok, kept} <- result,
         do: {:ok, for({row, i} <- Enum.with_index(rows), MapSet.member?(kept, i), do: row)}
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
  # kept points, each with its row's index; or the reducer's fault over the readings, at
  # the field (`{[:rows, field], reason}`).
  defp pick(points, time, field, node, {module, _count, _per, _least}) do
    table =
      Table.new!([
        {"x", :number, Enum.map(points, &x(&1, time))},
        {"y", :term, Enum.map(points, fn {{row, _i}, _place} -> Table.get(row, field) end)},
        {"i", :number, Enum.map(points, fn {{_row, i}, _place} -> i end)}
      ])

    case module.run(node, table, %{}) do
      %Table{} = reduced ->
        kept = reduced |> Table.column("i") |> MapSet.new()
        {:ok, Enum.filter(points, fn {{_row, i}, _place} -> MapSet.member?(kept, i) end)}

      {:error, {_key, reason}} ->
        {:error, [{[:rows, field], reason}]}
    end
  end

  defp x({{_row, _i}, place}, nil), do: place
  defp x({{row, _i}, _place}, time), do: Window.position(Table.get(row, time))

  # The registered reducer `method` names: its module, its count option, the rows each unit
  # keeps and the least count its option takes; else `{[:reduce], {:unknown, :reducer,
  # name}}`.
  defp reducer(%Registry{} = registry, method) do
    name = if is_atom(method), do: Atom.to_string(method), else: method

    with true <- is_binary(name),
         {:ok, module} <- Registry.transform(registry, name),
         true <- function_exported?(module, :reduces, 0) do
      {count, per} = module.reduces()
      {^count, %Option{type: type}} = List.keyfind(module.options(), count, 0)
      {:ok, {module, count, per, least(type)}}
    else
      _not_a_reducer -> {:error, [{[:reduce], {:unknown, :reducer, method}}]}
    end
  end

  defp reducer(_not_a_registry, _method), do: {:error, [{[:operations], {:type, :registry}}]}

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
  A budget clamped to the host's ceiling (spec/01 §6, macaw_compose 05 §1.2): `{:ok,
  {budget, clamped?}}`. A `nil` budget reads at the ceiling; a page's ceiling, given as
  `page:`, may lower the host's, never raise it. `host:` is required: without it,
  `{:error, [{[:host], :required}]}`; an option it does not take is `{[key],
  :unknown_key}` (spec/00 §5). `ceiling!/2` answers the pair or raises.

      iex> Macaw.Data.Source.Finish.ceiling(50_000, host: 10_000)
      {:ok, {10_000, true}}
      iex> Macaw.Data.Source.Finish.ceiling!(nil, host: 10_000, page: 2_000)
      {2_000, false}
      iex> Macaw.Data.Source.Finish.ceiling(5, page: 2_000)
      {:error, [{[:host], :required}]}
  """
  @spec ceiling(pos_integer() | nil, keyword()) ::
          {:ok, {pos_integer(), boolean()}} | {:error, [{list(), term()}, ...]}
  def ceiling(budget, opts) do
    with {:ok, opts} <- Macaw.Data.Options.known(opts, host: nil, page: nil) do
      case opts[:host] do
        nil ->
          {:error, [{[:host], :required}]}

        host ->
          limit = min(host, opts[:page] || host)

          case budget do
            nil -> {:ok, {limit, false}}
            n when n > limit -> {:ok, {limit, true}}
            n -> {:ok, {n, false}}
          end
      end
    end
  end

  @doc "As `ceiling/2`, the pair alone, raising `ArgumentError` naming the faults."
  @spec ceiling!(pos_integer() | nil, keyword()) :: {pos_integer(), boolean()}
  def ceiling!(budget, opts) do
    case ceiling(budget, opts) do
      {:ok, pair} -> pair
      {:error, faults} -> raise ArgumentError, "not a ceiling: #{inspect(faults)}"
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
