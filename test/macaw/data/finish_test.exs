defmodule Macaw.Data.FinishTest do
  @moduledoc "Windows and finishing (spec/01 §2.4, §6): Macaw does what a source did not."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table, Window}
  alias Macaw.Data.Source.{Description, Finish, Request}

  doctest Window
  doctest Finish

  @now ~U[2026-10-27 12:00:00Z]

  defp request(fields), do: Request.new!([now: @now] ++ fields)
  defp described(schema, supports \\ []), do: Description.new!(schema: schema, supports: supports)
  defp ts(delivery, field \\ "t"), do: Table.column(delivery |> Delivery.table!(), field)

  @numbers Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})
  @hundred Delivery.new(for(t <- 1..100, do: %{"t" => t, "v" => rem(t * 7, 5)}),
             served: [window: [1, 100]]
           )

  @tag verifies: "finish-window"
  test "a window the source did not honor is trimmed and served; an honored one is not" do
    d = Finish.finish(@hundred, described(@numbers), request(window: [10, 15]))
    assert ts(d) == Enum.to_list(10..15)
    assert d.served.window == [10, 15]

    open = Finish.finish(@hundred, described(@numbers), request(window: [98, nil]))
    assert ts(open) == [98, 99, 100]
    assert open.served.window == [98, 100]

    assert Finish.finish(@hundred, described(@numbers, [:window]), request(window: [10, 15])) ==
             @hundred

    assert Finish.finish(@hundred, described(@numbers), request([])) == @hundred
  end

  @tag verifies: "finish-window"
  test "a time window trims by DateTime; a window the schema cannot answer is the caller's error" do
    schema = Schema.new!(%{"at" => %{type: :time}, "v" => %{type: :number}})
    rows = for h <- 0..5, do: %{"at" => DateTime.add(@now, h * 3600), "v" => h}

    d =
      Finish.finish(
        Delivery.new(rows),
        described(schema),
        request(window: [DateTime.add(@now, 3600), DateTime.add(@now, 7200)])
      )

    assert Table.column(d |> Delivery.table!(), "v") == [1, 2]

    assert_raise ArgumentError, ~r/cannot answer/, fn ->
      Finish.finish(Delivery.new(rows), described(schema), request(window: [0, 1]))
    end
  end

  @tag verifies: "finish-box"
  test "a box over a point window field keeps the positions in it, across the antimeridian too" do
    schema = Schema.new!(%{"at" => %{type: :point, window: true}, "name" => %{type: :text}})

    places = [
      %{"at" => {2.35, 48.86}, "name" => "Paris"},
      %{"at" => {-74.0, 40.7}, "name" => "New York"},
      %{"at" => {179.0, -17.7}, "name" => "Suva"},
      %{"at" => {-179.9, -16.5}, "name" => "Taveuni"},
      %{"at" => nil, "name" => "nowhere"}
    ]

    d = Delivery.new(places, types: %{"at" => :point})
    europe = %{west: -10, south: 35, east: 30, north: 60}
    fiji = %{west: 175, south: -20, east: -175, north: -15}

    assert Table.column(
             Finish.finish(d, described(schema), request(box: europe)) |> Delivery.table!(),
             "name"
           ) ==
             ["Paris"]

    assert Table.column(
             Finish.finish(d, described(schema), request(box: fiji)) |> Delivery.table!(),
             "name"
           ) ==
             ["Suva", "Taveuni"]

    assert Finish.finish(d, described(schema), request(box: europe)).served.window == europe
    assert Finish.finish(d, described(schema, [:box]), request(box: europe)) == d

    assert_raise ArgumentError, fn ->
      Finish.finish(@hundred, described(@numbers), request(box: europe))
    end
  end

  @tag verifies: "finish-region"
  test "a region trims each ranged field, the window field among them; a refused region names why" do
    d =
      Finish.finish(
        @hundred,
        described(@numbers),
        request(region: %{"t" => [1, 20], "v" => [3, 4]})
      )

    assert Enum.all?(Delivery.rows(d), &(&1["t"] <= 20 and &1["v"] in [3, 4]))
    assert length(Delivery.rows(d)) == 8

    assert Finish.finish(
             @hundred,
             described(@numbers, [:region]),
             request(region: %{"v" => [3, 4]})
           ) == @hundred

    schema = Schema.new!(%{"t" => %{type: :number, window: true}, "s" => %{type: :category}})

    assert Window.check(
             request(region: %{"t" => [9, 1], "s" => ["a", "b"], "z" => [0, 1]}),
             schema
           ) ==
             {:error,
              [
                {[:region, "s"], {:invalid_for, :category}},
                {[:region, "t"], {:window, :inverted}},
                {[:region, "z"], {:window, :unknown_field}}
              ]}
  end

  @tag verifies: "finish-latest"
  test "latest keeps each identity's latest row by the window field; it needs an identity and a window field" do
    schema =
      Schema.new!(%{
        "t" => %{type: :number, window: true},
        "host" => %{type: :category, identity: true},
        "v" => %{type: :number}
      })

    rows = [
      %{"t" => 1, "host" => "a", "v" => 1},
      %{"t" => 2, "host" => "b", "v" => 2},
      %{"t" => 3, "host" => "a", "v" => 3},
      %{"t" => 3, "host" => nil, "v" => 9}
    ]

    d = Finish.finish(Delivery.new(rows), described(schema), request(latest: true))

    assert Delivery.rows(d) == [
             %{"t" => 2, "host" => "b", "v" => 2},
             %{"t" => 3, "host" => "a", "v" => 3}
           ]

    assert Finish.finish(Delivery.new(rows), described(schema, [:latest]), request(latest: true)) ==
             Delivery.new(rows)

    assert Window.check(request(latest: true), @numbers) ==
             {:error, [{[:latest], {:window, :no_identity}}]}

    assert Window.check(
             request(latest: true),
             Schema.new!(%{"id" => %{type: :text, identity: true}})
           ) ==
             {:error, [{[:latest], {:window, :no_window_field}}]}

    places =
      Schema.new!(%{
        "at" => %{type: :point, window: true},
        "id" => %{type: :text, identity: true}
      })

    assert Window.check(request(latest: true), places) ==
             {:error, [{[:latest], {:invalid_for, :point}}]}
  end

  @tag verifies: "finish-budget"
  test "a budget the source did not honor is reduced by Macaw, recorded :runtime; series share it" do
    d = Finish.finish(@hundred, described(@numbers), request(budget: 10))
    assert Table.size(d |> Delivery.table!()) == 10
    assert d.served.reduced_by == :runtime
    assert hd(ts(d)) == 1 and List.last(ts(d)) == 100

    assert Finish.finish(@hundred, described(@numbers, [:budget]), request(budget: 10)) ==
             @hundred

    assert Finish.finish(@hundred, described(@numbers), request(budget: 500)) == @hundred

    by_host =
      Schema.new!(%{
        "t" => %{type: :number, window: true},
        "s" => %{type: :category},
        "v" => %{type: :number}
      })

    rows = for t <- 1..100, s <- ["a", "b"], do: %{"t" => t, "s" => s, "v" => :math.sin(t / 5)}
    d = Finish.finish(Delivery.new(rows), described(by_host), request(budget: 20))
    counts = d |> Delivery.rows() |> Enum.frequencies_by(& &1["s"])
    assert counts["a"] > 0 and counts["b"] > 0 and Table.size(d |> Delivery.table!()) <= 20

    m4 = Finish.reduce(@hundred, @numbers, 12, :m4)
    assert Table.size(m4 |> Delivery.table!()) <= 12 and m4.served.reduced_by == :runtime
  end

  @tag verifies: "finish-only-removes"
  property "finishing never widens the window, never adds a row, and keeps at most the budget" do
    check all(
            n <- integer(0..120),
            from <- one_of([constant(nil), integer(0..120)]),
            to <- one_of([constant(nil), integer(0..120)]),
            budget <- one_of([constant(nil), integer(1..50)])
          ) do
      rows = for t <- 1..n//1, do: %{"t" => t, "v" => rem(t * 13, 7)}
      d = Delivery.new(rows, types: %{"t" => :number, "v" => :number})

      finished =
        Finish.finish(d, described(@numbers), request(window: [from, to], budget: budget))

      kept = Delivery.rows(finished)

      assert Enum.all?(kept, &(&1 in rows))
      assert Enum.all?(kept, &Window.within?(&1["t"], [from, to]))
      if budget, do: assert(length(kept) <= budget)
    end
  end

  @tag verifies: "finish-ceiling-pool"
  test "the host ceiling clamps a budget, a page may lower it, and a pooled fetch asks the largest" do
    assert Finish.ceiling(500, host: 10_000) == {500, false}
    assert Finish.ceiling(50_000, host: 10_000) == {10_000, true}
    assert Finish.ceiling(nil, host: 10_000) == {10_000, false}
    assert Finish.ceiling(5_000, host: 10_000, page: 2_000) == {2_000, true}
    assert Finish.ceiling(5_000, host: 1_000, page: 2_000) == {1_000, true}

    assert Finish.pooled([100, 4_000, 250]) == 4_000
    assert Finish.pooled([100, nil]) == nil

    # Each reader of a pooled delivery is reduced to its own budget.
    pooled =
      Finish.finish(@hundred, described(@numbers), request(budget: Finish.pooled([60, 15])))

    assert Table.size(Finish.reduce(pooled, @numbers, 15) |> Delivery.table!()) == 15
  end

  @tag verifies: "window-arithmetic"
  test "times compare by kind; positions, intersections and the seams" do
    assert Window.compare(1, 1.0) == :eq
    assert Window.compare(~D[2026-01-01], ~D[2026-01-02]) == :lt
    assert Window.intersect([0, 10], [5, nil]) == [5, 10]
    assert Window.intersect(nil, [1, 2]) == [1, 2]
    assert Window.position(~U[1970-01-01 00:00:01Z]) == 1_000_000
    assert Window.position(~D[0000-01-03]) == 2
    assert Window.position("x") == nil
    assert Window.newer([%{t: 1}, %{t: 5}, %{t: 9}], :t, 5) == [%{t: 9}]
    assert Window.within?(nil, [0, 1]) == false
    assert Window.applies?([0, 10], :number) and Window.applies?(nil, :time)
    refute Window.applies?([0, ~D[2026-01-01]], :number)
    assert Window.instant?(~N[2026-01-01 00:00:00])
    refute Window.instant?(1)
    assert Window.time?(1) and not Window.time?("1")
    refute Window.in_box?(nil, %{west: 0, south: 0, east: 1, north: 1})
  end

  # A delivery keeps the rows its source gave (macaw#185): finishing removes rows from
  # them in their own form, and never packs a row list into a table.
  @tag verifies: "finish-keeps-form"
  test "finishing keeps the rows' form: a row list stays rows, values untouched; tuple rows are named" do
    rows = for t <- 1..20, do: %{"t" => t, "v" => t * 2, "at" => ~N[2026-10-29 00:00:00]}
    d = Finish.finish(Delivery.new(rows), described(@numbers), request(window: [5, 7]))

    assert is_list(d.rows)
    assert d.rows == Enum.slice(rows, 4, 3)
    assert Enum.all?(d.rows, &is_integer(&1["v"]))
    assert hd(d.rows)["at"] == ~N[2026-10-29 00:00:00]

    tuples = for t <- 1..20, do: {t, t * 2}

    named =
      Finish.finish(
        Delivery.new(tuples, names: ["t", "v"]),
        described(@numbers),
        request(window: [5, 7])
      )

    assert named.rows == [%{"t" => 5, "v" => 10}, %{"t" => 6, "v" => 12}, %{"t" => 7, "v" => 14}]

    # Nothing to do: the rows as they came, tuples and all.
    untouched = Delivery.new(tuples)
    assert Finish.finish(untouched, described(@numbers), request([])) == untouched

    # A step that must read tuple rows by name, with no names: refused, never dropped.
    assert_raise ArgumentError, ~r/tuple rows have no names/, fn ->
      Finish.finish(Delivery.new(tuples), described(@numbers), request(window: [5, 7]))
    end

    # A table stays a table, its columns and types.
    table =
      Table.new!([
        {"t", :number, Enum.to_list(1..20)},
        {"v", :number, Enum.map(1..20, &(&1 * 1.0))}
      ])

    kept = Finish.finish(Delivery.new(table), described(@numbers), request(window: [5, 7]))
    assert %Table{} = kept.rows
    assert Table.column(kept.rows, "v") == [5.0, 6.0, 7.0]
  end

  # What a source steps its window by (macaw#185), ported from visualize's feed window.
  @tag verifies: "window-feed-steps"
  test "before/4, region/2, range/2 and check/2 over the axes alone" do
    rows = for t <- [1, 5, 9, nil], do: %{"t" => t}
    assert Window.before(rows, "t", nil, 5) == [%{"t" => 1}]
    assert Window.before(rows, :t, 5, nil) == [%{"t" => 5}, %{"t" => 9}]
    assert Window.before(rows, "t", 1, 9) == [%{"t" => 1}, %{"t" => 5}]

    at = ~U[2026-10-29 00:00:00Z]
    times = Schema.new!(%{"t" => %{type: :time, window: true}, "v" => %{type: :number}})
    assert Window.region([at, nil], times) == %{"t" => [at, nil]}
    assert Window.region([0, 10], times) == nil
    assert Window.region([0, 10], Schema.new!(%{"v" => %{type: :number}})) == nil
    assert Window.region(nil, times) == nil
    assert Window.region(%{"v" => [0, 1]}, times) == %{"v" => [0, 1]}

    assert Window.range(%{"t" => [1, 5]}, :t) == [1, 5]
    assert Window.range(%{t: [1, 5]}, "t") == [1, 5]
    assert Window.range([1, 5], "t") == [1, 5]
    assert Window.range(%{"v" => [0, 1]}, "t") == nil
    assert Window.range(:everything, "t") == :everything

    assert Window.check(%{}, times) == :ok
    assert Window.check(%{region: %{"t" => [at, nil]}}, times) == :ok
    assert {:error, [{[:latest], {:window, :no_identity}}]} = Window.check(%{latest: true}, times)

    assert Window.check(%{region: %{"v" => [9, 1]}, at: 1}, times) ==
             {:error, [{[:at], :unknown_key}, {[:region, "v"], {:window, :inverted}}]}
  end
end
