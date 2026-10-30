defmodule Macaw.Data.Operations.FrameLoopLoadTest do
  @moduledoc """
  The frame's pinned reductions with the kernels (spec/04 §1.5.1) are a count, not a
  reading of the box: idle and with every scheduler saturated they agree (macaw_data#60).
  Not async, so the saturation shares the runner with no other test; nothing here asserts
  a time.
  """
  use ExUnit.Case, async: false

  alias Macaw.Data.Native
  alias Macaw.Data.Operations.Cache
  alias Macaw.Data.Test.{FrameLoop, Saturate, Work}

  # The per-chunk frame, its merges alone and its full recompute, counted with every
  # kernel call on a normal scheduler, each the least of three counts: the counter's
  # residue only ever adds (a count of 168,617 once read 169,597, idle; macaw_data#65, #66).
  defp counts(window, cache, warm) do
    count = fn fun ->
      Enum.min(
        for _ <- 1..3, do: elem(Work.reductions(fn -> Native.normal_schedulers(fun) end), 0)
      )
    end

    {count.(fn -> FrameLoop.cached(window, cache) end),
     count.(fn -> FrameLoop.cached(window, warm) end), count.(fn -> FrameLoop.full(window) end)}
  end

  @tag verifies: "operations-cache-native-frame-load"
  test "with the kernels, the frame's reductions are the same idle and with every scheduler saturated" do
    {_, cache, _} = FrameLoop.cached(FrameLoop.first(), Cache.new())
    window = FrameLoop.next(FrameLoop.first())
    {_, warm, _} = FrameLoop.cached(window, cache)

    idle = counts(window, cache, warm)
    busy = Saturate.start()
    on_exit(fn -> Saturate.stop(busy) end)
    saturated = counts(window, cache, warm)
    :ok = Saturate.stop(busy)

    if Native.loaded?() do
      # Within the counter's stated residue, 0.2 % (Macaw.Data.Test.Work): a dirty call
      # charged by its time moved these by up to 45 % (macaw_data#60).
      for {i, s} <- Enum.zip(Tuple.to_list(idle), Tuple.to_list(saturated)) do
        assert abs(s - i) <= div(i, 500), "idle #{inspect(idle)}, saturated #{inspect(saturated)}"
        assert s <= 250_000, "saturated #{inspect(saturated)}"
      end
    end
  end
end
