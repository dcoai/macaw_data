defmodule Macaw.Data.Table.Canonical do
  @moduledoc false
  # A column's canonical form (spec/01 §1.1.2): what its content digest is over. It is a
  # form of the values, never of the buffers, so every storage form of the same values
  # (`Macaw.Data.Table.Column`), in any chunking, gives the same bytes. Each value is a tag
  # byte, an 8-byte word, and bytes of its own; a column's form is three streams:
  #
  #   tags   one byte per value
  #   words  eight bytes per value, little-endian
  #   bytes  each value's own bytes, in order, self-delimiting given its tag and word
  #
  # | Value | Tag | Word | Bytes |
  # |---|---|---|---|
  # | `nil` | 0 | 0 | none |
  # | an integer in int64 | 1 | the integer, signed | none |
  # | a float | 2 | its IEEE 754 binary64 bits | none |
  # | an integer beyond int64 | 3 | 0 | its kernel encoding |
  # | a binary | 4 | its byte size | its bytes |
  # | any other term | 7 | 0 | its kernel encoding |
  # | a UTC `DateTime` (ISO) | 8 | its microseconds since the Unix epoch | its precision, a byte |
  # | a `NaiveDateTime` (ISO) | 9 | its wall-clock microseconds since 1970-01-01 | its precision, a byte |
  # | a `Date` (ISO) | 10 | its days since 1970-01-01 | none |
  # | a `DateTime` in another zone (ISO) | 11 | its UTC microseconds | its precision, a byte, then the kernel encoding of `{time_zone, zone_abbr, utc_offset, std_offset}` |
  #
  # A value has one row of this table whatever form holds it, and the row determines the
  # value: the three streams of a column are a faithful, layout-free form of its values.
  # The forms that lay the values out the canonical way already (int64, float64, UTC
  # microseconds, text) give their buffers nearly as they are; the others are read value
  # by value.

  import Bitwise

  alias Macaw.Data.Table.Column
  alias Macaw.Data.Table.Digest

  @utc {"Etc/UTC", "UTC", 0, 0}
  @s64_min -0x8000000000000000
  @s64_max 0x7FFFFFFFFFFFFFFF

  # Each byte of a validity bitmap as eight tag bytes, least-significant bit first: the tag
  # where the bit is set, 0 where it is not.
  @expansions (for tag <- [1, 2, 4, 8, 10], into: %{} do
                 {tag,
                  List.to_tuple(
                    for byte <- 0..255,
                        do: for(i <- 0..7, into: <<>>, do: <<(byte >>> i &&& 1) * tag>>)
                  )}
               end)

  @doc false
  # The canonical streams of `count` values held in `storage`, a form sliced to them.
  @spec streams(Column.t(), non_neg_integer()) :: {iodata(), iodata(), iodata()}
  def streams(storage, count)

  def streams({:int64, data, validity}, n), do: {tags(validity, n, 1), data, []}
  def streams({:float64, data, validity}, n), do: {tags(validity, n, 2), data, []}

  def streams({:utc, us, validity, precision}, n) when is_integer(precision) do
    tags = tags(validity, n, 8)
    {tags, us, :binary.copy(<<precision>>, present(tags, n))}
  end

  def streams({:date, days, validity}, n) do
    words = for <<d::signed-little-32 <- days>>, into: <<>>, do: <<d::signed-little-64>>
    {tags(validity, n, 10), words, []}
  end

  def streams({form, offsets, data, validity}, n) when form in [:text, :binary] do
    <<from::signed-little-32, _::binary>> = offsets
    to = :binary.decode_unsigned(binary_part(offsets, 4 * n, 4), :little)
    {tags(validity, n, 4), lengths(offsets), binary_part(data, from, to - from)}
  end

  def streams({:dictionary, codes, validity, {offsets, data}, nil}, n) do
    strings = offsets |> lengths() |> dictionary(data, 0, []) |> List.to_tuple()
    tags = tags(validity, n, 4)
    {words, bytes} = coded(codes, tags, strings, <<>>, [])
    {tags, words, bytes}
  end

  def streams(storage, n), do: values(Column.values(storage, n))

  # -- one value at a time ----------------------------------------------------------------

  defp values(values) do
    {tags, words, bytes} =
      Enum.reduce(values, {[], [], []}, fn v, {tags, words, bytes} ->
        {tag, word, own} = value(v)
        {[tag | tags], [word | words], [own | bytes]}
      end)

    {Enum.reverse(tags), Enum.reverse(words), Enum.reverse(bytes)}
  end

  defp value(nil), do: {0, <<0::64>>, []}

  defp value(v) when is_integer(v) and v >= @s64_min and v <= @s64_max,
    do: {1, <<v::signed-little-64>>, []}

  defp value(v) when is_integer(v), do: {3, <<0::64>>, Digest.encode(v)}
  defp value(v) when is_float(v), do: {2, <<v::float-little-64>>, []}
  defp value(v) when is_binary(v), do: {4, <<byte_size(v)::little-64>>, v}

  defp value(%DateTime{calendar: Calendar.ISO, microsecond: {_, p}} = t) do
    us = DateTime.to_unix(t, :microsecond)

    case {t.time_zone, t.zone_abbr, t.utc_offset, t.std_offset} do
      @utc -> {8, <<us::signed-little-64>>, <<p>>}
      zone -> {11, <<us::signed-little-64>>, [p | Digest.encode(zone)]}
    end
  end

  defp value(%NaiveDateTime{calendar: Calendar.ISO, microsecond: {_, p}} = t) do
    us = NaiveDateTime.diff(t, ~N[1970-01-01 00:00:00], :microsecond)
    {9, <<us::signed-little-64>>, <<p>>}
  end

  defp value(%Date{calendar: Calendar.ISO} = d),
    do: {10, <<Date.diff(d, ~D[1970-01-01])::signed-little-64>>, []}

  defp value(other), do: {7, <<0::64>>, Digest.encode(other)}

  # -- buffers ----------------------------------------------------------------------------

  # The first n tag bytes of a validity bitmap: the tag where a value is present, 0 where
  # it is missing.
  defp tags(validity, n, tag) do
    expansion = Map.fetch!(@expansions, tag)
    binary_part(for(<<byte <- validity>>, into: <<>>, do: elem(expansion, byte)), 0, n)
  end

  # A dictionary's strings, in order, from their byte sizes.
  defp dictionary(<<size::little-64, sizes::binary>>, data, at, acc),
    do: dictionary(sizes, data, at + size, [binary_part(data, at, size) | acc])

  defp dictionary(<<>>, _data, _at, acc), do: Enum.reverse(acc)

  # Each coded value's byte size and bytes; a missing value's code is not read.
  defp coded(<<c::little-32, codes::binary>>, <<4, tags::binary>>, strings, words, bytes) do
    string = elem(strings, c)
    coded(codes, tags, strings, <<words::binary, byte_size(string)::little-64>>, [bytes | string])
  end

  defp coded(<<_::32, codes::binary>>, <<0, tags::binary>>, strings, words, bytes),
    do: coded(codes, tags, strings, <<words::binary, 0::64>>, bytes)

  defp coded(<<>>, <<>>, _strings, words, bytes), do: {words, bytes}

  defp present(tags, n), do: n - length(:binary.matches(tags, <<0>>))

  # Each value's byte size, from n + 1 offsets: a missing value's is 0.
  defp lengths(<<from::signed-little-32, rest::binary>>), do: lengths(rest, from, <<>>)

  defp lengths(<<to::signed-little-32, rest::binary>>, from, acc),
    do: lengths(rest, to, <<acc::binary, to - from::little-64>>)

  defp lengths(<<>>, _from, acc), do: acc
end
