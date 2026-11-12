defmodule Macaw.Data.FinishReducedIdsTest do
  @moduledoc """
  A reduced table's chunks are named stably (spec/01 §1.1.3, §2.4; macaw_data#247): each
  source chunk's kept rows one chunk named `{source id, {:reduced, name, count}}`, its
  version moving only with the rows it keeps.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table}
  alias Macaw.Data.Source.{Description, Finish, Request}
  alias Macaw.Data.Table.Chunk
  alias Macaw.Layers.Document

  @now ~U[2026-11-12 12:00:00Z]
  @schema Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})
  @origin %{source: "ticks", resolution: 1, window: "t", span: 100}

  defp held(ts, vs), do: Table.new!([{"t", :number, ts}, {"v", :number, vs}], origin: @origin)

  defp finished(table, reduce) do
    {:ok, d} =
      Finish.finish(
        Delivery.new!(table),
        Description.new!(schema: @schema),
        Request.new!(now: @now, reduce: reduce)
      )

    d
  end

  # Each chunk of a table by its id: its version (a view's with its bounds) and the rows'
  # window values it holds, which name the rows.
  defp named(table) do
    for {chunk, first, count} <- Table.chunks(table), into: %{} do
      version =
        if first == 0 and count == Chunk.size(chunk),
          do: Chunk.version(chunk),
          else: {Chunk.version(chunk), first, count}

      {Chunk.id(chunk), {version, Chunk.values(chunk, "t", first, count)}}
    end
  end

  @tag verifies: "table-reduced-ids"
  test "a reduced chunk's id is its source's and the key, its version the source's and the slots kept" do
    table = held(Enum.to_list(0..99), Enum.map(0..99, &rem(&1 * 7, 11)))
    [{chunk, 0, 100}] = Table.chunks(table)
    key = {:reduced, "m4", 3}

    picked = Chunk.pick(chunk, 0, 100, [0, 5, 99], key)
    assert Chunk.id(picked) == {Chunk.id(chunk), key}

    assert {:ok, Chunk.version(picked)} ==
             Document.digest({[Chunk.version(chunk)], {key, [0, 5, 99]}})

    assert Chunk.values(picked, "t", 0, 3) == [0, 5, 99]

    # Other rows, one id; another version. A view from slot 10 names the chunk's slots.
    other = Chunk.pick(chunk, 0, 100, [0, 6, 99], key)
    assert Chunk.id(other) == Chunk.id(picked)
    refute Chunk.version(other) == Chunk.version(picked)

    from_ten = Chunk.pick(chunk, 10, 90, [0, 89], key)

    assert {:ok, Chunk.version(from_ten)} ==
             Document.digest({[Chunk.version(chunk)], {key, [10, 99]}})
  end

  @tag verifies: "table-reduced-ids"
  test "a reduced table's chunks are named {source id, {:reduced, name, count}} on every reduction" do
    table = held(Enum.to_list(0..599), Enum.map(0..599, &:math.sin(&1 / 13)))

    for reduce <- [{:m4, 10}, {:lttb, 40}] do
      d = finished(table, reduce)
      {name, count} = d.served.reduced_with
      source_ids = for {chunk, _, _} <- Table.chunks(table), do: Chunk.id(chunk)

      for {chunk, _first, _count} <- Table.chunks(d.rows) do
        case Chunk.id(chunk) do
          {id, {:reduced, ^name, ^count}} -> assert id in source_ids
          id -> assert id in source_ids
        end
      end

      assert named(finished(table, reduce).rows) == named(d.rows)
    end
  end

  @tag verifies: "table-reduced-ids"
  property "a second reduction gives the same names; a changed chunk moves only its own" do
    check all(
            n <- integer(150..700),
            seed <- integer(1..1_000),
            reduce <- member_of([{:m4, 8}, {:m4, 20}, {:lttb, 25}, {:lttb, 60}]),
            max_runs: 40
          ) do
      ts = Enum.to_list(0..(n - 1))
      vs = Enum.map(ts, &(:math.sin((&1 + seed) / 9) * 10 + rem(&1 * seed, 7)))
      table = held(ts, vs)
      d = finished(table, reduce)

      # The rows are those the reducer keeps, named or not.
      assert Table.equal?(
               d.rows,
               Finish.reduce!(
                 Delivery.new!(table),
                 @schema,
                 Request.new!(now: @now, reduce: reduce)
               ).rows
             )

      assert named(finished(table, reduce).rows) == named(d.rows)

      # Append later rows into the last chunk's slot and beyond: a reduced chunk of a
      # source chunk that did not change keeps its id, and keeps its version exactly when
      # it keeps the same rows.
      more = held(Enum.to_list(n..(n + 40)), Enum.map(n..(n + 40), &(rem(&1, 5) * 1.0)))
      {:ok, grown} = Table.append(table, more)
      again = named(finished(grown, reduce).rows)
      before = named(d.rows)

      unchanged =
        for {chunk, _, _} <- Table.chunks(grown),
            {old, _, _} <- Table.chunks(table),
            Chunk.id(chunk) == Chunk.id(old) and Chunk.version(chunk) == Chunk.version(old),
            do: Chunk.id(chunk)

      for {id, {version, ts}} <- again,
          Map.has_key?(before, id),
          (case id do
             {source, {:reduced, _, _}} -> source in unchanged
             source -> source in unchanged
           end) do
        {version_before, ts_before} = before[id]
        assert version == version_before == (ts == ts_before)
      end
    end
  end
end
