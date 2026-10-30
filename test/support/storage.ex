defmodule Macaw.Data.Test.Storage do
  @moduledoc false
  # A table's storage, for the tests that check its layout byte for byte (spec/01 §1.1):
  # column `name` of the table's first chunk, as the table views it, its buffers sliced
  # to the view.

  alias Macaw.Data.Table
  alias Macaw.Data.Table.Column

  def storage(table, name) do
    [{chunk, first, count} | _] = Table.chunks(table)
    Column.slice(Map.fetch!(chunk.columns, name), first, count)
  end

  @doc """
  The table's rows rechunked: `size` rows a chunk from the first, the last shorter, or
  `:one`, every row in one chunk, whatever its length. Tests inject chunk sizes; the
  library never takes one (spec/01 §1.1.1).
  """
  def chunked(table, size) do
    header = for name <- Table.names(table), do: {name, Table.column_type(table, name)}
    rows = Table.rows(table)
    groups = if size == :one, do: [rows], else: Enum.chunk_every(rows, size)

    chunks =
      for group <- groups, group != [] do
        {:ok, chunk} = Macaw.Data.Table.Chunk.of_rows(header, group, nil)
        chunk
      end

    {:ok, chunked} = Table.from_chunks(header, chunks, sorted: Table.sorted(table))
    chunked
  end
end
