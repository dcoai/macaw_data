defmodule Macaw.Data.Operations.SandboxOpsTest do
  # What a stored function reaches (spec/04 §6): `Macaw.Data.Ops` by literal name, held to
  # the registry it is checked against and compiled against it; the engine's `packages:`;
  # the cache keyed by the registry's digest.
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Macaw.Data.{Delivery, Derived, Operations, Ops, Schema}
  alias Macaw.Data.Derived.{Engine, Sandbox}
  alias Macaw.Data.Derived.Sandbox.Cache

  @own Operations.registry()
  @hosted Operations.registry([Macaw.Data.Test.Ops])

  @rows [
    %{host: "a", cpu: 30},
    %{host: "b", cpu: 90},
    %{host: "a", cpu: 50},
    %{host: "c", cpu: nil}
  ]

  defp call(source, args, opts \\ []) do
    {:ok, compiled} = Sandbox.compile(source, opts)
    Sandbox.run(compiled, args)
  end

  defp reasons(source, opts \\ []) do
    {:error, faults} = Sandbox.check(source, opts)
    faults
  end

  describe "calls by literal name (spec/04 §6, §6.1)" do
    @tag verifies: ["operations-sandbox-calls", "operations-sandbox-ops"]
    test "a stored aggregate and transform answer what apply answers" do
      source = ~S"""
      fn rows ->
        p50 = rows |> Enum.map(& &1.cpu) |> Macaw.Data.Ops.aggregate("quantile", %{p: 0.5})

        hot =
          rows
          |> Macaw.Data.Ops.transform("filter", %{field: "cpu", test: :gte, value: p50})
          |> Macaw.Data.Ops.transform("sort", %{field: "cpu", order: :descending})

        %{p50: p50, hot: Enum.map(hot, & &1.host), mean: Macaw.Data.Ops.aggregate(Enum.map(rows, & &1.cpu), "mean")}
      end
      """

      assert {:ok, %{"p50" => 50.0, "hot" => ["b", "a"], "mean" => mean}} = call(source, [@rows])
      assert_in_delta mean, 170 / 3, 1.0e-12

      direct =
        Operations.apply!(
          @own,
          [%{op: "sort", field: :cpu, order: :descending}],
          Enum.take(@rows, 3)
        )

      assert Macaw.Data.Table.rows(direct) |> Enum.map(& &1.host) == ["b", "a", "a"]

      assert Ops.transform(Enum.take(@rows, 3), "sort", %{field: :cpu, order: "descending"})
             |> Enum.map(& &1.host) == ["b", "a", "a"]

      assert Ops.aggregate([1, nil, 3], "sum") == 4
      assert Ops.aggregate([1, 2, 3, 4], "quantile", %{p: 0.5}) == 2.5

      assert_raise ArgumentError, "take: step 1, n: is required", fn ->
        Ops.transform(@rows, "take")
      end
    end

    @tag verifies: ["operations-sandbox-calls", "operations-sandbox-attacks"]
    test "a name that is not a literal, not registered, or a drawing transform is refused at its line" do
      assert [{3, {:operation_name, :literal}}] =
               reasons(
                 "fn rows ->\n  name = \"sum\"\n  Macaw.Data.Ops.aggregate(rows, name)\nend"
               )

      assert [{3, {:unknown_operation, :transform, "sankey"}}] =
               reasons("fn rows ->\n\n  Macaw.Data.Ops.transform(rows, \"sankey\")\nend")

      assert [{1, {:unknown_operation, :transform, "double"}}] =
               reasons(~S|fn rows -> Macaw.Data.Ops.transform(rows, "double", %{field: "v"}) end|)

      assert [{1, {:needs, "layout", :frame}}] =
               reasons(~S|fn rows -> Macaw.Data.Ops.transform(rows, "layout") end|,
                 operations: @hosted
               )

      # Checked before it is placed, a name need only be a literal.
      assert {:ok, _} =
               Sandbox.check(~S|fn rows -> Macaw.Data.Ops.transform(rows, "double") end|,
                 operations: nil
               )

      assert [{1, {:operation_name, :literal}}] =
               reasons(~S|fn rows -> Macaw.Data.Ops.transform(rows, rows) end|, operations: nil)

      assert Sandbox.format_error({1, {:operation_name, :literal}}) ==
               "line 1: a Macaw.Data.Ops call names its operation with a literal string"

      assert Sandbox.format_error({2, {:unknown_operation, :aggregate, "mode"}}) ==
               ~S|line 2: aggregate "mode" is not available: no enabled package provides it|

      assert Sandbox.format_error({3, {:needs, "layout", :frame}}) ==
               ~S|line 3: transform "layout" needs a frame, which a derived source does not have|
    end

    @tag verifies: ["operations-sandbox-calls", "operations-sandbox-ops"]
    test "a bad option raises when the call runs, and the runner reports it" do
      assert {:error, :raised, ArgumentError} =
               call(~S|fn rows -> Macaw.Data.Ops.aggregate(rows, "quantile") end|, [[1, 2]])

      assert {:error, :raised, ArgumentError} =
               call(~S|fn rows -> Macaw.Data.Ops.transform(rows, "take", %{n: -1}) end|, [@rows])

      assert {:error, :raised, ArgumentError} =
               call(
                 ~S|fn rows -> Macaw.Data.Ops.transform(rows, "take", %{op: "sort", n: 1}) end|,
                 [@rows]
               )

      assert_raise ArgumentError, "quantile: p: is required", fn ->
        Ops.aggregate([1], "quantile")
      end
    end

    @tag verifies: "operations-sandbox-calls"
    test "a host package's members are callable only where it is enabled" do
      source =
        ~S|fn rows -> Macaw.Data.Ops.transform(rows, "double", %{field: "cpu", as: "twice"}) end|

      rows = Enum.take(@rows, 2)

      assert {:ok, [%{"twice" => 60}, %{"twice" => 180}]} =
               call(source, [rows], operations: @hosted)

      assert {:error, [{1, {:unknown_operation, :transform, "double"}}]} = Sandbox.compile(source)

      assert_raise ArgumentError, ~r/compile needs the registry/, fn ->
        Sandbox.compile(source, operations: nil)
      end
    end
  end

  describe "the engine and the cache (spec/04 §6.1)" do
    @hosts Schema.new!(%{
             t: %{type: :number, window: true},
             host: %{type: :category},
             cpu: %{type: :number}
           })

    defp derived(elixir) do
      Derived.new!(id: :d, from: [hosts: nil], schema: %{n: %{type: :number}}, elixir: elixir)
    end

    defp run(engine) do
      delivery = Delivery.new(for(i <- 1..4, do: %{t: i, host: "h", cpu: i * 10}))
      engine |> Engine.push(%{hosts: delivery}, %{hosts: @hosts}, 0) |> Engine.run(0)
    end

    @tag verifies: "operations-sandbox-calls"
    test "the engine's packages decide what a stored function reaches, default closed" do
      source =
        derived(~S"""
        fn %{hosts: rows} ->
          doubled = Macaw.Data.Ops.transform(rows, "double", %{field: "cpu"})
          [%{n: Macaw.Data.Ops.aggregate(Enum.map(doubled, & &1["double"]), "sum")}]
        end
        """)

      {:ok, closed} = Engine.new(%{[:d] => source}, sources: [:hosts], debounce: 0)
      assert %{["d"] => %{kind: :restricted}} = Engine.faults(closed)

      {:ok, open} =
        Engine.new(%{[:d] => source},
          sources: [:hosts],
          debounce: 0,
          packages: [Macaw.Data.Test.Ops]
        )

      assert Engine.faults(open) == %{}
      assert Delivery.rows(Engine.outputs(run(open))[["d"]]) == [%{"n" => 200}]
    end

    @tag verifies: "operations-sandbox-calls"
    test "validate in context holds a name to the registry given, or only to being literal" do
      source =
        derived(
          ~S|fn %{hosts: rows} -> Macaw.Data.Ops.transform(rows, "double", %{field: "cpu"}) end|
        )

      assert Derived.validate(source, inputs: %{hosts: @hosts}) == :ok
      assert Derived.validate(source, inputs: %{hosts: @hosts}, operations: @hosted) == :ok

      assert {:error, [{[:elixir], {:check, 1, {:unknown_operation, :transform, "double"}}}]} =
               Derived.validate(source, inputs: %{hosts: @hosts}, operations: @own)
    end

    @tag verifies: "operations-sandbox-cache"
    test "the same source compiles once per registry digest" do
      source = ~S|fn rows -> Macaw.Data.Ops.aggregate(rows, "sum") end|

      {:ok, a, cache} = Cache.compile(Cache.new(), source, operations: @own)
      {:ok, b, cache} = Cache.compile(cache, source, operations: @own)
      assert a == b and map_size(cache.entries) == 1

      {:ok, c, cache} = Cache.compile(cache, source, operations: @hosted)
      assert map_size(cache.entries) == 2
      assert Sandbox.run(c, [[1, 2]]) == {:ok, 3}
      assert Operations.digest(@own) != Operations.digest(@hosted)
    end
  end
end
