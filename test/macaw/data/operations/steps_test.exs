defmodule Macaw.Data.Operations.StepsTest do
  @moduledoc """
  Steps a chunk at a time (spec/04 §1.4; macaw_data#9 §5, #20): each column-native step
  declares its class and the context it reads, works each chunk by itself, and merges
  its parts as its class says, so the chunking never changes a result.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Macaw.Data.Test.Trace, only: [calls: 2]

  alias Macaw.Data.{Operations, Table}
  alias Macaw.Data.Operations.Step
  alias Macaw.Data.Operations.Transforms.{Filter, Take, Window}
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Test.Storage

  @registry Operations.registry()
  @origin %{source: "taps", resolution: 1, window: "t", span: 50}

  # A checked node, as `run/3` is given one.
  defp checked(node) do
    {:ok, [checked]} = Operations.validate(@registry, [node], %{})
    checked
  end

  defp run(table, node, context \\ %{}), do: Operations.apply!(@registry, [node], table, context)

  # Rows of every kind of column, `t` ascending with its gaps last when `sorted?`.
  defp columns(ts, vs, ks, ss) do
    [{"t", :number, ts}, {"v", :number, vs}, {"k", :category, ks}, {"s", :text, ss}]
  end

  defp header, do: [{"t", :number}, {"v", :number}, {"k", :category}, {"s", :text}]

  # A table of row maps under the header, as the oracle's answer.
  defp of_rows(rows),
    do: Table.new!(for({name, type} <- header(), do: {name, type, Enum.map(rows, & &1[name])}))

  defp source(n, span \\ 50) do
    ts = Enum.to_list(0..(n - 1))

    Table.new!(columns(ts, ts, Enum.map(ts, &"k#{rem(&1, 3)}"), Enum.map(ts, &"s#{&1}")),
      origin: %{@origin | span: span}
    )
  end

  # -- the oracles: the rows' answers, as the steps answered before they were chunked ----

  defp passes?(:present, r, _v), do: r != nil
  defp passes?(:absent, r, _v), do: r == nil
  defp passes?(:eq, r, v), do: Operations.same?(r, v)
  defp passes?(:ne, r, v), do: not Operations.same?(r, v)
  defp passes?(_ordering, nil, _v), do: false
  defp passes?(:lt, r, v), do: r < v
  defp passes?(:lte, r, v), do: r <= v
  defp passes?(:gt, r, v), do: r > v
  defp passes?(:gte, r, v), do: r >= v

  defp oracle(rows, %{op: "filter", field: f, test: test, value: value}),
    do: Enum.filter(rows, &passes?(test, &1[f], value))

  defp oracle(rows, %{op: "take", n: n, side: :end}), do: Enum.take(rows, -n)
  defp oracle(rows, %{op: "take", n: n, side: :start}), do: Enum.take(rows, n)

  defp oracle(rows, %{op: "window"} = node) do
    {from, to} = {Map.get(node, :from), Map.get(node, :to)}

    readings = for r <- rows, r["t"] != nil, do: r["t"]

    case readings do
      [] ->
        []

      _ ->
        now = Map.get(node, :now) || Enum.max(readings)
        lo = if from, do: now - hd(from), else: nil
        within? = fn t -> if to, do: t < now - hd(to), else: t <= now end

        Enum.filter(
          rows,
          &(&1["t"] != nil and (lo == nil or &1["t"] >= lo) and within?.(&1["t"]))
        )
    end
  end

  # -- generators ------------------------------------------------------------------------

  defp value_gen, do: one_of([integer(-5..5), float(min: -5.0, max: 5.0), constant(nil)])

  defp table_gen do
    gen all(
          n <- integer(0..90),
          ts <- list_of(integer(0..400), length: n),
          gaps <- integer(0..3),
          vs <- list_of(value_gen(), length: n + gaps),
          ks <- list_of(member_of(["a", "b", :c, nil]), length: n + gaps),
          ss <-
            list_of(one_of([string(:alphanumeric, max_length: 3), constant(nil)]),
              length: n + gaps
            ),
          sorted? <- boolean()
        ) do
      ts = if sorted?, do: Enum.sort(ts), else: ts
      ts = ts ++ List.duplicate(nil, gaps)
      opts = if sorted?, do: [origin: @origin], else: []
      Table.new!(columns(ts, vs, ks, ss), opts)
    end
  end

  defp node_gen do
    one_of([
      gen all(
            field <- member_of(["v", "k", "nope"]),
            test <- member_of([:eq, :ne, :lt, :lte, :gt, :gte, :present, :absent]),
            value <- one_of([integer(-3..3), member_of(["a", :c])])
          ) do
        %{op: "filter", field: field, test: test, value: value}
      end,
      gen all(n <- integer(0..100), side <- member_of([:end, :start])) do
        %{op: "take", n: n, side: side}
      end,
      gen all(
            from <- one_of([constant(nil), integer(0..300)]),
            to <- one_of([constant(nil), integer(0..100)]),
            now <- one_of([constant(nil), integer(0..500)])
          ) do
        [
          op: "window",
          field: "t",
          from: from && [from, :second],
          to: to && [to, :second],
          now: now
        ]
        |> Enum.reject(fn {_key, value} -> value == nil end)
        |> Map.new()
      end
    ])
  end

  defp context(%{now: now}), do: %{now: now}
  defp context(_node), do: %{}

  describe "the classes (spec/04 §1.4)" do
    @tag verifies: "operations-step-classes"
    test "filter, take and window declare a per-row class and the context they read" do
      nodes = [
        {Filter, %{op: "filter", field: "t"}},
        {Take, %{op: "take", n: 1}},
        {Window, %{op: "window", field: "t"}}
      ]

      for {module, node} <- nodes do
        assert Step.step?(module)
        assert module.class(checked(node)) == :row
      end

      assert Filter.reads() == []
      assert Take.reads() == []
      assert Window.reads() == [:now, :schema]
      refute Step.step?(Macaw.Data.Test.Ops.Double)
    end

    @tag verifies: "operations-step-classes"
    test "only the context a step declares reaches it" do
      table = source(20)
      node = checked(%{op: "window", field: "t", from: [5, :second]})
      parts = Step.parts(Window, node, table, %{now: 19, frame: %{width: 3}, sources: %{}})
      wide = Step.parts(Window, node, table, %{now: 19})
      assert parts == wide
    end

    @tag verifies: "operations-step-classes"
    test "a per-row step's merge is concatenation: chunks passed through, cut, or gathered" do
      table = Storage.chunked(source(30), 10)
      [{a, 0, 10}, {b, 0, 10}, {c, 0, 10}] = Table.chunks(table)

      # The first chunk fails `v >= 5` partly, the others pass whole.
      filtered = run(table, %{op: "filter", field: "v", test: :gte, value: 5})
      node = checked(%{op: "filter", field: "v", test: :gte, value: 5})
      [part | _] = Step.parts(Filter, node, table, %{})
      [{gathered, 0, 5}, {^b, 0, 10}, {^c, 0, 10}] = Table.chunks(filtered)
      assert Chunk.id(gathered) == {Chunk.id(a), part.key}
      assert Chunk.digest(gathered) == nil
      assert Table.column(filtered, "t") == Enum.to_list(5..29)

      # A run is cut without copying: the same chunk, read from another row.
      taken = run(table, %{op: "take", n: 15})
      assert Table.chunks(taken) == [{b, 5, 5}, {c, 0, 10}]

      # The input's columns and its sorted column are kept.
      assert Table.sorted(table) == "t"
      assert Table.sorted(filtered) == "t"
      assert Operations.columns(taken) == header()
    end
  end

  describe "chunk-size independence (spec/04 §1.4)" do
    @tag verifies: "operations-step-chunking"
    property "filter, take and window answer the rows' answer under every chunking" do
      check all(table <- table_gen(), node <- node_gen(), max_runs: 40) do
        expected = table |> Table.rows() |> oracle(node) |> of_rows()
        step = Map.delete(node, :now)

        for size <- [1, 7, :one] do
          chunked = Storage.chunked(table, size)
          assert Table.equal?(run(chunked, step, context(node)), expected)
        end

        assert Table.equal?(run(table, step, context(node)), expected)
      end
    end

    @tag verifies: "operations-step-chunking"
    test "twenty thousand rows answer alike canonically, 7 rows a chunk and in one chunk" do
      table = source(20_000)
      assert length(Table.chunks(table)) == 400

      nodes = [
        %{op: "filter", field: "k", test: :eq, value: "k1"},
        %{op: "take", n: 100},
        %{op: "window", field: "t", from: [7_000, :second], to: [100, :second]}
      ]

      for node <- nodes do
        expected = run(table, node)

        for size <- [7, :one] do
          assert Table.equal?(run(Storage.chunked(table, size), node), expected)
        end
      end
    end
  end

  describe "step keys (spec/04 §1.4)" do
    @tag verifies: "operations-step-keys"
    test "a key is the step's identity, its context as resolved for the chunk, and its run" do
      table = source(200)
      node = checked(%{op: "filter", field: "v", test: :gt, value: 3})
      identity = Operations.step_digest(@registry, node)

      [part | _] = Step.parts(Filter, node, table, %{})
      assert part.key == {identity, "v", nil}

      # A view that reads part of its chunk names its run in the key.
      [cut | _] = Step.parts(Filter, node, Table.slice(table, 3, 10), %{})
      assert cut.key == {identity, "v", {3, 10}}
    end

    @tag verifies: "operations-step-keys"
    test "window keys an inside chunk without now, drops an outside one, and keys an edge by its bounds" do
      # Spans of 50: chunks [0, 50), [50, 100), [100, 150), [150, 200).
      table = source(200)
      node = checked(%{op: "window", field: "t", from: [120, :second]})

      frame = fn now -> Step.parts(Window, node, table, %{now: now}) end
      [outside, edge, inside, last] = frame.(199)
      assert outside.context == :none
      assert edge.context == {:run, 29, 21}
      assert inside.context == :all
      assert last.context == :all

      # A frame later the inside chunk's key is the same; the edge's moves with now.
      [_, edge_later, inside_later, _] = frame.(200)
      assert inside_later.key == inside.key
      assert edge_later.context == {:run, 30, 20}
      assert edge_later.key != edge.key

      assert Step.chunk(Window, node, outside) == []
      [{chunk, 29, 21}] = Step.chunk(Window, node, edge)
      assert chunk == elem(edge.view, 0)
    end
  end

  describe "the window field, sorted (spec/04 §4.3)" do
    @tag verifies: "operations-window-sorted"
    test "a sorted window field is binary-searched, any other column scanned, alike" do
      # Spans of 8192: now is 24575, the window [14575, 24570).
      table = source(8192 * 3, 8192)
      {:ok, unsorted} = Table.from_chunks(header(), Enum.map(Table.chunks(table), &elem(&1, 0)))
      assert Table.sorted(unsorted) == nil

      node = %{op: "window", field: "t", from: [10_000, :second], to: [5, :second]}
      reads = calls({Chunk, :at, 3}, fn -> run(table, node) end)
      assert length(reads) < 200

      assert calls({Chunk, :at, 3}, fn -> run(unsorted, node) end) == []
      assert Table.equal?(run(table, node), run(unsorted, node))

      [_, {second, 0, 8192}, {third, 0, 8192}] = Table.chunks(table)
      assert Table.chunks(run(table, node)) == [{second, 6383, 1809}, {third, 0, 8186}]
    end
  end

  describe "cost, stated as work (spec/04 §1.4)" do
    @tag verifies: "operations-step-cost"
    test "take n: 100 does the same work whatever the input's length" do
      small = Table.new!([{"v", :number, Enum.to_list(1..(8192 * 4))}])
      large = Table.new!([{"v", :number, Enum.to_list(1..(8192 * 40))}])
      node = checked(%{op: "take", n: 100})

      work = fn table ->
        Table.chunks(table)
        {:reductions, before} = Process.info(self(), :reductions)
        Step.run(Take, node, table, %{})
        {:reductions, later} = Process.info(self(), :reductions)
        later - before
      end

      work.(small)
      {a, b} = {work.(small), work.(large)}
      # Ten times the rows: the work grows by a step a chunk, never by the rows.
      assert b - a < 36 * 100, "#{a} and #{b} reductions"
    end

    @tag verifies: "operations-step-cost"
    test "a chain of filter, window and take calls neither Table.rows/1 nor Operations.table/2" do
      table = source(1000)

      chain = [
        %{op: "filter", field: "k", test: :ne, value: "k0"},
        %{op: "window", field: "t", from: [500, :second]},
        %{op: "take", n: 100}
      ]

      assert calls({Table, :rows, 1}, fn -> Operations.apply!(@registry, chain, table) end) == []

      assert calls({Operations, :table, 2}, fn -> Operations.apply!(@registry, chain, table) end) ==
               []
    end
  end

  describe "the table's sorted column and its edge (spec/01 §1.1)" do
    @tag verifies: "table-sorted"
    test "a source's table in event time is sorted by its window field, rows by none" do
      assert Table.sorted(source(10)) == "t"
      assert Table.sorted(Table.new!(columns([1], [1], ["a"], ["s"]))) == nil

      by_count = Table.new!(columns([1], [1], ["a"], ["s"]), origin: %{@origin | span: nil})
      assert Table.sorted(by_count) == nil

      [{chunk, _, _}] = Table.chunks(source(10))
      {:ok, kept} = Table.from_chunks(header(), [chunk], sorted: "t")
      assert Table.sorted(kept) == "t"
      {:ok, none} = Table.from_chunks(header(), [chunk])
      assert Table.sorted(none) == nil
      assert Table.equal?(kept, none)
      assert Table.digest(kept) == Table.digest(none)
    end

    @tag verifies: "table-edge-names"
    test "from/2 names every key of every row without merging a row map" do
      rows = for i <- 1..50, do: if(rem(i, 7) == 0, do: %{a: i, b: i, c: i}, else: %{a: i, b: i})

      assert calls({:maps, :merge, 2}, fn -> Table.from(rows) end) == []
      {:ok, table} = Table.from(rows)
      assert Table.names(table) == [:a, :b, :c]
      assert Table.column(table, :c) == for(i <- 1..50, do: if(rem(i, 7) == 0, do: i))
    end
  end
end
