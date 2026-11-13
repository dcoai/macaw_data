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

  import StreamData,
    only: [bind: 2, integer: 1, list_of: 2, map: 2, member_of: 1, sized: 1, tuple: 1]

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

  @doc """
  A map of `keys` to `values`, at most `max_length` entries, that never retries
  (macaw_data#290). `StreamData.map_of/3` asks for unique keys and gives up after 10
  duplicates in a row (`StreamData.TooManyDuplicatesError`), so over a short list of keys
  (`member_of([:a, :b])`, two keys for a map of two) a property fails now and then without
  testing anything. Here the pairs are drawn as a list and joined by `Map.new/1`: a
  repeated key keeps its last value, so a map smaller than drawn is generated too, which a
  reader of maps must take anyway. `min_length` is 0 or 1, the sizes a map of any key
  space can promise.

      iex> maps = Enum.take(Macaw.Data.Test.Gen.map_of(StreamData.member_of([:a, :b]), StreamData.integer(), max_length: 2), 200)
      iex> Enum.all?(maps, &(map_size(&1) <= 2 and Enum.all?(Map.keys(&1), fn k -> k in [:a, :b] end)))
      true
  """
  @spec map_of(StreamData.t(term()), StreamData.t(term()), keyword()) ::
          StreamData.t(map())
  def map_of(keys, values, opts) when is_list(opts),
    do:
      sized_map(
        keys,
        values,
        Keyword.get(opts, :min_length, 0),
        Keyword.fetch!(opts, :max_length)
      )

  defp sized_map(keys, values, min, max) when min in [0, 1] and is_integer(max) and max >= min,
    do: map(list_of(tuple({keys, values}), min_length: min, max_length: max), &Map.new/1)

  @doc """
  Two different members of `list`, in either order, drawn without retrying: the second
  is drawn from the rest.

      iex> pairs = Enum.take(Macaw.Data.Test.Gen.two_of([:a, :b]), 50)
      iex> Enum.all?(pairs, &(&1 in [[:a, :b], [:b, :a]]))
      true
  """
  @spec two_of([term(), ...]) :: StreamData.t([term()])
  def two_of([_, _ | _] = list) do
    bind(member_of(list), fn first -> map(member_of(List.delete(list, first)), &[first, &1]) end)
  end
end
