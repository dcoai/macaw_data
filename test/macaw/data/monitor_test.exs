defmodule Macaw.Data.MonitorTest do
  @moduledoc """
  `Macaw.Data.Monitor` (spec/01 §6.3): the loop as a value. Pull sources are polled at
  their interval, pushes buffer and the next tick drains them, the schema arrives before
  its data, errors and staleness are states, and readers of one request are one pool,
  each reduced its own way. Ported from visualize's `Visualize.Feed.MonitorTest`, its
  slots now readers.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Monitor, Schema, Table}
  alias Macaw.Data.Source
  alias Macaw.Data.Source.{Finish, Request, Signal}
  alias Macaw.Data.Test.Scripted

  doctest Monitor

  @tick %{type: :number, window: true}
  @v1 Schema.new!(%{t: @tick, v: %{type: :number, unit: "ms", label: "Latency"}})
  @v2 Schema.new!(%{t: @tick, v: %{type: :number, unit: "s", label: "Latency"}})
  @now ~U[2026-11-01 00:00:00Z]

  defp rows(range), do: for(t <- range, do: %{t: t, v: rem(t * 7, 11)})

  defp size(%Delivery{} = delivery), do: length(Delivery.rows!(delivery))

  defp column(%Delivery{} = delivery, field),
    do: Enum.map(Delivery.rows!(delivery), &Table.get(&1, field))

  defp push_source(rows), do: Scripted.new(schema: @v1, supports: [:window, :push], rows: rows)

  # One source `:a` and its one reader `:a`.
  defp one(source, ask \\ [], opts \\ []),
    do: Monitor.new!(%{a: source}, %{a: [source: :a, ask: ask]}, opts)

  defp tick(monitor, now), do: Monitor.tick!(monitor, now: now, at: @now)

  describe "pull sources" do
    @tag verifies: "monitor-pull"
    test "a source is described and fetched at the first tick, and polled at its interval" do
      {source, agent} = Scripted.new(schema: @v1, rows: rows(1..5))
      monitor = one(source, [], every: 100)
      assert Monitor.status(monitor) == %{a: :loading}
      assert Monitor.deliveries(monitor) == %{}

      monitor = tick(monitor, 0)
      assert Monitor.status(monitor) == %{a: :live}
      assert %{a: %Delivery{rows: %Table{} = table}} = Monitor.deliveries(monitor)
      assert Table.size(table) == 5
      assert {Scripted.calls(agent, :describe), Scripted.calls(agent, :fetch)} == {1, 1}

      monitor = tick(monitor, 50)
      assert Scripted.calls(agent, :fetch) == 1

      Scripted.set(agent, rows: rows(1..7))
      monitor = tick(monitor, 100)
      assert Scripted.calls(agent, :fetch) == 2
      assert size(Monitor.deliveries(monitor).a) == 7
      assert Scripted.calls(agent, :describe) == 1
      assert Scripted.calls(agent, :subscribe) == 0
    end

    @tag verifies: "monitor-pull"
    test "the monitor finishes what the source does not, and a budget-honoring source is not reduced again" do
      {source, _} = Scripted.new(schema: @v1, rows: rows(1..1000))
      monitor = source |> one(window: [101, 900], budget: 50) |> tick(0)
      delivery = Monitor.deliveries(monitor).a
      assert size(delivery) == 50
      assert delivery.served.reduced_by == :runtime
      assert Enum.all?(column(delivery, :t), &(&1 in 101..900))

      answer = fn %Request{budget: budget} -> {rows(1..budget), [reduced_by: :source]} end
      {honors, _} = Scripted.new(schema: @v1, supports: [:budget], rows: answer)
      monitor = honors |> one(budget: 40) |> tick(0)
      assert %{served: %{reduced_by: :source}} = delivery = Monitor.deliveries(monitor).a
      assert size(delivery) == 40
    end

    @tag verifies: "monitor-pull"
    test "every request's now is tick's at:, the window and the budget asked" do
      {source, agent} = Scripted.new(schema: @v1, rows: rows(1..10))
      source |> one(window: [2, 8], budget: 3, latest: false) |> tick(0)

      [%Request{now: @now, window: [2, 8], budget: 3, subscription: nil}] =
        Scripted.requests(agent)
    end
  end

  describe "readers and pooling" do
    @tag verifies: "monitor-pool"
    test "readers of one request share one fetch at the largest budget, each reduced its own way" do
      test = self()

      answer = fn %Request{budget: budget} ->
        send(test, {:asked, budget})
        {rows(1..500), []}
      end

      {source, agent} = Scripted.new(schema: @v1, rows: answer)

      readers = %{
        small: [source: :a, ask: [window: [1, 400], budget: 10]],
        large: [source: :a, ask: [window: [1, 400], budget: 60, reduce: {:m4, 15}]],
        every: [source: :a, ask: [window: [1, 400], reduce: :none]],
        other: [source: :a, ask: [window: [100, 200], budget: 5]]
      }

      monitor = Monitor.new!(%{a: source}, readers) |> tick(0)

      # Two pools: one request but for budgets, and another window.
      assert Scripted.calls(agent, :fetch) == 2
      assert_received {:asked, nil}
      assert_received {:asked, 5}
      %{small: small, large: large, every: every, other: other} = Monitor.deliveries(monitor)
      assert size(small) == 10
      assert large.served.reduced_with == {"m4", 15}
      assert size(every) == 400
      assert size(other) == 5
      assert Monitor.status(monitor) == %{small: :live, large: :live, every: :live, other: :live}
    end

    @tag verifies: "monitor-pool"
    property "each pooled reader's delivery is the source's answer finished for that reader alone" do
      {:ok, d} = Source.describe(Signal.new!(:sine, [:t, :a, :b]), nil)

      check all(
              budgets <-
                list_of(one_of([constant(nil), integer(1..80)]), min_length: 1, max_length: 4),
              reducers <-
                list_of(member_of([nil, :none, {:m4, 6}, {:lttb, 20}]), length: length(budgets)),
              from <- integer(0..100),
              span <- integer(0..200)
            ) do
        signal = Signal.new!(:sine, [:t, :a, :b], tick: 300, window: 300)
        window = [from, from + span]

        readers =
          for {{budget, reduce}, i} <- Enum.with_index(Enum.zip(budgets, reducers)), into: %{} do
            {i, [source: :s, ask: [window: window, budget: budget, reduce: reduce]]}
          end

        monitor = Monitor.new!(%{s: signal}, readers) |> tick(0)
        deliveries = Monitor.deliveries(monitor)

        for {i, reader} <- readers do
          ask = reader[:ask]
          request = Request.new!(Keyword.put(ask, :now, @now))
          {:ok, fetched} = Source.fetch(signal, d, %{request | budget: nil, reduce: nil})
          {:ok, alone} = Finish.finish(fetched, d, request)
          got = deliveries[i]
          assert Table.equal?(got.rows, alone.rows), inspect({i, ask})
          assert Map.drop(got.served, [:position]) == Map.drop(alone.served, [:position])
        end
      end
    end

    @tag verifies: "monitor-pool"
    test "readers moving together keep their pool; one moving alone leaves it; an emptied pool is dropped" do
      fetched = fn %Request{window: [from, _to]} -> {rows(from..10), [window: [from, 10]]} end
      {source, agent} = push_source(fetched)

      readers = %{
        x: [source: :a, ask: [window: [3, nil], budget: 4]],
        y: [source: :a, ask: [window: [3, nil]]]
      }

      monitor = Monitor.new!(%{a: source}, readers) |> tick(0) |> Scripted.drain()
      assert {Scripted.calls(agent, :subscribe), Scripted.calls(agent, :fetch)} == {1, 1}

      # Both move within what is held: the pool is trimmed, nothing fetched.
      {:ok, monitor} =
        Monitor.ask(monitor, %{x: [window: [6, nil], budget: 4], y: [window: [6, nil]]})

      monitor = tick(monitor, 1)
      assert {Scripted.calls(agent, :subscribe), Scripted.calls(agent, :fetch)} == {1, 1}
      assert column(Monitor.deliveries(monitor).y, :t) == Enum.to_list(6..10)
      assert size(Monitor.deliveries(monitor).x) == 4

      # One moves alone: a pool of its own, subscribed and fetched.
      {:ok, monitor} = Monitor.ask(monitor, %{x: [window: [8, nil]]})
      monitor = tick(monitor, 2)
      assert {Scripted.calls(agent, :subscribe), Scripted.calls(agent, :fetch)} == {2, 2}
      assert column(Monitor.deliveries(monitor).x, :t) == Enum.to_list(8..10)
      assert column(Monitor.deliveries(monitor).y, :t) == Enum.to_list(6..10)

      # Rejoining: the emptied pool is unsubscribed and dropped.
      {:ok, monitor} = Monitor.ask(monitor, %{x: [window: [6, nil]]})
      assert Scripted.calls(agent, :unsubscribe) == 1
      monitor = tick(monitor, 3)
      assert column(Monitor.deliveries(monitor).x, :t) == Enum.to_list(6..10)
      assert Map.keys(Monitor.deliveries(monitor)) |> Enum.sort() == [:x, :y]

      # A window before what is held fetches again.
      {:ok, monitor} = Monitor.ask(monitor, %{x: [window: [1, nil]], y: [window: [1, nil]]})
      monitor = tick(monitor, 4)
      assert hd(column(Monitor.deliveries(monitor).y, :t)) == 1
      assert Scripted.calls(agent, :fetch) == 3
    end

    @tag verifies: "monitor-pool"
    test "a new budget refetches a pool whose source honors one, and refinishes any other" do
      answer = fn %Request{budget: budget} ->
        {rows(1..(budget || 100)), [reduced_by: :source]}
      end

      {honors, honors_agent} = Scripted.new(schema: @v1, supports: [:budget, :push], rows: answer)
      {plain, plain_agent} = Scripted.new(schema: @v1, supports: [:push], rows: rows(1..100))

      monitor =
        Monitor.new!(%{h: honors, p: plain}, %{
          h: [source: :h, ask: [budget: 40]],
          p: [source: :p, ask: [budget: 40]]
        })
        |> tick(0)

      calls = fn ->
        {Scripted.calls(honors_agent, :fetch), Scripted.calls(plain_agent, :fetch)}
      end

      assert calls.() == {1, 1}

      {:ok, monitor} = Monitor.budget(monitor, %{h: 40, p: 40})
      monitor = tick(monitor, 1)
      assert calls.() == {1, 1}

      {:ok, monitor} = Monitor.budget(monitor, %{h: 20, p: 20})
      monitor = tick(monitor, 2)
      assert calls.() == {2, 1}
      %{h: h, p: p} = Monitor.deliveries(monitor)
      assert {size(h), h.served.reduced_by} == {20, :source}
      assert {size(p), p.served.reduced_by} == {20, :runtime}

      {:ok, monitor} = Monitor.ask(monitor, %{p: [budget: 20, reduce: {:m4, 3}]})
      monitor = tick(monitor, 3)
      assert Monitor.deliveries(monitor).p.served.reduced_with == {"m4", 3}
      assert calls.() == {2, 1}
    end

    @tag verifies: "monitor-pool"
    test "an unchanged holding asked the same keeps every reader's delivery" do
      {source, _} = push_source(rows(1..50))

      monitor =
        Monitor.new!(%{a: source}, %{a: [source: :a, ask: [budget: 10]], b: [source: :a]})
        |> tick(0)
        |> Scripted.drain()
        |> tick(1)

      before = Monitor.deliveries(monitor)
      monitor = tick(monitor, 2)
      assert Monitor.deliveries(monitor) === before
    end
  end

  describe "the owner's calls" do
    @tag verifies: "monitor-faults"
    test "new/3, tick/2, ask/2 and budget/2 answer their faults, every one at once" do
      {source, _} = Scripted.new(schema: @v1)

      assert Monitor.new(%{a: 1, b: source}, %{r: [source: :c], s: [ask: [budget: 0]], t: 3},
               every: -1,
               stale_after: 0,
               nope: 1
             ) == {:error, [{[:nope], :unknown_key}]}

      assert Monitor.new(
               %{a: 1, b: source},
               %{r: [source: :c], s: [source: :b, ask: [budget: 0, x: 1]], t: 3},
               every: -1,
               stale_after: 0
             ) ==
               {:error,
                [
                  {[:every], {:type, :non_neg_integer}},
                  {[:stale_after], {:type, :pos_integer}},
                  {[:sources, :a], {:type, :source}},
                  {[:readers, :r, :source], {:unknown_source, :c}},
                  {[:readers, :s, :ask, :x], :unknown_key},
                  {[:readers, :t], {:type, :reader}}
                ]}

      assert Monitor.new([], %{}) == {:error, [{[:sources], {:type, :map}}]}
      assert Monitor.new(%{}, :x) == {:error, [{[:readers], {:type, :map}}]}

      assert {:error, [{[:readers, :s, :ask, :budget], {:type, :pos_integer}}]} =
               Monitor.new(%{b: source}, %{s: [source: :b, ask: [budget: 0]]})

      monitor = one(source)

      assert Monitor.tick(monitor, now: 1.5, at: ~D[2026-01-01]) ==
               {:error, [{[:now], {:type, :integer}}, {[:at], {:type, :datetime}}]}

      assert Monitor.tick(monitor, at: @now, now: 0, then: 1) ==
               {:error, [{[:then], :unknown_key}]}

      assert Monitor.ask(monitor, %{z: []}) == {:error, [{[:readers, :z], :unknown_reader}]}
      assert Monitor.ask(monitor, :x) == {:error, [{[:readers], {:type, :map}}]}

      assert Monitor.budget(monitor, %{a: -1}) ==
               {:error, [{[:readers, :a, :ask, :budget], {:type, :pos_integer}}]}

      assert Monitor.put_source(monitor, :a, 3) == {:error, [{[:sources, :a], {:type, :source}}]}

      assert Monitor.put_reader(monitor, :q, source: :none) ==
               {:error, [{[:readers, :q, :source], {:unknown_source, :none}}]}

      error = assert_raise Macaw.Data.Error, fn -> Monitor.new!(%{a: 1}, %{}) end
      assert error.reason == [{[:sources, :a], {:type, :source}}]
      refute error.message =~ "{:"
      error = assert_raise Macaw.Data.Error, fn -> Monitor.tick!(monitor, now: 0) end
      assert error.reason == [{[:at], {:type, :datetime}}]
      assert Monitor.format_error({:unknown_source, :c}) =~ ":c"
    end

    @tag verifies: "monitor-faults"
    test "a request the schema cannot answer is not asked: the pool is down until one that holds is set" do
      {source, agent} = Scripted.new(schema: @v1, rows: rows(1..5))
      monitor = source |> one(window: [~U[2026-01-01 00:00:00Z], nil]) |> tick(0)
      assert %{a: {:down, {:request, [{[:window], {:type, :number}}]}}} = Monitor.status(monitor)
      assert Scripted.calls(agent, :fetch) == 0

      {:ok, monitor} = Monitor.ask(monitor, %{a: [window: [1, 3]]})
      monitor = tick(monitor, 1)
      assert Monitor.status(monitor) == %{a: :live}
      assert column(Monitor.deliveries(monitor).a, :t) == [1, 2, 3]
    end

    @tag verifies: "monitor-push"
    test "put and remove sources and readers; stop unsubscribes every pool" do
      {source, agent} = push_source(rows(1..3))
      monitor = source |> one() |> tick(0) |> Scripted.drain()

      {:ok, monitor} = Monitor.put_reader(monitor, :b, source: :a, ask: [budget: 2])
      monitor = tick(monitor, 1)
      assert size(Monitor.deliveries(monitor).b) == 2
      assert Scripted.calls(agent, :subscribe) == 1

      monitor = Monitor.remove_reader(monitor, :b)
      assert Map.keys(Monitor.deliveries(monitor)) == [:a]
      assert Monitor.remove_reader(monitor, :missing) == monitor

      {other, _} = Scripted.new(schema: @v1, rows: rows(1..2))
      {:ok, monitor} = Monitor.put_source(monitor, :a, other)
      assert Scripted.calls(agent, :unsubscribe) == 1
      assert Monitor.status(monitor) == %{a: :loading}
      monitor = tick(monitor, 2)
      assert size(Monitor.deliveries(monitor).a) == 2

      gone = Monitor.remove_source(monitor, :a)
      assert {gone.sources, gone.readers, gone.pools} == {%{}, %{}, %{}}

      {pushing, pushing_agent} = push_source(rows(1..3))
      monitor = pushing |> one() |> tick(0)
      assert Monitor.stop(monitor) == :ok
      assert Scripted.calls(pushing_agent, :unsubscribe) == 1
    end
  end

  describe "errors and staleness are states" do
    @tag verifies: "monitor-states"
    test "a source that cannot describe is down, retried with backoff, and recovers" do
      {source, agent} = Scripted.new(schema: @v1, rows: rows(1..3), error: :unreachable)
      monitor = source |> one([], every: 100, backoff_max: 300) |> tick(0)
      assert Monitor.status(monitor) == %{a: {:down, :unreachable}}
      assert Monitor.deliveries(monitor) == %{}

      # Retried after 100, then 200, then at most 300.
      monitor =
        Enum.reduce(
          [{99, 1}, {100, 2}, {299, 2}, {300, 3}, {599, 3}, {600, 4}, {899, 4}, {900, 5}],
          monitor,
          fn {now, calls}, monitor ->
            monitor = tick(monitor, now)
            assert Scripted.calls(agent, :describe) == calls, inspect(now)
            monitor
          end
        )

      Scripted.set(agent, error: nil)
      monitor = monitor |> tick(10_000)
      assert Monitor.status(monitor) == %{a: :live}
    end

    @tag verifies: "monitor-states"
    test "a failed poll is down and backs off, the last delivery still handed out" do
      {source, agent} = Scripted.new(schema: @v1, rows: rows(1..3))
      monitor = source |> one([], every: 100) |> tick(0)
      Scripted.set(agent, error: :timeout)
      monitor = tick(monitor, 100)
      assert Monitor.status(monitor) == %{a: {:down, :timeout}}
      assert size(Monitor.deliveries(monitor).a) == 3
      # Retried after 100, then after 200.
      monitor = tick(monitor, 199)
      assert Scripted.calls(agent, :fetch) == 2
      monitor = tick(monitor, 200)
      assert Scripted.calls(agent, :fetch) == 3
      monitor = tick(monitor, 399)
      assert Scripted.calls(agent, :fetch) == 3
      Scripted.set(agent, error: nil)
      monitor = tick(monitor, 700)
      assert Monitor.status(monitor) == %{a: :live}
    end

    @tag verifies: "monitor-states"
    test "rows that do not pack are the source's fault before they are held" do
      good = rows(1..100)
      bad = List.replace_at(good, 49, %{t: 50, v: "x"})
      {source, agent} = Scripted.new(schema: @v1, rows: good)
      monitor = source |> one([budget: 10], every: 100) |> tick(0)
      Scripted.set(agent, rows: bad)
      monitor = tick(monitor, 100)
      assert %{a: {:down, {:table, _faults}}} = Monitor.status(monitor)
      assert size(Monitor.deliveries(monitor).a) == 10
      Scripted.set(agent, rows: good)
      monitor = tick(monitor, 200)
      assert Monitor.status(monitor) == %{a: :live}
    end

    @tag verifies: "monitor-states"
    test "a reader with no answer within stale_after is stale, and live again on the next" do
      {source, agent} = push_source(rows(1..3))
      monitor = source |> one([], stale_after: 100) |> tick(0)
      monitor = monitor |> Scripted.drain() |> tick(100)
      assert Monitor.status(monitor) == %{a: :live}
      monitor = tick(monitor, 101)
      assert Monitor.status(monitor) == %{a: :stale}

      Scripted.push(agent, self(), Delivery.new!(rows(4..4), schema: Schema.version(@v1)))
      monitor = monitor |> Scripted.drain() |> tick(102)
      assert Monitor.status(monitor) == %{a: :live}
    end
  end

  describe "push sources" do
    @tag verifies: "monitor-push"
    test "a push source is subscribed by the owner, whichever process ticks" do
      {source, agent} = push_source(rows(1..3))
      monitor = one(source)
      ticked = Task.async(fn -> tick(monitor, 0) end) |> Task.await()
      ref = Scripted.ref(agent)
      assert Scripted.calls(agent, :subscribe) == 1
      assert_received {:macaw_source, ^ref, {:schema, @v1}}
      assert Monitor.handle_message(ticked, :unrelated) == :ignore
    end

    @tag verifies: "monitor-push"
    test "pushes buffer and the next tick drains them in one merge, without a fetch" do
      {source, agent} = push_source(rows(1..3))
      monitor = source |> one() |> tick(0) |> Scripted.drain()

      for chunk <- [4..5, 6..6, 7..9] do
        Scripted.push(
          agent,
          self(),
          Delivery.new!(rows(chunk),
            served: [window: [chunk.first, chunk.last]],
            schema: Schema.version(@v1)
          )
        )
      end

      monitor = Scripted.drain(monitor)
      assert size(Monitor.deliveries(monitor).a) == 3
      monitor = tick(monitor, 10_000)
      assert column(Monitor.deliveries(monitor).a, :t) == Enum.to_list(1..9)
      assert Scripted.calls(agent, :fetch) == 1
      assert %Delivery{} = Monitor.held(monitor).a
    end

    @tag verifies: "monitor-push"
    test "a push overlapping a fetch adds nothing twice, and a gap is answered by a fetch" do
      {source, agent} = push_source(fn _ -> {rows(1..5), [window: [1, 5]]} end)
      monitor = source |> one() |> tick(0) |> Scripted.drain()
      version = Schema.version(@v1)

      Scripted.push(agent, self(), Delivery.new!(rows(6..7), schema: version))
      Scripted.push(agent, self(), Delivery.new!(rows(8..8), schema: version))
      Scripted.set(agent, rows: fn _ -> {rows(1..8), [window: [1, 8]]} end)
      monitor = monitor |> Monitor.refetch() |> tick(1)
      assert column(Monitor.deliveries(monitor).a, :t) == Enum.to_list(1..8)
      monitor = monitor |> Scripted.drain() |> tick(2)
      assert column(Monitor.deliveries(monitor).a, :t) == Enum.to_list(1..8)

      # Increment 3 is lost; 4 is held back, and the gap fetched.
      Agent.update(agent, &%{&1 | seq: 3})
      Scripted.push(agent, self(), Delivery.new!(rows(10..10), schema: version))
      monitor = monitor |> Scripted.drain() |> tick(3)
      assert Monitor.errors(monitor) == %{a: {:gap, 3, 3}}
      Scripted.set(agent, rows: fn _ -> {rows(1..10), [window: [1, 10]]} end)
      monitor = tick(monitor, 4)
      assert column(Monitor.deliveries(monitor).a, :t) == Enum.to_list(1..10)
      assert Scripted.calls(agent, :fetch) == 3
    end

    @tag verifies: "monitor-push"
    test "a pushed schema is used without asking, an unknown version asks once, an unresolvable one is an error" do
      {source, agent} = push_source(rows(1..3))
      monitor = source |> one() |> tick(0) |> Scripted.drain()
      Scripted.push_schema(agent, self(), @v2)
      Scripted.push(agent, self(), Delivery.new!(rows(4..4), schema: Schema.version(@v2)))
      monitor = monitor |> Scripted.drain() |> tick(1)
      assert Scripted.calls(agent, :describe) == 1
      assert Monitor.deliveries(monitor).a.schema == Schema.version(@v2)
      assert {:ok, @v2} = Schema.Cache.fetch(Monitor.cache(monitor), :a, Schema.version(@v2))

      {lost, lost_agent} = push_source(rows(1..3))
      monitor = lost |> one() |> tick(0) |> Scripted.drain()
      Scripted.set(lost_agent, schema: @v2)
      Scripted.push(lost_agent, self(), Delivery.new!(rows(4..4), schema: Schema.version(@v2)))
      monitor = monitor |> Scripted.drain() |> tick(1)
      assert Scripted.calls(lost_agent, :describe) == 2
      assert column(Monitor.deliveries(monitor).a, :t) == [1, 2, 3, 4]

      Scripted.push(lost_agent, self(), Delivery.new!(rows(5..5), schema: "0000"))
      monitor = monitor |> Scripted.drain() |> tick(2)
      assert %{a: {:schema_version, :a, "0000", _held}} = Monitor.errors(monitor)

      stale = {:macaw_source, make_ref(), {:increment, 1, Delivery.new!([])}}
      assert {:ok, ^monitor} = Monitor.handle_message(monitor, stale)
    end

    @tag verifies: "monitor-push"
    test "a sliding window drops the holding's chunks before it, and copies none" do
      span = 10

      {source, agent} =
        Scripted.new(schema: @v1, supports: [:window, :push], rows: rows(1..40), chunk_span: span)

      monitor = source |> one(window: [1, nil]) |> tick(0) |> Scripted.drain()
      before = Table.chunks(Monitor.held(monitor).a.rows)
      {:ok, monitor} = Monitor.ask(monitor, %{a: [window: [21, nil]]})
      monitor = tick(monitor, 1)
      after_ = Table.chunks(Monitor.held(monitor).a.rows)
      assert length(after_) < length(before)
      kept = MapSet.new(for {c, _, _} <- before, do: c.id)
      assert Enum.all?(after_, fn {c, _, _} -> c.id in kept end)
      assert hd(column(Monitor.deliveries(monitor).a, :t)) == 21
      assert Scripted.calls(agent, :fetch) == 1
    end
  end

  describe "cost" do
    defp reductions(fun) do
      {:reductions, before} = Process.info(self(), :reductions)
      fun.()
      {:reductions, after_} = Process.info(self(), :reductions)
      after_ - before
    end

    # A frame with nothing due and nothing pushed: every pool's holding unchanged, so the
    # tick finishes nothing (2,189 to 2,466 reductions, 0.06 to 0.09 ms, measured).
    # Pinned so a regression that refinishes every frame is seen (spec/01 §6.3).
    @tag verifies: "monitor-cost"
    test "a quiet tick over ten readers costs a pinned count of reductions" do
      signal = Signal.new!(:sine, [:t, :v], tick: 5_000, window: 5_000)
      readers = for i <- 1..10, into: %{}, do: {i, [source: :s, ask: [budget: 100 * i]]}
      monitor = Monitor.new!(%{s: signal}, readers, every: 60_000) |> tick(0)
      tick(monitor, 1)
      counted = reductions(fn -> tick(monitor, 2) end)
      assert counted < 5_000, "a quiet tick cost #{counted} reductions"
    end

    # Ten readers of one request pooled: one fetch and one finishing, then ten reductions
    # (1,267,466 reductions, 21 ms, measured), against each fetched and finished alone
    # (4,696,384 reductions, 72 ms): pinned at half.
    @tag verifies: "monitor-cost"
    test "ten pooled readers cost at most half of each fetched and finished alone" do
      signal = Signal.new!(:sine, [:t, :v], tick: 5_000, window: 5_000)
      readers = for i <- 1..10, into: %{}, do: {i, [source: :s, ask: [budget: 100 * i]]}
      monitor = Monitor.new!(%{s: signal}, readers)
      {:ok, d} = Source.describe(signal, nil)

      pooled = reductions(fn -> tick(monitor, 0) end)

      alone =
        reductions(fn ->
          for i <- 1..10 do
            request = Request.new!(now: @now, budget: 100 * i)
            {:ok, fetched} = Source.fetch(signal, d, request)
            {:ok, _} = Finish.finish(fetched, d, request)
          end
        end)

      assert pooled * 2 < alone, "pooled #{pooled} reductions, alone #{alone}"
    end
  end
end
