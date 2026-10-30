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
end
