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
  use ExUnitProperties

  alias Macaw.Data.{Native, Operations, Reduce, Schema, Table}
  alias Macaw.Data.Operations.Transforms

  @registry Operations.registry()
  @rows for i <- 0..5, do: %{t: i, v: rem(i * 7, 5), a: i, b: 5 - i, c: 1, k: "k#{rem(i, 2)}"}

  defp run(node, rows, context \\ %{}),
    do: @registry |> Operations.apply!([node], rows, context) |> Table.rows!()

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

    # The rows of a one-column table an ordering keeps, chunked `size` rows a chunk.
    defp refused(type, readings, test, value) do
      table = Table.new!([{"t", type, readings}])
      Operations.apply(@registry, [%{op: "filter", field: "t", test: test, value: value}], table)
    end

    defp ordered(type, readings, test, value, size \\ :one) do
      table = Table.new!([{"t", type, readings}]) |> Macaw.Data.Test.Storage.chunked(size)

      @registry
      |> Operations.apply!([%{op: "filter", field: "t", test: test, value: value}], table)
      |> Table.column("t")
    end

    @tag verifies: "operations-filter-typed"
    test "a time compares by its instant against a DateTime, a Date or an ISO string, never as a map" do
      # #96's reproduction: under term order `lt` 2026-01-01 kept none and `gt` all four.
      times = [
        ~U[2026-10-02 00:00:00Z],
        ~U[2026-09-30 00:00:00Z],
        ~U[2026-10-01 00:00:00Z],
        ~U[2025-12-31 00:00:00Z],
        nil
      ]

      for value <- [~U[2026-01-01 00:00:00Z], ~D[2026-01-01], "2026-01-01T00:00:00Z"],
          size <- [:one, 1, 2] do
        assert ordered(:time, times, :lt, value, size) == [~U[2025-12-31 00:00:00Z]]
        assert ordered(:time, times, :gte, value, size) == Enum.take(times, 3)
      end

      # Equal instants: lte and gte keep the reading, whatever its zone or precision.
      at = ~U[2026-09-30 00:00:00.000000Z]

      assert ordered(:time, times, :lte, at) == [
               ~U[2026-09-30 00:00:00Z],
               ~U[2025-12-31 00:00:00Z]
             ]

      assert ordered(:time, times, :gt, "2026-09-30T02:00:00+02:00") ==
               [~U[2026-10-02 00:00:00Z], ~U[2026-10-01 00:00:00Z]]

      # Naive and date columns, and a mix, by instant: a wall clock and a midnight.
      naive = [~N[2030-01-01 00:00:00], ~N[2025-01-01 00:00:00]]
      assert ordered(:time, naive, :gt, ~U[2026-01-01 00:00:00Z]) == [~N[2030-01-01 00:00:00]]
      dates = [~D[2026-01-02], ~D[2025-12-31], ~D[2026-01-01]]
      assert ordered(:time, dates, :gte, "2026-01-01") == [~D[2026-01-02], ~D[2026-01-01]]
      mixed = [~N[2030-01-01 00:00:00], ~D[2020-01-01], ~U[2026-06-01 00:00:00Z]]
      assert ordered(:time, mixed, :lt, ~D[2027-01-01]) == Enum.drop(mixed, 1)
    end

    @tag verifies: "operations-filter-typed"
    property "over generated instants, an ordering keeps exactly the rows DateTime.compare/2 says" do
      check all(
              kind <- member_of([DateTime, NaiveDateTime, Date]),
              seconds <-
                list_of(one_of([constant(nil), integer(-4_000_000_000..4_000_000_000)]),
                  min_length: 1,
                  max_length: 80
                ),
              at <-
                one_of([
                  integer(-4_000_000_000..4_000_000_000),
                  map(integer(-46_000..46_000), &(&1 * 86_400))
                ]),
              test <- member_of([:lt, :lte, :gt, :gte]),
              size <- member_of([:one, 1, 5, 32])
            ) do
        # A UTC, a naive (wall clock) or a date (midnight) column, gaps among it.
        as = fn t ->
          case kind do
            DateTime -> t
            NaiveDateTime -> DateTime.to_naive(t)
            Date -> DateTime.to_date(t)
          end
        end

        times = Enum.map(seconds, &(&1 && as.(DateTime.from_unix!(&1))))
        value = DateTime.from_unix!(at)
        wanted = %{lt: [:lt], lte: [:lt, :eq], gt: [:gt], gte: [:gt, :eq]}[test]

        expected =
          Enum.filter(times, &(&1 && DateTime.compare(Table.at_edge(:time, &1), value) in wanted))

        assert ordered(:time, times, test, value, size) == expected
        assert Native.elixir(fn -> ordered(:time, times, test, value, size) end) == expected
      end
    end

    @tag verifies: "operations-filter-typed"
    test "numbers by value, text and a category by spelling; a reading of no value for its type never passes" do
      assert ordered(:number, [3, 2.5, nil, -1, 10], :gte, 2.5) == [3, 2.5, 10]
      assert ordered(:text, ["b", "a", nil, 7, "c"], :gt, "a") == ["b", "c"]
      assert ordered(:category, [:ok, "bad", nil, "warn"], :lt, :ok) == ["bad"]
      assert ordered(:category, [:ok, "bad", "warn"], :gte, "ok") == ["ok", "warn"]
    end

    # The rows (by their place) of a table of readings `t`, chunked `size` rows a chunk,
    # that a filter keeps.
    defp kept(type, readings, test, value, size) do
      table =
        Table.new!([
          {"t", type, readings},
          {"i", :number, Enum.to_list(0..(length(readings) - 1))}
        ])
        |> Macaw.Data.Test.Storage.chunked(size)

      @registry
      |> Operations.apply!([%{op: "filter", field: "t", test: test, value: value}], table)
      |> Table.column("i")
    end

    defp east(utc),
      do: %{DateTime.add(utc, 3600) | utc_offset: 3600, time_zone: "Etc/GMT-1", zone_abbr: "+01"}

    defp instants(times), do: Enum.map(times, &(&1 && Macaw.Data.Source.Order.instant(&1)))

    # #102's reproduction: one instant written in another zone or at another precision is
    # `lte` and `gte` the value, and was not `eq` it.
    @tag verifies: "operations-filter-equal"
    test "eq and ne compare a time by its instant, whatever its zone, precision or kind" do
      at = ~U[2026-01-01 00:00:00Z]
      later = ~U[2026-01-02 00:00:00Z]
      times = [at, later, nil, east(at)]

      for value <- [
            at,
            east(at),
            ~U[2026-01-01 00:00:00.000000Z],
            "2026-01-01T01:00:00+01:00",
            ~N[2026-01-01 00:00:00],
            ~D[2026-01-01]
          ],
          size <- [:one, 1, 3] do
        assert kept(:time, times, :eq, value, size) == [0, 3]
        assert kept(:time, times, :ne, value, size) == [1, 2]
        assert Native.elixir(fn -> kept(:time, times, :eq, value, size) end) == [0, 3]
      end

      # Naive and date columns against a DateTime: a wall clock, a midnight.
      naive = [~N[2026-01-01 00:00:00], ~N[2026-01-01 00:00:01], nil]
      assert instants(ordered(:time, naive, :eq, at)) == instants([at])

      assert ordered(:time, [~D[2026-01-01], ~D[2026-01-02], nil], :ne, at) == [
               ~D[2026-01-02],
               nil
             ]

      assert instants(ordered(:time, [~D[2026-01-01], later], :eq, east(at))) == instants([at])
    end

    @tag verifies: "operations-filter-equal"
    property "on every kind of time column, lte and gte both hold exactly when eq does, as DateTime.compare/2 says" do
      check all(
              kind <- member_of([:utc, :zoned, :naive, :date]),
              steps <-
                list_of(one_of([constant(nil), integer(-12..12)]), min_length: 1, max_length: 60),
              at <- integer(-12..12),
              spelling <- member_of([:utc, :zoned, :naive, :date, :iso, :micro]),
              size <- member_of([:one, 1, 5, 32])
            ) do
        # A date column's readings are midnights; the others step by the hour.
        unit = if kind == :date or spelling == :date, do: 86_400, else: 3600
        utc = &DateTime.from_unix!(&1 * unit)

        as = fn t, spelled ->
          case spelled do
            :utc -> t
            :zoned -> east(t)
            :naive -> DateTime.to_naive(t)
            :date -> DateTime.to_date(t)
            :iso -> t |> east() |> DateTime.to_iso8601()
            :micro -> %{t | microsecond: {0, 6}}
          end
        end

        times = Enum.map(steps, &(&1 && as.(utc.(&1), kind)))
        value = as.(utc.(at), spelling)
        edge = &Table.at_edge(:time, &1)

        expected =
          for {t, i} <- Enum.with_index(times),
              t != nil and DateTime.compare(edge.(t), edge.(value)) == :eq,
              do: i

        eq = kept(:time, times, :eq, value, size)

        both =
          MapSet.intersection(
            MapSet.new(kept(:time, times, :lte, value, size)),
            MapSet.new(kept(:time, times, :gte, value, size))
          )

        assert eq == expected
        assert eq == Enum.sort(both)
        assert kept(:time, times, :ne, value, size) == Enum.to_list(0..(length(times) - 1)) -- eq
        assert Native.elixir(fn -> kept(:time, times, :eq, value, size) end) == eq

        assert Native.elixir(fn -> kept(:time, times, :ne, value, size) end) ==
                 Enum.to_list(0..(length(times) - 1)) -- eq
      end
    end

    # A number by its value, as the orderings compare it (spec/04 §4.1): 1 is 1.0 and 0.0
    # is -0.0, so lte and gte cannot both hold where eq does not.
    @tag verifies: "operations-filter-equal"
    property "on a number column, lte and gte both hold exactly when eq does, 1 and 1.0 alike" do
      number = one_of([integer(-3..3), map(integer(-3..3), &(&1 * 1.0)), constant(-0.0)])

      check all(
              values <-
                list_of(
                  one_of([constant(nil), number, Macaw.Data.Test.Gen.float(min: -3.0, max: 3.0)]),
                  min_length: 1,
                  max_length: 60
                ),
              value <- number,
              size <- member_of([:one, 1, 5, 32])
            ) do
        expected = for {v, i} <- Enum.with_index(values), v != nil and v == value, do: i
        eq = kept(:number, values, :eq, value, size)

        both =
          MapSet.intersection(
            MapSet.new(kept(:number, values, :lte, value, size)),
            MapSet.new(kept(:number, values, :gte, value, size))
          )

        assert eq == expected
        assert eq == Enum.sort(both)
        assert Native.elixir(fn -> kept(:number, values, :eq, value, size) end) == eq
      end
    end

    @tag verifies: "operations-filter-equal"
    test "eq and ne on a time column refuse a value with no instant; on a number column another kind equals none" do
      for value <- [1_767_225_600, "yesterday", nil], test <- [:eq, :ne] do
        run = fn -> refused(:time, [~U[2026-01-01 00:00:00Z]], test, value) end
        assert run.() == {:error, [{[0, "value"], {:reading, :time}}]}
        assert Native.elixir(run) == run.()
      end

      assert_raise Macaw.Data.Error, "step 1, value: is no value of the field's type, time", fn ->
        ordered(:time, [~U[2026-01-01 00:00:00Z]], :eq, "yesterday")
      end

      assert ordered(:number, [1, 2], :eq, "1") == []
      assert ordered(:number, [1, 2], :ne, "1") == [1, 2]
      assert ordered(:number, [1, nil], :eq, nil) == [nil]
    end

    @tag verifies: "operations-filter-typed"
    test "a value of another kind is refused before any row is read; a column the rows lack keeps none" do
      for {type, readings, value} <- [
            {:time, [~U[2026-01-01 00:00:00Z]], 1_767_225_600},
            {:time, [~U[2026-01-01 00:00:00Z]], "yesterday"},
            {:number, [1, 2], "2"},
            {:number, [1, 2], ~U[2026-01-01 00:00:00Z]},
            {:text, ["a"], :a},
            {:number, [1], nil}
          ] do
        assert refused(type, readings, :lt, value) == {:error, [{[0, "value"], {:reading, type}}]}
      end

      assert run(%{op: "filter", field: :nope, test: :lt, value: nil}, @rows) == []
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

      assert_raise Macaw.Data.Error, "step 1, n: is an integer of at least 0", fn ->
        run(%{op: "take", n: -1}, minutes())
      end

      assert_raise Macaw.Data.Error, "step 1, n: is required", fn ->
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
    test "a reading that is not a time is the step's fault, and a bad duration is refused" do
      step = %{op: "window", field: :v, from: [1, :minute]}

      assert Operations.apply(@registry, [step], [%{v: "later"}]) ==
               {:error, [{[0, "field"], {:reads, :time}}]}

      assert Operations.apply(@registry, [step], [%{v: 1}], %{now: "soon"}) ==
               {:error, [{[0, "op"], {:context, :now, :time}}]}

      assert_raise Macaw.Data.Error,
                   "step 1, field: reads a value that is not a time or a number",
                   fn ->
                     run(step, [%{v: "later"}])
                   end

      assert_raise Macaw.Data.Error, ~r/^step 1, from: is a duration \[n, unit\]/, fn ->
        run(%{op: "window", field: :t, from: [1, :fortnight]}, minutes())
      end

      assert_raise Macaw.Data.Error, ~r/^step 1, from: is a duration/, fn ->
        run(%{op: "window", field: :t, from: 60}, minutes())
      end

      assert_raise Macaw.Data.Error, "step 1, field: is required", fn ->
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
    test "latest without a schema, or over one that declares no identity, is the step's fault" do
      step = %{op: "window", field: :t, latest: true}

      assert Operations.apply(@registry, [step], cars(1..3)) ==
               {:error, [{[0, "latest"], {:needs, :schema}}]}

      assert Operations.apply(@registry, [step], cars(1..3), %{schema: @anonymous}) ==
               {:error, [{[0, "latest"], {:needs, :identity}}]}

      assert_raise Macaw.Data.Error,
                   "step 1, latest: needs a schema, which the caller does not give",
                   fn ->
                     run(step, cars(1..3))
                   end
    end
  end

  describe "lttb and m4 (spec/04 §4.4, §4.5)" do
    defp wave(count) do
      for i <- 0..(count - 1), do: %{t: i, v: :math.sin(i / 40) * 10 + rem(i * 7919, 13), id: i}
    end

    @tag verifies: "operations-lttb-shape"
    test "lttb keeps the ends and at most n whole rows of the two columns" do
      rows = wave(1_000)
      kept = run(%{op: "lttb", fields: [:t, :v], n: 50}, rows)

      assert length(kept) == 50
      assert hd(kept) == hd(rows) and List.last(kept) == List.last(rows)
      assert Enum.all?(kept, &(&1 in rows))
      assert kept == Enum.filter(rows, &(&1 in kept))
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
    test "m4 keeps every column's extremes where the buckets' edges are the pixels'" do
      # t over [0, 960] in 30 columns: a pixel is 32 wide, a bucket 8, so their edges meet.
      rows = wave(961)
      kept = run(%{op: "m4", fields: [:t, :v], width: 30}, rows)
      assert kept == Reduce.m4(rows, 30, &{&1.t, &1.v})

      column = fn row -> min(29, floor(row.t / 32)) end
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
    test "a time column under a linear scale reads in seconds, as window reads one" do
      epoch = ~U[2026-01-01 00:00:00Z]
      timed = for %{t: t} = row <- wave(500), do: %{row | t: DateTime.add(epoch, t)}
      ids = fn rows -> Enum.map(rows, & &1.id) end
      linear = %{scale: :linear}

      assert ids.(run(%{op: "lttb", fields: [:t, :v], n: 40}, timed, linear)) ==
               ids.(run(%{op: "lttb", fields: [:t, :v], n: 40}, wave(500)))

      assert ids.(run(%{op: "m4", fields: [:t, :v], width: 25}, timed, linear)) ==
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
        assert_raise Macaw.Data.Error, words, fn -> run(node, rows) end
      end

      bad_y = [%{t: 0, v: 1}, %{t: 1, v: "x"}, %{t: 2, v: 1}, %{t: 3, v: 0}]

      assert Operations.apply(@registry, [%{op: "lttb", fields: [:t, :v], n: 3}], bad_y) ==
               {:error, [{[0, "fields"], {:reads, :number}}]}

      # A category is no time, in either spelling (macaw_data#16).
      assert Operations.apply(@registry, [%{op: "m4", fields: [:t, :v], width: 3}], [
               %{t: :soon, v: 1}
             ]) == {:error, [{[0, "fields"], {:reads, :time}}]}

      # A log scale reads an x above zero; a scale the step does not know is the context's.
      log = %{scale: :log}
      at_zero = [%{t: 0, v: 1}, %{t: 1, v: 2}, %{t: 2, v: 1}, %{t: 3, v: 0}]

      assert Operations.apply(@registry, [%{op: "m4", fields: [:t, :v], width: 3}], at_zero, log) ==
               {:error, [{[0, "fields"], {:reads, :positive}}]}

      assert Operations.apply(@registry, [%{op: "m4", fields: [:t, :v], width: 3}], at_zero, %{
               scale: :radial
             }) == {:error, [{[0, "op"], {:unknown, :scale, :radial}}]}

      assert_raise Macaw.Data.Error, "step 1, fields: reads a value that is not a number", fn ->
        run(%{op: "lttb", fields: [:t, :v], n: 3}, bad_y)
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

      # A nil reading sorts last in either direction, in its input order.
      gappy = [%{t: 0}, %{t: 1, v: 2}, %{t: 2}, %{t: 3, v: 1}]
      assert ts(run(%{op: "sort", field: :v}, gappy)) == [3, 1, 0, 2]
      assert ts(run(%{op: "sort", field: :v, order: :descending}, gappy)) == [1, 3, 0, 2]
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

      assert_raise Macaw.Data.Error, "step 1, as: is a pair, each a column name", fn ->
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

      assert_raise Macaw.Data.Error, "step 1, p: is required", fn ->
        run(%{op: "aggregate", field: :ms, fn: "quantile"}, rows)
      end

      assert_raise Macaw.Data.Error, "step 1, p: is not read by sum", fn ->
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
