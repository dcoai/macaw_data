defmodule Macaw.Data.Derived.Columns do
  @moduledoc """
  A derived function's input read as columns (spec/02 §2.2): accessors over a windowed
  input table that read its packed buffers and never make a row.

  A function whose source reads its inputs as columns (`input: :columns`) is handed each
  input as a `Macaw.Data.Table`, and reads it through these. A column is named by either
  spelling, its atom or its string (`Macaw.Layers.Names.same?/2`), as a row's field is
  read.

  **Every accessor answers `{:ok, value}` or `{:error, reason}`**, and raises on no input.
  The reasons (`format_error/1` words each):

  - `{:unknown_column, name}`: the table has no column `name` names;
  - `{:wrong_type, name, expected, actual}`: a typed accessor read column `name`, of type
    `actual`, which is none of the types in `expected`;
  - `{:type, :name}`: a column was named by something other than an atom or a string;
  - `{:type, :table}`: the input given is not a `Macaw.Data.Table`;
  - `{:type, :integer}`, `{:type, :non_neg_integer}`: `take/2`'s count is not an integer,
    or `slice/3`'s start or count is not a non-negative integer.

  Each has a `!` variant (`sum!/2`, …) that answers the value alone, or raises
  `ArgumentError` worded by `format_error/1`.

  - **What it holds:** `names/1`, `type/2`, `size/1`.
  - **Positional reads**, one value a row, in order, `nil` at a gap (`false` in
    `valid/2`), so two columns zip row by row: `column/2` the decoded values, as
    `Macaw.Data.Table.column/2` gives them; `numbers/2` a number column's; `instants/2` a
    time column's instants, integer Unix microseconds on
    `Macaw.Data.Source.Order.instant/1`'s scale (a naive time by its wall clock, a date
    by its midnight), read straight from the buffer; `valid/2` the presence mask; and
    `time_kind/2` the kind of time a time column holds, read from its storage form, for
    host code alone (not on the sandbox allowlist).
  - **Reductions** over the column's readings, its values present, with the semantics of
    the package's aggregates (spec/04 §5): `count/2`, `sum/2` (exact, `0` of none),
    `mean/2` (`nil` of none), and `min/2` and `max/2` of a number or a time column, the
    first on a tie, a time compared by its instant and answered as its value. With the
    native kernels loaded (`Macaw.Data.Native`), `sum`, `count` and `mean` read an int64
    or float64 buffer in the exact-sum kernel, and `min` and `max` find their slot in the
    extremes kernel, which reads an int64, float64 or int32 buffer; their Elixir path
    reads the same buffers and answers the same.
  - **Part of the input:** `slice/3` and `take/2` answer a table of some of its rows,
    views of its chunks, decoding nothing; `rows/1` is the row view, for a function that
    wants rows after all.

        iex> alias Macaw.Data.Derived.Columns
        iex> table = Macaw.Data.Table.new!([{"v", :number, [1.5, nil, 2.5]},
        ...>   {"t", :time, [~U[2026-01-01 00:00:00Z], ~U[2026-01-01 00:00:01Z], nil]}])
        iex> Columns.sum(table, :v)
        {:ok, 4.0}
        iex> Columns.valid(table, "v")
        {:ok, [true, false, true]}
        iex> Columns.instants!(table, "t")
        [1767225600000000, 1767225601000000, nil]
        iex> Columns.max(table, "t")
        {:ok, ~U[2026-01-01 00:00:01Z]}
        iex> Columns.take!(table, -1) |> Columns.column!("v")
        [2.5]
        iex> Columns.sum(table, "w")
        {:error, {:unknown_column, "w"}}
        iex> Columns.mean(table, "t")
        {:error, {:wrong_type, "t", [:number], :time}}
  """

  import Kernel, except: [min: 2, max: 2]

  alias Macaw.Data.{Exact, Native, Table}
  alias Macaw.Data.Native.Kernels
  alias Macaw.Data.Source.Order
  alias Macaw.Data.Table.{Bitmap, Chunk, Column}
  alias Macaw.Layers.Names

  @typedoc "A column's name, by either spelling."
  @type name :: atom() | String.t()

  @typedoc "Why an accessor answered no value (`format_error/1`)."
  @type reason ::
          {:unknown_column, term()}
          | {:wrong_type, Table.name(), [Table.type(), ...], Table.type()}
          | {:type, :name | :table | :integer | :non_neg_integer}

  @typedoc "An accessor's answer."
  @type result(value) :: {:ok, value} | {:error, reason()}

  # -- what it holds -----------------------------------------------------------------------

  @doc "The column names, in order, as the table spells them."
  @spec names(Table.t()) :: result([Table.name()])
  def names(%Table{} = table), do: {:ok, Table.names(table)}
  def names(_other), do: {:error, {:type, :table}}

  @doc "The column's declared type (`Macaw.Data.Table.types/0`)."
  @spec type(Table.t(), name()) :: result(Table.type())
  def type(table, name) do
    with {:ok, table, found} <- lookup(table, name),
         do: {:ok, Table.column_type(table, found)}
  end

  @doc "The number of rows."
  @spec size(Table.t()) :: result(non_neg_integer())
  def size(%Table{} = table), do: {:ok, Table.size(table)}
  def size(_other), do: {:error, {:type, :table}}

  # -- positional reads --------------------------------------------------------------------

  @doc """
  The column's values, in order, `nil` where one is missing, as
  `Macaw.Data.Table.column/2` decodes them.
  """
  @spec column(Table.t(), name()) :: result([term()])
  def column(table, name) do
    with {:ok, table, found} <- lookup(table, name), do: {:ok, Table.column(table, found)}
  end

  @doc "A number column's values, in order, `nil` where one is missing."
  @spec numbers(Table.t(), name()) :: result([number() | nil])
  def numbers(table, name) do
    with {:ok, table, found} <- typed(table, name, [:number]),
         do: {:ok, Table.column(table, found)}
  end

  @doc """
  A time column's instants, in order, `nil` where one is missing: integer Unix
  microseconds (`Macaw.Data.Source.Order.instant/1`), read from the buffer, no time made.
  """
  @spec instants(Table.t(), name()) :: result([integer() | nil])
  def instants(table, name) do
    with {:ok, table, found} <- typed(table, name, [:time]) do
      {:ok,
       Enum.flat_map(Table.chunks(ready(table)), fn {chunk, first, n} ->
         Chunk.instants(chunk, found, first, n)
       end)}
    end
  end

  @doc """
  The kind of time a `:time` column holds (macaw_data#149): `DateTime` (UTC or zoned,
  whose instants order alike), `NaiveDateTime` or `Date` when every chunk holding a value
  holds that one kind, else `:mixed`. It is read from each chunk's storage form alone
  (`Macaw.Data.Table.Chunk.time_kind/4`), so no value is decoded. A column with no value
  present, an empty table's included, packs as `DateTime` and answers it.

  It is for host code (visualize's board placement): a stored function cannot call it,
  since its answer is a module (spec/02 §6.2).

      iex> alias Macaw.Data.Derived.Columns
      iex> table = Macaw.Data.Table.new!([{"t", :time, [~N[2026-01-01 00:00:00], nil]}])
      iex> Columns.time_kind(table, "t")
      {:ok, NaiveDateTime}
      iex> Columns.time_kind(Macaw.Data.Table.new!([{"t", :time, [~D[2026-01-01], ~U[2026-01-01 00:00:00Z]]}]), :t)
      {:ok, :mixed}
  """
  @spec time_kind(Table.t(), name()) :: result(DateTime | NaiveDateTime | Date | :mixed)
  def time_kind(table, name) do
    with {:ok, table, found} <- typed(table, name, [:time]) do
      kinds =
        for {chunk, first, n} = view <- Table.chunks(ready(table)),
            kind = Chunk.time_kind(chunk, found, first, n),
            kind != DateTime or count_view(view, found) > 0,
            uniq: true,
            do: kind

      case kinds do
        [] -> {:ok, DateTime}
        [kind] -> {:ok, kind}
        _several -> {:ok, :mixed}
      end
    end
  end

  @doc "The column's presence mask, in order: `true` where a value is present."
  @spec valid(Table.t(), name()) :: result([boolean()])
  def valid(table, name) do
    with {:ok, table, found} <- lookup(table, name) do
      {:ok, Enum.flat_map(Table.chunks(ready(table)), &valid_view(&1, found))}
    end
  end

  defp valid_view({chunk, first, n}, name) do
    storage = Chunk.storage(chunk, name, first, n)

    case Column.validity(storage) do
      nil ->
        for value <- Column.values(storage, n), do: value != nil

      validity ->
        if Bitmap.all?(validity, n),
          do: List.duplicate(true, n),
          else: for(bit <- Bitmap.bits(validity, n), do: bit == 1)
    end
  end

  # -- reductions --------------------------------------------------------------------------

  @doc "The number of the column's readings: its values present."
  @spec count(Table.t(), name()) :: result(non_neg_integer())
  def count(table, name) do
    with {:ok, table, found} <- lookup(table, name),
         do: {:ok, each(table, 0, &(&2 + count_view(&1, found)))}
  end

  @doc """
  The exact sum of a number column's readings (spec/04 §5): an
  integer when every reading is one, else the exact sum rounded once; `0` of none.
  """
  @spec sum(Table.t(), name()) :: result(number())
  def sum(table, name) do
    with {:ok, table, found} <- typed(table, name, [:number]) do
      {sum, _readings} = each(table, {Exact.zero(), 0}, &merge(&2, sum_view(&1, found)))

      case Exact.value(sum) do
        {:ok, value} -> {:ok, value}
        {:error, :overflow} -> {:error, {:overflow, name}}
      end
    end
  end

  @doc """
  The arithmetic mean of a number column's readings, the exact sum over their count;
  `nil` of none.
  """
  @spec mean(Table.t(), name()) :: result(float() | nil)
  def mean(table, name) do
    with {:ok, table, found} <- typed(table, name, [:number]) do
      case each(table, {Exact.zero(), 0}, &merge(&2, sum_view(&1, found))) do
        {_sum, 0} ->
          {:ok, nil}

        {sum, n} ->
          case Exact.value(sum) do
            {:ok, value} -> {:ok, value / n}
            {:error, :overflow} -> {:error, {:overflow, name}}
          end
      end
    end
  end

  @doc """
  The least reading of a number or a time column, the first on a tie, `nil` of none: a
  time by its instant (`Macaw.Data.Source.Order.instant/1`), answered as its value.
  """
  @spec min(Table.t(), name()) ::
          result(number() | DateTime.t() | NaiveDateTime.t() | Date.t() | nil)
  def min(table, name), do: extreme(table, name, :lt)

  @doc """
  The greatest reading of a number or a time column, the first on a tie, `nil` of none: a
  time by its instant (`Macaw.Data.Source.Order.instant/1`), answered as its value.
  """
  @spec max(Table.t(), name()) ::
          result(number() | DateTime.t() | NaiveDateTime.t() | Date.t() | nil)
  def max(table, name), do: extreme(table, name, :gt)

  # -- part of the input -------------------------------------------------------------------

  @doc """
  The `count` rows from `start` (from 0), as a table of the same columns: views of the
  chunks they lie in, nothing decoded (`Macaw.Data.Table.slice/3`).
  """
  @spec slice(Table.t(), non_neg_integer(), non_neg_integer()) :: result(Table.t())
  def slice(%Table{} = table, start, count)
      when is_integer(start) and start >= 0 and is_integer(count) and count >= 0,
      do: {:ok, Table.slice(table, start, count)}

  def slice(%Table{}, _start, _count), do: {:error, {:type, :non_neg_integer}}
  def slice(_other, _start, _count), do: {:error, {:type, :table}}

  @doc """
  The first `n` rows, or with `n` negative the last `-n`, as a table of the same columns,
  as `Enum.take/2` takes.
  """
  @spec take(Table.t(), integer()) :: result(Table.t())
  def take(%Table{} = table, n) when is_integer(n) and n >= 0, do: {:ok, Table.slice(table, 0, n)}

  def take(%Table{} = table, n) when is_integer(n) do
    size = Table.size(table)
    {:ok, Table.slice(table, Kernel.max(size + n, 0), -n)}
  end

  def take(%Table{}, _n), do: {:error, {:type, :integer}}
  def take(_other, _n), do: {:error, {:type, :table}}

  @doc "The rows, one map a row keyed by every column name (`Macaw.Data.Table.rows/1`)."
  @spec rows(Table.t()) :: result([map()])
  def rows(%Table{} = table), do: {:ok, Table.rows(table)}
  def rows(_other), do: {:error, {:type, :table}}

  # -- the ! variants ----------------------------------------------------------------------

  @doc "As `names/1`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec names!(Table.t()) :: [Table.name()]
  def names!(table), do: value!(names(table))

  @doc "As `type/2`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec type!(Table.t(), name()) :: Table.type()
  def type!(table, name), do: value!(type(table, name))

  @doc "As `size/1`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec size!(Table.t()) :: non_neg_integer()
  def size!(table), do: value!(size(table))

  @doc "As `column/2`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec column!(Table.t(), name()) :: [term()]
  def column!(table, name), do: value!(column(table, name))

  @doc "As `numbers/2`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec numbers!(Table.t(), name()) :: [number() | nil]
  def numbers!(table, name), do: value!(numbers(table, name))

  @doc "As `instants/2`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec instants!(Table.t(), name()) :: [integer() | nil]
  def instants!(table, name), do: value!(instants(table, name))

  @doc "As `time_kind/2`, the kind, or `ArgumentError` worded by `format_error/1`."
  @spec time_kind!(Table.t(), name()) :: DateTime | NaiveDateTime | Date | :mixed
  def time_kind!(table, name), do: value!(time_kind(table, name))

  @doc "As `valid/2`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec valid!(Table.t(), name()) :: [boolean()]
  def valid!(table, name), do: value!(valid(table, name))

  @doc "As `count/2`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec count!(Table.t(), name()) :: non_neg_integer()
  def count!(table, name), do: value!(count(table, name))

  @doc "As `sum/2`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec sum!(Table.t(), name()) :: number()
  def sum!(table, name), do: value!(sum(table, name))

  @doc "As `mean/2`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec mean!(Table.t(), name()) :: float() | nil
  def mean!(table, name), do: value!(mean(table, name))

  @doc "As `min/2`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec min!(Table.t(), name()) :: number() | DateTime.t() | NaiveDateTime.t() | Date.t() | nil
  def min!(table, name), do: value!(min(table, name))

  @doc "As `max/2`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec max!(Table.t(), name()) :: number() | DateTime.t() | NaiveDateTime.t() | Date.t() | nil
  def max!(table, name), do: value!(max(table, name))

  @doc "As `slice/3`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec slice!(Table.t(), non_neg_integer(), non_neg_integer()) :: Table.t()
  def slice!(table, start, count), do: value!(slice(table, start, count))

  @doc "As `take/2`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec take!(Table.t(), integer()) :: Table.t()
  def take!(table, n), do: value!(take(table, n))

  @doc "As `rows/1`, the value, or `ArgumentError` worded by `format_error/1`."
  @spec rows!(Table.t()) :: [map()]
  def rows!(table), do: value!(rows(table))

  defp value!({:ok, value}), do: value
  defp value!({:error, reason}), do: raise(ArgumentError, format_error(reason))

  @doc """
  One reason as a line a person reads.

      iex> Macaw.Data.Derived.Columns.format_error({:wrong_type, "t", [:number], :time})
      ~s|column "t" is :time, not :number|
  """
  @spec format_error(reason()) :: String.t()
  def format_error({:unknown_column, name}), do: "the input has no column #{inspect(name)}"

  def format_error({:wrong_type, name, expected, actual}),
    do:
      "column #{inspect(name)} is #{inspect(actual)}, not #{Enum.map_join(expected, " or ", &inspect/1)}"

  def format_error({:overflow, name}),
    do: "column #{inspect(name)} sums beyond a float's range, so no float holds its sum"

  def format_error({:type, :name}), do: "a column is named by an atom or a string"
  def format_error({:type, :table}), do: "the input read is not a Macaw.Data.Table"
  def format_error({:type, :integer}), do: "take/2 takes an integer count"

  def format_error({:type, :non_neg_integer}),
    do: "slice/3 takes a start and a count that are non-negative integers"

  # -- the views ---------------------------------------------------------------------------

  # The table and the column `name` names in it, by either spelling.
  defp lookup(%Table{} = table, name) when is_atom(name) or is_binary(name) do
    case Enum.find(Table.names(table), &Names.same?(&1, name)) do
      nil -> {:error, {:unknown_column, name}}
      found -> {:ok, table, found}
    end
  end

  defp lookup(%Table{}, _name), do: {:error, {:type, :name}}
  defp lookup(_other, _name), do: {:error, {:type, :table}}

  # As `lookup/2`, the column of one of `types`.
  defp typed(table, name, types) do
    with {:ok, table, found} <- lookup(table, name) do
      type = Table.column_type(table, found)

      if type in types,
        do: {:ok, table, found},
        else: {:error, {:wrong_type, found, types, type}}
    end
  end

  # A table some chunk of which is cold with its count pending, warmed (spec/01 §1.1.4).
  defp ready(table) do
    if Enum.any?(Table.chunks(table), fn {_chunk, _first, count} -> count == nil end),
      do: Table.warm(table),
      else: table
  end

  defp each(table, acc, fun),
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
    with {:ok, table, name} <- typed(table, name, [:number, :time]) do
      type = Table.column_type(table, name)

      best =
        each(table, nil, fn view, best ->
          case view_extreme(view, name, type, side) do
            nil -> best
            candidate -> better(best, candidate, side)
          end
        end)

      case best do
        nil -> {:ok, nil}
        {_key, value} -> {:ok, value}
      end
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
