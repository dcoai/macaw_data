defmodule Macaw.Data.Test.Reader do
  @moduledoc """
  A `Table.Reader` source read by rows, as Explorer's frames are: the table tests' stand-in
  for a data-frame library, so the edge is tested without one.
  """
  defstruct [:columns, :rows]
end

defimpl Table.Reader, for: Macaw.Data.Test.Reader do
  def init(%{columns: columns, rows: rows}), do: {:rows, %{columns: columns}, rows}
end
