defmodule Macaw.Data.Table.Column.Concat do
  @moduledoc false
  # Columns joined end to end, nothing decoded (spec/01 §2.4, macaw_data#128, #138): the
  # pieces of one column across a table's chunks as one storage, so rows in any order
  # across chunks are gathered by their slots (`Macaw.Data.Table.Column.gather/2`).
  #
  # - Fixed-width buffers of one form (int64, float64, date, utc, naive) join as binaries;
  #   a time's precision is kept where every piece shares it and spelled per value where not.
  # - Text and binary columns of one form join their data, each piece's offsets moved past
  #   the data before it, while the whole fits int32 offsets.
  # - Dictionary columns join their codes: as they are where every piece has the same
  #   dictionary, else each code moved to its string's place in a dictionary of every
  #   piece's strings, in first-appearance order. A missing or boolean slot keeps code 0.
  #   Side bitmaps of booleans join, a piece without them read as holding none.
  #
  # Validity bitmaps join bit by bit (`Macaw.Data.Table.Bitmap.concat/1`). Any other form,
  # or pieces of different forms, is `:general`, which a caller reads value by value.

  alias Macaw.Data.Table.{Bitmap, Column}

  @s32_max 0x7FFFFFFF

  @doc false
  @spec concat([{tuple(), non_neg_integer()}]) :: {:ok, tuple()} | :general
  def concat([{_column, _n} | _] = pieces) do
    case Enum.uniq_by(pieces, fn {column, _n} -> shape(column) end) do
      [{column, _n}] -> joined(shape(column), pieces)
      _shapes -> :general
    end
  end

  def concat([]), do: :general

  defp shape({form, _data, _validity}) when form in [:int64, :float64, :date], do: form
  defp shape({form, _us, _validity, _precision}) when form in [:utc, :naive], do: form

  defp shape({form, _offsets, data, _validity}) when form in [:text, :binary] and is_binary(data),
    do: form

  defp shape({:dictionary, _codes, _validity, _dictionary, _booleans}), do: :dictionary
  defp shape(_column), do: :general

  defp joined(:general, _pieces), do: :general

  defp joined(form, pieces) when form in [:int64, :float64, :date] do
    data = IO.iodata_to_binary(for {{_form, data, _validity}, _n} <- pieces, do: data)
    {:ok, {form, data, validity(pieces)}}
  end

  defp joined(form, pieces) when form in [:utc, :naive] do
    us = IO.iodata_to_binary(for {{_form, us, _validity, _precision}, _n} <- pieces, do: us)

    precision =
      case Enum.uniq(for {{_f, _us, _v, precision}, _n} <- pieces, do: precision) do
        [p] when is_integer(p) ->
          p

        _several ->
          IO.iodata_to_binary(
            for {{_f, _us, _v, p}, n} <- pieces,
                do: if(is_integer(p), do: :binary.copy(<<p>>, n), else: p)
          )
      end

    {:ok, {form, us, validity(pieces), precision}}
  end

  defp joined(form, pieces) when form in [:text, :binary] do
    {offsets, data, size} =
      Enum.reduce(pieces, {[], [], 0}, fn {{_form, offsets, data, _validity}, n},
                                          {all, parts, at} ->
        <<from::signed-little-32, rest::binary>> = offsets
        <<to::signed-little-32>> = binary_part(offsets, n * 4, 4)

        moved =
          for <<o::signed-little-32 <- rest>>, into: <<>>, do: <<o - from + at::signed-little-32>>

        {[moved | all], [binary_part(data, from, to - from) | parts], at + to - from}
      end)

    if size > @s32_max do
      :general
    else
      {:ok,
       {form, IO.iodata_to_binary([<<0::32>> | Enum.reverse(offsets)]),
        IO.iodata_to_binary(Enum.reverse(data)), validity(pieces)}}
    end
  end

  defp joined(:dictionary, pieces) do
    dictionaries = for {{:dictionary, _c, _v, dictionary, _b}, _n} <- pieces, do: dictionary

    {codes, dictionary} =
      case Enum.uniq(dictionaries) do
        [one] -> {IO.iodata_to_binary(for {{_, codes, _, _, _}, _n} <- pieces, do: codes), one}
        _several -> merged(pieces, dictionaries)
      end

    {:ok, {:dictionary, codes, validity(pieces), dictionary, booleans(pieces)}}
  end

  defp validity(pieces),
    do: Bitmap.concat(for {column, n} <- pieces, do: {Column.validity(column), n})

  # Every piece's strings in one dictionary, first appearance first, and each piece's codes
  # moved to their strings' places; a slot that holds no string keeps code 0.
  defp merged(pieces, dictionaries) do
    {places, strings, _next} =
      dictionaries
      |> Enum.flat_map(&strings/1)
      |> Enum.reduce({%{}, [], 0}, fn s, {places, strings, next} ->
        if is_map_key(places, s),
          do: {places, strings, next},
          else: {Map.put(places, s, next), [s | strings], next + 1}
      end)

    strings = Enum.reverse(strings)

    codes =
      for {{:dictionary, codes, validity, dictionary, booleans}, n} <- pieces do
        moved = dictionary |> strings() |> Enum.map(&Map.fetch!(places, &1)) |> List.to_tuple()
        moved_codes(codes, holds(validity, booleans, n), moved)
      end

    {offsets, _at} =
      Enum.map_reduce(strings, 0, fn s, at ->
        at = at + byte_size(s)
        {<<at::signed-little-32>>, at}
      end)

    {IO.iodata_to_binary(codes),
     {IO.iodata_to_binary([<<0::32>> | offsets]), IO.iodata_to_binary(strings)}}
  end

  defp strings({offsets, data}) do
    bounds = for <<o::signed-little-32 <- offsets>>, do: o

    bounds
    |> Enum.zip(tl(bounds))
    |> Enum.map(fn {from, to} -> binary_part(data, from, to - from) end)
  end

  # Which slots hold a string: `:all`, or a bit per slot, valid and not a boolean.
  defp holds(validity, nil, n),
    do: if(Bitmap.all?(validity, n), do: :all, else: Bitmap.bits(validity, n))

  defp holds(validity, {kinds, _values}, n),
    do: Enum.zip_with(Bitmap.bits(validity, n), Bitmap.bits(kinds, n), &(&1 * (1 - &2)))

  defp moved_codes(codes, :all, moved),
    do: for(<<c::little-32 <- codes>>, into: <<>>, do: <<elem(moved, c)::little-32>>)

  defp moved_codes(codes, bits, moved) do
    Enum.zip_with(for(<<c::little-32 <- codes>>, do: c), bits, fn
      c, 1 -> <<elem(moved, c)::little-32>>
      _c, 0 -> <<0::32>>
    end)
    |> IO.iodata_to_binary()
  end

  # The pieces' side bitmaps of booleans joined, a piece without them read as all zeros;
  # `nil` when none has them.
  defp booleans(pieces) do
    if Enum.all?(pieces, fn {{:dictionary, _, _, _, b}, _n} -> b == nil end) do
      nil
    else
      sides =
        for {{:dictionary, _, _, _, b}, n} <- pieces do
          case b do
            nil -> {zeros(n), zeros(n), n}
            {kinds, values} -> {kinds, values, n}
          end
        end

      {Bitmap.concat(for {k, _v, n} <- sides, do: {k, n}),
       Bitmap.concat(for {_k, v, n} <- sides, do: {v, n})}
    end
  end

  defp zeros(n), do: <<0::size(div(n + 7, 8) * 8)>>
end
