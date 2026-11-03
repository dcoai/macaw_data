defmodule Macaw.Data.Derived.ColumnsTimeKindTest do
  @moduledoc """
  The kind of time a column holds, read from its storage form alone (macaw_data#149,
  spec/01 §1.1.5, spec/02 §2.2): `Columns.time_kind/2` and `Chunk.time_kind/4`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Derived.Columns
  alias Macaw.Data.Table
  alias Macaw.Data.Table.{Chunk, Column}
  alias Macaw.Data.Test.Trace

  @utc ~U[2026-01-01 00:00:00Z]

  defp time(:utc, s), do: DateTime.add(@utc, s, :second)

  defp time(:zoned, s) do
    wall = DateTime.add(time(:utc, s), 3600, :second)
    %{wall | time_zone: "Europe/Paris", zone_abbr: "CET", utc_offset: 3600, std_offset: 0}
  end

  defp time(:naive, s), do: DateTime.to_naive(time(:utc, s))
  defp time(:date, s), do: Date.add(~D[2026-01-01], s)

  defp table(pieces) do
    pieces
    |> Enum.map(&Table.new!([{"t", :time, &1}, {"v", :number, Enum.map(&1, fn _ -> 1 end)}]))
    |> Enum.reduce(fn piece, table ->
      {:ok, table} = Table.append(table, piece)
      table
    end)
  end

  defp kinds(table),
    do: for({chunk, first, n} <- Table.chunks(table), do: Chunk.time_kind(chunk, "t", first, n))

  @tag verifies: "table-time-kind"
  test "each storage form gives its kind, read per chunk run" do
    for {kind, expected} <- [utc: DateTime, zoned: DateTime, naive: NaiveDateTime, date: Date] do
      table = table([[time(kind, 0), nil, time(kind, 1)]])
      assert kinds(table) == [expected]
      assert Columns.time_kind(table, "t") == {:ok, expected}
      assert Columns.time_kind!(table, :t) == expected
    end

    # One chunk of two kinds is the general form: mixed.
    mixed = table([[time(:utc, 0), time(:naive, 1)]])
    assert kinds(mixed) == [:mixed]
    assert Columns.time_kind(mixed, "t") == {:ok, :mixed}

    # A UTC and a zoned chunk are one kind; a UTC and a naive one are mixed.
    assert Columns.time_kind(table([[time(:utc, 0)], [time(:zoned, 1)]]), "t") ==
             {:ok, DateTime}

    two = table([[time(:utc, 0)], [time(:naive, 1)]])
    assert kinds(two) == [DateTime, NaiveDateTime]
    assert Columns.time_kind(two, "t") == {:ok, :mixed}

    # A run of a chunk is its chunk's kind, whatever its bounds.
    [{chunk, _first, _n}] = Table.chunks(table([[time(:date, 0), nil, time(:date, 2)]]))
    assert Chunk.time_kind(chunk, "t", 1, 1) == Date
    assert Chunk.time_kind(chunk, "t", 0, 0) == Date

    # A column the chunk does not hold, or one not of times, has no kind of time.
    assert Chunk.time_kind(chunk, "v", 0, 3) == nil
    assert Chunk.time_kind(chunk, "w", 0, 3) == nil
  end

  @tag verifies: "table-time-kind"
  test "a column with no value is DateTime, and a chunk with none takes no part in the kind" do
    assert Columns.time_kind(table([[nil, nil]]), "t") == {:ok, DateTime}
    assert Columns.time_kind(Table.new!([{"t", :time, []}]), "t") == {:ok, DateTime}

    # The empty chunk packs as DateTime; the kind is the naive chunk's.
    gaps = table([[nil, nil], [time(:naive, 0)]])
    assert kinds(gaps) == [DateTime, NaiveDateTime]
    assert Columns.time_kind(gaps, "t") == {:ok, NaiveDateTime}
  end

  @tag verifies: "table-time-kind"
  test "the kind is read without decoding a value" do
    table = table([[time(:naive, 0), nil, time(:naive, 2)], [time(:date, 0)], [nil]])

    for read <- [
          {Column, :values, 2},
          {Macaw.Data.Source.Order, :instant, 1},
          {Table, :column, 2}
        ] do
      assert Trace.calls(read, fn -> Columns.time_kind(table, "t") end) == []
    end

    assert Columns.time_kind(table, "t") == {:ok, :mixed}

    # The cost is a few reductions a chunk, not a row: a 50k-row column costs what a
    # 50-row one does, give or take a chunk's.
    small = table([Enum.map(0..49, &time(:utc, &1))])
    large = table(Enum.map(0..9, fn c -> Enum.map(0..4_999, &time(:utc, c * 5_000 + &1)) end))

    assert reductions(fn -> Columns.time_kind(large, "t") end) <
             50 * reductions(fn -> Columns.time_kind(small, "t") end)

    assert reductions(fn -> Columns.time_kind(large, "t") end) < 5_000
  end

  @tag verifies: "derived-columns-time-kind"
  test "an unknown column, a column not of times and an input not a table are faults" do
    table = table([[time(:utc, 0)]])
    assert Columns.time_kind(table, "w") == {:error, {:unknown_column, "w"}}
    assert Columns.time_kind(table, :v) == {:error, {:wrong_type, "v", [:time], :number}}
    assert Columns.time_kind([%{"t" => @utc}], "t") == {:error, {:type, :table}}
    assert Columns.time_kind(table, 1) == {:error, {:type, :name}}

    assert_raise Macaw.Data.Error, ~s(column "v" is :number, not :time), fn ->
      Columns.time_kind!(table, "v")
    end

    assert_raise Macaw.Data.Error, ~r/no column "w"/, fn -> Columns.time_kind!(table, "w") end
  end

  @tag verifies: "derived-columns-time-kind"
  property "the kind agrees with the kinds of the decoded values, for columns of every kind, mixed and missing" do
    check all(
            pieces <-
              list_of(
                gen all(
                      kind <- member_of([:utc, :zoned, :naive, :date, :mixed]),
                      values <-
                        list_of(
                          frequency([
                            {1, constant(nil)},
                            {4,
                             gen(
                               all(
                                 k <-
                                   if(kind == :mixed,
                                     do: member_of([:utc, :zoned, :naive, :date]),
                                     else: constant(kind)
                                   ),
                                 s <- integer(-100..100),
                                 do: time(k, s)
                               )
                             )}
                          ]),
                          max_length: 12
                        )
                    ) do
                  values
                end,
                min_length: 1,
                max_length: 5
              )
          ) do
      table = table(pieces)

      expected =
        case pieces
             |> List.flatten()
             |> Enum.reject(&is_nil/1)
             |> Enum.map(& &1.__struct__)
             |> Enum.uniq() do
          [] -> DateTime
          [kind] -> kind
          _several -> :mixed
        end

      assert Columns.time_kind(table, "t") == {:ok, expected}

      # Each run's kind is that of the values it holds, or DateTime holding none.
      for {chunk, first, n} <- Table.chunks(table) do
        values = Chunk.values(chunk, "t", first, n) |> Enum.reject(&is_nil/1)

        case values |> Enum.map(& &1.__struct__) |> Enum.uniq() do
          [] -> assert Chunk.time_kind(chunk, "t", first, n) == DateTime
          [kind] -> assert Chunk.time_kind(chunk, "t", first, n) == kind
          _several -> assert Chunk.time_kind(chunk, "t", first, n) == :mixed
        end
      end
    end
  end

  @tag verifies: "table-time-kind"
  test "Chunk.instants/4 reads a run's instants, every kind on one scale" do
    table = table([[time(:utc, 0), nil, time(:zoned, 1)], [time(:naive, 2), time(:date, 1)]])

    instants =
      for {chunk, first, n} <- Table.chunks(table),
          instant <- Chunk.instants(chunk, "t", first, n),
          do: instant

    base = DateTime.to_unix(@utc, :microsecond)
    assert instants == [base, nil, base + 1_000_000, base + 2_000_000, base + 86_400_000_000]
  end

  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, after_} = Process.info(self(), :reductions)
    after_ - before
  end
end
