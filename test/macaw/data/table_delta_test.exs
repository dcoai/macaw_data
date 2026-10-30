defmodule Macaw.Data.TableDeltaTest do
  @moduledoc """
  Settled chunks, open chunks and the delta (spec/01 §1.1.4; macaw_data#9 §3, #19):
  `Table.apply/2` routes each change to an open chunk's new contents or a settled chunk's
  delta, reads go through the delta, a cold chunk is fetched only when read, and lazy
  compaction keeps a chunk's identity.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Schema
  alias Macaw.Data.Table
  alias Macaw.Data.Table.Chunk

  @schema Schema.new!(%{
            "id" => %{type: :category, identity: true},
            "t" => %{type: :number, window: true},
            "v" => %{type: :number}
          })

  @origin %{source: "taps", resolution: 1, window: "t", span: 10}

  defp row(id, t, v), do: %{"id" => id, "t" => t, "v" => v}

  # A source's table of `rows`, in the window field's order, spans of 10.
  defp table(rows, origin \\ @origin) do
    rows = sorted(rows)

    Table.new!(
      for(name <- ["id", "t", "v"], do: {name, type(name), Enum.map(rows, & &1[name])}),
      origin: origin
    )
  end

  defp type("id"), do: :category
  defp type(_name), do: :number

  # Stable by t, rows with no t last: the order a push holds rows in.
  defp sorted(rows), do: Enum.sort_by(rows, &if(&1["t"] == nil, do: {1, 0}, else: {0, &1["t"]}))

  defp change(fields),
    do:
      Map.merge(
        %{insert: [], retract: [], replace: [], schema: @schema, settled: nil, thinned: false},
        Map.new(fields)
      )

  defp apply!(table, fields) do
    {table, [], 0} = Table.apply(table, change(fields))
    table
  end

  defp chunk(table, id),
    do: Enum.find_value(Table.chunks(table), fn {c, _, _} -> Chunk.id(c) == id && c end)

  defp slot(start), do: {"taps", 1, start}

  describe "settled and open" do
    @tag verifies: "table-settled"
    test "a chunk whose span ends at or before complete_until is settled" do
      table = table([row("a", 1, 1), row("a", 12, 2), row("a", 25, 3), row("a", nil, 4)])

      settled = fn until ->
        for {c, _, _} <- Table.chunks(table), do: Table.settled?(table, c, until)
      end

      assert settled.(20) == [true, true, false, false]
      assert settled.(19) == [true, false, false, false]
      assert settled.(nil) == [false, false, false, false]
      assert settled.(1000) == [true, true, true, false]

      rows = Table.new!([{"m", :text, ["a", "b"]}], origin: %{source: "log", resolution: nil})
      assert for({c, _, _} <- Table.chunks(rows), do: Table.settled?(rows, c, 1000)) == [false]
    end
  end

  describe "apply/2" do
    @tag verifies: "table-apply"
    test "an open chunk is written again; a settled chunk's change lands in its delta" do
      # Nine rows in the settled span, so two changes stay in its delta.
      rest = for t <- 3..9, do: row("a", t, t)

      table =
        table([row("a", 1, 1), row("b", 2, 2)] ++ rest ++ [row("a", 12, 3), row("a", 15, 4)])

      old = chunk(table, slot(0))

      applied =
        apply!(table,
          settled: 10,
          retract: [row("b", 2, 2), row("a", 12, 3)],
          insert: [row("c", 3, 5), row("c", 11, 6)]
        )

      settled = chunk(applied, slot(0))
      assert Chunk.id(settled) == Chunk.id(old)
      assert Chunk.delta?(settled) and settled.columns == old.columns
      refute Chunk.delta?(chunk(applied, slot(10)))

      assert Table.rows(applied) ==
               sorted(
                 [row("a", 1, 1)] ++ rest ++ [row("c", 3, 5), row("c", 11, 6), row("a", 15, 4)]
               )

      assert Chunk.digest(settled) ==
               Chunk.digest(chunk(table([row("a", 1, 1)] ++ rest ++ [row("c", 3, 5)]), slot(0)))
    end

    @tag verifies: "table-apply"
    test "a slot with no chunk starts one in slot order; an unrestricted replacement of a whole span replaces it outright" do
      table = table([row("a", 1, 1), row("a", 25, 2), row("a", nil, 3)])
      applied = apply!(table, insert: [row("b", 14, 4), row("b", 35, 5)])

      assert Enum.map(Table.chunks(applied), fn {c, _, _} -> Chunk.id(c) end) == [
               slot(0),
               slot(10),
               slot(20),
               slot(30),
               slot(nil)
             ]

      replaced =
        apply!(applied,
          settled: 40,
          replace: [%{from: 20, to: 30, identities: nil, rows: [row("z", 21, 9)]}]
        )

      fresh = chunk(replaced, slot(20))
      refute Chunk.delta?(fresh)
      assert Table.column(replaced, "t") == [1, 14, 21, 35, nil]
    end

    @tag verifies: "table-apply"
    test "a table with no window field takes changes directly and appends insertions to its last chunk" do
      log = %{source: "log", resolution: nil}
      rows = Table.chunk_rows()
      table = Table.new!([{"m", :number, Enum.to_list(1..(rows - 1))}], origin: log)
      schema = Schema.new!(%{"m" => %{type: :number}})

      {applied, [], 0} =
        Table.apply(
          table,
          change(schema: schema, retract: [%{"m" => 1}], insert: [%{"m" => -1}, %{"m" => -2}])
        )

      assert Enum.map(Table.chunks(applied), fn {c, _, _} -> {Chunk.id(c), Chunk.size(c)} end) ==
               [{{"log", nil, 0}, rows - 1}, {{"log", nil, rows}, 1}]

      assert Table.column(applied, "m") == Enum.to_list(2..(rows - 1)) ++ [-1, -2]
      refute Enum.any?(Table.chunks(applied), fn {c, _, _} -> Chunk.delta?(c) end)

      # A table built from rows, too.
      plain = Table.new!([{"m", :number, [1, 2]}])
      {plain, [], 0} = Table.apply(plain, change(schema: schema, insert: [%{"m" => 3}]))
      assert [{_, 0, 3}] = Table.chunks(plain)
      assert Table.column(plain, "m") == [1, 2, 3]
    end

    @tag verifies: "table-apply"
    test "retraction faults and unheld counts are §4.2's" do
      table = table([row("a", 1, 1), row("a", 1, 1), row("b", 2, 2), row("b", 2, 3)])

      {same, faults, 0} =
        Table.apply(
          table,
          change(
            settled: 10,
            retract: [row("c", 5, 0), row("a", 3, 1), %{"id" => "b", "t" => 2}]
          )
        )

      assert faults == [
               {:retract, :not_held, row("c", 5, 0)},
               {:retract, :moved, row("a", 3, 1)},
               {:retract, :ambiguous, %{"id" => "b", "t" => 2}}
             ]

      assert Table.equal?(same, table)

      {_, [], 1} = Table.apply(table, change(thinned: true, retract: [row("c", 5, 0)]))

      # One copy per unit of weight.
      one = apply!(table, settled: 10, retract: [row("a", 1, 1)])
      assert Enum.count(Table.rows(one), &(&1 == row("a", 1, 1))) == 1
    end
  end

  describe "the delta" do
    defp rows_gen do
      list_of(
        tuple({member_of(["a", "b"]), integer(0..59), integer(0..3)}),
        min_length: 1,
        max_length: 30
      )
      |> map(fn rows -> for {id, t, v} <- rows, do: row(id, t, v) end)
    end

    # The relation built directly: §4.2's order on a list of rows.
    defp directly(rows, %{retract: retract, replace: replace, insert: insert}) do
      rows = Enum.reduce(retract, rows, &List.delete(&2, &1))
      rows = Enum.reject(rows, fn r -> Enum.any?(replace, &in_scope?(r, &1)) end)
      sorted(rows ++ Enum.flat_map(replace, & &1.rows) ++ insert)
    end

    defp in_scope?(row, %{from: from, to: to, identities: ids}),
      do: (ids == nil or row["id"] in ids) and row["t"] >= from and row["t"] < to

    @tag verifies: "table-delta"
    property "reads through the delta equal the relation built directly, before and after compaction" do
      check all(
              rows <- rows_gen(),
              picks <- list_of(integer(0..100), max_length: 4),
              from <- integer(0..25),
              width <- integer(1..10),
              ids <- member_of([nil, ["a"], ["b"]]),
              replacement <- list_of(integer(0..9), max_length: 3),
              inserts <- list_of(tuple({member_of(["a", "b"]), integer(0..59)}), max_length: 6),
              max_runs: 40
            ) do
        table = table(rows)
        range = %{from: from, to: from + width, identities: ids}
        held = sorted(rows)

        retract =
          picks
          |> Enum.map(&Enum.at(held, rem(&1, length(held))))
          |> Enum.uniq()
          |> Enum.reject(&in_scope?(&1, range))

        replacing = for i <- replacement, do: row(hd(ids || ["a"]), from + rem(i, width), 7)
        insert = for {id, t} <- inserts, row = row(id, t, 8), not in_scope?(row, range), do: row
        changes = %{retract: retract, replace: [Map.put(range, :rows, replacing)], insert: insert}

        applied = apply!(table, Map.put(changes, :settled, 30))
        expected = directly(held, changes)

        assert Table.rows(applied) == expected
        ts = Table.column(applied, "t")
        assert ts == Enum.sort_by(ts, &{&1 == nil, &1})

        # Compacted, each chunk keeps its id, digest and version, and the contents.
        compacted = Table.compact(applied)
        assert Table.rows(compacted) == expected

        for {{before, _, _}, {after_, _, _}} <-
              Enum.zip(Table.chunks(applied), Table.chunks(compacted)) do
          refute Chunk.delta?(after_)

          assert {Chunk.id(after_), Chunk.digest(after_), Chunk.version(after_)} ==
                   {Chunk.id(before), Chunk.digest(before), Chunk.version(before)}
        end
      end
    end

    @tag verifies: "table-predicate"
    test "a replacement over a settled chunk is a predicate delete that reads as its row form" do
      table =
        table([
          row("a", 1, 1),
          row("b", 2, 2),
          row("a", 5, 3),
          row("b", 8, 4),
          row("a", 9, 5),
          row("b", 9, 6),
          row("a", 3, 7),
          row("b", 4, 8),
          row("b", 6, 9),
          row("b", 7, 10),
          row("b", 1, 11),
          row("b", 3, 12)
        ])

      old = chunk(table, slot(0))
      replace = [%{from: 2, to: 9, identities: ["a"], rows: [row("a", 6, 0)]}]
      applied = apply!(table, settled: 10, replace: replace)

      settled = chunk(applied, slot(0))
      assert Chunk.delta?(settled) and settled.columns == old.columns

      assert Table.rows(applied) ==
               sorted([
                 row("a", 1, 1),
                 row("b", 2, 2),
                 row("b", 8, 4),
                 row("a", 9, 5),
                 row("b", 9, 6),
                 row("b", 4, 8),
                 row("b", 6, 9),
                 row("b", 7, 10),
                 row("b", 1, 11),
                 row("b", 3, 12),
                 row("a", 6, 0)
               ])
    end
  end

  describe "predicates and the side chunk" do
    @tag verifies: "table-predicate"
    test "a predicate takes the side chunk's rows inserted before it, never those after" do
      base = for t <- 0..9, do: row("b", t, t)
      table = apply!(table(base), settled: 10, insert: [row("a", 4, 1)])

      replace = [%{from: 2, to: 9, identities: ["a"], rows: [row("a", 6, 2)]}]
      replaced = apply!(table, settled: 10, replace: replace)

      assert Chunk.delta?(chunk(replaced, slot(0)))
      assert Table.rows(replaced) == sorted(base ++ [row("a", 6, 2)])
    end
  end

  describe "cold chunks" do
    # The table with its slot-0 chunk cold: its base fetched by a function that says so.
    defp cold(table) do
      me = self()
      [{warm, 0, n} | rest] = Table.chunks(table)
      base = warm.columns

      fetch = fn ->
        send(me, :fetched)
        base
      end

      cold = Chunk.cold(Chunk.header(warm), Chunk.id(warm), Chunk.digest(warm), n, fetch)
      %{table | chunks: [{cold, 0, n} | rest]}
    end

    defp four,
      do: table([row("a", 1, 1), row("b", 2, 2), row("a", 5, 3), row("b", 8, 4), row("a", 12, 5)])

    @tag verifies: "table-predicate"
    test "a predicate delete needs no fetch of a cold chunk" do
      replace = [%{from: 2, to: 9, identities: ["a"], rows: []}]
      applied = apply!(cold(four()), settled: 10, replace: replace)
      refute_received :fetched

      assert Table.rows(applied) == [
               row("a", 1, 1),
               row("b", 2, 2),
               row("b", 8, 4),
               row("a", 12, 5)
             ]

      assert_received :fetched
    end

    @tag verifies: "table-cold"
    test "a pending digest matches no cache key until warm/1 fetches it once" do
      replace = [%{from: 2, to: 9, identities: ["a"], rows: []}]
      applied = apply!(cold(four()), settled: 10, replace: replace)
      [{pending, 0, nil} | _] = Table.chunks(applied)

      assert Chunk.digest(pending) == :pending
      assert Chunk.version(pending) == nil
      refute_received :fetched

      warmed = Table.warm(applied)
      assert_received :fetched
      refute_received :fetched

      [{warm, 0, 3} | _] = Table.chunks(warmed)
      expected = chunk(apply!(four(), settled: 10, replace: replace), slot(0))
      assert Chunk.digest(warm) == Chunk.digest(expected)
      assert Chunk.version(warm) == Chunk.digest(expected)
      assert Table.size(warmed) == 4
    end
  end

  describe "the read view" do
    @tag verifies: "table-read-view"
    test "a chunk with a delta is read through its state's view, built once" do
      rows = for t <- 0..9, do: row(Enum.at(["a", "b"], rem(t, 2)), t, t)
      table = table(rows)
      [{base, _, _}] = Table.chunks(table)

      once = apply!(table, settled: 10, retract: [row("a", 4, 4)])
      [{chunk, 0, 9}] = Table.chunks(once)
      assert Chunk.base_version(chunk) == Chunk.digest(base)
      refute Chunk.version(chunk) == Chunk.digest(base)

      read =
        Macaw.Data.Test.Trace.calls({Macaw.Data.Table.Delta, :read, 2}, fn ->
          assert Chunk.values(chunk, "t", 0, 9) == [0, 1, 2, 3, 5, 6, 7, 8, 9]
          assert Chunk.at(chunk, "v", 4) == 5
          gathered = Chunk.gather(chunk, 2, 5, [0, 4], :key)
          assert Chunk.values(gathered, "t", 0, 2) == [2, 7]
          registry = Macaw.Data.Operations.registry()
          window = %{op: "window", field: "t", from: [6, :second]}
          out = Macaw.Data.Operations.apply!(registry, [window], once)
          assert Table.column(out, "t") == [3, 5, 6, 7, 8, 9]
        end)

      assert read == []

      # A later change keeps the base version; compaction makes the read the base.
      twice = apply!(once, settled: 10, insert: [row("a", 4, 40)])
      [{again, _, _}] = Table.chunks(twice)
      assert Chunk.base_version(again) == Chunk.digest(base)

      [{compacted, _, _}] = Table.chunks(Table.compact(twice))
      assert Chunk.base_version(compacted) == Chunk.digest(compacted)
      assert Chunk.digest(compacted) == Chunk.digest(again)
    end
  end

  describe "compaction" do
    @tag verifies: "table-compaction"
    test "a delta that reaches a quarter of its base is compacted, keeping id, digest and version" do
      eight = for t <- 0..7, do: row("a", t, t)
      table = table(eight)

      once = apply!(table, settled: 10, retract: [row("a", 0, 0)])
      kept = chunk(once, slot(0))
      assert Chunk.delta?(kept)

      twice = apply!(once, settled: 10, retract: [row("a", 1, 1)])
      compacted = chunk(twice, slot(0))
      refute Chunk.delta?(compacted)
      assert Chunk.id(compacted) == slot(0)
      assert Chunk.digest(compacted) == Chunk.digest(chunk(table(Enum.drop(eight, 2)), slot(0)))
      assert Table.rows(twice) == Enum.drop(eight, 2)

      # Compacting keeps what was read: the same digest and version before and after.
      [{delta, _, _}] = Table.chunks(once)
      [{folded, _, _}] = Table.chunks(Table.compact(once))

      assert {Chunk.id(folded), Chunk.digest(folded), Chunk.version(folded)} ==
               {Chunk.id(delta), Chunk.digest(delta), Chunk.version(delta)}

      refute Chunk.delta?(folded)

      refute_received _any
    end
  end
end
