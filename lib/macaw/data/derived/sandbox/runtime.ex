defmodule Macaw.Data.Derived.Sandbox.Runtime do
  @moduledoc false
  # What a checked function calls at run time that it did not write (spec/02 §6.3,
  # visualize D-195): a map read, `row.field`, reads the row's key of the field's spelling, an atom or
  # a string, as `Macaw.Data.Table.get/2` does, and raises as a map read does when the
  # row has neither — so a field named by its string reaches a host's atom-keyed rows
  # without an atom made. A table is read through its accessors, never by a map read.
  #
  # Every `Macaw.Data.Derived.Columns` accessor a stored function calls is its twin here
  # (spec/02 §2.2, §6.3), of the same name and arity: it answers as the accessor does, its
  # names and values (`names`, `type`, `column`, `rows`) and its reasons spelled as the
  # function's rows and literals are (`Macaw.Data.Derived.Sandbox.Names.spelling/1`), a
  # word's atom, else the string. So `{:error, {:unknown_column, _}}` in a stored function
  # matches the reason a missing column answers, its `:unknown_column` and the reason's
  # both `"unknown_column"`. `format_error/1` reads a reason so spelled back.

  import Kernel, except: [min: 2, max: 2]

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

  # -- the accessors, spelled --------------------------------------------------------------

  @doc false
  def names(t), do: answer(Columns.names(t), &each/1)
  @doc false
  def type(t, name), do: answer(Columns.type(t, name), &Names.spelling/1)
  @doc false
  def size(t), do: answer(Columns.size(t), & &1)
  @doc false
  def column(t, name), do: answer(Columns.column(t, name), &each/1)
  @doc false
  def numbers(t, name), do: answer(Columns.numbers(t, name), & &1)
  @doc false
  def instants(t, name), do: answer(Columns.instants(t, name), & &1)
  @doc false
  def valid(t, name), do: answer(Columns.valid(t, name), & &1)
  @doc false
  def count(t, name), do: answer(Columns.count(t, name), & &1)
  @doc false
  def sum(t, name), do: answer(Columns.sum(t, name), & &1)
  @doc false
  def mean(t, name), do: answer(Columns.mean(t, name), & &1)
  @doc false
  def min(t, name), do: answer(Columns.min(t, name), & &1)
  @doc false
  def max(t, name), do: answer(Columns.max(t, name), & &1)
  @doc false
  def slice(t, start, count), do: answer(Columns.slice(t, start, count), & &1)
  @doc false
  def take(t, n), do: answer(Columns.take(t, n), & &1)
  @doc false
  def rows(t), do: answer(Columns.rows(t), &Enum.map(&1, fn row -> row(row) end))

  @doc false
  def names!(t), do: value!(names(t))
  @doc false
  def type!(t, name), do: value!(type(t, name))
  @doc false
  def size!(t), do: value!(size(t))
  @doc false
  def column!(t, name), do: value!(column(t, name))
  @doc false
  def numbers!(t, name), do: value!(numbers(t, name))
  @doc false
  def instants!(t, name), do: value!(instants(t, name))
  @doc false
  def valid!(t, name), do: value!(valid(t, name))
  @doc false
  def count!(t, name), do: value!(count(t, name))
  @doc false
  def sum!(t, name), do: value!(sum(t, name))
  @doc false
  def mean!(t, name), do: value!(mean(t, name))
  @doc false
  def min!(t, name), do: value!(min(t, name))
  @doc false
  def max!(t, name), do: value!(max(t, name))
  @doc false
  def slice!(t, start, count), do: value!(slice(t, start, count))
  @doc false
  def take!(t, n), do: value!(take(t, n))
  @doc false
  def rows!(t), do: value!(rows(t))

  # A reason's words, by their spellings: the atoms a reason holds, read back from the
  # strings a stored function writes for them. A fixed table; no atom is made.
  @words Map.new(
           [
             :unknown_column,
             :wrong_type,
             :overflow,
             :type,
             :name,
             :table,
             :integer,
             :non_neg_integer
           ] ++
             Table.types(),
           &{Atom.to_string(&1), &1}
         )

  @doc false
  def format_error(reason), do: Columns.format_error(unspelled(reason))

  defp answer({:ok, value}, spell), do: {:ok, spell.(value)}
  defp answer({:error, reason}, _spell), do: {:error, spelled(reason)}

  defp value!({:ok, value}), do: value
  defp value!({:error, reason}), do: raise(ArgumentError, format_error(reason))

  defp each(values), do: Enum.map(values, &Names.spelling/1)
  defp row(row), do: Map.new(row, fn {k, v} -> {Names.spelling(k), Names.spelling(v)} end)

  defp spelled(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.map(&spelled/1) |> List.to_tuple()

  defp spelled(reason) when is_list(reason), do: Enum.map(reason, &spelled/1)
  defp spelled(reason), do: Names.spelling(reason)

  defp unspelled(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.map(&unspelled/1) |> List.to_tuple()

  defp unspelled(reason) when is_list(reason), do: Enum.map(reason, &unspelled/1)
  defp unspelled(word) when is_binary(word), do: Map.get(@words, word, word)
  defp unspelled(other), do: other
end
