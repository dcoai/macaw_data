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
  # the request answering `{rows, served}`; `error:` an error for every fetch.
  defmodule Scripted do
    @moduledoc false
    @behaviour Macaw.Data.Source
    defstruct [:schema, :agent, supports: [], rows: [], error: nil, ref: nil]

    def new(opts) do
      {:ok, agent} = Agent.start_link(fn -> %{fetch: 0, unsubscribe: 0} end)
      struct!(__MODULE__, [agent: agent, ref: make_ref()] ++ opts)
    end

    def calls(%__MODULE__{agent: agent}, call), do: Agent.get(agent, & &1[call])

    @impl true
    def describe(%__MODULE__{schema: schema, supports: supports}, _context),
      do: {:ok, %Description{schema: schema, supports: supports}}

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

      # No budget: a part honoring one reduces rows the combination does not record
      # (macaw_data#273).
      assert [] ==
               Conformance.check(combined,
                 requests: [[], [window: [2, 10]], [window: [nil, 6]]],
                 budgets: [nil],
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
end
