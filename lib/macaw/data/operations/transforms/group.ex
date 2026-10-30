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

  alias Macaw.Data.{Native, Operations, Table}
  alias Macaw.Data.Native.Kernels
  alias Macaw.Data.Operations.{Aggregates, Option, Step, Transforms}
  alias Macaw.Data.Table.Chunk

  # The aggregates whose state the native exact sum by group builds.
  @exact [Aggregates.Sum, Aggregates.Mean, Aggregates.Count]

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
  def run(node, table, context), do: Step.run(__MODULE__, node, table, context)

  # A combine (spec/04 §1.4) when the aggregate has the combining form; with any other
  # (median, quantile, distinct, …), a global step: each chunk's part is its keys and
  # readings, and the merge reduces every group's readings at once.
  @impl true
  def class(node), do: group_class(node["fn"])

  @impl true
  def reads, do: []

  @impl true
  def bind(node, table, _context), do: group_bind(node, table)

  @impl true
  # The bound context alone: a chunk's part depends not on where it sits (`:at`, `:rows`),
  # so its step key holds while other chunks come and go.
  def resolve(_node, _view, bound), do: Map.drop(bound, [:at, :rows])

  @impl true
  def chunk(node, view, bound) do
    case class(node) do
      :combine -> group_chunk(node, node["fn"], view, bound, name())
      :global -> global_chunk(view, bound, name())
    end
  end

  @impl true
  def combine(node, a, b), do: group_combine(node["fn"], node, a, b)

  # An inverse update, where the aggregate's is exact: count, and a sum of integers.
  @impl true
  def update(node, partial, change, _bound) do
    case class(node) do
      :combine -> group_update(node["fn"], node, partial, change)
      :global -> :recompute
    end
  end

  @impl true
  def finish(node, partial, at) do
    case class(node) do
      :combine -> group_finish(node, node["fn"], partial, at)
      :global -> global_finish(node, node["fn"], partial, at)
    end
  end

  # -- the grouping, a combine --------------------------------------------------------------

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
  # One chunk's groups: their keys in order of first appearance, each one's state of the
  # aggregate's streaming form over its readings, `nil`s dropped, and each one's first row
  # in the view and its count of rows, which an inverse update reads (spec/04 §1.5).
  def group_chunk(node, aggregate, view, bound, op) do
    case group_native(aggregate, view, bound) do
      :fallback -> group_chunk_elixir(node, aggregate, view, bound, op)
      groups -> groups
    end
  end

  @doc false
  # One chunk's groups by the Elixir fold alone, whatever the kernels: the path a build
  # without them runs, and the reference the native kernel is held equal to.
  def group_chunk_elixir(node, aggregate, view, bound, op) do
    options = options(node, aggregate)
    readings = view_readings(view, bound.field, op)
    step = &aggregate.step(&1, &2, options)
    init = aggregate.init(options)

    case bound.by do
      [] ->
        readings |> fold_all(step, init, 0, nil) |> one_group()

      [name] ->
        case coded(view, name) do
          {codes, strings} ->
            codes
            |> fold(readings, step, init, 0, %{}, [])
            |> named(&[if(&1 == nil, do: nil, else: elem(strings, &1))])

          :values ->
            view
            |> Transforms.view_values(name)
            |> fold(readings, step, init, 0, %{}, [])
            |> named(&[&1])
        end

      by ->
        by
        |> Enum.map(&Transforms.view_values(view, &1))
        |> Enum.zip()
        |> Enum.map(&Tuple.to_list/1)
        |> fold(readings, step, init, 0, %{}, [])
        |> named(& &1)
    end
  end

  # Each row's group by its key, one map update a row: the map holds a key's state, its
  # first row and its count of rows together, and the keys in order of first appearance
  # are kept newest first.
  defp fold([key | keys], [reading | readings], step, init, i, groups, order) do
    case groups do
      %{^key => {state, first, n}} ->
        state = if reading == nil, do: state, else: step.(state, reading)
        fold(keys, readings, step, init, i + 1, %{groups | key => {state, first, n + 1}}, order)

      _ ->
        state = if reading == nil, do: init, else: step.(init, reading)

        fold(keys, readings, step, init, i + 1, Map.put(groups, key, {state, i, 1}), [key | order])
    end
  end

  defp fold([], [], _step, _init, _i, groups, order), do: {Enum.reverse(order), groups}

  # Without `by`: one group, every row's.
  defp fold_all([reading | readings], step, state, n, _first) when n == 0,
    do: fold_all(readings, step, read(step, state, reading), 1, 0)

  defp fold_all([reading | readings], step, state, n, first),
    do: fold_all(readings, step, read(step, state, reading), n + 1, first)

  defp fold_all([], _step, state, n, first), do: {state, first, n}

  defp read(_step, state, nil), do: state
  defp read(step, state, reading), do: step.(state, reading)

  defp one_group({_state, _first, 0}), do: {[], %{}, %{}}
  defp one_group({state, first, n}), do: {[[]], %{[] => state}, %{[] => {first, n}}}

  # The groups under their keys as the step names them, `name` a fold key's.
  defp named({order, groups}, name) do
    {groups, rows} =
      Enum.reduce(groups, {%{}, %{}}, fn {key, {state, first, n}}, {gs, rs} ->
        key = name.(key)
        {Map.put(gs, key, state), Map.put(rs, key, {first, n})}
      end)

    {Enum.map(order, name), groups, rows}
  end

  # A dictionary column's rows as their codes, `nil` where a value is missing, and its
  # strings by code: one group a code, named once. A column of another form is read as
  # its values.
  defp coded({chunk, first, count}, name) do
    case Macaw.Data.Table.Chunk.storage(chunk, name, first, count) do
      {:dictionary, _codes, _validity, _dictionary, nil} = column ->
        Macaw.Data.Table.Column.codes(column, count)

      _other ->
        :values
    end
  end

  # -- the native exact sum by group (spec/04 §5.1) -----------------------------------------

  # The groups by the native kernel, for an aggregate whose state is an exact sum or a
  # count (sum, mean, count) of an int64 or float64 column, grouped by one dictionary
  # column or not at all, where the kernels are loaded; else, or where the kernel hands
  # the view back, `:fallback`. The kernel answers each group's code, first row, rows,
  # readings and exact sum; the states and names are built here, a group at a time.
  @doc false
  def group_native(aggregate, {chunk, first, count}, %{field: {_field, name}, by: by})
      when aggregate in @exact and name != nil and length(by) <= 1 do
    with true <- Native.active?(),
         {vf, vd, vv} <- value_buffers(Chunk.packed(chunk, name)),
         {grouped, cd, cv, dictionary} <- code_buffers(chunk, by) do
      ncodes = if grouped, do: div(byte_size(elem(dictionary, 0)), 4) - 1, else: 0

      call = &Kernels.group_sum(vf, vd, vv, grouped, cd, cv, ncodes, first, count, &1)
      dirty = &Kernels.group_sum_dirty(vf, vd, vv, grouped, cd, cv, ncodes, first, count, &1)

      # Past `sync_rows/0` rows the call is dirty; past `sync_entries/0` entries the normal
      # call answers `:dirty` before building any term, and is made dirty.
      answer =
        case Native.scheduler(count) do
          :normal ->
            case call.(Native.entry_limit()) do
              :dirty -> dirty.(0)
              answer -> answer
            end

          :dirty ->
            dirty.(0)
        end

      native_groups(answer, aggregate, grouped, dictionary)
    else
      _ -> :fallback
    end
  end

  def group_native(_aggregate, _view, _bound), do: :fallback

  defp native_groups(:fallback, _aggregate, _grouped, _dictionary), do: :fallback

  defp native_groups([], _aggregate, false, _dictionary), do: one_group({nil, 0, 0})

  defp native_groups([{_code, first, rows, readings, ints, floats}], aggregate, false, _dict),
    do: one_group({state(aggregate, ints, floats, readings), first, rows})

  defp native_groups(list, aggregate, true, {offsets, data}) do
    groups =
      Map.new(list, fn {code, first, rows, readings, ints, floats} ->
        {code, {state(aggregate, ints, floats, readings), first, rows}}
      end)

    named({Enum.map(list, &elem(&1, 0)), groups}, fn
      nil -> [nil]
      code -> [dictionary_string(offsets, data, code)]
    end)
  end

  # The aggregate's state of a group's exact sum (`Macaw.Data.Exact`) and readings.
  defp state(Aggregates.Sum, ints, floats, _readings), do: {ints, floats}
  defp state(Aggregates.Mean, ints, floats, readings), do: {{ints, floats}, readings}
  defp state(Aggregates.Count, _ints, _floats, readings), do: readings

  defp value_buffers({:int64, data, validity}), do: {0, data, validity}
  defp value_buffers({:float64, data, validity}), do: {1, data, validity}
  defp value_buffers(_column), do: :elixir

  # The `by` column's codes, their validity and its dictionary, unsliced; ungrouped, empty
  # buffers the kernel doesn't read.
  defp code_buffers(_chunk, []), do: {false, <<>>, <<>>, nil}

  defp code_buffers(chunk, [name]) do
    case Chunk.packed(chunk, name) do
      {:dictionary, codes, validity, dictionary, nil} -> {true, codes, validity, dictionary}
      _other -> :elixir
    end
  end

  # The dictionary's string of `code`, as `Column.codes/2` reads it.
  defp dictionary_string(offsets, data, code) do
    skip = code * 4
    <<_::binary-size(^skip), a::signed-little-32, b::signed-little-32, _::binary>> = offsets
    binary_part(data, a, b - a)
  end

  @doc false
  # Two runs' groups, the first's before the second's: keys in order of first appearance,
  # each key's states merged by the aggregate's combining form. The rows are a chunk's
  # alone, so a merged partial has none.
  def group_combine(aggregate, node, {order_a, groups_a, _rows_a}, {order_b, groups_b, _rows_b}) do
    options = options(node, aggregate)

    groups =
      Map.merge(groups_a, groups_b, fn _key, a, b -> aggregate.merge(a, b, options) end)

    {order_a ++ Enum.reject(order_b, &Map.has_key?(groups_a, &1)), groups, nil}
  end

  @doc false
  # An inverse update of one chunk's groups (spec/04 §1.5): the base's partial, less the
  # removed rows' states and plus the inserted rows', where the aggregate's `retract/3` is
  # exact. A group none of whose rows remain is gone; the groups are in order of first
  # appearance in the chunk as read, each first row placed where it reads. A group whose
  # first row was removed has its next first row unknown here, so it recomputes, as does
  # an aggregate without an exact inverse.
  def group_update(aggregate, node, {_order, groups, rows}, change) when is_map(rows) do
    Code.ensure_loaded!(aggregate)
    options = options(node, aggregate)
    {_r_order, r_groups, r_rows} = change.removed
    {i_order, i_groups, i_rows} = change.inserted

    with true <- function_exported?(aggregate, :retract, 3),
         {:ok, groups, rows} <-
           retracted(aggregate, options, groups, rows, r_groups, r_rows, change) do
      firsts =
        Map.new(rows, fn {key, {first, n}} -> {key, {elem(change.base, first), n}} end)

      {groups, firsts} =
        Enum.reduce(i_order, {groups, firsts}, fn key, {groups, firsts} ->
          {j, n} = Map.fetch!(i_rows, key)
          at = elem(change.side, j)
          state = Map.fetch!(i_groups, key)

          case firsts do
            %{^key => {first, m}} ->
              {Map.update!(groups, key, &aggregate.merge(&1, state, options)),
               Map.put(firsts, key, {min(first, at), m + n})}

            _ ->
              {Map.put(groups, key, state), Map.put(firsts, key, {at, n})}
          end
        end)

      order =
        firsts |> Enum.sort_by(fn {_key, {first, _n}} -> first end) |> Enum.map(&elem(&1, 0))

      {:ok, {order, groups, firsts}}
    else
      _inexact -> :recompute
    end
  end

  def group_update(_aggregate, _node, _merged, _change), do: :recompute

  defp retracted(aggregate, options, groups, rows, r_groups, r_rows, change) do
    Enum.reduce_while(r_rows, {:ok, groups, rows}, fn {key, {_j, n}}, {:ok, groups, rows} ->
      {first, m} = Map.fetch!(rows, key)

      cond do
        m == n ->
          {:cont, {:ok, Map.delete(groups, key), Map.delete(rows, key)}}

        MapSet.member?(change.gone, first) ->
          {:halt, :inexact}

        true ->
          case aggregate.retract(Map.fetch!(groups, key), Map.fetch!(r_groups, key), options) do
            {:ok, state} ->
              {:cont, {:ok, Map.put(groups, key, state), Map.put(rows, key, {first, m - n})}}

            :inexact ->
              {:halt, :inexact}
          end
      end
    end)
  end

  @doc false
  def group_finish(%{"by" => by} = node, aggregate, merged, %{input: input, key: key}) do
    options = options(node, aggregate)
    by_names = by_list(by)
    {order, groups, _rows} = merged || {[], %{}, nil}
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
  # One chunk's keys and readings, in row order: a global grouping's part.
  def global_chunk({_chunk, _first, count} = view, bound, op) do
    keys =
      case bound.by do
        [] -> List.duplicate([], count)
        by -> by |> Enum.map(&Transforms.view_values(view, &1)) |> Enum.zip_with(& &1)
      end

    {keys, view_readings(view, bound.field, op)}
  end

  @doc false
  # Every chunk's keys and readings: one row a group in order of first appearance, its
  # readings reduced at once, `nil`s dropped.
  def global_finish(%{"by" => by} = node, aggregate, partials, %{input: input, key: key}) do
    options = options(node, aggregate)
    by_names = by_list(by)

    {order, groups} =
      partials
      |> Enum.flat_map(fn {keys, readings} -> Enum.zip(keys, readings) end)
      |> Enum.reduce({[], %{}}, fn {k, reading}, {order, groups} ->
        order = if Map.has_key?(groups, k), do: order, else: [k | order]
        {order, Map.update(groups, k, [reading], &[reading | &1])}
      end)

    order = if order == [] and by_names == [], do: [[]], else: Enum.reverse(order)

    values =
      for k <- order do
        groups
        |> Map.get(k, [])
        |> Enum.reverse()
        |> Enum.reject(&is_nil/1)
        |> aggregate.reduce(options)
      end

    columns = group_outputs(node, aggregate, Operations.columns(input))

    keyed =
      Enum.with_index(by_names, fn _name, i -> Enum.map(order, &Enum.at(&1, i)) end) ++ [values]

    Step.output(input, key, Enum.zip_with(columns, keyed, fn {n, t}, v -> {n, t, v} end))
  end

  defp by_list(nil), do: []
  defp by_list(by) when is_list(by), do: by
  defp by_list(by), do: [by]
end

defmodule Macaw.Data.Operations.Transforms.Sum do
  @moduledoc """
  `sum` (spec/04 §4.10): `aggregate` with `fn: "sum"`, `as` `"sum"` by default. It is
  vocabulary a design writes, not a deprecated alias.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.Operations.Aggregates
  alias Macaw.Data.Operations.{Option, Step}
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
  def run(node, table, context), do: Step.run(__MODULE__, node, table, context)

  # A combine (spec/04 §1.4): each chunk's groups summed exactly, the sums merged.
  @impl true
  def class(_node), do: :combine

  @impl true
  def reads, do: []

  @impl true
  def bind(node, table, _context), do: Aggregate.group_bind(node, table)

  @impl true
  # The bound context alone: a chunk's part depends not on where it sits (`:at`, `:rows`),
  # so its step key holds while other chunks come and go.
  def resolve(_node, _view, bound), do: Map.drop(bound, [:at, :rows])

  @impl true
  def chunk(node, view, bound),
    do: Aggregate.group_chunk(node, Aggregates.Sum, view, bound, name())

  @impl true
  def combine(node, a, b), do: Aggregate.group_combine(Aggregates.Sum, node, a, b)

  # An inverse update while every reading is an integer (spec/04 §1.5).
  @impl true
  def update(node, partial, change, _bound),
    do: Aggregate.group_update(Aggregates.Sum, node, partial, change)

  @impl true
  def finish(node, merged, at), do: Aggregate.group_finish(node, Aggregates.Sum, merged, at)
end
