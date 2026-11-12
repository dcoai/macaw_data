defmodule Macaw.Data.FinishChunkwiseCostTest do
  @moduledoc """
  What a warm chunk-wise reduction costs on visualize#998's loop (spec/01 §2.4,
  macaw_data#247): the chunks that changed and the merge, a pinned share of a whole
  reduction's reductions.
  """
  use ExUnit.Case, async: false

  alias Macaw.Data.Native
  alias Macaw.Data.Operations.Cache
  alias Macaw.Data.Source.{Description, Finish, Push, Request}
  alias Macaw.Data.Test.{LiveLoop, Work}

  @t0 ~U[2026-01-01 00:00:00Z]
  @description %Description{schema: LiveLoop.schema(), supports: []}

  # The holding of 50,000 readings one frame on: the cache warmed by the frame before it,
  # and the request for the newest 50,000 seconds, reduced by `reduce`.
  defp frame(reduce) do
    loop = LiveLoop.push(LiveLoop.start(nil))

    {:ok, _, cache} =
      Finish.finish(Push.held(loop.push), @description, request(loop, reduce), [], Cache.new())

    loop = LiveLoop.push(loop)
    {Push.held(loop.push), request(loop, reduce), cache}
  end

  defp request(loop, reduce) do
    now = DateTime.add(@t0, loop.next)
    Request.new!(window: [DateTime.add(now, -LiveLoop.rows()), now], reduce: reduce, now: now)
  end

  @tag verifies: "finish-chunkwise-cost"
  test "a warm reduction by m4 and lttb costs at most a third of a whole one, under pinned budgets" do
    for reduce <- [{:m4, 1_000}, {:lttb, 1_000}] do
      {held, request, cache} = frame(reduce)
      whole = fn -> Finish.finish(held, @description, request) end
      warm = fn -> Finish.finish(held, @description, request, [], cache) end

      {:ok, delivery} = whole.()
      {:ok, ^delivery, after_} = warm.()
      # The window's two edge chunks and the open one; every other part reused.
      assert after_.last.computed <= 3 * 3 and after_.last.reused >= 12

      {elixir_whole, _} = Work.reductions(whole, native: :elixir)
      {elixir_warm, _} = Work.reductions(warm, native: :elixir)
      assert elixir_warm <= 700_000, "#{inspect(reduce)}: warm #{elixir_warm} on the Elixir path"

      assert 3 * elixir_warm <= elixir_whole,
             "#{inspect(reduce)}: warm #{elixir_warm} of #{elixir_whole}"

      if Native.loaded?() do
        {kernels_whole, _} = Work.reductions(whole, native: :normal_schedulers)
        {kernels_warm, _} = Work.reductions(warm, native: :normal_schedulers)

        assert kernels_warm <= 250_000,
               "#{inspect(reduce)}: warm #{kernels_warm} with the kernels"

        assert 3 * kernels_warm <= kernels_whole,
               "#{inspect(reduce)}: #{kernels_warm} of #{kernels_whole}"
      end
    end
  end
end
