defmodule Macaw.Data.Derived.FunctionsTest do
  # A host's functions: defsource and the registry (spec/02 §7). Ported from visualize's
  # `Visualize.VirtualSourcesTest`: the registry is explicit and default closed, keyed by
  # each name's string with its arity, and a context carries no variables.
  use ExUnit.Case, async: true

  alias Macaw.Data.Derived.{Functions, Sandbox}

  doctest Functions

  defmodule Sources do
    use Macaw.Data.Derived.Functions

    defsource(doubled(rows), do: Enum.map(rows, &(&1 * 2)))

    defsource last([row | _]) when is_map(row) do
      row.cpu
    end

    defsource(last([]), do: nil)

    defsource(runaway(_rows), do: Enum.to_list(1..100_000_000_000))

    defsource bins(inputs, context) do
      {map_size(inputs), context["inputs"]["hosts"]["capped"]}
    end
  end

  defmodule Other do
    use Macaw.Data.Derived.Functions
    defsource(doubled(rows), do: rows)
  end

  @tag verifies: "derived-defsource"
  test "a defsource is a public def, tested as any function" do
    assert Sources.doubled([1, 2]) == [2, 4]
    assert Sources.last([%{cpu: 3}]) == 3
    assert Sources.last([]) == nil
  end

  @tag verifies: "derived-defsource"
  test "its source is captured when the module compiles, in definition order, every clause once" do
    assert Sources.__derived__() == [
             {:doubled, 1, "fn rows -> Enum.map(rows, &(&1 * 2)) end"},
             {:last, 1, "fn\n  [row | _] when is_map(row) -> row.cpu\n  [] -> nil\nend"},
             {:runaway, 1, "fn _rows -> Enum.to_list(1..100_000_000_000) end"},
             {:bins, 2,
              "fn inputs, context -> {map_size(inputs), context[\"inputs\"][\"hosts\"][\"capped\"]} end"}
           ]
  end

  @tag verifies: "derived-defsource"
  test "a head of two arguments takes the context, and its arity is recorded" do
    context = %{"inputs" => %{"hosts" => %{"capped" => true}}}
    assert Sources.bins(%{"hosts" => []}, context) == {1, true}
    assert {:ok, {0, nil}} = Sandbox.run(&Sources.bins/2, [%{}, %{"inputs" => %{}}])
  end

  @tag verifies: "derived-defsource"
  test "trusted, but bounded: it runs through the same runner" do
    assert {:ok, [2]} = Sandbox.run(&Sources.doubled/1, [[1]])
    assert {:error, :memory, 100_000} = Sandbox.run(&Sources.runaway/1, [[]], max_heap: 100_000)
  end

  @tag verifies: "derived-registry"
  test "the registry: the modules given and nothing else, by name string with module and arity" do
    assert Functions.registry([Sources]) == %{
             "doubled" => {Sources, 1},
             "last" => {Sources, 1},
             "runaway" => {Sources, 1},
             "bins" => {Sources, 2}
           }

    # Default closed: no modules, no functions, whatever the application environment holds.
    Application.put_env(:macaw_data, :derived_functions, [Sources])
    on_exit(fn -> Application.delete_env(:macaw_data, :derived_functions) end)
    assert Functions.registry([]) == %{}

    assert_raise ArgumentError, ~r/defined by both/, fn ->
      Functions.registry([Sources, Other])
    end

    assert_raise ArgumentError, ~r/not a derived-source function module/, fn ->
      Functions.registry([Enum])
    end
  end

  @tag verifies: "derived-defsource"
  test "a head of another arity, two arities of one name, or a body other than do, is a compile error" do
    assert_raise CompileError, ~r/one argument/, fn ->
      Code.eval_string("""
      defmodule Macaw.Data.Derived.FunctionsTest.Bad do
        use Macaw.Data.Derived.Functions
        defsource three(a, b, c), do: {a, b, c}
      end
      """)
    end

    assert_raise CompileError, ~r/clauses of 1 and 2 arguments/, fn ->
      Code.eval_string("""
      defmodule Macaw.Data.Derived.FunctionsTest.Bad3 do
        use Macaw.Data.Derived.Functions
        defsource both(a), do: a
        defsource both(a, b), do: {a, b}
      end
      """)
    end

    assert_raise CompileError, ~r/do block alone/, fn ->
      Code.eval_string("""
      defmodule Macaw.Data.Derived.FunctionsTest.Bad2 do
        use Macaw.Data.Derived.Functions
        defsource one(a), do: a, else: a
      end
      """)
    end
  end
end
