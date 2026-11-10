defmodule Macaw.Data.TableSubsetTest do
  @moduledoc """
  Rows of a table in any order across its chunks (spec/01 §2.4, macaw_data#128): gathered
  by their slots, each column joined across the chunks where they share a form, and equal
  to the same rows packed afresh, over every form, gaps, partial views and mixed forms:
  text beside binary pieces, dictionaries of different strings, booleans beside names.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Table
  alias Macaw.Data.Table.{Chunk, Subset}

  @base ~U[2026-01-01 00:00:00Z]

  # A value of each kind a column may hold, `k` choosing it; `nil` a gap.
  defp value(_kind, nil), do: nil
  defp value(:int, k), do: k
  defp value(:float, k), do: k * 0.5
  defp value(:huge, k), do: k * 1_000_000_000_000_000_000
  defp value(:utc, k), do: DateTime.add(@base, k, :second)
  defp value(:micro, k), do: DateTime.add(@base, k, :microsecond)
  defp value(:naive, k), do: DateTime.to_naive(DateTime.add(@base, k, :millisecond))
  defp value(:date, k), do: Date.add(~D[2026-01-01], k)
  defp value(:text, k), do: "s#{k}"
  defp value(:category, k), do: Enum.at(["a", "b", "c"], rem(abs(k), 3))
  defp value(:bytes, k), do: <<255, k + 10>>

  defp value(:flagged, k),
    do: if(rem(k, 2) == 0, do: k > 0, else: Enum.at(["c", "d"], rem(abs(k), 2)))

  # A column's kinds across the chunks: one kind throughout, or each chunk its own of one
  # type, so pieces of one column may hold different forms (int64 beside float64, whole
  # seconds beside microseconds).
  defp kinds(type, chunks) do
    of_type =
      case type do
        :number -> [:int, :float, :huge]
        :time -> [:utc, :micro, :naive, :date]
        :text -> [:text, :bytes]
        :category -> [:category, :flagged]
      end

    one_of([
      bind(member_of(of_type), &constant(List.duplicate(&1, chunks))),
      list_of(member_of(of_type), length: chunks)
    ])
  end

  defp input do
    gen all(
          types <-
            list_of(member_of([:number, :time, :text, :category]), min_length: 1, max_length: 4),
          sizes <- list_of(integer(0..12), min_length: 1, max_length: 4),
          columns <- fixed_list(Enum.map(types, &kinds(&1, length(sizes)))),
          ks <-
            list_of(one_of([constant(nil), integer(-9..9)]),
              length: Enum.sum(sizes) * length(types)
            ),
          skip <- integer(0..2),
          trim <- integer(0..2),
          share <- member_of([:all, :some, :few]),
          seed <- integer(0..10_000)
        ) do
      {types, sizes, columns, ks, skip, trim, share, seed}
    end
  end

  # The table, chunk by chunk, each chunk packed by itself, its first and last views partial.
  defp table({types, sizes, columns, ks, skip, trim, _share, _seed}) do
    names = for i <- 0..(length(types) - 1), do: :"c#{i}"
    per = Enum.chunk_every(ks, length(types))

    {pieces, _rest} =
      Enum.map_reduce(Enum.with_index(sizes), per, fn {n, c}, rest ->
        {rows, rest} = Enum.split(rest, n)

        piece =
          Table.new!(
            for {{name, type}, i} <- Enum.with_index(Enum.zip(names, types)) do
              kind = Enum.at(Enum.at(columns, i), c)
              {name, type, Enum.map(rows, &value(kind, Enum.at(&1, i)))}
            end
          )

        {piece, rest}
      end)

    [first | more] = pieces
    joined = Enum.reduce(more, first, fn piece, acc -> elem(Table.append(acc, piece), 1) end)
    size = Table.size(joined)
    start = min(skip, size)
    Table.slice(joined, start, max(size - start - trim, 0))
  end

  defp indexes(size, share, seed) do
    :rand.seed(:exsss, {seed, 7, 11})
    all = Enum.shuffle(0..(size - 1)//1)

    case share do
      :all -> all
      :some -> Enum.take(all, div(size, 2))
      :few -> Enum.take(all, div(size, 5))
    end
  end

  # The same rows packed afresh, column by column.
  defp packed(table, indexes) do
    rows = Table.rows!(table) |> List.to_tuple()

    Table.new!(
      for name <- Table.names(table) do
        {name, Table.column_type(table, name),
         Enum.map(indexes, &Table.get(elem(rows, &1), name))}
      end
    )
  end

  @tag verifies: "finish-subset-gather"
  property "rows in any order across chunks equal the same rows packed, over every form" do
    check all(given <- input(), max_runs: 400) do
      {_types, _sizes, _columns, _ks, _skip, _trim, share, seed} = given
      table = table(given)
      indexes = indexes(Table.size(table), share, seed)
      taken = Subset.at(table, indexes)

      assert Table.size(taken) == length(indexes)
      assert Table.equal?(taken, packed(table, indexes))
      assert Enum.all?(Table.chunks(taken), fn {_c, _f, n} -> n <= Table.chunk_rows() end)
    end
  end

  @tag verifies: "finish-subset-gather"
  property "rows repeated, in any order across chunks, equal the same rows packed (#205)" do
    check all(given <- input(), repeats <- integer(1..6), max_runs: 200) do
      {_types, _sizes, _columns, _ks, _skip, _trim, share, seed} = given
      table = table(given)
      once = indexes(Table.size(table), share, seed)
      indexes = Enum.shuffle(once ++ Enum.take(once, repeats))
      taken = Subset.at(table, indexes)

      assert Table.size(taken) == length(indexes)
      assert Table.equal?(taken, packed(table, indexes))
    end
  end

  # A view's kept rows spanning as many places as they hold read as a run only when none
  # repeats: [10, 10, 12, 13] spans four and holds four, and is not rows 10 to 13 (#205).
  @tag verifies: "finish-subset-gather"
  test "repeated rows in a view are gathered, never read as the run they span" do
    table = Macaw.Data.Test.Storage.chunked(Table.new!([{"v", :number, Enum.to_list(0..29)}]), 5)

    assert Table.column(Subset.at(table, [12, 10, 10, 13]), "v") == [12, 10, 10, 13]

    assert Table.column(Subset.at(table, [13, 10, 13, 14, 14, 27]), "v") == [
             13,
             10,
             13,
             14,
             14,
             27
           ]
  end

  @tag verifies: "finish-subset-gather"
  test "a reorder of more than a chunk's rows is chunked at chunk_rows/0, each column joined" do
    n = Table.chunk_rows() * 2 + 100

    a =
      Table.new!([
        {:i, :number, Enum.to_list(0..(n - 1))},
        {:t, :time, for(k <- 0..(n - 1), do: value(:utc, k))}
      ])

    b =
      Table.new!([
        {:i, :number, Enum.map(n..(2 * n - 1), &(&1 * 1.0))},
        {:t, :time, for(k <- n..(2 * n - 1), do: value(:utc, k))}
      ])

    {:ok, table} = Table.append(a, b)
    indexes = Enum.to_list((2 * n - 1)..0//-1)
    taken = Subset.at(table, indexes)

    assert Table.equal?(taken, packed(table, indexes))
    assert Enum.map(Table.chunks(taken), &elem(&1, 2)) |> Enum.max() == Table.chunk_rows()
    assert Table.column(taken, :t) |> hd() == value(:utc, 2 * n - 1)
  end

  # The form of a table's one chunk's column, as stored.
  defp form(table, name) do
    [{chunk, first, count}] = Table.chunks(table)
    elem(Chunk.storage(chunk, name, first, count), 0)
  end

  @tag verifies: "finish-subset-gather"
  test "text, binary and dictionary pieces join, a dictionary's codes moved to one dictionary" do
    a =
      Table.new!([
        {:s, :text, ["x", nil, "yy"]},
        {:c, :category, ["a", true, nil]},
        {:b, :text, [<<255>>, nil, <<254>>]}
      ])

    b =
      Table.new!([
        {:s, :text, ["zzz", "w"]},
        {:c, :category, ["b", "a"]},
        {:b, :text, [<<253>>, <<252, 1>>]}
      ])

    {:ok, table} = Table.append(a, b)
    indexes = [4, 0, 2, 3, 1]
    taken = Subset.at(table, indexes)

    assert Table.equal?(taken, packed(table, indexes))
    assert Table.column(taken, :c) == ["a", "a", nil, "b", true]
    assert Table.column(taken, :s) == ["w", "x", "yy", "zzz", nil]
    assert form(taken, :s) == :text
    assert form(taken, :c) == :dictionary
    assert form(taken, :b) == :binary
  end
end
