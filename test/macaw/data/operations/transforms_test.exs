defmodule Macaw.Data.Operations.TransformsTest do
  # The table operations of spec/04 §4.1–§4.7 and §4.10, ported from visualize's
  # `Chart.TransformTest`, `Chart.DownsampleTest` and `Chart.LatestTest` with their
  # expectations, but for what Macaw changes on purpose:
  #
  # - a step's default column names are strings (`"sum"`), never atoms;
  # - rows go through `Macaw.Data.Table`, so a row missing a column reads it as `nil`, and
  #   a `Date` or an ISO 8601 string in a time column is a `DateTime` at the edge;
  # - a bad option is a validation fault before any step runs (`apply!/4` raises its
  #   words), where visualize's step raised; a bad reading still raises from the step.
  use ExUnit.Case, async: true

  alias Macaw.Data.{Operations, Reduce, Schema, Table}
  alias Macaw.Data.Operations.Transforms

  @registry Operations.registry()
  @rows for i <- 0..5, do: %{t: i, v: rem(i * 7, 5), a: i, b: 5 - i, c: 1, k: "k#{rem(i, 2)}"}

  defp run(node, rows, context \\ %{}),
    do: @registry |> Operations.apply!([node], rows, context) |> Table.rows()

  defp ts(rows), do: Enum.map(rows, & &1.t)

  # Every op's outputs name exactly the columns its run answers, over a fixture.
  defp agrees(node, rows, context \\ %{}) do
    table = Operations.apply!(@registry, [node], rows, context)
    {:ok, input} = Table.from(rows)

    assert {:ok, Operations.columns(table)} ==
             Operations.outputs(@registry, [node], Operations.columns(input), context)

    table
  end

  describe "filter (spec/04 §4.1)" do
    @tag verifies: "operations-filter-tests"
    test "keeps the rows whose reading passes the test, a missing field reading nil" do
      # `v` is 0 2 4 1 3 over `t` 0..4; the last row lacks `v` altogether.
      rows = Enum.take(@rows, 5) ++ [%{t: 5}]
      kept = fn node -> node |> Map.put(:op, "filter") |> run(rows) |> ts() end

      assert kept.(%{field: :v}) == [0, 1, 2, 3, 4]
      assert kept.(%{field: :v, test: :present}) == [0, 1, 2, 3, 4]
      assert kept.(%{field: :v, test: :absent}) == [5]
      assert kept.(%{field: :v, test: :eq, value: 0}) == [0]
      assert kept.(%{field: :v, test: :ne, value: 0}) == [1, 2, 3, 4, 5]
      assert kept.(%{field: :v, test: :lt, value: 2}) == [0, 3]
      assert kept.(%{field: :v, test: :lte, value: 2}) == [0, 1, 3]
      assert kept.(%{field: :v, test: :gt, value: 2}) == [2, 4]
      assert kept.(%{field: :v, test: :gte, value: 2}) == [1, 2, 4]

      # A field the rows never carry: everything under absent, nothing otherwise.
      assert kept.(%{field: :nope, test: :absent}) == [0, 1, 2, 3, 4, 5]
      assert kept.(%{field: :nope}) == []
      assert kept.(%{field: :nope, test: :gte, value: 0}) == []

      # A pure row step: a kept row is the row, and order is kept.
      assert run(%{op: "filter", field: :k, test: :eq, value: "k1"}, @rows) ==
               Enum.filter(@rows, &(&1.k == "k1"))

      agrees(%{op: "filter", field: :v, test: "gt", value: 1}, @rows)
    end

    @tag verifies: "operations-filter-tests"
    test "a category is one value whichever spelling the row or the node gives it" do
      rows = [%{s: :ok}, %{s: "ok"}, %{s: :down}, %{s: nil}]
      assert run(%{op: "filter", field: "s", test: "eq", value: "ok"}, rows) == Enum.take(rows, 2)
      assert run(%{op: "filter", field: "s", test: :ne, value: :ok}, rows) == Enum.drop(rows, 2)
      assert Operations.same?(:ok, "ok") and Operations.same?(2, 2.0)
      refute Operations.same?(nil, "nil") or Operations.same?(true, "true")
    end
  end

  describe "take (spec/04 §4.2)" do
    defp minutes, do: for(i <- 0..10, do: %{t: i * 60, v: i})

    @tag verifies: "operations-take-ends"
    test "is the last or the first n rows, and n beyond the count is every row" do
      assert run(%{op: "take", n: 2}, minutes()) |> ts() == [540, 600]
      assert run(%{op: "take", n: 2, side: :end}, minutes()) |> ts() == [540, 600]
      assert run(%{op: "take", n: 3, side: "start"}, minutes()) |> ts() == [0, 60, 120]
      assert run(%{op: "take", n: 1}, minutes()) |> ts() == [600]
      assert run(%{op: "take", n: 99}, minutes()) == minutes()
      assert run(%{op: "take", n: 0}, minutes()) == []

      assert_raise ArgumentError, "step 1, n: is an integer of at least 0", fn ->
        run(%{op: "take", n: -1}, minutes())
      end

      assert_raise ArgumentError, "step 1, n: is required", fn ->
        run(%{op: "take"}, minutes())
      end

      agrees(%{op: "take", n: 3}, minutes())
    end
  end

  describe "window (spec/04 §4.3)" do
    @tag verifies: "operations-window-spans"
    test "a given to is exclusive, so adjacent windows partition the column" do
      old = run(%{op: "window", field: :t, from: [10, :minute], to: [5, :minute]}, minutes())
      recent = run(%{op: "window", field: :t, from: [5, "minute"]}, minutes())

      assert ts(old) == [0, 60, 120, 180, 240]
      assert ts(recent) == [300, 360, 420, 480, 540, 600]
      assert old ++ recent == minutes()
      agrees(%{op: "window", field: :t, from: [5, :minute]}, minutes())
    end

    @tag verifies: "operations-window-spans"
    test "an absent to closes at now inclusively, and an absent from is open" do
      assert run(%{op: "window", field: :t, from: [1, :minute]}, minutes()) |> ts() == [540, 600]

      # With now in the middle of the data, a future reading is not "the last minute".
      assert run(%{op: "window", field: :t, from: [1, :minute]}, minutes(), %{now: 300}) |> ts() ==
               [240, 300]

      assert run(%{op: "window", field: :t, to: [5, :minute]}, minutes()) |> ts() == [
               0,
               60,
               120,
               180,
               240
             ]

      assert run(%{op: "window", field: :t}, minutes()) == minutes()
    end

    @tag verifies: "operations-window-spans"
    test "now is the context's when given and the newest reading otherwise" do
      assert run(%{op: "window", field: :t, from: [1, :minute]}, minutes()) |> ts() == [540, 600]

      assert run(%{op: "window", field: :t, from: [1, :minute]}, minutes(), %{now: 120}) |> ts() ==
               [60, 120]

      # No row with a reading is no rows, whatever now is.
      assert run(%{op: "window", field: :t, from: [1, :minute]}, [%{v: 1}]) == []
    end

    @tag verifies: "operations-window-spans"
    test "every unit is the seconds it names, an extent of time, not a calendar walk" do
      day = for i <- 0..3, do: %{t: i * 86_400}
      assert run(%{op: "window", field: :t, from: [1, :day]}, day) |> ts() == [172_800, 259_200]

      assert run(%{op: "window", field: :t, from: [2, :day]}, day) |> ts() == [
               86_400,
               172_800,
               259_200
             ]

      units = [second: 1, minute: 60, hour: 3_600, day: 86_400, week: 604_800, year: 31_536_000]

      for {unit, seconds} <- units do
        rows = [%{t: 0}, %{t: seconds}, %{t: 2 * seconds}]

        assert run(%{op: "window", field: :t, from: [1, unit]}, rows) |> ts() == [
                 seconds,
                 2 * seconds
               ]
      end
    end

    @tag verifies: "operations-window-spans"
    test "a window reads the temporal forms a time domain reads" do
      at = fn s -> DateTime.add(~U[2026-01-01 00:00:00.000000Z], s, :second) end
      rows = for i <- 0..4, do: %{t: at.(i * 60)}

      assert run(%{op: "window", field: :t, from: [1, :minute]}, rows) |> ts() == [
               at.(180),
               at.(240)
             ]

      naive = for i <- 0..4, do: %{t: NaiveDateTime.add(~N[2026-01-01 00:00:00], i * 60, :second)}
      assert length(run(%{op: "window", field: :t, from: [1, :minute]}, naive)) == 2

      iso = for i <- 0..4, do: %{t: DateTime.to_iso8601(at.(i * 60))}
      assert length(run(%{op: "window", field: :t, from: [1, :minute]}, iso)) == 2

      # A Date is a DateTime at midnight UTC once the table reads it (spec/01 §1.1), at
      # the Date's own precision: packing keeps it (macaw_data#16).
      dates = for i <- 0..4, do: %{t: Date.add(~D[2026-01-01], i)}

      assert run(%{op: "window", field: :t, from: [1, :day]}, dates) |> ts() ==
               [~U[2026-01-04 00:00:00Z], ~U[2026-01-05 00:00:00Z]]

      # The reading itself, before any table: each form in seconds.
      assert Transforms.seconds!(~D[1970-01-02], :t, "window") == 86_400.0
      assert Transforms.seconds!(~N[1970-01-01 00:01:00], :t, "window") == 60.0
      assert Transforms.seconds!("1970-01-01T00:00:30Z", :t, "window") == 30.0
    end

    @tag verifies: "operations-window-spans"
    test "a reading that is not a time raises, and a bad duration is refused" do
      assert_raise ArgumentError,
                   ~r/^transform "window": :v reads "later", which is not a time/,
                   fn ->
                     run(%{op: "window", field: :v, from: [1, :minute]}, [%{v: "later"}])
                   end

      assert_raise ArgumentError, ~r/^step 1, from: is a duration \[n, unit\]/, fn ->
        run(%{op: "window", field: :t, from: [1, :fortnight]}, minutes())
      end

      assert_raise ArgumentError, ~r/^step 1, from: is a duration/, fn ->
        run(%{op: "window", field: :t, from: 60}, minutes())
      end

      assert_raise ArgumentError, "step 1, field: is required", fn ->
        run(%{op: "window", from: [1, :minute]}, minutes())
      end
    end

    @fleet Schema.new!(%{
             t: %{type: :number, window: true},
             car: %{type: :category, identity: true},
             x: %{type: :number},
             y: %{type: :number}
           })

    @anonymous Schema.new!(%{
                 t: %{type: :number, window: true},
                 car: %{type: :category},
                 x: %{type: :number},
                 y: %{type: :number}
               })

    defp cars(ticks) do
      for t <- ticks,
          {car, i} <- Enum.with_index(["a", "b"]),
          do: %{t: t, car: car, x: t + i, y: t * 2 + i}
    end

    @tag verifies: "operations-window-latest"
    test "latest keeps each declared identity's last row within the window, in order" do
      step = %{op: "window", field: :t, from: [3, :second], latest: true}
      kept = run(step, cars(1..9), %{schema: @fleet})
      assert kept == [%{t: 9, car: "a", x: 9, y: 18}, %{t: 9, car: "b", x: 10, y: 19}]

      # An entity whose last row falls before the window has none.
      older = Enum.reject(cars(1..9), &(&1.car == "b" and &1.t > 4))
      assert [%{car: "a", t: 9}] = run(step, older, %{schema: @fleet})

      # A tie keeps the later row; a row with no identity names nothing.
      tied = [
        %{t: 5, car: "a", x: 1, y: 0},
        %{t: 5, car: "a", x: 2, y: 0},
        %{t: 6, car: nil, x: 3, y: 0}
      ]

      assert run(%{op: "window", field: :t, latest: true}, tied, %{schema: @fleet}) == [
               Enum.at(tied, 1)
             ]

      plain = %{op: "window", field: :t, from: [3, :second]}
      assert run(plain, cars(1..9)) == run(Map.put(plain, :latest, false), cars(1..9))
      assert length(run(plain, cars(1..9))) == 8
    end

    @tag verifies: "operations-window-latest"
    test "latest without a schema, or over one that declares no identity, raises" do
      step = %{op: "window", field: :t, latest: true}

      assert_raise ArgumentError, ~r/latest needs the schema of its rows/, fn ->
        run(step, cars(1..3))
      end

      assert_raise ArgumentError, ~r/declares no identity/, fn ->
        run(step, cars(1..3), %{schema: @anonymous})
      end
    end
  end

  describe "lttb and m4 (spec/04 §4.4, §4.5)" do
    defp wave(count) do
      for i <- 0..(count - 1), do: %{t: i, v: :math.sin(i / 40) * 10 + rem(i * 7919, 13), id: i}
    end

    @tag verifies: "operations-lttb-shape"
    test "lttb is Reduce.lttb/3 over the two columns, keeping whole rows" do
      rows = wave(1_000)
      kept = run(%{op: "lttb", fields: [:t, :v], n: 50}, rows)

      assert kept == Reduce.lttb(rows, 50, &{&1.t, &1.v})
      assert length(kept) == 50
      assert Enum.all?(kept, &(&1 in rows))
      assert run(%{op: "lttb", fields: [:t, :v], n: 20}, wave(20)) == wave(20)
      agrees(%{op: "lttb", fields: [:t, :v], n: 10}, rows)
    end

    @tag verifies: "operations-lttb-shape"
    test "gaps pass through, each run of gaps kept as its first row" do
      rows =
        for i <- 0..39 do
          %{t: i, v: if(i in 15..19, do: nil, else: rem(i * 7, 11))}
        end

      kept = run(%{op: "lttb", fields: [:t, :v], n: 10}, rows)
      assert Enum.filter(kept, &(&1.v == nil)) == [Enum.at(rows, 15)]
      assert kept == Reduce.lttb(rows, 10, &{&1.t, &1.v})
    end

    @tag verifies: "operations-m4-columns"
    test "m4 is Reduce.m4/3 over the two columns, every column's extremes kept" do
      rows = wave(1_000)
      kept = run(%{op: "m4", fields: [:t, :v], width: 30}, rows)
      assert kept == Reduce.m4(rows, 30, &{&1.t, &1.v})

      # Each of the 30 columns over the extent of t keeps its least and greatest reading.
      column = fn row -> min(29, floor(row.t / 999 * 30)) end
      by_column = Enum.group_by(kept, column)

      for {c, members} <- Enum.group_by(rows, column) do
        values = Enum.map(by_column[c], & &1.v)
        assert Enum.min_by(members, & &1.v).v in values
        assert Enum.max_by(members, & &1.v).v in values
      end

      agrees(%{op: "m4", fields: [:t, :v], width: 30}, rows)
    end

    @tag verifies: ["operations-lttb-shape", "operations-m4-columns"]
    test "plot reads the frame's width, whole pixels up" do
      rows = wave(1_000)
      frame = fn width -> %{frame: %{width: width, height: 50, center: [0, 0]}} end
      assert length(run(%{op: "lttb", fields: [:t, :v], n: "plot"}, rows, frame.(72.4))) == 73

      assert run(%{op: "m4", fields: [:t, :v], width: :plot}, rows, frame.(40)) ==
               run(%{op: "m4", fields: [:t, :v], width: 40}, rows)
    end

    @tag verifies: ["operations-lttb-shape", "operations-m4-columns"]
    test "a time column reads in seconds, as window reads one" do
      epoch = ~U[2026-01-01 00:00:00Z]
      timed = for %{t: t} = row <- wave(500), do: %{row | t: DateTime.add(epoch, t)}
      ids = fn rows -> Enum.map(rows, & &1.id) end

      assert ids.(run(%{op: "lttb", fields: [:t, :v], n: 40}, timed)) ==
               ids.(run(%{op: "lttb", fields: [:t, :v], n: 40}, wave(500)))

      assert ids.(run(%{op: "m4", fields: [:t, :v], width: 25}, timed)) ==
               ids.(run(%{op: "m4", fields: [:t, :v], width: 25}, wave(500)))
    end

    @tag verifies: ["operations-lttb-shape", "operations-m4-columns"]
    test "the faults: bad options before the step, bad readings from it" do
      rows = wave(20)

      for {node, words} <- [
            {%{op: "lttb", fields: [:t, :v], n: 2}, "step 1, n: is an integer of at least 3"},
            {%{op: "m4", fields: [:t, :v], width: 0},
             "step 1, width: is an integer of at least 1"},
            {%{op: "lttb", fields: [:t, :v], n: "10"}, "step 1, n: is an integer of at least 3"},
            {%{op: "m4", fields: [:t], width: 10},
             "step 1, fields: is a pair, each a field name"},
            {%{op: "lttb", fields: [:t, :v]}, "step 1, n: is required"},
            {%{op: "lttb", fields: [:t, :v], n: "plot"},
             "step 1, n: needs a frame, which the caller does not give"}
          ] do
        assert_raise ArgumentError, words, fn -> run(node, rows) end
      end

      assert_raise ArgumentError,
                   ~r/^transform "lttb": :v reads "x", which is not a number/,
                   fn ->
                     run(%{op: "lttb", fields: [:t, :v], n: 3}, [
                       %{t: 0, v: 1},
                       %{t: 1, v: "x"},
                       %{t: 2, v: 1},
                       %{t: 3, v: 0}
                     ])
                   end

      # A category reads back as the string that spells it (macaw_data#16).
      assert_raise ArgumentError, ~r/^transform "m4": :t reads "soon", which is not a time/, fn ->
        run(%{op: "m4", fields: [:t, :v], width: 3}, [%{t: :soon, v: 1}])
      end
    end

    @tag verifies: ["operations-lttb-shape", "operations-m4-columns"]
    test "both declare themselves reducers" do
      assert Transforms.Lttb.reduces() == {"n", 1}
      assert Transforms.M4.reduces() == {"width", 4}
    end
  end

  describe "sort (spec/04 §4.6)" do
    @tag verifies: "operations-sort-stable"
    test "sort is stable, ascending by default or descending" do
      sorted = run(%{op: "sort", field: :v, order: :descending}, @rows)
      assert Enum.map(sorted, & &1.v) == [4, 3, 2, 1, 0, 0]
      assert ts(sorted) == [2, 4, 1, 3, 0, 5]

      ascending = run(%{op: "sort", field: "v"}, @rows)
      assert ts(ascending) == [0, 5, 3, 1, 4, 2]
      agrees(%{op: "sort", field: :v, order: "descending"}, @rows)
    end
  end

  describe "fold (spec/04 §4.7)" do
    @tag verifies: "operations-fold-long"
    test "turns wide columns into long rows, skipping listed columns the rows lack" do
      wide = [%{hour: 0, cpu: 1, mem: 2}, %{hour: 1, cpu: 3}, %{hour: 2, mem: nil, cpu: 5}]

      # A category reads back as the string that spells it (macaw_data#16).
      assert run(%{op: "fold", fields: [:cpu, :mem, :disk]}, wide) == [
               %{:hour => 0, "key" => "cpu", "value" => 1},
               %{:hour => 0, "key" => "mem", "value" => 2},
               %{:hour => 1, "key" => "cpu", "value" => 3},
               %{:hour => 2, "key" => "cpu", "value" => 5}
             ]

      # The order within a row is the author's; as names the two columns.
      assert run(%{op: "fold", fields: [:mem, :cpu], as: [:series, :v]}, Enum.take(wide, 1)) == [
               %{hour: 0, series: "mem", v: 2},
               %{hour: 0, series: "cpu", v: 1}
             ]

      assert_raise ArgumentError, "step 1, as: is a pair, each a column name", fn ->
        run(%{op: "fold", fields: [:cpu], as: :key}, wide)
      end

      table = agrees(%{op: "fold", fields: [:cpu, :mem]}, wide)

      assert Table.column_type(table, "value") == :number and
               Table.column_type(table, "key") == :category
    end
  end

  describe "aggregate and sum (spec/04 §4.10)" do
    @tag verifies: "operations-group-rows"
    test "sum groups by first appearance, or makes one row without by" do
      assert run(%{op: "sum", field: :a, by: :k}, @rows) == [
               %{:k => "k0", "sum" => 6},
               %{:k => "k1", "sum" => 9}
             ]

      assert run(%{op: "sum", field: :a, as: :total}, @rows) == [%{total: 15}]
      assert run(%{op: "sum", field: :a}, []) == [%{"sum" => 0}]

      assert run(%{op: "sum", field: :a, by: :k}, @rows) ==
               run(%{op: "aggregate", field: :a, fn: "sum", by: :k}, @rows)

      agrees(%{op: "sum", field: :a, by: :k}, @rows)
    end

    @tag verifies: "operations-group-rows"
    test "aggregate applies the named statistic per group, nils dropped, by one field or several" do
      rows = [
        %{host: "a", role: :web, ms: 10},
        %{host: "b", role: :db, ms: 30},
        %{host: "a", role: :web, ms: nil},
        %{host: "a", role: :db, ms: 50},
        %{host: nil, role: :web, ms: 7}
      ]

      assert run(%{op: "aggregate", field: :ms, fn: "mean", by: :host}, rows) == [
               %{:host => "a", "mean" => 30.0},
               %{:host => "b", "mean" => 30.0},
               %{:host => nil, "mean" => 7.0}
             ]

      assert run(
               %{
                 op: "aggregate",
                 field: :ms,
                 fn: "quantile",
                 p: 1,
                 by: [:host, :role],
                 as: "p100"
               },
               rows
             ) == [
               # A category reads back as the string that spells it (macaw_data#16).
               %{:host => "a", :role => "web", "p100" => 10.0},
               %{:host => "b", :role => "db", "p100" => 30.0},
               %{:host => "a", :role => "db", "p100" => 50.0},
               %{:host => nil, :role => "web", "p100" => 7.0}
             ]

      assert run(%{op: "aggregate", field: :ms, fn: "count"}, rows) == [%{"count" => 4}]

      assert_raise ArgumentError, "step 1, p: is required", fn ->
        run(%{op: "aggregate", field: :ms, fn: "quantile"}, rows)
      end

      assert_raise ArgumentError, "step 1, p: is not read by sum", fn ->
        run(%{op: "sum", field: :ms, p: 0.5}, rows)
      end

      table = agrees(%{op: "aggregate", field: :ms, fn: "max", by: :role}, rows)
      assert Operations.columns(table) == [{:role, :category}, {"max", :number}]
    end

    @tag verifies: "operations-group-rows"
    test "a pair field reads points, a time x in seconds, for slope" do
      epoch = ~U[2026-01-01 00:00:00Z]
      rows = for s <- [0, 10, 20, 30], do: %{t: DateTime.add(epoch, s), v: s * 2, k: "x"}

      assert [%{"slope" => slope}] = run(%{op: "aggregate", field: [:t, :v], fn: "slope"}, rows)
      assert_in_delta slope, 2.0, 1.0e-9

      gapped = [%{t: 0, v: 1}, %{t: 1, v: nil}, %{t: nil, v: 5}, %{t: 2, v: 3}]
      assert [%{"slope" => 1.0}] = run(%{op: "aggregate", field: [:t, :v], fn: "slope"}, gapped)
    end
  end

  describe "the package" do
    @tag verifies: "operations-table-package"
    test "the twelve table operations are macaw_data's transforms, every one needing nothing" do
      assert Enum.map(Transforms.all(), & &1.name()) ==
               ~w(filter take window lttb m4 sort fold stack bin aggregate sum spectrum)

      for module <- Transforms.all() do
        assert module.needs() == []
        assert Operations.transform(@registry, module.name()) == {:ok, module}
      end
    end
  end
end
