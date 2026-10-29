defmodule Macaw.Data.ParameterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Macaw.Layers.Color, only: [sigil_RGB: 2]

  alias Macaw.Data.Parameter

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

  @tag verifies: "params-validate"
  test "given values are checked by name, every fault at once, defaults filled in" do
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
