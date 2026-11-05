defmodule Macaw.Data.StepsExtremeValuesTest do
  @moduledoc """
  No step raises on a number column, whatever its values (spec/04 §5, macaw_data#181): the
  BEAM has no infinity, so arithmetic past a float's range raises, and a step's `bind/3`
  proves its readings are numbers, not that their arithmetic holds. Every registered step
  runs over columns holding extreme values, each answering `{:ok, table}` or
  `{:error, faults}`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Error, Fault, Operations, Table}

  @extreme [
    1.0e308,
    -1.0e308,
    1.7976931348623157e308,
    -1.7976931348623157e308,
    8.98846567431158e307,
    1.0e154,
    -1.0e154,
    5.0e-324,
    -5.0e-324,
    1.0e-308,
    10 ** 308,
    -(10 ** 308),
    10 ** 400,
    -(10 ** 400),
    0,
    0.0,
    1,
    -1
  ]

  defp reading, do: one_of([member_of(@extreme), float(), integer()])

  defp aggregates, do: Operations.registry().aggregates |> Map.keys() |> Enum.sort()

  defp amount, do: one_of([member_of(@extreme), integer(1..5), float()])

  # A node of each registered step, its numeric options among the extreme ones too.
  defp nodes do
    aggregate = member_of(aggregates())
    fields = constant(["x", "y", "z"])

    %{
      "aggregate" =>
        one_of([
          fixed_map(%{"field" => member_of(["x", "y"]), "fn" => aggregate}),
          fixed_map(%{
            "field" => member_of(["x", "y"]),
            "fn" => aggregate,
            "by" => constant("g")
          }),
          fixed_map(%{"field" => constant(["x", "y"]), "fn" => aggregate})
        ]),
      "bin" =>
        one_of([
          fixed_map(%{"field" => constant("x")}),
          fixed_map(%{"field" => constant("x"), "thresholds" => integer(1..4)}),
          fixed_map(%{"field" => constant("x"), "fn" => aggregate}),
          fixed_map(%{"field" => constant("x"), "thresholds" => list_of(amount(), max_length: 3)})
        ]),
      "filter" =>
        fixed_map(%{
          "field" => constant("x"),
          "test" => member_of(~w(eq ne lt lte gt gte present absent)),
          "value" => amount()
        }),
      "fold" => fixed_map(%{"fields" => fields}),
      "lttb" => fixed_map(%{"fields" => constant(["x", "y"]), "n" => integer(3..5)}),
      "m4" => fixed_map(%{"fields" => constant(["x", "y"]), "width" => integer(1..3)}),
      "sort" =>
        fixed_map(%{"field" => constant("x"), "order" => member_of(~w(ascending descending))}),
      "spectrum" =>
        one_of([
          fixed_map(%{
            "field" => constant("x"),
            "every" => member_of([1, 1.0e308, 5.0e-324, 1.0e-300, 10 ** 400]),
            "window" => member_of(~w(hann hamming none)),
            "detrend" => boolean()
          }),
          fixed_map(%{
            "field" => constant("x"),
            "time" => constant("y"),
            "detrend" => boolean()
          })
        ]),
      "stack" =>
        fixed_map(%{
          "fields" => fields,
          "order" => member_of(~w(none ascending descending inside_out reverse appearance)),
          "offset" => member_of(~w(none expand silhouette wiggle diverging))
        }),
      "sum" =>
        one_of([
          fixed_map(%{"field" => constant("x")}),
          fixed_map(%{"field" => constant("x"), "by" => constant("g")})
        ]),
      "take" => fixed_map(%{"n" => integer(0..3), "side" => member_of(~w(end start))}),
      "window" =>
        one_of([
          fixed_map(%{
            "field" => constant("x"),
            "from" => map(amount(), &[&1, "year"]),
            "to" => map(amount(), &[&1, "second"])
          }),
          fixed_map(%{"field" => constant("x"), "latest" => boolean()})
        ])
    }
  end

  defp columns do
    bind(integer(0..8), fn n ->
      fixed_map(%{
        "x" => list_of(reading(), length: n),
        "y" => list_of(reading(), length: n),
        "z" => list_of(reading(), length: n),
        "g" => list_of(member_of(["a", "b"]), length: n)
      })
    end)
  end

  defp table(columns) do
    Table.new!([
      {"x", :number, columns["x"]},
      {"y", :number, columns["y"]},
      {"z", :number, columns["z"]},
      {"g", :category, columns["g"]}
    ])
  end

  defp answers(registry, nodes, source) do
    case Operations.apply(registry, nodes, source) do
      {:ok, %Table{}} ->
        :ok

      {:error, [_ | _] = faults} ->
        assert is_binary(Fault.sentence(faults))
        error = assert_raise Error, fn -> Operations.apply!(registry, nodes, source) end
        assert error.reason == faults
    end
  end

  test "every registered step has a generator here" do
    assert Map.keys(nodes()) |> Enum.sort() ==
             Operations.registry().transforms |> Map.keys() |> Enum.sort()
  end

  @tag verifies: "operations-extreme-values"
  property "aggregate answers any number column, through every aggregate" do
    each_answers("aggregate")
  end

  @tag verifies: "operations-extreme-values"
  property "bin answers any number column, through its edges and its aggregate" do
    each_answers("bin")
  end

  @tag verifies: "operations-extreme-values"
  property "filter answers any number column, through its tests" do
    each_answers("filter")
  end

  @tag verifies: "operations-extreme-values"
  property "fold answers any number column, through its columns" do
    each_answers("fold")
  end

  @tag verifies: "operations-extreme-values"
  property "sort answers any number column, through its order" do
    each_answers("sort")
  end

  @tag verifies: "operations-extreme-values"
  property "spectrum answers any number column, through its transform and its interval" do
    each_answers("spectrum")
  end

  @tag verifies: "operations-extreme-values"
  property "stack answers any number column, through every order and offset" do
    each_answers("stack")
  end

  @tag verifies: "operations-extreme-values"
  property "sum answers any number column, through its groups" do
    each_answers("sum")
  end

  @tag verifies: "operations-extreme-values"
  property "take answers any number column, through its rows" do
    each_answers("take")
  end

  @tag verifies: "operations-extreme-values"
  property "window answers any number column, through its bounds" do
    each_answers("window")
  end

  @tag verifies: "operations-extreme-values"
  property "lttb answers any number column, on every scale" do
    each_answers_on_scales("lttb")
  end

  @tag verifies: "operations-extreme-values"
  property "m4 answers any number column, on every scale" do
    each_answers_on_scales("m4")
  end

  defp each_answers_on_scales(op) do
    registry = Operations.registry()

    check all(
            columns <- columns(),
            node <- nodes()[op],
            scale <- member_of([nil, :linear, :time, :log])
          ) do
      nodes = [Map.put(node, "op", op)]
      source = table(columns)
      context = if scale, do: %{scale: scale}, else: %{}

      answer = Operations.apply(registry, nodes, source, context)

      # The kernel and the Elixir path answer alike, a fault or the rows.
      on_elixir =
        Macaw.Data.Native.elixir(fn -> Operations.apply(registry, nodes, source, context) end)

      assert rows_of(answer) == rows_of(on_elixir)

      case answer do
        {:ok, %Table{}} ->
          :ok

        {:error, [_ | _] = faults} ->
          assert is_binary(Fault.sentence(faults))

          error =
            assert_raise Error, fn -> Operations.apply!(registry, nodes, source, context) end

          assert error.reason == faults
      end
    end
  end

  defp rows_of({:ok, table}), do: {:ok, Table.rows!(table)}
  defp rows_of(fault), do: fault

  @tag verifies: "operations-extreme-values"
  test "lttb and m4 past what their arithmetic holds are faults at fields" do
    wide = Table.new!([{"x", :number, [-1.0e308, 0.0, 1.0e308]}, {"y", :number, [1, 2, 3]}])

    for node <- [
          %{"op" => "lttb", "fields" => ["x", "y"], "n" => 3},
          %{"op" => "m4", "fields" => ["x", "y"], "width" => 2}
        ] do
      assert Operations.apply(Operations.registry(), [node], wide) ==
               {:error, [{[0, "fields"], :overflow}]}
    end

    tall =
      Table.new!([
        {"x", :number, Enum.to_list(1..20)},
        {"y", :number, for(i <- 1..20, do: if(rem(i, 2) == 0, do: 1.0e307, else: -1.0e307))}
      ])

    assert Operations.apply(
             Operations.registry(),
             [%{"op" => "lttb", "fields" => ["x", "y"], "n" => 3}],
             tall
           ) == {:error, [{[0, "fields"], :overflow}]}

    assert Operations.apply(
             Operations.registry(),
             [%{"op" => "m4", "fields" => ["x", "y"], "width" => 2}],
             Table.new!([{"x", :number, [1.0e302, 2.0e302]}, {"y", :number, [1, 2]}]),
             %{scale: :time}
           ) == {:error, [{[0, "fields"], :overflow}]}

    assert Operations.apply(
             Operations.registry(),
             [%{"op" => "m4", "fields" => ["x", "y"], "width" => 2}],
             Table.new!([{"x", :number, [1, 10 ** 400]}, {"y", :number, [1, 2]}]),
             %{scale: :log}
           ) == {:error, [{[0, "fields"], :overflow}]}
  end

  @tag verifies: "operations-extreme-values"
  test "m4 over an extent whose bucket underflows answers, the kernel and the Elixir path alike" do
    table = Table.new!([{"x", :number, [5.0e-324, -5.0e-324]}, {"y", :number, [1, 2]}])
    node = %{"op" => "m4", "fields" => ["x", "y"], "width" => 1}
    registry = Operations.registry()

    assert {:ok, kept} = Operations.apply(registry, [node], table)
    assert Table.size(kept) == 2

    assert {:ok, same} =
             Macaw.Data.Native.elixir(fn -> Operations.apply(registry, [node], table) end)

    assert Table.rows!(same) == Table.rows!(kept)
  end

  @tag verifies: "operations-extreme-values"
  test "a line well inside a float's range is reduced, not refused" do
    n = 2_000
    x = Enum.to_list(1..n)
    y = for i <- x, do: :math.sin(i / 25) * 1.0e140
    table = Table.new!([{"x", :number, x}, {"y", :number, y}])
    points = Enum.zip(x, y)

    assert {:ok, kept} =
             Operations.apply(
               Operations.registry(),
               [%{"op" => "lttb", "fields" => ["x", "y"], "n" => 50}],
               table
             )

    assert Table.size(kept) <= 50
    assert Table.rows!(kept) |> Enum.all?(&({&1["x"], &1["y"]} in points))
  end

  defp each_answers(op) do
    registry = Operations.registry()

    check all(columns <- columns(), node <- nodes()[op]) do
      answers(registry, [Map.put(node, "op", op)], table(columns))
    end
  end

  defp over(values, node) do
    Operations.apply(Operations.registry(), [node], Table.new!([{"x", :number, values}]))
  end

  @tag verifies: "operations-extreme-values"
  test "bin over an extent past a float's range is its fault, and its twin raises it" do
    table = Table.new!([{"x", :number, [1.0e308, -1.0e308]}])
    node = %{"op" => "bin", "field" => "x"}

    assert Operations.apply(Operations.registry(), [node], table) ==
             {:error, [{[0, "field"], :overflow}]}

    error =
      assert_raise Error, fn -> Operations.apply!(Operations.registry(), [node], table) end

    assert error.reason == [{[0, "field"], :overflow}]
    assert Exception.message(error) =~ "beyond a float's range"
  end

  @tag verifies: "operations-extreme-values"
  test "a bin a float holds is the BEAM's own: its edges to the bit" do
    for {d0, d1, n} <- [
          {0.0, 1.0e307, 4},
          {-1.0e307, 1.0e307, 3},
          {1, 7, 3},
          {-1.0e-300, 1.0e-300, 2}
        ] do
      assert {:ok, table} =
               over([d0, d1], %{"op" => "bin", "field" => "x", "thresholds" => n})

      rows = Table.rows!(table)
      assert hd(rows)["x0"] == d0
      assert List.last(rows)["x1"] == d1

      for {row, i} <- Enum.with_index(Enum.drop(rows, 1), 1) do
        assert row["x0"] === d0 + i * (d1 - d0) / n
      end
    end
  end

  @tag verifies: "operations-extreme-values"
  test "a statistic past a float's range is its fault at the field" do
    for {name, values} <- [
          {"mean", [10 ** 400, 10 ** 400]},
          {"median", [1.0e308, 1.0e308]},
          {"variance", [1.0e308, -1.0e308]},
          {"deviation", [1.0e308, -1.0e308]},
          {"slope", [1.0e308, -1.0e308]},
          {"delta", [-1.0e308, 1.0e308]}
        ] do
      assert over(values, %{"op" => "aggregate", "field" => "x", "fn" => name}) ==
               {:error, [{[0, "field"], :overflow}]},
             name

      assert Operations.aggregate(Operations.registry(), name, values, %{}) ==
               {:error, [{["values"], :overflow}]},
             name
    end

    assert Operations.aggregate(Operations.registry(), "quantile", [-1.0e308, 1.0e308], %{
             "p" => 0.5
           }) ==
             {:error, [{["values"], :overflow}]}
  end

  @tag verifies: "operations-extreme-values"
  test "a statistic a float holds is the value it was" do
    values = [1.5, 2.5, 4.0, 8.25]
    run = &Operations.aggregate(Operations.registry(), &1, values, &2)

    assert run.("median", %{}) == {:ok, 3.25}
    assert run.("quantile", %{"p" => 0.25}) == {:ok, 1.5 + (2.5 - 1.5) * 0.75}
    assert run.("delta", %{}) == {:ok, 8.25 - 1.5}
    mean = Enum.sum(values) / 4
    assert {:ok, variance} = run.("variance", %{})
    assert_in_delta variance, Enum.sum(for(v <- values, do: (v - mean) ** 2)) / 3, 1.0e-12

    # Against the one formula for a place's points: x is 0, 1, 2, 3, whose mean is 1.5.
    moment = Enum.sum(for({v, x} <- Enum.with_index(values), do: (x - 1.5) * (v - mean)))
    assert {:ok, slope} = run.("slope", %{})
    assert_in_delta slope, moment / 5.0, 1.0e-12
  end

  # Welford's update as the BEAM runs it, for values past the fast path's screen.
  defp welford(values) do
    {n, _mean, m2} =
      Enum.reduce(values, {0, 0.0, 0.0}, fn value, {n, mean, m2} ->
        n = n + 1
        delta = value - mean
        mean = mean + delta / n
        {n, mean, m2 + delta * (value - mean)}
      end)

    m2 / (n - 1)
  end

  @tag verifies: "operations-extreme-values"
  test "past the screen of variance's fast path, a value a float holds is the BEAM's to the bit" do
    values = [1.0e151, 3.0e151, -2.0e151]

    assert Operations.aggregate(Operations.registry(), "variance", values, %{}) ==
             {:ok, welford(values)}
  end

  @tag verifies: "operations-extreme-values"
  test "window's bounds past a float's range are its faults at from and to" do
    assert over([1.0e308], %{"op" => "window", "field" => "x", "from" => [-1.0e308, "year"]}) ==
             {:error, [{[0, "from"], :overflow}]}

    assert over([1.0e308], %{"op" => "window", "field" => "x", "to" => [1.0e308, "year"]}) ==
             {:error, [{[0, "to"], :overflow}]}

    assert {:ok, table} =
             over([1, 5, 9], %{"op" => "window", "field" => "x", "from" => [5, "second"]})

    assert Enum.map(Table.rows!(table), & &1["x"]) == [5, 9]
  end

  @tag verifies: ["operations-extreme-values", "operations-spectrum-lines"]
  test "a spectrum past its bound is its fault at field, every or time, and below it unchanged" do
    node = %{"op" => "spectrum", "field" => "x", "every" => 1}
    huge = List.duplicate(1.0e152, 4)

    assert over(huge, node) == {:error, [{[0, "field"], :overflow}]}

    assert over([1.0, 2.0, 3.0, 4.0], %{node | "every" => 5.0e-324}) ==
             {:error, [{[0, "every"], :overflow}]}

    gaps =
      Table.new!([
        {"x", :number, [1, 2, 3, 4]},
        {"t", :number, [-1.0e308, 1.0e308, 1.1e308, 1.2e308]}
      ])

    assert Operations.apply(
             Operations.registry(),
             [%{"op" => "spectrum", "field" => "x", "time" => "t"}],
             gaps
           ) == {:error, [{[0, "time"], :overflow}]}

    assert Macaw.Data.FFT.spectrum(huge, 1) == {:error, {:values, :overflow}}
    assert Macaw.Data.FFT.format_error({:values, :overflow}) =~ "1.0e152"
    assert Macaw.Data.FFT.format_error({:every, :overflow}) =~ "float's range"

    assert_raise Error, fn -> Macaw.Data.FFT.spectrum!(huge, 1) end

    # Just below the bound, a term's square still holds.
    assert {:ok, [_ | _]} = Macaw.Data.FFT.spectrum(List.duplicate(2.0e151, 4), 1, window: :none)
  end
end
