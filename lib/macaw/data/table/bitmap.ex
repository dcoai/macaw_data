defmodule Macaw.Data.Table.Bitmap do
  @moduledoc false
  # A column's bitmaps (spec/01 §1.1): Arrow's, least-significant bit first. Value i is
  # bit (i rem 8) of byte (i div 8), and the last byte's padding bits are 0.
  #
  # A bitmap is read as one little-endian integer wherever that is exact: bit i of the
  # bitmap is then bit i of the integer, so a slice is a shift and a mask. The BEAM's own
  # bitstring slicing reads a byte's bits most-significant first, so it is never used to
  # cut one here.

  import Bitwise

  @doc false
  # A bitmap of `values`, a bit set where `bit?` holds: eight values a byte, the last
  # byte's padding 0.
  @spec from([term()], (term() -> boolean())) :: binary()
  def from(values, bit?), do: from(values, bit?, <<>>)

  defp from([a, b, c, d, e, f, g, h | rest], bit?, acc) do
    from(
      rest,
      bit?,
      <<acc::binary, bit(bit?, h)::1, bit(bit?, g)::1, bit(bit?, f)::1, bit(bit?, e)::1,
        bit(bit?, d)::1, bit(bit?, c)::1, bit(bit?, b)::1, bit(bit?, a)::1>>
    )
  end

  defp from([], _bit?, acc), do: acc

  defp from(tail, bit?, acc) do
    {byte, _} =
      Enum.reduce(tail, {0, 0}, fn v, {byte, i} -> {byte ||| bit(bit?, v) <<< i, i + 1} end)

    <<acc::binary, byte>>
  end

  defp bit(bit?, v), do: if(bit?.(v), do: 1, else: 0)

  @doc false
  # The validity bitmap of `values`, a bit set where a value is not `nil`: as `from/2`,
  # with no function call per value.
  @spec validity([term()]) :: binary()
  def validity(values), do: validity(values, <<>>)

  defp validity([a, b, c, d, e, f, g, h | rest], acc) do
    validity(
      rest,
      <<acc::binary, valid(h)::1, valid(g)::1, valid(f)::1, valid(e)::1, valid(d)::1, valid(c)::1,
        valid(b)::1, valid(a)::1>>
    )
  end

  defp validity(tail, acc), do: from(tail, &(&1 != nil), acc)

  defp valid(nil), do: 0
  defp valid(_value), do: 1

  @doc false
  # A bitmap of bits given as a list of 0s and 1s, in value order.
  @spec pack([0 | 1]) :: binary()
  def pack(bits), do: pack(bits, <<>>)

  defp pack([a, b, c, d, e, f, g, h | rest], acc),
    do: pack(rest, <<acc::binary, h::1, g::1, f::1, e::1, d::1, c::1, b::1, a::1>>)

  defp pack([], acc), do: acc
  defp pack(tail, acc), do: <<acc::binary, low(tail, 0, 0)>>

  defp low([b | rest], i, byte), do: low(rest, i + 1, byte ||| b <<< i)
  defp low([], _i, byte), do: byte

  @doc false
  # A bitmap of `n` set bits.
  @spec ones(non_neg_integer()) :: binary()
  def ones(n), do: <<(1 <<< n) - 1::little-size(bytes(n) * 8)>>

  @doc false
  # Whether the first `n` bits of a bitmap are all set: every value valid, when it is a
  # validity bitmap. Two compares, no bit expanded.
  @spec all?(binary(), non_neg_integer()) :: boolean()
  def all?(bitmap, n) do
    whole = div(n, 8)

    case bitmap do
      <<x::size(^whole * 8), rest::binary>> when x == (1 <<< (whole * 8)) - 1 ->
        case rem(n, 8) do
          0 -> true
          r -> match?(<<last, _::binary>> when (last &&& (1 <<< r) - 1) == (1 <<< r) - 1, rest)
        end

      _ ->
        false
    end
  end

  @doc false
  # The first `n` bits of a bitmap, each 0 or 1, in value order.
  @spec bits(binary(), non_neg_integer()) :: [0 | 1]
  def bits(_bitmap, 0), do: []

  def bits(<<b7::1, b6::1, b5::1, b4::1, b3::1, b2::1, b1::1, b0::1, rest::binary>>, n)
      when n >= 8,
      do: [b0, b1, b2, b3, b4, b5, b6, b7 | bits(rest, n - 8)]

  def bits(<<byte, _::binary>>, n), do: for(i <- 0..(n - 1), do: byte >>> i &&& 1)

  @doc false
  # Bit `i`.
  @spec at(binary(), non_neg_integer()) :: 0 | 1
  def at(bitmap, i), do: :binary.at(bitmap, div(i, 8)) >>> rem(i, 8) &&& 1

  @doc false
  # Bits `first` to `first + n - 1` as a bitmap of their own, from bit 0, its padding 0:
  # the bytes they lie in read as one little-endian integer, shifted down and masked.
  @spec slice(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  def slice(_bitmap, _first, 0), do: <<>>

  def slice(bitmap, first, n) do
    start = div(first, 8)
    size = min(bytes(rem(first, 8) + n), byte_size(bitmap) - start)
    <<x::little-size(^size * 8), _::binary>> = binary_part(bitmap, start, size)
    <<x >>> rem(first, 8) &&& (1 <<< n) - 1::little-size(bytes(n) * 8)>>
  end

  @doc false
  # The bits at `indexes` (any order, repeats allowed) of a bitmap of `n` bits, as a
  # bitmap of their own. One with every bit set gives one with every bit set, read from
  # nothing.
  @spec take(binary(), [non_neg_integer()], non_neg_integer() | nil) :: binary()
  def take(bitmap, indexes, n) when is_integer(n) do
    if all?(bitmap, n), do: ones(length(indexes)), else: take(bitmap, indexes, nil)
  end

  # By the native kernel where the kernels are loaded (spec/04 §4.1.1), the same bits.
  def take(bitmap, [_ | _] = indexes, nil) do
    if Macaw.Data.Native.active?() do
      case Macaw.Data.Native.scheduler(length(indexes)) do
        :normal -> Macaw.Data.Native.Kernels.take_bits(bitmap, indexes)
        :dirty -> Macaw.Data.Native.Kernels.take_bits_dirty(bitmap, indexes)
      end
    else
      pack(for(i <- indexes, do: at(bitmap, i)))
    end
  end

  def take(bitmap, indexes, nil), do: pack(for(i <- indexes, do: at(bitmap, i)))

  defp bytes(n), do: div(n + 7, 8)
end
