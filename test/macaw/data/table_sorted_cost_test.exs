defmodule Macaw.Data.TableSortedCostTest do
  @moduledoc """
  What keeping a table's sorted mark true costs (macaw_data#261, spec/01 §1.1.3): an
  `append/2` or `apply/2` of a table not a source's reads only the rows it adds and the
  held table's last, so the check costs the same over a held table of 1k rows as of 50k,
  in a bound pinned per row added; a source's table, whose paths already keep its order,
  checks nothing.
  """
  use ExUnit.Case, async: false

  alias Macaw.Data.Table
  alias Macaw.Data.Test.Work

  @header [{"x", :number}, {"v", :number}]
  @added 100

  defp held(n, sorted) do
    {:ok, table} =
      [{"x", :number, Enum.to_list(1..n)}, {"v", :number, Enum.to_list(1..n)}]
      |> Table.new!()
      |> Table.chunks()
      |> then(&Table.from_chunks(@header, &1, sorted: sorted))

    table
  end

  defp added(n, sorted) do
    xs = Enum.to_list((n + 1)..(n + @added))
    chunks = Table.chunks(Table.new!([{"x", :number, xs}, {"v", :number, xs}]))
    {:ok, table} = Table.from_chunks(@header, chunks, sorted: sorted)
    table
  end

  defp rows(n), do: for(x <- (n + 1)..(n + @added), do: %{"x" => x, "v" => x})

  defp red(f), do: elem(Work.reductions(f), 0)

  # The reductions the mark's check adds: the operation on the marked table less the same
  # on its unmarked twin, which checks nothing.
  defp check_cost(n, op) do
    {marked, unmarked} = {held(n, "x"), held(n, nil)}
    red(fn -> op.(marked, n) end) - red(fn -> op.(unmarked, n) end)
  end

  # Pinned per row added (macaw_data#261: 100 rows cost ~1.1k reductions to check, two ~110).
  @per_row 20
  # A 50k-row held table's check over a 1k one's: its last row is found among more chunks.
  @slack 200

  @tag verifies: "table-sorted"
  test "an append of rows marked by nothing reads only them and the table's last row" do
    op = fn table, n -> Table.append(table, added(n, nil)) end
    small = check_cost(1_000, op)
    large = check_cost(50_000, op)

    assert {small > 0, sorted_kept(op, 50_000)} == {true, "x"}
    assert large < @per_row * @added
    assert large < small + @slack
  end

  @tag verifies: "table-sorted"
  test "an append of rows marked by the same column reads two rows" do
    op = fn table, n -> Table.append(table, added(n, "x")) end
    assert check_cost(50_000, op) < 2 * @slack
  end

  @tag verifies: "table-sorted"
  test "rows inserted after the held ones are checked alone" do
    op = fn table, n -> Table.apply(table, %{insert: rows(n)}) end
    small = check_cost(1_000, op)
    large = check_cost(50_000, op)

    {applied, [], 0} = op.(held(50_000, "x"), 50_000)
    assert Table.sorted(applied) == "x"
    assert large < @per_row * @added
    assert large < small + @slack
  end

  defp sorted_kept(op, n) do
    {:ok, table} = op.(held(n, "x"), n)
    Table.sorted(table)
  end
end
