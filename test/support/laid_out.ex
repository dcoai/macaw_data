defmodule Macaw.Data.Test.LaidOut do
  @moduledoc false
  # A struct whose fields are a layout of its contents: its canonical term
  # (`Macaw.Layers.Digest`) is its rows alone, so two layouts of the same rows are one
  # value to the kernel's digest, and so to a table's (macaw_data#218).
  defstruct rows: [], layout: nil
end

defmodule Macaw.Data.Test.NotDataInside do
  @moduledoc false
  # A struct whose canonical term is not data, though its fields are: the kernel's encoder
  # refuses it, so `Table.new/2` must too (macaw_data#218).
  defstruct name: nil
end

defimpl Macaw.Layers.Digest, for: Macaw.Data.Test.LaidOut do
  def canonical(%{rows: rows}), do: {"test.laid_out", rows}
end

defimpl Macaw.Layers.Digest, for: Macaw.Data.Test.NotDataInside do
  def canonical(%{name: name}), do: {name, self()}
end
