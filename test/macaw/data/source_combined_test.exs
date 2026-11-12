defmodule Macaw.Data.SourceCombinedTest do
  @moduledoc """
  One source over several, routed by window (spec/01 §10.2), ported from visualize's
  `Visualize.Feed.CombineTest`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Source, Table, Window}
  alias Macaw.Data.Source.{Combined, Conformance, Description, Push, Request, Signal}

  doctest Combined

  # A source answering what it is told, counting its calls: `rows:` a list, or a function of
  # the request answering `{rows, served}`; `error:` an error for every fetch; `described:`
  # the description's other facts.
  defmodule Scripted do
    @moduledoc false
    @behaviour Macaw.Data.Source
    defstruct [:schema, :agent, supports: [], described: [], rows: [], error: nil, ref: nil]

    def new(opts) do
      {:ok, agent} = Agent.start_link(fn -> %{fetch: 0, unsubscribe: 0} end)
      struct!(__MODULE__, [agent: agent, ref: make_ref()] ++ opts)
    end

    def calls(%__MODULE__{agent: agent}, call), do: Agent.get(agent, & &1[call])

    @impl true
    def describe(%__MODULE__{schema: schema, supports: supports} = s, _context),
      do: {:ok, struct!(%Description{schema: schema, supports: supports}, s.described)}

    @impl true
    def fetch(%__MODULE__{error: error} = s, _request) when error != nil do
      Agent.update(s.agent, &Map.update!(&1, :fetch, fn n -> n + 1 end))
      {:error, error}
    end

    def fetch(%__MODULE__{} = s, request) do
      Agent.update(s.agent, &Map.update!(&1, :fetch, fn n -> n + 1 end))

      {rows, served} =
        if is_function(s.rows, 1), do: s.rows.(request), else: {s.rows, []}

      Delivery.new(rows, served: served, schema: Schema.version(s.schema))
    end

    @impl true
    def subscribe(%__MODULE__{} = s, pid) do
      send(pid, Push.schema_message(s.ref, s.schema))
      {:ok, s.ref}
    end

    @impl true
    def unsubscribe(%__MODULE__{} = s, _ref) do
      Agent.update(s.agent, &Map.update!(&1, :unsubscribe, fn n -> n + 1 end))
      :ok
    end
  end

  # A part whose served position no delivery takes, built by hand.
  defmodule Lying do
    @moduledoc false
    @behaviour Macaw.Data.Source
    defstruct [:schema]

    @impl true
    def describe(%__MODULE__{schema: schema}, _context),
      do: {:ok, %Description{schema: schema, supports: [:window]}}

    @impl true
    def fetch(%__MODULE__{schema: schema}, _request) do
      delivery = Delivery.new!([%{t: 90, v: 90}], schema: Schema.version(schema))
      {:ok, %{delivery | served: %{delivery.served | window: [50, 100], position: "late"}}}
    end
  end

  @schema Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number}})
  @now ~U[2026-11-01 00:00:00Z]

  use Conformance,
    name: "Combined signals",
    source:
      Macaw.Data.Source.Combined.new!([
        Macaw.Data.Source.Signal.new!(:sine, [:t, :v], tick: 60, limit: 20),
        Macaw.Data.Source.Signal.new!(:sine, [:t, :v], tick: 60)
      ]),
    requests: [
      [],
      [window: [5, 60]],
      [window: [50, 55]],
      [window: [nil, 30]],
      [window: [45, nil]]
    ]

  defp describe(source), do: Source.describe(source, nil)

  defp column(%Delivery{} = delivery, field),
    do: Enum.map(Delivery.rows!(delivery), &Table.get(&1, field))

  defp fetch(source, window, now \\ @now) do
    with {:ok, description} <- describe(source),
         do: Source.fetch(source, description, Request.new!(window: window, now: now))
  end

  defp rows(range, source), do: for(t <- range, do: %{t: t, v: t, from: source})

  # A store that holds `range` and honors windows, as a history store does.
  defp store(range, source, schema \\ @schema) do
    answer = fn %Request{window: window} ->
      [from, to] = window || [nil, nil]
      held = rows(range, source) |> Window.trim(:t, [from, to])
      served = [Window.latest(from, range.first), Window.earliest(to, range.last)]
      {held, [window: served, capped: from != nil and from < range.first]}
    end

    Scripted.new(schema: schema, supports: [:window], rows: answer)
  end

  describe "routing by window" do
    @tag verifies: "combined-route"
    test "the freshest part serves what it holds and the next the rest" do
      live = store(50..100, :live)
      history = store(0..100, :history)
      {:ok, delivery} = fetch(Combined.new!([live, history]), [10, 100])

      assert column(delivery, :t) == Enum.to_list(10..100)

      assert Enum.all?(Delivery.rows!(delivery), fn row ->
               row.from == if(row.t >= 50, do: :live, else: :history)
             end)

      assert delivery.served.window == [10, 100]
      refute delivery.served.capped
      assert delivery.schema == Schema.version(@schema)
    end

    @tag verifies: "combined-route"
    test "a window the freshest part covers is not asked of the history" do
      live = store(50..100, :live)
      history = store(0..100, :history)
      {:ok, delivery} = fetch(Combined.new!([live, history]), [60, 70])
      assert column(delivery, :t) == Enum.to_list(60..70)
      assert Scripted.calls(history, :fetch) == 0
    end

    @tag verifies: "combined-route"
    test "the seam keeps the fresher part's row: a history that ignores the window gives only what is older" do
      live = store(50..100, :live)
      history = Scripted.new(schema: @schema, rows: rows(0..100, :history))
      {:ok, delivery} = fetch(Combined.new!([live, history]), [40, nil])
      ts = column(delivery, :t)
      assert ts == Enum.to_list(40..100)
      assert ts == Enum.uniq(ts)
    end

    @tag verifies: "combined-route"
    test "a window no part reaches is capped, and an open one takes what every part has" do
      combined = Combined.new!([store(50..100, :live), store(20..100, :history)])
      {:ok, capped} = fetch(combined, [0, 100])
      assert capped.served.capped
      assert capped.served.window == [20, 100]

      {:ok, all} = fetch(combined, nil)
      assert column(all, :t) == Enum.to_list(20..100)
    end

    @tag verifies: "combined-route"
    test "an error of any part is the combination's, and so is a served fact no delivery takes" do
      down = Scripted.new(schema: @schema, error: :down)
      assert fetch(Combined.new!([store(50..100, :live), down]), [0, 100]) == {:error, :down}

      assert {:error, {:combined_delivery, [{[:served, :position], {:type, :non_neg_integer}}]}} =
               fetch(Combined.new!([%Lying{schema: @schema}, store(0..100, :history)]), [0, 100])
    end

    @tag verifies: "combined-route"
    test "parts that deliver tables are one table of their chunks, copied nowhere" do
      live = Signal.new!(:discrete, [:t, :n], tick: 300, limit: 100)
      history = Signal.new!(:discrete, [:t, :n], tick: 300)
      {:ok, delivery} = fetch(Combined.new!([live, history]), [0, 300])
      assert %Table{} = delivery.rows
      assert Table.column(delivery.rows, "t") == Enum.to_list(0..300)

      {:ok, d} = Source.describe(history, nil)
      {:ok, whole} = Source.fetch(history, d, Request.new!(window: [0, 300], now: @now))
      assert Table.equal?(delivery.rows, whole.rows)

      held = MapSet.new(for {chunk, _, _} <- Table.chunks(whole.rows), do: chunk.id)
      assert Enum.all?(Table.chunks(delivery.rows), fn {chunk, _, _} -> chunk.id in held end)
    end
  end

  describe "one schema" do
    @tag verifies: "combined-schema"
    test "a part of another version but a compatible schema combines; the schema needs a window field" do
      other =
        Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number, label: "Other"}})

      history = Scripted.new(schema: other, rows: rows(0..100, :history))

      assert {:ok, %Description{schema: @schema, supports: [:window]}} =
               describe(Combined.new!([store(50..100, :live), history]))

      for schema <- [
            Schema.new!(%{v: %{type: :number}}),
            Schema.new!(%{t: %{type: :number}, v: %{type: :number}}),
            Schema.new!(%{p: %{type: :point, window: true}})
          ] do
        assert describe(Combined.new!([Scripted.new(schema: schema)])) ==
                 {:error, :combined_window_field}
      end
    end

    @tag verifies: "combined-push"
    test "a combination honors the window, and pushes through its first part" do
      pull = store(0..10, :a)
      assert {:ok, %Description{supports: [:window]}} = describe(Combined.new!([pull]))

      push = Scripted.new(schema: @schema, supports: [:window, :push])
      combined = Combined.new!([push, pull])
      assert {:ok, %Description{supports: [:window, :push]}} = describe(combined)

      assert {:ok, ref} = Source.subscribe(combined, self())
      assert ref == push.ref
      assert_received {:macaw_source, ^ref, {:schema, @schema}}
      assert Source.unsubscribe(combined, ref) == :ok
      assert Scripted.calls(push, :unsubscribe) == 1
      signal = Signal.new!(:discrete, [:t, :v])
      assert Source.subscribe(Combined.new!([signal]), self()) == {:error, :no_push}
    end

    @tag verifies: "combined-push"
    test "a combination pushing through its first part passes every check, its snapshot at that part's position" do
      alias Macaw.Data.Test.Sources.Broken
      live = Broken.new()
      combined = Combined.new!([live, Broken.new()])

      assert {:ok, %Description{supports: [:window, :push, :as_of]}} = describe(combined)

      # Its parts honor a budget, asked of none of them (macaw_data#273).
      assert [] ==
               Conformance.check(combined,
                 requests: [[], [window: [2, 10]], [window: [nil, 6]]],
                 budgets: [nil, 5],
                 push: fn _combined -> Broken.emit(live) end,
                 quiet: 30
               )

      {:ok, ref} = Source.subscribe(combined, self())
      Broken.emit(live)
      {:ok, description} = describe(combined)
      request = Request.new!(now: @now, window: [0, 30], subscription: ref)

      assert {:ok, %Delivery{served: %{position: 1}}} =
               Source.fetch(combined, description, request)

      assert {:ok, %Delivery{served: %{position: nil}}} =
               Source.fetch(combined, description, %{request | subscription: nil})
    end

    @tag verifies: "combined-request"
    test "every part is asked the window alone, as_of as it is, and finishing works over the union" do
      asking = fn name, range ->
        Scripted.new(
          schema: @schema,
          supports: [:window, :order, :budget, :as_of],
          rows: fn %Request{} = request ->
            send(self(), {:asked, name, request})
            [from, to] = request.window
            held = Window.trim(rows(range, name), :t, [from, to])
            {held, [window: [Window.latest(from, range.first), to]]}
          end
        )
      end

      combined = Combined.new!([asking.(:live, 50..100), asking.(:history, 0..100)])
      assert {:ok, %Description{supports: [:window, :as_of]} = description} = describe(combined)
      as_of = DateTime.add(@now, -3600)

      request =
        Request.new!(
          now: @now,
          window: [0, 100],
          budget: 10,
          order: [{:v, :desc}],
          reduce: {"lttb", 5},
          region: %{v: [0, 100]},
          as_of: as_of,
          params: %{},
          viewer: :ann
        )

      assert {:ok, delivery} = Source.fetch(combined, description, request)
      assert length(Delivery.rows!(delivery)) == 101
      assert delivery.served.reduced_by == nil

      for name <- [:live, :history] do
        assert_received {:asked, ^name, asked}

        assert %Request{
                 budget: nil,
                 order: [],
                 reduce: nil,
                 region: nil,
                 latest: false,
                 as_of: ^as_of,
                 viewer: :ann,
                 now: @now
               } = asked
      end

      # Finishing orders the union and keeps its head: the hundred's first ten.
      finish = %{request | region: nil, reduce: nil}
      assert {:ok, delivery} = Source.fetch(combined, description, finish)
      assert {:ok, finished} = Source.Finish.finish(delivery, description, finish)
      assert column(finished, :t) == Enum.to_list(100..91//-1)
      assert finished.served.ordered == :runtime
      assert finished.served.reduced_by == :runtime

      # A budget alone reduces the union once, never past the budget.
      budget = Request.new!(now: @now, window: [0, 100], budget: 10)
      assert {:ok, delivery} = Source.fetch(combined, description, budget)
      assert {:ok, reduced} = Source.Finish.finish(delivery, description, budget)
      assert length(Delivery.rows!(reduced)) == 10
      assert reduced.served.reduced_by == :runtime
    end

    @tag verifies: "combined-request"
    test "a combination names :as_of only when every part does" do
      as_of = Scripted.new(schema: @schema, supports: [:window, :as_of])
      now = Scripted.new(schema: @schema, supports: [:window, :budget])

      assert {:ok, %Description{supports: [:window, :as_of]}} = describe(Combined.new!([as_of]))

      for parts <- [[as_of, now], [now, as_of], [now]] do
        assert {:ok, %Description{supports: [:window]}} = describe(Combined.new!(parts))
      end
    end

    @tag verifies: "combined-faults"
    test "new/2 refuses what is no list of parts, a part that is no source, and options" do
      assert Combined.new([]) == {:error, [{[], {:type, :parts}}]}
      assert Combined.new(:x) == {:error, [{[], {:type, :parts}}]}
      assert Combined.new([store(0..1, :a) | :b]) == {:error, [{[], {:type, :parts}}]}

      assert Combined.new([store(0..1, :a), 3, {:x, nil}]) ==
               {:error, [{[1], {:type, :part}}, {[2], {:type, :part}}]}

      assert Combined.new([store(0..1, :a)], at: 1) == {:error, [{[:at], :unknown_key}]}
      assert {:ok, %Combined{}} = Combined.new([{store(0..1, :a), :context}])

      error = assert_raise Macaw.Data.Error, fn -> Combined.new!(Enum.take([1], 0)) end
      assert error.reason == [{[], {:type, :parts}}]
      refute error.message =~ "{:"
      assert describe(Combined.new!([%Request{now: @now}])) == {:error, :not_a_source}
    end
  end

  describe "compatible schemas" do
    @telemetry Schema.new!(%{
                 t: %{type: :time, label: "Time"},
                 value: %{type: :number, unit: "ms", quantity: :duration, label: "Load"},
                 panel: %{type: :category}
               })

    @metresis Schema.new!(%{
                "t" => %{type: :time},
                "value" => %{
                  type: :number,
                  unit: "ms",
                  quantity: :duration,
                  label: "metresis.load",
                  polarity: :lower_is_better
                },
                "panel" => %{type: :category, label: "panel"}
              })

    @t0 ~U[2026-10-13 00:00:00Z]

    defp at(s), do: DateTime.add(@t0, s, :second)

    defp timed(schema, seconds, field, row, supports \\ [:window]) do
      answer = fn %Request{window: window} ->
        [from, to] = window || [nil, nil]
        held = seconds |> Enum.map(row) |> Window.trim(field, [from, to])
        {held, [window: [Window.latest(from, at(seconds.first)), to || at(seconds.last)]]}
      end

      Scripted.new(schema: schema, supports: supports, rows: answer)
    end

    defp telemetry(supports \\ [:window]),
      do: timed(@telemetry, 60..120, :t, &%{t: at(&1), value: &1 * 1.0, panel: "a"}, supports)

    defp history(schema, row), do: timed(schema, 0..120, "t", row)

    @tag verifies: "combined-schema"
    test "a telemetry and a store's history combine, every row in the first's names" do
      combined =
        Combined.new!([
          telemetry(),
          history(@metresis, &%{"t" => at(&1), "value" => &1 * 1.0, "panel" => "a"})
        ])

      assert {:ok, %Description{schema: @telemetry}} = describe(combined)
      {:ok, delivery} = fetch(combined, [at(0), at(120)])
      assert delivery.schema == Schema.version(@telemetry)
      assert delivery.served.window == [at(0), at(120)]
      assert column(delivery, :t) == Enum.map(0..120, &at/1)

      assert Enum.map(Delivery.rows!(delivery), &Map.drop(&1, [:t])) ==
               Enum.map(0..120, &%{value: &1 * 1.0, panel: "a"})
    end

    @tag verifies: "combined-schema"
    test "a history in s behind live data in ms is converted; extra fields dropped, an undescribed column left" do
      seconds =
        Schema.new!(%{
          "t" => %{type: :time},
          "value" => %{type: :number, unit: "s"},
          "panel" => %{type: :category},
          "host" => %{type: :category}
        })

      history =
        history(seconds, fn s ->
          %{"t" => at(s), "value" => s / 1000, "panel" => "a", "host" => "h", "from" => :h}
        end)

      {:ok, delivery} = fetch(Combined.new!([telemetry(), history]), [at(0), at(120)])

      assert column(delivery, :value) ==
               Enum.map(0..59, &Macaw.Data.Unit.convert!(&1 / 1000, "s", "ms")) ++
                 Enum.map(60..120, &(&1 * 1.0))

      assert hd(Delivery.rows!(delivery)) == %{"from" => :h, t: at(0), value: 0.0, panel: "a"}
      assert List.last(Delivery.rows!(delivery)) == %{t: at(120), value: 120.0, panel: "a"}
    end

    @tag verifies: "combined-schema"
    test "every incompatibility is reported with the later part's position" do
      no_panel = Schema.new!(%{"t" => %{type: :time}, "value" => %{type: :number, unit: "ms"}})

      typed =
        Schema.new!(%{t: %{type: :time}, value: %{type: :category}, panel: %{type: :category}})

      bytes =
        Schema.new!(%{
          t: %{type: :time},
          value: %{type: :number, unit: "By"},
          panel: %{type: :text}
        })

      other_window =
        Schema.new!(%{"t" => %{type: :number}, "v" => %{type: :number, window: true}})

      parts = [telemetry() | for(s <- [no_panel, typed, bytes], do: Scripted.new(schema: s))]

      assert describe(Combined.new!(parts)) ==
               {:error,
                {:combined_schema,
                 [
                   {1, "panel", :missing},
                   {2, "value", {:type, :number, :category}},
                   {3, "panel", {:type, :category, :text}},
                   {3, "value", {:unit, "ms", "By"}}
                 ]}}

      assert fetch(Combined.new!(Enum.take(parts, 2)), [at(0), nil]) ==
               {:error, {:combined_schema, [{1, "panel", :missing}]}}

      assert describe(Combined.new!([store(50..100, :l), Scripted.new(schema: other_window)])) ==
               {:error, {:combined_schema, [{1, "t", {:window, "t", "v"}}]}}

      assert Combined.format_error({:combined_schema, [{1, "panel", :missing}]}) =~ "part 1"
      assert Combined.format_error(:combined_window_field) =~ "window field"
    end

    @tag verifies: "combined-schema"
    test "a numeric window field in other units has its window converted both ways" do
      ms = Schema.new!(%{t: %{type: :number, window: true, unit: "ms"}, v: %{type: :number}})

      s =
        Schema.new!(%{"t" => %{type: :number, window: true, unit: "s"}, "v" => %{type: :number}})

      live =
        Scripted.new(
          schema: ms,
          supports: [:window],
          rows: fn %Request{window: [from, _to]} ->
            held = for t <- 50_000..100_000//1000, t >= from, do: %{t: t, v: 1}
            {held, [window: [max(from, 50_000), 100_000]]}
          end
        )

      history =
        Scripted.new(
          schema: s,
          supports: [:window],
          rows: fn %Request{window: [from, to]} ->
            held = for t <- 0..100, t >= from, t <= to, do: %{"t" => t, "v" => 2}
            {held, [window: [max(from, 0), to]]}
          end
        )

      {:ok, delivery} = fetch(Combined.new!([live, history]), [10_000, 100_000])
      assert Scripted.calls(history, :fetch) == 1

      assert column(delivery, :t) ==
               Enum.map(10..49, &(&1 * 1000.0)) ++ Enum.to_list(50_000..100_000//1000)

      assert delivery.served.window == [10_000.0, 100_000]
      refute delivery.served.capped
    end

    @tag verifies: "combined-schema"
    test "a later part's rows that cannot be read as the first's are the combination's fault" do
      unnamed =
        Schema.new!(%{
          "t" => %{type: :time},
          "value" => %{type: :number, unit: "s"},
          "panel" => %{type: :category}
        })

      tuples = Scripted.new(schema: unnamed, rows: [{at(1), 1, "a"}])

      assert {:error, {:combined_part, 1, _faults}} =
               fetch(Combined.new!([telemetry(), tuples]), [at(0), at(120)])
    end
  end

  # The kinds of time a `:time` window holds, on one instant scale.
  defp instant(:datetime, s), do: DateTime.add(@t0, s, :second)
  defp instant(:naive, s), do: NaiveDateTime.add(~N[2026-10-13 00:00:00], s, :second)
  defp instant(:date, s), do: Date.add(~D[2026-10-13], s)

  @tag verifies: "combined-route"
  property "the union is each time once, the fresher part's at every seam, over gaps, open bounds and every kind of time" do
    check all(
            kind <- member_of([:number, :datetime, :naive, :date]),
            cuts <- uniq_list_of(integer(1..59), min_length: 1, max_length: 3),
            gaps <- list_of(integer(0..60), max_length: 6),
            from <- one_of([constant(nil), integer(0..60)]),
            span <- integer(0..60),
            open_to <- boolean()
          ) do
      time = if kind == :number, do: & &1, else: &instant(kind, &1)
      type = if kind == :number, do: :number, else: :time
      schema = Schema.new!(%{t: %{type: type, window: true}, v: %{type: :number}})
      starts = Enum.sort(cuts, :desc) ++ [0]
      held = Enum.to_list(0..60) -- gaps

      # Part i (freshest first) holds the times from its start on.
      parts =
        for {start, i} <- Enum.with_index(starts) do
          Scripted.new(
            schema: schema,
            supports: [:window],
            rows: fn %Request{window: window} ->
              [f, t] = window || [nil, nil]

              rows =
                for s <- held, s >= start, do: %{t: time.(s), v: i}

              rows = Window.trim(rows, :t, [f, t])
              {rows, [window: [Window.latest(f, time.(start)), t || time.(60)]]}
            end
          )
        end

      to = if open_to, do: nil, else: (from || 0) + span
      window = [from && time.(from), to && time.(to)]
      {:ok, delivery} = fetch(Combined.new!(parts), window)
      rows = Delivery.rows!(delivery)

      expected = for s <- held, (from == nil or s >= from) and (to == nil or s <= to), do: s
      assert Enum.map(rows, &Table.get(&1, :t)) == Enum.map(expected, time)

      # Each row comes from the freshest part holding its time.
      for row <- rows do
        s = Enum.find(0..60, &(time.(&1) == Table.get(row, :t)))
        assert Table.get(row, :v) == Enum.find_index(starts, &(s >= &1))
      end
    end
  end

  describe "what the combination states of its parts' answers" do
    # A store holding `range`, honoring windows, saying `said` of every answer.
    defp saying(range, name, said) do
      answer = fn %Request{window: window} ->
        [from, to] = window || [nil, nil]
        held = rows(range, name) |> Window.trim(:t, [from, to])
        served = [Window.latest(from, range.first), Window.earliest(to, range.last)]
        {held, [window: served, capped: from != nil and from < range.first] ++ said}
      end

      Scripted.new(schema: @schema, supports: [:window], rows: answer)
    end

    @tag verifies: "combined-served"
    test "a stale part, the freshest or the history, makes the combination stale; with none it is fresh" do
      fresh = fetch(Combined.new!([store(50..100, :live), store(0..100, :history)]), [0, 100])
      assert {:ok, %Delivery{served: %{stale: false, note: nil}}} = fresh

      live = saying(50..100, :live, stale: true, note: "upstream down")
      assert {:ok, d} = fetch(Combined.new!([live, store(0..100, :history)]), [0, 100])
      assert {d.served.stale, d.served.note} == {true, "upstream down"}

      # A history that answered stale, rows or none, is the combination's too.
      history = saying(0..100, :history, stale: true)

      assert {:ok, %{served: %{stale: true}}} =
               fetch(Combined.new!([store(50..100, :live), history]), [0, 100])

      empty = saying(200..300, :history, stale: true)

      assert {:ok, %{served: %{stale: true}}} =
               fetch(Combined.new!([store(50..100, :live), empty]), [0, 100])

      # A part the window never reaches is not asked, and says nothing of the answer.
      assert {:ok, %{served: %{stale: false}}} =
               fetch(Combined.new!([store(0..100, :live), history]), [10, 100])
    end

    @tag verifies: "combined-served"
    property "the combination is stale exactly when a part it asked answered stale" do
      check all(flags <- list_of(boolean(), min_length: 1, max_length: 5)) do
        # Part i holds from 100 - 20 * (i + 1), so every part is asked [0, 100].
        parts =
          flags
          |> Enum.with_index()
          |> Enum.map(fn {stale, i} -> saying((80 - 20 * i)..100, i, stale: stale) end)

        {:ok, delivery} = fetch(Combined.new!(parts), [0, 100])
        assert delivery.served.stale == Enum.any?(flags)
        assert delivery.served.capped == length(flags) < 5
      end
    end

    @tag verifies: "combined-served"
    test "notes are the parts', each once, the freshest first; params are the first part's" do
      live = saying(50..100, :live, note: "from memory", params: %{"floor" => 1})
      middle = saying(30..100, :middle, note: "from memory")
      history = saying(0..100, :history, note: "coarsened from raw", params: %{"floor" => 2})

      assert {:ok, d} = fetch(Combined.new!([live, middle, history]), [0, 100])
      assert d.served.note == "from memory; coarsened from raw"
      assert d.served.params == %{"floor" => 1}

      # A part's fact no delivery takes is the combination's fault, not dropped.
      broken = Macaw.Data.Test.Sources.Broken.new(:stale_not_boolean)

      assert {:error, {:combined_delivery, [{[:served, :stale], {:type, :boolean}}]}} =
               fetch(Combined.new!([broken]), [0, 10])
    end

    @tag verifies: "combined-served"
    test "the oldest part asked is capped when it says it cut, though it reaches the window's start" do
      cut = saying(0..100, :history, capped: true)
      assert {:ok, d} = fetch(Combined.new!([store(50..100, :live), cut]), [0, 100])
      assert d.served.capped

      # A fresher part's cut was handed on to the next, which covered it.
      live = saying(50..100, :live, capped: true)

      assert {:ok, %{served: %{capped: false}}} =
               fetch(Combined.new!([live, store(0..100, :history)]), [0, 100])
    end

    @tag verifies: "combined-served"
    test "complete_until is the least claim of the parts asked, none with any none, and the first's for a subscription" do
      live = saying(50..100, :live, complete_until: 90)
      history = saying(0..100, :history, complete_until: 40)
      assert {:ok, d} = fetch(Combined.new!([live, history]), [0, 100])
      assert d.served.complete_until == 40

      unclaimed = store(0..100, :history)

      assert {:ok, %{served: %{complete_until: nil}}} =
               fetch(Combined.new!([live, unclaimed]), [0, 100])

      # A window the first part covers asks it alone, and its claim is the union's.
      assert {:ok, %{served: %{complete_until: 90}}} =
               fetch(Combined.new!([live, history]), [60, 100])

      # A snapshot for a subscription claims what the subscription does: the first part's.
      subscribed = saying(50..100, :live, complete_until: 90, position: 3)

      assert {:ok, %{served: %{complete_until: 90, position: 3}}} =
               fetch(Combined.new!([subscribed, history]), [0, 100])

      # A later part's claim, in its own units, is read in the first's.
      ms = Schema.new!(%{t: %{type: :number, window: true, unit: "ms"}, v: %{type: :number}})
      s = Schema.new!(%{t: %{type: :number, window: true, unit: "s"}, v: %{type: :number}})

      fast = fn %Request{window: [from, _to]} ->
        {for(t <- 50_000..100_000//1000, t >= from, do: %{t: t, v: 1}),
         [window: [max(from, 50_000), 100_000], complete_until: 90_000]}
      end

      slow = fn %Request{window: [from, to]} ->
        {for(t <- 0..100, t >= from, t <= to, do: %{t: t, v: 2}),
         [window: [max(from, 0), to], complete_until: 40]}
      end

      parts = [
        Scripted.new(schema: ms, supports: [:window], rows: fast),
        Scripted.new(schema: s, supports: [:window], rows: slow)
      ]

      assert {:ok, d} = fetch(Combined.new!(parts), [10_000, 100_000])
      assert d.served.complete_until == 40_000.0
    end

    @tag verifies: "combined-served"
    test "a budget, a reducer, an order and an origin are no part's to state" do
      reducing =
        saying(50..100, :live,
          reduced_by: :source,
          reduced_with: {"m4", 2},
          ordered: :source
        )

      assert {:ok, d} = fetch(Combined.new!([reducing, store(0..100, :history)]), [0, 100])

      assert {d.served.reduced_by, d.served.reduced_with, d.served.ordered, d.origin} ==
               {nil, nil, nil, nil}
    end

    @tag verifies: "combined-served"
    test "a stale part passes the kit's every check, and its staleness is the combination's" do
      alias Macaw.Data.Test.Sources.Broken
      live = Broken.new(:stale)
      combined = Combined.new!([live, Broken.new()])
      requests = [[], [window: [2, 10]], [window: [nil, 6]]]

      assert [] ==
               Conformance.check(combined,
                 requests: requests,
                 budgets: [nil, 5],
                 push: fn _combined -> Broken.emit(live) end,
                 quiet: 30
               )

      {:ok, description} = describe(combined)

      for ask <- requests do
        request = Request.new!([now: @now] ++ ask)

        assert {:ok, %Delivery{served: %{stale: true}}} =
                 Source.fetch(combined, description, request)
      end
    end
  end

  describe "what the combination is, from its parts" do
    @floor %{"floor" => %{type: :number, default: nil}}

    # A store holding 0..100 from `first`, honoring windows and a `floor` on `v`, telling
    # the test each parameter map it is asked.
    defp floored(first, name, described) do
      test = self()

      answer = fn %Request{window: window, params: params} ->
        send(test, {:asked, name, params})
        [from, to] = window || [nil, nil]
        floor = params["floor"]

        held =
          rows(first..100, name)
          |> Window.trim(:t, [from, to])
          |> Enum.filter(&(floor == nil or &1.v >= floor))

        {held, [window: [Window.latest(from, first), Window.earliest(to, 100)]]}
      end

      Scripted.new(schema: @schema, supports: [:window], rows: answer, described: described)
    end

    @tag verifies: "combined-description"
    test "the first part's parameters are the combination's, and every part is asked a value given" do
      combined =
        Combined.new!([floored(50, :live, params: @floor), floored(0, :history, params: @floor)])

      assert {:ok, %Description{params: @floor} = description} = describe(combined)
      request = Request.new!(window: [0, 100], params: %{"floor" => 20}, now: @now)
      assert {:ok, delivery} = Source.fetch(combined, description, request)
      assert column(delivery, :t) == Enum.to_list(20..100)
      assert_received {:asked, :live, %{"floor" => 20}}
      assert_received {:asked, :history, %{"floor" => 20}}

      # Not given, the first's default reaches every part.
      assert {:ok, _} = Source.fetch(combined, description, Request.new!(now: @now))
      assert_received {:asked, :history, %{"floor" => nil}}

      # A later part's own other parameter is not the combination's.
      extra = Map.put(@floor, "zoom", %{type: :number, default: 1})

      combined =
        Combined.new!([floored(50, :live, params: @floor), floored(0, :h, params: extra)])

      assert {:ok, %Description{params: @floor}} = describe(combined)
    end

    @tag verifies: "combined-description"
    test "a later part that lacks a parameter of the first's, or takes less of it, is the fault" do
      first = floored(50, :live, params: @floor)
      request = Request.new!(window: [0, 100], now: @now)

      missing = Combined.new!([first, floored(0, :history, params: %{})])
      fault = {:combined_params, [{1, "floor", :missing}]}
      assert describe(missing) == {:error, fault}
      assert Combined.fetch(missing, request) == {:error, fault}
      assert Combined.format_error(fault) =~ ~s(part 1 lacks "floor")

      narrower = [
        %{"floor" => %{type: :category, default: nil}},
        %{"floor" => %{type: :number, default: nil, values: [1, 2]}},
        %{"floor" => %{type: :number, default: 0}},
        %{"floor" => %{type: :number}}
      ]

      for theirs <- narrower do
        combined = Combined.new!([first, floored(0, :history, params: theirs)])
        reason = {:narrower, @floor["floor"], theirs["floor"]}
        assert describe(combined) == {:error, {:combined_params, [{1, "floor", reason}]}}

        assert Combined.fetch(combined, request) ==
                 {:error, {:combined_params, [{1, "floor", reason}]}}
      end

      assert Combined.format_error({:combined_params, [{2, "floor", {:narrower, %{}, %{}}}]}) =~
               ~s(part 2 takes less of "floor")

      # A wider declaration takes every value the first's does.
      closed = %{"agg" => %{type: :category, values: ["max"]}}

      wider = [
        {@floor, %{"floor" => %{type: :term}}},
        {closed, %{"agg" => %{type: :category, values: ["max", "mean"]}}},
        {closed, %{"agg" => %{type: :category, default: "max"}}},
        {%{"floor" => %{type: :number, default: 1}}, @floor}
      ]

      for {ours, theirs} <- wider do
        combined =
          Combined.new!([floored(50, :live, params: ours), floored(0, :h, params: theirs)])

        assert {:ok, %Description{params: ^ours}} = describe(combined)
      end
    end

    @tag verifies: "combined-description"
    test "viewer independent only when every part is; lateness, idle_after and chunk_span the first's" do
      first = [viewer_independent: true, lateness: 5, idle_after: 1_000, chunk_span: 50]
      later = [viewer_independent: true, lateness: 60, idle_after: 10, chunk_span: 500]

      assert {:ok, d} = describe(Combined.new!([floored(50, :l, first), floored(0, :h, later)]))

      assert {d.viewer_independent, d.lateness, d.idle_after, d.chunk_span} ==
               {true, 5, 1_000, 50}

      dependent = Keyword.put(later, :viewer_independent, false)

      assert {:ok, d} =
               describe(Combined.new!([floored(50, :l, first), floored(0, :h, dependent)]))

      refute d.viewer_independent

      assert {:ok, d} = describe(Combined.new!([floored(50, :l, []), floored(0, :h, later)]))

      assert {d.viewer_independent, d.lateness, d.idle_after, d.chunk_span} ==
               {false, nil, nil, nil}
    end

    @tag verifies: "combined-description"
    test "a combination of parameterized, viewer-independent parts passes the kit asked a parameter" do
      alias Macaw.Data.Test.Sources.Broken
      live = Broken.new()
      combined = Combined.new!([live, Broken.new()])
      {:ok, description} = describe(combined)
      assert description.viewer_independent
      assert Map.keys(description.params) == ["scale"]

      assert [] ==
               Conformance.check(combined,
                 requests: [[], [window: [2, 10], params: %{"scale" => 3}], [window: [nil, 6]]],
                 budgets: [nil, 5],
                 push: fn _combined -> Broken.emit(live) end,
                 quiet: 30
               )
    end
  end

  # Rows a `step` apart from `first` to 100 over the number window field `t`, honoring
  # windows, stating `resolution:` (the step by default).
  defmodule Grid do
    @moduledoc false
    @behaviour Macaw.Data.Source
    alias Macaw.Data.{Delivery, Schema, Window}
    alias Macaw.Data.Source.{Description, Request}

    defstruct [:first, :step, :resolution, schema: nil]

    @schema Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number}})

    def new(first, step, opts \\ []),
      do: struct!(__MODULE__, [first: first, step: step, resolution: step] ++ opts)

    @impl true
    def describe(%__MODULE__{} = g, _context),
      do: {:ok, %Description{schema: g.schema || @schema, supports: [:window]}}

    @impl true
    def fetch(%__MODULE__{first: first, step: step} = g, %Request{window: window}) do
      [from, to] = if is_list(window), do: window, else: [nil, nil]

      if Enum.all?([from, to], &(&1 == nil or is_number(&1))) do
        rows = for t <- first..100//step, Window.within?(t, [from, to]), do: %{t: t, v: t}

        Delivery.new(rows,
          served: [
            window: [Window.latest(from, first), Window.earliest(to, 100)],
            resolution: g.resolution
          ],
          schema: Schema.version(g.schema || @schema)
        )
      else
        {:error, {:window, window}}
      end
    end
  end

  describe "the union's resolution" do
    @tag verifies: "combined-resolution"
    test "a later part keeping rows finer than the first's resolution, or at none, is the fault" do
      live = Grid.new(60, 10)
      fault = {:combined_resolution, 1, 1, 10}
      assert fetch(Combined.new!([live, Grid.new(0, 1)]), [0, 100]) == {:error, fault}

      assert Combined.format_error(fault) =~
               "part 1 serves rows at 1, finer than the first part's resolution 10"

      # Its position among the parts, behind one that combines.
      parts = [live, Grid.new(30, 10), Grid.new(0, 5)]
      assert fetch(Combined.new!(parts), [0, 100]) == {:error, {:combined_resolution, 2, 5, 10}}

      # A part stating no resolution, or a name with no span over a number field, has no
      # spacing to compare.
      for theirs <- [nil, :minute] do
        history = Grid.new(0, 10, resolution: theirs)

        assert fetch(Combined.new!([live, history]), [0, 100]) ==
                 {:error, {:combined_resolution, 1, theirs, 10}}
      end
    end

    @tag verifies: "combined-resolution"
    test "a coarser or equal later part combines, the first's resolution the union's" do
      for history <- [Grid.new(0, 20), Grid.new(0, 10), Grid.new(0, 10, resolution: 10.0)] do
        assert {:ok, d} = fetch(Combined.new!([Grid.new(60, 10), history]), [0, 100])
        assert d.served.resolution == 10

        assert column(d, :t) ==
                 Enum.to_list(Enum.filter(history.first..50//history.step, &(&1 < 60))) ++
                   Enum.to_list(60..100//10)
      end

      # A part that kept no rows says nothing of the union's spacing.
      assert {:ok, d} = fetch(Combined.new!([Grid.new(60, 10), Grid.new(0, 1)]), [60, 100])
      assert d.served.resolution == 10
      assert {:ok, _} = fetch(Combined.new!([Grid.new(60, 10), Grid.new(200, 1)]), [0, 100])

      # A first part stating no resolution claims none, so any later part combines.
      assert {:ok, %{served: %{resolution: nil}}} =
               fetch(Combined.new!([Grid.new(60, 10, resolution: nil), Grid.new(0, 1)]), [0, 100])
    end

    @tag verifies: "combined-resolution"
    test "a named resolution over a time field, and a later part in other units, compare by spacing" do
      t0 = ~U[2026-11-01 00:00:00Z]
      time = Schema.new!(%{t: %{type: :time, window: true}, v: %{type: :number}})

      part = fn first, step, resolution ->
        answer = fn %Request{window: [from, to]} ->
          rows =
            for s <- first..3600//step,
                at = DateTime.add(t0, s),
                Window.within?(at, [from, to]),
                do: %{t: at, v: s}

          {rows,
           [window: [Window.latest(from, DateTime.add(t0, first)), to], resolution: resolution]}
        end

        Scripted.new(schema: time, supports: [:window], rows: answer)
      end

      window = [t0, DateTime.add(t0, 3600)]
      live = part.(1800, 60, :minute)

      assert {:ok, %{served: %{resolution: :minute}}} =
               fetch(Combined.new!([live, part.(0, 600, 600)]), window)

      assert {:ok, _} = fetch(Combined.new!([live, part.(0, 3600, :hour)]), window)

      assert fetch(Combined.new!([live, part.(0, 1, :second)]), window) ==
               {:error, {:combined_resolution, 1, :second, :minute}}

      assert fetch(Combined.new!([live, part.(0, 30, 30)]), window) ==
               {:error, {:combined_resolution, 1, 30, :minute}}

      # A history in s behind live data in ms: its resolution read in ms.
      ms = Schema.new!(%{t: %{type: :number, window: true, unit: "ms"}, v: %{type: :number}})
      s = Schema.new!(%{t: %{type: :number, window: true, unit: "s"}, v: %{type: :number}})
      live = Grid.new(60_000, 10_000, schema: ms, resolution: 10_000)

      assert {:ok, %{served: %{resolution: 10_000}}} =
               fetch(Combined.new!([live, Grid.new(0, 10, schema: s)]), [0, 100_000])

      assert fetch(Combined.new!([live, Grid.new(0, 5, schema: s)]), [0, 100_000]) ==
               {:error, {:combined_resolution, 1, 5000.0, 10_000}}
    end

    @tag verifies: "combined-resolution"
    test "the kit finds a finer history the combination's fault, and passes a coarser one" do
      requests = [[], [window: [0, 100]], [window: [20, 70]]]
      finer = Combined.new!([Grid.new(60, 10), Grid.new(0, 1)])
      findings = Conformance.check(finer, requests: requests, budgets: [nil])
      assert findings != []
      assert Enum.all?(findings, &(inspect(&1) =~ "combined_resolution"))

      coarser = Combined.new!([Grid.new(50, 1), Grid.new(0, 10)])
      assert Conformance.check(coarser, requests: requests, budgets: [nil, 5]) == []
    end
  end
end
