defmodule Macaw.Data.Lists do
  @moduledoc false
  # The one judge of a list a caller gave (spec/00 §5, macaw_data#184, #169). `is_list/1`
  # passes an improper list, and `Enum` raises on its tail, so a list read from a caller is
  # judged here: an improper list fails `is_proper_list/1`, and falls to the clause that
  # refuses any other term, with the fault that position already has.
  #
  # `length/1` walks the list once. In a guard, its failure on an improper list is the guard
  # failing, no raise. Outside a guard that is `proper?/1`'s to answer.

  @doc false
  defguard is_proper_list(term) when is_list(term) and length(term) >= 0

  @doc false
  @spec proper?(term()) :: boolean()
  def proper?(term) when is_proper_list(term), do: true
  def proper?(_term), do: false
end
