defmodule Macaw.Data.Test.WorkTest do
  # The suite's counter of work (macaw_data#66): a count is exact, but for the one BIF its
  # moduledoc names, and that one's residue stays within the bound it states. Not async: a
  # module purged anywhere in the VM charges every process its literal-area check, and the
  # async tests compile and purge modules (#81); the sync tests run one at a time.
  use ExUnit.Case, async: false

  alias Macaw.Data.Test.Work

  doctest Work

  defp counts(fun, n), do: for(_ <- 1..n, do: elem(Work.reductions(fun), 0))

  test "a run over many time slices counts the same every time: its trace wakes no tracer" do
    # About 50 time slices a run, each ending in a schedule out and in that the trace
    # reports. Traced to a waiting tracer, a run like it read 4 or 8 more one time in 50
    # or so; over 20 runs of 50 slices some run did.
    loop = fn -> Enum.reduce(1..400_000, 0, &(&1 + &2)) end
    [count | _] = all = counts(loop, 20)
    assert Enum.uniq(all) == [count], "counts #{inspect(Enum.frequencies(all))}"
  end

  test "maps:from_list/1's charge moves from call to call, within a few reductions per hundred keys" do
    pairs = for i <- 1..1000, do: {{i, :key}, true}
    all = counts(fn -> :maps.from_list(pairs) end, 30)

    # Measured 627 to 701 for 1,000 keys, idle or loaded: the same map built every time,
    # charged differently. The bound stated: within 10 reductions per hundred keys.
    assert Enum.max(all) - Enum.min(all) <= 100, "counts #{inspect(Enum.frequencies(all))}"
    assert Enum.min(all) >= 500 and Enum.max(all) <= 800

    # At 32 keys a map is flat, built by no hashing, and its charge is exact.
    small = for i <- 1..32, do: {{i, :key}, true}
    [count | _] = flat = counts(fn -> :maps.from_list(small) end, 30)
    assert Enum.uniq(flat) == [count]
  end
end
