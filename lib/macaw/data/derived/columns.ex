defmodule Macaw.Data.Derived.Columns do
  @moduledoc """
  A derived function's input read as columns (spec/02 §2.2): accessors over a windowed
  input table that read its packed buffers and never make a row.

  A function whose source reads its inputs as columns (`input: :columns`) is handed each
  input as a `Macaw.Data.Table`, and reads it through these. A column is named by either
  spelling, its atom or its string (`Macaw.Layers.Names.same?/2`), as a row's field is
  read; a name the table lacks, and a typed accessor on a column of another type, raise
  `ArgumentError`, so a function that reads what is not there fails at once.

  - **What it holds:** `names/1`, `type/2`, `size/1`.
  - **Positional reads**, one value a row, in order, `nil` at a gap (`false` in
    `valid/2`), so two columns zip row by row: `column/2` the decoded values, as
    `Macaw.Data.Table.column/2` gives them; `numbers/2` a number column's; `instants/2` a
    time column's instants, integer Unix microseconds on
    `Macaw.Data.Source.Order.instant/1`'s scale (a naive time by its wall clock, a date
    by its midnight), read straight from the buffer; `valid/2` the presence mask.
  - **Reductions** over the column's readings, its values present, with the semantics of
    the package's aggregates (spec/04 §5): `count/2`, `sum/2` (exact,
    `0` of none), `mean/2` (`nil` of none), and `min/2` and `max/2`
    of a number or a time column, the first on a tie, a time compared by its instant and
    answered as its value. With the native kernels loaded (`Macaw.Data.Native`), `sum`,
    `count` and `mean` read an int64 or float64 buffer in the exact-sum kernel, and `min`
    and `max` find their slot in the extremes kernel, which reads an int64, float64 or
    int32 buffer; their Elixir path reads the same buffers and answers the same.
  - **Part of the input:** `slice/3` and `take/2` answer a table of some of its rows,
    views of its chunks, decoding nothing; `rows/1` is the row view, for a function that
    wants rows after all.

        iex> alias Macaw.Data.Derived.Columns
        iex> table = Macaw.Data.Table.new!([{"v", :number, [1.5, nil, 2.5]},
        ...>   {"t", :time, [~U[2026-01-01 00:00:00Z], ~U[2026-01-01 00:00:01Z], nil]}])
        iex> Columns.sum(table, :v)
        4.0
        iex> Columns.valid(table, "v")
        [true, false, true]
        iex> Columns.instants(table, "t")
        [1767225600000000, 1767225601000000, nil]
        iex> Columns.max(table, "t")
        ~U[2026-01-01 00:00:01Z]
        iex> Columns.take(table, -1) |> Columns.column("v")
        [2.5]
  """

  alias Macaw.Data.{Exact, Native, Table}
  alias Macaw.Data.Native.Kernels
  alias Macaw.Data.Source.Order
  alias Macaw.Data.Table.{Bitmap, Chunk, Column}
  alias Macaw.Layers.Names

  @typedoc "A column's name, by either spelling."
  @type name :: atom() | String.t()

  # -- what it holds -----------------------------------------------------------------------

  @doc "The column names, in order, as the table spells them."
  @spec names(Table.t()) :: [Table.name()]
  def names(%Table{} = table), do: Table.names(table)

  @doc "The column's declared type (`Macaw.Data.Table.types/0`)."
  @spec type(Table.t(), name()) :: Table.type()
  def type(%Table{} = table, name), do: Table.column_type(table, column!(table, name))

  @doc "The number of rows."
  @spec size(Table.t()) :: non_neg_integer()
  def size(%Table{} = table), do: Table.size(table)

  # -- positional reads --------------------------------------------------------------------

  @doc """
  The column's values, in order, `nil` where one is missing, as
  `Macaw.Data.Table.column/2` decodes them.
  """
  @spec column(Table.t(), name()) :: [term()]
  def column(%Table{} = table, name), do: Table.column(table, column!(table, name))

  @doc "A number column's values, in order, `nil` where one is missing."
  @spec numbers(Table.t(), name()) :: [number() | nil]
  def numbers(%Table{} = table, name), do: Table.column(table, typed!(table, name, [:number]))

  @doc """
  A time column's instants, in order, `nil` where one is missing: integer Unix
  microseconds (`Macaw.Data.Source.Order.instant/1`), read from the buffer, no time made.
  """
  @spec instants(Table.t(), name()) :: [integer() | nil]
  def instants(%Table{} = table, name) do
    name = typed!(table, name, [:time])
    table = ready(table)

    Enum.flat_map(Table.chunks(table), fn {chunk, first, n} ->
      Chunk.instants(chunk, name, first, n)
    end)
  end

  @doc "The column's presence mask, in order: `true` where a value is present."
  @spec valid(Table.t(), name()) :: [boolean()]
  def valid(%Table{} = table, name) do
    name = column!(table, name)
    table = ready(table)

    Enum.flat_map(Table.chunks(table), fn {chunk, first, n} ->
      storage = Chunk.storage(chunk, name, first, n)

      case Column.validity(storage) do
        nil ->
          for value <- Column.values(storage, n), do: value != nil

        validity ->
          if Bitmap.all?(validity, n),
            do: List.duplicate(true, n),
            else: for(bit <- Bitmap.bits(validity, n), do: bit == 1)
      end
    end)
  end

  # -- reductions --------------------------------------------------------------------------

  @doc "The number of the column's readings: its values present."
  @spec count(Table.t(), name()) :: non_neg_integer()
  def count(%Table{} = table, name) do
    name = column!(table, name)
    each(table, name, 0, &(&2 + count_view(&1, name)))
  end

  @doc """
  The exact sum of a number column's readings (spec/04 §5): an
  integer when every reading is one, else the exact sum rounded once; `0` of none.
  """
  @spec sum(Table.t(), name()) :: number()
  def sum(%Table{} = table, name) do
    name = typed!(table, name, [:number])
    {sum, _readings} = each(table, name, {Exact.zero(), 0}, &merge(&2, sum_view(&1, name)))
    Exact.value(sum)
  end

  @doc "The arithmetic mean of a number column's readings, the exact sum over their count; `nil` of none."
  @spec mean(Table.t(), name()) :: float() | nil
  def mean(%Table{} = table, name) do
    name = typed!(table, name, [:number])

    case each(table, name, {Exact.zero(), 0}, &merge(&2, sum_view(&1, name))) do
      {_sum, 0} -> nil
      {sum, n} -> Exact.value(sum) / n
    end
  end

  @doc """
  The least reading of a number or a time column, the first on a tie, `nil` of none: a
  time by its instant (`Macaw.Data.Source.Order.instant/1`), answered as its value.
  """
  @spec min(Table.t(), name()) :: number() | DateTime.t() | NaiveDateTime.t() | Date.t() | nil
  def min(%Table{} = table, name), do: extreme(table, name, :lt)

  @doc """
  The greatest reading of a number or a time column, the first on a tie, `nil` of none: a
  time by its instant (`Macaw.Data.Source.Order.instant/1`), answered as its value.
  """
  @spec max(Table.t(), name()) :: number() | DateTime.t() | NaiveDateTime.t() | Date.t() | nil
  def max(%Table{} = table, name), do: extreme(table, name, :gt)

  # -- part of the input -------------------------------------------------------------------

  @doc """
  The `count` rows from `start` (from 0), as a table of the same columns: views of the
  chunks they lie in, nothing decoded (`Macaw.Data.Table.slice/3`).
  """
  @spec slice(Table.t(), non_neg_integer(), non_neg_integer()) :: Table.t()
  def slice(%Table{} = table, start, count), do: Table.slice(table, start, count)

  @doc """
  The first `n` rows, or with `n` negative the last `-n`, as a table of the same columns,
  as `Enum.take/2` takes.
  """
  @spec take(Table.t(), integer()) :: Table.t()
  def take(%Table{} = table, n) when is_integer(n) and n >= 0, do: Table.slice(table, 0, n)

  def take(%Table{} = table, n) when is_integer(n) do
    size = Table.size(table)
    Table.slice(table, Kernel.max(size + n, 0), -n)
  end

  @doc "The rows, one map a row keyed by every column name (`Macaw.Data.Table.rows/1`)."
  @spec rows(Table.t()) :: [map()]
  def rows(%Table{} = table), do: Table.rows(table)

  # -- the views ---------------------------------------------------------------------------

  # The table's column `name` names, by either spelling, else ArgumentError.
  defp column!(table, name) when is_atom(name) or is_binary(name) do
    case Enum.find(Table.names(table), &Names.same?(&1, name)) do
      nil -> raise ArgumentError, "the input has no column #{inspect(name)}"
      found -> found
    end
  end

  defp column!(_table, name),
    do: raise(ArgumentError, "a column is named by an atom or a string, got #{inspect(name)}")

  defp typed!(table, name, types) do
    found = column!(table, name)
    type = Table.column_type(table, found)

    if type in types,
      do: found,
      else:
        raise(
          ArgumentError,
          "column #{inspect(found)} is #{inspect(type)}, not #{Enum.map_join(types, " or ", &inspect/1)}"
        )
  end

  # A table some chunk of which is cold with its count pending, warmed (spec/01 §1.1.4).
  defp ready(table) do
    if Enum.any?(Table.chunks(table), fn {_chunk, _first, count} -> count == nil end),
      do: Table.warm(table),
      else: table
  end

  defp each(table, _name, acc, fun),
    do: table |> ready() |> Table.chunks() |> Enum.reduce(acc, &fun.(&1, &2))

  # -- count and sum -----------------------------------------------------------------------

  defp count_view({chunk, first, n}, name) do
    storage = Chunk.storage(chunk, name, first, n)

    case Column.validity(storage) do
      nil -> Enum.count(Column.values(storage, n), &(&1 != nil))
      validity -> ones(validity, n)
    end
  end

  # The set bits of a bitmap's first `n`, its padding 0.
  defp ones(validity, n) do
    if Bitmap.all?(validity, n),
      do: n,
      else: for(<<byte <- validity>>, reduce: 0, do: (acc -> acc + Integer.popcount(byte)))
  end

  defp merge({sum, n}, {other, m}), do: {Exact.merge(sum, other), n + m}

  # One view's exact sum and readings: by the kernel where it is active and the column an
  # int64 or float64 buffer, else read from the buffer, else from the values.
  defp sum_view({chunk, first, n} = view, name) do
    case native_sum(view, name) do
      :fallback -> elixir_sum(Chunk.storage(chunk, name, first, n), n)
      sum -> sum
    end
  end

  defp native_sum({chunk, first, n}, name) do
    with true <- Native.active?(),
         {form, data, validity} <- sum_buffers(Chunk.packed(chunk, name)) do
      call = &Kernels.group_sum(form, data, validity, false, <<>>, <<>>, 0, first, n, &1)
      dirty = &Kernels.group_sum_dirty(form, data, validity, false, <<>>, <<>>, 0, first, n, &1)

      answer =
        case Native.scheduler(n) do
          :normal -> call.(Native.entry_limit()) |> redo(dirty)
          :dirty -> dirty.(0)
        end

      case answer do
        :fallback -> :fallback
        [] -> {Exact.zero(), 0}
        [{_code, _first, _rows, readings, ints, floats}] -> {{ints, floats}, readings}
      end
    else
      _elixir -> :fallback
    end
  end

  defp redo(:dirty, dirty), do: dirty.(0)
  defp redo(answer, _dirty), do: answer

  defp sum_buffers({:int64, data, validity}), do: {0, data, validity}
  defp sum_buffers({:float64, data, validity}), do: {1, data, validity}
  defp sum_buffers(_column), do: :elixir

  # A missing slot holds zero, so a buffer's slots are summed whole: a zero adds nothing to
  # an exact sum's value.
  defp elixir_sum({:int64, data, validity}, n),
    do: {{int_sum(data, 0), nil}, ones(validity, n)}

  defp elixir_sum({:float64, data, validity}, n) do
    case ones(validity, n) do
      0 -> {Exact.zero(), 0}
      readings -> {float_sum(data, Exact.zero()), readings}
    end
  end

  defp elixir_sum(storage, n) do
    storage
    |> Column.values(n)
    |> Enum.reduce({Exact.zero(), 0}, fn
      nil, acc -> acc
      value, {sum, k} -> {Exact.add(sum, value), k + 1}
    end)
  end

  defp int_sum(<<v::signed-little-64, rest::binary>>, acc), do: int_sum(rest, acc + v)
  defp int_sum(<<>>, acc), do: acc

  defp float_sum(<<v::float-little-64, rest::binary>>, acc),
    do: float_sum(rest, Exact.add(acc, v))

  defp float_sum(<<>>, acc), do: acc

  # -- min and max -------------------------------------------------------------------------

  # The first least (`:lt`) or greatest (`:gt`) reading over the views, each view's found
  # by its key: a number its value, a time its instant.
  defp extreme(table, name, side) do
    name = typed!(table, name, [:number, :time])
    type = Table.column_type(table, name)

    best =
      each(table, name, nil, fn view, best ->
        case view_extreme(view, name, type, side) do
          nil -> best
          candidate -> better(best, candidate, side)
        end
      end)

    case best do
      nil -> nil
      {_key, value} -> value
    end
  end

  defp better(nil, candidate, _side), do: candidate

  defp better({key, _value} = best, {other, _} = candidate, side),
    do: if(beats?(other, key, side), do: candidate, else: best)

  defp beats?(a, b, :lt), do: a < b
  defp beats?(a, b, :gt), do: a > b

  # One view's extreme reading as `{key, value}`, `nil` of none.
  defp view_extreme({chunk, first, n} = view, name, type, side) do
    case native_extreme(view, name, side) do
      :fallback ->
        storage = Chunk.storage(chunk, name, first, n)
        keyed(storage, n, type) |> first_extreme(side) |> at(storage)

      answer ->
        answer
    end
  end

  # The kernel's slot, where it is active and the column a buffer it reads; its key and
  # value decoded from that one slot.
  defp native_extreme({chunk, first, n}, name, side) do
    with true <- Native.active?(),
         packed = Chunk.packed(chunk, name),
         {form, data, validity} <- extreme_buffers(packed) do
      answer =
        case Native.scheduler(n) do
          :normal -> Kernels.extremes(form, data, validity, first, n)
          :dirty -> Kernels.extremes_dirty(form, data, validity, first, n)
        end

      case answer do
        :fallback ->
          :fallback

        nil ->
          nil

        {lo, hi} ->
          i = if side == :lt, do: lo, else: hi
          slot(Chunk.storage(chunk, name, first + i, 1))
      end
    else
      _elixir -> :fallback
    end
  end

  defp extreme_buffers({:int64, data, validity}), do: {0, data, validity}
  defp extreme_buffers({:float64, data, validity}), do: {1, data, validity}
  defp extreme_buffers({:integral, data, validity, _integral}), do: {1, data, validity}

  defp extreme_buffers({form, us, validity, _p}) when form in [:utc, :naive],
    do: {0, us, validity}

  defp extreme_buffers({:zoned, us, validity, _p, _zones, _codes}), do: {0, us, validity}
  defp extreme_buffers({:date, days, validity}), do: {2, days, validity}
  defp extreme_buffers(_column), do: :elixir

  # A one-slot column's key and value.
  defp slot(storage) do
    [value] = Column.values(storage, 1)
    {key(value), value}
  end

  defp key(value) when is_number(value), do: value
  defp key(value), do: Order.instant(value)

  # The view's keys in order, `nil` at a gap: a number column's values, a time column's
  # instants, read from its buffer where it is packed.
  defp keyed(storage, n, :number), do: Column.values(storage, n)

  defp keyed(storage, n, :time) do
    case Column.instants(storage, n) do
      :general -> storage |> Column.values(n) |> Enum.map(&Order.instant/1)
      instants -> instants
    end
  end

  # The index of the first least or greatest key, `nil` of none.
  defp first_extreme(keys, side), do: first_extreme(keys, side, 0, nil, nil)

  defp first_extreme([nil | keys], side, i, best, at),
    do: first_extreme(keys, side, i + 1, best, at)

  defp first_extreme([key | keys], side, i, best, at) do
    if best == nil or beats?(key, best, side),
      do: first_extreme(keys, side, i + 1, key, i),
      else: first_extreme(keys, side, i + 1, best, at)
  end

  defp first_extreme([], _side, _i, _best, at), do: at

  defp at(nil, _storage), do: nil
  defp at(i, storage), do: slot(Column.slice(storage, i, 1))
end
