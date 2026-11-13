defmodule Macaw.Data.Test.GenTest do
  # The suite's own generators (macaw_data#68): their cost doesn't grow with the size.
  use ExUnit.Case, async: true

  alias Macaw.Data.Test.{Gen, Work}

  doctest Gen

  # 200 floats at `size`, each from a seed of its own, fixed, and the reductions generating
  # them cost.
  defp floats(generator, size) do
    Work.reductions(fn ->
      for seed <- 1..200 do
        [value] = generator |> StreamData.resize(size) |> StreamData.seeded(seed) |> Enum.take(1)
        value
      end
    end)
  end

  test "a float costs the same few reductions at every size, where StreamData's grows with it" do
    bounded = Gen.float(min: -100.0, max: 100.0)
    {small, _} = floats(bounded, 100)
    {large, values} = floats(bounded, 400)

    # Measured 24,807 for 200 at both sizes, the draw and the seeding: under 150 a float.
    assert small <= 200 * 150 and large <= 200 * 150, "size 100: #{small}, size 400: #{large}"
    assert Enum.all?(values, &(is_float(&1) and &1 >= -100.0 and &1 <= 100.0))
    assert length(Enum.uniq(values)) > 150

    # StreamData's own: 4,342 a float at size 100, 53,841 at 400.
    {theirs, _} = floats(StreamData.float(min: -100.0, max: 100.0), 400)
    assert theirs > 100 * large, "theirs #{theirs}, ours #{large}"
  end

  test "at a small size it draws the coarse fractions StreamData draws: the ends and halves" do
    {_, values} = floats(Gen.float(min: -1.0, max: 1.0), 1)
    assert Enum.sort(Enum.uniq(values)) == [-1.0, 0.0, 1.0]
  end

  # One draw from `generator` at size 100 and `seed`, in a process of its own: `:ok`, or
  # the exception it exited with.
  defp draw(generator, seed) do
    {pid, ref} =
      spawn_monitor(fn ->
        generator |> StreamData.resize(100) |> StreamData.seeded(seed) |> Enum.take(1)
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
      {:DOWN, ^ref, :process, ^pid, {exception, _stack}} -> exception
    end
  end

  # macaw_data#290: `Monitor.new/3`'s never-raise property drew its sources as
  # `map_of(member_of([:a, :b]), ..., max_length: 2)` and failed at seed 717492 with
  # `StreamData.TooManyDuplicatesError`, testing nothing. The same keys over 5,000 fixed
  # seeds: StreamData's gives up for some, ours for none.
  @tag :capture_log
  test "a map over two keys never gives up, where StreamData's map_of does" do
    keys = StreamData.member_of([:a, :b])
    theirs = StreamData.map_of(keys, StreamData.integer(), max_length: 2)
    ours = Gen.map_of(keys, StreamData.integer(), max_length: 2)

    gave_up = for seed <- 1..5_000, draw(theirs, seed) != :ok, do: draw(theirs, seed)
    assert gave_up != [] and Enum.all?(gave_up, &match?(%StreamData.TooManyDuplicatesError{}, &1))
    assert Enum.all?(1..5_000, &(draw(ours, &1) == :ok))

    maps = ours |> StreamData.resize(100) |> Enum.take(500)
    assert Enum.all?(maps, &(map_size(&1) <= 2 and Map.keys(&1) -- [:a, :b] == []))
    assert Enum.any?(maps, &(map_size(&1) == 2)) and Enum.any?(maps, &(map_size(&1) == 1))
  end
end
