defmodule Macaw.Data.Test.LiveLoop do
  @moduledoc """
  visualize#998's real loop in this library's terms (macaw_data#132, #133): a push
  source's holding of `rows/0` readings one second apart (`t` a UTC time, the window
  field; `v` and `w` floats), one increment of `step/0` new readings a frame through
  `Macaw.Data.Source.Push`, the holding finished for the frame's window and budget by
  `Macaw.Data.Source.Finish` (the source supports neither), and the finished table drawn
  by `m4` and `lttb` of `t` and `v` to 1,000 through a caller's
  `Macaw.Data.Operations.Cache`. `Macaw.Data.Test.FrameLoop` is the operations' own loop
  over a number x with no source; this one is a viewer's, through the source layer.
  """

  alias Macaw.Data.{Delivery, Operations, Schema}
  alias Macaw.Data.Operations.{Cache, Registry}
  alias Macaw.Data.Source.{Description, Finish, Push, Request}

  @t0 ~U[2026-01-01 00:00:00Z]
  @registry Operations.registry()

  @schema Schema.new!(%{
            "t" => %{type: :time, window: true},
            "v" => %{type: :number},
            "w" => %{type: :number}
          })

  @doc "The readings a window holds: 50,000."
  def rows, do: 50_000

  @doc "The readings a frame pushes: 1,000."
  def step, do: 1_000

  @doc "The schema the source pushes."
  def schema, do: @schema

  @doc "The readings from second `from`, `n` of them, as rows."
  def readings(from, n) do
    for i <- from..(from + n - 1)//1 do
      %{
        "t" => DateTime.add(@t0, i),
        "v" => :math.sin(i / 40) * 10 + rem(i * 7919, 13),
        "w" => :math.cos(i / 97) * 5
      }
    end
  end

  @doc """
  The loop at frame 0: the holding a snapshot of `rows/0` readings, finished under
  `budget` (`nil` for none) by the reducer `reduce` names (`"lttb"`, Finish's default, or
  `"m4"`), with an empty cache. A map the other functions take and return.
  """
  def start(budget, reduce \\ "lttb") do
    ref = make_ref()

    snapshot =
      Delivery.new!(readings(0, rows()),
        schema: Schema.version(@schema),
        served: [position: 0, resolution: 1]
      )

    push = Push.new!(:live, ref)
    {:ok, push} = Push.receive(push, Push.schema_message(ref, @schema))
    {:ok, push} = Push.receive(push, Push.snapshot_message(ref, snapshot))

    %{
      push: drained(push),
      ref: ref,
      next: rows(),
      budget: budget,
      reduce: reduce,
      cache: Cache.new()
    }
  end

  @doc "The loop with one more frame's readings pushed and drained into the holding."
  def push(%{push: push, ref: ref, next: next} = loop) do
    increment =
      Delivery.new!(readings(next, step()),
        schema: Schema.version(@schema),
        served: [resolution: 1]
      )

    {:ok, push} = Push.receive(push, Push.increment_message(ref, push.position + 1, increment))
    %{loop | push: drained(push), next: next + step()}
  end

  @doc "The holding finished for the frame's window, the newest `rows/0` seconds, and its budget."
  def finished(%{push: push, next: next, budget: budget, reduce: reduce}) do
    now = DateTime.add(@t0, next)
    request = Request.new!(window: [DateTime.add(now, -rows()), now], budget: budget, now: now)

    Finish.finish!(Push.held(push), %Description{schema: @schema, supports: []}, request,
      reduce: reduce
    )
  end

  @doc """
  The frame drawn over `delivery` through `cache`: `{outputs, cache, counts}`, the m4 and
  lttb outputs, the cache holding this frame's parts, and the parts the two steps
  reused, updated and computed.
  """
  def draw(delivery, cache) do
    {outputs, {cache, counts}} =
      Enum.map_reduce(nodes(), {cache, %{reused: 0, updated: 0, computed: 0}}, fn {module, node},
                                                                                  {cache, counts} ->
        {output, cache} = Cache.run!(cache, module, node, delivery.rows, %{})
        {output, {cache, Map.merge(counts, cache.last, fn _k, a, b -> a + b end)}}
      end)

    {outputs, cache, counts}
  end

  @doc "One frame: pushed, finished and drawn, the cache pruned to it. `{loop, counts}`."
  def frame(loop) do
    loop = push(loop)
    delivery = finished(loop)
    {_outputs, cache, counts} = draw(delivery, loop.cache)
    {%{loop | cache: Cache.prune(cache, [delivery.rows])}, counts}
  end

  defp nodes do
    for {op, count} <- [{"m4", %{width: 1000}}, {"lttb", %{n: 1000}}] do
      {:ok, [node]} =
        Operations.validate(@registry, [Map.merge(%{op: op, fields: ["t", "v"]}, count)], %{})

      {:ok, module} = Registry.transform(@registry, op)
      {module, node}
    end
  end

  defp drained(push), do: Push.drain(push, fn _name -> {:error, :pushed} end)
end
