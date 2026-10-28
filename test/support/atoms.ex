defmodule Macaw.Data.Test.Atoms do
  @moduledoc """
  "Makes no atom", checked on the input's own names (macaw_data#1).

  The node's atom count is no measure of one test: every process on the node moves it —
  other tests, the logger, code loading — and a test can't hold the atom table to itself
  without stopping all of them. So a test spells its input with `fresh/0` names, runs the
  code, and asserts `made/1` of those names is `[]`. Nothing else on the node can make a
  name it has never seen, so the check holds whatever else runs, async or not.
  """

  @doc "A name no atom has been made of: letters and digits, unique on the node."
  @spec fresh() :: String.t()
  def fresh, do: "zz#{System.unique_integer([:positive])}q"

  @doc """
  Whether `name` is an atom, asked without making one: the parser, reading only existing
  atoms, answers an error for a name the node never saw.
  """
  @spec atom?(String.t()) :: boolean()
  def atom?(name) do
    false = String.contains?(name, ["\"", "\\", "\#{"])

    match?(
      {:ok, _},
      Code.string_to_quoted(~s(:"#{name}"), existing_atoms_only: true, emit_warnings: false)
    )
  end

  @doc "The names among `names` that are atoms, in order."
  @spec made([String.t()]) :: [String.t()]
  def made(names), do: Enum.filter(names, &atom?/1)
end
