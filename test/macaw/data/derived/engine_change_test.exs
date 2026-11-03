defmodule Macaw.Data.Derived.EngineChangeTest do
  # A derived source's answer is held as a table, packed once under its schema, and a
  # change is told by the table's identity (spec/02 §8.2, §8.4; spec/01 §1.1.2;
  # macaw_data#47). Not async: the reductions guard counts exactly only where no other
  # test loads or purges code (`Macaw.Data.Test.Work`).
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Derived, Schema, Table}
  alias Macaw.Data.Derived.{Engine, Functions}
  alias Macaw.Data.Test.{Gen, Work}

  defmodule Echo do
    use Macaw.Data.Derived.Functions
    defsource(echo(inputs), do: inputs["given"])
  end

  @given Schema.new!(%{n: %{type: :number}})
  @output %{t: %{type: :time}, c: %{type: :category}, v: %{type: :number}}

  # `a` answers its input's rows as given; `b` reads `a`, so it runs only when `a`'s
  # answer changed.
  defp engine do
    a = Derived.new!(id: :a, from: [given: nil], schema: @output, function: :echo)

    b =
      Derived.new!(
        id: :b,
        from: [a: nil],
        schema: %{n: %{type: :number}},
        elixir: "fn %{a: rows} -> [%{n: Enum.count(rows)}] end"
      )

    {:ok, engine} =
      Engine.new(%{["a"] => a, ["b"] => b},
        sources: [:given],
        debounce: 0,
        functions: Functions.registry!([Echo])
      )

    engine
  end

  # Each push names its moment in a served fact, so `push/4` marks `a` every time and the
  # property judges the answer check alone, whatever the rows (macaw_data#106).
  defp answered(engine, rows, now) do
    engine =
      engine
      |> Engine.push(
        %{given: Delivery.new!(rows, served: [note: "#{now}"])},
        %{given: @given},
        now
      )
      |> Engine.run(now)

    assert Engine.faults(engine) == %{}
    engine
  end

  # Whether `b` ran again: `a`'s second answer changed.
  defp changed?(first, second) do
    engine = engine() |> answered(first, 0) |> answered(second, 1)
    Engine.runs(engine)[["b"]] == 2
  end

  # -- the reference: rows as a table reads them ------------------------------------------

  # A row as its table reads it back: every field, `nil` where it is absent, a category's
  # atom as its string; then compared strictly, as `Table.equal?/2` compares values.
  defp as_read(rows) do
    for row <- rows do
      for field <- ["c", "t", "v"], into: %{} do
        value = Map.get(row, String.to_existing_atom(field))

        {field,
         if(field == "c" and is_atom(value) and value != nil,
           do: Atom.to_string(value),
           else: value
         )}
      end
    end
  end

  # -- generated answers --------------------------------------------------------------------

  defp value(:v), do: one_of([integer(-3..3), Gen.float(min: -3.0, max: 3.0), constant(-0.0)])
  defp value(:c), do: member_of([:ok, :warn, "ok", "warn", 2])
  defp value(:t), do: map(integer(0..3), &DateTime.from_unix!/1)

  defp row do
    gen all(
          fields <- list_of(member_of([:t, :c, :v]), max_length: 3),
          values <- fixed_map(%{t: value(:t), c: value(:c), v: value(:v)})
        ) do
      Map.take(values, Enum.uniq(fields))
    end
  end

  # One answer and another: the same, or the first with one change a table may or may not
  # tell apart (an integer as a float, 0.0 as -0.0, a category's atom as its string, an
  # absent field as nil, a value replaced, a row dropped).
  defp answers do
    gen all(
          first <- list_of(row(), max_length: 6),
          change <- member_of([:same, :float, :zero, :spelling, :absent, :value, :drop]),
          at <- integer(0..5),
          other <- row()
        ) do
      {first, change(first, change, at, other)}
    end
  end

  defp change([], _change, _at, other), do: [other]
  defp change(rows, :same, _at, _other), do: rows
  defp change(rows, :drop, at, _other), do: List.delete_at(rows, rem(at, length(rows)))

  defp change(rows, :value, at, other),
    do: List.update_at(rows, rem(at, length(rows)), &Map.merge(&1, other))

  defp change(rows, change, at, _other),
    do: List.update_at(rows, rem(at, length(rows)), &respelled(&1, change))

  defp respelled(row, :float),
    do: Map.update(row, :v, 1.0, &if(is_integer(&1), do: &1 * 1.0, else: &1))

  defp respelled(row, :zero),
    do: Map.put(row, :v, if(Map.get(row, :v) === 0.0, do: -0.0, else: 0.0))

  defp respelled(row, :spelling),
    do: Map.update(row, :c, :ok, &if(is_atom(&1), do: Atom.to_string(&1), else: &1))

  defp respelled(row, :absent),
    do: if(Map.has_key?(row, :t), do: Map.delete(row, :t), else: Map.put(row, :t, nil))

  # -- the change check ------------------------------------------------------------------------

  @tag verifies: "derived-engine-change"
  property "an answer changed exactly when its rows, read as its table reads them, differ" do
    check all({first, second} <- answers(), max_runs: 60) do
      assert changed?(first, second) == (as_read(first) !== as_read(second))
    end
  end

  @tag verifies: "derived-engine-change"
  test "the output is a table under the schema, a category's atom read as its string" do
    engine = answered(engine(), [%{v: 1, c: :ok}], 0)
    %Delivery{rows: table} = Engine.outputs(engine)[["a"]]

    assert Table.names(table) == ["c", "t", "v"]

    assert Enum.map(Table.names(table), &Table.column_type(table, &1)) == [
             :category,
             :time,
             :number
           ]

    assert Table.rows!(table) == [%{"c" => "ok", "t" => nil, "v" => 1}]
  end

  # The row comparison this replaced used `!=`, under which 1 and 1.0 were one value, and
  # a category's atom and its string two: a table tells the first apart and not the second.
  @tag verifies: "derived-engine-change"
  test "1 and 1.0 are a change; a category's atom and its string are not" do
    assert changed?([%{v: 1}], [%{v: 1.0}])
    refute changed?([%{c: :ok}], [%{c: "ok"}])
    refute changed?([%{v: 2}], [%{v: 2, t: nil}])
  end

  # -- equal?'s digests ------------------------------------------------------------------------

  defp table(rows) do
    {:ok, table} =
      Table.new(
        for name <- [:c, :v],
            do:
              {name, if(name == :c, do: :category, else: :number),
               Enum.map(rows, &Map.get(&1, name))}
      )

    table
  end

  @tag verifies: "table-equal-digests"
  property "equal? by chunk digests agrees with comparing the columns, chunked alike or not" do
    check all({first, second} <- answers(), cut <- integer(0..6), max_runs: 200) do
      {a, b} = {table(first), table(second)}
      header = [c: :category, v: :number]

      {:ok, recut} =
        Table.from_chunks(
          header,
          Table.chunks(Table.slice(b, 0, cut)) ++ Table.chunks(Table.slice(b, cut, 99))
        )

      columns? =
        Table.size(a) == Table.size(b) and
          Enum.all?([:c, :v], &(Table.column(a, &1) === Table.column(b, &1)))

      assert Table.equal?(a, b) == columns?
      assert Table.equal?(a, recut) == columns?
      assert Table.equal?(a, b) == (Table.digest(a) == Table.digest(b))
    end
  end

  # Two canonical tables of 50,000 rows that differ in their last value: equal? reads
  # their chunks' digests, seven a side, and decodes no column.
  @tag verifies: "table-equal-digests"
  test "equal? of two canonical tables reads their digests, not their columns" do
    values = Enum.map(1..50_000, &(&1 * 1.0))
    {:ok, a} = Table.new([{"v", :number, values}])
    {:ok, b} = Table.new([{"v", :number, List.replace_at(values, -1, 0.5)}])

    {reductions, equal?} = Work.reductions(fn -> Table.equal?(a, b) end)
    {decode, _values} = Work.reductions(fn -> Table.column(a, "v") end)

    refute equal?
    assert reductions < 1_000
    assert reductions * 100 < decode
  end
end
