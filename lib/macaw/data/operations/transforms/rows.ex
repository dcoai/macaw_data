defmodule Macaw.Data.Operations.Transforms.Filter do
  @moduledoc """
  `filter` (spec/04 §4.1): the rows, in order, whose reading of `field` passes `test`
  against `value`. `present` and `absent` test `nil`; `eq` and `ne` compare with a
  category one value whichever spelling it has (`Macaw.Data.Operations.same?/2`); the
  orderings compare under term order, and a `nil` reading never passes one.
  """
  @behaviour Macaw.Data.Transform

  alias Macaw.Data.{Native, Operations, Table}
  alias Macaw.Data.Native.Kernels
  alias Macaw.Data.Operations.{Option, Step, Transforms}
  alias Macaw.Data.Table.{Bitmap, Chunk, Column}

  @tests [:eq, :ne, :lt, :lte, :gt, :gte, :present, :absent]
  # The kernel's code of each comparison.
  @codes %{eq: 0, ne: 1, lt: 2, lte: 3, gt: 4, gte: 5}
  @s64_min -0x8000000000000000
  @s64_max 0x7FFFFFFFFFFFFFFF

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
  def chunk(node, view, name) do
    case native(node, view, name) do
      :fallback -> chunk_elixir(node, view, name)
      selection -> selection
    end
  end

  @doc false
  # The selection by the native kernel (spec/04 §4.1.1), reading `name`'s buffers in place,
  # where the kernels are loaded and the column and test are ones it reads; else, or where
  # the kernel hands the view back, `:fallback`.
  def native(%{"test" => test, "value" => value}, {chunk, first, count}, name) when name != nil do
    with true <- Native.active?(),
         {mode, data, validity, present, pass, ncodes} <-
           buffers(Chunk.packed(chunk, name), test, value) do
      missing = passes?(test, nil, value)
      code = Map.get(@codes, test, 0)
      x = if is_number(value), do: value, else: 0
      args = [mode, data, validity, first, count, code, x, present, missing, pass, ncodes]

      case Native.scheduler(count) do
        :normal -> apply(Kernels, :filter_mask, args)
        :dirty -> apply(Kernels, :filter_mask_dirty, args)
      end
    else
      _ -> :fallback
    end
  end

  def native(_node, _view, _name), do: :fallback

  # What the kernel reads of a column, `{mode, data, validity, present, pass, ncodes}`:
  # `present` and `absent` of any column whose validity bitmap says which rows are `nil`
  # (mode 0, the bitmap alone); a number column against a number within int64 or a float
  # (1, 2: the values compared); against any other value (0: every number stands so to a
  # term of another type, so one answer holds for every reading); a dictionary of strings
  # (3: each code's answer, decided once over the dictionary by the Elixir path's own test).
  # Any other column (a union, an integral, a list) or test is the Elixir path's.
  defp buffers(column, test, _value) when test in [:present, :absent] do
    case validity(column) do
      nil -> :elixir
      validity -> {0, <<>>, validity, test == :present, <<>>, 0}
    end
  end

  defp buffers({form, data, validity}, test, value) when form in [:int64, :float64] do
    cond do
      is_float(value) or (is_integer(value) and value >= @s64_min and value <= @s64_max) ->
        {if(form == :int64, do: 1, else: 2), data, validity, false, <<>>, 0}

      is_number(value) ->
        :elixir

      true ->
        {0, <<>>, validity, passes?(test, 0, value), <<>>, 0}
    end
  end

  defp buffers({:dictionary, codes, validity, dictionary, nil}, test, value) do
    strings = Column.dictionary_strings(dictionary)
    pass = Bitmap.from(strings, &passes?(test, &1, value))
    {3, codes, validity, false, pass, length(strings)}
  end

  defp buffers(_column, _test, _value), do: :elixir

  # A column's validity bitmap, where it alone says which rows are `nil`.
  defp validity({form, _data, validity}) when form in [:int64, :float64, :date, :bool],
    do: validity

  defp validity({form, _us, validity, _precision}) when form in [:utc, :naive], do: validity
  defp validity({:zoned, _us, validity, _precision, _zones, _codes}), do: validity
  defp validity({form, _offsets, _data, validity}) when form in [:text, :binary], do: validity
  defp validity({:dictionary, _codes, validity, _dictionary, _booleans}), do: validity
  defp validity({:integral, _data, validity, _integral}), do: validity
  defp validity(_column), do: nil

  @doc false
  # The selection by the Elixir path alone, whatever the kernels: the path a build without
  # them runs, and the reference the native kernel is held equal to.
  def chunk_elixir(%{"test" => test, "value" => value}, {chunk, first, count} = view, name) do
    packed =
      if name, do: Column.where(Chunk.storage(chunk, name, first, count), count, test, value)

    kept =
      case packed do
        {:ok, kept} -> kept
        _general -> view |> Transforms.view_values(name) |> kept(test, value, 0, [])
      end

    selected(kept, count)
  end

  # The rows whose readings pass, ascending: one pass, no index list built beside them.
  defp kept([reading | readings], test, value, i, acc) do
    acc = if passes?(test, reading, value), do: [i | acc], else: acc
    kept(readings, test, value, i + 1, acc)
  end

  defp kept([], _test, _value, _i, acc), do: :lists.reverse(acc)

  # The rows kept as a selection: every row, none, one run of them, cut without copying,
  # or the rows gathered.
  defp selected([], _count), do: :none
  defp selected(kept, count) when length(kept) == count, do: :all

  defp selected([a | _] = kept, _count) do
    n = length(kept)
    if List.last(kept) == a + n - 1, do: {:run, a, n}, else: {:rows, kept}
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
