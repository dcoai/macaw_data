defmodule Macaw.Data.Table.Chunk do
  @moduledoc """
  One chunk of a `Macaw.Data.Table` (spec/01 §1.1.1): a run of rows of every column, each
  column packed by itself in the table's forms, Arrow's record batch. A chunk is immutable.

  It carries its **content digest** (spec/01 §1.1.2), its contents' digest as a one-chunk
  table of its table's names and types, computed once when the chunk is built: `digest/1`
  reads it and never hashes.

  A table holds its chunks with the run of each one's rows it reads
  (`Macaw.Data.Table.chunks/1`); a chunk itself is always whole.
  """

  alias Macaw.Data.Table.Column
  alias Macaw.Data.Table.Digest

  @enforce_keys [:size, :columns, :digest]
  defstruct [:size, :columns, :digest]

  @typedoc "A chunk: its row count, each column's storage by name, and its content digest."
  @opaque t :: %__MODULE__{
            size: pos_integer(),
            columns: %{term() => Column.t()},
            digest: String.t()
          }

  @doc "The number of rows the chunk holds."
  @spec size(t()) :: pos_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc """
  The chunk's content digest: 64 lowercase hex characters, the kernel's digest of its
  contents as a one-chunk table (spec/01 §1.1.2). Read, never computed here.
  """
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{digest: digest}), do: digest

  # A chunk of `size` rows of the packed `columns`, under the table's `header` of
  # `{name, type}`s in order: hashed here, once.
  @doc false
  @spec build([{term(), atom()}], %{term() => Column.t()}, pos_integer()) :: t()
  def build(header, columns, size) do
    segments = for {name, _type} <- header, do: [fn -> {columns[name], size} end]
    %__MODULE__{size: size, columns: columns, digest: Digest.digest(header, size, segments)}
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
