defmodule Macaw.Data.ErrorTest do
  @moduledoc """
  The `!` twins' raise (spec/00 §5, macaw_data#130, #157): a `Macaw.Data.Error` holding
  the value twin's error term exactly, worded by the library's one formatter or the
  module's own words, never an `inspect`ed fault.
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.{Delivery, Error, Fault, Schema, Table}
  alias Macaw.Data.Derived.{Engine, Functions}
  alias Macaw.Data.Source.{Description, Finish, Order, Push, Request}
  alias Macaw.Data.Source.Conformance.Words

  doctest Macaw.Data.Fault
  doctest Macaw.Data.Error

  @schema Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})

  # The value twin answers `{:error, reason}`; the twin raises it, the same term, in words.
  defp same(value, bang, lead) do
    assert {:error, reason} = value.()
    error = assert_raise Error, bang
    assert error.reason == reason
    message = Exception.message(error)
    assert String.starts_with?(message, lead), message
    refute message =~ "{[", message
    refute message =~ "{:", message
    message
  end

  describe "the 13 sites that inspected their faults" do
    @tag verifies: "data-errors-twins"
    test "each raises its value twin's reason, worded" do
      same(
        fn -> Table.new([{"v", :number, ["x"]}]) end,
        fn -> Table.new!([{"v", :number, ["x"]}]) end,
        "not a table: v[0]: must be a number"
      )

      same(
        fn -> Request.new(budget: 0) end,
        fn -> Request.new!(budget: 0) end,
        "not a request: budget: must be a positive integer; now: is required"
      )

      same(
        fn -> Description.new(schema: 1) end,
        fn -> Description.new!(schema: 1) end,
        "not a description: schema: must be a Macaw.Data.Schema"
      )

      {:ok, engine} = Engine.new(%{}, sources: [], debounce: 0)

      same(
        fn -> Engine.source(engine, ["x"]) end,
        fn -> Engine.source!(engine, ["x"]) end,
        "not a derived source of the engine: path: is not a path the engine defines"
      )

      same(
        fn -> Push.new(:ticks, make_ref(), bogus: 1) end,
        fn -> Push.new!(:ticks, make_ref(), bogus: 1) end,
        "not a subscription's options: bogus: is not a key it takes"
      )

      delivery = Delivery.new!([%{"t" => 1, "v" => 2}])
      description = Description.new!(schema: @schema)
      request = Request.new!(now: ~U[2026-01-01 00:00:00Z])

      same(
        fn -> Finish.finish(delivery, description, request, bogus: 1) end,
        fn -> Finish.finish!(delivery, description, request, bogus: 1) end,
        "the delivery cannot be finished: bogus: is not a key it takes"
      )

      same(
        fn -> Finish.reduce(delivery, @schema, 10, "sort") end,
        fn -> Finish.reduce!(delivery, @schema, 10, "sort") end,
        ~s(the delivery cannot be reduced: reduce: "sort" is not a reducer the registry has)
      )

      same(
        fn -> Finish.ceiling(10, []) end,
        fn -> Finish.ceiling!(10, []) end,
        "not a ceiling: host: is required"
      )

      same(
        fn -> Order.sort([%{"v" => 1}], [{"w", :asc}], @schema) end,
        fn -> Order.sort!([%{"v" => 1}], [{"w", :asc}], @schema) end,
        ~s(an order the schema cannot sort by: order[0]: "w" is not a field the schema describes)
      )

      columns = Delivery.new!([%{"v" => "x"}], types: %{"v" => :number})

      same(
        fn -> Delivery.table(columns) end,
        fn -> Delivery.table!(columns) end,
        "the rows do not pack into a table: v[0]: must be a number"
      )

      same(
        fn -> Functions.registry([String]) end,
        fn -> Functions.registry!([String]) end,
        "not a registry of derived-source functions: String: is not a module of derived-source functions"
      )
    end

    @tag verifies: "data-errors-twins"
    test "the conformance kit's findings word their faults" do
      {:error, faults} = Description.new(schema: 1)
      words = Words.words({:description_invalid, faults})
      assert words =~ "schema: must be a Macaw.Data.Schema"
      refute words =~ "{["

      {:error, faults} = Request.new(budget: 0)
      words = Words.words({:probe, [budget: 0], faults})
      assert words =~ "(budget: must be a positive integer; now: is required)"
    end
  end

  describe "the formatter" do
    @tag verifies: "data-errors-twins"
    test "words a fault list by path, a bare reason, a module's own reason and an unknown one" do
      assert Fault.sentence([{[:a, 0], :required}, {[], {:type, :keyword}}], root: "opts") ==
               "a[0]: is required; opts: must be a keyword list"

      assert Fault.sentence({:rank, 3}) ==
               "is a tensor of rank 3; a source's tensor has rank 1 or 2"

      assert Fault.sentence([{[:x], :mine}], words: fn :mine -> "is mine" end) == "x: is mine"
      assert Fault.sentence([{[:x], {:odd, 1}}]) == "x: {:odd, 1}"
    end

    @tag verifies: "data-errors-twins"
    test "a twin with words of its own keeps them, and the term rides along" do
      error = assert_raise Error, fn -> Macaw.Data.Unit.dimension!("furlong") end
      assert {:error, error.reason} == Macaw.Data.Unit.dimension("furlong")
      assert Exception.message(error) == Macaw.Data.Unit.format_error(error.reason)
    end
  end
end
