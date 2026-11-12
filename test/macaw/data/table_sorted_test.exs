defmodule Macaw.Data.TableSortedTest do
  @moduledoc """
  The column a table is known to be sorted by (`Table.sorted/1`, spec/01 §1.1.3) through
  every function that changes a table's layout and keeps its rows' order (macaw_data#260):
  the mark is kept, with and without an origin, and whenever a result names a column its
  rows are in that column's order, `nil` last. A reader binary-searches only that column
  (spec/04 §4.3), so a mark lost costs a scan and a mark kept untrue a wrong answer.

  The origin-less `append/2` of rows out of order and `apply/2` keeping a mark their rows
  no longer satisfy are macaw_data#261's.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Table
  alias Macaw.Data.Table.Subset
  alias Macaw.Data.Test.Storage

  @header [{"x", :number}, {"v", :number}]

  # Ascending window values, gaps last, as a window field is held (spec/01 §1.5).
  defp xs do
    gen all(
          values <- list_of(integer(-50..50), max_length: 60),
          gaps <- integer(0..5)
        ) do
      Enum.sort(values) ++ List.duplicate(nil, gaps)
    end
  end

  defp columns(xs), do: [{"x", :number, xs}, {"v", :number, Enum.to_list(1..length(xs)//1)}]

  # The rows `xs`, as a source's table (in event time or by row count) or as a step's
  # output of chunks of `size` rows marked sorted by "x".
  defp build({:source, span}, xs, _size),
    do: Table.new!(columns(xs), origin: %{source: "s", resolution: 1, window: "x", span: span})

  defp build(:chunks, xs, size) do
    {:ok, chunked} =
      xs
      |> columns()
      |> Table.new!()
      |> Storage.chunked(size)
      |> then(&Table.from_chunks(@header, Table.chunks(&1), sorted: "x"))

    chunked
  end

  # In "x"'s order, `nil` last.
  defp ordered?(xs) do
    {present, gaps} = Enum.split_while(xs, &(&1 != nil))
    present == Enum.sort(present) and Enum.all?(gaps, &is_nil/1)
  end

  # Every order-keeping layout function of `table`, by name; `rest` the rows after it.
  defp results(table, rest, kind, size, cut, count, picks) do
    n = Table.size(table)
    indexes = Enum.filter(0..(n - 1)//1, &(rem(&1, picks) == 0))
    {:ok, appended} = Table.append(table, build(kind, rest, size))

    [
      compact: Table.compact(table),
      slice: Table.slice(table, cut, count),
      trim: Table.trim(table, cut),
      detached: Table.detached(table),
      warm: Table.warm(table),
      compact_of_slice: Table.compact(Table.slice(table, cut, count)),
      subset_at: Subset.at(table, indexes),
      subset_picked: Subset.picked(table, indexes, {:reduced, :none, length(indexes)}),
      append: appended,
      compact_of_append: Table.compact(appended)
    ]
  end

  @tag verifies: "table-sorted"
  property "every order-keeping layout function keeps the sorted mark, and the mark is true" do
    check all(
            xs <- xs(),
            kind <- member_of([{:source, 10}, {:source, nil}, :chunks]),
            split <- integer(0..60),
            size <- integer(1..9),
            cut <- integer(0..60),
            count <- integer(0..60),
            picks <- integer(1..4),
            max_runs: 300
          ) do
      {head, rest} = Enum.split(xs, split)
      table = build(kind, head, size)
      assert Table.sorted(table) == "x"

      for {name, result} <- results(table, rest, kind, size, cut, count, picks) do
        assert {name, Table.sorted(result)} == {name, "x"}
        assert {name, ordered?(Table.column(result, "x"))} == {name, true}
      end
    end
  end

  @tag verifies: "table-sorted"
  test "compact/1 of a table not a source's keeps its sorted column (#260)" do
    t = Table.new!([{"x", :number, [1, 2, 3]}])
    [{c, _, _}] = Table.chunks(t)
    {:ok, s} = Table.from_chunks([{"x", :number}], [{c, 0, 2}, {c, 2, 1}], sorted: "x")

    assert {Table.sorted(s), Table.sorted(Table.compact(s))} == {"x", "x"}
    assert Table.column(Table.compact(s), "x") == [1, 2, 3]
    {:ok, none} = Table.from_chunks([{"x", :number}], [{c, 0, 2}, {c, 2, 1}])
    assert Table.sorted(Table.compact(none)) == nil
  end
end
