defmodule Macaw.Data.ImplicitFaultsTest do
  @moduledoc """
  Errors are values where an implicit raise once answered (spec/00 §5, macaw_data#121):
  an option a function does not take, a missing required one, and a quantity, unit,
  system or metric kind outside the vocabulary are faults, never a `KeyError`,
  `ArgumentError` or `FunctionClauseError`.
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.{Delivery, Derived, Quantity}
  alias Macaw.Data.Derived.Engine
  alias Macaw.Data.Source.{Finish, Push}

  # A term the type checker cannot see through: a call it can prove raises is still made,
  # on purpose, as the twin's raise is what the test asserts.
  defp opaque(term), do: :erlang.binary_to_term(:erlang.term_to_binary(term))

  defp stored(id) do
    Derived.new!(
      id: id,
      from: [hosts: nil],
      schema: %{n: %{type: :number}},
      elixir: "fn %{hosts: rows} -> [%{n: Enum.count(rows)}] end"
    )
  end

  @tag verifies: "data-errors-implicit"
  test "an option a function does not take is {[key], :unknown_key}; a missing required one {[key], :required}" do
    delivery = Delivery.new!([%{v: 1}])
    assert Delivery.table(delivery, sort: true) == {:error, [{[:sort], :unknown_key}]}

    assert Derived.validate(stored(:a), input: %{}) == {:error, [{[:input], :unknown_key}]}

    assert Engine.new(%{[:a] => stored(:a)}, sources: [:hosts], retries: 3) ==
             {:error, [{[], [:retries], :unknown_key}]}

    {:ok, engine} = Engine.new(%{[:a] => stored(:a)}, sources: [:hosts])
    assert {:ok, _output} = Engine.source(engine, [:a])
    assert Engine.source(engine, [:nope]) == {:error, [{[:path], :unknown_path}]}
    assert Engine.source(engine, [:a], shared: true) == {:error, [{[:shared], :unknown_key}]}

    ref = make_ref()
    assert {:ok, %Push{}} = Push.new(:feed, ref)
    assert Push.new(:feed, ref, size: 3) == {:error, [{[:size], :unknown_key}]}

    assert Finish.ceiling(5, page: 2) == {:error, [{[:host], :required}]}
    assert Finish.ceiling(5, host: 10, floor: 1) == {:error, [{[:floor], :unknown_key}]}
    assert Finish.ceiling(5, :host) == {:error, [{[], {:type, :keyword}}]}

    assert_raise Macaw.Data.Error, fn -> Push.new!(:feed, ref, size: 3) end
    assert_raise Macaw.Data.Error, fn -> Finish.ceiling!(5, page: 2) end
    assert_raise Macaw.Data.Error, fn -> Engine.source!(engine, [:nope]) end
  end

  @tag verifies: "data-errors-implicit"
  test "a quantity, unit, system or metric kind outside the vocabulary is Quantity's fault" do
    for fun <- [
          &Quantity.base_unit/1,
          &Quantity.kind/1,
          &Quantity.bounds/1,
          &Quantity.additivity/1
        ] do
      assert fun.(:vibes) == {:error, {:unknown_quantity, :vibes}}
    end

    assert Quantity.bounds(:vibes, "s") == {:error, {:unknown_quantity, :vibes}}
    assert Quantity.additivity(:count, :histogram) == {:error, {:unknown_metric_kind, :histogram}}
    assert Quantity.family(:vibes, "s") == {:error, {:unknown_quantity, :vibes}}
    assert Quantity.family(:duration, "sec") == {:error, {:unknown_atom, "sec"}}
    assert Quantity.family(:duration, 7) == {:error, {:syntax, "7"}}
    assert Quantity.family(:mass, "kg", :imperial) == {:error, {:unknown_system, :imperial}}

    assert {:ok, "s"} = Quantity.base_unit(:duration)
    assert {:ok, :cyclic} = Quantity.kind(:angle)
    assert {:ok, %{across: true}} = Quantity.additivity(nil)

    assert_raise Macaw.Data.Error, ~r/:vibes is not a quantity/, fn -> Quantity.kind!(:vibes) end

    assert_raise Macaw.Data.Error, ~r/:imperial is not a unit system/, fn ->
      Quantity.family!(:mass, "kg", opaque(:imperial))
    end
  end
end
