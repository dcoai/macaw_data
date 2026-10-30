defmodule Macaw.Data.Test.FrameLoop do
  @moduledoc """
  A synthetic frame loop modeled on visualize's (macaw_data#9 item 7, #26): a live
  source's 50k-row window, a new chunk's worth of readings appended each frame and the
  oldest trimmed, and a frame that runs a chart's data steps over it, either recomputed
  in full (`Operations.apply!/4`) or per chunk through a caller's cache
  (`Macaw.Data.Operations.Cache`), whose parts of unchanged chunks are reused.

  The steps are the frame loop's (visualize#971): `take n: 100` (the newest reading
  beside its history), `filter`, a `window` of the newest 30,000 seconds, `m4` and `lttb`
  of that window to a 1,000-pixel plot, and `sum` by series.
  """

  alias Macaw.Data.{Operations, Table}
  alias Macaw.Data.Operations.Cache

  @registry Operations.registry()

  @doc "The window's rows: 50,000."
  def rows, do: 50_000

  @doc "The rows a frame appends: one canonical chunk's worth."
  def step, do: Table.chunk_rows()

  # The source: one reading a second, chunks spanning a chunk's worth of seconds.
  @origin %{source: "frame-loop", resolution: 1, window: "t", span: 8192}

  @doc "The chains a frame runs, each a list of nodes over the window."
  def chains do
    [
      [%{op: "take", n: 100}],
      [%{op: "filter", field: "v", test: :gt, value: 0.0}],
      [
        %{op: "window", field: "t", from: [30_000, :second]},
        %{op: "m4", fields: ["t", "v"], width: 1000}
      ],
      [
        %{op: "window", field: "t", from: [30_000, :second]},
        %{op: "lttb", fields: ["t", "v"], n: 1000}
      ],
      [%{op: "sum", field: "v", by: "k"}]
    ]
  end

  @doc "The readings from second `from`, `n` of them: a sine with a deterministic wobble, four series."
  def readings(from, n) do
    ts = Enum.to_list(from..(from + n - 1)//1)

    Table.new!(
      [
        {"t", :number, ts},
        {"v", :number, Enum.map(ts, &(:math.sin(&1 / 500) * 100 + :math.sin(&1 * 7.3) * 5))},
        {"k", :category, Enum.map(ts, &Enum.at(~w(a b c d), rem(&1, 4)))}
      ],
      origin: @origin
    )
  end

  @doc "The window at frame 0: the readings from second 0."
  def first, do: readings(0, rows())

  @doc "The next frame's window: a chunk's worth of new readings appended, the oldest trimmed."
  def next(window) do
    [last | _] = Enum.reverse(Table.column(window, "t"))
    {:ok, grown} = Table.append(window, readings(last + 1, step()))
    Table.trim(grown, Table.size(grown) - rows())
  end

  @doc "A frame recomputed in full: every chain's output."
  def full(window), do: Enum.map(chains(), &Operations.apply!(@registry, &1, window))

  @doc """
  A frame recomputed per chunk: every chain's output through `cache`, and the cache
  pruned to what the frame's tables hold. Answers `{outputs, cache, counts}`, the counts
  of parts reused, updated and computed over every step.
  """
  def cached(window, cache) do
    zero = %{reused: 0, updated: 0, computed: 0}

    {outputs, {cache, counts, tables}} =
      Enum.map_reduce(chains(), {cache, zero, [window]}, fn chain, {cache, counts, tables} ->
        Enum.reduce(chain, {window, {cache, counts, tables}}, fn node,
                                                                 {input, {cache, counts, tables}} ->
          {:ok, [checked]} = Operations.validate(@registry, [node], %{})
          {:ok, module} = Operations.Registry.transform(@registry, checked["op"])
          {output, cache} = Cache.run(cache, module, checked, input, %{})
          counts = Map.merge(counts, cache.last, fn _k, a, b -> a + b end)
          {output, {cache, counts, [input | tables]}}
        end)
      end)

    {outputs, Cache.prune(cache, tables), counts}
  end
end
