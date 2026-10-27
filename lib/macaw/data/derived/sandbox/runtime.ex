defmodule Macaw.Data.Derived.Sandbox.Runtime do
  @moduledoc false
  # What a checked function calls at run time that it did not write (spec/02 §6.3,
  # visualize D-195): a map read, `row.field`, reads the row's key of the field's spelling, an atom or
  # a string, as `Macaw.Data.Table.get/2` does, and raises as a map read does when the
  # row has neither — so a field named by its string reaches a host's atom-keyed rows
  # without an atom made.

  alias Macaw.Data.Table

  @doc false
  @spec get(map(), atom() | String.t()) :: term()
  def get(row, field), do: Map.fetch!(row, Table.key(row, field) || field)
end
