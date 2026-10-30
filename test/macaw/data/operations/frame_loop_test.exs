defmodule Macaw.Data.Operations.FrameLoopTest do
  @moduledoc """
  The synthetic frame loop at 50k rows (spec/04 §1.5; macaw_data#9 item 7, #26): a live
  window with one new chunk's worth of readings a frame, recomputed in full and per
  chunk. The default suite states the per-chunk recompute's cost as work, in reductions;
  the wall-clock run is `@tag :benchmark` (`mix test --only benchmark`) and gates
  nothing.
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.Native
  alias Macaw.Data.Operations.Cache
  alias Macaw.Data.Table
  alias Macaw.Data.Test.{FrameLoop, Work}

  # The window after `frames` frames, and the cache the per-chunk loop holds then.
  defp loop(frames) do
    Enum.reduce(1..frames//1, {FrameLoop.first(), nil}, fn _frame, {window, cache} ->
      {_, cache, _} = FrameLoop.cached(window, cache || Cache.new())
      {FrameLoop.next(window), cache}
    end)
  end

  describe "the frame loop" do
    @tag verifies: "operations-cache-frame"
    test "a per-chunk recompute equals the full one every frame and costs about its new chunk" do
      {window, cache} = loop(1)
      assert Table.size(window) == FrameLoop.rows()

      for _frame <- 1..3, reduce: {window, cache} do
        {window, cache} ->
          {outputs, next_cache, counts} = FrameLoop.cached(window, cache)
          full = FrameLoop.full(window)
          assert Enum.zip_with(outputs, full, &Table.equal?/2) |> Enum.all?()

          # Only the chunks the frame changed are computed: the last one written again and
          # the new one, for each of the frame's seven steps at most.
          assert counts.updated == 0
          assert counts.computed <= 2 * 7 + 2
          assert counts.reused >= counts.computed

          {FrameLoop.next(window), next_cache}
      end

      # In reductions, on the Elixir path (a kernel's work counts none, spec/04 §1.7): the
      # frame's changed chunks cost at most a full run over one chunk's readings, and the
      # whole frame (merges included) under half the full one.
      {_, warm, _} = FrameLoop.cached(window, cache)
      {full, _} = Work.reductions(fn -> Native.elixir(fn -> FrameLoop.full(window) end) end)

      {per_chunk, _} =
        Work.reductions(fn -> Native.elixir(fn -> FrameLoop.cached(window, cache) end) end)

      {merges, _} =
        Work.reductions(fn -> Native.elixir(fn -> FrameLoop.cached(window, warm) end) end)

      {one, _} =
        Work.reductions(fn ->
          Native.elixir(fn -> FrameLoop.full(FrameLoop.readings(0, FrameLoop.step())) end)
        end)

      assert per_chunk - merges <= one, "changed chunks #{per_chunk - merges}, one chunk #{one}"
      assert 2 * per_chunk <= full, "per chunk #{per_chunk}, full #{full}"
    end

    @tag verifies: "operations-cache-frame-budget"
    test "a per-chunk frame costs at most 1,100,000 reductions, its merges alone 600,000" do
      {window, cache} = loop(1)
      {_, warm, _} = FrameLoop.cached(window, cache)

      {per_chunk, _} =
        Work.reductions(fn -> Native.elixir(fn -> FrameLoop.cached(window, cache) end) end)

      {merges, _} =
        Work.reductions(fn -> Native.elixir(fn -> FrameLoop.cached(window, warm) end) end)

      assert per_chunk <= 1_100_000, "per chunk #{per_chunk}"
      assert merges <= 600_000, "merges alone #{merges}"
    end
  end

  describe "the wall clock" do
    defp next_of(window), do: FrameLoop.next(window)

    # A frame process's minimum heap that holds the frame loop's cache (about 824,000
    # words) with room for a frame's garbage (macaw_data#41).
    @heap_words 4_000_000

    # macaw_data#9 item 7: stated, not gated. `mix test --only benchmark`.
    @tag :benchmark
    @tag timeout: :infinity
    test "a frame at 50k rows, recomputed in full and per chunk" do
      frames = 10
      {window, cache} = loop(2)

      ms = fn fun ->
        {us, result} = :timer.tc(fun)
        {us / 1000, result}
      end

      run = fn ->
        {_, rows} =
          Enum.reduce(1..frames, {{window, cache}, []}, fn _frame, {{window, cache}, rows} ->
            {full_ms, _} = ms.(fn -> FrameLoop.full(window) end)

            {cached_ms, {_, next_cache, counts}} =
              ms.(fn -> FrameLoop.cached(window, cache) end)

            {merge_ms, _} = ms.(fn -> FrameLoop.cached(window, next_cache) end)
            row = {full_ms, cached_ms, merge_ms, counts.computed}
            {{FrameLoop.next(window), next_cache}, [row | rows]}
          end)

        rows
      end

      rows = run.()

      # The same frames in a process whose minimum heap holds the cache (spec/04 §1.5):
      # what a frame costs once its caller sizes the garbage collection it pays.
      me = self()
      :erlang.spawn_opt(fn -> send(me, {:sized, run.()}) end, min_heap_size: @heap_words)
      sized = receive do: ({:sized, rows} -> rows)

      median = fn values -> values |> Enum.sort() |> Enum.at(div(length(values), 2)) end

      # Each step by itself over the last frame's input: full, per chunk, merge alone.
      {last, _} =
        Enum.reduce(1..frames, {window, nil}, fn _, {w, _} -> {FrameLoop.next(w), nil} end)

      {_, held, _} = FrameLoop.cached(FrameLoop.first(), Cache.new())
      {_, held, _} = FrameLoop.cached(last, held)
      registry = Macaw.Data.Operations.registry()

      timed = fn fun ->
        for(_ <- 1..5, do: elem(:timer.tc(fun), 0))
        |> median.()
        |> Kernel./(1000)
        |> Float.round(2)
      end

      by_step =
        for chain <- FrameLoop.chains() do
          {:ok, checked} = Macaw.Data.Operations.validate(registry, chain, %{})
          input = Macaw.Data.Operations.apply!(registry, Enum.drop(chain, -1), next_of(last))
          before = Macaw.Data.Operations.apply!(registry, Enum.drop(chain, -1), last)
          node = List.last(checked)
          {:ok, module} = Macaw.Data.Operations.Registry.transform(registry, node["op"])
          {_, cold} = Cache.run(held, module, node, before, %{})
          {_, warm} = Cache.run(cold, module, node, input, %{})

          {node["op"], timed.(fn -> Macaw.Data.Operations.Step.run(module, node, input, %{}) end),
           timed.(fn -> Cache.run(cold, module, node, input, %{}) end),
           timed.(fn -> Cache.run(warm, module, node, input, %{}) end),
           timed.(fn ->
             Macaw.Data.Operations.Step.run(module, node, input, %{parallel: true})
           end)}
        end

      column = fn i -> median.(Enum.map(rows, &elem(&1, i))) end
      sized_column = fn i -> Float.round(median.(Enum.map(sized, &elem(&1, i))), 1) end

      steps =
        for chain <- FrameLoop.chains(), node <- chain do
          label = Enum.map_join(chain, " → ", & &1.op)
          {label, node}
        end

      IO.puts("""

      Frame loop, #{FrameLoop.rows()} rows, #{FrameLoop.step()} new rows a frame, median of #{frames} frames:
        full recompute:           #{Float.round(column.(0), 1)} ms
        per-chunk recompute:      #{Float.round(column.(1), 1)} ms (#{column.(3)} parts computed)
        of which merges alone:    #{Float.round(column.(2), 1)} ms (every part reused)
        steps: #{steps |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join("; ")}
        in a process with a #{@heap_words}-word minimum heap: full #{sized_column.(0)} ms, per chunk #{sized_column.(1)} ms, merges alone #{sized_column.(2)} ms

      By step (ms, median of 5): full · per chunk · merge alone · full, parallel
      #{Enum.map_join(by_step, "\n", fn {op, f, c, m, p} -> "  #{op}: #{f} · #{c} · #{m} · #{p}" end)}
      """)
    end
  end
end
