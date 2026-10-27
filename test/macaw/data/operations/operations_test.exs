defmodule Macaw.Data.OperationsTest do
  # The behaviors, the registry, validating and running nodes (spec/04 §1–§3), over a
  # host's test package (`Macaw.Data.Test.Ops`), so nothing here depends on macaw_data's
  # own members.
  use ExUnit.Case, async: true

  alias Macaw.Data.{Aggregate, Operations, Table, Transform}
  alias Macaw.Data.Operations.{Option, Registry}
  alias Macaw.Data.Test.Ops

  doctest Macaw.Data.Operations
  doctest Macaw.Data.Operations.Option

  defp registry, do: Operations.registry([Ops])

  defp rows(table), do: Table.rows(table)

  describe "the behaviors (spec/04 §1.1, §1.2)" do
    @tag verifies: "operations-transform-callbacks"
    test "a transform declares its name, options, needs and outputs, and runs a checked node" do
      assert Ops.Double.name() == "double"

      assert [{"field", %Option{required: true}}, {"as", %Option{default: "double"}}] =
               Ops.Double.options()

      assert Ops.Layout.needs() == [:frame]
      assert Ops.Every.reduces() == {"n", 1}

      # spelling: allow, behaviour_info/1 is Elixir's
      callbacks = Transform.behaviour_info(:callbacks)
      assert {:run, 3} in callbacks and {:outputs, 2} in callbacks and {:needs, 0} in callbacks
      # spelling: allow, behaviour_info/1 is Elixir's
      assert Enum.sort(Transform.behaviour_info(:optional_callbacks)) == [prepare: 3, reduces: 0]
      refute function_exported?(Ops.Double, :reduces, 0)
    end

    @tag verifies: "operations-transform-callbacks"
    test "outputs agree with what run answers" do
      {:ok, table} = Table.from([%{v: 1}, %{v: 3}])

      for {node, context} <- [
            {%{"field" => :v, "as" => "d"}, %{}},
            {%{"padding" => 0}, %{frame: %{width: 10}}}
          ] do
        module = if Map.has_key?(node, "field"), do: Ops.Double, else: Ops.Layout
        out = module.run(node, table, context)
        assert Operations.columns(out) == module.outputs(node, Operations.columns(table))
      end
    end

    @tag verifies: "operations-aggregate-callbacks"
    test "an aggregate declares its name, options, output type and unit, and reduces readings" do
      assert Ops.Spread.name() == "spread"
      assert Ops.Spread.output(:time, %{}) == :time
      assert Ops.Spread.keeps_unit?()
      refute Ops.Scaled.keeps_unit?()

      # spelling: allow, behaviour_info/1 is Elixir's
      assert Enum.sort(Aggregate.behaviour_info(:optional_callbacks)) == [
               finish: 2,
               init: 1,
               step: 3
             ]

      assert Operations.step_keys() == ~w(op field by as fn thresholds values)

      registry = registry()
      assert Operations.aggregate(registry, "spread", [3, nil, 9, 4], %{}) == {:ok, 6}
      assert Operations.aggregate(registry, :scaled, [1, 2, nil], %{scale: 10}) == {:ok, 30}
    end

    @tag verifies: "operations-aggregate-callbacks"
    test "the streaming form equals reduce, chunked at every split" do
      values = [4, -2, 7, 7, 0, 3.5]

      for split <- 0..length(values) do
        {a, b} = Enum.split(values, split)
        state = Enum.reduce(a, Ops.Spread.init(%{}), &Ops.Spread.step(&2, &1, %{}))
        state = Enum.reduce(b, state, &Ops.Spread.step(&2, &1, %{}))
        assert Ops.Spread.finish(state, %{}) == Ops.Spread.reduce(values, %{})
      end

      assert Ops.Spread.finish(Ops.Spread.init(%{}), %{}) == Ops.Spread.reduce([], %{})
    end
  end

  describe "options (spec/04 §1.3)" do
    @tag verifies: "operations-option-types"
    test "every type holds its values and refuses the rest" do
      r = registry()

      holds = [
        {:field, "cpu"},
        {:field, :cpu},
        {:name, "n"},
        {:number, 1.5},
        {{:number, 0, 1}, 1},
        {:positive, 0.1},
        {:integer, -3},
        {{:integer, 3}, 3},
        {:power_of_two, 64},
        {:boolean, false},
        {{:list, :field}, ["a", :b]},
        {{:pair, :number}, [1, 2]},
        {{:one_of, [:integer, {:list, :number}]}, [1.5]},
        {:term, {:any, "thing"}}
      ]

      for {type, value} <- holds, do: assert(Option.check(r, type, value) == {:ok, value})

      refuses = [
        {:field, 1},
        {:field, nil},
        {:name, true},
        {:number, "1"},
        {{:number, 0, 1}, 1.01},
        {:positive, 0},
        {:integer, 1.0},
        {{:integer, 3}, 2},
        {:power_of_two, 48},
        {:power_of_two, 0},
        {:boolean, nil},
        {{:list, :field}, ["a", 1]},
        {{:pair, :number}, [1, 2, 3]},
        {{:one_of, [:integer, {:list, :number}]}, "x"},
        {:duration, [1, :fortnight]},
        {:duration, {1, :hour}},
        {{:enum, [:a, :b]}, "c"},
        {{:keys, {:list, :field}}, [:a]}
      ]

      for {type, value} <- refuses,
          do: assert(Option.check(r, type, value) == {:error, {:type, type}})
    end

    @tag verifies: "operations-option-types"
    test "an enum, a unit and a fixed order are read by spelling; an aggregate checks to its module" do
      r = registry()

      assert Option.check(r, {:enum, [:ascending, :descending]}, "descending") ==
               {:ok, :descending}

      assert Option.check(r, {:enum, [:ascending, :descending]}, :ascending) == {:ok, :ascending}
      assert Option.check(r, :duration, [15, "minute"]) == {:ok, [15, :minute]}
      assert Keyword.keys(Option.units()) == [:second, :minute, :hour, :day, :week, :year]
      assert Option.units()[:year] == 365 * Option.units()[:day]

      assert Option.check(r, {:keys, {:list, :field}}, %{"keys" => ["b", "a"]}) ==
               {:ok, {:keys, ["b", "a"]}}

      assert Option.check(r, {:keys, {:list, :field}}, {:keys, [:b]}) == {:ok, {:keys, [:b]}}
      assert Option.check(r, :aggregate, "spread") == {:ok, Ops.Spread}
      assert Option.check(r, :aggregate, :scaled) == {:ok, Ops.Scaled}
      assert Option.check(r, :aggregate, "mode") == {:error, {:unknown, :aggregate, "mode"}}
      assert Option.check(r, :aggregate, 1) == {:error, {:type, :aggregate}}
    end

    @tag verifies: ["operations-option-types", "operations-context-needs"]
    test "a frame-bound option takes plot or its own type" do
      r = registry()
      node = %{op: "every", fields: ["t", "v"]}
      frame = %{frame: %{width: 99.2, height: 10, center: [0, 0]}}

      assert {:ok, [%{"n" => 100}]} = Operations.validate(r, [Map.put(node, :n, "plot")], frame)
      assert {:ok, [%{"n" => 100}]} = Operations.validate(r, [Map.put(node, :n, :plot)], frame)
      assert {:ok, [%{"n" => 7}]} = Operations.validate(r, [Map.put(node, :n, 7)], %{})

      assert Operations.validate(r, [Map.put(node, :n, "wide")], frame) ==
               {:error, [{[0, "n"], {:type, {:integer, 2}}}]}
    end
  end

  describe "the registry (spec/04 §2)" do
    @tag verifies: "operations-registry-build"
    test "it holds macaw_data's own package and exactly the packages listed" do
      own = Operations.registry()
      assert Operations.packages(own) == [Operations]

      for member <- Operations.__members__(),
          do: assert(member.name() in (Operations.transforms(own) ++ Operations.aggregates(own)))

      assert Operations.transform(own, "double") == :error

      r = Operations.registry([Ops, Ops])
      assert Operations.packages(r) == [Operations, Ops]
      assert "double" in Operations.transforms(r) and "layout" in Operations.transforms(r)
      assert "spread" in Operations.aggregates(r)
      assert Operations.transforms(r) == Enum.sort(Operations.transforms(r))
      assert Operations.transform(r, "double") == {:ok, Ops.Double}
      assert Operations.transform(r, :double) == {:ok, Ops.Double}
      assert Operations.aggregate(r, "scaled") == {:ok, Ops.Scaled}
      assert Operations.aggregate(r, "double") == :error
      assert Registry.transform(r, :layout) == {:ok, Ops.Layout}
      assert Registry.aggregate(r, "spread") == {:ok, Ops.Spread}
      assert Registry.aggregate(r, "layout") == :error
    end

    @tag verifies: "operations-registry-build"
    test "a duplicate name, a step's key and a member of no behavior each raise naming it" do
      assert_raise ArgumentError,
                   ~r/"double" is named twice: by .*Ops.Double .*Ops.Twin.Double/,
                   fn ->
                     Operations.registry([Ops, Ops.Twin])
                   end

      assert_raise ArgumentError, ~r/"by_field" .*declares "field"/, fn ->
        Operations.registry([Ops.Greedy])
      end

      assert_raise ArgumentError, ~r/String, a member of .*Stray, implements no behavior/, fn ->
        Operations.registry([Ops.Stray])
      end

      assert_raise ArgumentError, ~r/Enum is not a package/, fn -> Operations.registry([Enum]) end
    end

    @tag verifies: "operations-registry-build"
    test "the digest changes with the members" do
      assert Operations.digest(Operations.registry()) != Operations.digest(registry())
      assert Operations.digest(registry()) == Operations.digest(Operations.registry([Ops, Ops]))
      assert %Registry{} = registry()
    end
  end

  describe "validating and running (spec/04 §3)" do
    @tag verifies: "operations-validate-faults"
    test "every fault of every node is answered at once, at its index and key" do
      nodes = [
        %{op: "double"},
        %{"op" => "sankey"},
        %{field: "v"},
        %{op: "double", field: 1, shade: "red"},
        :sort,
        %{op: "every", fields: ["t"], n: 1},
        %{op: "layout"},
        %{op: 7}
      ]

      assert Operations.validate(registry(), nodes, %{}) ==
               {:error,
                [
                  {[0, "field"], :required},
                  {[1, "op"], {:unknown, :transform, "sankey"}},
                  {[2, "op"], :required},
                  {[3, "field"], {:type, :field}},
                  {[3, "shade"], {:invalid_for, "double"}},
                  {[4], :not_a_node},
                  {[5, "fields"], {:type, {:pair, :field}}},
                  {[5, "n"], {:type, {:integer, 2}}},
                  {[6, "op"], {:needs, :frame}},
                  {[7, "op"], {:type, :name}}
                ]}
    end

    @tag verifies: ["operations-validate-faults", "operations-run-apply"]
    test "a checked node has string keys and defaults, and apply runs the nodes in order" do
      r = registry()

      assert {:ok, [%{"op" => "double", "field" => :v, "as" => "double"}]} =
               Operations.validate(r, [%{op: :double, field: :v}], %{})

      nodes = [%{op: "double", field: "v", as: :d}, %{op: "double", field: :d}]
      {:ok, table} = Operations.apply(r, nodes, [%{v: 1}, %{v: 5}])

      assert rows(table) == [
               %{:v => 1, :d => 2, "double" => 4},
               %{:v => 5, :d => 10, "double" => 20}
             ]

      assert Operations.columns(table) == [{:v, :number}, {:d, :number}, {"double", :number}]
      assert Table.rows(Operations.table([%{"v" => 1, "w" => 2}], [{:v, :number}])) == [%{v: 1}]

      assert Operations.outputs(r, nodes, [{:v, :number}]) ==
               {:ok, [{:v, :number}, {:d, :number}, {"double", :number}]}

      assert Operations.apply(r, [%{op: "double"}], [%{v: 1}]) ==
               {:error, [{[0, "field"], :required}]}

      assert_raise ArgumentError, "step 1, field: is required", fn ->
        Operations.apply!(r, [%{op: "double"}], [%{v: 1}])
      end
    end

    @tag verifies: ["operations-validate-faults", "operations-run-apply"]
    test "an aggregate's options are checked against its declaration" do
      r = registry()

      assert Operations.aggregate(r, "mode", [1], %{}) ==
               {:error, [{[], {:unknown, :aggregate, "mode"}}]}

      assert Operations.aggregate(r, "scaled", [1], %{scale: "x", by: 2}) ==
               {:error, [{["by"], {:invalid_for, "scaled"}}, {["scale"], {:type, :number}}]}

      assert Operations.aggregate(r, "scaled", [1], %{}) == {:error, [{["scale"], :required}]}
    end

    @tag verifies: ["operations-validate-faults", "operations-run-apply"]
    test "format_error words each reason" do
      words = [
        {{[0, "op"], :required}, "step 1, op: is required"},
        {{[2], :not_a_node}, "step 3: is not a node (a map with an op)"},
        {{[0, "shade"], {:invalid_for, "double"}}, "step 1, shade: is not read by double"},
        {{[0, "fn"], {:unknown, :aggregate, "mode"}},
         "step 1, fn: aggregate \"mode\" is not available"},
        {{[0, "op"], {:needs, :frame}},
         "step 1, op: needs a frame, which the caller does not give"},
        {{[0, "n"], {:type, {:integer, 3}}}, "step 1, n: is an integer of at least 3"},
        {{[0, "p"], {:type, {:number, 0, 1}}}, "step 1, p: is a number from 0 to 1"},
        {{[0, "from"], {:type, :duration}},
         "step 1, from: is a duration [n, unit], unit one of second, minute, hour, day, week or year"},
        {{[0, "thresholds"], {:type, {:one_of, [{:integer, 1}, {:list, :number}]}}},
         "step 1, thresholds: is an integer of at least 1 or a list, each a number"},
        {{["scale"], :required}, "scale: is required"},
        {{[], {:unknown, :aggregate, "mode"}}, "the name: aggregate \"mode\" is not available"}
      ]

      for {fault, sentence} <- words, do: assert(Operations.format_error(fault) == sentence)
    end
  end

  describe "the context (spec/04 §3.2)" do
    @tag verifies: "operations-context-needs"
    test "a transform needing a frame runs with one and is refused without one" do
      r = registry()

      assert Operations.apply(r, [%{op: "layout"}], [%{v: 1}]) ==
               {:error, [{[0, "op"], {:needs, :frame}}]}

      {:ok, table} =
        Operations.apply(r, [%{op: "layout"}], [%{v: 1}, %{v: 2}], %{frame: %{width: 10}})

      assert rows(table) == [%{:v => 1, "x" => 0.0}, %{:v => 2, "x" => 5.0}]
    end

    @tag verifies: "operations-context-needs"
    test "plot resolves to the frame's width before the step and is refused without a frame" do
      r = registry()
      rows = for t <- 1..10, do: %{t: t, v: t * t}
      node = %{op: "every", fields: [:t, :v], n: "plot"}

      assert Operations.apply(r, [node], rows) == {:error, [{[0, "n"], {:needs, :frame}}]}

      {:ok, table} = Operations.apply(r, [node], rows, %{frame: %{width: 2.5}})
      assert Enum.map(rows(table), & &1.t) == [1, 6, 10]
    end

    @tag verifies: "operations-context-needs"
    test "now and schema reach the step as the caller gave them" do
      schema = Macaw.Data.Schema.new!(%{v: %{type: :number}})
      context = %{now: ~U[2026-10-27 12:00:00Z], schema: schema}
      {:ok, table} = Operations.apply(registry(), [%{op: "stamp"}], [%{v: 1}], context)
      assert rows(table) == [%{:v => 1, "now" => ~U[2026-10-27 12:00:00.000000Z], "fields" => 1}]
    end
  end
end
