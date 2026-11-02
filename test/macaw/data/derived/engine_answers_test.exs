defmodule Macaw.Data.Derived.EngineAnswersTest do
  # A columnar answer (spec/02 §1.2, §8.2, macaw_data#107): a source that reads its inputs
  # as columns may answer a table or a column map, held to its schema column by column and
  # packed without a row. It answers the output its rows would, and faults where its rows
  # would. Not async: the reductions comparison counts exactly only where no other test
  # loads or purges code (`Macaw.Data.Test.Work`).
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Derived, Schema, Table}
  alias Macaw.Data.Derived.{Columns, Engine, Functions}
  alias Macaw.Data.Test.{Gen, Work}

  @fields %{
    id: %{type: :category, identity: true},
    n: %{type: :number},
    s: %{type: :category, values: [:ok, :warn]},
    t: %{type: :time},
    txt: %{type: :text}
  }

  @schema Schema.new!(@fields)

  defmodule Host do
    use Macaw.Data.Derived.Functions

    # The input is the answer: as rows, as a column map, and as the table itself.
    defsource(as_rows(inputs), do: Columns.rows!(inputs["in"]))

    defsource as_map(inputs) do
      t = inputs["in"]
      Map.new(Columns.names!(t), &{&1, Columns.column!(t, &1)})
    end

    defsource(as_table(inputs), do: inputs["in"])

    # Per identity, each entity's table, or its rows.
    defsource(entity_table(t), do: Columns.take!(t, -1))
    defsource(entity_rows(t), do: Columns.rows!(Columns.take!(t, -1)))

    defsource many_rows(inputs) do
      t = inputs["in"]
      for {n, s} <- Enum.zip(Columns.numbers!(t, "n"), Columns.column!(t, "s")), do: %{n: n, s: s}
    end

    defsource many_columns(inputs) do
      t = inputs["in"]
      %{n: Columns.numbers!(t, "n"), s: Columns.column!(t, "s")}
    end
  end

  defp engine(sources) do
    {:ok, engine} =
      Engine.new(sources, sources: [:in], debounce: 0, functions: Functions.registry([Host]))

    engine
  end

  defp source(id, function, opts \\ []) do
    Derived.new!(
      [id: id, from: [in: nil], schema: @fields, input: :columns, function: function] ++ opts
    )
  end

  defp a_row do
    fixed_map(%{
      id: member_of(["a", "b", "c", "d"]),
      n:
        frequency([{1, constant(nil)}, {4, integer(-9..9)}, {4, Gen.float(min: -9.0, max: 9.0)}]),
      s: member_of([nil, "ok", "warn"]),
      t: one_of([constant(nil), map(integer(0..9), &DateTime.from_unix!/1)]),
      txt: member_of([nil, "x", ""])
    })
  end

  defp packed(rows) do
    Table.new!(
      for {name, %{type: type}} <- Enum.sort(@fields),
          do: {name, type, Enum.map(rows, &Map.get(&1, name))}
    )
  end

  # -- the same output ---------------------------------------------------------------------

  @tag verifies: "derived-conform-columns"
  property "a table, a column map and rows of the same answer give one output" do
    engine =
      engine(%{
        ["r"] => source(:r, :as_rows),
        ["m"] => source(:m, :as_map),
        ["t"] => source(:t, :as_table)
      })

    check all(rows <- list_of(a_row(), max_length: 30), max_runs: 100) do
      engine =
        engine
        |> Engine.push(%{in: Delivery.new!(packed(rows))}, %{in: @schema}, 0)
        |> Engine.run(0)

      assert Engine.faults(engine) == %{}
      outputs = Engine.outputs(engine)
      assert Table.equal?(outputs[["r"]].rows, outputs[["m"]].rows)
      assert Table.equal?(outputs[["r"]].rows, outputs[["t"]].rows)

      assert Table.rows(outputs[["m"]].rows) ==
               Enum.map(rows, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))
    end
  end

  @tag verifies: "derived-conform-columns"
  test "a table in the output's layout is the output as it is; any other is packed under the schema" do
    laid =
      Table.new!(
        for {name, type, v} <- [
              {"id", :category, "a"},
              {"n", :number, 1},
              {"s", :category, "ok"},
              {"t", :time, nil},
              {"txt", :text, "x"}
            ],
            do: {name, type, [v]}
      )

    {:ok, ^laid} = Derived.conform(source(:c, :f), laid)

    # Atom names, another order, a column absent: packed by name, the absent one nil.
    other = Table.new!([{:n, :number, [2]}, {:id, :category, ["b"]}])
    {:ok, table} = Derived.conform(source(:c, :f), other)
    assert Table.names(table) == ["id", "n", "s", "t", "txt"]
    assert Table.rows(table) == [%{"id" => "b", "n" => 2, "s" => nil, "t" => nil, "txt" => nil}]
  end

  @tag verifies: "derived-conform-columns"
  test "under per, an entity's table answer is read as its rows and stamped with its identity" do
    per = [per: :identity, schema: @fields]

    engine =
      engine(%{["t"] => source(:t, :entity_table, per), ["r"] => source(:r, :entity_rows, per)})

    rows = [
      %{id: "a", n: 1, s: "ok", t: nil, txt: nil},
      %{id: "b", n: 2, s: nil, t: nil, txt: nil},
      %{id: "a", n: 3, s: "warn", t: nil, txt: nil}
    ]

    engine =
      engine
      |> Engine.push(%{in: Delivery.new!(packed(rows))}, %{in: @schema}, 0)
      |> Engine.run(0)

    assert Engine.faults(engine) == %{}
    outputs = Engine.outputs(engine)
    assert Table.equal?(outputs[["t"]].rows, outputs[["r"]].rows)
    assert Enum.map(Table.rows(outputs[["t"]].rows), & &1["n"]) == [3, 2]
  end

  # -- the faults ----------------------------------------------------------------------------

  defp c, do: source(:c, :f)

  @tag verifies: "derived-conform-columns"
  test "each fault of a columnar answer, at its index and field, a whole column's at nil" do
    assert Derived.conform(c(), %{w: [1]}) == {:error, {nil, "w", :undescribed}}
    assert Derived.conform(c(), %{1 => [1]}) == {:error, {nil, nil, :undescribed}}
    assert Derived.conform(c(), %{:n => [1], "n" => [2]}) == {:error, {nil, "n", :duplicate}}
    assert Derived.conform(c(), %{id: ["a"], n: 1}) == {:error, {nil, "n", :not_a_column}}
    assert Derived.conform(c(), %{id: ["a", "b"], n: [1]}) == {:error, {nil, "n", {:length, 2}}}

    assert Derived.conform(c(), %{id: ["a", "b"], n: [1, "x"]}) ==
             {:error, {1, "n", {:type, :number}}}

    assert Derived.conform(c(), %{id: ["a"], s: [:bad]}) == {:error, {0, "s", :not_in_values}}
    assert Derived.conform(c(), %{id: ["a", nil], n: [1, 2]}) == {:error, {1, "id", :no_identity}}
    assert Derived.conform(c(), %{n: [1]}) == {:error, {0, "id", :no_identity}}
    assert {:ok, _empty} = Derived.conform(c(), %{})

    # The lowest index first; at one index an identity gap before a value fault.
    assert Derived.conform(c(), %{id: ["a", "b", nil], n: [1, "x", "y"]}) ==
             {:error, {1, "n", {:type, :number}}}

    assert Derived.conform(c(), %{id: [nil], n: ["x"]}) == {:error, {0, "id", :no_identity}}

    # A table: a column of another type is a whole column's fault; text and category are
    # held value by value, as a table of those types holds any value.
    assert Derived.conform(c(), Table.new!([{"n", :text, ["1"]}])) ==
             {:error, {nil, "n", {:type, :number}}}

    assert Derived.conform(c(), Table.new!([{"w", :number, [1]}])) ==
             {:error, {nil, "w", :undescribed}}

    assert Derived.conform(c(), Table.new!([{"id", :category, ["a"]}, {"txt", :text, [1]}])) ==
             {:error, {0, "txt", {:type, :text}}}

    assert Derived.conform(c(), Table.new!([{"id", :category, [true]}])) ==
             {:error, {0, "id", {:type, :category}}}

    assert Derived.conform(c(), Table.new!([{"id", :category, ["a"]}, {"s", :category, ["no"]}])) ==
             {:error, {0, "s", :not_in_values}}

    assert Derived.conform(c(), Table.new!([{"id", :category, ["a", nil]}])) ==
             {:error, {1, "id", :no_identity}}

    # A rows source answers rows alone, as before.
    rows = Derived.new!(id: :r, from: [in: nil], schema: @fields, function: :f)
    assert Derived.conform(rows, %{id: ["a"]}) == {:error, {nil, nil, :not_a_list}}

    assert Derived.conform(rows, Table.new!([{"id", :category, ["a"]}])) ==
             {:error, {nil, nil, :not_a_list}}
  end

  @tag verifies: "derived-conform-columns"
  property "one fault at one row is the fault rows would answer, and holds no value" do
    check all(
            rows <- list_of(a_row(), min_length: 1, max_length: 10),
            at <- integer(0..9),
            {field, bad} <-
              member_of([
                {:n, "marker-q9"},
                {:s, "marker-q9"},
                {:id, nil},
                {:t, "marker-q9"},
                {:txt, 7}
              ]),
            max_runs: 200
          ) do
      at = rem(at, length(rows))
      rows = List.update_at(rows, at, &Map.put(&1, field, bad))

      columns =
        Map.new(Map.keys(@fields), fn name -> {name, Enum.map(rows, &Map.get(&1, name))} end)

      expected =
        Derived.conform(
          Derived.new!(id: :r, from: [in: nil], schema: @fields, function: :f),
          rows
        )

      assert {:error, {^at, _field, _reason}} = expected
      assert Derived.conform(c(), columns) == expected
      refute inspect(Derived.conform(c(), columns)) =~ "marker-q9"
    end
  end

  # -- the cost -----------------------------------------------------------------------------

  # One recompute answering 5,000 rows of two fields from a 5,000-row input, as rows and
  # as a column map: the engine's own process, which conforms and packs the answer (the
  # function's call is counted in its sandbox, apart). When this was written: rows
  # 976,673, a column map 164,585 (#113).
  @tag verifies: "derived-conform-columns-cost"
  test "answering 5,000 rows as a column map costs the engine less than answering them as rows" do
    out = %{n: %{type: :number}, s: %{type: :category, values: [:ok, :warn]}}
    schema = Schema.new!(out)

    input =
      Table.new!([
        {"n", :number, Enum.map(1..5_000, &(&1 * 0.5))},
        {"s", :category, Enum.map(1..5_000, &if(rem(&1, 3) == 0, do: "ok", else: "warn"))}
      ])

    count = fn function ->
      engine =
        engine(%{
          ["a"] =>
            Derived.new!(
              id: :a,
              from: [in: nil],
              schema: out,
              input: :columns,
              function: function
            )
        })

      engine = engine |> Engine.push(%{in: Delivery.new!(input)}, %{in: schema}, 0)
      {work, done} = Work.reductions(fn -> Engine.run(engine, 0) end)
      assert Engine.faults(done) == %{}
      {work, Engine.outputs(done)[["a"]].rows}
    end

    {rows_work, rows_table} = count.(:many_rows)
    {map_work, map_table} = count.(:many_columns)
    assert Table.equal?(rows_table, map_table)
    assert map_work < rows_work
    assert map_work * 4 < rows_work
    assert map_work < 250_000
  end
end
