defmodule Macaw.Data.FinishChunkwiseTest do
  @moduledoc """
  Finishing reduces a table chunk by chunk through the caller's `Operations.Cache`
  (spec/01 §2.4, macaw_data#247): the same answer as a whole reduction, at the cost of the
  chunks that changed.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table}
  alias Macaw.Data.Operations.Cache
  alias Macaw.Data.Source.{Description, Finish, Request}
  alias Macaw.Data.Table.Chunk

  @now ~U[2026-11-12 12:00:00Z]
  @t0 ~U[2026-01-01 00:00:00.000000Z]

  defp schema(kind, series?) do
    fields = %{
      "t" => %{type: kind, window: true},
      "v" => %{type: :number},
      "w" => %{type: :number}
    }

    Schema.new!(if series?, do: Map.put(fields, "s", %{type: :category}), else: fields)
  end

  defp at(t, :number), do: t
  defp at(t, :time), do: DateTime.add(@t0, t, :second)

  # A source's table of `n` readings a second apart from `from`, `v` with gaps.
  defp held(kind, series?, n, span, seed, from \\ 0) do
    ts = Enum.to_list(from..(from + n - 1)//1)

    columns =
      [
        {"t", kind, Enum.map(ts, &at(&1, kind))},
        {"v", :number,
         Enum.map(
           ts,
           &if(rem(&1 * seed, 23) == 0, do: nil, else: :math.sin((&1 + seed) / 11) * 10)
         )},
        {"w", :number, Enum.map(ts, &(rem(&1 * 7 + seed, 13) * 1.0))}
      ] ++
        if(series?,
          do: [{"s", :category, Enum.map(ts, &Enum.at(~w(a b c), rem(&1 + seed, 3)))}],
          else: []
        )

    span = if kind == :time, do: Duration.new!(second: span), else: span
    Table.new!(columns, origin: %{source: "s", resolution: 1, window: "t", span: span})
  end

  defp request(fields), do: Request.new!([now: @now] ++ fields)

  # The table's chunks by name and version, a view by its bounds too.
  defp named(table),
    do: for({c, f, n} <- Table.chunks(table), do: {Chunk.id(c), Chunk.version(c), f, n})

  @tag verifies: "finish-chunkwise"
  property "through a cache, finishing answers exactly what it answers whole" do
    check all(
            kind <- member_of([:number, :time]),
            series? <- boolean(),
            n <- integer(40..900),
            span <- member_of([25, 64, 300]),
            seed <- integer(1..500),
            reduce <- member_of([{:m4, 3}, {:m4, 20}, {:lttb, 3}, {:lttb, 30}, nil]),
            budget <- member_of([nil, 7, 60, 400]),
            cut <- member_of([nil, {5, 3}, {0, 2}]),
            max_runs: 150
          ) do
      s = schema(kind, series?)
      d = Delivery.new!(held(kind, series?, n, span, seed))
      description = Description.new!(schema: s)

      window =
        case cut do
          nil -> nil
          {a, b} -> [at(div(n * a, 37), kind), at(n - 1 - div(n, 7 * b), kind)]
        end

      budget = if reduce == nil and budget == nil, do: 60, else: budget
      r = request(reduce: reduce, budget: budget, window: window)
      whole = Finish.finish!(d, description, r)
      {:ok, cached, cache} = Finish.finish(d, description, r, [], Cache.new())

      assert Table.equal?(cached.rows, whole.rows)
      assert named(cached.rows) == named(whole.rows)
      assert cached.served == whole.served

      # A second call reuses every part it holds and computes none.
      {:ok, again, cache} = Finish.finish(d, description, r, [], cache)
      assert again == cached
      assert cache.last.computed == 0
    end
  end

  @tag verifies: "finish-chunkwise"
  test "reduce/5 through a cache: the whole answer, every part reused on a second call" do
    s = schema(:time, false)
    d = Delivery.new!(held(:time, false, 5_000, 1_000, 3))

    for reduce <- [{:m4, 40}, {:lttb, 100}] do
      r = request(reduce: reduce)
      {:ok, cached, cache} = Finish.reduce(d, s, r, Cache.new())
      assert cached == Finish.reduce!(d, s, r)
      assert cache.last.computed > 0 and cache.last.reused == 0

      {:ok, ^cached, cache} = Finish.reduce(d, s, r, cache)
      assert cache.last.computed == 0 and cache.last.reused > 0

      assert {^cached, _cache} = Finish.reduce!(d, s, r, cache)
    end
  end

  @tag verifies: "finish-chunkwise"
  test "a new chunk computes that chunk alone; a coarser level folds the held partials" do
    s = schema(:time, false)
    table = held(:time, false, 5_000, 1_000, 3)
    r = request(reduce: {:m4, 40})
    {:ok, _d, cache} = Finish.reduce(Delivery.new!(table), s, r, Cache.new())
    parts = cache.last.computed

    # One more chunk's readings: the open chunk and the new one are computed, the rest reused.
    {:ok, grown} = Table.append(table, held(:time, false, 1_000, 1_000, 3, 5_000))
    {:ok, d, cache} = Finish.reduce(Delivery.new!(grown), s, r, cache)
    assert d == Finish.reduce!(Delivery.new!(grown), s, r)
    # Each view holds its series and a partial a field: the changed views' three each are
    # computed, every other part reused, or folded where the wider extent's level is
    # coarser.
    assert cache.last.computed <= 2 * 3
    assert cache.last.reused + cache.last.updated >= parts - 2 * 3

    # A zoom out (a quarter of the columns) is a coarser level: folded, nothing computed.
    zoomed = request(reduce: {:m4, 10})
    {:ok, z, cache} = Finish.reduce(Delivery.new!(grown), s, zoomed, cache)
    assert z == Finish.reduce!(Delivery.new!(grown), s, zoomed)
    assert cache.last.computed == 0 and cache.last.updated > 0
  end

  @tag verifies: "finish-chunkwise"
  test "rows, another reducer and a window field of no time or number reduce whole, the cache unchanged" do
    s = schema(:number, false)
    rows = Delivery.new!(for t <- 1..500, do: %{"t" => t, "v" => :math.sin(t / 9), "w" => 1.0})
    r = request(reduce: {:m4, 10})
    cache = Cache.new()

    assert {:ok, reduced, ^cache} = Finish.reduce(rows, s, r, cache)
    assert reduced == Finish.reduce!(rows, s, r)

    table = Delivery.new!(held(:number, false, 500, 64, 1))
    hosted = Macaw.Data.Operations.registry!([Macaw.Data.Test.Ops])
    every = request(reduce: {"every", 20})
    assert {:ok, by_every, ^cache} = Finish.reduce(table, s, every, cache, hosted)
    assert by_every == Finish.reduce!(table, s, every, "lttb", hosted)

    places = Schema.new!(%{"p" => %{type: :point, window: true}, "v" => %{type: :number}})

    points =
      Delivery.new!(
        Table.new!([
          {"p", :point, for(i <- 1..100, do: {i, i})},
          {"v", :number, Enum.map(1..100, &(&1 * 1.0))}
        ])
      )

    assert {:ok, _, ^cache} = Finish.reduce(points, places, r, cache)

    assert Finish.reduce(table, s, request(reduce: {:nope, 3}), cache) ==
             {:error, [{[:reduce], {:unknown, :reducer, "nope"}}]}
  end
end
