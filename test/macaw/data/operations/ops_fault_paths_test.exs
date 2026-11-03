defmodule Macaw.Data.Operations.OpsFaultPathsTest do
  # Where `Macaw.Data.Ops`' faults are placed (spec/04 §6, macaw_data#139): an aggregate
  # call is no step, so its faults are step-less; a transform call runs a one-step
  # pipeline, so its faults are at that step's index, the name's at `[0, "op"]`.
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Macaw.Data.{Operations, Ops}
  alias Macaw.Data.Derived.Sandbox

  doctest Ops

  @own Operations.registry()
  @rows [%{v: 2}, %{v: 1}]

  defp call(source, args) do
    {:ok, compiled} = Sandbox.compile(source, operations: @own)
    Sandbox.run(compiled, args)
  end

  @tag verifies: "operations-sandbox-paths"
  test "from host code: an aggregate's faults are at [], [key] and [\"values\"]" do
    # The name, which no step holds.
    assert Ops.aggregate([1, 2], "mode") == {:error, [{[], {:unknown, :aggregate, "mode"}}]}

    assert Ops.aggregate([1, 2], "mode", %{p: 1}) ==
             {:error, [{[], {:unknown, :aggregate, "mode"}}]}

    # An option, at its key: wrong, missing, and one the aggregate does not read.
    assert Ops.aggregate([1, 2], "quantile", %{p: 2}) ==
             {:error, [{["p"], {:type, {:number, 0, 1}}}]}

    assert Ops.aggregate([1, 2], "quantile") == {:error, [{["p"], :required}]}

    assert Ops.aggregate([1, 2], "quantile", %{q: 1}) ==
             {:error, [{["p"], :required}, {["q"], {:invalid_for, "quantile"}}]}

    # A reading, and values that are no list, at "values"; options not a map at "options".
    assert Ops.aggregate(["x"], "sum") == {:error, [{["values"], {:reads, :number}}]}
    assert Ops.aggregate(:none, "sum") == {:error, [{["values"], {:type, {:list, :term}}}]}
    assert Ops.aggregate([1], "sum", p: 1) == {:error, [{["options"], {:type, :map}}]}

    # The words: a step-less path reads as its key alone.
    assert Ops.format_error({["p"], :required}) == "p: is required"

    assert_raise ArgumentError, ~r/^quantile: p: is required$/, fn ->
      Ops.aggregate!([1], "quantile")
    end
  end

  @tag verifies: "operations-sandbox-paths"
  test "from host code: a transform's faults are at [0, key], its name and an op option at [0, \"op\"]" do
    assert Ops.transform(@rows, "mode") == {:error, [{[0, "op"], {:unknown, :transform, "mode"}}]}

    assert Ops.transform(@rows, "take", %{op: "sort", n: 1}) ==
             {:error, [{[0, "op"], {:invalid_for, "take"}}]}

    assert Ops.transform(@rows, "take", %{"op" => "take", n: 1}) ==
             {:error, [{[0, "op"], {:invalid_for, "take"}}]}

    assert Ops.transform(@rows, "take", %{n: -1}) ==
             {:error, [{[0, "n"], {:type, {:integer, 0}}}]}

    assert Ops.transform(@rows, "take") == {:error, [{[0, "n"], :required}]}

    assert Ops.transform(@rows, "take", %{n: 1, q: 2}) ==
             {:error, [{[0, "q"], {:invalid_for, "take"}}]}

    # The words: step 1, the transform's only step.
    assert Ops.format_error({[0, "n"], :required}) == "step 1, n: is required"

    assert_raise ArgumentError, ~r/^take: step 1, n: is required$/, fn ->
      Ops.transform!(@rows, "take")
    end
  end

  @tag verifies: "operations-sandbox-paths"
  test "from a stored function: the same paths, the reasons spelled; an unknown name is refused at its line" do
    source = ~S"""
    fn rows ->
      %{
        option: Macaw.Data.Ops.aggregate([1, 2], "quantile", %{p: 2}),
        missing: Macaw.Data.Ops.aggregate([1, 2], "quantile"),
        reading: Macaw.Data.Ops.aggregate(["x"], "sum"),
        step: Macaw.Data.Ops.transform(rows, "take", %{n: -1}),
        op: Macaw.Data.Ops.transform(rows, "take", %{op: "sort", n: 1}),
        matched:
          case Macaw.Data.Ops.aggregate([1], "quantile") do
            {:error, [{["p"], :required}]} -> :at_key
            other -> other
          end
      }
    end
    """

    assert {:ok, answer} = call(source, [@rows])
    assert answer["option"] == {:error, [{["p"], {"type", {"number", 0, 1}}}]}
    assert answer["missing"] == {:error, [{["p"], "required"}]}
    assert answer["reading"] == {:error, [{["values"], {"reads", "number"}}]}
    # `integer` is one of the checker's words (a binary segment type), so it stays an atom.
    assert answer["step"] == {:error, [{[0, "n"], {"type", {:integer, 0}}}]}
    assert answer["op"] == {:error, [{[0, "op"], {"invalid_for", "take"}}]}
    assert answer["matched"] == "at_key"

    # A name is a literal the checker holds to the registry, so an unknown one never runs:
    # it is refused at its line, for an aggregate and a transform alike.
    assert {:error, faults} =
             Sandbox.check(
               ~S"""
               fn rows ->
                 Macaw.Data.Ops.aggregate(rows, "mode")
               end
               """,
               operations: @own
             )

    assert {2, {:unknown_operation, :aggregate, "mode"}} in faults

    assert {:error, faults} =
             Sandbox.check(~S|fn rows -> Macaw.Data.Ops.transform(rows, "mode") end|,
               operations: @own
             )

    assert {1, {:unknown_operation, :transform, "mode"}} in faults
  end
end
