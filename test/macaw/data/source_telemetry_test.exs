defmodule Macaw.Data.SourceTelemetryTest do
  @moduledoc """
  `Macaw.Data.Source.Telemetry` (spec/01 §10.3) under real `:telemetry.execute/3` calls and
  real `Telemetry.Metrics` definitions: a schema from the definitions, one source per
  metric, a window honored, pushes with the schema first, and calls that answer values
  when the collector is gone. Ported from visualize's `Visualize.Feed.TelemetryTest`.
  """
  use ExUnit.Case, async: true

  import Telemetry.Metrics

  alias Macaw.Data.{Delivery, Schema, Source}
  alias Macaw.Data.Source.{Combined, Conformance, Description, Request, Telemetry}

  doctest Telemetry

  # A history store holding fixed rows, honoring windows by serving what was asked.
  defmodule History do
    @moduledoc false
    @behaviour Macaw.Data.Source
    defstruct [:schema, :rows]

    @impl true
    def describe(%__MODULE__{schema: schema}, _context),
      do: {:ok, %Description{schema: schema, supports: [:window]}}

    @impl true
    def fetch(%__MODULE__{schema: schema, rows: rows}, %Request{window: window}),
      do: Delivery.new(rows, served: [window: window], schema: Schema.version(schema))
  end

  # The kit's collector: one gauge under this module's own event, which no other test emits.
  @kit [:macaw_data_telemetry_kit, :gauge]

  @doc false
  def kit_source do
    {:ok, server} =
      ExUnit.Callbacks.start_supervised(
        {Telemetry, metrics: [last_value("macaw_data_telemetry_kit.gauge.value")], every: nil}
      )

    for v <- 1..3, do: :telemetry.execute(@kit, %{value: v}, %{})
    Telemetry.source(server, "macaw_data_telemetry_kit.gauge.value")
  end

  @doc false
  def kit_push(%Telemetry{server: server}) do
    :telemetry.execute(@kit, %{value: 9}, %{})
    Telemetry.flush(server)
  end

  use Conformance,
    name: "Telemetry",
    source: Macaw.Data.SourceTelemetryTest.kit_source(),
    requests: [
      [],
      [window: [~U[2000-01-01 00:00:00Z], nil]],
      [window: [nil, ~U[2000-01-01 00:00:00Z]]]
    ],
    push: &Macaw.Data.SourceTelemetryTest.kit_push/1,
    down: Macaw.Data.Source.Telemetry.source(:macaw_data_no_collector, "gauge"),
    quiet: 30

  # Each test emits under its own prefix, so tests running together never see each
  # other's events.
  defp prefix(context), do: :"macaw_data_telemetry_#{:erlang.phash2(context.test)}"

  # A clock that moves a millisecond each time it is read: deterministic, no wall clock.
  defp clock do
    counter = :counters.new(1, [])
    :counters.put(counter, 1, 1_760_000_000_000_000)

    fn ->
      :counters.add(counter, 1, 1_000)
      :counters.get(counter, 1)
    end
  end

  # Every request's `now`: after every stamp the collector's clock gives a test.
  @now ~U[2030-01-01 00:00:00.000000Z]

  defp describe(source) do
    with {:ok, %Description{schema: schema, supports: supports}} <- Source.describe(source, nil),
         do: {schema.version, schema, supports}
  end

  # A request built as a struct, so a window no request takes (`:all`) still reaches the
  # source, as the conformance kit's unreadable requests do.
  defp fetch(source, window, now \\ @now) do
    with {:ok, description} <- Source.describe(source, nil),
         do: Source.fetch(source, description, %Request{window: window, now: now})
  end

  defp rows_of(%Delivery{} = delivery), do: Delivery.rows!(delivery)
  defp get(row, field), do: Macaw.Data.Table.get(row, field)
  defp values(delivery), do: Enum.map(rows_of(delivery), &get(&1, :value))

  defp start(metrics, opts \\ []) do
    opts = Keyword.merge([metrics: metrics, every: nil, clock: clock()], opts)
    start_supervised!({Telemetry, opts})
  end

  defp request(p, ms, route),
    do: :telemetry.execute([p, :request, :stop], %{duration: ms * 1_000_000}, %{route: route})

  describe "the schema from the definitions" do
    @tag verifies: "telemetry-schema"
    test "labels, UCUM units, the quantity, a counter's count and a tag's category", context do
      p = prefix(context)

      server =
        start([
          summary("#{p}.request.stop.duration",
            unit: {:native, :millisecond},
            tags: [:route],
            description: "Request time"
          ),
          counter("#{p}.request.stop.duration", tags: [:route]),
          last_value("#{p}.vm.memory.total", unit: {:byte, :kilobyte}),
          last_value("#{p}.queue.length", unit: :native)
        ])

      {:ok, sources} = Telemetry.sources(server)
      name = "#{p}.request.stop.duration"

      assert Map.keys(sources) |> Enum.sort() ==
               Enum.sort([
                 name <> ":summary",
                 name <> ":counter",
                 "#{p}.vm.memory.total",
                 "#{p}.queue.length"
               ])

      {version, schema, supports} = describe(Telemetry.source(server, name <> ":summary"))
      assert supports == [:window, :push]
      assert version == Schema.version(schema)
      assert Schema.window_field(schema) == "t"
      assert {:ok, %{type: :time}} = Schema.fetch(schema, :t)
      assert {:ok, %{type: :category}} = Schema.fetch(schema, :route)

      assert {:ok, %{type: :number, label: "Request time", unit: "ms", quantity: :duration}} =
               Schema.fetch(schema, :value)

      {_v, count, _} = describe(sources[name <> ":counter"])
      assert {:ok, %{unit: "1", quantity: :count, label: ^name}} = Schema.fetch(count, :value)

      {_v, memory, _} = describe(sources["#{p}.vm.memory.total"])
      assert {:ok, %{unit: "kBy", quantity: :information}} = Schema.fetch(memory, :value)

      # `:native` has no size until converted: no unit rather than a guess.
      {_v, queue, _} = describe(sources["#{p}.queue.length"])
      assert {:ok, value} = Schema.fetch(queue, :value)
      refute Map.has_key?(value, :unit)
    end
  end

  describe "a definition's facts" do
    defp value(server, name) do
      {_v, schema, _} = describe(Telemetry.source(server, name))
      {:ok, value} = Schema.fetch(schema, :value)
      value
    end

    @tag verifies: "telemetry-schema"
    test "each metric type gives its metric_kind", context do
      p = prefix(context)

      server =
        start([
          counter("#{p}.a.count"),
          sum("#{p}.a.sum"),
          last_value("#{p}.a.last"),
          summary("#{p}.a.summary"),
          distribution("#{p}.a.distribution")
        ])

      kinds =
        for k <- ~w(count sum last summary distribution), into: %{} do
          {k, value(server, "#{p}.a.#{k}").metric_kind}
        end

      assert kinds == %{
               "count" => :counter,
               "sum" => :counter,
               "last" => :gauge,
               "summary" => :gauge,
               "distribution" => :gauge
             }
    end

    @tag verifies: "telemetry-schema"
    test "reporter_options[:macaw] lands in the schema, an explicit metric_kind wins, facts_key: names another key",
         context do
      p = prefix(context)

      facts = [polarity: :lower_is_better, bounds: [0, nil], target: 250]

      server =
        start([
          summary("#{p}.panel.load",
            unit: {:native, :millisecond},
            reporter_options: [macaw: facts]
          ),
          last_value("#{p}.queue.total", reporter_options: [macaw: [metric_kind: :counter]]),
          # Options for another reporter are that reporter's, never read here.
          last_value("#{p}.queue.depth", reporter_options: [other: [anything: true]])
        ])

      assert %{
               type: :number,
               unit: "ms",
               quantity: :duration,
               metric_kind: :gauge,
               polarity: :lower_is_better,
               bounds: [0, nil],
               target: 250
             } = value(server, "#{p}.panel.load")

      assert value(server, "#{p}.queue.total").metric_kind == :counter
      assert %{type: :number, metric_kind: :gauge} = depth = value(server, "#{p}.queue.depth")
      refute Map.has_key?(depth, :polarity)

      # visualize's key, named: its definitions keep their facts.
      {:ok, other} =
        Telemetry.start_link(
          metrics: [summary("#{p}.v.load", reporter_options: [visualize: facts])],
          facts_key: :visualize,
          every: nil
        )

      assert %{polarity: :lower_is_better, target: 250} = value(other, "#{p}.v.load")
      GenServer.stop(other)
    end

    @tag verifies: "telemetry-faults"
    test "an unknown fact, an invalid fact or a bad option is its fault, every one at once, nothing started",
         context do
      p = prefix(context)
      ok = counter("#{p}.request.duration")
      label = summary("#{p}.request.duration", reporter_options: [macaw: [label: "Nope"]])
      up = summary("#{p}.request.duration", reporter_options: [macaw: [polarity: :up]])
      bad = last_value("#{p}.gauge", reporter_options: [macaw: :lower_is_better])

      assert Telemetry.start_link(metrics: [ok, label, up, bad, :nope], every: nil) ==
               {:error,
                [
                  {[:metrics, 1, :value, :label], :unknown_key},
                  {[:metrics, 2, :value, :polarity], {:enum, Schema.polarities()}},
                  {[:metrics, 3, :value], {:type, :description}},
                  {[:metrics, 4], {:type, :metric}}
                ]}

      assert Telemetry.start_link(every: 0, keep: -1, clock: 3, facts_key: "x", at: 1) ==
               {:error, [{[:at], :unknown_key}]}

      assert Telemetry.start_link(every: 0, keep: -1, clock: 3, facts_key: "x") ==
               {:error,
                [
                  {[:metrics], :required},
                  {[:keep], {:type, :pos_integer}},
                  {[:every], {:type, :pos_integer}},
                  {[:clock], {:type, :clock}},
                  {[:facts_key], {:type, :atom}}
                ]}

      assert Telemetry.start_link(metrics: :nope) == {:error, [{[:metrics], {:type, :metrics}}]}

      # Nothing was attached for a collector that never started.
      assert :telemetry.list_handlers([p, :request, :duration]) == []
      assert :telemetry.list_handlers([p, :gauge]) == []

      error = assert_raise Macaw.Data.Error, fn -> Telemetry.start_link!(metrics: :nope) end
      assert error.reason == [{[:metrics], {:type, :metrics}}]
      refute error.message =~ "{:"
      assert Telemetry.format_error(:no_telemetry) =~ ":telemetry"
    end

    @tag verifies: "telemetry-schema"
    test "a combination keeps the telemetry source's facts in front of a history", context do
      p = prefix(context)

      server =
        start([
          summary("#{p}.panel.load",
            unit: {:native, :millisecond},
            reporter_options: [macaw: [polarity: :lower_is_better, target: 250]]
          )
        ])

      live = Telemetry.source(server, "#{p}.panel.load")
      :telemetry.execute([p, :panel], %{load: 7_000_000}, %{})

      history_schema =
        Schema.new!(%{"t" => %{type: :time}, "value" => %{type: :number, unit: "s"}})

      t0 = ~U[2025-10-01 00:00:00Z]
      history = %History{schema: history_schema, rows: [%{"t" => t0, "value" => 0.25}]}

      {version, schema, _} = describe(live)
      combined = Combined.new!([live, history])
      assert {^version, ^schema, [:window, :push]} = describe(combined)

      {:ok, delivery} = fetch(combined, [t0, nil])
      assert delivery.schema == version
      assert [%{"t" => ^t0, "value" => 250.0}, %{"value" => 7.0}] = rows_of(delivery)
    end
  end

  describe "the rows" do
    @tag verifies: "telemetry-rows"
    test "a summary row is the measurement, converted; a counter's the count per tag; a sum's the total",
         context do
      p = prefix(context)

      server =
        start([
          summary("#{p}.request.stop.duration", unit: {:native, :millisecond}, tags: [:route]),
          counter("#{p}.request.count", event_name: [p, :request, :stop], tags: [:route]),
          sum("#{p}.request.total",
            event_name: [p, :request, :stop],
            measurement: :duration,
            unit: {:native, :millisecond}
          )
        ])

      for {ms, route} <- [{5, "/a"}, {7, "/b"}, {11, "/a"}], do: request(p, ms, route)

      {:ok, d} = fetch(Telemetry.source(server, "#{p}.request.stop.duration"), nil)

      assert Enum.map(rows_of(d), &{get(&1, :value), get(&1, :route)}) ==
               [{5, "/a"}, {7, "/b"}, {11, "/a"}]

      assert rows_of(d)
             |> Enum.map(&get(&1, :t))
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> DateTime.before?(a, b) end)

      {:ok, count} = fetch(Telemetry.source(server, "#{p}.request.count"), nil)

      assert Enum.map(rows_of(count), &{get(&1, :value), get(&1, :route)}) ==
               [{1, "/a"}, {1, "/b"}, {2, "/a"}]

      {:ok, total} = fetch(Telemetry.source(server, "#{p}.request.total"), nil)
      assert values(total) == [5, 12, 23]
    end

    @tag verifies: "telemetry-rows"
    test "keep, a measurement function and a missing measurement", context do
      p = prefix(context)

      server =
        start([
          last_value("#{p}.job.stop.duration",
            drop: &(&1.kind == :noise),
            measurement: fn m -> m.duration * 2 end
          ),
          last_value("#{p}.job.stop.size", measurement: :size)
        ])

      :telemetry.execute([p, :job, :stop], %{duration: 1}, %{kind: :real})
      :telemetry.execute([p, :job, :stop], %{duration: 2}, %{kind: :noise})
      :telemetry.execute([p, :job, :stop], %{duration: 3}, %{kind: :real})

      {:ok, d} = fetch(Telemetry.source(server, "#{p}.job.stop.duration"), nil)
      assert values(d) == [2, 6]
      {:ok, none} = fetch(Telemetry.source(server, "#{p}.job.stop.size"), nil)
      assert rows_of(none) == []
    end

    @tag verifies: "telemetry-rows"
    test "a window of DateTimes is honored, up to now; a fetch before the kept rows is capped",
         context do
      p = prefix(context)
      server = start([last_value("#{p}.gauge.value")], keep: 3)
      source = Telemetry.source(server, "#{p}.gauge.value")
      for v <- 1..5, do: :telemetry.execute([p, :gauge], %{value: v}, %{})

      {:ok, all} = fetch(source, nil)
      assert values(all) == [3, 4, 5]
      [oldest, middle, newest] = Enum.map(rows_of(all), &get(&1, :t))
      assert all.served.window == [oldest, @now]

      {:ok, part} = fetch(source, [middle, newest])
      assert values(part) == [4, 5]
      refute part.served.capped

      {:ok, early} = fetch(source, [DateTime.add(oldest, -1, :hour), nil])
      assert early.served.capped
      assert early.served.window == [oldest, @now]

      assert fetch(source, [1, 2]) == {:error, {:window, [1, 2]}}
      assert fetch(source, :all) == {:error, {:window, :all}}
      assert fetch(Telemetry.source(server, "nope"), nil) == {:error, {:unknown_metric, "nope"}}
    end

    @tag verifies: "telemetry-rows"
    test "one request, one now, one answer: a row stamped after now is never served", context do
      p = prefix(context)
      server = start([last_value("#{p}.gauge.value")])
      source = Telemetry.source(server, "#{p}.gauge.value")
      for v <- 1..3, do: :telemetry.execute([p, :gauge], %{value: v}, %{})
      {:ok, all} = fetch(source, nil)
      [_first, second, _third] = Enum.map(rows_of(all), &get(&1, :t))

      {:ok, then} = fetch(source, nil, second)
      assert values(then) == [1, 2]
      assert List.last(then.served.window) == second
      for v <- 4..5, do: :telemetry.execute([p, :gauge], %{value: v}, %{})
      assert {:ok, ^then} = fetch(source, nil, second)
      assert {:ok, all} = fetch(source, nil)
      assert values(all) == [1, 2, 3, 4, 5]
    end
  end

  describe "push" do
    @tag verifies: "telemetry-push"
    test "the schema arrives first, then the rows new since the last flush, numbered per subscription",
         context do
      p = prefix(context)
      server = start([last_value("#{p}.gauge.value")])
      source = Telemetry.source(server, "#{p}.gauge.value")
      :telemetry.execute([p, :gauge], %{value: 0}, %{})

      {:ok, first} = Source.subscribe(source, self())
      {version, schema, _} = describe(source)
      assert_received {:macaw_source, ^first, {:schema, ^schema}}

      :telemetry.execute([p, :gauge], %{value: 1}, %{})
      :ok = Telemetry.flush(server)
      {:ok, second} = Source.subscribe(source, self())
      assert_received {:macaw_source, ^second, {:schema, ^schema}}

      for v <- 2..3 do
        :telemetry.execute([p, :gauge], %{value: v}, %{})
        :ok = Telemetry.flush(server)
      end

      for {ref, seq, value} <- [
            {first, 1, 1},
            {first, 2, 2},
            {first, 3, 3},
            {second, 1, 2},
            {second, 2, 3}
          ] do
        assert_received {:macaw_source, ^ref, {:increment, ^seq, d}}
        assert values(d) == [value]
        assert d.schema == version
      end

      :ok = Telemetry.flush(server)
      refute_received {:macaw_source, _ref, {:increment, _seq, _d}}
      :ok = Source.unsubscribe(source, first)
      :ok = Source.unsubscribe(source, second)
      :telemetry.execute([p, :gauge], %{value: 4}, %{})
      :ok = Telemetry.flush(server)
      refute_received {:macaw_source, _ref, _}
    end

    @tag verifies: "telemetry-push"
    test "a fetch under a subscription is its snapshot: at its last increment, without the rows waiting",
         context do
      p = prefix(context)
      server = start([last_value("#{p}.gauge.value")])
      source = Telemetry.source(server, "#{p}.gauge.value")
      {:ok, description} = Source.describe(source, nil)
      :telemetry.execute([p, :gauge], %{value: 1}, %{})
      {:ok, ref} = Source.subscribe(source, self())
      :telemetry.execute([p, :gauge], %{value: 2}, %{})
      :ok = Telemetry.flush(server)
      :telemetry.execute([p, :gauge], %{value: 3}, %{})

      {:ok, snapshot} = Source.fetch(source, description, %Request{now: @now, subscription: ref})
      assert {values(snapshot), snapshot.served.position} == {[1, 2], 1}

      {:ok, plain} = fetch(source, nil)
      assert {values(plain), plain.served.position} == {[1, 2, 3], nil}

      :ok = Telemetry.flush(server)
      assert_received {:macaw_source, ^ref, {:increment, 2, next}}
      assert values(next) == [3]
      assert %{source: name, window: "t"} = Macaw.Data.Table.origin(snapshot.rows)
      assert name == "#{p}.gauge.value"
    end

    @tag verifies: "telemetry-push"
    test "a subscriber that exits is dropped; every: flushes on its own", context do
      p = prefix(context)
      server = start([last_value("#{p}.gauge.value")], every: 10)
      source = Telemetry.source(server, "#{p}.gauge.value")
      subscriber = spawn(fn -> receive do: (:never -> :ok) end)
      {:ok, _ref} = Source.subscribe(source, subscriber)
      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}
      :telemetry.execute([p, :gauge], %{value: 1}, %{})
      assert :ok = Telemetry.flush(server)
      assert %{subscribers: subscribers} = :sys.get_state(server)
      assert subscribers == %{}

      {:ok, mine} = Source.subscribe(source, self())
      :telemetry.execute([p, :gauge], %{value: 2}, %{})
      assert_receive {:macaw_source, ^mine, {:increment, 1, d}}, 1_000
      assert values(d) == [2]
    end
  end

  describe "the collector's life" do
    @tag verifies: "telemetry-life"
    test "calls answer values when the collector is gone, and its handler is detached", context do
      p = prefix(context)
      server = start([last_value("#{p}.gauge.value")])
      source = Telemetry.source(server, "#{p}.gauge.value")
      assert [_handler] = :telemetry.list_handlers([p, :gauge])

      :ok = stop_supervised(Telemetry)
      assert :telemetry.list_handlers([p, :gauge]) == []
      assert describe(source) == {:error, :noproc}
      assert fetch(source, nil) == {:error, :noproc}
      assert Source.subscribe(source, self()) == {:error, :noproc}
      assert Source.unsubscribe(source, make_ref()) == :ok
      assert Telemetry.sources(server) == {:error, :noproc}
      assert Telemetry.flush(server) == {:error, :noproc}
      refute_received _anything
    end

    @tag verifies: "telemetry-life"
    test "a collector that stops during a call is a value, not an exit", context do
      p = prefix(context)
      server = start([last_value("#{p}.gauge.value")])
      :sys.suspend(server)
      source = Telemetry.source(server, "#{p}.gauge.value")
      caller = Task.async(fn -> describe(source) end)
      wait_for_message(server)
      Process.exit(server, :kill)
      assert {:error, {:down, :killed}} = Task.await(caller)
    end
  end

  defp wait_for_message(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, 0} ->
        receive after: (1 -> wait_for_message(pid))

      _queued ->
        :ok
    end
  end
end
