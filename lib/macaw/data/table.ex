defmodule Macaw.Data.Table do
  @moduledoc """
  Columnar typed data: the currency of deliveries, derived sources and components
  (spec/01 §1.1).

  A table is named columns of declared types, every column the same length:

  | Type | Holds | Stored as (Arrow's form) |
  |---|---|---|
  | `:number` | integers and floats | int64 when every value is an integer that fits; float64 when every one is a float; both, float64 and a bitmap of the integers (`macaw.integral`); both with an integer beyond ±2^53, a dense union of int64 and float64; an integer beyond int64, a list |
  | `:time` | `DateTime`s, `NaiveDateTime`s or `Date`s, one kind a column | all UTC, `timestamp[us, UTC]`; other zones, UTC microseconds and a dictionary of whole zones (`macaw.zoned`); naive, `timestamp[us]`; dates, `date32`; the precision kept; kinds mixed, a list |
  | `:text` | any value | strings, utf8: int32 offsets and one data buffer (Arrow binary when one is not valid UTF-8); anything else, a list |
  | `:category` | any value, an atom held as its string | strings and atoms, one dictionary of strings, any booleans beside it in side bitmaps; booleans alone, a bitmap; mixed types, a list |
  | `:color` | color terms (`Macaw.Data.Schema.color?/1`) | a list |
  | `:point`, `:term` | any value; a point is `{longitude, latitude}` | a list |

  **Packing never changes a value:** every column reads back values `==` to those given,
  but that a category's atom reads back as its string, in every form. **A missing value is `nil`,** in
  every type. A packed column keeps a validity bitmap beside its buffers, least-significant
  bit first as Arrow numbers bits, so a gap stays a gap: absence is never zero (spec/01 §3).

  **A table is an ordered list of chunks** (spec/01 §1.1.1): each a run of rows of every
  column, each column packed by itself, so a form and a dictionary are a chunk's. `new/1`
  and `from/2` build canonical chunks of `chunk_rows/0` rows; `append/2`, `trim/2` and
  `slice/3` keep whole chunks and where the table's rows start and end in them, copying
  nothing; `compact/1` rewrites any table into canonical chunks.

  **A table's identity is its contents** (spec/01 §1.1.2): `equal?/2` and `digest/1` read
  the values, never the layout, so the same rows chunked two ways are one value. `t()` is
  opaque, and `==` on the struct is not a table's equality.

  **The packed columns live off the process heap.** A binary over 64 bytes is
  reference-counted, so a garbage collection never copies it: a table costs its process a
  constant number of words a chunk, never a row.

  **Row lists are accepted at the edge.** `from/2` reads every shape data arrives in (a
  list of row maps, a map or keyword list of columns, an `Nx.Tensor`, anything implementing
  `Table.Reader`) into a table, and `rows/1` is the row view for code that wants rows. The
  row helpers (`get/2`, `key/2`, `accessor/1`, `temporal?/1`, `time_columns/1`,
  `column_types/1`) read any source, as visualize's `Visualize.Data.Table` does; this
  module's row readers are its port.

  The `table` package and Nx are optional: without them lists and column maps still work,
  and a struct source or a tensor raises `UndefinedFunctionError` where it is read.
  """

  alias Macaw.Data.Schema
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Table.Column
  alias Macaw.Data.Table.Digest

  @compile {:no_warn_undefined, [Table, Nx]}

  @enforce_keys [:names, :types, :chunks, :size]
  defstruct [:names, :types, :chunks, :size]

  @types [:number, :time, :category, :text, :color, :point, :term]

  # A canonical chunk's rows (spec/01 §1.1.1): fixed, never a setting.
  @rows 8192

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

  @typedoc """
  A chunk the table reads, with the run of its rows it reads: the first, and how many.
  """
  @type view :: {Chunk.t(), non_neg_integer(), pos_integer()}

  @typedoc "A table: equal to another by its contents (`equal?/2`), never by `==`."
  @opaque t :: %__MODULE__{
            names: [name()],
            types: %{name() => type()},
            chunks: [view()],
            size: non_neg_integer()
          }

  @doc "The column types, in the order spec/01 §1.1 lists them."
  @spec types() :: [type(), ...]
  def types, do: @types

  @doc """
  The rows of a canonical chunk, 8,192: `new/1`, `from/2` and `compact/1` build chunks of
  this many rows from the first, the last shorter (spec/01 §1.1.1). Not a setting.
  """
  @spec chunk_rows() :: pos_integer()
  def chunk_rows, do: @rows

  # -- building ---------------------------------------------------------------------------

  @doc """
  A table of `columns`, each `{name, type, values}`, in order.

  `{:ok, table}`, or every fault: `{[name], {:enum, types}}` for an unknown type,
  `{[name, i], {:type, type}}` for a value its type does not hold, `{[name, i], :not_data}`
  for a value that is not data (a function, a PID, a reference, a port, an improper list:
  it has no digest), `{[name], {:length, n}}`
  for a column whose length is not the first column's `n`, `{[name], :duplicate}` for a
  name given twice. A number column holds numbers; a time column `DateTime`s,
  `NaiveDateTime`s or `Date`s; a color column color terms (`Macaw.Data.Schema.color?/1`);
  a point column `{longitude, latitude}` pairs of numbers; the others any value. `nil` is
  missing in every type.
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
            case pack(type, values, name) do
              {:ok, pieces} -> {[{name, type, pieces} | built], faults}
              {:error, column_faults} -> {built, column_faults ++ faults}
            end
        end
      end)

    case faults do
      [] -> {:ok, chunked(Enum.reverse(built), size)}
      _ -> {:error, Enum.sort_by(Enum.reverse(faults), &elem(&1, 0))}
    end
  end

  # A column's values packed a canonical chunk at a time, each piece by itself; a fault's
  # index is the row's in the whole column. A value that is not data (a function, a PID, a
  # reference, a port, an improper list) has no digest, so no column holds it.
  defp pack(type, values, name) do
    values
    |> Enum.chunk_every(@rows)
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {piece, k}, {pieces, faults} ->
      case Column.pack(type, piece, name) do
        {:ok, {:list, list} = col} ->
          {[col | pieces], not_data(list, name, k * @rows) ++ faults}

        {:ok, col} ->
          {[col | pieces], faults}

        {:error, piece_faults} ->
          {pieces, Enum.map(piece_faults, &shift(&1, k * @rows)) ++ faults}
      end
    end)
    |> case do
      {pieces, []} -> {:ok, Enum.reverse(pieces)}
      {_pieces, faults} -> {:error, faults}
    end
  end

  defp shift({[name, i], fault}, by), do: {[name, i + by], fault}

  defp not_data(values, name, at) do
    for {v, i} <- Enum.with_index(values, at), not Digest.data?(v), do: {[name, i], :not_data}
  end

  # Packed columns, each a list of pieces, as one table of chunks: the k-th piece of every
  # column is chunk k.
  defp chunked(columns, size) do
    header = for {name, type, _pieces} <- columns, do: {name, type}

    chunks =
      case columns do
        [] ->
          []

        _ ->
          columns
          |> Enum.map(fn {name, _type, pieces} -> Enum.map(pieces, &{name, &1}) end)
          |> Enum.zip_with(& &1)
          |> Enum.with_index()
          |> Enum.map(fn {piece, k} ->
            rows = min(@rows, size - k * @rows)
            {Chunk.build(header, Map.new(piece), rows), 0, rows}
          end)
      end

    %__MODULE__{
      names: Enum.map(header, &elem(&1, 0)),
      types: Map.new(header),
      chunks: chunks,
      size: size
    }
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

    rows
    |> column_names()
    |> Enum.map(fn name ->
      values = Enum.map(rows, &Map.get(&1, name))
      type = Map.get(given, name) || infer_column(values) || :term
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

  # -- reading ----------------------------------------------------------------------------

  @doc "The number of rows."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc "The column names, in order."
  @spec names(t()) :: [name()]
  def names(%__MODULE__{names: names}), do: names

  @doc "Each column's type, by name."
  @spec column_type(t(), name()) :: type() | nil
  def column_type(%__MODULE__{types: types}, name), do: Map.get(types, name)

  @doc """
  The values of column `name`, in order, `nil` where a value is missing; `nil` for a name
  the table does not have. Every value is `==` to the one given, integer or float, a time
  in its own zone at its own precision, but that a category's atom reads back as the
  string that spells it.
  """
  @spec column(t(), name()) :: [term()] | nil
  def column(%__MODULE__{types: types, chunks: chunks}, name) when is_map_key(types, name),
    do:
      Enum.flat_map(chunks, fn {chunk, first, count} ->
        Chunk.values(chunk, name, first, count)
      end)

  def column(%__MODULE__{}, _name), do: nil

  @doc "The rows, one map per row keyed by every column name, `nil` where missing."
  @spec rows(source() | t()) :: [row()]
  def rows(%__MODULE__{names: names} = table) do
    case names do
      [] ->
        List.duplicate(%{}, table.size)

      _ ->
        transpose(names, Enum.map(names, &column(table, &1)), [])
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

  # One row a step: the heads of every column under the names, then the tails.
  defp transpose(_names, [[] | _], acc), do: :lists.reverse(acc)

  defp transpose(names, columns, acc) do
    {heads, tails} = heads_tails(columns, [], [])
    transpose(names, tails, [:maps.from_list(:lists.zip(names, heads)) | acc])
  end

  defp heads_tails([[head | tail] | columns], heads, tails),
    do: heads_tails(columns, [head | heads], [tail | tails])

  defp heads_tails([], heads, tails), do: {:lists.reverse(heads), :lists.reverse(tails)}

  @doc "Row `i` (from 0) as a map, or `nil` past the end."
  @spec row(t(), non_neg_integer()) :: map() | nil
  def row(%__MODULE__{size: size}, i) when i >= size, do: nil

  def row(%__MODULE__{names: names} = table, i) when is_integer(i) and i >= 0,
    do: Map.new(names, &{&1, hd(column(slice(table, i, 1), &1))})

  @doc """
  The rows `start` to `start + count - 1`, as a table of the same columns. It keeps the
  chunks the run spans, cut at both ends, and copies nothing (spec/01 §1.1.1).
  """
  @spec slice(t(), non_neg_integer(), non_neg_integer()) :: t()
  def slice(%__MODULE__{size: size} = table, start, count)
      when is_integer(start) and start >= 0 and is_integer(count) and count >= 0 do
    first = min(start, size)
    n = min(count, size - first)
    %__MODULE__{table | chunks: cut(table.chunks, first, n), size: n}
  end

  # The views of `take` rows after the first `skip`.
  defp cut(_views, _skip, 0), do: []
  defp cut([{_chunk, _first, n} | rest], skip, take) when skip >= n, do: cut(rest, skip - n, take)

  defp cut([{chunk, first, n} | rest], skip, take) do
    k = min(n - skip, take)
    [{chunk, first + skip, k} | cut(rest, 0, take - k)]
  end

  # -- chunks -----------------------------------------------------------------------------

  @doc """
  The chunks the table reads, in order, each with the run of its rows the table reads:
  `{chunk, first, count}` (spec/01 §1.1.1). Every chunk the table references is in it, and
  nothing else.
  """
  @spec chunks(t()) :: [view()]
  def chunks(%__MODULE__{chunks: chunks}), do: chunks

  @doc """
  The table with `other`'s rows after its own: `other`'s chunks added as they are, nothing
  copied (spec/01 §1.1.1). The two have the same names in the same order, each of the same
  type; another table is `{:error, {:columns, expected, given}}`, each a list of
  `{name, type}`.
  """
  @spec append(t(), t()) :: {:ok, t()} | {:error, {:columns, list(), list()}}
  def append(%__MODULE__{} = table, %__MODULE__{} = other) do
    case {header(table), header(other)} do
      {same, same} ->
        {:ok,
         %__MODULE__{table | chunks: table.chunks ++ other.chunks, size: table.size + other.size}}

      {expected, given} ->
        {:error, {:columns, expected, given}}
    end
  end

  @doc """
  The table without its oldest `n` rows: every chunk wholly before the cut dropped, the
  first that remains read from the cut (spec/01 §1.1.1). A dropped chunk is referenced by
  nothing in the table, so it is freed once nothing else references it.
  """
  @spec trim(t(), non_neg_integer()) :: t()
  def trim(%__MODULE__{size: size} = table, n) when is_integer(n) and n >= 0,
    do: slice(table, n, size)

  @doc """
  The table in canonical chunks: `chunk_rows/0` rows each from the first, the last
  shorter, each packed from its own values (spec/01 §1.1.1). Two equal tables compact to
  the same struct; a table already canonical is returned as it is.
  """
  @spec compact(t()) :: t()
  def compact(%__MODULE__{} = table) do
    if canonical?(table.chunks) do
      table
    else
      {:ok, compacted} =
        new(for {name, type} <- header(table), do: {name, type, column(table, name)})

      compacted
    end
  end

  # Whole chunks, every one but the last of `@rows` rows.
  defp canonical?([]), do: true
  defp canonical?([{chunk, 0, n}]), do: Chunk.size(chunk) == n
  defp canonical?([{chunk, 0, @rows} | rest]), do: Chunk.size(chunk) == @rows and canonical?(rest)
  defp canonical?(_views), do: false

  # -- identity ---------------------------------------------------------------------------

  @doc """
  Whether two tables have the same contents (spec/01 §1.1.2): the same names in order, each
  of the same type, and each column's values in order, compared strictly, as the digest
  tells them apart (`1` and `1.0` differ, and `0.0` and `-0.0`). How the rows are chunked
  never matters. Exactly when `digest/1` of the two is equal.
  """
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.size == b.size and header(a) == header(b) and
      (a.chunks == b.chunks or Enum.all?(a.names, &(column(a, &1) === column(b, &1))))
  end

  @doc """
  The table's content digest (spec/01 §1.1.2): 64 lowercase hex characters, the kernel's
  digest (`Macaw.Layers.Document.digest/1`) of its canonical term
  `{"macaw.table", [{name, type}, …], [values, …]}`, each column's values a list in order.
  Over the values, never the buffers: a chunking, a column's form and a dictionary's order
  all keep it.
  """
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{chunks: chunks, size: size} = table) do
    columns =
      for name <- table.names do
        for {chunk, first, count} <- chunks,
            do: fn -> {Chunk.storage(chunk, name, first, count), count} end
      end

    Digest.digest(header(table), size, columns)
  end

  defp header(%__MODULE__{names: names, types: types}), do: Enum.map(names, &{&1, types[&1]})

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
  numbers `:number`, all strings `:text`, all color terms `:color` (a literal or a typed
  color, `Macaw.Data.Schema.color?/1`), all atoms or booleans `:category`. A string is
  never a color, so a column of CSS text is `:text`. A mixed or empty column is left out.
  A suggestion for a tool, never something a reader relies on; a table's own declared
  types are `column_type/2`'s.

      iex> rows = [%{t: ~U[2024-01-01 00:00:00Z], v: 1, k: :a, s: "x", c: {:color, "good"}, m: 1},
      ...>         %{t: ~U[2024-01-02 00:00:00Z], v: 2.5, k: :b, s: "y", c: nil, m: "two"}]
      iex> Macaw.Data.Table.column_types(rows)
      %{t: :time, v: :number, k: :category, s: :text, c: :color}
  """
  @spec column_types(source() | t()) ::
          %{name() => :time | :number | :category | :text | :color}
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

  # One column's type from its values, gaps aside; nil when nothing suggests one.
  defp infer_column(values), do: infer_one(Enum.reject(values, &is_nil/1))

  defp infer_one([]), do: nil

  defp infer_one(values) do
    cond do
      Enum.all?(values, &temporal?/1) -> :time
      Enum.all?(values, &is_number/1) -> :number
      Enum.all?(values, &is_binary/1) -> :text
      Enum.all?(values, &Schema.color?/1) -> :color
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
    |> Enum.reduce(%{}, fn
      row, seen when is_map(row) -> Map.merge(seen, row)
      _row, seen -> seen
    end)
    |> Map.keys()
    |> Enum.sort()
  end

  defp temporal_column?(values) do
    Enum.any?(values, &(not is_nil(&1))) and Enum.all?(values, &(is_nil(&1) or temporal?(&1)))
  end
end
