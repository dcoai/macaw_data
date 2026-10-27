defmodule Macaw.Data.Operations.AggregatesTest do
  # The thirteen statistics (spec/04 §5), on visualize's `Visualize.Data` fixtures and
  # doc examples (its `visualize_test.exs` and `data_test.exs`), each value written as
  # visualize answers it; through `Operations.aggregate/4`, the readings' nils dropped.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Operations
  alias Macaw.Data.Operations.Aggregates

  defp agg(name, values, options \\ %{}) do
    {:ok, value} = Operations.aggregate(Operations.registry(), name, values, options)
    value
  end

  @t1 ~U[2026-10-27 10:00:00Z]
  @t2 ~U[2026-10-27 11:00:00Z]
  @t3 ~U[2026-10-27 12:00:00Z]

  describe "values (spec/04 §5)" do
    @tag verifies: "operations-statistics-values"
    test "count and distinct" do
      assert agg("count", [3, nil, 1, 4]) == 3
      assert agg("count", []) == 0
      assert agg("distinct", [3, 1, 3, nil, 1.0]) == 3
      assert agg("distinct", [:ok, "ok", :down]) == 2
      assert agg("distinct", []) == 0
    end

    @tag verifies: "operations-statistics-values"
    test "min, max and extent, of numbers and of times" do
      assert agg("min", [3, 1, 4, 1, 5]) == 1
      assert agg("max", [3, 1, 4, 1, 5, 9]) == 9
      assert agg("extent", [3, 1, 4, 1, 5, 9]) == [1, 9]
      assert agg("extent", [%{v: 1}, %{v: 4}] |> Enum.map(& &1.v)) == [1, 4]
      assert agg("min", [@t2, nil, @t1, @t3]) == @t1
      assert agg("max", [@t2, @t1, @t3]) == @t3
      assert agg("extent", [@t2, @t3, @t1]) == [@t1, @t3]
      assert agg("min", [~D[2026-01-02], ~D[2026-01-01]]) == ~D[2026-01-01]
      for name <- ~w(min max extent), do: assert(agg(name, [nil]) == nil)
    end

    @tag verifies: "operations-statistics-values"
    test "sum, mean and median" do
      assert agg("sum", [1, 2, 3.5]) == 6.5
      assert agg("sum", []) == 0
      assert agg("mean", [1, 2, 3, 4, 5]) == 3.0
      assert agg("mean", [nil]) == nil
      assert agg("median", [3, 1, 2]) == 2
      assert agg("median", [4, 1, 3, 2]) == 2.5
      assert agg("median", []) == nil
    end

    @tag verifies: "operations-statistics-values"
    test "quantile interpolates between the sorted readings, the last index clamped" do
      assert agg("quantile", [4, 1, 3, 2], %{p: 0.5}) == 2.5
      assert agg("quantile", [4, 1, 3, 2], %{p: 0}) == 1
      assert agg("quantile", [4, 1, 3, 2], %{"p" => 1}) == 4
      assert_in_delta agg("quantile", Enum.to_list(1..20), %{p: 0.95}), 19.05, 1.0e-12
      assert agg("quantile", [], %{p: 0.5}) == nil

      assert Operations.aggregate(Operations.registry(), "quantile", [1], %{p: 1.5}) ==
               {:error, [{["p"], {:type, {:number, 0, 1}}}]}
    end

    @tag verifies: "operations-statistics-values"
    test "variance and deviation are the sample's, nil for fewer than two" do
      assert agg("variance", [1, 2, 3, 4, 5]) == 2.5
      assert_in_delta agg("deviation", [1, 2, 3, 4, 5]), 1.5811388300841898, 1.0e-15
      assert agg("variance", [2, 4, 4, 4, 5, 5, 7, 9]) == 32 / 7
      assert agg("variance", [7]) == nil
      assert agg("deviation", [7]) == nil
      assert agg("variance", []) == nil
    end

    @tag verifies: "operations-statistics-values"
    test "slope over places and points, nil without spread (visualize's data_test)" do
      assert agg("slope", []) == nil
      assert agg("slope", [4]) == nil
      assert agg("slope", [[1, 2]]) == nil
      assert agg("slope", [{3, 1}, {3, 9}, {3, 4}]) == nil
      assert agg("slope", [1, 3, 5, 7]) == 2.0
      assert agg("slope", [5, 5, 5]) == 0.0
      assert agg("slope", [10, 7]) == -3.0
      assert_in_delta agg("slope", [[0, 1], [1, 4], [2, 4], [3, 7]]), 1.8, 1.0e-12
      assert agg("slope", [{0, 0}, {10, 5}]) == 0.5
      assert agg("slope", [[0, 2], [5, 4], [10, 6]]) == 0.4
      assert agg("slope", [0, {1, 1}, 2]) == 1.0
    end

    @tag verifies: "operations-statistics-values"
    test "delta is the last minus the first (visualize's data_test)" do
      assert agg("delta", []) == nil
      assert agg("delta", [7]) == 0
      assert agg("delta", [2.5]) == 0.0
      assert agg("delta", [3, 100, -4, 8]) == 5
      assert agg("delta", [10, nil, 0, 4]) == -6
    end

    @tag verifies: "operations-statistics-values"
    test "output types and units: kept exactly for the statistics of the reading's kind" do
      kept = ~w(min max extent sum mean median quantile deviation delta)

      for module <- Aggregates.all() do
        assert module.keeps_unit?() == module.name() in kept, module.name()
      end

      assert Aggregates.Min.output(:time, %{}) == :time
      assert Aggregates.Max.output(:number, %{}) == :number
      assert Aggregates.Extent.output(:time, %{}) == :term

      for module <- Aggregates.all(),
          module.name() not in ~w(min max extent),
          do: assert(module.output(:number, %{}) == :number)

      assert Enum.map(Aggregates.all(), & &1.name()) ==
               ~w(count distinct min max extent sum mean median quantile variance deviation slope delta)
    end

    @tag verifies: "operations-statistics-values"
    test "each statistic's own reduce gives its value of one fixture" do
      v = [3, 1, 4, 1, 5]
      assert Aggregates.Count.reduce(v, %{}) == 5
      assert Aggregates.Distinct.reduce(v, %{}) == 4
      assert Aggregates.Min.reduce(v, %{}) == 1
      assert Aggregates.Max.reduce(v, %{}) == 5
      assert Aggregates.Extent.reduce(v, %{}) == [1, 5]
      assert Aggregates.Sum.reduce(v, %{}) == 14
      assert Aggregates.Mean.reduce(v, %{}) == 2.8
      assert Aggregates.Median.reduce(v, %{}) == 3
      assert Aggregates.Quantile.reduce(v, %{"p" => 0.25}) == 1.0
      assert_in_delta Aggregates.Variance.reduce(v, %{}), 3.2, 1.0e-12
      assert_in_delta Aggregates.Deviation.reduce(v, %{}), :math.sqrt(3.2), 1.0e-12
      assert_in_delta Aggregates.Slope.reduce(v, %{}), 0.4, 1.0e-12
      assert Aggregates.Delta.reduce(v, %{}) == 2
    end

    @tag verifies: "operations-statistics-values"
    test "a reading of the wrong kind raises naming the aggregate" do
      for {name, values} <- [
            {"sum", [1, "2"]},
            {"mean", [@t1]},
            {"median", [1, :two]},
            {"quantile", ["a"]},
            {"variance", [1, "x"]},
            {"deviation", [[1]]},
            {"slope", ["up"]},
            {"delta", [1, @t1]},
            {"min", [1, @t1]},
            {"max", ["a"]},
            {"extent", [@t1, ~D[2026-01-01]]}
          ] do
        options = if name == "quantile", do: %{p: 0.5}, else: %{}

        assert_raise ArgumentError, ~r/^aggregate "#{name}": .* is not /, fn ->
          agg(name, values, options)
        end
      end
    end
  end

  describe "the streaming form (spec/04 §5)" do
    @streaming ~w(count distinct min max extent sum mean variance deviation slope delta)

    @tag verifies: "operations-statistics-stream"
    test "exactly the statistics but median and quantile give it" do
      for module <- Aggregates.all() do
        Code.ensure_loaded!(module)
        assert function_exported?(module, :step, 3) == module.name() in @streaming
      end
    end

    @tag verifies: "operations-statistics-stream"
    property "however the readings are chunked, the stream equals reduce" do
      check all(
              values <-
                list_of(one_of([integer(), float(min: -1.0e6, max: 1.0e6)]), max_length: 30),
              cut <- integer(0..30)
            ) do
        {a, b} = Enum.split(values, cut)

        for module <- Aggregates.all(), module.name() in @streaming do
          state = Enum.reduce(a, module.init(%{}), &module.step(&2, &1, %{}))
          state = Enum.reduce(b, state, &module.step(&2, &1, %{}))
          assert module.finish(state, %{}) == module.reduce(values, %{})
        end
      end
    end
  end
end
