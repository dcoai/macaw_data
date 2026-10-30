defmodule Macaw.Data.Exact do
  @moduledoc false
  # An exact sum of numbers (spec/04 §5): integers added as integers, each float as the
  # integer count of 2^-1074 it is exactly, so any grouping and any order of the same
  # readings give the same state, and a float result is the exact sum rounded once, to
  # nearest, ties to even.

  import Bitwise

  @typedoc "An exact sum: the integers' sum, and the floats' in units of 2^-1074, or nil."
  @type t :: {integer(), integer() | nil}

  @doc false
  @spec zero() :: t()
  def zero, do: {0, nil}

  @doc false
  @spec add(t(), number()) :: t()
  def add({ints, floats}, n) when is_integer(n), do: {ints + n, floats}
  def add({ints, floats}, f) when is_float(f), do: {ints, (floats || 0) + units(f)}

  @doc false
  @spec merge(t(), t()) :: t()
  def merge({a, nil}, {b, nil}), do: {a + b, nil}
  def merge({a, fa}, {b, fb}), do: {a + b, (fa || 0) + (fb || 0)}

  @doc false
  # The sum's value: an integer when no float was added, else the exact sum rounded once.
  @spec value(t()) :: number()
  def value({ints, nil}), do: ints
  def value({ints, floats}), do: to_float((ints <<< 1074) + floats)

  # A float as the exact integer count of 2^-1074 it is.
  defp units(f) do
    <<sign::1, exp::11, frac::52>> = <<f::float>>
    m = if exp == 0, do: frac, else: frac ||| 1 <<< 52
    shift = if exp == 0, do: 0, else: exp - 1
    units = m <<< shift
    if sign == 1, do: -units, else: units
  end

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

  defp bit_length(a), do: length(Integer.digits(a, 2))
end
