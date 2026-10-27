defmodule Macaw.Data.Operations.SeriesTest do
  # `stack`, `bin` and `spectrum` (spec/04 §4.8, §4.9, §4.11), ported from visualize's
  # `Chart.TransformTest` with its expectations, but for what Macaw changes on purpose: a
  # step's column names are strings (`"x0"`, `"key"`), and a bad option is a validation
  # fault before the step runs.
  use ExUnit.Case, async: true

  alias Macaw.Data.{FFT, Operations, Stack, Table}

  @registry Operations.registry()
  @rows for i <- 0..5, do: %{t: i, v: rem(i * 7, 5), a: i, b: 5 - i, c: 1, k: "k#{rem(i, 2)}"}

  defp run(node, rows, context \\ %{}),
    do: @registry |> Operations.apply!([node], rows, context) |> Table.rows()

  defp agrees(node, rows) do
    table = Operations.apply!(@registry, [node], rows)
    {:ok, input} = Table.from(rows)

    assert {:ok, Operations.columns(table)} ==
             Operations.outputs(@registry, [node], Operations.columns(input))

    table
  end

  describe "stack (spec/04 §4.8)" do
    @tag verifies: "operations-stack-orders"
    test "is Stack per series in key order, each row its datum plus the stack" do
      rows = run(%{op: "stack", fields: [:a, :b, :c], offset: :expand}, @rows)

      series =
        Stack.new() |> Stack.keys([:a, :b, :c]) |> Stack.offset(:expand) |> Stack.generate(@rows)

      expected =
        for s <- series, p <- s.points do
          Map.merge(p.data, %{
            "key" => s.key,
            "series" => s.index,
            "value" => p.value,
            "y0" => p.y0,
            "y1" => p.y1
          })
        end

      assert rows == expected
      assert rows |> Enum.map(& &1["key"]) |> Enum.uniq() == [:a, :b, :c]
      agrees(%{op: "stack", fields: [:a, :b, :c]}, @rows)
    end

    @tag verifies: "operations-stack-orders"
    test "maps inside_out and appearance onto the stacking order" do
      inside = run(%{op: "stack", fields: [:a, :b, :c], order: :inside_out}, @rows)

      direct =
        Stack.new()
        |> Stack.keys([:a, :b, :c])
        |> Stack.order(:insideout)
        |> Stack.generate(@rows)

      assert inside |> Enum.map(& &1["series"]) |> Enum.uniq() == Enum.map(direct, & &1.index)

      # Peaks: a at the last row, b at the first, c at the first; b and c precede a.
      appearance = run(%{op: "stack", fields: [:a, :b, :c], order: "appearance"}, @rows)
      by_key = appearance |> Enum.map(&{&1["key"], &1["series"]}) |> Enum.uniq() |> Map.new()
      assert by_key == %{b: 0, c: 1, a: 2}
    end

    @tag verifies: "operations-stack-orders"
    test "takes a fixed key order through to the stack, read by spelling" do
      rows = run(%{op: "stack", fields: [:a, :b, :c], order: %{keys: ["c", :x, "a"]}}, @rows)
      by_key = rows |> Enum.map(&{&1["key"], &1["series"]}) |> Enum.uniq() |> Map.new()
      assert by_key == %{c: 0, a: 1, b: 2}

      # The bottom series is c from zero in every row, whatever the sums.
      for %{"key" => :c} = row <- rows, do: assert(row["y0"] == 0)
    end

    @tag verifies: "operations-stack-orders"
    test "a nil reading is zero; a reading that is not a number raises naming the step" do
      rows = run(%{op: "stack", fields: [:a, :b]}, [%{a: 1, b: nil}, %{a: nil, b: 2}])

      assert Enum.map(rows, &{&1["key"], &1["y0"], &1["y1"]}) == [
               {:a, 0, 1},
               {:a, 0, 0},
               {:b, 1, 1},
               {:b, 0, 2}
             ]

      assert_raise ArgumentError,
                   ~r/^transform "stack": :b reads "x", which is not a number/,
                   fn ->
                     run(%{op: "stack", fields: [:a, :b]}, [%{a: 1, b: "x"}])
                   end

      assert_raise ArgumentError, ~r/^step 1, offset: is one of none, expand/, fn ->
        run(%{op: "stack", fields: [:a], offset: :zero}, @rows)
      end
    end
  end

  describe "bin (spec/04 §4.9)" do
    @tag verifies: "operations-bin-counts"
    test "splits the extent into equal bins, each reading in its half-open bin, the maximum in the last" do
      # v is 0 2 4 1 3 0: over [0, 4] in two bins, [0, 2) holds 0 1 0 and [2, 4] holds 2 4 3.
      assert run(%{op: "bin", field: :v, thresholds: 2, as: :n}, @rows) == [
               %{"x0" => 0, "x1" => 2.0, "y0" => 0, :n => 3, "values" => [0, 1, 0]},
               %{"x0" => 2.0, "x1" => 4, "y0" => 0, :n => 3, "values" => [2, 4, 3]}
             ]

      assert run(%{op: "bin", field: :v}, [%{v: nil}]) == []
      assert length(run(%{op: "bin", field: :v}, @rows)) == 10
      agrees(%{op: "bin", field: :v, thresholds: 2}, @rows)
    end

    @tag verifies: "operations-bin-counts"
    test "given thresholds are the inner ones, and fn reduces each bin's readings" do
      rows = for v <- [1, 2, 2, 9, 5, nil], do: %{v: v}

      assert run(%{op: "bin", field: :v, thresholds: [5]}, rows) == [
               %{"x0" => 1, "x1" => 5, "y0" => 0, "count" => 3, "values" => [1, 2, 2]},
               %{"x0" => 5, "x1" => 9, "y0" => 0, "count" => 2, "values" => [9, 5]}
             ]

      assert run(%{op: "bin", field: :v, thresholds: [5], fn: "mean", as: "mean"}, rows)
             |> Enum.map(& &1["mean"]) == [5 / 3, 7.0]

      # An empty bin is the aggregate's empty value.
      gappy = for v <- [0, 1, 9, 10], do: %{v: v}

      assert run(%{op: "bin", field: :v, thresholds: 5, fn: "max"}, gappy)
             |> Enum.map(& &1["count"]) ==
               [1, nil, nil, nil, 10]

      assert run(%{op: "bin", field: :v, thresholds: 2, fn: "quantile", p: 0.5}, gappy)
             |> Enum.map(& &1["count"]) ==
               [0.5, 9.5]

      assert_raise ArgumentError, ~r/^transform "bin": :v reads "x", which is not a number/, fn ->
        run(%{op: "bin", field: :v}, [%{v: 1}, %{v: "x"}])
      end

      table = agrees(%{op: "bin", field: :v, fn: "extent"}, rows)
      assert Table.column_type(table, "count") == :term
    end
  end

  describe "spectrum (spec/04 §4.11)" do
    defp tone,
      do: for(i <- 0..99, do: %{t: i / 50, v: 2 * :math.sin(2 * :math.pi() * 10 * i / 50)})

    @tag verifies: "operations-spectrum-lines"
    test "is FFT.spectrum/3 over the sample column at the time column's gap" do
      out = run(%{op: "spectrum", field: :v, time: :t}, tone())

      # 64 samples of 100 at 50 Hz: 32 lines, 0.78125 Hz apart, the peak at 10 Hz reading 2.
      assert length(out) == 32

      assert out |> Enum.map(&Enum.sort(Map.keys(&1))) |> Enum.uniq() == [
               ["frequency", "magnitude"]
             ]

      assert_in_delta Enum.at(out, 1)["frequency"], 50 / 64, 1.0e-9
      peak = Enum.max_by(out, & &1["magnitude"])
      assert_in_delta peak["frequency"], 10.0, 0.4
      assert_in_delta peak["magnitude"], 2.0, 0.05
      agrees(%{op: "spectrum", field: :v, time: :t}, tone())
    end

    @tag verifies: "operations-spectrum-lines"
    test "every and samples given, three names under as, no window" do
      out =
        run(
          %{op: "spectrum", field: :v, every: 0.02, samples: 32, window: :none, as: [:f, :a, :p]},
          tone()
        )

      assert length(out) == 16
      assert hd(out) |> Map.keys() |> Enum.sort() == [:a, :f, :p]

      assert run(%{op: "spectrum", field: :v, as: "f"}, tone())
             |> hd()
             |> Map.keys()
             |> Enum.sort() == ["f", "magnitude"]
    end

    @tag verifies: "operations-spectrum-lines"
    test "DateTimes read in seconds; a row without a numeric sample is left out; too few is none" do
      at = ~U[2024-01-01 00:00:00Z]
      timed = for i <- 0..15, do: %{at: DateTime.add(at, i * 250, :millisecond), v: :math.sin(i)}
      lines = run(%{op: "spectrum", field: :v, time: :at}, timed)
      assert length(lines) == 8
      assert_in_delta Enum.at(lines, 1)["frequency"], 1 / (16 * 0.25), 1.0e-9

      assert run(%{op: "spectrum", field: :v}, [%{v: 1}]) == []
      assert run(%{op: "spectrum", field: :v}, [%{v: "x"}, %{v: 1}, %{v: 2}]) |> length() == 1
    end

    @tag verifies: "operations-spectrum-lines"
    test "detrend takes the mean out first, so an offset no longer leaks beside the DC line" do
      lifted = Enum.map(tone(), &%{&1 | v: &1.v + 100})
      leaked = run(%{op: "spectrum", field: :v, time: :t}, lifted)
      assert Enum.at(leaked, 1)["magnitude"] > 10

      flat = run(%{op: "spectrum", field: :v, time: :t, detrend: true}, lifted)
      assert Enum.at(flat, 1)["magnitude"] < 0.01
      assert_in_delta Enum.max_by(flat, & &1["magnitude"])["magnitude"], 2.0, 0.05

      assert_raise ArgumentError, "step 1, samples: is a power of two", fn ->
        run(%{op: "spectrum", field: :v, samples: 12}, tone())
      end

      assert_raise ArgumentError, "step 1, window: is one of hann, hamming or none", fn ->
        run(%{op: "spectrum", field: :v, window: :flat}, tone())
      end

      assert FFT.windows() == [:hann, :hamming, :none]
    end
  end
end
