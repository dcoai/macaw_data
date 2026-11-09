defmodule Macaw.Data.TableOpenWriteTest do
  @moduledoc """
  Writing an open chunk again keeps what doesn't move (spec/01 §1.1.4, macaw_data#204):
  whatever path `Table.apply/2` takes, every chunk it answers is exactly the chunk the
  full rewrite builds, byte for byte, digest and all. The full rewrite is
  `Macaw.Data.Test.ApplyReference`, `Table.Apply` as it was before.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Schema, Table, Window}
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Test.ApplyReference

  @t0 ~U[2026-01-01 00:00:00Z]
  @n0 ~N[2026-01-01 00:00:00]

  @header [{"c", :category}, {"s", :text}, {"t", :number}, {"u", :time}, {"v", :number}]

  defp schema(window_type) do
    Schema.new!(%{
      "c" => %{type: :category},
      "s" => %{type: :text},
      "t" => %{type: window_type, window: true},
      "u" => %{type: :time},
      "v" => %{type: :number}
    })
  end

  defp header(:number), do: @header
  defp header(:time), do: List.keyreplace(@header, "t", 0, {"t", :time})

  defp origin(:number), do: %{source: "s", resolution: 1, window: "t", span: 10}

  defp origin(:time),
    do: %{source: "s", resolution: 1, window: "t", span: Duration.new!(second: 10)}

  # -- generators -------------------------------------------------------------------------

  # A column's values come in a mode, so a holding and an increment often share a form
  # (the join applies) and sometimes don't (the rewrite does).
  defp value("v", :ints), do: one_of([integer(-50..50), constant(nil)])
  defp value("v", :floats), do: one_of([float(min: -50.0, max: 50.0), constant(nil)])
  defp value("v", :mixed), do: one_of([integer(-5..5), float(min: -5.0, max: 5.0)])
  defp value("v", :wide), do: one_of([constant(2 ** 60), constant(0.5), constant(nil)])
  defp value("v", :none), do: constant(nil)
  defp value("s", :ints), do: member_of(["a", "b", "é", "", nil])
  defp value("s", :floats), do: member_of(["x", <<255>>, nil])
  defp value("s", :mixed), do: member_of(["a", <<0b10_000000>>, "zz", nil])
  defp value("s", :wide), do: member_of(["a", 1, nil])
  defp value("s", :none), do: constant(nil)
  defp value("c", :ints), do: member_of(["x", "y", :z, nil])
  defp value("c", :floats), do: member_of(["y", "w", "x", nil])
  defp value("c", :mixed), do: member_of(["x", true, false, nil])
  defp value("c", :wide), do: member_of([true, false, nil])
  defp value("c", :none), do: constant(nil)
  defp value("u", :ints), do: map(integer(0..5), &DateTime.add(@t0, &1))
  defp value("u", :floats), do: map(integer(0..5), &DateTime.add(@t0, &1 * 1000, :millisecond))
  defp value("u", :mixed), do: member_of([@t0, DateTime.add(@t0, 1, :microsecond), nil])
  defp value("u", :wide), do: member_of([@t0, @n0, nil])
  defp value("u", :none), do: constant(nil)
  # Values a column's type does not hold: the increment is refused whole, its faults compared.
  defp value("v", :bad), do: member_of(["x", 1, nil])
  defp value("u", :bad), do: member_of([5, @t0])
  defp value(c, :bad), do: value(c, :wide)

  defp modes(:held), do: member_of([:ints, :ints, :ints, :floats, :mixed, :wide, :none])

  defp modes(:increment),
    do: member_of([:ints, :ints, :ints, :ints, :floats, :mixed, :wide, :none, :bad])

  # A window value at position `p` (seconds), of the holding's kind, or none.
  defp window(nil, _kind), do: nil
  defp window(p, :ints), do: p
  defp window(p, :floats), do: p / 1
  defp window(p, :utc), do: DateTime.add(@t0, p)
  defp window(p, :utc_ms), do: @t0 |> DateTime.add(p) |> Map.put(:microsecond, {0, 3})
  defp window(p, :naive), do: NaiveDateTime.add(@n0, p)

  defp kinds(:number), do: member_of([:ints, :ints, :floats])
  defp kinds(:time), do: member_of([:utc, :utc, :utc_ms, :naive])

  defp rows(positions, kind, of \\ :increment) do
    bind(fixed_map(for c <- ~w(c s u v), into: %{}, do: {c, modes(of)}), fn modes ->
      positions
      |> Enum.map(fn p ->
        fixed_map(
          for(
            c <- ~w(c s u v),
            into: %{"t" => constant(window(p, kind))},
            do: {c, value(c, modes[c])}
          )
        )
      end)
      |> fixed_list()
    end)
  end

  # Positions after `last`, at it, anywhere, or none; mostly in order.
  defp positions(last) do
    one_of([
      list_of(integer(last..(last + 25)), max_length: 12),
      list_of(constant(last), min_length: 1, max_length: 3),
      list_of(one_of([integer(0..(last + 15)), constant(nil)]), max_length: 12)
    ])
  end

  defp case_gen do
    gen all(
          window_type <- member_of([:number, :time]),
          kind <- kinds(window_type),
          held_at <-
            list_of(one_of([integer(0..60), integer(0..60), constant(nil)]), max_length: 40),
          held <- rows(held_at, kind, :held),
          steps <-
            list_of(
              tuple(
                {positions(Enum.max([0 | Enum.reject(held_at, &is_nil/1)])), integer(0..3),
                 member_of([nil, nil, 10, 30])}
              ),
              min_length: 1,
              max_length: 4
            ),
          steps <-
            fixed_list(
              Enum.map(steps, fn {ps, retracts, settled} ->
                tuple({rows(ps, kind), constant(retracts), constant(settled)})
              end)
            )
        ) do
      %{window_type: window_type, kind: kind, held: held, steps: steps}
    end
  end

  # -- the holding and its changes --------------------------------------------------------

  defp position(nil), do: nil
  defp position(v), do: Window.position(v)

  defp sorted(rows), do: Enum.sort_by(rows, &order_key(position(&1["t"])))

  defp order_key(nil), do: {1, 0}
  defp order_key(p), do: {0, p}

  defp table(%{window_type: w, held: held}) do
    rows = sorted(held)

    Table.new!(for({name, type} <- header(w), do: {name, type, Enum.map(rows, & &1[name])}),
      origin: origin(w)
    )
  end

  defp settled(nil, _kind), do: nil
  defp settled(p, kind) when kind in [:ints, :floats], do: p
  defp settled(p, :naive), do: NaiveDateTime.add(@n0, p)
  defp settled(p, _utc), do: DateTime.add(@t0, p)

  defp state(%Table{} = table, w),
    do: %{header: header(w), origin: Table.origin(table), chunks: chunks(table), next: table.next}

  defp chunks(table), do: for({chunk, 0, _n} <- Table.chunks(table), do: chunk)

  # Each step applied through both, from the same state; the next step from the result.
  defp run(%{window_type: w, kind: kind, steps: steps} = c) do
    Enum.reduce(steps, table(c), fn {inserts, retracts, settled}, table ->
      held = for chunk <- chunks(table), {row, _} <- Chunk.read(chunk), do: row

      change = %{
        insert: inserts,
        retract: Enum.take(held, retracts),
        replace: [],
        schema: schema(w),
        settled: settled(settled, kind),
        thinned: false
      }

      assert same?(table, w, change)
      {table, _faults, _unheld} = Table.apply(table, change)
      table
    end)
  end

  # `Table.apply/2` against the full rewrite from the same chunks: the same chunks, a chunk
  # left with no row being none, as `Table.apply/2` holds them; the same next position,
  # faults and unheld count.
  defp same?(table, w, change) do
    {applied, faults, unheld} = Table.apply(table, change)
    {chunks, next, ref_faults, ref_unheld} = ApplyReference.run(state(table, w), change)

    assert chunks(applied) == Enum.reject(chunks, &(Chunk.size(&1) == 0))
    {applied.next, faults, unheld} == {next, ref_faults, ref_unheld}
  end

  @tag verifies: "table-open-write"
  property "every chunk an increment writes is the full rewrite's, byte for byte" do
    check all(c <- case_gen(), max_runs: 400) do
      run(c)
    end
  end

  @tag verifies: "table-open-write"
  test "an in-order increment into an open chunk of each joined form is the full rewrite's" do
    held =
      for p <- 0..6 do
        %{
          "t" => DateTime.add(@t0, p),
          "v" => p / 2,
          "s" => "s#{p}",
          "c" => "c#{rem(p, 2)}",
          "u" => DateTime.add(@t0, p)
        }
      end

    c = %{window_type: :time, kind: :utc, held: held, steps: []}
    table = table(c)

    for inserts <- [
          [%{"t" => DateTime.add(@t0, 6), "v" => 1.5, "s" => "é", "c" => "c9", "u" => @t0}],
          [%{"t" => DateTime.add(@t0, 8), "v" => nil, "s" => nil, "c" => nil, "u" => nil}],
          # A form that changes (an integer among floats) is the rewrite's too.
          [%{"t" => DateTime.add(@t0, 9), "v" => 3, "s" => "x", "c" => true, "u" => @t0}]
        ] do
      change = %{
        insert: inserts,
        retract: [],
        replace: [],
        schema: schema(:time),
        settled: nil,
        thinned: false
      }

      assert same?(table, :time, change)
    end
  end
end
