defmodule Macaw.Data.ParameterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Macaw.Layers.Color, only: [sigil_RGB: 2]

  alias Macaw.Data.{Parameter, Source}
  alias Macaw.Data.Source.Request
  alias Macaw.Data.Test.Sources.Asked

  doctest Parameter

  @tag verifies: "params-shape"
  test "a parameter declaration is checked: its type, default, values and keys, every fault at once" do
    assert Parameter.keys() == [:type, :default, :values, :legal_for, :bindable, :doc]

    for type <- [:time, :number, :category, :text, :color, :point, :term, {:document, :page}],
        do: assert(Parameter.check(%{type: type}) == :ok, inspect(type))

    assert Parameter.check(%{
             type: :category,
             values: ["max", "mean"],
             default: "max",
             legal_for: {"primary", "v", :values},
             bindable: true,
             doc: "aggregation"
           }) == :ok

    assert Parameter.check(%{
             type: :number,
             default: "5",
             values: [1, "two"],
             legal_for: "primary",
             bindable: :yes,
             doc: :bins,
             scale: 2
           }) ==
             {:error,
              [
                {[:bindable], {:type, :boolean}},
                {[:default], {:type, :number}},
                {[:default], :not_in_values},
                {[:doc], {:type, :string}},
                {[:legal_for], {:type, :legal_for}},
                {[:scale], :unknown_key},
                {[:values, 1], {:type, :number}}
              ]}

    assert Parameter.check(%{default: 1}) == {:error, [{[:type], :required}]}

    assert Parameter.check(%{type: :float}) ==
             {:error,
              [{[:type], {:enum, [:time, :number, :category, :text, :color, :point, :term]}}]}

    assert Parameter.check(type: :number) == {:error, [{[], {:type, :parameter}}]}

    assert Parameter.check(%{type: :number, values: []}) ==
             {:error, [{[:values], {:type, :values}}]}
  end

  @tag verifies: "params-types"
  test "a value conforms to its type, nil to none but :term" do
    yes = [
      time: ~U[2026-10-27 12:00:00Z],
      number: 1.5,
      category: :ok,
      category: "ok",
      category: 3,
      text: "x",
      color: ~RGB"#fff",
      color: {:alpha, {:color, :good}, 0.5},
      point: {-73.98, 40.75},
      term: nil,
      term: {:anything}
    ]

    no = [
      time: "2026-10-27",
      number: "1",
      category: true,
      category: nil,
      text: :x,
      color: "good",
      color: "#fff",
      color: :good,
      point: {200, 0},
      point: {0, 91},
      point: [0, 0]
    ]

    for {type, v} <- yes, do: assert(Parameter.conforms?(type, v), inspect({type, v}))
    for {type, v} <- no, do: refute(Parameter.conforms?(type, v), inspect({type, v}))
    assert Parameter.conforms?({:document, :page}, %{"title" => "x"})
    refute Parameter.conforms?({:document, :page}, [])
  end

  @every_type [:time, :number, :category, :text, :color, :point, :term, {:document, :page}]

  describe "a nil default" do
    @tag verifies: "params-nil-default"
    test "passes check on every type, beside values that don't list it" do
      for type <- @every_type do
        assert Parameter.check(%{type: type, default: nil}) == :ok, inspect(type)
        assert Parameter.check(%{type: type, default: nil, bindable: true}) == :ok, inspect(type)
      end

      assert Parameter.check(%{type: :text, default: nil, values: ["a", "b"]}) == :ok
      assert Parameter.check(%{type: :term, default: nil, values: ["a", "b"]}) == :ok
      assert Parameter.check(%{type: :number, default: nil, values: nil}) == :ok

      # nil is legal unlisted, and still no value of the type.
      assert Parameter.check(%{type: :text, default: nil, values: ["a", nil]}) ==
               {:error, [{[:values, 1], {:type, :text}}]}

      assert Parameter.check(%{type: :category, values: ["a"], default: "b"}) ==
               {:error, [{[:default], :not_in_values}]}
    end

    @tag verifies: "params-nil-default"
    test "is the only thing nil conforms to, and a type's own rule is unchanged" do
      for type <- @every_type -- [:term] do
        assert Parameter.conforms?(%{type: type, default: nil}, nil), inspect(type)
        refute Parameter.conforms?(%{type: type}, nil), inspect(type)
        refute Parameter.conforms?(type, nil), inspect(type)
      end

      refute Parameter.conforms?(%{type: :number, default: 5}, nil)
      refute Parameter.conforms?(%{type: :text, default: ""}, nil)

      # A parameter's other values read as its type's.
      assert Parameter.conforms?(%{type: :number, default: nil}, 5)
      refute Parameter.conforms?(%{type: :number, default: nil}, "5")
      refute Parameter.conforms?(%{default: nil}, nil)

      # :term takes nil whatever its default, as it takes anything.
      assert Parameter.conforms?(:term, nil)
      assert Parameter.conforms?(%{type: :term}, nil)
    end

    @tag verifies: "params-nil-default"
    test "validate fills nil when absent, and nil given is the same as absent" do
      for type <- @every_type do
        params = %{"p" => %{type: type, default: nil}}
        assert Parameter.validate(params, %{}) == {:ok, %{"p" => nil}}, inspect(type)
        assert Parameter.validate(params, %{"p" => nil}) == {:ok, %{"p" => nil}}, inspect(type)
      end

      low = %{"low" => %{type: :number, default: nil}}
      assert Parameter.validate(low, %{"low" => 3}) == {:ok, %{"low" => 3}}
      assert Parameter.validate(low, %{"low" => "3"}) == {:error, [{["low"], {:type, :number}}]}

      closed = %{"mode" => %{type: :category, values: ["a", "b"], default: nil}}
      assert Parameter.validate(closed, %{}) == {:ok, %{"mode" => nil}}
      assert Parameter.validate(closed, %{"mode" => nil}) == {:ok, %{"mode" => nil}}
      assert Parameter.validate(closed, %{"mode" => "a"}) == {:ok, %{"mode" => "a"}}

      assert Parameter.validate(closed, %{"mode" => "c"}) ==
               {:error, [{["mode"], {:enum, ["a", "b"]}}]}

      bindable = %{"at" => %{type: :number, default: nil, bindable: true}}
      assert Parameter.validate(bindable, %{}) == {:ok, %{"at" => nil}}
    end

    @tag verifies: "params-nil-default"
    test "leaves a required parameter and any other default refusing nil" do
      assert Parameter.validate(%{"low" => %{type: :number}}, %{"low" => nil}) ==
               {:error, [{["low"], {:type, :number}}]}

      assert Parameter.validate(%{"low" => %{type: :number}}, %{}) ==
               {:error, [{["low"], :required}]}

      assert Parameter.validate(%{"low" => %{type: :number, default: 5}}, %{"low" => nil}) ==
               {:error, [{["low"], {:type, :number}}]}

      # A required :term keeps taking nil; its values are still closed.
      assert Parameter.validate(%{"any" => %{type: :term}}, %{"any" => nil}) ==
               {:ok, %{"any" => nil}}

      assert Parameter.validate(%{"any" => %{type: :term, values: [1]}}, %{"any" => nil}) ==
               {:error, [{["any"], {:enum, [1]}}]}
    end

    @tag verifies: "params-nil-default-fetch"
    test "reaches a source the same given nil or not given" do
      source = Asked.new(self())
      {:ok, description} = Source.describe(source, nil)
      now = ~U[2026-11-04 00:00:00Z]

      assert {:ok, _} = Source.fetch(source, description, %Request{now: now})
      assert_received {:asked, %{"floor" => nil} = absent}

      given = %Request{now: now, params: %{"floor" => nil}}
      assert {:ok, _} = Source.fetch(source, description, given)
      assert_received {:asked, ^absent}

      required = Asked.new(self(), %{"floor" => %{type: :number}})
      {:ok, description} = Source.describe(required, nil)

      assert Source.fetch(required, description, given) ==
               {:error, {:params, [{["floor"], {:type, :number}}]}}

      refute_received {:asked, _}
    end
  end

  @tag verifies: "params-validate"
  test "given values are checked by name\
, every fault at once, defaults filled in" do
    params = %{
      "agg" => %{type: :category, values: ["max", "mean"]},
      "bins" => %{type: :number, default: 10},
      "at" => %{type: :time, default: nil}
    }

    assert Parameter.validate(params, %{"agg" => "mean"}) ==
             {:ok, %{"agg" => "mean", "bins" => 10, "at" => nil}}

    assert Parameter.validate(params, %{"bins" => "ten", "zoom" => 1}) ==
             {:error,
              [{["agg"], :required}, {["bins"], {:type, :number}}, {["zoom"], :unknown_param}]}

    assert Parameter.validate(params, %{"agg" => "sum"}) ==
             {:error, [{["agg"], {:enum, ["max", "mean"]}}]}

    assert Parameter.validate(%{}, %{}) == {:ok, %{}}
  end

  @tag verifies: "params-validate"
  property "a value in a parameter's closed values is accepted, any other is refused by name" do
    check all(
            values <-
              uniq_list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 5),
            given <- string(:alphanumeric, min_length: 1)
          ) do
      params = %{"p" => %{type: :category, values: values}}

      case Parameter.validate(params, %{"p" => given}) do
        {:ok, %{"p" => ^given}} -> assert given in values
        {:error, [{["p"], {:enum, ^values}}]} -> refute given in values
      end
    end
  end
end
