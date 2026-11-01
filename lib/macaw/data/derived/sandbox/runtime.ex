defmodule Macaw.Data.Derived.Sandbox.Runtime do
  @moduledoc false
  # What a checked function calls at run time that it did not write (spec/02 §6.3,
  # visualize D-195): a map read, `row.field`, reads the row's key of the field's spelling, an atom or
  # a string, as `Macaw.Data.Table.get/2` does, and raises as a map read does when the
  # row has neither — so a field named by its string reaches a host's atom-keyed rows
  # without an atom made. A table is read through its accessors, never by a map read.
  #
  # The `Macaw.Data.Derived.Columns` accessors whose answer holds names or values (spec/02
  # §2.2) are these twins, which spell them as the function's rows are spelled
  # (`Macaw.Data.Derived.Sandbox.Names.spelling/1`): a word's atom, else the string.

  alias Macaw.Data.Derived.Columns
  alias Macaw.Data.Derived.Sandbox.Names
  alias Macaw.Data.Table

  @doc false
  @spec get(map(), atom() | String.t()) :: term()
  def get(%Table{}, field) do
    raise ArgumentError,
          "a table has no field #{inspect(field)}: read it through Macaw.Data.Derived.Columns"
  end

  def get(row, field), do: Map.fetch!(row, Table.key(row, field) || field)

  @doc false
  @spec names(Table.t()) :: [term()]
  def names(table), do: Enum.map(Columns.names(table), &Names.spelling/1)

  @doc false
  @spec type(Table.t(), term()) :: term()
  def type(table, name), do: Names.spelling(Columns.type(table, name))

  @doc false
  @spec column(Table.t(), term()) :: [term()]
  def column(table, name), do: Enum.map(Columns.column(table, name), &Names.spelling/1)

  @doc false
  @spec rows(Table.t()) :: [map()]
  def rows(table) do
    for row <- Columns.rows(table),
        do: Map.new(row, fn {k, v} -> {Names.spelling(k), Names.spelling(v)} end)
  end
end
