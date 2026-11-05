defmodule Macaw.Data.StackValuesTest do
  @moduledoc """
  What `Macaw.Data.Stack` reads as a number, and what it answers for a value that is none
  or a sum past a float's range (spec/04 §4.8, §5, macaw_data#178).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Error, Fault, Operations, Stack, Table}
  alias Macaw.Data.Checked

  @orders [:none, :reverse, :ascending, :descending, :insideout, {:keys, [:b]}]
  @offsets [:none, :expand, :diverging, :silhouette, :wiggle]

  # Keeps the compiler from judging a deliberately bad value.
  defp opaque(value), do: :erlang.binary_to_term(:erlang.term_to_binary(value))

  defp stack(keys, order \\ :none, offset \\ :none),
    do: Stack.new() |> Stack.keys(keys) |> Stack.order(order) |> Stack.offset(offset)

  describe "a value that is no number" do
    @tag verifies: "operations-stack-values"
    test "is its fault by key and row under every order and offset, and the twin raises it" do
      for bad <- [false, "x", :a, ~U[2026-01-01 00:00:00Z], [1], {1, 2}, %{}],
          order <- @orders,
          offset <- @offsets do
        bad = opaque(bad)
        stack = stack([:a, :b], order, offset)
        rows = [%{a: 1, b: 2}, %{a: bad, b: 2}]

        assert Stack.generate(stack, rows) == {:error, [{[:a, 1], {:reads, :number}}]}
        error = assert_raise Error, fn -> Stack.generate!(stack, rows) end
        assert error.reason == [{[:a, 1], {:reads, :number}}]
        assert Exception.message(error) =~ "a[1]: must read a number"
      end
    end

    @tag verifies: "operations-stack-values"
    test "every one is reported at once" do
      rows = [%{a: "x", b: 1}, %{a: 1, b: :y}, %{a: false, b: 1}]

      assert Stack.generate(stack([:a, :b]), rows) ==
               {:error,
                [
                  {[:a, 0], {:reads, :number}},
                  {[:a, 2], {:reads, :number}},
                  {[:b, 1], {:reads, :number}}
                ]}
    end

    @tag verifies: "operations-stack-values"
    test "a caller's value function answering none is the same, nil among them" do
      for bad <- [nil, "x", false] do
        bad = opaque(bad)
        stack = stack([:a, :b]) |> Stack.value(fn _d, _key -> bad end)

        assert Stack.generate(stack, [%{a: 1}]) ==
                 {:error, [{[:a, 0], {:reads, :number}}, {[:b, 0], {:reads, :number}}]}

        assert_raise Error, fn -> Stack.generate!(stack, [%{a: 1}]) end
        assert_raise Error, fn -> Stack.series(stack, [:datum]) end
        assert Stack.stacked(stack, [:datum]) == Stack.generate(stack, [%{a: 1}])
      end
    end

    @tag verifies: "operations-stack-values"
    test "the default function still reads nil, and a key a row lacks, as zero" do
      assert {:ok, [%{points: [a]}, %{points: [b]}]} =
               Stack.generate(stack([:a, :b]), [%{a: nil, c: 1}])

      assert {a.value, a.y1, b.value, b.y1} == {0, 0, 0, 0}
    end

    @tag verifies: "operations-stack-values"
    test "a stack that does no arithmetic takes each value as it is" do
      for order <- [:none, :reverse, {:keys, [:a]}], value <- ["x", false, nil] do
        value = opaque(value)
        stack = stack([:a], order) |> Stack.value(fn _d, _key -> value end)

        assert {:ok, [%{index: 0, points: [%{value: ^value, y0: 0, y1: ^value}]}]} =
                 Stack.generate(stack, [%{a: 1}])

        assert [%{points: [%{y1: ^value}]}] = Stack.series(stack, [:datum])
      end

      # Any order that reads a value, or offset that does, refuses it.
      for {order, offset} <- [{:ascending, :none}, {:none, :expand}, {:none, :wiggle}] do
        assert Stack.generate(stack([:a], order, offset), [%{a: "x"}]) ==
                 {:error, [{[:a, 0], {:reads, :number}}]}
      end
    end

    @tag verifies: "operations-stack-values"
    test "a key of any term is a path that reads" do
      stack = stack([{1, 2}, :b]) |> Stack.value(fn _d, _key -> "x" end)
      assert {:error, faults} = Stack.generate(stack, [%{b: 1}])
      assert Fault.sentence(faults) =~ "must read a number"
    end

    @tag verifies: "operations-stack-values"
    test "no keys or no rows read nothing" do
      assert Stack.generate(stack([]), [%{a: "x"}]) == {:ok, []}
      assert Stack.generate(stack([:a, :b]), []) == {:ok, []}
      assert Stack.series(stack([]), [:datum]) == []
      assert Stack.series(stack([:a]), []) == []
    end
  end

  describe "a sum past a float's range" do
    @tag verifies: "operations-stack-values"
    test "is :overflow at the point, for every offset that sums" do
      high = %{a: 1.0e308, b: 1.0e308}

      for offset <- [:none, :diverging] do
        assert Stack.generate(stack([:a, :b], :none, offset), [high]) ==
                 {:error, [{[:b, 0], :overflow}]}
      end

      for offset <- [:expand, :silhouette] do
        assert {:error, [_ | _] = faults} = Stack.generate(stack([:a, :b], :none, offset), [high])
        assert Enum.all?(faults, &match?({[_key, 0], :overflow}, &1))
      end

      big = %{a: 10 ** 400, b: 1.5}
      assert Stack.generate(stack([:a, :b]), [big]) == {:error, [{[:b, 0], :overflow}]}

      assert {:error, [_ | _]} =
               Stack.generate(stack([:a], :none, :silhouette), [%{a: 10 ** 400}])

      assert {:error, [_ | _]} =
               Stack.generate(stack([:a, :b], :none, :wiggle), [
                 %{a: 1.0e200, b: 1.0},
                 %{a: 1.0e-100, b: 1.0e200}
               ])
    end

    @tag verifies: "operations-stack-values"
    test "an order's sum past it is the order's fault" do
      rows = [%{a: 1.0e308, b: 1}, %{a: 1.0e308, b: 1}]

      for order <- [:ascending, :descending, :insideout] do
        assert Stack.generate(stack([:a, :b], order), rows) ==
                 {:error, [{[:order], :overflow}]}
      end

      # Each series' sum holds; the sides they join don't.
      three = [%{a: 1.0e308, b: 1.0e308, c: 1.0e308}]

      assert Stack.generate(stack([:a, :b, :c], :insideout), three) ==
               {:error, [{[:order], :overflow}]}

      error =
        assert_raise Error, fn -> Stack.generate!(stack([:a, :b], :ascending), rows) end

      assert Exception.message(error) =~ "order: is beyond a float's range"
    end

    @tag verifies: "operations-stack-values"
    test "what holds is unchanged: a sum up to the largest float, and integers of any size" do
      assert {:ok, [_, %{points: [%{y0: 8.0e307, y1: 1.6e308}]}]} =
               Stack.generate(stack([:a, :b]), [%{a: 8.0e307, b: 8.0e307}])

      assert {:ok, [_, %{points: [%{y1: y1}]}]} =
               Stack.generate(stack([:a, :b]), [%{a: 10 ** 400, b: 1}])

      assert y1 == 10 ** 400 + 1

      # Past a float, and back within it, sums of integers stay exact.
      assert {:ok, [_, %{points: [%{y1: 0}]}]} =
               Stack.generate(stack([:a, :b]), [%{a: 10 ** 400, b: -(10 ** 400)}])

      assert {:ok, [%{points: [%{value: 1.0e308, y1: 1.0e308}]}]} =
               Stack.generate(stack([:a]), [%{a: 1.0e308}])
    end

    @tag verifies: "operations-stack-values"
    test "series/2 raises what stacked/2 answers" do
      stack = stack([:a, :b]) |> Stack.value(fn d, _key -> d end)

      assert Stack.stacked(stack, [1.0e308]) == {:error, [{[:b, 0], :overflow}]}
      error = assert_raise Error, fn -> Stack.series(stack, [1.0e308]) end
      assert error.reason == [{[:b, 0], :overflow}]
      assert Stack.series(stack, [1]) == Stack.stacked!(stack, [1])
      assert {:ok, Stack.series(stack, [1])} == Stack.stacked(stack, [1])
    end

    @tag verifies: "operations-stack-values"
    test "the stack step answers it as its fault at fields" do
      registry = Operations.registry()

      for offset <- @offsets -- [:wiggle], a <- [1.0e308, 10 ** 400] do
        table = Table.new!([{"a", :number, [a, 1.0]}, {"b", :number, [1.0e308, 2.0]}])

        assert Operations.apply(
                 registry,
                 [%{op: "stack", fields: ["a", "b"], offset: offset}],
                 table
               ) ==
                 {:error, [{[0, "fields"], :overflow}]}
      end

      table = Table.new!([{"a", :number, [1.0, 2.0]}, {"b", :number, [3.0, 4.0]}])
      assert {:ok, _} = Operations.apply(registry, [%{op: "stack", fields: ["a", "b"]}], table)
    end
  end

  describe "the arithmetic" do
    defp extreme do
      one_of([
        integer(-5..5),
        float(),
        member_of([
          1.7976931348623157e308,
          -1.7976931348623157e308,
          8.98846567431158e307,
          8.0e307,
          1.0e308,
          1.0e154,
          -1.0e155,
          1.0e-300,
          5.0e-324,
          -5.0e-324,
          0.5,
          0.0,
          10 ** 300,
          10 ** 308,
          10 ** 400,
          -(10 ** 400)
        ])
      ])
    end

    # The checked answer is the BEAM's, and :overflow exactly where the BEAM raises.
    defp agrees(checked, beam) do
      case checked.() do
        :overflow -> assert_raise ArithmeticError, beam
        answer -> assert answer === beam.()
      end
    end

    @tag verifies: "operations-stack-values"
    property "agrees with the BEAM's, over the whole range" do
      check all(a <- extreme(), b <- extreme(), max_runs: 500) do
        agrees(fn -> Checked.add(a, b) end, fn -> opaque(a) + opaque(b) end)
        agrees(fn -> Checked.multiply(a, b) end, fn -> opaque(a) * opaque(b) end)

        if b != 0,
          do: agrees(fn -> Checked.divide(a, b) end, fn -> opaque(a) / opaque(b) end)
      end
    end

    @tag verifies: "operations-stack-values"
    test "a result half a unit past the largest float is the line" do
      largest = 1.7976931348623157e308
      # 2^970, half a unit there: rounds to even, up, past the largest float.
      half_unit = :math.pow(2, 970)
      below = :math.pow(2, 969)

      assert Checked.add(largest, half_unit) == :overflow
      assert Checked.add(largest, below) == largest
    end

    @tag verifies: "operations-stack-values"
    test "overflow passes through every operation" do
      assert Checked.add(:overflow, 1) == :overflow
      assert Checked.add(1, :overflow) == :overflow
      assert Checked.multiply(:overflow, 1) == :overflow
      assert Checked.divide(:overflow, 1) == :overflow
      assert Checked.divide(1, :overflow) == :overflow
      assert Checked.negate(:overflow) == :overflow
    end
  end
end
