defmodule Macaw.Data.Operations.LiveLoopTest do
  @moduledoc """
  visualize#998's loop through the source layer (spec/04 §1.5, spec/01 §2.4;
  macaw_data#132): a push holding of 50,000 readings, one 1,000-reading increment a frame,
  finished for its window and a budget, then `m4` and `lttb` through a caller's cache.
  The finish keeps the held chunks, so the cache reuses every unchanged chunk's parts.
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.Operations.Cache
  alias Macaw.Data.Table
  alias Macaw.Data.Test.LiveLoop

  # `frames` frames from the start, each one's counts, and the loop after them.
  defp run(loop, frames) do
    {counts, loop} =
      Enum.map_reduce(1..frames//1, loop, fn _frame, loop ->
        {loop, counts} = LiveLoop.frame(loop)
        {counts, loop}
      end)

    {loop, counts}
  end

  # The next frame drawn through the loop's cache and afresh, outputs compared.
  defp equal_to_full?(loop) do
    next = LiveLoop.push(loop)
    delivery = LiveLoop.finished(next)
    {cached, _cache, _counts} = LiveLoop.draw(delivery, loop.cache)
    {full, _cache, _counts} = LiveLoop.draw(delivery, Cache.new())
    Enum.zip_with(cached, full, &Table.equal?/2) |> Enum.all?()
  end

  @tag verifies: "operations-cache-live-loop"
  test "unreduced, every frame reuses at least 8 of its 14 parts, its outputs a full recompute's" do
    {loop, _warm} = run(LiveLoop.start(nil), 2)
    {loop, counts} = run(loop, 6)

    assert Table.size(LiveLoop.finished(loop).rows) == LiveLoop.rows()

    for %{reused: reused, computed: computed, updated: 0} <- counts do
      assert reused + computed == 14
      assert reused >= 8, "reused #{reused} of 14"
    end

    assert equal_to_full?(loop)
  end

  @tag verifies: "operations-cache-live-loop"
  test "reduced by m4 under a budget, the finished rows keep their chunks where the kept slots stay" do
    {loop, _warm} = run(LiveLoop.start(4_000, "m4"), 2)
    {loop, counts} = run(loop, 6)

    assert LiveLoop.finished(loop).served.reduced_by == :runtime
    assert Enum.sum(Enum.map(counts, & &1.reused)) >= 6 * 8
    assert equal_to_full?(loop)
  end
end
