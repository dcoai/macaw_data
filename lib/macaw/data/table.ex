defmodule Macaw.Data.Table do
  @moduledoc """
  Columnar typed data: the currency of deliveries, derived sources and components
  (spec/01 §1.1).

  A table is named columns of declared types, every column the same length:

  | Type | Holds | Stored as |
  |---|---|---|
  | `:number` | integers and floats | one packed binary: signed 64-bit integers when every value is an integer that fits, else 64-bit floats |
  | `:time` | `DateTime`s | one packed binary of signed 64-bit microseconds since the Unix epoch, UTC |
  | `:category`, `:text`, `:color`, `:point`, `:term` | any value | a list |

  **A missing value is `nil`,** in every type. A packed column keeps a validity bitmap
  beside its binary, so a gap stays a gap: absence is never zero (spec/01 §3).

  **The packed columns live off the process heap.** A binary over 64 bytes is
  reference-counted, so a garbage collection never copies it: a table of a million numbers
  costs its process a constant number of words, whatever its length.

  **Row lists are accepted at the edge.** `from/2` reads every shape data arrives in (a
  list of row maps, a map or keyword list of columns, an `Nx.Tensor`, anything implementing
  `Table.Reader`) into a table, and `rows/1` is the row view for code that wants rows. The
  row helpers (`get/2`, `key/2`, `accessor/1`, `temporal?/1`, `time_columns/1`,
  `column_types/1`) read any source, as visualize's `Visualize.Data.Table` does; this
  module's row readers are its port.

  The `table` package and Nx are optional: without them lists and column maps still work,
  and a struct source or a tensor raises `UndefinedFunctionError` where it is read.
  """

  @compile {:no_warn_undefined, [Table, Nx]}

  @enforce_keys [:names, :columns, :size]
  defstruct [:names, :columns, :size]

  @types [:number, :time, :category, :text, :color, :point, :term]
  @s64 -0x8000000000000000..0x7FFFFFFFFFFFFFFF

  @typedoc "A column name, as the source spells it."
  @type name :: atom() | String.t()

  @typedoc "A column's declared type."
  @type type :: :number | :time | :category | :text | :color | :point | :term

  @typedoc "A row: a map keyed by column name, or a tuple in column order."
  @type row :: map() | tuple()

  @typedoc """
  Anything `from/2` and `rows/1` accept: a list of rows, a keyword list or map of
  equal-length columns, an `Nx.Tensor` of rank 1 or 2, or a struct implementing
  `Table.Reader`.
  """
  @type source :: [row()] | %{name() => [term()]} | [{name(), [term()]}] | struct()

  @typedoc "One column: its type, its storage and, when packed, its validity bitmap."
  @type column ::
          {:s64 | :f64 | :us, binary(), bitstring()} | {:list, [term()]}

  @typedoc "A table."
  @type t :: %__MODULE__{
          names: [name()],
          columns: %{name() => {type(), column()}},
          size: non_neg_integer()
        }

  @doc "The column types, in the order spec/01 §1.1 lists them."
  @spec types() :: [type(), ...]
  def types, do: @types

  # -- building ---------------------------------------------------------------------------

  @doc """
  A table of `columns`, each `{name, type, values}`, in order.

  `{:ok, table}`, or every fault: `{[name], {:enum, types}}` for an unknown type,
  `{[name, i], {:type, type}}` for a value its type does not hold, `{[name], {:length, n}}`
  for a column whose length is not the first column's `n`, `{[name], :duplicate}` for a
  name given twice. A number column holds numbers; a time column `DateTime`s; a point
  column `{longitude, latitude}` pairs of numbers; the others any value. `nil` is missing
  in every type.
  """
  @spec new([{name(), type(), [term()]}]) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def new(columns) when is_list(columns) do
    size =
      case columns do
        [{_, _, values} | _] when is_list(values) -> length(values)
        _ -> 0
      end

    {built, faults} =
      columns
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {{name, type, values}, i}, {built, faults} ->
        cond do
          Enum.any?(Enum.take(columns, i), &(elem(&1, 0) == name)) ->
            {built, [{[name], :duplicate} | faults]}

          type not in @types ->
            {built, [{[name], {:enum, @types}} | faults]}

          not is_list(values) or length(values) != size ->
            {built, [{[name], {:length, size}} | faults]}

          true ->
            case column(type, values, name) do
              {:ok, col} -> {[{name, {type, col}} | built], faults}
              {:error, column_faults} -> {built, column_faults ++ faults}
            end
        end
      end)

    case faults do
      [] ->
        built = Enum.reverse(built)

        {:ok,
         %__MODULE__{names: Enum.map(built, &elem(&1, 0)), columns: Map.new(built), size: size}}

      _ ->
        {:error, Enum.sort_by(Enum.reverse(faults), &elem(&1, 0))}
    end
  end

  @doc "As `new/1`, raising `ArgumentError` naming every fault."
  @spec new!([{name(), type(), [term()]}]) :: t()
  def new!(columns) do
    case new(columns) do
      {:ok, table} -> table
      {:error, faults} -> raise ArgumentError, "not a table: #{inspect(faults)}"
    end
  end

  @doc """
  A table of any source `rows/1` reads.

  Columns are named by every key of every row map, in term order, a row without the key
  missing there. Each column's type is `types:`'s (a map from name to type) when given,
  else the one `column_types/1` infers, else `:term`. A time column's values become
  `DateTime`s here, at the edge: a `Date` at midnight UTC, a `NaiveDateTime` as UTC, an
  ISO 8601 string parsed. A source whose rows are tuples has
  no names; `named/2` gives it some first. `{:ok, table}` or `new/1`'s faults.
  """
  @spec from(source() | t(), keyword()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def from(source, opts \\ [])
  def from(%__MODULE__{} = table, _opts), do: {:ok, table}

  def from(source, opts) do
    rows = rows(source)
    given = Keyword.get(opts, :types, %{})
    inferred = infer(rows)

    rows
    |> column_names()
    |> Enum.map(fn name ->
      type = Map.get(given, name) || Map.get(inferred, name, :term)
      values = Enum.map(rows, &Map.get(&1, name))
      {name, type, if(type == :time, do: Enum.map(values, &to_datetime/1), else: values)}
    end)
    |> new()
  end

  # A time at the edge: a `Date` at midnight UTC, a `NaiveDateTime` taken as UTC, an
  # ISO 8601 string parsed as one of those; anything else as it is, for `new/1` to refuse.
  defp to_datetime(%DateTime{} = t), do: t
  defp to_datetime(%NaiveDateTime{} = t), do: DateTime.from_naive!(t, "Etc/UTC")
  defp to_datetime(%Date{} = d), do: DateTime.new!(d, ~T[00:00:00], "Etc/UTC")

  defp to_datetime(string) when is_binary(string) do
    with {:error, _} <- DateTime.from_iso8601(string),
         {:error, _} <- NaiveDateTime.from_iso8601(string),
         {:error, _} <- Date.from_iso8601(string) do
      string
    else
      {:ok, t, _offset} -> t
      {:ok, t} -> to_datetime(t)
    end
  end

  defp to_datetime(other), do: other

  defp column(:number, values, name) do
    case faults(values, name, &is_number/1, :number) do
      [] ->
        valid = validity(values)

        if Enum.all?(values, &(is_nil(&1) or (is_integer(&1) and &1 in @s64))),
          do: {:ok, {:s64, pack(values, &<<&1::signed-little-64>>, <<0::64>>), valid}},
          else: {:ok, {:f64, pack(values, &<<&1 / 1::float-little-64>>, <<0::64>>), valid}}

      faults ->
        {:error, faults}
    end
  end

  defp column(:time, values, name) do
    case faults(values, name, &match?(%DateTime{}, &1), :time) do
      [] ->
        us = &<<DateTime.to_unix(&1, :microsecond)::signed-little-64>>
        {:ok, {:us, pack(values, us, <<0::64>>), validity(values)}}

      faults ->
        {:error, faults}
    end
  end

  defp column(:point, values, name) do
    point? = &match?({lon, lat} when is_number(lon) and is_number(lat), &1)

    case faults(values, name, point?, :point) do
      [] -> {:ok, {:list, values}}
      faults -> {:error, faults}
    end
  end

  defp column(_type, values, _name), do: {:ok, {:list, values}}

  defp faults(values, name, ok?, type) do
    for {v, i} <- Enum.with_index(values), v != nil, not ok?.(v), do: {[name, i], {:type, type}}
  end

  defp pack(values, encode, zero),
    do: values |> Enum.map(&if(is_nil(&1), do: zero, else: encode.(&1))) |> IO.iodata_to_binary()

  defp validity(values),
    do: for(v <- values, into: <<>>, do: <<if(is_nil(v), do: 0, else: 1)::1>>)

  # -- reading ----------------------------------------------------------------------------

  @doc "The number of rows."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc "The column names, in order."
  @spec names(t()) :: [name()]
  def names(%__MODULE__{names: names}), do: names

  @doc "Each column's type, by name."
  @spec column_type(t(), name()) :: type() | nil
  def column_type(%__MODULE__{columns: columns}, name) do
    case columns do
      %{^name => {type, _}} -> type
      _ -> nil
    end
  end

  @doc """
  The values of column `name`, in order, `nil` where a value is missing; `nil` for a name
  the table does not have. A number column of integers reads back integers; of floats, or
  of both, floats. A time column reads back `DateTime`s in UTC at microsecond precision.
  """
  @spec column(t(), name()) :: [term()] | nil
  def column(%__MODULE__{columns: columns}, name) do
    case columns do
      %{^name => {_type, col}} -> values(col)
      _ -> nil
    end
  end

  defp values({:list, list}), do: list
  defp values({:s64, bin, valid}), do: unpack(bin, valid, fn <<n::signed-little-64>> -> n end)
  defp values({:f64, bin, valid}), do: unpack(bin, valid, fn <<f::float-little-64>> -> f end)

  defp values({:us, bin, valid}),
    do:
      unpack(bin, valid, fn <<us::signed-little-64>> -> DateTime.from_unix!(us, :microsecond) end)

  defp unpack(bin, valid, decode) do
    words = for <<w::binary-size(8) <- bin>>, do: w
    bits = for <<b::1 <- valid>>, do: b
    Enum.zip_with(words, bits, fn w, b -> if b == 1, do: decode.(w) end)
  end

  @doc "The rows, one map per row keyed by every column name, `nil` where missing."
  @spec rows(source() | t()) :: [row()]
  def rows(%__MODULE__{names: names} = table) do
    case names do
      [] ->
        List.duplicate(%{}, table.size)

      _ ->
        names
        |> Enum.map(&column(table, &1))
        |> Enum.zip_with(fn values -> names |> Enum.zip(values) |> Map.new() end)
    end
  end

  def rows([]), do: []
  # A delivery's rows as they are (macaw#185). A map pattern, so this module needs no
  # delivery at compile time.
  def rows(%{__struct__: Macaw.Data.Delivery, rows: rows}), do: rows(rows)
  # A map pattern, not `%Nx.Tensor{}`: a struct pattern needs the struct defined at
  # compile time, and a consumer without Nx has none.
  def rows(%{__struct__: Nx.Tensor} = tensor), do: tensor_rows(tensor, Nx.rank(tensor))
  def rows(%_{} = struct), do: struct |> Table.to_rows() |> Enum.to_list()
  def rows(map) when map_size(map) == 0, do: []
  def rows(map) when is_map(map), do: column_rows(Map.to_list(map))

  def rows([first | _] = list) do
    if columns?(list, first), do: column_rows(list), else: list
  end

  @doc "Row `i` (from 0) as a map, or `nil` past the end."
  @spec row(t(), non_neg_integer()) :: map() | nil
  def row(%__MODULE__{size: size}, i) when i >= size, do: nil

  def row(%__MODULE__{names: names} = table, i) when is_integer(i) and i >= 0,
    do: Map.new(names, &{&1, Enum.at(column(table, &1), i)})

  @doc """
  The rows `start` to `start + count - 1`, as a table of the same columns: a packed
  column's binary is sliced, not copied.
  """
  @spec slice(t(), non_neg_integer(), non_neg_integer()) :: t()
  def slice(%__MODULE__{size: size} = table, start, count)
      when is_integer(start) and start >= 0 and is_integer(count) and count >= 0 do
    first = min(start, size)
    n = min(count, size - first)

    columns =
      Map.new(table.columns, fn
        {name, {type, {:list, list}}} ->
          {name, {type, {:list, Enum.slice(list, first, n)}}}

        {name, {type, {kind, bin, valid}}} ->
          <<_::bitstring-size(^first), bits::bitstring-size(^n), _::bitstring>> = valid
          {name, {type, {kind, binary_part(bin, first * 8, n * 8), bits}}}
      end)

    %__MODULE__{table | columns: columns, size: n}
  end

  # -- row helpers, for any source ---------------------------------------------------------

  @doc """
  A tensor's columns, or tuple rows' elements, under `names`, in order.

  Column `i` of a rank-2 tensor is `Enum.at(names, i)`, and a rank-1 tensor is one column.
  A tensor whose width is not `length(names)` is `{:error, {:width, length(names), width}}`,
  one of another rank `{:error, {:rank, rank}}`. Tuple rows are named row by row, element
  `i` under `Enum.at(names, i)`; a tuple of another size is `{:error, {:width, n, size}}`.
  Any other source is `{:ok, source}`, unchanged.

      iex> Macaw.Data.Table.named([{1, 4.0}, {2, 5.0}], ["x", "y"])
      {:ok, [%{"x" => 1, "y" => 4.0}, %{"x" => 2, "y" => 5.0}]}
      iex> Macaw.Data.Table.named([{1, 4.0, 7}], ["x", "y"])
      {:error, {:width, 2, 3}}
  """
  @spec named(source(), [name()]) ::
          {:ok, source()}
          | {:error, {:width, non_neg_integer(), non_neg_integer()} | {:rank, non_neg_integer()}}
  def named(%{__struct__: Nx.Tensor} = tensor, names) when is_list(names) do
    case {Nx.rank(tensor), length(names)} do
      {1, 1} -> {:ok, %{hd(names) => Nx.to_list(tensor)}}
      {1, n} -> {:error, {:width, n, 1}}
      {2, n} -> named_columns(tensor, names, Nx.axis_size(tensor, 1), n)
      {rank, _n} -> {:error, {:rank, rank}}
    end
  end

  def named([first | _] = rows, names) when is_tuple(first) and is_list(names) do
    if columns?(rows, first), do: {:ok, rows}, else: named_rows(rows, names, length(names))
  end

  def named(source, names) when is_list(names), do: {:ok, source}

  @doc """
  Whether a source's rows have no names: a tensor, or tuple rows (a list whose first
  row is a tuple and which is not a keyword list of columns). `named/2` gives them some.

      iex> Macaw.Data.Table.unnamed?([{1, 4.0}])
      true
      iex> Macaw.Data.Table.unnamed?([x: [1, 2]])
      false
  """
  @spec unnamed?(term()) :: boolean()
  def unnamed?(%{__struct__: Nx.Tensor}), do: true
  def unnamed?([first | _] = rows) when is_tuple(first), do: not columns?(rows, first)
  def unnamed?(_source), do: false

  defp named_rows(rows, names, n) do
    rows
    |> Enum.reduce_while([], fn
      row, acc when is_tuple(row) and tuple_size(row) == n ->
        {:cont, [names |> Enum.zip(Tuple.to_list(row)) |> Map.new() | acc]}

      row, _acc when is_tuple(row) ->
        {:halt, {:error, {:width, n, tuple_size(row)}}}

      row, acc ->
        {:cont, [row | acc]}
    end)
    |> case do
      {:error, _width} = error -> error
      named -> {:ok, Enum.reverse(named)}
    end
  end

  defp named_columns(tensor, names, n, n),
    do: {:ok, names |> Enum.zip(tensor |> Nx.transpose() |> Nx.to_list()) |> Map.new()}

  defp named_columns(_tensor, _names, width, n), do: {:error, {:width, n, width}}

  @doc """
  The value of column `name` in `row`, by either spelling of the name: the key itself, else
  an atom name as its string and a string name as the atom key spelled the same. `nil`
  when neither is a key. No atom is ever made.
  """
  @spec get(map(), name()) :: term()
  def get(row, name) do
    case key(row, name) do
      nil -> nil
      key -> Map.fetch!(row, key)
    end
  end

  @doc """
  The key of `row` that spells `name`: `name` itself when it is a key, else the key of the
  other spelling, `nil` when neither is. The atom key a string finds is remembered for the
  calling process, so reading one field from every row scans one row's keys. No atom is
  ever made or looked up by name: the remembered key is one a row held.

      iex> Macaw.Data.Table.key(%{cpu: 1}, "cpu")
      :cpu
      iex> Macaw.Data.Table.key(%{"cpu" => 1}, :cpu)
      "cpu"
      iex> Macaw.Data.Table.key(%{cpu: 1}, "mem")
      nil
  """
  @spec key(map(), name()) :: name() | nil
  def key(row, name) when is_map_key(row, name), do: name

  def key(row, name) when is_atom(name),
    do: if(is_map_key(row, Atom.to_string(name)), do: Atom.to_string(name))

  def key(row, name) when is_binary(name) do
    case Process.get({__MODULE__, name}) do
      key when is_map_key(row, key) -> key
      _other -> scan(row, name)
    end
  end

  defp scan(row, name) do
    found = Enum.find(Map.keys(row), &(is_atom(&1) and Atom.to_string(&1) == name))
    if found, do: Process.put({__MODULE__, name}, found)
    found
  end

  @doc "The accessor `fn row -> get(row, name) end`; a function is returned unchanged."
  @spec accessor(name() | (row() -> term())) :: (row() -> term())
  def accessor(fun) when is_function(fun, 1), do: fun
  def accessor(name) when is_atom(name) or is_binary(name), do: &get(&1, name)

  @doc """
  The names of the columns whose values are all temporal: at least one value not `nil`,
  and every value `nil` or `temporal?/1`. The whole column is read.
  """
  @spec time_columns(source() | t()) :: [name()]
  def time_columns(%__MODULE__{} = table),
    do: for(name <- table.names, column_type(table, name) == :time, do: name)

  def time_columns(source) do
    rows = rows(source)

    rows
    |> column_names()
    |> Enum.filter(fn name -> temporal_column?(Enum.map(rows, &Map.get(&1, name))) end)
  end

  @doc """
  Every named column's type, read whole: all non-`nil` values temporal is `:time`, all
  numbers `:number`, all strings `:text`, all atoms or booleans `:category`. A mixed or
  empty column is left out. A suggestion for a tool, never something a reader relies on;
  a table's own declared types are `column_type/2`'s.

      iex> rows = [%{t: ~U[2024-01-01 00:00:00Z], v: 1, k: :a, s: "x", m: 1},
      ...>         %{t: ~U[2024-01-02 00:00:00Z], v: 2.5, k: :b, s: "y", m: "two"}]
      iex> Macaw.Data.Table.column_types(rows)
      %{t: :time, v: :number, k: :category, s: :text}
  """
  @spec column_types(source() | t()) :: %{name() => :time | :number | :category | :text}
  def column_types(%__MODULE__{} = table),
    do: Map.new(table.names, &{&1, column_type(table, &1)})

  def column_types(source), do: source |> rows() |> infer()

  defp infer(rows) do
    for name <- column_names(rows),
        type = infer_one(Enum.reject(Enum.map(rows, &Map.get(&1, name)), &is_nil/1)),
        type != nil,
        into: %{},
        do: {name, type}
  end

  defp infer_one([]), do: nil

  defp infer_one(values) do
    cond do
      Enum.all?(values, &temporal?/1) -> :time
      Enum.all?(values, &is_number/1) -> :number
      Enum.all?(values, &is_binary/1) -> :text
      Enum.all?(values, &(is_atom(&1) and not is_nil(&1))) -> :category
      true -> nil
    end
  end

  @doc """
  Whether a value is a point in time: a `DateTime`, `Date` or `NaiveDateTime`, or a string
  in ISO 8601 form that one of those parses.
  """
  @spec temporal?(term()) :: boolean()
  def temporal?(%DateTime{}), do: true
  def temporal?(%Date{}), do: true
  def temporal?(%NaiveDateTime{}), do: true

  def temporal?(string) when is_binary(string) do
    match?({:ok, _, _}, DateTime.from_iso8601(string)) or
      match?({:ok, _}, NaiveDateTime.from_iso8601(string)) or
      match?({:ok, _}, Date.from_iso8601(string))
  end

  def temporal?(_), do: false

  # -- sources ----------------------------------------------------------------------------

  # A list is columns when every element names an equal-length column.
  defp columns?(list, {name, values}) when is_atom(name) or is_binary(name) do
    n = column_length(values)

    n != nil and
      Enum.all?(list, fn
        {k, v} when is_atom(k) or is_binary(k) -> column_length(v) == n
        _other -> false
      end)
  end

  defp columns?(_list, _first), do: false

  defp column_length(values) when is_list(values), do: length(values)

  defp column_length(%{__struct__: Nx.Tensor} = tensor) do
    if Nx.rank(tensor) == 1, do: Nx.axis_size(tensor, 0)
  end

  defp column_length(_values), do: nil

  defp column_values(%{__struct__: Nx.Tensor} = tensor) do
    if Nx.rank(tensor) == 1, do: Nx.to_list(tensor), else: tensor
  end

  defp column_values(values), do: values

  defp column_rows(pairs) do
    columns = Enum.map(pairs, fn {name, values} -> {name, column_values(values)} end)
    [{_, first} | _] = columns
    n = if is_list(first), do: length(first), else: 0

    Enum.each(columns, fn {name, values} ->
      unless is_list(values) and length(values) == n do
        raise ArgumentError,
              "expected every column to be a list of #{n} values, got #{inspect(name)}: " <>
                inspect(values)
      end
    end)

    names = Enum.map(columns, &elem(&1, 0))

    columns
    |> Enum.map(&elem(&1, 1))
    |> Enum.zip_with(fn values -> names |> Enum.zip(values) |> Map.new() end)
  end

  defp tensor_rows(tensor, 1), do: Nx.to_list(tensor)
  defp tensor_rows(tensor, 2), do: tensor |> Nx.to_list() |> Enum.map(&List.to_tuple/1)

  defp tensor_rows(tensor, rank) do
    raise ArgumentError, "expected a tensor of rank 1 or 2, got rank #{rank}: #{inspect(tensor)}"
  end

  defp column_names(rows) do
    rows
    |> Enum.flat_map(fn
      row when is_map(row) -> Map.keys(row)
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp temporal_column?(values) do
    Enum.any?(values, &(not is_nil(&1))) and Enum.all?(values, &(is_nil(&1) or temporal?(&1)))
  end
end
