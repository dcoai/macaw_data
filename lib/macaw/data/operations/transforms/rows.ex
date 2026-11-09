defmodule Macaw.Data.Operations.Transforms.Filter do
  @moduledoc """
  `filter` (spec/04 §4.1): the rows, in order, whose reading of `field` passes `test`
  against `value`. `present` and `absent` test `nil`; `eq` and `ne` compare a number by
  its value (`1` equals `1.0`) and a category one value whichever spelling it has
  (`Macaw.Data.Operations.same?/2`), and a time by its instant; the orderings compare the
  reading and `value` by the column's type, by the keys `sort` orders by
  (`Macaw.Data.Source.Order.key/2`), the value read as the column reads it at the edge.
  So `lte` and `gte` both hold exactly when `eq` does. A `nil` reading, and one of no
  reading for its type, never passes an ordering nor `eq`; a value of no reading for the
  column's type (`nil` included) is a fault under an ordering, and under `eq` and `ne` on
  a time column, raised before any row is read.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.{Native, Operations, Table}
  alias Macaw.Data.Operations.{Option, Step, Transforms}
  alias Macaw.Data.Source.Order
  alias Macaw.Data.Table.{Bitmap, Chunk, Column}

  @tests [:eq, :ne, :lt, :lte, :gt, :gte, :present, :absent]
  @orderings [:lt, :lte, :gt, :gte]
  @equalities [:eq, :ne]
  # The kernel's code of each comparison.
  @codes %{eq: 0, ne: 1, lt: 2, lte: 3, gt: 4, gte: 5}
  @s64_min -0x8000000000000000
  @s64_max 0x7FFFFFFFFFFFFFFF

  @typedoc """
  What a chunk is tested with: the column's name (`nil` for a column the rows lack), its
  type, and for an ordering, or `eq` and `ne` on a time column, the value's key under
  that type (else `nil`).
  """
  @type bound :: {Table.name() | nil, Table.type() | nil, term()}

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
  def run(node, table, context), do: Step.answer(__MODULE__, node, table, context)

  # A per-row step (spec/04 §1.4): each chunk decided from the one column it reads.
  @impl true
  def class(_node), do: :row

  @impl true
  def reads, do: []

  # The column and, for an ordering or a time's `eq` and `ne`, the value's key under its
  # type, once over the input: a value of no reading for the column's type is the caller's
  # fault, `{"value", {:reading, type}}`, answered here, before any row is read (spec/04
  # §3.1). A column the rows lack has no type: every reading is `nil`, and no row passes.
  @impl true
  def bind(%{"field" => field, "test" => test, "value" => value}, table, _context) do
    name = Transforms.name_in(Table.names(table), field)
    type = if name, do: Table.column_type(table, name)

    case at(test, type, value) do
      {:ok, key} -> %{bound: {name, type, key}}
      :error -> {:error, {"value", {:reading, type}}}
    end
  end

  defp at(test, type, value)
       when (test in @orderings and type != nil) or (test in @equalities and type == :time) do
    case Order.key(type).(Table.at_edge(type, value)) do
      nil -> :error
      key -> {:ok, key}
    end
  end

  defp at(_test, _type, _value), do: {:ok, nil}

  @impl true
  def resolve(_node, _view, %{bound: bound}), do: bound

  @impl true
  def chunk(node, view, bound) do
    case native(node, view, bound) do
      :fallback -> chunk_elixir(node, view, bound)
      selection -> selection
    end
  end

  @doc false
  # What a chunk is tested with, for a node and its input: `bind/3` then `resolve/3`, so a
  # test drives `native/3` and `chunk_elixir/3` as the step does.
  @spec bound(map(), Table.t()) :: bound()
  def bound(node, table), do: bind(node, table, %{}).bound

  @doc false
  # The selection by the native kernel (spec/04 §4.1.1), reading `name`'s buffers in place,
  # where the kernels are loaded and the column and test are ones it reads; else, or where
  # the kernel hands the view back, `:fallback`.
  def native(%{"test" => test} = node, {chunk, first, count}, {name, _type, _at} = bound)
      when name != nil do
    passes? = tester(node, bound)
    x = against(node, bound)

    with true <- Native.active?(),
         {mode, data, validity, present, pass, ncodes} <-
           buffers(Chunk.packed(chunk, name), test, x, passes?) do
      code = Map.get(@codes, test, 0)
      x = if is_number(x), do: x, else: 0
      args = [mode, data, validity, first, count, code, x, present, passes?.(nil), pass, ncodes]

      Native.kernel(:filter_mask, args, Native.scheduler(count))
    else
      _ -> :fallback
    end
  end

  def native(_node, _view, _bound), do: :fallback

  # What a reading is compared with: an ordering's, and a time's `eq` and `ne`, the value's
  # key; any other test's, the value as given.
  defp against(%{"test" => test}, {_name, _type, at}) when test in @orderings, do: at
  defp against(%{"test" => test}, {_name, :time, at}) when test in @equalities, do: at
  defp against(%{"value" => value}, _bound), do: value

  # What the kernel reads of a column, `{mode, data, validity, present, pass, ncodes}`:
  # `present` and `absent` of any column whose validity bitmap says which rows are `nil`
  # (mode 0, the bitmap alone); a number column against a number within int64 or a float
  # (1, 2: the values compared); against any other value (0: no number equals a term of
  # another type, so one answer holds for every reading; an ordering's value is always a
  # number here, `bind/3` refusing any other); a time column's instants, Unix
  # microseconds in an int64 buffer, under any comparison against its value's instant (1,
  # `bind/3` refusing a value with none); a dictionary of strings (3: each code's answer,
  # decided once over the dictionary by the Elixir path's own test). Any other column (a
  # union, an integral, a date, a list) or test is the Elixir path's.
  defp buffers(column, test, _x, _passes?) when test in [:present, :absent] do
    case Column.validity(column) do
      nil -> :elixir
      validity -> {0, <<>>, validity, test == :present, <<>>, 0}
    end
  end

  defp buffers({form, data, validity}, _test, x, passes?) when form in [:int64, :float64] do
    cond do
      int64?(x) or is_float(x) ->
        {if(form == :int64, do: 1, else: 2), data, validity, false, <<>>, 0}

      is_number(x) ->
        :elixir

      true ->
        {0, <<>>, validity, passes?.(0), <<>>, 0}
    end
  end

  defp buffers({form, us, validity, _precision}, _test, x, _passes?)
       when form in [:utc, :naive],
       do: instants(us, validity, x)

  defp buffers({:zoned, us, validity, _precision, _zones, _codes}, _test, x, _passes?),
    do: instants(us, validity, x)

  defp buffers({:dictionary, codes, validity, dictionary, nil}, _test, _x, passes?) do
    strings = Column.dictionary_strings(dictionary)
    pass = Bitmap.from(strings, passes?)
    {3, codes, validity, false, pass, length(strings)}
  end

  defp buffers(_column, _test, _x, _passes?), do: :elixir

  defp instants(us, validity, x) do
    if int64?(x), do: {1, us, validity, false, <<>>, 0}, else: :elixir
  end

  defp int64?(x), do: is_integer(x) and x >= @s64_min and x <= @s64_max

  @doc false
  # The selection by the Elixir path alone, whatever the kernels: the path a build without
  # them runs, and the reference the native kernel is held equal to.
  def chunk_elixir(%{"test" => test} = node, {chunk, first, count} = view, {name, _, _} = bound) do
    packed =
      if name,
        do:
          Column.where(
            Chunk.storage(chunk, name, first, count),
            count,
            test,
            against(node, bound)
          )

    kept =
      case packed do
        {:ok, kept} -> kept
        _general -> view |> Transforms.view_values(name) |> kept(tester(node, bound), 0, [])
      end

    selected(kept, count)
  end

  # The rows whose readings pass, ascending: one pass, no index list built beside them.
  defp kept([reading | readings], passes?, i, acc) do
    acc = if passes?.(reading), do: [i | acc], else: acc
    kept(readings, passes?, i + 1, acc)
  end

  defp kept([], _passes?, _i, acc), do: :lists.reverse(acc)

  # The rows kept as a selection: every row, none, one run of them, cut without copying,
  # or the rows gathered.
  defp selected([], _count), do: :none
  defp selected(kept, count) when length(kept) == count, do: :all

  defp selected([a | _] = kept, _count) do
    n = length(kept)
    if List.last(kept) == a + n - 1, do: {:run, a, n}, else: {:rows, kept}
  end

  # A reading's test, built once a chunk. A time's `eq` compares the reading's instant
  # with the value's, and `ne` is its negation, so a `nil` reading passes `ne` alone. An
  # ordering keys the reading under the column's type, as `sort` does, and compares the
  # key with the value's: a reading with no key (`nil`, or no reading for its type) never
  # passes, nor does any reading of a column the rows lack. A number's key is the number
  # itself, and a text's its string, so they are compared directly.
  defp tester(%{"test" => :present}, _bound), do: &(&1 != nil)
  defp tester(%{"test" => :absent}, _bound), do: &(&1 == nil)
  defp tester(%{"test" => :eq}, {_name, :time, x}), do: &(Order.instant(&1) == x)
  defp tester(%{"test" => :ne}, {_name, :time, x}), do: &(Order.instant(&1) != x)
  defp tester(%{"test" => :eq, "value" => value}, _bound), do: &Operations.same?(&1, value)
  defp tester(%{"test" => :ne, "value" => value}, _bound), do: &(not Operations.same?(&1, value))
  defp tester(%{"test" => _ordering}, {_name, nil, _at}), do: fn _reading -> false end

  defp tester(%{"test" => test}, {_name, :number, x}) do
    case test do
      :lt -> &(is_number(&1) and &1 < x)
      :lte -> &(is_number(&1) and &1 <= x)
      :gt -> &(is_number(&1) and &1 > x)
      :gte -> &(is_number(&1) and &1 >= x)
    end
  end

  defp tester(%{"test" => test}, {_name, :text, x}) do
    case test do
      :lt -> &(is_binary(&1) and &1 < x)
      :lte -> &(is_binary(&1) and &1 <= x)
      :gt -> &(is_binary(&1) and &1 > x)
      :gte -> &(is_binary(&1) and &1 >= x)
    end
  end

  defp tester(%{"test" => test}, {_name, type, x}) do
    key = Order.key(type)

    case test do
      :lt -> &holds?(key.(&1), x, :lt)
      :lte -> &holds?(key.(&1), x, :lte)
      :gt -> &holds?(key.(&1), x, :gt)
      :gte -> &holds?(key.(&1), x, :gte)
    end
  end

  defp holds?(nil, _x, _test), do: false
  defp holds?(k, x, :lt), do: k < x
  defp holds?(k, x, :lte), do: k <= x
  defp holds?(k, x, :gt), do: k > x
  defp holds?(k, x, :gte), do: k >= x
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
  def run(node, table, context), do: Step.answer(__MODULE__, node, table, context)

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
  `sort` (spec/04 §4.6): the rows stably sorted by the reading of `field` under the
  column's type, ascending or descending, `nil` last either way: a time by its instant, a
  number by its value, text and a category by spelling, any other type by term order. The
  comparison is `Macaw.Data.Source.Order`'s, so the step and a request's row order agree.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.{Operations, Table}
  alias Macaw.Data.Operations.{Option, Step, Transforms}
  alias Macaw.Data.Source.Order

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
  def run(node, table, context), do: Step.answer(__MODULE__, node, table, context)

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

  # Every reading keyed by the column's type (a column the rows lack reads `nil`
  # throughout, which keeps the rows' order) and sorted stably across the chunks.
  @impl true
  def finish(%{"order" => order, "field" => field} = node, partials, %{input: input, key: key}) do
    direction = if order == :descending, do: :desc, else: :asc
    type = Table.column_type(input, Transforms.name_in(Table.names(input), field))

    picks =
      partials
      |> Enum.with_index()
      |> Enum.flat_map(fn {readings, v} ->
        readings |> Enum.with_index() |> Enum.map(fn {reading, i} -> {reading, {v, i}} end)
      end)
      |> Order.sort_by([{direction, Order.key(type), &elem(&1, 0)}])
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
  def run(node, table, context), do: Step.answer(__MODULE__, node, table, context)

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
