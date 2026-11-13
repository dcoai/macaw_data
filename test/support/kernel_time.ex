defmodule Macaw.Data.Test.KernelTime do
  @moduledoc """
  A kernel call's own time, for spec/04 §1.7's 1 ms rule (macaw_data#297).

  A NIF makes no reductions, so `Macaw.Data.Test.Work` has nothing to count for one, and
  a wall clock read around the call counts whatever else the host ran meanwhile: under
  `ci/stress.exs`, six suites on one box, the least of 21 wall timings of a `group_sum`
  that takes 288 µs idle reached 1,063 µs. Each timed kernel has a probe twin, `<kernel>_timed`,
  built under `native_probes: true`, that reads the CPU clock of the scheduler thread
  running it before and after the kernel and answers `{answer, ns}`. That clock stops
  while the OS runs another thread, so it is the kernel's own work.

  `least/1` calls the probe 5 times to warm it, then answers the probe's answer and the
  least ns of 21 calls: the least, since what is left (a cache another thread evicted, a
  busy SMT sibling) only ever adds.
  """

  @warm 5
  @runs 21

  @doc "`{answer, least_ns}` of `@runs` calls of a `<kernel>_timed` probe, after `@warm`."
  @spec least((-> {term(), non_neg_integer()})) :: {term(), non_neg_integer()}
  def least(timed) when is_function(timed, 0) do
    for _ <- 1..@warm, do: timed.()
    runs = for _ <- 1..@runs, do: timed.()
    {elem(hd(runs), 0), runs |> Enum.map(&elem(&1, 1)) |> Enum.min()}
  end
end
