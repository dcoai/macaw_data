defmodule Macaw.Data.TableIdentityTest do
  @moduledoc """
  A chunk's identity (spec/01 §1.1.3; macaw_data#9 §2, #18): logical ids for tables built
  from rows, a source's chunks in event time and by row count, the resolution in the id,
  the span from the description, and step outputs keyed by derivation, never hashed.
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.Schema
  alias Macaw.Data.Source.Description
  alias Macaw.Data.Table
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Table.Digest
  alias Macaw.Layers.Document

  import Macaw.Data.Test.Trace, only: [calls: 2]

  @hour Duration.new!(hour: 1)

  defp ids(table), do: for({chunk, _, _} <- Table.chunks(table), do: Chunk.id(chunk))

  defp at(time), do: DateTime.add(~U[2026-01-01 00:00:00.000000Z], time, :minute)

  # Readings of "cpu" at the given minutes after 2026-01-01, nil a reading with no time.
  defp readings(minutes, origin) do
    times = Enum.map(minutes, &(&1 && at(&1)))
    values = Enum.map(1..length(minutes)//1, &(&1 * 1.0))
    Table.new([{"t", :time, times}, {"v", :number, values}], origin: origin)
  end

  defp cpu(resolution \\ 60),
    do: %{source: "cpu", resolution: resolution, window: "t", span: @hour}

  describe "logical ids" do
    @tag verifies: "table-chunk-ids"
    test "a table built from rows has its chunks' content digests as their ids" do
      table = Table.new!([{"v", :number, Enum.to_list(1..(Table.chunk_rows() + 1))}])
      assert [_, _] = Table.chunks(table)

      for {chunk, _, _} <- Table.chunks(table) do
        assert Chunk.id(chunk) == Chunk.digest(chunk)
        assert Chunk.version(chunk) == Chunk.digest(chunk)
      end

      assert Table.origin(table) == nil
    end

    @tag verifies: "table-chunk-ids"
    test "a source's chunks in event time are {source, resolution, span start}" do
      {:ok, table} = readings([10, 50, 65, 180, 181, nil], cpu())

      assert ids(table) == [
               {"cpu", 60, ~U[2026-01-01 00:00:00.000000Z]},
               {"cpu", 60, ~U[2026-01-01 01:00:00.000000Z]},
               {"cpu", 60, ~U[2026-01-01 03:00:00.000000Z]},
               {"cpu", 60, nil}
             ]

      assert for({c, _, _} <- Table.chunks(table), do: Chunk.size(c)) == [2, 1, 2, 1]

      # A rebuild has the same ids.
      {:ok, again} = readings([10, 50, 65, 180, 181, nil], cpu())
      assert ids(again) == ids(table)

      # A number window field: spans of 10 from 0.
      {:ok, numbers} =
        Table.new([{"x", :number, [1, 5, 12, 25.5]}],
          origin: %{source: "depth", resolution: 1, window: "x", span: 10}
        )

      assert ids(numbers) == [{"depth", 1, 0}, {"depth", 1, 10}, {"depth", 1, 20}]

      # Naive times and dates are laid from 1970-01-01 too, their slots naive times.
      {:ok, days} =
        Table.new([{"d", :time, [~D[2026-01-01], ~D[2026-01-02]]}],
          origin: %{source: "daily", resolution: :day, window: "d", span: Duration.new!(day: 1)}
        )

      assert ids(days) == [
               {"daily", :day, ~N[2026-01-01 00:00:00.000000]},
               {"daily", :day, ~N[2026-01-02 00:00:00.000000]}
             ]
    end

    @tag verifies: "table-chunk-ids"
    test "a source's chunks by row count are {source, resolution, row offset}" do
      rows = Table.chunk_rows()
      origin = %{source: "log", resolution: nil, offset: rows - 2}
      {:ok, table} = Table.new([{"m", :text, Enum.map(1..10, &"m#{&1}")}], origin: origin)

      assert ids(table) == [{"log", nil, 0}, {"log", nil, rows}]
      assert for({c, _, _} <- Table.chunks(table), do: Chunk.size(c)) == [2, 8]

      # Trimming never moves a later chunk's slot.
      assert ids(Table.trim(table, 3)) == [{"log", nil, rows}]
    end

    @tag verifies: "table-chunk-ids"
    test "trimming keeps every remaining id; appending writes into the last slot and starts new ones" do
      {:ok, table} = readings([10, 50, 65], cpu())
      [_, {last, 0, 1}] = Table.chunks(table)

      assert ids(Table.trim(table, 1)) == ids(table)
      assert ids(Table.trim(table, 2)) == [{"cpu", 60, ~U[2026-01-01 01:00:00.000000Z]}]

      {:ok, more} = readings([70, 130], %{cpu() | span: @hour})
      {:ok, appended} = Table.append(table, more)

      assert ids(appended) == [
               {"cpu", 60, ~U[2026-01-01 00:00:00.000000Z]},
               {"cpu", 60, ~U[2026-01-01 01:00:00.000000Z]},
               {"cpu", 60, ~U[2026-01-01 02:00:00.000000Z]}
             ]

      # The last slot's chunk is written again: one id, new contents, a new digest.
      [_, {rewritten, 0, 2}, _] = Table.chunks(appended)
      assert Chunk.id(rewritten) == Chunk.id(last)
      refute Chunk.digest(rewritten) == Chunk.digest(last)
      assert Table.column(appended, "t") == Enum.map([10, 50, 65, 70, 130], &at/1)

      # By row count: the last slot fills to chunk_rows/0, then a new chunk starts.
      rows = Table.chunk_rows()
      log = %{source: "log", resolution: nil}
      {:ok, a} = Table.new([{"n", :number, Enum.to_list(1..(rows - 1))}], origin: log)
      {:ok, b} = Table.new([{"n", :number, [rows, rows + 1]}], origin: log)
      {:ok, ab} = Table.append(a, b)
      assert ids(ab) == [{"log", nil, 0}, {"log", nil, rows}]
      assert Table.column(ab, "n") == Enum.to_list(1..(rows + 1))
      assert Table.equal?(ab, Table.new!([{"n", :number, Enum.to_list(1..(rows + 1))}]))
    end

    @tag verifies: "table-chunk-ids"
    test "rows out of window order, and an append of another origin, are refused" do
      assert readings([10, nil, 5], cpu()) == {:error, [{[:origin, :window], {:unsorted, 2}}]}
      assert readings([10, 9], cpu()) == {:error, [{[:origin, :window], {:unsorted, 1}}]}

      {:ok, table} = readings([10, 50], cpu())
      {:ok, early} = readings([30], cpu())
      assert Table.append(table, early) == {:error, {:unsorted, 0}}

      {:ok, other} = readings([70], cpu(300))
      assert Table.append(table, other) == {:error, {:origin, cpu(), cpu(300)}}

      assert Table.new([{"v", :number, [1]}],
               origin: %{source: "cpu", resolution: 60, window: "t", span: @hour}
             ) ==
               {:error, [{[:origin, :window], :unknown}]}

      assert Table.new([{"t", :time, [at(1)]}], origin: %{cpu() | span: 10}) ==
               {:error, [{[:origin, :span], {:type, :duration}}]}
    end

    @tag verifies: "table-chunk-ids"
    test "compaction keeps a source's slots, and the origin is not part of the contents" do
      {:ok, a} = readings([10, 50], cpu())
      {:ok, b} = readings([65], cpu())
      {:ok, table} = Table.append(a, b)
      sliced = Table.slice(table, 1, 2)

      assert ids(Table.compact(sliced)) == ids(sliced)
      assert Table.origin(Table.compact(sliced)) == Table.origin(sliced)

      plain =
        Table.new!([{"t", :time, Enum.map([10, 50, 65], &at/1)}, {"v", :number, [1.0, 2.0, 1.0]}])

      assert Table.equal?(table, plain)
      assert Table.digest(table) == Table.digest(plain)
    end
  end

  describe "resolution" do
    @tag verifies: "table-resolution-ids"
    test "the same rows of one source held at two resolutions share no chunk id" do
      minutes = [10, 50, 65, 180, nil]
      {:ok, fine} = readings(minutes, cpu(60))
      {:ok, coarse} = readings(minutes, cpu(300))

      assert Table.equal?(fine, coarse)
      assert MapSet.disjoint?(MapSet.new(ids(fine)), MapSet.new(ids(coarse)))

      log = fn resolution ->
        Table.new!([{"n", :number, [1, 2]}], origin: %{source: "log", resolution: resolution})
      end

      assert MapSet.disjoint?(MapSet.new(ids(log.(:raw))), MapSet.new(ids(log.(:minute))))
    end
  end

  describe "the span" do
    defp described(fields, extra \\ []),
      do: Description.new([schema: Schema.new!(fields)] ++ extra)

    @tag verifies: "table-span"
    test "chunk_span/2 is the declared span, else chunk_rows times the resolution" do
      time = %{t: %{type: :time}, v: %{type: :number}}
      rows = Table.chunk_rows()

      {:ok, declared} = described(time, chunk_span: @hour)
      assert Description.chunk_span(declared, 60) == @hour
      assert Description.chunk_span(declared, nil) == @hour

      {:ok, derived} = described(time)
      assert Description.chunk_span(derived, 60) == Duration.new!(second: 60 * rows)
      assert Description.chunk_span(derived, :minute) == Duration.new!(second: 60 * rows)
      assert Description.chunk_span(derived, :day) == Duration.new!(second: 86_400 * rows)

      assert Description.chunk_span(derived, 0.001) ==
               Duration.new!(second: 8, microsecond: {192_000, 6})

      assert Description.chunk_span(derived, nil) == nil
      assert Description.chunk_span(derived, :fortnight) == nil

      {:ok, number} = described(%{x: %{type: :number, window: true}})
      assert Description.chunk_span(number, 2) == 2 * rows
      assert Description.chunk_span(number, 0.5) == 0.5 * rows
      assert Description.chunk_span(number, :minute) == nil

      {:ok, none} = described(%{v: %{type: :number}})
      assert Description.chunk_span(none, 60) == nil
    end

    @tag verifies: "table-span"
    test "a description refuses a chunk span of the wrong kind" do
      time = %{t: %{type: :time}}

      for bad <- [60, Duration.new!(month: 1), Duration.new!(second: 0), Duration.new!(hour: -1)] do
        assert described(time, chunk_span: bad) == {:error, [{[:chunk_span], {:type, :duration}}]}
      end

      number = %{x: %{type: :number, window: true}}

      for bad <- [@hour, 0, -1, "10"] do
        assert described(number, chunk_span: bad) == {:error, [{[:chunk_span], {:type, :number}}]}
      end

      assert described(%{v: %{type: :number}}, chunk_span: 10) ==
               {:error, [{[:chunk_span], :no_window_field}]}

      assert {:ok, plain} = described(time)
      assert Map.get(plain, :chunk_span) == nil
    end

    @tag verifies: "table-span"
    test "tables of different rows at one span have their boundaries at the same span starts" do
      {:ok, a} = readings([1, 59, 61, 125], cpu())
      {:ok, b} = readings([30, 70, 179], cpu())

      starts = fn table ->
        for {chunk, _, _} <- Table.chunks(table), do: elem(Chunk.id(chunk), 2)
      end

      for start <- starts.(a) ++ starts.(b) do
        assert DateTime.to_unix(start, :microsecond) |> rem(3_600_000_000) == 0
      end

      assert starts.(a) == Enum.map([0, 60, 120], &at/1)
      assert starts.(b) == Enum.map([0, 60, 120], &at/1)
    end
  end

  describe "derivations" do
    defp step(chunk, key, values), do: Chunk.derive(chunk, key, [{"v", :number, values}])

    @tag verifies: "table-derivation"
    test "a per-row step's output has the id {input id, step key}, its version the derivation digest" do
      [{input, 0, 3}] = Table.chunks(Table.new!([{"v", :number, [1, 2, 3]}]))
      key = {"filter", %{"field" => "v", "gt" => 1}}

      {:ok, out} = step(input, key, [2, 3])
      assert Chunk.id(out) == {Chunk.id(input), key}
      assert Chunk.digest(out) == nil
      assert Chunk.version(out) == Document.digest({[Chunk.version(input)], key})
      assert Chunk.size(out) == 2

      {:ok, next} = step(out, {"take", %{"n" => 1}}, [2])
      assert Chunk.id(next) == {{Chunk.id(input), key}, {"take", %{"n" => 1}}}
      assert Chunk.version(next) == Document.digest({[Chunk.version(out)], {"take", %{"n" => 1}}})
    end

    @tag verifies: "table-derivation"
    test "a global step's output has the digest of its key over its inputs' ids and versions" do
      [{a, 0, 2}] = Table.chunks(Table.new!([{"v", :number, [3, 1]}]))
      [{b, 0, 1}] = Table.chunks(Table.new!([{"v", :number, [2]}]))
      key = {"sort", %{"by" => "v"}}

      {:ok, sorted} = Chunk.combine([a, b], key, [{"v", :number, [1, 2, 3]}])

      assert Chunk.id(sorted) ==
               {:combined,
                Document.digest(
                  {key, [{Chunk.id(a), Chunk.version(a)}, {Chunk.id(b), Chunk.version(b)}]}
                )}

      assert Chunk.version(sorted) == Document.digest({[Chunk.version(a), Chunk.version(b)], key})
      assert Chunk.digest(sorted) == nil
    end

    @tag verifies: "table-derivation"
    test "a derivation digest is the same across runs and changes with an input's version or the key" do
      version = fn values, key ->
        [{input, 0, _}] = Table.chunks(Table.new!([{"v", :number, values}]))
        {:ok, out} = step(input, key, values)
        Chunk.version(out)
      end

      key = {"scale", %{"by" => 2}}
      assert version.([1, 2], key) == version.([1, 2], key)
      refute version.([1, 2], key) == version.([1, 3], key)
      refute version.([1, 2], key) == version.([1, 2], {"scale", %{"by" => 3}})
    end

    @tag verifies: "table-derivation"
    test "a chain of steps hashes no output's contents; compact/1 gives an output its content digest" do
      [{input, 0, 3}] = Table.chunks(Table.new!([{"v", :number, [1, 2, 3]}]))

      hashed =
        calls({Digest, :digest, 3}, fn ->
          {:ok, a} = step(input, {"a", %{}}, [1, 2, 3])
          {:ok, b} = step(a, {"b", %{}}, [2, 3])
          {:ok, c} = Chunk.combine([b], {"c", %{}}, [{"v", :number, [3, 2]}])
          {:ok, table} = Table.from_chunks([{"v", :number}], [c])
          send(self(), {:table, table})
        end)

      assert hashed == []
      assert_received {:table, table}
      assert Table.column(table, "v") == [3, 2]
      assert [{derived, 0, 2}] = Table.chunks(table)
      assert Chunk.digest(derived) == nil

      [{compacted, 0, 2}] = Table.chunks(Table.compact(table))
      assert Chunk.digest(compacted) == Table.digest(Table.new!([{"v", :number, [3, 2]}]))
      assert Table.equal?(Table.compact(table), table)
    end

    @tag verifies: "table-derivation"
    test "from_chunks/2 refuses a chunk of other columns" do
      [{input, 0, 1}] = Table.chunks(Table.new!([{"v", :number, [1]}]))

      assert Table.from_chunks([{"w", :number}], [input]) ==
               {:error, {:columns, [{"w", :number}], ["v"]}}
    end
  end
end
