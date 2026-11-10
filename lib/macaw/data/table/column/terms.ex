defmodule Macaw.Data.Table.Column.Terms do
  @moduledoc false
  # A `:color` column's packed form (spec/01 §1.1, macaw_data#235):
  #
  #   {:terms, codes, validity, terms}
  #
  # `terms` is a tuple of the column's distinct values in the order they first appear,
  # each told apart as exactly as a map key tells it (`1` and `1.0`, `0.0` and `-0.0` are
  # two), and `codes` a little-endian int32 per value into it, 0 at a missing value's
  # slot. A color is a nested term of no fixed width, but a column repeats few of them,
  # so each is held once and decoded by no one: a value reads back as the very term
  # given. The tag is its own, never `:dictionary`, whose dictionary is a text column
  # that grouping and filtering read as strings.
  #
  # A slice and a gather keep the whole tuple, as a dictionary column keeps its
  # dictionary; `head/2` cuts it to the terms the kept values hold, so an open chunk's
  # held values join an increment's as packing every value numbers them.

  alias Macaw.Data.Table.{Bitmap, Column}

  @doc false
  # Values packed, each distinct one numbered as it first appears.
  @spec pack([term()]) :: Column.t()
  def pack(values) do
    {codes, terms} = codes(values, <<>>, %{}, [], 0)
    {:terms, codes, Bitmap.validity(values), List.to_tuple(:lists.reverse(terms))}
  end

  defp codes([], codes, _seen, terms, _next), do: {codes, terms}

  defp codes([nil | rest], codes, seen, terms, next),
    do: codes(rest, <<codes::binary, 0::32>>, seen, terms, next)

  defp codes([v | rest], codes, seen, terms, next) do
    case seen do
      %{^v => code} ->
        codes(rest, <<codes::binary, code::little-32>>, seen, terms, next)

      _new ->
        seen = Map.put(seen, v, next)
        codes(rest, <<codes::binary, next::little-32>>, seen, [v | terms], next + 1)
    end
  end

  @doc false
  # The `n` values, `nil` where one is missing.
  @spec values(Column.t(), non_neg_integer()) :: [term()]
  def values({:terms, codes, validity, terms}, n) do
    if Bitmap.all?(validity, n),
      do: for(<<c::little-32 <- codes>>, do: elem(terms, c)),
      else: decode(codes, Bitmap.bits(validity, n), terms)
  end

  defp decode(<<c::little-32, codes::binary>>, [1 | bits], terms),
    do: [elem(terms, c) | decode(codes, bits, terms)]

  defp decode(<<_::32, codes::binary>>, [0 | bits], terms), do: [nil | decode(codes, bits, terms)]
  defp decode(<<>>, [], _terms), do: []

  @doc false
  @spec slice(Column.t(), non_neg_integer(), non_neg_integer()) :: Column.t()
  def slice({:terms, codes, validity, terms}, first, n),
    do: {:terms, binary_part(codes, first * 4, n * 4), Bitmap.slice(validity, first, n), terms}

  @doc false
  # The first `at` values as packing them alone gives: codes number terms in
  # first-appearance order, so the kept values hold codes 0 to k - 1 and their terms are
  # the tuple's first k.
  @spec head(Column.t(), non_neg_integer()) :: Column.t()
  def head(column, at) do
    {:terms, codes, validity, terms} = slice(column, 0, at)

    k =
      codes
      |> present(Bitmap.bits(validity, at))
      |> Enum.reduce(-1, &max/2)
      |> Kernel.+(1)

    {:terms, codes, validity, terms |> Tuple.to_list() |> Enum.take(k) |> List.to_tuple()}
  end

  defp present(<<c::little-32, codes::binary>>, [1 | bits]), do: [c | present(codes, bits)]
  defp present(<<_::32, codes::binary>>, [0 | bits]), do: present(codes, bits)
  defp present(<<>>, []), do: []

  @doc false
  # Columns of `n` values each joined end to end: their codes as they are where every
  # piece has the same terms, else each code moved to its term's place among every
  # piece's terms, in first-appearance order, a missing slot keeping code 0. So two
  # pieces packed from their own values (or `head/2` of such a column) join as packing
  # every value numbers them.
  @spec concat([{Column.t(), non_neg_integer()}]) :: {:ok, Column.t()}
  def concat(pieces) do
    validity = Bitmap.concat(for {{:terms, _, v, _}, n} <- pieces, do: {v, n})

    case Enum.uniq(for {{:terms, _, _, terms}, _n} <- pieces, do: terms) do
      [terms] ->
        {:ok,
         {:terms, IO.iodata_to_binary(for {{_, c, _, _}, _n} <- pieces, do: c), validity, terms}}

      _several ->
        {places, all, _next} =
          for {{:terms, _, _, terms}, _n} <- pieces,
              term <- Tuple.to_list(terms),
              reduce: {%{}, [], 0} do
            {places, all, next} when is_map_key(places, term) -> {places, all, next}
            {places, all, next} -> {Map.put(places, term, next), [term | all], next + 1}
          end

        codes =
          for {{:terms, codes, v, terms}, n} <- pieces do
            moved =
              terms |> Tuple.to_list() |> Enum.map(&Map.fetch!(places, &1)) |> List.to_tuple()

            moved(codes, Bitmap.bits(v, n), moved, <<>>)
          end

        {:ok, {:terms, IO.iodata_to_binary(codes), validity, List.to_tuple(:lists.reverse(all))}}
    end
  end

  defp moved(<<c::little-32, codes::binary>>, [1 | bits], moved, acc),
    do: moved(codes, bits, moved, <<acc::binary, elem(moved, c)::little-32>>)

  defp moved(<<_::32, codes::binary>>, [0 | bits], moved, acc),
    do: moved(codes, bits, moved, <<acc::binary, 0::32>>)

  defp moved(<<>>, [], _moved, acc), do: acc
end
