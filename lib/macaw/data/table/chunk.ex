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
  alias Macaw.Data.Table.Digest
  alias Macaw.Layers.Document

  @enforce_keys [:size, :columns, :id, :digest, :derivation]
  defstruct [:size, :columns, :id, :digest, :derivation]

  @typedoc """
  A chunk: its row count, each column's storage by name, its logical id, and its content
  digest or its derivation digest.
  """
  @opaque t :: %__MODULE__{
            size: non_neg_integer(),
            columns: %{term() => Column.t()},
            id: term(),
            digest: String.t() | nil,
            derivation: String.t() | nil
          }

  @typedoc "A step output's columns: `{name, type, values}`, as `Macaw.Data.Table.new/2` takes."
  @type columns :: [{term(), atom(), [term()]}]

  @doc "The number of rows the chunk holds."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc "The names of the chunk's columns, in no order."
  @spec names(t()) :: [term()]
  def names(%__MODULE__{columns: columns}), do: Map.keys(columns)

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
  A cache's key for the chunk's results is `{id(chunk), version(chunk), step key}`.
  """
  @spec version(t()) :: String.t()
  def version(%__MODULE__{digest: nil, derivation: derivation}), do: derivation
  def version(%__MODULE__{digest: digest}), do: digest

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

        {:ok,
         %__MODULE__{size: size, columns: packed, id: id, digest: nil, derivation: derivation}}

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
    %__MODULE__{size: size, columns: columns, id: id || digest, digest: digest, derivation: nil}
  end

  # The values of column `name` in the run of `count` rows from `first`.
  @doc false
  @spec values(t(), term(), non_neg_integer(), non_neg_integer()) :: [term()]
  def values(%__MODULE__{size: size, columns: columns}, name, 0, size),
    do: Column.values(Map.fetch!(columns, name), size)

  def values(%__MODULE__{} = chunk, name, first, count),
    do: chunk |> storage(name, first, count) |> Column.values(count)

  # The storage of column `name` sliced to the run of `count` rows from `first`.
  @doc false
  @spec storage(t(), term(), non_neg_integer(), non_neg_integer()) :: Column.t()
  def storage(%__MODULE__{size: size, columns: columns}, name, 0, size),
    do: Map.fetch!(columns, name)

  def storage(%__MODULE__{columns: columns}, name, first, count),
    do: columns |> Map.fetch!(name) |> Column.slice(first, count)
end
