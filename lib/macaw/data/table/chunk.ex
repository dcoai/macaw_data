defmodule Macaw.Data.Table.Chunk do
  @moduledoc """
  One chunk of a `Macaw.Data.Table` (spec/01 §1.1.1): a run of rows of every column, each
  column packed by itself in the table's forms, Arrow's record batch. A chunk is immutable.

  - **Its logical id** (`id/1`, spec/01 §1.1.3) is where it sits, which never changes: a
    source's chunk `{source, resolution, slot}`, a chunk of a table built from rows its
    content digest, a step's output its input's id and the step key.
  - **Its content digest** (`digest/1`, spec/01 §1.1.2) is its contents' digest as a
    one-chunk table of its table's names and types, computed once, when the chunk is built
    from data that enters; reading it never hashes. A step's output has none until it is
    persisted or compared (`Macaw.Data.Table.compact/1`).
  - **Its version** (`version/1`) is its content digest, or a step's output's derivation
    digest: the kernel's digest of its inputs' versions and the step key, never of its
    contents. A cache keys a chunk's results by `{id, version, step key}`.

  A table holds its chunks with the run of each one's rows it reads
  (`Macaw.Data.Table.chunks/1`); a chunk itself is always whole.
  """

  alias Macaw.Data.Table.Column
  alias Macaw.Data.Table.Delta
  alias Macaw.Data.Table.Digest
  alias Macaw.Layers.Document

  @enforce_keys [:size, :columns, :id, :digest, :derivation]
  defstruct [
    :size,
    :columns,
    :id,
    :digest,
    :derivation,
    :base_rows,
    base_digest: nil,
    header: [],
    delta: nil,
    read: nil,
    fetch: nil
  ]

  @typedoc """
  A chunk: its row count, each column's storage by name, its logical id, and its content
  digest or its derivation digest.
  """
  @opaque t :: %__MODULE__{
            size: non_neg_integer() | nil,
            columns: %{term() => Column.t()} | nil,
            id: term(),
            digest: String.t() | nil | :pending,
            derivation: String.t() | nil,
            base_rows: non_neg_integer(),
            base_digest: String.t() | nil,
            header: [{term(), atom()}],
            delta: Delta.t() | nil,
            read: %{columns: %{term() => Column.t()}, refs: tuple()} | nil,
            fetch: (-> %{term() => Column.t()}) | nil
          }

  @typedoc "A step output's columns: `{name, type, values}`, as `Macaw.Data.Table.new/2` takes."
  @type columns :: [{term(), atom(), [term()]}]

  @doc """
  The number of rows the chunk holds, as read through its delta (spec/01 §1.1.4); `nil`
  while a cold chunk's predicate deletes are pending.
  """
  @spec size(t()) :: non_neg_integer() | nil
  def size(%__MODULE__{size: size}), do: size

  @doc "The chunk's columns, `{name, type}` in order."
  @spec header(t()) :: [{term(), atom()}]
  def header(%__MODULE__{header: header}), do: header

  @doc "Whether the chunk has a delta over its base (spec/01 §1.1.4)."
  @spec delta?(t()) :: boolean()
  def delta?(%__MODULE__{delta: delta}), do: delta != nil

  @doc """
  A cold chunk (spec/01 §1.1.4): its base held elsewhere, fetched by `fetch`, a function
  answering the base's columns by name, as `Macaw.Data.Table.chunks/1`'s chunks hold them.
  The chunk keeps its `header`, `id`, content `digest` and `size`; it is fetched only when
  it is read.
  """
  @spec cold([{term(), atom()}], term(), String.t(), non_neg_integer(), (-> map())) :: t()
  def cold(header, id, digest, size, fetch) when is_function(fetch, 0) do
    %__MODULE__{
      size: size,
      columns: nil,
      id: id,
      digest: digest,
      derivation: nil,
      base_rows: size,
      base_digest: digest,
      header: header,
      fetch: fetch
    }
  end

  @doc """
  The chunk's logical id (spec/01 §1.1.3): where it sits, which never changes.
  """
  @spec id(t()) :: term()
  def id(%__MODULE__{id: id}), do: id

  @doc """
  The chunk's content digest: 64 lowercase hex characters, its contents' digest as a
  one-chunk table (spec/01 §1.1.2); `nil` for a step's output, until it is persisted or
  compared. Read, never computed here.
  """
  @spec digest(t()) :: String.t() | nil
  def digest(%__MODULE__{digest: digest}), do: digest

  @doc """
  The chunk's version: its content digest, else its derivation digest (spec/01 §1.1.3).
  A cache's key for the chunk's results is `{id(chunk), version(chunk), step key}`. `nil`
  while the digest is pending (spec/01 §1.1.4): it matches no key.
  """
  @spec version(t()) :: String.t() | nil
  def version(%__MODULE__{digest: :pending}), do: nil
  def version(%__MODULE__{digest: nil, derivation: derivation}), do: derivation
  def version(%__MODULE__{digest: digest}), do: digest

  @doc """
  The version of the chunk's base (spec/04 §1.5): its content digest before its delta,
  the version a cache held the base's parts under, and an inverse update starts from.
  The chunk's `version/1` when it has no delta; `nil` for a step's output, which has no
  delta.
  """
  @spec base_version(t()) :: String.t() | nil
  def base_version(%__MODULE__{delta: nil} = chunk), do: version(chunk)
  def base_version(%__MODULE__{base_digest: digest}), do: digest

  @doc """
  A per-row step's output chunk of `input` (spec/01 §1.1.3): `columns` packed, nothing
  hashed. Its id is `{id(input), step_key}`, and its version the kernel's digest of
  `{[version(input)], step_key}`. `{:error, faults}` as `Macaw.Data.Table.new/2` reports
  them for columns that are not a table's.
  """
  @spec derive(t(), term(), columns()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def derive(%__MODULE__{} = input, step_key, columns),
    do: output({input.id, step_key}, [input], step_key, columns)

  @doc """
  A global step's output chunk of `inputs`, in order (spec/01 §1.1.3): a sort, a merge of
  several chunks. Its id is `{:combined, digest}`, the kernel's digest of
  `{step_key, [{id, version}, …]}` over the inputs, and its version the kernel's digest of
  `{[version, …], step_key}`. Nothing of the contents is hashed.
  """
  @spec combine([t()], term(), columns()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def combine(inputs, step_key, columns) when is_list(inputs) do
    id = {:combined, Document.digest({step_key, Enum.map(inputs, &{&1.id, version(&1)})})}
    output(id, inputs, step_key, columns)
  end

  defp output(id, inputs, step_key, columns) do
    size =
      case columns do
        [{_, _, values} | _] when is_list(values) -> length(values)
        _ -> 0
      end

    faults =
      for {name, _type, values} <- columns,
          not is_list(values) or length(values) != size,
          do: {[name], {:length, size}}

    {packed, faults} =
      Enum.reduce(columns, {%{}, faults}, fn
        {name, type, values}, {packed, faults} when is_list(values) and length(values) == size ->
          case Column.piece(type, values, name, 0) do
            {:ok, col} -> {Map.put(packed, name, col), faults}
            {:error, column_faults} -> {packed, column_faults ++ faults}
          end

        _column, acc ->
          acc
      end)

    case faults do
      [] ->
        derivation = Document.digest({Enum.map(inputs, &version/1), step_key})
        header = for {name, type, _values} <- columns, do: {name, type}

        {:ok,
         %__MODULE__{
           size: size,
           columns: packed,
           id: id,
           digest: nil,
           derivation: derivation,
           base_rows: size,
           header: header
         }}

      _ ->
        {:error, Enum.sort(faults)}
    end
  end

  # A chunk of `size` rows of the packed `columns`, under the table's `header` of
  # `{name, type}`s in order: hashed here, once. Its id is `id`, or its digest for `nil`.
  @doc false
  @spec build([{term(), atom()}], %{term() => Column.t()}, pos_integer(), term()) :: t()
  def build(header, columns, size, id \\ nil) do
    segments = for {name, _type} <- header, do: [fn -> {columns[name], size} end]
    digest = Digest.digest(header, size, segments)

    %__MODULE__{
      size: size,
      columns: columns,
      id: id || digest,
      digest: digest,
      derivation: nil,
      base_rows: size,
      base_digest: digest,
      header: header
    }
  end

  # A chunk of `rows` (maps keyed by column name), packed under `header` and hashed:
  # data entering, or an open chunk written again (spec/01 §1.1.4). `{:ok, chunk}` or the
  # packing's faults.
  @doc false
  @spec of_rows([{term(), atom()}], [map()], term()) :: {:ok, t()} | {:error, list()}
  def of_rows(header, rows, id) do
    case pack(header, rows) do
      {:ok, columns} -> {:ok, build(header, columns, length(rows), id)}
      {:error, faults} -> {:error, faults}
    end
  end

  defp pack(header, rows) do
    Enum.reduce(header, {:ok, %{}}, fn {name, type}, acc ->
      case {acc, Column.piece(type, Enum.map(rows, &Map.get(&1, name)), name, 0)} do
        {{:ok, packed}, {:ok, col}} -> {:ok, Map.put(packed, name, col)}
        {{:ok, _packed}, {:error, faults}} -> {:error, faults}
        {{:error, faults}, {:error, more}} -> {:error, faults ++ more}
        {{:error, faults}, {:ok, _col}} -> {:error, faults}
      end
    end)
  end

  # -- the delta (spec/01 §1.1.4) --------------------------------------------------------

  @doc false
  # The chunk as read, a row map each with where it is held: `{:base, i}` or `{:side, j}`.
  # A cold chunk is fetched for it.
  @spec read(t()) :: [{map(), {:base | :side, non_neg_integer()}}]
  def read(%__MODULE__{read: %{columns: columns, refs: refs}} = chunk) do
    names = for {name, _type} <- chunk.header, do: name
    n = tuple_size(refs)

    rows =
      case names do
        [] ->
          List.duplicate(%{}, n)

        _ ->
          names
          |> Enum.map(&Column.values(Map.fetch!(columns, &1), n))
          |> Enum.zip_with(&Map.new(Enum.zip(names, &1)))
      end

    Enum.zip(rows, Tuple.to_list(refs))
  end

  def read(%__MODULE__{} = chunk), do: read_base(chunk)

  # The chunk as read, from its base and its delta: done once per state, when the state
  # is made, and for a cold chunk's change that reads it.
  defp read_base(%__MODULE__{} = chunk) do
    base = base(chunk)
    names = for {name, _type} <- chunk.header, do: name
    n = chunk.base_rows

    rows =
      case names do
        [] ->
          List.duplicate(%{}, n)

        _ ->
          names
          |> Enum.map(&Column.values(Map.fetch!(base, &1), n))
          |> Enum.zip_with(&Map.new(Enum.zip(names, &1)))
      end

    Delta.read(chunk.delta, rows)
  end

  @doc false
  # The chunk with `delta` over its base, its size and digest as read: computed now for a
  # chunk in memory, pending for a cold one whose predicates need a read. `nil` for no
  # delta writes the chunk as read into a base of its own.
  @spec with_delta(t(), Delta.t()) :: t()
  def with_delta(%__MODULE__{fetch: fetch} = chunk, delta) when fetch != nil do
    size =
      if delta.predicates == [],
        do: chunk.base_rows - MapSet.size(delta.deleted) + length(delta.side),
        else: nil

    %{chunk | delta: delta, digest: :pending, size: size}
  end

  def with_delta(%__MODULE__{} = chunk, delta) do
    state = %{chunk | delta: delta, read: nil, base_digest: base_version(chunk)}
    {rows, refs} = state |> read_base() |> Enum.unzip()
    {:ok, read} = pack(chunk.header, rows)
    size = length(rows)

    digest =
      Digest.digest(
        chunk.header,
        size,
        for({name, _} <- chunk.header, do: [fn -> {read[name], size} end])
      )

    %{state | size: size, digest: digest, read: %{columns: read, refs: List.to_tuple(refs)}}
  end

  @doc false
  # The chunk in memory: a cold chunk's base fetched once, and its size and digest
  # computed as read. A chunk in memory as it is.
  @spec warm(t()) :: t()
  def warm(%__MODULE__{fetch: nil} = chunk), do: chunk

  def warm(%__MODULE__{fetch: fetch, delta: delta} = chunk) do
    loaded = %{chunk | columns: fetch.(), fetch: nil}

    if delta == nil,
      do: loaded,
      else: with_delta(%{loaded | delta: nil, digest: chunk.base_digest}, delta)
  end

  @doc false
  # The chunk as read written into a new base with no delta: its id, its content digest
  # and so its version kept, since the contents are equal (spec/01 §1.1.4).
  @spec compact(t()) :: t()
  def compact(%__MODULE__{delta: nil} = chunk), do: chunk
  def compact(%__MODULE__{fetch: fetch} = chunk) when fetch != nil, do: chunk

  def compact(%__MODULE__{read: %{columns: columns}} = chunk) do
    %{
      chunk
      | columns: columns,
        delta: nil,
        read: nil,
        base_rows: chunk.size,
        base_digest: chunk.digest
    }
  end

  @doc false
  # Whether the delta has reached a quarter of the base's rows: time to compact.
  @spec due?(t()) :: boolean()
  def due?(%__MODULE__{delta: nil}), do: false
  def due?(%__MODULE__{fetch: fetch}) when fetch != nil, do: false
  def due?(%__MODULE__{delta: delta} = chunk), do: 4 * Delta.size(delta) >= chunk.base_rows

  defp base(%__MODULE__{fetch: nil, columns: columns}), do: columns
  defp base(%__MODULE__{fetch: fetch}), do: fetch.()

  @doc """
  The values of column `name` in the run of `count` rows from `first`, as read through
  the chunk's delta: what a step decides from (spec/04 §1.4). One column is read, never a
  row.
  """
  @spec values(t(), term(), non_neg_integer(), non_neg_integer()) :: [term()]
  def values(%__MODULE__{size: size, columns: columns, delta: nil, fetch: nil}, name, 0, size),
    do: Column.values(Map.fetch!(columns, name), size)

  def values(%__MODULE__{} = chunk, name, first, count),
    do: chunk |> storage(name, first, count) |> Column.values(count)

  @doc """
  The value of column `name` at row `i` of the chunk, as read: one slot of its storage,
  for a step that searches a sorted column (spec/04 §1.4).
  """
  @spec at(t(), term(), non_neg_integer()) :: term()
  def at(%__MODULE__{} = chunk, name, i) do
    [value] = chunk |> storage(name, i, 1) |> Column.values(1)
    value
  end

  @doc """
  A per-row step's output chunk (spec/01 §1.1.3, spec/04 §1.4): the rows at `indexes`
  of the run of `count` rows from `first` of `input`, every column gathered from its
  storage by copying its slots, nothing decoded and nothing hashed. As `derive/3`, its id
  is `{id(input), step_key}` and its version the derivation digest of
  `{[version(input)], step_key}`; the step key names the run when it is not the whole
  chunk.
  """
  @spec gather(t(), non_neg_integer(), non_neg_integer(), [non_neg_integer()], term()) :: t()
  def gather(%__MODULE__{} = input, first, count, indexes, step_key) when is_list(indexes) do
    columns =
      input
      |> view_columns(first, count)
      |> Map.new(fn {name, col} -> {name, Column.gather(col, indexes)} end)

    size = length(indexes)

    %__MODULE__{
      size: size,
      columns: columns,
      id: {input.id, step_key},
      digest: nil,
      derivation: Document.digest({[version(input)], step_key}),
      base_rows: size,
      header: input.header
    }
  end

  @doc """
  A reshaping per-row step's output chunk (spec/04 §1.4, §4.7): the rows at `indexes` of
  the run of `count` rows from `first` of `input`, repeats allowed, under `header`
  (`{name, type}` in order): a column of `added` (a map from name to its values) packed
  from them, any other gathered from the input's column of that name by copying its
  slots. Named as `gather/5` names its chunk; nothing hashed.
  """
  @spec reshape(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          [non_neg_integer()],
          term(),
          list(),
          map()
        ) ::
          t()
  def reshape(%__MODULE__{} = input, first, count, indexes, step_key, header, added) do
    view = view_columns(input, first, count)
    size = length(indexes)

    columns =
      Map.new(header, fn {name, type} ->
        case added do
          %{^name => values} ->
            {:ok, col} = Column.piece(type, values, name, 0)
            {name, col}

          _ ->
            {name, Column.gather(Map.fetch!(view, name), indexes)}
        end
      end)

    %__MODULE__{
      size: size,
      columns: columns,
      id: {input.id, step_key},
      digest: nil,
      derivation: Document.digest({[version(input)], step_key}),
      base_rows: size,
      header: header
    }
  end

  # Every column's storage for the run, as read: the base's, or the state's read view.
  defp view_columns(%__MODULE__{} = chunk, first, count),
    do: Map.new(as_read(chunk), fn {name, col} -> {name, Column.slice(col, first, count)} end)

  # The chunk's columns as read: its base's with no delta; with one, its state's read
  # view, built once when the state was made (spec/01 §1.1.4), so no read rebuilds it. A
  # cold chunk is fetched for it, as `Macaw.Data.Table.warm/1` would.
  defp as_read(%__MODULE__{delta: nil, fetch: nil, columns: columns}), do: columns
  defp as_read(%__MODULE__{read: %{columns: columns}}), do: columns
  defp as_read(%__MODULE__{} = chunk), do: chunk |> warm() |> as_read()

  # The storage of column `name` sliced to the run of `count` rows from `first`.
  @doc false
  @spec storage(t(), term(), non_neg_integer(), non_neg_integer()) :: Column.t()
  def storage(%__MODULE__{size: size, columns: columns, delta: nil, fetch: nil}, name, 0, size),
    do: Map.fetch!(columns, name)

  def storage(%__MODULE__{} = chunk, name, first, count),
    do: chunk |> as_read() |> Map.fetch!(name) |> Column.slice(first, count)

  @doc false
  # A chunk's delta as the changes an inverse update applies to its base's part
  # (spec/04 §1.5): `removed`, a view of the base's rows the delta takes out, and
  # `inserted`, one of its side rows in the order they read, each a chunk of its own,
  # nothing hashed; `gone`, the removed rows' base indexes; and where each base row and
  # each inserted row lies in the chunk as read, `base` and `side` (tuples of positions,
  # `nil` for a removed base row).
  @spec changes(t()) :: map()
  def changes(%__MODULE__{delta: delta, read: %{refs: refs}} = chunk) when delta != nil do
    {base, side} =
      refs
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.reduce(
        {Tuple.duplicate(nil, chunk.base_rows), Tuple.duplicate(nil, length(delta.side))},
        fn
          {{:base, i}, p}, {base, side} -> {put_elem(base, i, p), side}
          {{:side, j}, p}, {base, side} -> {base, put_elem(side, j, p)}
        end
      )

    gone = for i <- 0..(chunk.base_rows - 1)//1, elem(base, i) == nil, do: i
    removed = Map.new(chunk.columns, fn {name, col} -> {name, Column.gather(col, gone)} end)

    # The side rows in the order they read, so the inserted part reads them so too.
    {side_rows, side} =
      delta.side
      |> Enum.with_index(&{&1, elem(side, &2)})
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.unzip()

    {:ok, side_columns} = pack(chunk.header, side_rows)
    removed = local(chunk, removed, length(gone))
    inserted = local(chunk, side_columns, length(side_rows))

    %{
      removed: {removed, 0, length(gone)},
      inserted: {inserted, 0, length(side_rows)},
      gone: MapSet.new(gone),
      base: base,
      side: List.to_tuple(side)
    }
  end

  # A chunk of the rows of `columns` under `chunk`'s header, held for a step's part alone:
  # no id of its own and nothing hashed.
  defp local(chunk, columns, size) do
    %__MODULE__{
      size: size,
      columns: columns,
      id: {chunk.id, :changes},
      digest: nil,
      derivation: nil,
      base_rows: size,
      header: chunk.header
    }
  end
end
