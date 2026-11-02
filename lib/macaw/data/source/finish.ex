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

  **A table stays a table, finished on its columns** (macaw_data#105): every step reads
  the columns it decides by and keeps rows of the table's chunks, as views or gathered by
  their slots, and never reads the table's rows. An order under a budget that keeps its
  head gathers that head alone. Each step keeps exactly the rows finishing the table's
  rows would keep. Any other delivery is finished over its rows, read by name.

  The pure rules of running sources (spec/01 §6) are here too: `ceiling/2` clamps a
  budget to the host's ceiling, and `pooled/1` is the one budget a pooled fetch asks for,
  the largest among its readers, each reader then reduced to its own by `reduce/5`.

  Ported from visualize's `Visualize.Feed.finish/3` and `reduce/4`.
  """

  alias Macaw.Data.{Delivery, Operations, Schema, Table, Window}
  alias Macaw.Data.Operations.{Option, Registry}
  alias Macaw.Data.Source.{Description, Order, Request}
  alias Macaw.Data.Source.Finish.Columns
  alias Macaw.Data.Table.Subset

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
             with {:ok, d} <- trimmed(d, field, request.window),
                  do: {:ok, serve(d, :window, Window.intersect(d.served.window, request.window))}
           end),
         {:ok, d} <-
           step(d, :box in supports or request.box == nil, fn d ->
             with {:ok, d} <- boxed(d, field, request.box),
                  do: {:ok, serve(d, :window, request.box)}
           end),
         {:ok, d} <-
           step(d, :region in supports or request.region == nil, &region(&1, request.region)),
         {:ok, d} <-
           step(d, :latest in supports or not request.latest, &latest(&1, field, schema)),
         {:ok, d} <-
           step(d, :order in supports or request.order == [], fn d ->
             by = ordered_by(d.served)

             with {:ok, d} <- ordered(d, request.order, schema, head(supports, request.budget)),
                  do: {:ok, serve(d, :ordered, by)}
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

  # A table is finished on its columns (macaw_data#105): a step reads the columns it
  # decides by and keeps rows of the table's chunks (`Finish.Columns`), making no row; any
  # other delivery is finished over its rows, read by name.

  # The rows whose `field` lies in the window.
  defp trimmed(%Delivery{rows: %Table{} = table} = delivery, field, window) do
    table = Subset.ready(table)

    case Columns.within(table, field, window) do
      {:run, first, count} -> {:ok, %{delivery | rows: Table.slice(table, first, count)}}
      {:at, indexes} -> {:ok, %{delivery | rows: Subset.at(table, indexes)}}
    end
  end

  defp trimmed(%Delivery{} = delivery, field, window) do
    with {:ok, rows} <- Delivery.named_rows(delivery),
         do: {:ok, rebuild(delivery, Window.trim(rows, field, window))}
  end

  # The rows whose `field` lies in the box.
  defp boxed(%Delivery{rows: %Table{} = table} = delivery, field, box) do
    table = Subset.ready(table)
    {:ok, %{delivery | rows: Subset.at(table, Columns.box(table, field, box))}}
  end

  defp boxed(%Delivery{} = delivery, field, box) do
    with {:ok, rows} <- Delivery.named_rows(delivery),
         do: {:ok, rebuild(delivery, Window.trim_box(rows, field, box))}
  end

  # The rows whose every ranged field lies in its range.
  defp region(%Delivery{rows: %Table{} = table} = delivery, region) do
    table = Subset.ready(table)
    {:ok, %{delivery | rows: Subset.at(table, Columns.region(table, region))}}
  end

  defp region(%Delivery{} = delivery, region) do
    with {:ok, rows} <- Delivery.named_rows(delivery),
         do: {:ok, rebuild(delivery, Window.trim_region(rows, region))}
  end

  # The budget an ordered table keeps the head of, when the budget step will (it is not
  # the source's), so the order step gathers that head alone; `nil` for none.
  defp head(supports, budget) when is_integer(budget) and budget > 0,
    do: if(:budget in supports, do: nil, else: budget)

  defp head(_supports, _budget), do: nil

  # The rows in the order. A table's row indexes are sorted by its columns and the rows
  # gathered in that order, only its `head` when the budget will keep no more: the budget
  # step's own cut, `reduced_by: :runtime`, made before the rows it drops are gathered.
  defp ordered(%Delivery{rows: %Table{} = table} = delivery, order, schema, head) do
    table = Subset.ready(table)

    with {:ok, sorted} <- Columns.ordered(table, order, schema) do
      case head do
        n when is_integer(n) and length(sorted) > n ->
          {:ok,
           %{delivery | rows: Subset.at(table, Enum.take(sorted, n))}
           |> serve(:reduced_by, :runtime)}

        _all ->
          {:ok, %{delivery | rows: Subset.at(table, sorted)}}
      end
    end
  end

  defp ordered(%Delivery{} = delivery, order, schema, _head) do
    with {:ok, rows} <- Delivery.named_rows(delivery),
         {:ok, sorted} <- Order.sort(rows, order, schema),
         do: {:ok, rebuild(delivery, sorted)}
  end

  # Each identity's latest row by the window field.
  defp latest(%Delivery{rows: %Table{} = table} = delivery, field, schema) do
    table = Subset.ready(table)
    {:ok, %{delivery | rows: Subset.at(table, Columns.latest(table, field, schema))}}
  end

  defp latest(%Delivery{} = delivery, field, schema) do
    with {:ok, rows} <- Delivery.named_rows(delivery) do
      latest =
        Window.latest_rows(
          rows,
          &Window.position(Table.get(&1, field)),
          &Schema.identity(schema, &1)
        )

      {:ok, rebuild(delivery, latest)}
    end
  end

  defp serve(delivery, key, value), do: %{delivery | served: Map.put(delivery.served, key, value)}

  # Fewer rows of a delivery that is no table: the rows themselves, named (macaw#185). A
  # table keeps rows of its chunks instead (`Finish.Columns`).
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
    with {:ok, form} <- form(delivery) do
      if size(form) <= budget,
        do: {:ok, delivery},
        else: {:ok, delivery |> keep(form, 0..(budget - 1)) |> serve(:reduced_by, :runtime)}
    end
  end

  defp reduced(%Delivery{} = delivery, schema, budget, reducer, registry)
       when is_integer(budget) and budget > 0 do
    clock = Schema.window_field(schema)
    numbers = for {name, %{type: :number}} <- schema.fields, name != clock, do: name

    with {:ok, form} <- form(delivery) do
      if size(form) <= budget or numbers == [] do
        {:ok, delivery}
      else
        numbers = Enum.sort_by(numbers, &to_string/1)

        with {:ok, kept} <- kept(form, schema, numbers, budget, reducer, registry),
             do:
               {:ok,
                delivery |> keep(form, at_most(kept, budget)) |> serve(:reduced_by, :runtime)}
      end
    end
  end

  # What the budget reads of a delivery: a table as it is, any other the rows by name.
  defp form(%Delivery{rows: %Table{} = table}), do: {:ok, {:table, Subset.ready(table)}}

  defp form(%Delivery{} = delivery) do
    with {:ok, rows} <- Delivery.named_rows(delivery), do: {:ok, {:rows, rows}}
  end

  defp size({:table, table}), do: Table.size(table)
  defp size({:rows, rows}), do: length(rows)

  # A field's values, in order; a table's read from its column, making no row.
  defp read({:table, table}, field), do: Columns.values(table, field)
  defp read({:rows, rows}, field), do: Enum.map(rows, &Table.get(&1, field))

  # A field's positions (`Window.position/1`), in order.
  defp positions({:table, table}, field), do: Columns.positions(table, field)
  defp positions(form, field), do: form |> read(field) |> Enum.map(&Window.position/1)

  # The rows at the ascending indexes, in the delivery's form.
  defp keep(delivery, {:table, table}, first..last//1) when last >= first,
    do: %{delivery | rows: Table.slice(table, first, last - first + 1)}

  defp keep(delivery, {:table, table}, indexes), do: %{delivery | rows: Subset.at(table, indexes)}

  defp keep(delivery, {:rows, rows}, first..last//1),
    do: rebuild(delivery, Enum.slice(rows, first..last//1))

  defp keep(delivery, {:rows, rows}, indexes) do
    kept = MapSet.new(indexes)
    rebuild(delivery, for({row, i} <- Enum.with_index(rows), MapSet.member?(kept, i), do: row))
  end

  # The indexes, ascending, of the rows each series' reducer keeps, field by field: a
  # series the rows sharing every `:category` field's value, each field's readings and
  # the window field's positions read once, by index.
  defp kept(form, schema, numbers, budget, method, registry) do
    categories =
      Enum.sort_by(for({name, %{type: :category}} <- schema.fields, do: name), &to_string/1)

    time = Schema.window_field(schema)
    n = size(form)

    groups =
      case Enum.map(categories, &read(form, &1)) do
        [] ->
          if n == 0, do: [], else: [Enum.to_list(0..(n - 1))]

        columns ->
          columns
          |> Enum.zip_with(& &1)
          |> Enum.with_index()
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
          |> Map.values()
      end

    x = if time, do: form |> positions(time) |> List.to_tuple()
    share = length(groups) * length(numbers)
    node = node!(method, budget, share, registry)

    ys = for field <- numbers, do: {field, form |> read(field) |> List.to_tuple()}

    result =
      for group <- groups, {field, y} <- ys, reduce: {:ok, MapSet.new()} do
        {:ok, kept} ->
          with {:ok, picked} <- pick(group, x, y, field, node, method),
               do: {:ok, Enum.reduce(picked, kept, &MapSet.put(&2, &1))}

        {:error, _faults} = error ->
          error
      end

    with {:ok, kept} <- result, do: {:ok, kept |> MapSet.to_list() |> Enum.sort()}
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
  # indexes of the rows it keeps; or the reducer's fault over the readings, at the field
  # (`{[:rows, field], reason}`). `x` is each row's position by the window field, or its
  # place in the series without one.
  defp pick(series, x, y, field, node, {module, _count, _per, _least}) do
    xs = if x, do: Enum.map(series, &elem(x, &1)), else: Enum.to_list(0..(length(series) - 1)//1)

    table =
      Table.new!([
        {"x", :number, xs},
        {"y", :term, Enum.map(series, &elem(y, &1))},
        {"i", :number, series}
      ])

    case module.run(node, table, %{}) do
      %Table{} = reduced -> {:ok, Table.column(reduced, "i")}
      {:error, {_key, reason}} -> {:error, [{[:rows, field], reason}]}
    end
  end

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
  defp at_most(indexes, budget) when length(indexes) <= budget, do: indexes

  defp at_most(indexes, 1), do: [hd(indexes)]

  defp at_most(indexes, budget) do
    n = length(indexes)
    picks = MapSet.new(0..(budget - 1), &round(&1 * (n - 1) / (budget - 1)))
    for {index, i} <- Enum.with_index(indexes), MapSet.member?(picks, i), do: index
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
