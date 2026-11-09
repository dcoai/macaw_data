defmodule Macaw.Data.Derived.EngineColumnsTest do
  # A source that reads its inputs as columns (spec/02 §2.2, §8.2, macaw_data#107): the
  # engine hands its function each input as a table, and makes rows only for a source
  # that reads rows. A `:columns` source and its `:rows` twin answer alike through pulses,
  # faults and watermarks, and the columnar one costs a fraction of the rows' work. Not
  # async: the reductions guard counts exactly only where no other test loads or purges
  # code (`Macaw.Data.Test.Work`).
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Derived, Native, Schema, Table}
  alias Macaw.Data.Derived.{Columns, Engine, Functions, Sandbox}
  alias Macaw.Data.Test.{Gen, Work}

  defmodule Host do
    use Macaw.Data.Derived.Functions

    # The twins: the same answer, read from rows and from columns. A count of 3 raises in
    # both, so a fault comes and goes alike.
    defsource rows_total(inputs) do
      rows = inputs["in"]
      values = for row <- rows, v = row[:v] || row["v"], v != nil, do: v
      if length(rows) == 3, do: raise(ArgumentError, "three")

      [
        %{
          n: length(rows),
          total: Macaw.Data.Ops.aggregate!(values, "sum"),
          readings: length(values)
        }
      ]
    end

    defsource columns_total(inputs) do
      t = inputs["in"]
      if Columns.size!(t) == 3, do: raise(ArgumentError, "three")
      [%{n: Columns.size!(t), total: Columns.sum!(t, "v"), readings: Columns.count!(t, :v)}]
    end

    defsource(rows_entity(rows),
      do: %{n: length(rows), last: List.last(rows)[:v] || List.last(rows)["v"]}
    )

    defsource(columns_entity(t),
      do: %{n: Columns.size!(t), last: List.last(Columns.numbers!(t, "v"))}
    )

    defsource sees(inputs) do
      t = inputs["in"]
      [%{origin: if(Table.origin(t) == nil, do: "none", else: "kept")}]
    end
  end

  @schema Schema.new!(%{
            t: %{type: :time},
            host: %{type: :category, identity: true},
            v: %{type: :number}
          })

  @out %{n: %{type: :number}, total: %{type: :number}, readings: %{type: :number}}
  @per %{host: %{type: :category, identity: true}, n: %{type: :number}, last: %{type: :number}}

  @stored_rows ~S"""
  fn %{in: rows} ->
    values = for row <- rows, row.v != nil, do: row.v
    n = Enum.count(rows)
    [%{n: n, total: Macaw.Data.Ops.aggregate!(values, "sum") * div(6, rem(n + 3, 6)) / div(6, rem(n + 3, 6)), readings: Enum.count(values)}]
  end
  """

  @stored_columns ~S"""
  fn %{in: t} ->
    n = Macaw.Data.Derived.Columns.size!(t)
    total = Macaw.Data.Derived.Columns.sum!(t, "v")
    [%{n: n, total: total * div(6, rem(n + 3, 6)) / div(6, rem(n + 3, 6)), readings: Macaw.Data.Derived.Columns.count!(t, :v)}]
  end
  """

  # Each pair: the `:rows` source and its `:columns` twin, by path.
  defp twins do
    windows = [nil, %{last: 4}, %{window: [~U[1970-01-01 00:00:01Z], ~U[1970-01-01 00:00:05Z]]}]

    for {window, w} <- Enum.with_index(windows),
        {kind, rows, columns, schema, per} <- [
          {"host", [function: :rows_total], [function: :columns_total], @out, nil},
          {"stored", [elixir: @stored_rows], [elixir: @stored_columns], @out, nil},
          {"per", [function: :rows_entity], [function: :columns_entity], @per, :identity}
        ] do
      base = [from: [in: window], schema: schema, per: per]
      name = "#{kind}#{w}"

      {Derived.new!([id: name <> "r"] ++ base ++ rows),
       Derived.new!([id: name <> "c", input: :columns] ++ base ++ columns)}
    end
  end

  defp engine do
    pairs = twins()

    sources =
      Map.new(Enum.flat_map(pairs, fn {r, c} -> [{[r.id], r}, {[c.id], c}] end))

    {:ok, engine} =
      Engine.new(sources,
        sources: [:in],
        debounce: 0,
        functions: Functions.registry!([Host])
      )

    {engine, pairs}
  end

  # -- generated deliveries -----------------------------------------------------------------

  defp a_row do
    fixed_map(%{
      t: map(integer(0..6), &DateTime.from_unix!/1),
      host: member_of(["a", "b", :c]),
      v: frequency([{1, constant(nil)}, {4, integer(-5..5)}, {4, Gen.float(min: -5.0, max: 5.0)}])
    })
  end

  defp delivery do
    gen all(
          rows <- list_of(a_row(), max_length: 12),
          table? <- boolean(),
          watermark <- one_of([constant(nil), integer(0..9)])
        ) do
      rows = Enum.sort_by(rows, &DateTime.to_unix(&1.t))
      held = if table?, do: packed(rows), else: rows
      Delivery.new!(held, served: [complete_until: watermark])
    end
  end

  defp packed(rows) do
    Table.new!(
      for name <- [:t, :host, :v],
          do:
            {name, Schema.fetch(@schema, name, :type) |> elem(1),
             Enum.map(rows, &Map.get(&1, name))}
    )
  end

  # -- the twins -----------------------------------------------------------------------------

  @tag verifies: "derived-engine-columns"
  property "a :columns source and its :rows twin answer alike through pulses, faults and watermarks" do
    {engine, pairs} = engine()

    check all(deliveries <- list_of(delivery(), min_length: 1, max_length: 6), max_runs: 60) do
      Enum.reduce(Enum.with_index(deliveries), engine, fn {delivery, now}, engine ->
        engine = engine |> Engine.push(%{in: delivery}, %{in: @schema}, now) |> Engine.run(now)
        outputs = Engine.outputs(engine)
        status = Engine.status(engine)
        faults = Engine.faults(engine)

        for {r, c} <- pairs do
          {a, b} = {outputs[[r.id]], outputs[[c.id]]}
          assert a == nil == (b == nil), "#{r.id} and #{c.id}: one answered"

          if a do
            assert Table.equal?(a.rows, b.rows), "#{r.id} and #{c.id} differ"
            assert a.served === b.served
          end

          assert state(status[[r.id]]) == state(status[[c.id]])
          assert Map.get(faults, [r.id], %{})[:kind] == Map.get(faults, [c.id], %{})[:kind]
        end

        engine
      end)
    end
  end

  defp state({:down, {:derived, _id, kind}}), do: {:down, kind}
  defp state(state), do: state

  @tag verifies: "derived-engine-columns"
  test "rows are made only for :rows: a :columns function is handed tables, a stored one detached" do
    rows = [%{t: ~U[1970-01-01 00:00:01Z], host: "a", v: 1}]

    host =
      Derived.new!(
        id: :h,
        from: [in: nil],
        input: :columns,
        function: :sees,
        schema: %{origin: %{type: :category}}
      )

    stored =
      Derived.new!(
        id: :s,
        from: [in: nil],
        input: :columns,
        schema: %{n: %{type: :number}},
        elixir: "fn %{in: t} -> [%{n: Macaw.Data.Derived.Columns.size!(t)}] end"
      )

    {:ok, engine} =
      Engine.new(%{["h"] => host, ["s"] => stored},
        sources: [:in],
        debounce: 0,
        functions: Functions.registry!([Host])
      )

    {:ok, sourced} =
      Table.new(
        [{:t, :time, [~U[1970-01-01 00:00:01Z]]}, {:host, :category, ["a"]}, {:v, :number, [1]}],
        origin: %{source: :in, resolution: nil, window: :t, span: nil}
      )

    engine =
      engine |> Engine.push(%{in: Delivery.new!(sourced)}, %{in: @schema}, 0) |> Engine.run(0)

    assert Engine.faults(engine) == %{}
    assert Delivery.rows!(Engine.outputs(engine)[["h"]]) == [%{"origin" => "kept"}]
    assert Delivery.rows!(Engine.outputs(engine)[["s"]]) == [%{"n" => 1}]

    # A list delivery is packed under the input's schema, so the host reads a table.
    engine = engine |> Engine.push(%{in: Delivery.new!(rows)}, %{in: @schema}, 1) |> Engine.run(1)
    assert Delivery.rows!(Engine.outputs(engine)[["h"]]) == [%{"origin" => "none"}]
  end

  @tag verifies: "derived-engine-columns"
  test "a detached table holds its values alone: no origin, no chunk identity, no function" do
    {:ok, table} =
      Table.new(
        [
          {:t, :time, [~U[1970-01-01 00:00:01Z], ~U[1970-01-01 00:00:02Z]]},
          {:v, :number, [1, 2.5]}
        ],
        origin: %{source: {:secret, "token"}, resolution: nil, window: :t, span: nil}
      )

    detached = Table.detached(Table.slice(table, 1, 1))
    assert Table.rows!(detached) == Table.rows!(Table.slice(table, 1, 1))
    assert Table.origin(detached) == nil
    refute holds?(detached, &is_function/1)
    refute holds?(detached, &(&1 == {:secret, "token"}))
    assert holds?(table, &(&1 == {:secret, "token"}))
  end

  defp holds?(term, found?) do
    found?.(term) or
      case term do
        %_{} = struct ->
          struct |> Map.from_struct() |> Map.values() |> Enum.any?(&holds?(&1, found?))

        map when is_map(map) ->
          Enum.any?(map, fn {k, v} -> holds?(k, found?) or holds?(v, found?) end)

        list when is_list(list) ->
          Enum.any?(list, &holds?(&1, found?))

        tuple when is_tuple(tuple) ->
          tuple |> Tuple.to_list() |> Enum.any?(&holds?(&1, found?))

        _other ->
          false
      end
  end

  @tag verifies: "derived-engine-columns"
  test "rows that do not pack under the input's schema are nonconforming at the input, with no value" do
    source =
      Derived.new!(
        id: :c,
        from: [in: nil],
        input: :columns,
        function: :columns_total,
        schema: @out
      )

    {:ok, engine} =
      Engine.new(%{["c"] => source},
        sources: [:in],
        debounce: 0,
        functions: Functions.registry!([Host])
      )

    bad = [%{t: ~U[1970-01-01 00:00:01Z], host: "a", v: "secret-value"}]
    engine = engine |> Engine.push(%{in: Delivery.new!(bad)}, %{in: @schema}, 0) |> Engine.run(0)

    assert %{["c"] => %{kind: :nonconforming, detail: {:input, "in", faults}}} =
             Engine.faults(engine)

    assert [{["v", 0], {:type, :number}}] = faults
    refute inspect(Engine.faults(engine)) =~ "secret-value"
  end

  # -- the cost -------------------------------------------------------------------------------

  # One recompute of a source summing one field of a 50,000-row input of four columns
  # (time, float, text, integer), as rows and as columns: the engine's own process
  # (push and run, the windowed input made into rows or not) and the function's call on
  # its argument, each counted by `Test.Work`. When this was written: the :rows host
  # twin 2,056,059 + 350,015 = 2,406,074; the :columns twin 1,422 + 953 = 2,375 with
  # the kernels, 1,422 + 150,985 = 152,407 on the Elixir path (#107).
  @n 50_000

  defp wide(shift) do
    t0 = ~U[2026-01-01 00:00:00.000000Z]

    Table.new!([
      {"t", :time, for(i <- 0..(@n - 1), do: DateTime.add(t0, i, :second))},
      {"v", :number, for(i <- 0..(@n - 1), do: :math.sin((i + shift) / 50) * 10)},
      {"host", :text, for(i <- 0..(@n - 1), do: "h#{rem(i, 50)}")},
      {"n", :number, Enum.to_list(0..(@n - 1))}
    ])
  end

  @wide Schema.new!(%{
          t: %{type: :time},
          v: %{type: :number},
          host: %{type: :text},
          n: %{type: :number}
        })

  defp recompute(source, fun, input) do
    {:ok, engine} =
      Engine.new(%{["s"] => source},
        sources: [:in],
        debounce: 0,
        functions: Functions.registry!([Host.Wide])
      )

    {first, second} = {wide(0), wide(1)}
    engine = engine |> Engine.push(%{in: Delivery.new!(first)}, %{in: @wide}, 0) |> Engine.run(0)

    {engine_work, done} =
      Work.reductions(fn ->
        engine |> Engine.push(%{in: Delivery.new!(second)}, %{in: @wide}, 1) |> Engine.run(1)
      end)

    assert Engine.faults(done) == %{}
    argument = Derived.argument(source, [%{name: "in", rows: input.(second), schema: @wide}])
    {kernels, _} = Work.reductions(fn -> fun.(argument) end, native: :normal_schedulers)
    {elixir, _} = Work.reductions(fn -> fun.(argument) end, native: :elixir)
    {engine_work + kernels, engine_work + elixir}
  end

  defmodule Host.Wide do
    use Macaw.Data.Derived.Functions
    defsource(rows_sum(inputs), do: [%{total: inputs["in"] |> Enum.map(& &1["v"]) |> Enum.sum()}])
    defsource(columns_sum(inputs), do: [%{total: Columns.sum!(inputs["in"], "v")}])
  end

  @tag verifies: "derived-engine-columns-cost"
  test "summing one field of a 50k-row input as columns costs at least 10x fewer reductions than as rows" do
    out = %{total: %{type: :number}}

    rows = Derived.new!(id: :s, from: [in: nil], schema: out, function: :rows_sum)

    columns =
      Derived.new!(id: :s, from: [in: nil], schema: out, function: :columns_sum, input: :columns)

    {rows_work, _} = recompute(rows, &Host.Wide.rows_sum/1, &Table.rows!/1)
    {with_kernels, elixir} = recompute(columns, &Host.Wide.columns_sum/1, & &1)

    assert elixir * 10 <= rows_work
    assert elixir < 200_000
    if Native.loaded?(), do: assert(with_kernels < 10_000)

    stored =
      Derived.new!(
        id: :s,
        from: [in: nil],
        schema: out,
        input: :columns,
        elixir: ~S|fn %{in: t} -> [%{total: Macaw.Data.Derived.Columns.sum!(t, "v")}] end|
      )

    {:ok, compiled} = Sandbox.compile(stored.elixir)
    {_kernels, stored_elixir} = recompute(stored, compiled.fun, &Table.detached/1)
    assert stored_elixir * 10 <= rows_work
    assert stored_elixir < 200_000
  end
end
