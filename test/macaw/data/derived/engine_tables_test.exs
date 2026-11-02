defmodule Macaw.Data.Derived.EngineTablesTest do
  # The engine reads a table input as a table (spec/02 §8.2, macaw_data#47): windowed on
  # its columns, its rows made once, at the call. Not async: the reductions guard counts
  # exactly only where no other test loads or purges code (`Macaw.Data.Test.Work`).
  use ExUnit.Case, async: false

  alias Macaw.Data.{Delivery, Derived, Schema, Table}
  alias Macaw.Data.Derived.Engine
  alias Macaw.Data.Test.Work

  defmodule Host do
    use Macaw.Data.Derived.Functions

    defsource(seen(inputs),
      do: [
        %{
          n: length(inputs["hosts"]),
          first: hd(inputs["hosts"])[:host],
          kind: if(is_atom(hd(inputs["hosts"])[:host]), do: "atom", else: "string")
        }
      ]
    )
  end

  @hosts Schema.new!(%{
           t: %{type: :time},
           host: %{type: :category, identity: true},
           cpu: %{type: :number}
         })

  @base ~U[2026-01-01 00:00:00Z]

  # `n` readings over `hosts` hosts, a reading a host a second, in time order.
  defp readings(n, hosts, shift \\ 0) do
    {:ok, table} =
      Table.new([
        {:t, :time, for(i <- 0..(n - 1), do: DateTime.add(@base, div(i, hosts), :second))},
        {:host, :category, for(i <- 0..(n - 1), do: "h#{rem(i, hosts)}")},
        {:cpu, :number, for(i <- 0..(n - 1), do: rem(i * 7 + shift, 100) * 1.0)}
      ])

    table
  end

  defp engine(source, opts \\ []) do
    {:ok, engine} =
      Engine.new(%{["a"] => source}, [sources: [:hosts], debounce: 0] ++ opts)

    engine
  end

  defp pushed(engine, rows, now),
    do: Engine.push(engine, %{hosts: Delivery.new!(rows)}, %{hosts: @hosts}, now)

  defp answer(engine, rows) do
    engine = engine |> pushed(rows, 0) |> Engine.run(0)
    assert Engine.faults(engine) == %{}
    Delivery.rows(Engine.outputs(engine)[["a"]])
  end

  @last Derived.new!(
          id: :a,
          from: [hosts: %{last: 2}],
          schema: %{host: %{type: :category}, cpu: %{type: :number}},
          elixir:
            "fn %{hosts: rows} -> Enum.map(rows, fn r -> %{host: r.host, cpu: r.cpu} end) end"
        )

  @tag verifies: "derived-engine-tables"
  test "a table input answers what its rows answer, windowed and read as rows at the call" do
    table = readings(40, 4)
    rows = Table.rows(table)

    assert answer(engine(@last), table) == answer(engine(@last), rows)
    assert length(answer(engine(@last), table)) == 8

    asked = %{@last | from: [hosts: %{window: [DateTime.add(@base, 3, :second), nil]}]}
    assert answer(engine(asked), table) == answer(engine(asked), rows)
  end

  @tag verifies: "derived-engine-tables"
  test "a host's function reads a table input as its rows, and a row input as given" do
    source =
      Derived.new!(
        id: :a,
        from: [hosts: %{last: 1}],
        schema: %{n: %{type: :number}, first: %{type: :category}, kind: %{type: :text}},
        function: :seen
      )

    functions = Macaw.Data.Derived.Functions.registry!([Host])
    table = readings(12, 3)

    assert answer(engine(source, functions: functions), table) ==
             [%{"n" => 3, "first" => "h0", "kind" => "string"}]

    given = [%{t: @base, host: :h9, cpu: 1.0}]

    assert answer(engine(source, functions: functions), given) ==
             [%{"n" => 1, "first" => "h9", "kind" => "atom"}]
  end

  # One recompute of a `last: 20` source over 50,000 rows of 50 hosts, pushed as a table:
  # the window reads the time column's instants and the host column's values, sorts the
  # indexes, gathers 1,000 rows, and transposes those alone. It counted 915,785 when this
  # was written (7,923,737 when the engine transposed the input and windowed row maps);
  # the bound allows for the bounded call's spawn and monitor, charged to the engine's
  # process, and stays below what transposing the input alone costs (1,705,513).
  @tag verifies: "derived-engine-tables"
  test "one recompute of a last n source over a 50k-row table input stays under its bound" do
    count =
      Derived.new!(
        id: :a,
        from: [hosts: %{last: 20}],
        schema: %{n: %{type: :number}},
        elixir: "fn %{hosts: rows} -> [%{n: Enum.count(rows)}] end"
      )

    {first, second} = {readings(50_000, 50), readings(50_000, 50, 1)}
    engine = engine(count) |> pushed(first, 0) |> Engine.run(0) |> pushed(second, 1)

    {reductions, faults} = Work.reductions(fn -> engine |> Engine.run(1) |> Engine.faults() end)
    {transpose, _rows} = Work.reductions(fn -> Table.rows(second) end)

    assert faults == %{}
    assert reductions < 1_100_000
    assert reductions < transpose
  end

  # One recompute of an expression over the whole of a 50,000-row table input, answering
  # the 5,000 rows it keeps: the input transposed once at the call, the answer conformed,
  # then packed once into the output table (245,278 of it) and compared with the last by
  # its chunks' digests. It counted 5,944,162 when this was written; 5,701,833 before the
  # answer was packed, which each reader that wanted columns paid again (381,292 for
  # `Delivery.table/2` of those rows).
  @tag verifies: "derived-engine-change"
  test "one recompute of an expression over a 50k-row table input stays under its bound" do
    keep =
      Derived.new!(
        id: :a,
        from: [hosts: nil],
        schema: %{t: %{type: :time}, host: %{type: :category}, cpu: %{type: :number}},
        elixir:
          "fn %{hosts: rows} -> for r <- rows, r.cpu >= 90.0, do: %{t: r.t, host: r.host, cpu: r.cpu} end"
      )

    {first, second} = {readings(50_000, 50), readings(50_000, 50, 1)}
    engine = engine(keep) |> pushed(first, 0) |> Engine.run(0) |> pushed(second, 1)

    {reductions, engine} = Work.reductions(fn -> Engine.run(engine, 1) end)

    assert Engine.faults(engine) == %{}
    assert Table.size(Engine.outputs(engine)[["a"]].rows) == 5_000
    assert reductions < 6_500_000
  end
end
