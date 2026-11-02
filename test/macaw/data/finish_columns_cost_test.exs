defmodule Macaw.Data.FinishColumnsCostTest do
  # What finishing a table on its columns costs (spec/01 §2.4, macaw_data#105), counted in
  # reductions (`Macaw.Data.Test.Work`). Not async: the count is exact only where no other
  # test loads or purges code.
  use ExUnit.Case, async: false

  alias Macaw.Data.{Delivery, Derived, Native, Schema, Table}
  alias Macaw.Data.Source.{Description, Finish, Request}
  alias Macaw.Data.Table.Subset
  alias Macaw.Data.Test.Work

  @base ~U[2026-01-01 00:00:00Z]
  @schema Schema.new!(%{
            t: %{type: :time},
            host: %{type: :category, identity: true},
            cpu: %{type: :number}
          })
  @half [DateTime.add(@base, 500, :second), nil]

  # 50,000 readings over 50 hosts, a reading a host a second, in time order: 1,000 seconds.
  defp readings(opts \\ []) do
    n = 50_000

    table =
      Table.new!([
        {:t, :time, for(i <- 0..(n - 1), do: DateTime.add(@base, div(i, 50), :second))},
        {:host, :category, for(i <- 0..(n - 1), do: "h#{rem(i, 50)}")},
        {:cpu, :number, for(i <- 0..(n - 1), do: rem(i * 7, 100) * 1.0)}
      ])

    if opts[:sorted] do
      header = for name <- Table.names(table), do: {name, Table.column_type(table, name)}
      {:ok, sorted} = Table.from_chunks(header, Table.chunks(table), sorted: :t)
      sorted
    else
      table
    end
  end

  defp finish(table, fields) do
    request = Request.new!([now: ~U[2026-10-27 00:00:00Z]] ++ fields)
    Finish.finish(Delivery.new!(table), %Description{schema: @schema}, request)
  end

  # Finishing the table to half its window scans its time buffer and keeps runs of its
  # chunks: 319,799 when this was written, against 5,349,486 when every step transposed
  # the table and repacked the rows it kept, and 1,705,513 for one transpose. Its sorted
  # twin binary-searches the window field to one run: 5,252. Latest reads the time
  # buffer's instants and the host column's values and gathers 50 rows: 609,412, against
  # 5,163,695 by rows.
  @tag verifies: "finish-columns-cost"
  test "finishing a 50k-row table by window or latest costs less than one transpose" do
    table = readings()
    {transpose, _rows} = Work.reductions(fn -> Table.rows(table) end)

    {window, {:ok, half}} = Work.reductions(fn -> finish(table, window: @half) end)
    assert Table.size(half.rows) == 25_000
    assert window < 400_000
    assert window < transpose

    sorted = readings(sorted: true)
    {search, {:ok, run}} = Work.reductions(fn -> finish(sorted, window: @half) end)
    assert Table.equal?(run.rows, half.rows)
    assert search < 20_000

    {latest, {:ok, newest}} = Work.reductions(fn -> finish(table, latest: true) end)
    assert Table.size(newest.rows) == 50
    assert latest < 750_000
    assert latest < transpose
  end

  # A window of another kind of time than its column (macaw_data#124) compares on the
  # instant scale the buffer holds, so it scans the buffer as a bound of the column's own
  # kind does: 319,993 for a naive half window over the UTC column when this was written,
  # 319,867 for a UTC one; it raised before. Its sorted twin is the same binary search.
  @tag verifies: "finish-columns-cost"
  test "a window of another kind of time than its column scans the buffer as its own kind does" do
    table = readings()
    {transpose, _rows} = Work.reductions(fn -> Table.rows(table) end)
    naive = Enum.map(@half, &(&1 && DateTime.to_naive(&1)))

    {window, {:ok, half}} = Work.reductions(fn -> finish(table, window: naive) end)
    assert Table.size(half.rows) == 25_000
    assert window < 400_000
    assert window < transpose

    sorted = readings(sorted: true)
    {search, {:ok, run}} = Work.reductions(fn -> finish(sorted, window: naive) end)
    assert Table.equal?(run.rows, half.rows)
    assert search < 20_000
  end

  # Latest over a naive or a date column reads its buffer's instants as it lies, as over a
  # UTC one (macaw_data#127): 609,472 each when this was written, against 2,009,465 (naive)
  # and 1,567,973 (date) when their positions were read value by value.
  @tag verifies: "finish-columns-cost"
  test "latest over a naive or a date column reads its buffer as over a UTC one" do
    table = readings()
    {utc, {:ok, _newest}} = Work.reductions(fn -> finish(table, latest: true) end)

    for to <- [&DateTime.to_naive/1, &DateTime.to_date/1] do
      retimed =
        Table.new!([
          {:t, :time, Enum.map(Table.column(table, :t), to)},
          {:host, :category, Table.column(table, :host)},
          {:cpu, :number, Table.column(table, :cpu)}
        ])

      {latest, {:ok, newest}} = Work.reductions(fn -> finish(retimed, latest: true) end)
      assert Table.size(newest.rows) == 50
      assert latest < 750_000
      assert latest < utc * 1.1
    end
  end

  # A region reads its ranged columns, a scan of each packed buffer, intersected: 718,109
  # when this was written, 3,697,471 by rows. An order with a budget sorts the row indexes
  # by the order's columns and gathers its head alone: 1,569,977, 7,851,916 by rows. A
  # budget reduces each host's series from its columns and gathers the kept rows:
  # 5,685,119, 10,263,925 by rows; most of it is the reducer's own work, which the rows
  # paid too.
  @tag verifies: "finish-columns-cost"
  test "finishing a 50k-row table by region, order and budget stays under its bounds" do
    table = readings()
    {transpose, _rows} = Work.reductions(fn -> Table.rows(table) end)

    {region, {:ok, kept}} = Work.reductions(fn -> finish(table, region: %{cpu: [50, 100]}) end)
    assert Table.size(kept.rows) == 25_000
    assert region < 900_000
    assert region < transpose

    {top, {:ok, head}} =
      Work.reductions(fn -> finish(table, order: [{:cpu, :desc}], budget: 1_000) end)

    assert Table.size(head.rows) == 1_000
    assert Enum.all?(Table.column(head.rows, :cpu), &(&1 >= 98.0))
    assert top < 2_000_000

    {budget, {:ok, reduced}} = Work.reductions(fn -> finish(table, budget: 1_000) end)
    assert Table.size(reduced.rows) <= 1_000
    assert budget < 6_500_000
  end

  # A derived source's request window over a table input is the same finishing: 319,907
  # when this was written, 4,109,058 when the table was transposed and finished as rows.
  @tag verifies: "finish-columns-cost"
  test "Derived.window/3 finishes a request window on a 50k-row table for less than a transpose" do
    table = readings()
    {transpose, _rows} = Work.reductions(fn -> Table.rows(table) end)

    {reductions, windowed} =
      Work.reductions(fn -> Derived.window(table, %{window: @half}, @schema) end)

    assert %Table{} = windowed
    assert Table.size(windowed) == 25_000
    assert reductions < 400_000
    assert reductions < transpose
  end

  # Rows in another order across chunks are gathered by their slots, each fixed-width column
  # joined across the chunks (macaw_data#128): a random permutation of 50k rows of an int64,
  # a float64 and a UTC column cost 1,228,251 reductions on the Elixir path when this was
  # written (448,160 with the kernels), against 4,088,217 when every column was decoded and
  # packed again. A full order by cpu: 2,856,710 (2,076,736 with the kernels; its sort
  # 1,471,715), against 5,316,721, its category column's codes joined too (macaw_data#138).
  # A reorder of a text and a category column: 1,156,091 (896,060), against 2,064,177.
  # Counted on the Elixir path, which every job runs alike.
  @tag verifies: "finish-columns-cost"
  test "rows in another order across chunks are gathered by their slots, a full order too" do
    n = 50_000
    table = readings()

    fixed =
      Table.new!([
        {:a, :number, Enum.to_list(1..n)},
        {:b, :number, Enum.map(1..n, &(&1 * 0.5))},
        {:t, :time, Table.column(table, :t)}
      ])

    :rand.seed(:exsss, {1, 2, 3})
    shuffled = Enum.shuffle(0..(n - 1))

    {gather, taken} =
      Work.reductions(fn -> Native.elixir(fn -> Subset.at(fixed, shuffled) end) end)

    assert Table.column(taken, :a) == Enum.map(shuffled, &(&1 + 1))
    assert gather < 1_400_000

    {order, {:ok, ordered}} =
      Work.reductions(fn ->
        Native.elixir(fn -> finish(table, order: [{:cpu, :desc}]) end)
      end)

    assert Table.size(ordered.rows) == n
    assert order < 3_000_000

    named =
      Table.new!([
        {:s, :text, for(i <- 1..n, do: "row-#{i}")},
        {:host, :category, Table.column(table, :host)}
      ])

    {strings, taken} =
      Work.reductions(fn -> Native.elixir(fn -> Subset.at(named, shuffled) end) end)

    assert Table.column(taken, :s) == Enum.map(shuffled, &"row-#{&1 + 1}")
    assert strings < 1_500_000
  end
end
