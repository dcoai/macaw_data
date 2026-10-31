defmodule Macaw.Data.Test.Gen do
  @moduledoc """
  Generators whose cost does not grow with the generation size (macaw_data#68).

  ExUnitProperties grows the generation size with the run index, so a property of 400
  runs reaches size 400. StreamData's `float(min: a, max: b)` draws an exponent up to
  the size and builds two to that power with a recursive bignum product, so one float
  costs 4,342 reductions at size 100 and 53,841 at size 400. A list of 400 rows, a float
  each, then costs 9.8 million to generate, and a property of 400 runs about a billion
  reductions, nearly all of it generation: a verdict that ExUnit's 60 s clock judged on a
  loaded host, in a test that asserts no time.

  `float/1` draws the same distribution with the exponent capped at 53, the bits of a
  double's significand: a fraction of more bits has no more to say in a double. A float
  then costs a few dozen reductions at any size (`Macaw.Data.Test.GenTest` holds it to a
  bound).
  """

  import Bitwise
  import StreamData, only: [bind: 2, integer: 1, map: 2, sized: 1]

  # A double's significand: 53 bits.
  @bits 53

  @doc """
  A float in `[min, max]`, as `StreamData.float(min: min, max: max)` draws one: a
  fraction `i / 2^e` of the way from `min` to `max`, its exponent `e` at most the size,
  here also at most 53. It shrinks towards `min`.

      iex> Enum.all?(Enum.take(Macaw.Data.Test.Gen.float(min: -1.0, max: 1.0), 50), &(&1 >= -1.0 and &1 <= 1.0))
      true
  """
  @spec float(min: float(), max: float()) :: StreamData.t(float())
  def float(min: min, max: max) when is_float(min) and is_float(max) and min <= max do
    sized(fn size ->
      bind(integer(0..min(size, @bits)), fn e ->
        map(integer(0..(1 <<< e)), fn i ->
          fraction = i / (1 <<< e)
          fraction * max + min * (1.0 - fraction)
        end)
      end)
    end)
  end
end
