defmodule Macaw.Data.TableInsertSlotsTest do
  @moduledoc """
  An increment's insertions are slotted and sorted by each row's window value read once
  (spec/01 §1.1.4, macaw_data#215): its slot key stands for its slot exactly, so every
  chunk `Table.apply/2` answers is the full rewrite's (`Macaw.Data.Test.ApplyReference`),
  byte for byte, whatever kinds of time or number the window column mixes.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Schema, Table, Window}
  alias Macaw.Data.Table.{Chunk, Origin}
  alias Macaw.Data.Test.ApplyReference

  @t0 ~U[2026-01-01 00:00:00Z]
  @n0 ~N[2026-01-01 00:00:00]
  @d0 ~D[2026-01-01]
  # The earliest instant a DateTime holds, which a span of 7 s reaches back past.
  @earliest ~U[-9999-01-01 00:00:00Z]

  # -- window values ----------------------------------------------------------------------

  # A time at second `s`: of each kind, at several precisions, so equal instants are
  # different terms and a DateTime and a naive time share an instant; a date at midnight.
  defp time(s) do
    member_of([
      DateTime.add(@t0, s),
      @t0 |> DateTime.add(s) |> Map.put(:microsecond, {0, 3}),
      DateTime.add(@t0, s * 1_000_000 + 1, :microsecond),
      NaiveDateTime.add(@n0, s),
      @n0 |> NaiveDateTime.add(s) |> Map.put(:microsecond, {0, 6}),
      Date.add(@d0, div(s, 86_400)),
      DateTime.add(@earliest, rem(abs(s), 20))
    ])
  end

  # A number around position `s`: an integer, a float, either past 2^53, or none.
  defp number(s) do
    member_of([s, s / 1, s + 0.5, 2 ** 60 + s, 2.0 ** 60, -(2 ** 60), 2 ** 53 + 1])
  end

  defp window_value(type, range \\ -30..90)

  defp window_value(:time, range),
    do: frequency([{6, bind(integer(range), &time/1)}, {1, constant(nil)}])

  defp window_value(:number, range),
    do: frequency([{6, bind(integer(range), &number/1)}, {1, constant(nil)}])

  defp span(:time), do: member_of([Duration.new!(second: 10), Duration.new!(second: 7)])
  defp span(:number), do: member_of([10, 7, 2.5, 0.1])

  defp origin(span), do: %{source: "s", resolution: 1, window: "t", span: span}

  @tag verifies: "table-insert-slots"
  property "two window values share a slot key exactly when their slots are the same term" do
    check all(
            type <- member_of([:time, :number]),
            span <- span(type),
            values <- list_of(window_value(type), min_length: 2, max_length: 30),
            max_runs: 400
          ) do
      origin = origin(span)

      for a <- values, b <- values do
        {ka, pa} = Origin.slot_key(origin, a)
        {kb, _pb} = Origin.slot_key(origin, b)
        assert pa === Origin.position(a)
        assert ka === kb == (Origin.slot_of(origin, a) === Origin.slot_of(origin, b))
      end
    end
  end

  @tag verifies: "table-insert-slots"
  test "a DateTime and a naive time at one instant are two slot keys, as they are two slots" do
    origin = origin(Duration.new!(second: 10))

    assert Origin.slot_of(origin, @t0) !== Origin.slot_of(origin, @n0)

    assert elem(Origin.slot_key(origin, @t0), 0) ===
             elem(Origin.slot_key(origin, DateTime.add(@t0, 3)), 0)

    assert elem(Origin.slot_key(origin, @t0), 0) !== elem(Origin.slot_key(origin, @n0), 0)
    assert elem(Origin.slot_key(origin, @n0), 0) === elem(Origin.slot_key(origin, @d0), 0)
    assert Origin.slot_of(origin, @n0) === Origin.slot_of(origin, @d0)
  end

  # -- holdings and increments ------------------------------------------------------------

  defp header(type), do: [{"t", type}, {"v", :number}]

  defp schema(type),
    do: Schema.new!(%{"t" => %{type: type, window: true}, "v" => %{type: :number}})

  defp rows(type, {min, max}, range) do
    bind(list_of(window_value(type, range), min_length: min, max_length: max), fn ts ->
      constant(Enum.with_index(ts, fn t, i -> %{"t" => t, "v" => i} end))
    end)
  end

  defp position(nil), do: {1, 0}
  defp position(v), do: {0, Window.position(v)}

  defp table(type, span, held) do
    rows = Enum.sort_by(held, &position(&1["t"]))

    Table.new!(for({name, t} <- header(type), do: {name, t, Enum.map(rows, & &1[name])}),
      origin: origin(span)
    )
  end

  # A `complete_until` that settles some slots, or none.
  defp settled(:time), do: member_of([nil, DateTime.add(@t0, 20), @n0, DateTime.add(@t0, 95)])
  defp settled(:number), do: member_of([nil, 20, 0.0, 95])

  defp case_gen do
    gen all(
          type <- member_of([:time, :number]),
          span <- span(type),
          # Dense, so a settled chunk's delta often stays under a quarter of its base and
          # its side rows are read in the order they were inserted.
          held <- rows(type, {40, 80}, -5..25),
          {n, range} <- member_of([{{3, 6}, -5..15}, {{2, 4}, -5..25}, {{0, 15}, -30..90}]),
          steps <-
            list_of(tuple({rows(type, n, range), settled(type)}), min_length: 1, max_length: 3)
        ) do
      %{type: type, span: span, held: held, steps: steps}
    end
  end

  defp chunks(table), do: for({chunk, 0, _n} <- Table.chunks(table), do: chunk)

  defp state(%Table{} = table) do
    header = for name <- Table.names(table), do: {name, Table.column_type(table, name)}
    %{header: header, origin: Table.origin(table), chunks: chunks(table), next: table.next}
  end

  @tag verifies: "table-insert-slots"
  test "rows into a settled chunk join its side chunk in the order they came" do
    held = for s <- Enum.to_list(0..9) ++ [30], do: %{"t" => DateTime.add(@t0, s), "v" => s}
    table = table(:time, Duration.new!(second: 10), held)
    late = [%{"t" => DateTime.add(@t0, 5), "v" => 9}, %{"t" => DateTime.add(@t0, 3), "v" => 8}]

    change = %{
      insert: late,
      retract: [],
      replace: [],
      schema: schema(:time),
      settled: DateTime.add(@t0, 20),
      thinned: false
    }

    {applied, [], 0} = Table.apply(table, change)
    [settled, _open] = chunks(applied)
    assert settled.delta.side == late
  end

  @tag verifies: "table-insert-slots"
  property "every chunk an out-of-order increment writes is the full rewrite's, byte for byte" do
    check all(c <- case_gen(), max_runs: 300) do
      Enum.reduce(c.steps, table(c.type, c.span, c.held), fn {inserts, settled}, table ->
        change = %{
          insert: inserts,
          retract: [],
          replace: [],
          schema: schema(c.type),
          settled: settled,
          thinned: false
        }

        {applied, faults, unheld} = Table.apply(table, change)
        {ref, next, ref_faults, ref_unheld} = ApplyReference.run(state(table), change)

        assert chunks(applied) == Enum.reject(ref, &(Chunk.size(&1) == 0))
        assert {applied.next, faults, unheld} == {next, ref_faults, ref_unheld}
        applied
      end)
    end
  end
end
