defmodule Macaw.Data.SourceSignalTest do
  @moduledoc "Generated sources (spec/01 §10.1), ported from visualize's Signals and Feed.Signals."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Schema, Source, Table}
  alias Macaw.Data.Source.{Conformance, Request, Signal}

  doctest Signal

  use Conformance,
    name: "Signal",
    source: Signal.new!(:sine, [:t, :a, :b], tick: 40, window: 12),
    requests: [[], [window: [3, 30]], [window: [nil, 20]], [window: [35, nil]]]

  use Conformance,
    name: "Signal on the request's clock",
    source: Signal.new!(:random, [:t, :r], every: 1000, limit: 50, seed: 3),
    requests: [[], [window: [0, 10]], [window: [nil, 5]]]

  @now ~U[2026-11-01 00:00:00Z]

  # Rows visualize's Visualize.Signals.rows/2 gave for these signals (origin/main, 2026-11-12),
  # exactly: the port keeps every value bit for bit, so visualize's goldens hold.
  @golden [
    {:sine, [:t, :a, :b], [window: 5, period: 7, min: -3, max: 11], 40,
     [
       %{b: -1.4728203772762178, a: 9.472820377276204, t: 36},
       %{b: -2.824495385272773, a: 10.824495385272767, t: 37},
       %{b: 0.962813826177106, a: 7.037186173822915, t: 38},
       %{b: 7.0371861738228745, a: 0.9628138261771015, t: 39},
       %{b: 10.824495385272767, a: -2.824495385272763, t: 40}
     ]},
    {:square, [:t, :a, :b, :c], [window: 6, period: 5], 17,
     [
       %{c: 100, b: 0, a: 100, t: 12},
       %{c: 100, b: 0, a: 0, t: 13},
       %{c: 100, b: 100, a: 0, t: 14},
       %{c: 0, b: 100, a: 100, t: 15},
       %{c: 0, b: 0, a: 100, t: 16},
       %{c: 100, b: 0, a: 100, t: 17}
     ]},
    {:random, [:t, :a, :b], [window: 4, seed: 42, min: 1.5, max: 2.5], 1000,
     [
       %{b: 1.8136248232249064, a: 2.2657541012454767, t: 997},
       %{b: 2.1952223742836225, a: 1.6347854769070373, t: 998},
       %{b: 1.7058773202104363, a: 2.429705631806228, t: 999},
       %{b: 1.8685635514441157, a: 2.4579524695396895, t: 1000}
     ]},
    {:discrete, [:t, :n, :m], [window: 5, min: 3, max: 7], 12,
     [
       %{m: 7, t: 8, n: 6},
       %{m: 3, t: 9, n: 7},
       %{m: 4, t: 10, n: 3},
       %{m: 5, t: 11, n: 4},
       %{m: 6, t: 12, n: 5}
     ]}
  ]

  @tag verifies: "signal-rows"
  test "the rows are visualize's for the same tick, bit for bit" do
    for {kind, fields, opts, tick, rows} <- @golden do
      assert Signal.rows(Signal.new!(kind, fields, opts), tick) == rows, inspect(kind)
    end
  end

  @tag verifies: "signal-rows"
  test "a sine starts at the midpoint, a square alternates, a random replays, a discrete wraps" do
    sine = Signal.new!(:sine, [:t, :a, :b], window: 5, period: 4, min: 10, max: 20)
    [r0, r1, _r2, r3, r4] = Signal.rows(sine, 4)
    assert_in_delta r0.a, 15.0, 1.0e-9
    assert_in_delta r1.a, 20.0, 1.0e-9
    assert_in_delta r3.a, 10.0, 1.0e-9
    assert_in_delta r4.a, 15.0, 1.0e-9
    assert_in_delta r1.b, 10.0, 1.0e-9

    square = Signal.new!(:square, [:t, :on], window: 4, period: 4, min: 0, max: 1)
    assert Enum.map(Signal.rows(square, 3), & &1.on) == [1, 1, 0, 0]

    random = Signal.new!(:random, [:t, :r], window: 3, seed: 7)
    rows = Signal.rows(random, 9)
    assert rows == Signal.rows(random, 9)
    assert rows != Signal.rows(%{random | seed: 8}, 9)
    assert List.last(rows) == List.last(Signal.rows(%{random | window: 1}, 9))

    counter = Signal.new!(:discrete, [:t, :n, :m], window: 4, min: 0, max: 2)
    assert Enum.map(Signal.rows(counter, 3), &{&1.n, &1.m}) == [{0, 1}, {1, 2}, {2, 0}, {0, 1}]
    assert Enum.map(Signal.rows(Signal.new!(:sine, [:t, :v]), 25), & &1.t) == Enum.to_list(2..25)
  end

  @tag verifies: "signal-faults"
  test "a bad kind, fields or option is a fault, every one at once; new!/3 raises them" do
    assert Signal.new(:saw, [:t, :t], window: 0, period: -1, min: "a", seed: 1.5, origin: 3) ==
             {:error,
              [
                {[:fields], {:type, :fields}},
                {[:kind], {:enum, Signal.kinds()}},
                {[:min], {:type, :number}},
                {[:origin], {:type, :datetime}},
                {[:period], {:type, :number}},
                {[:seed], {:type, :integer}},
                {[:window], {:type, :pos_integer}}
              ]}

    assert Signal.new(:sine, [], at: 1) == {:error, [{[:at], :unknown_key}]}
    assert Signal.new(:sine, [:t | :v]) == {:error, [{[:fields], {:type, :fields}}]}

    assert Signal.new(:sine, [:t], limit: 0, tick: -1, every: 1.5, describe: []) ==
             {:error,
              [
                {[:describe], {:type, :map}},
                {[:every], {:type, :pos_integer}},
                {[:limit], {:type, :pos_integer}},
                {[:tick], {:type, :non_neg_integer}}
              ]}

    assert {:error, [{[:describe, :v, :type], _} | _]} =
             Signal.new(:sine, [:t, :v], describe: %{v: %{type: :nope}})

    error = assert_raise Macaw.Data.Error, fn -> Signal.new!(:sine, [:t], window: 0) end
    assert error.reason == [{[:window], {:type, :pos_integer}}]
    assert error.message == "not a signal: window: must be a positive integer"
  end

  @tag verifies: "signal-source"
  test "the present is the fixed tick or the request's now, the window is ticks up to it, capped past limit:" do
    signal = Signal.new!(:discrete, [:t, :n], every: 1000, origin: @now, limit: 4)
    {:ok, d} = Source.describe(signal, nil)
    assert Schema.window_field(d.schema) == "t"
    assert Schema.fetch(d.schema, :t, :label) == {:ok, "Tick"}

    at = fn ms, window ->
      {:ok, r} = Request.new(now: DateTime.add(@now, ms, :millisecond), window: window)
      {:ok, delivery} = Source.fetch(signal, d, r)
      {Table.column(delivery.rows, "t"), delivery.served.window, delivery.served.capped}
    end

    assert at.(9_999, [0, nil]) == {[6, 7, 8, 9], [6, 9], true}
    assert at.(9_999, [7, 20]) == {[7, 8, 9], [7, 9], false}
    assert at.(-5_000, nil) == {[0], [0, 0], false}
    assert at.(2_500, [1.5, 2.5]) == {[2], [2, 2], false}

    fixed = Signal.at(Signal.new!(:discrete, [:t, :n], tick: 3), 7)
    {:ok, r} = Request.new(now: @now, window: [nil, nil])
    {:ok, moved} = Source.fetch(fixed, d, r)
    assert Table.column(moved.rows, "t") == Enum.to_list(0..7)

    {:ok, r} = Request.new(now: @now, window: [~U[2026-01-01 00:00:00Z], nil])
    assert Source.fetch(signal, d, r) == {:error, {:window, r.window}}
    assert Signal.format_error({:window, r.window}) =~ "not ticks"
  end

  @tag verifies: "signal-source"
  property "one request, one now, one answer: a tick's row is the same through every window" do
    check all(
            kind <- member_of(Signal.kinds()),
            seed <- integer(),
            tick <- integer(0..500),
            from <- integer(0..500),
            span <- integer(0..60)
          ) do
      to = from + span
      signal = Signal.new!(kind, [:t, :a, :b], seed: seed, tick: tick, window: 7)
      {:ok, d} = Source.describe(signal, nil)
      {:ok, r} = Request.new(now: @now, window: [from, to])
      {:ok, one} = Source.fetch(signal, d, r)
      {:ok, two} = Source.fetch(signal, d, r)
      assert Table.rows!(one.rows) == Table.rows!(two.rows)

      for row <- Table.rows!(one.rows) do
        [expected] = Signal.rows(signal, row["t"], row["t"])
        assert row == Map.new(expected, fn {k, v} -> {to_string(k), v} end)
      end
    end
  end
end
