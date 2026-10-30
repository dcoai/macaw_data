defmodule Macaw.Data.Exact do
  @moduledoc false
  # An exact sum of numbers (spec/04 §5): integers added as integers, floats as the sums
  # of their signed mantissas by binary exponent, each sum exact, so any grouping and any
  # order of the same readings give the same state. A float result is the exact sum,
  # every exponent's mantissas counted in units of 2^-1074, rounded once, to nearest, ties
  # to even. Adding a float shifts nothing: its mantissa, at most 2^53, joins its
  # exponent's sum, and the units are counted once, when the value is read.

  import Bitwise

  @typedoc """
  An exact sum: the integers' sum, and the floats' signed mantissas summed by biased
  exponent, or nil when no float was added.
  """
  @type t :: {integer(), %{non_neg_integer() => integer()} | nil}

  @doc false
  @spec zero() :: t()
  def zero, do: {0, nil}

  @doc false
  @spec add(t(), number()) :: t()
  def add({ints, floats}, n) when is_integer(n), do: {ints + n, floats}

  def add({ints, floats}, f) when is_float(f) do
    <<sign::1, exp::11, frac::52>> = <<f::float>>
    m = if exp == 0, do: frac, else: frac ||| 1 <<< 52
    m = if sign == 1, do: -m, else: m

    case floats do
      %{^exp => sum} -> {ints, %{floats | exp => sum + m}}
      nil -> {ints, %{exp => m}}
      _ -> {ints, Map.put(floats, exp, m)}
    end
  end

  @doc false
  @spec merge(t(), t()) :: t()
  def merge({a, nil}, {b, nil}), do: {a + b, nil}

  def merge({a, fa}, {b, fb}),
    do: {a + b, Map.merge(fa || %{}, fb || %{}, fn _exp, x, y -> x + y end)}

  @doc false
  # The sum's value: an integer when no float was added, else the exact sum rounded once.
  @spec value(t()) :: number()
  def value({ints, nil}), do: ints
  def value({ints, floats}), do: to_float((ints <<< 1074) + units(floats))

  # The floats' sum as the exact integer count of 2^-1074 it is: a mantissa at biased
  # exponent `exp` counts 2^(exp - 1) units, a subnormal's (exponent 0) one.
  defp units(floats),
    do: Enum.reduce(floats, 0, fn {exp, m}, total -> total + (m <<< max(exp - 1, 0)) end)

  # The float nearest `n` × 2^-1074, ties to even.
  defp to_float(0), do: 0.0

  defp to_float(n) do
    sign = if n < 0, do: 1, else: 0
    a = abs(n)
    bits = bit_length(a)
    shift = max(bits - 53, 0)
    m = round_even(a, shift)
    {m, shift} = if m == 1 <<< 53, do: {m >>> 1, shift + 1}, else: {m, shift}

    cond do
      m < 1 <<< 52 ->
        <<f::float>> = <<sign::1, 0::11, m::52>>
        f

      shift + 1 > 2046 ->
        raise ArithmeticError, "the sum is beyond a float's range"

      true ->
        <<f::float>> = <<sign::1, shift + 1::11, m - (1 <<< 52)::52>>
        f
    end
  end

  defp round_even(a, 0), do: a

  defp round_even(a, shift) do
    q = a >>> shift
    r = a - (q <<< shift)
    half = 1 <<< (shift - 1)

    cond do
      r > half -> q + 1
      r < half -> q
      (q &&& 1) == 1 -> q + 1
      true -> q
    end
  end

  # The bits of a positive integer: its bytes', less the leading zeros of the first.
  defp bit_length(a) do
    <<top, _::binary>> = bytes = :binary.encode_unsigned(a)
    byte_size(bytes) * 8 - leading_zeros(top, 0)
  end

  defp leading_zeros(top, n) when top >= 128 >>> n, do: n
  defp leading_zeros(top, n), do: leading_zeros(top, n + 1)
end
