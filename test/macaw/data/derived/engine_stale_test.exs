defmodule Macaw.Data.Derived.EngineStaleTest do
  # A derived source's output is stale when any input's delivery is (spec/02 §8.7,
  # macaw_data#148): its rows are in the answer, so a cell drawn from it is drawn stale.
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Macaw.Data.{Delivery, Derived, Schema}
  alias Macaw.Data.Derived.{Columns, Engine, Functions}

  defmodule Host do
    use Macaw.Data.Derived.Functions

    defsource(rows_sum(inputs), do: [%{n: length(inputs["a"]) + length(inputs["b"])}])

    defsource(columns_sum(inputs),
      do: [%{n: Columns.size!(inputs["a"]) + Columns.size!(inputs["b"])}]
    )

    # The context's stale of each input, as the function is given it.
    defsource sees(_inputs, context) do
      [%{a: "#{context["inputs"]["a"]["stale"]}", b: "#{context["inputs"]["b"]["stale"]}"}]
    end
  end

  @schema Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number}})
  @schemas %{a: @schema, b: @schema}
  @n %{n: %{type: :number}}

  defp sources do
    stored = ~S"fn %{a: a, b: b} -> [%{n: Enum.count(a) + Enum.count(b)}] end"

    columns =
      ~S"""
      fn %{a: a, b: b} ->
        [%{n: Macaw.Data.Derived.Columns.size!(a) + Macaw.Data.Derived.Columns.size!(b)}]
      end
      """

    %{
      ["stored"] => Derived.new!(id: :stored, from: [a: nil, b: nil], schema: @n, elixir: stored),
      ["stored_columns"] =>
        Derived.new!(
          id: :stored_columns,
          from: [a: nil, b: nil],
          schema: @n,
          elixir: columns,
          input: :columns
        ),
      ["host"] =>
        Derived.new!(id: :host, from: [a: nil, b: nil], schema: @n, function: :rows_sum),
      ["host_columns"] =>
        Derived.new!(
          id: :host_columns,
          from: [a: nil, b: nil],
          schema: @n,
          function: :columns_sum,
          input: :columns
        ),
      ["next"] =>
        Derived.new!(
          id: :next,
          from: [stored: nil],
          schema: @n,
          elixir: "fn %{stored: [%{n: n}]} -> [%{n: n}] end"
        ),
      ["sees"] =>
        Derived.new!(
          id: :sees,
          from: [a: nil, b: nil],
          schema: %{a: %{type: :category}, b: %{type: :category}},
          function: :sees
        )
    }
  end

  defp engine(opts \\ []) do
    {:ok, engine} =
      Engine.new(
        sources(),
        [sources: [:a, :b], functions: Functions.registry!([Host]), debounce: 0] ++ opts
      )

    engine
  end

  defp at(rows, stale), do: Delivery.new!(rows, served: [stale: stale])
  defp rows(n), do: for(t <- 1..n, do: %{t: t, v: t})
  defp stale(engine, path), do: Engine.outputs(engine)[path].served.stale

  defp pulse(engine, a, b, now) do
    engine |> Engine.push(%{a: a, b: b}, @schemas, now) |> Engine.run(now)
  end

  @tag verifies: "derived-stale"
  test "a derived source is stale exactly when one of its inputs is, for every kind of function" do
    for {a?, b?} <- [{false, false}, {true, false}, {false, true}, {true, true}] do
      engine = pulse(engine(), at(rows(2), a?), at(rows(3), b?), 0)
      assert Engine.faults(engine) == %{}

      for path <- [["stored"], ["stored_columns"], ["host"], ["host_columns"]] do
        assert Delivery.rows!(Engine.outputs(engine)[path]) == [%{"n" => 5}]
        assert stale(engine, path) == (a? or b?), "#{inspect(path)} for #{inspect({a?, b?})}"
      end

      # A derived input over a stale input is stale too.
      assert stale(engine, ["next"]) == (a? or b?)
    end
  end

  @tag verifies: "derived-context-facts"
  test "the context gives each input's stale, a derived input its output's" do
    engine = pulse(engine(), at(rows(1), true), at(rows(1), false), 0)
    assert Delivery.rows!(Engine.outputs(engine)[["sees"]]) == [%{"a" => "true", "b" => "false"}]

    assert Derived.Context.new([
             %{
               key: :stored,
               delivery: Engine.outputs(engine)[["stored"]],
               schema: Schema.new!(@n)
             }
           ])["inputs"]["stored"]["stale"] == true
  end

  @tag verifies: "derived-stale"
  test "a pulse that changes only stale marks the readers, and the next fresh pulse clears it" do
    engine = pulse(engine(), at(rows(2), false), at(rows(3), false), 0)
    runs = Engine.runs(engine)[["next"]]
    refute stale(engine, ["stored"])

    # The same rows, now stale: a changed answer, so the reader runs again.
    engine = pulse(engine, at(rows(2), true), at(rows(3), false), 10)
    assert {stale(engine, ["stored"]), stale(engine, ["next"])} == {true, true}
    assert Engine.runs(engine)[["next"]] == runs + 1

    engine = pulse(engine, at(rows(2), false), at(rows(3), false), 20)
    assert {stale(engine, ["stored"]), stale(engine, ["next"])} == {false, false}
    assert Engine.runs(engine)[["next"]] == runs + 2
  end

  @tag verifies: "derived-stale"
  test "an idle input still counts: a source serving its last good answer goes idle, and stays stale" do
    engine = engine(idle_after: %{b: 1_000})
    engine = pulse(engine, at(rows(2), false), at(rows(3), true), 0)
    assert stale(engine, ["stored"])

    # b repeats its stale answer, so it is idle by now; a moves on. The output is still
    # drawn from b's stale rows, so it is still stale (unlike the watermark, §8.6).
    engine = pulse(engine, at(rows(4), false), at(rows(3), true), 2_000)
    assert Delivery.rows!(Engine.outputs(engine)[["stored"]]) == [%{"n" => 7}]
    assert stale(engine, ["stored"])
  end
end
