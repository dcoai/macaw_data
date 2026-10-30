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

  alias Macaw.Data.Table.Edge
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Table.Column
  alias Macaw.Data.Table.Digest
  alias Macaw.Data.Table.Origin

  import Kernel, except: [apply: 2]

  @enforce_keys [:names, :types, :chunks, :size]
  defstruct [:names, :types, :chunks, :size, origin: nil, next: 0, sorted: nil]

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
            size: non_neg_integer(),
            origin: origin() | nil,
            next: non_neg_integer(),
            sorted: name() | nil
          }

  @typedoc """
  A source's table's origin (spec/01 §1.1.3): the source, the resolution its relation is
  held at, its window field and its chunk span (each `nil` for row-count alignment). Given
  to `new/2`, it may also say where the rows start among the source's (`offset:`, 0).
  """
  @type origin :: %{
          source: term(),
          resolution: term(),
          window: name() | nil,
          span: Duration.t() | number() | nil
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
  it has no digest), `{[name], {:length, n}}` for a column whose length is not the first
  column's `n`, `{[name], :duplicate}` for a name given twice. A number column holds
  numbers; a time column `DateTime`s, `NaiveDateTime`s or `Date`s; a color column color
  terms (`Macaw.Data.Schema.color?/1`); a point column `{longitude, latitude}` pairs of
  numbers; the others any value. `nil` is missing in every type.

  Its chunks are canonical (spec/01 §1.1.1), their ids their content digests. With
  `origin:` it is a source's table (spec/01 §1.1.3), its chunks laid on the origin's slots
  and named `{source, resolution, slot}`; an origin's own faults are `{[:origin, key],
  reason}`, and rows out of the window field's order `{[:origin, :window], {:unsorted, i}}`.
  """
  @spec new([{name(), type(), [term()]}], keyword()) ::
          {:ok, t()} | {:error, [{list(), term()}, ...]}
  def new(columns, opts \\ []) when is_list(columns) and is_list(opts) do
    size =
      case columns do
        [{_, _, values} | _] when is_list(values) -> length(values)
        _ -> 0
      end

    {checked, faults} =
      columns
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {{name, type, values}, i}, {checked, faults} ->
        cond do
          Enum.any?(Enum.take(columns, i), &(elem(&1, 0) == name)) ->
            {checked, [{[name], :duplicate} | faults]}

          type not in @types ->
            {checked, [{[name], {:enum, @types}} | faults]}

          not is_list(values) or length(values) != size ->
            {checked, [{[name], {:length, size}} | faults]}

          true ->
            {[{name, type, values} | checked], faults}
        end
      end)

    checked = Enum.reverse(checked)

    {origin, offset, layout} =
      case Origin.check(Keyword.get(opts, :origin), checked) do
        {:ok, origin, offset} ->
          {origin, offset, Origin.layout(origin, offset, checked, size, @rows)}

        {:error, origin_faults} ->
          {nil, 0, {:error, origin_faults}}
      end

    {counts, faults} =
      case layout do
        {:ok, counts} -> {counts, faults}
        :invalid -> {nil, faults}
        {:error, layout_faults} -> {nil, layout_faults ++ faults}
      end

    {packed, faults} = pack(checked, counts, faults)

    case faults do
      [] -> {:ok, chunked(packed, counts, size, origin, offset)}
      _ -> {:error, Enum.sort_by(Enum.reverse(faults), &elem(&1, 0))}
    end
  end

  # Each column packed a chunk at a time, by the layout's counts; a fault's index is the
  # row's in the whole column. Without a layout (its faults are reported), the columns are
  # still packed a canonical chunk at a time, so every value's fault is found.
  defp pack(columns, nil, faults) do
    Enum.reduce(columns, {[], faults}, fn {name, type, values}, {packed, faults} ->
      {_pieces, piece_faults} = pieces(type, values, name, counts_of(length(values)))
      {packed, piece_faults ++ faults}
    end)
  end

  defp pack(columns, counts, faults) do
    {packed, faults} =
      Enum.reduce(columns, {[], faults}, fn {name, type, values}, {packed, faults} ->
        {pieces, piece_faults} = pieces(type, values, name, Enum.map(counts, &elem(&1, 0)))
        {[{name, type, pieces} | packed], piece_faults ++ faults}
      end)

    {Enum.reverse(packed), faults}
  end

  defp counts_of(size),
    do: Enum.map(Enum.chunk_every(List.duplicate(nil, size), @rows), &length/1)

  defp pieces(type, values, name, counts) do
    {pieces, faults, _rest, _at} =
      Enum.reduce(counts, {[], [], values, 0}, fn count, {pieces, faults, rest, at} ->
        {piece, rest} = Enum.split(rest, count)

        case Column.piece(type, piece, name, at) do
          {:ok, col} -> {[col | pieces], faults, rest, at + count}
          {:error, piece_faults} -> {pieces, piece_faults ++ faults, rest, at + count}
        end
      end)

    {Enum.reverse(pieces), faults}
  end

  # Packed columns, each a list of pieces, as one table of chunks: the k-th piece of every
  # column is chunk k, of the layout's k-th count and id.
  defp chunked(columns, counts, size, origin, offset) do
    header = for {name, type, _pieces} <- columns, do: {name, type}

    chunks =
      case columns do
        [] ->
          []

        _ ->
          columns
          |> Enum.map(fn {name, _type, pieces} -> Enum.map(pieces, &{name, &1}) end)
          |> Enum.zip_with(& &1)
          |> Enum.zip(counts)
          |> Enum.map(fn {piece, {rows, id}} ->
            {Chunk.build(header, Map.new(piece), rows, id), 0, rows}
          end)
      end

    %__MODULE__{
      names: Enum.map(header, &elem(&1, 0)),
      types: Map.new(header),
      chunks: chunks,
      size: size,
      origin: origin,
      next: if(origin, do: offset + size, else: 0),
      sorted: if(Origin.windowed?(origin), do: origin.window)
    }
  end

  @doc "As `new/2`, raising `ArgumentError` naming every fault."
  @spec new!([{name(), type(), [term()]}], keyword()) :: t()
  def new!(columns, opts \\ []) do
    case new(columns, opts) do
      {:ok, table} -> table
      {:error, faults} -> raise ArgumentError, "not a table: #{inspect(faults)}"
    end
  end

  @doc """
  A table of chunks already built (spec/01 §1.1.3): a step's outputs (`Chunk.derive/3`,
  `Chunk.gather/5`, `Chunk.combine/3`), in order, under `header`, a list of
  `{name, type}`. Each is a chunk, read whole, or a view `{chunk, first, count}` reading a
  run of it, as `chunks/1` lists them, so a per-row step's output keeps the chunks it
  passes through (spec/04 §1.4). A chunk or a run of no rows is left out. A chunk of other
  columns is `{:error, {:columns, header, names}}`, its column names. Nothing is hashed.

  `sorted:` names a column the rows are known to be in ascending order of, `nil` last
  (`sorted/1`): a per-row step's output keeps its input's.
  """
  @spec from_chunks([{name(), type()}], [Chunk.t() | view()], keyword()) ::
          {:ok, t()} | {:error, {:columns, list(), list()}}
  def from_chunks(header, chunks, opts \\ []) when is_list(header) and is_list(chunks) do
    names = Enum.map(header, &elem(&1, 0))
    views = Enum.map(chunks, &as_view/1)

    case Enum.find(views, fn {chunk, _, _} ->
           Enum.sort(chunk_names(chunk)) != Enum.sort(names)
         end) do
      nil ->
        views = for {_chunk, _first, count} = view <- views, count > 0, do: view

        {:ok,
         %__MODULE__{
           names: names,
           types: Map.new(header),
           chunks: views,
           size: Enum.sum(Enum.map(views, &elem(&1, 2))),
           sorted: Keyword.get(opts, :sorted)
         }}

      {chunk, _first, _count} ->
        {:error, {:columns, header, chunk_names(chunk)}}
    end
  end

  defp as_view({_chunk, first, count} = view) when is_integer(first) and is_integer(count),
    do: view

  defp as_view(chunk), do: {chunk, 0, Chunk.size(chunk)}

  defp chunk_names(chunk), do: Enum.map(Chunk.header(chunk), &elem(&1, 0))

  @doc """
  The column the table's rows are known to be in ascending order of, `nil` last, or `nil`
  for none (spec/01 §1.1.3): a source's table in event time is in its window field's order,
  and a per-row step's output keeps its input's order. A step binary-searches only this
  column (spec/04 §4.3).
  """
  @spec sorted(t()) :: name() | nil
  def sorted(%__MODULE__{sorted: sorted}), do: sorted

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
    |> Edge.column_names()
    |> Enum.map(fn name ->
      values = Enum.map(rows, &Map.get(&1, name))
      type = Map.get(given, name) || Edge.infer_column(values) || :term
      {name, type, if(type == :time, do: Enum.map(values, &Edge.to_datetime/1), else: values)}
    end)
    |> new()
  end

  @doc false
  # A value as the edge reads it into a column of `type` (spec/01 §2.6, as `from/2` and
  # `Delivery.table/2` pack): a time column's ISO strings, dates and naive times as
  # `DateTime`s, a category's atom as its string; any other as it is.
  @spec at_edge(type() | nil, term()) :: term()
  def at_edge(:time, value), do: Edge.to_datetime(value)

  def at_edge(:category, v) when is_atom(v) and not is_boolean(v) and v != nil,
    do: Atom.to_string(v)

  def at_edge(_type, value), do: value

  # -- reading ----------------------------------------------------------------------------

  @doc "The number of rows."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: nil} = table), do: table |> warm() |> size()
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
  def column(%__MODULE__{size: nil} = table, name), do: table |> warm() |> column(name)

  def column(%__MODULE__{types: types, chunks: chunks}, name) when is_map_key(types, name),
    do:
      Enum.flat_map(chunks, fn {chunk, first, count} ->
        Chunk.values(chunk, name, first, count)
      end)

  def column(%__MODULE__{}, _name), do: nil

  @doc "The rows, one map per row keyed by every column name, `nil` where missing."
  @spec rows(source() | t()) :: [row()]
  def rows(%__MODULE__{size: nil} = table), do: table |> warm() |> rows()

  def rows(%__MODULE__{names: names} = table) do
    case names do
      [] ->
        List.duplicate(%{}, table.size)

      _ ->
        transpose(names, Enum.map(names, &column(table, &1)), [])
    end
  end

  def rows(source), do: Edge.rows(source)

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
  def row(%__MODULE__{size: nil} = table, i), do: table |> warm() |> row(i)
  def row(%__MODULE__{size: size}, i) when i >= size, do: nil

  def row(%__MODULE__{names: names} = table, i) when is_integer(i) and i >= 0,
    do: Map.new(names, &{&1, hd(column(slice(table, i, 1), &1))})

  @doc """
  The rows `start` to `start + count - 1`, as a table of the same columns. It keeps the
  chunks the run spans, cut at both ends, and copies nothing (spec/01 §1.1.1).
  """
  @spec slice(t(), non_neg_integer(), non_neg_integer()) :: t()
  def slice(%__MODULE__{size: nil} = table, start, count),
    do: table |> warm() |> slice(start, count)

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
  A source's table's origin (spec/01 §1.1.3), or `nil` for a table built from rows.
  """
  @spec origin(t()) :: origin() | nil
  def origin(%__MODULE__{origin: origin}), do: origin

  @doc """
  The table with `other`'s rows after its own (spec/01 §1.1.1, §1.1.3). The two have the
  same names in the same order, each of the same type; another table is
  `{:error, {:columns, expected, given}}`, each a list of `{name, type}`.

  A table built from rows takes `other`'s chunks as they are, copying nothing. A source's
  table keeps its alignment: the rows that fall in its last chunk's slot are written into
  it, a chunk of the same id with new contents, and later rows start new chunks. `other`
  is of the same origin, else `{:error, {:origin, expected, given}}`, and its rows lie at
  or after the table's last row in the window field's order, else
  `{:error, {:unsorted, i}}`, `i` the row of `other`'s out of order.
  """
  @spec append(t(), t()) ::
          {:ok, t()}
          | {:error,
             {:columns, list(), list()}
             | {:origin, term(), term()}
             | {:unsorted, non_neg_integer()}}
  def append(%__MODULE__{} = table, %__MODULE__{} = other) do
    {table, other} = {ready(table), ready(other)}

    cond do
      header(table) != header(other) ->
        {:error, {:columns, header(table), header(other)}}

      table.origin != other.origin ->
        {:error, {:origin, table.origin, other.origin}}

      table.origin == nil ->
        {:ok,
         %__MODULE__{table | chunks: table.chunks ++ other.chunks, size: table.size + other.size}}

      true ->
        aligned(table, other)
    end
  end

  # `other`'s rows laid on the source's slots after the table's: inserted as an increment
  # is, into the open chunk of each row's slot or a new one (spec/01 §1.1.4).
  defp aligned(%__MODULE__{} = table, other) do
    with :ok <- in_order(table, other) do
      inserted = %{
        insert: rows(other),
        retract: [],
        replace: [],
        schema: nil,
        settled: nil,
        thinned: false
      }

      {table, [], 0} = apply(table, inserted)
      {:ok, table}
    end
  end

  defp in_order(%__MODULE__{origin: %{window: window, span: span}} = table, other)
       when window != nil and span != nil and table.size > 0 and other.size > 0 do
    [last] = column(slice(table, table.size - 1, 1), window)
    [next] = column(slice(other, 0, 1), window)
    if Origin.ordered?(last, next), do: :ok, else: {:error, {:unsorted, 0}}
  end

  defp in_order(_table, _other), do: :ok

  # -- changes (spec/01 §1.1.4) -------------------------------------------------------------

  @doc """
  One increment's changes applied to the table (spec/01 §1.1.4): `{table, faults,
  unheld}`. `change` is `%{insert, retract, replace, schema, settled, thinned}`: the rows
  inserted, the rows retracted and the range replacements (`%{from, to, identities,
  rows}`) of one increment, already judged for lateness, overlaps and conflicts
  (spec/01 §4.2, §4.4); the source's schema (its identity and window field); the
  `complete_until` in force; and whether the holding is thinned.

  Row retractions, then range retractions, then insertions, each where its slot is: an
  open chunk is written again with its new contents, a settled chunk's change lands in its
  delta. A retraction that is not held, held only at another window value, or that can't
  tell rows apart is `{:retract, reason, row}` in `faults`, or counted in `unheld` against
  a thinned holding. Rows to insert that don't pack under the table's columns are
  `{:table, faults}`, and nothing is applied. A settled chunk whose delta reaches a
  quarter of its base is compacted.
  """
  @spec apply(t(), map()) :: {t(), list(), non_neg_integer()}
  def apply(%__MODULE__{} = table, change) when is_map(change) do
    change =
      Map.merge(
        %{insert: [], retract: [], replace: [], schema: nil, settled: nil, thinned: false},
        change
      )

    chunks = whole(table)

    {chunks, next, faults, unheld} =
      Macaw.Data.Table.Apply.run(
        %{header: header(table), origin: table.origin, chunks: chunks, next: table.next},
        change
      )

    {with_chunks(table, chunks, next), faults, unheld}
  end

  # The table's chunks, each whole: a view that reads part of its chunk written as a chunk
  # of its own, of the same id.
  defp whole(%__MODULE__{chunks: views} = table) do
    for {chunk, first, count} <- views do
      if first == 0 and count in [nil, Chunk.size(chunk)] do
        chunk
      else
        rows = rows(%__MODULE__{table | chunks: [{chunk, first, count}], size: count})
        id = if table.origin, do: Chunk.id(chunk)
        {:ok, chunk} = Chunk.of_rows(header(table), rows, id)
        chunk
      end
    end
  end

  defp with_chunks(%__MODULE__{} = table, chunks, next) do
    views = for chunk <- chunks, Chunk.size(chunk) != 0, do: {chunk, 0, Chunk.size(chunk)}
    counts = Enum.map(views, &elem(&1, 2))
    size = if nil in counts, do: nil, else: Enum.sum(counts)
    %__MODULE__{table | chunks: views, size: size, next: next}
  end

  @doc """
  Whether `chunk` of the table is settled under `complete_until` (spec/01 §1.1.4): its
  span ends at or before it. Never for a chunk of rows with no window value, and never in
  a table that is not a source's in event time.
  """
  @spec settled?(t(), Chunk.t(), term()) :: boolean()
  def settled?(%__MODULE__{origin: origin}, chunk, complete_until) do
    case {Origin.windowed?(origin), Chunk.id(chunk)} do
      {true, {_source, _resolution, slot}} -> Origin.settled?(origin, slot, complete_until)
      _other -> false
    end
  end

  @doc """
  The table with every cold chunk it holds fetched once (spec/01 §1.1.4): its base in
  memory, and its size and content digest, pending under a predicate delete, computed as
  read. Every read of a table whose size is pending warms it first.
  """
  @spec warm(t()) :: t()
  def warm(%__MODULE__{} = table),
    do: with_chunks(table, Enum.map(whole(table), &Chunk.warm/1), table.next)

  # A table whose size is pending, warmed; any other as it is.
  defp ready(%__MODULE__{size: nil} = table), do: warm(table)
  defp ready(table), do: table

  @doc """
  The table without its oldest `n` rows: every chunk wholly before the cut dropped, the
  first that remains read from the cut (spec/01 §1.1.1). A dropped chunk is referenced by
  nothing in the table, so it is freed once nothing else references it.
  """
  @spec trim(t(), non_neg_integer()) :: t()
  def trim(%__MODULE__{size: size} = table, n) when is_integer(n) and n >= 0,
    do: slice(table, n, size)

  @doc """
  The table in canonical chunks, each whole, packed from its own values and hashed
  (spec/01 §1.1.1): `chunk_rows/0` rows each from the first, the last shorter, for a table
  built from rows or of steps' outputs; a source's table on its origin's slots
  (spec/01 §1.1.3). Two equal tables of one origin compact to the same struct; a table
  already canonical is returned as it is.
  """
  @spec compact(t()) :: t()
  def compact(%__MODULE__{size: nil} = table), do: table |> warm() |> compact()

  def compact(%__MODULE__{origin: origin} = table) when origin != nil do
    if canonical?(table.chunks, origin),
      do: table,
      else: with_chunks(table, Enum.map(whole(table), &Chunk.compact/1), table.next)
  end

  def compact(%__MODULE__{origin: origin} = table) do
    if canonical?(table.chunks, origin) do
      table
    else
      opts = []

      {:ok, compacted} =
        new(for({name, type} <- header(table), do: {name, type, column(table, name)}), opts)

      compacted
    end
  end

  # Whole, hashed chunks: on the origin's slots, which a source's table always has, or,
  # built from rows, named by their digests, every one but the last of `@rows` rows.
  defp canonical?(views, nil), do: canonical?(views)

  defp canonical?(views, _origin),
    do:
      Enum.all?(views, fn {chunk, first, n} ->
        first == 0 and n == Chunk.size(chunk) and not Chunk.delta?(chunk) and
          is_binary(Chunk.digest(chunk))
      end)

  defp canonical?([]), do: true
  defp canonical?([{chunk, 0, n}]), do: Chunk.size(chunk) == n and named?(chunk)

  defp canonical?([{chunk, 0, @rows} | rest]),
    do: Chunk.size(chunk) == @rows and named?(chunk) and canonical?(rest)

  defp canonical?(_views), do: false

  defp named?(chunk),
    do:
      not Chunk.delta?(chunk) and is_binary(Chunk.digest(chunk)) and
        Chunk.id(chunk) == Chunk.digest(chunk)

  # -- identity ---------------------------------------------------------------------------

  @doc """
  Whether two tables have the same contents (spec/01 §1.1.2): the same names in order, each
  of the same type, and each column's values in order, compared strictly, as the digest
  tells them apart (`1` and `1.0` differ, and `0.0` and `-0.0`). How the rows are chunked
  never matters. Exactly when `digest/1` of the two is equal.
  """
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{} = a, %__MODULE__{} = b) do
    {a, b} = {ready(a), ready(b)}

    a.size == b.size and header(a) == header(b) and
      (a.chunks == b.chunks or Enum.all?(a.names, &(column(a, &1) === column(b, &1))))
  end

  @doc """
  The table's content digest (spec/01 §1.1.2): 64 lowercase hex characters, a SHA-256 over
  its canonical form, each value a tag, a word and bytes of its own, whatever form holds
  it. Over the values, never the buffers: a chunking, a column's form and a dictionary's
  order all keep it, and the origin is not part of it.
  """
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{size: nil} = table), do: table |> warm() |> digest()

  def digest(%__MODULE__{chunks: chunks, size: size} = table) do
    columns =
      for name <- table.names do
        for {chunk, first, count} <- chunks,
            do: fn -> {Chunk.storage(chunk, name, first, count), count} end
      end

    Digest.digest(header(table), size, columns)
  end

  defp header(%__MODULE__{names: names, types: types}), do: Enum.map(names, &{&1, types[&1]})

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
  defdelegate named(source, names), to: Edge

  @doc """
  Whether a source's rows have no names: a tensor, or tuple rows (a list whose first
  row is a tuple and which is not a keyword list of columns). `named/2` gives them some.

      iex> Macaw.Data.Table.unnamed?([{1, 4.0}])
      true
      iex> Macaw.Data.Table.unnamed?([x: [1, 2]])
      false
  """
  @spec unnamed?(term()) :: boolean()
  defdelegate unnamed?(source), to: Edge

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
  defdelegate key(row, name), to: Edge

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

  def time_columns(source), do: Edge.time_columns(source)

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

  def column_types(source), do: Edge.column_types(source)

  @doc """
  Whether a value is a point in time: a `DateTime`, `Date` or `NaiveDateTime`, or a string
  in ISO 8601 form that one of those parses.
  """
  @spec temporal?(term()) :: boolean()
  defdelegate temporal?(value), to: Edge
end
