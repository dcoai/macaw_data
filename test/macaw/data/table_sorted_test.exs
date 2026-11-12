defmodule Macaw.Data.TableSortedTest do
  @moduledoc """
  The column a table is known to be sorted by (`Table.sorted/1`, spec/01 §1.1.3) through
  every function that changes a table's layout (macaw_data#260, #261): the mark is kept
  where the rows keep its order, with and without an origin, and whenever a result names a
  column its rows are in that column's order, `nil` last. A reader binary-searches only
  that column (spec/04 §4.3), so a mark lost costs a scan and a mark kept untrue a wrong
  answer: every reader that trusts it answers on a marked result as on the same rows
  unmarked.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Operations, Schema, Table}
  alias Macaw.Data.Derived.Last
  alias Macaw.Data.Source.Finish.Columns
  alias Macaw.Data.Table.Subset
  alias Macaw.Data.Test.Storage

  @registry Operations.registry()
  @base ~U[2026-01-01 00:00:00Z]

  # A window value of the kind at step `k`: a number itself, a time `k` seconds on.
  defp at(_xkind, nil), do: nil
  defp at(:number, k), do: k
  defp at(:time, k), do: DateTime.add(@base, k, :second)

  defp type(:number), do: :number
  defp type(:time), do: :time

  defp header(xkind), do: [{"x", type(xkind)}, {"v", :number}]

  defp schema(xkind),
    do: Schema.new!(%{"x" => %{type: type(xkind), window: true}, "v" => %{type: :number}})

  # Ascending window values, gaps last, as a window field is held (spec/01 §1.5).
  defp xs do
    gen all(
          values <- list_of(integer(-50..50), max_length: 60),
          gaps <- integer(0..5)
        ) do
      Enum.sort(values) ++ List.duplicate(nil, gaps)
    end
  end

  # Window values in any order, gaps anywhere.
  defp any_xs, do: list_of(one_of([integer(-60..60), constant(nil)]), max_length: 20)

  defp columns(xkind, xs, from \\ 1),
    do: [
      {"x", type(xkind), Enum.map(xs, &at(xkind, &1))},
      {"v", :number, Enum.to_list(from..(from + length(xs) - 1)//1)}
    ]

  defp rows(xkind, xs, from),
    do: xs |> Enum.with_index(from) |> Enum.map(fn {x, v} -> %{"x" => at(xkind, x), "v" => v} end)

  defp origin(:number, span), do: %{source: "s", resolution: 1, window: "x", span: span}

  defp origin(:time, span),
    do: %{source: "s", resolution: 1, window: "x", span: span && Duration.new!(second: span)}

  # The rows `xs`, as a source's table (in event time or by row count) or as a step's
  # output of chunks of `size` rows, marked sorted by "x" when `sorted`.
  defp build({:source, span}, xkind, xs, _size, _sorted),
    do: Table.new!(columns(xkind, xs), origin: origin(xkind, span))

  defp build(:chunks, xkind, xs, size, sorted) do
    {:ok, chunked} =
      xkind
      |> columns(xs)
      |> Table.new!()
      |> Storage.chunked(size)
      |> then(&Table.from_chunks(header(xkind), Table.chunks(&1), sorted: sorted && "x"))

    chunked
  end

  # The same rows and chunks, marked by nothing.
  defp unmarked(table) do
    header = for name <- Table.names(table), do: {name, Table.column_type(table, name)}
    {:ok, unmarked} = Table.from_chunks(header, Table.chunks(table))
    unmarked
  end

  # In "x"'s order, `nil` last.
  defp ordered?(xs) do
    {present, gaps} = xs |> Enum.map(&key/1) |> Enum.split_while(&(&1 != nil))
    present == Enum.sort(present) and Enum.all?(gaps, &is_nil/1)
  end

  defp key(%DateTime{} = t), do: DateTime.to_unix(t)
  defp key(other), do: other

  # Every order-keeping layout function of `table`, by name; `rest` the rows after it.
  defp kept(table, rest, kind, xkind, size, cut, count, picks) do
    n = Table.size(table)
    indexes = Enum.filter(0..(n - 1)//1, &(rem(&1, picks) == 0))
    {:ok, appended} = Table.append(table, build(kind, xkind, rest, size, true))
    next = n + 1

    {inserted, [], 0} = Table.apply(table, %{insert: rows(xkind, rest, next)})

    {merged, [], 0} =
      Table.apply(table, %{insert: rows(xkind, rest, next), schema: schema(xkind)})

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
      compact_of_append: Table.compact(appended),
      apply_in_order: inserted,
      apply_merged: merged,
      apply_nothing: elem(Table.apply(table, %{}), 0)
    ] ++ unmarked_append(table, kind, xkind, rest, next)
  end

  # An in-order append of rows marked by nothing keeps the mark of a table of no origin
  # holding rows, its rows checked; an empty table takes the other's mark, here none.
  defp unmarked_append(table, :chunks, xkind, rest, next) do
    {:ok, appended} = Table.append(table, Table.new!(columns(xkind, rest, next)))
    if Table.size(table) > 0, do: [append_unmarked: appended], else: []
  end

  defp unmarked_append(_table, _kind, _xkind, _rest, _next), do: []

  # Every layout function given rows in any order, by name: its mark may go, never stay
  # untrue. A source's table refuses an out-of-order append (macaw_data#256).
  defp any(table, kind, xkind, size, any, retract) do
    next = Table.size(table) + 1
    rows = rows(xkind, any, next)
    {inserted, _faults, _} = Table.apply(table, %{insert: rows})
    {merged, _faults, _} = Table.apply(table, %{insert: rows, schema: schema(xkind)})
    {retracted, _faults, _} = Table.apply(table, %{retract: retract, insert: rows})

    appends =
      case kind do
        :chunks ->
          {:ok, marked} = Table.append(table, build(:chunks, xkind, any, size, ordered?(any)))
          {:ok, plain} = Table.append(table, Table.new!(columns(xkind, any, next)))
          [append_any: marked, append_any_unmarked: plain]

        {:source, _span} ->
          []
      end

    [apply_any: inserted, apply_any_merged: merged, apply_any_retracted: retracted] ++ appends
  end

  # What each reader that trusts the mark answers: the finished window's binary search,
  # `last`'s as-is order, the ladder's extent read at its ends (lttb, m4) and the `window`
  # step's newest reading and run of a time column.
  defp readers(table, xkind, from, to) do
    within =
      case Columns.within(table, "x", [at(xkind, from), at(xkind, to)]) do
        {:run, lower, n} -> Enum.to_list(lower..(lower + n - 1)//1)
        {:at, indexes} -> indexes
      end

    last = Last.window(table, 3, schema(xkind))

    steps =
      for node <-
            [%{op: "lttb", fields: ["x", "v"], n: 5}, %{op: "m4", fields: ["x", "v"], width: 2}] ++
              window_step(xkind) do
        Table.rows!(Operations.apply!(@registry, [node], table))
      end

    {within, Table.rows!(last), steps}
  end

  defp window_step(:time), do: [%{op: "window", field: "x", from: [20, :second]}]
  defp window_step(:number), do: []

  defp generated do
    gen all(
          xs <- xs(),
          kind <- member_of([{:source, 10}, {:source, nil}, :chunks]),
          xkind <- member_of([:number, :time]),
          split <- integer(0..60),
          size <- integer(1..9),
          cut <- integer(0..60),
          count <- integer(0..60),
          picks <- integer(1..4),
          any <- any_xs(),
          from <- integer(-60..60),
          span <- integer(0..60)
        ) do
      {head, rest} = Enum.split(xs, split)

      given = %{kind: kind, rest: rest, size: size, cut: cut, count: count, picks: picks}

      {xkind, build(kind, xkind, head, size, true),
       Map.merge(given, %{any: any, from: from, to: from + span})}
    end
  end

  @tag verifies: "table-sorted"
  property "every order-keeping layout function keeps the sorted mark, and the mark is true" do
    check all({xkind, table, g} <- generated(), max_runs: 200) do
      assert Table.sorted(table) == "x"

      for {name, result} <- kept(table, g.rest, g.kind, xkind, g.size, g.cut, g.count, g.picks) do
        assert {name, Table.sorted(result)} == {name, "x"}
        assert {name, ordered?(Table.column(result, "x"))} == {name, true}
      end
    end
  end

  @tag verifies: "table-sorted"
  property "rows in any order keep the mark only when it is still true, and every reader answers as on the rows unmarked" do
    check all({xkind, table, g} <- generated(), max_runs: 200) do
      retract = table |> Table.rows!() |> Enum.take(2)

      results =
        kept(table, g.rest, g.kind, xkind, g.size, g.cut, g.count, g.picks) ++
          any(table, g.kind, xkind, g.size, g.any, retract)

      for {name, result} <- results do
        if Table.sorted(result) == "x",
          do: assert({name, ordered?(Table.column(result, "x"))} == {name, true})

        assert {name, readers(result, xkind, g.from, g.to)} ==
                 {name, readers(unmarked(result), xkind, g.from, g.to)}
      end
    end
  end

  @tag verifies: "table-sorted"
  test "an append or apply of rows out of order drops the mark of a table not a source's (#261)" do
    t = Table.new!([{"x", :number, [1, 2, 3]}])
    [{c, _, _}] = Table.chunks(t)
    {:ok, s} = Table.from_chunks([{"x", :number}], [{c, 0, 2}, {c, 2, 1}], sorted: "x")

    {:ok, a} = Table.append(s, Table.new!([{"x", :number, [0]}]))
    assert {Table.sorted(a), Table.column(a, "x")} == {nil, [1, 2, 3, 0]}
    {t2, [], 0} = Table.apply(s, %{insert: [%{"x" => 0}]})
    assert {Table.sorted(t2), Table.column(t2, "x")} == {nil, [1, 2, 3, 0]}

    # In order, the mark stays: an append marked or not, rows inserted after the last,
    # rows merged under a schema ordering by it, and a retraction.
    {:ok, a} = Table.append(s, Table.new!([{"x", :number, [3, 4, nil]}]))
    assert {Table.sorted(a), Table.column(a, "x")} == {"x", [1, 2, 3, 3, 4, nil]}
    {t3, [], 0} = Table.apply(s, %{insert: [%{"x" => 5}, %{"x" => nil}]})
    assert {Table.sorted(t3), Table.column(t3, "x")} == {"x", [1, 2, 3, 5, nil]}

    merge = %{
      insert: [%{"x" => 0}],
      schema: Schema.new!(%{"x" => %{type: :number, window: true}})
    }

    {t4, [], 0} = Table.apply(s, merge)
    assert {Table.sorted(t4), Table.column(t4, "x")} == {"x", [0, 1, 2, 3]}

    # Under another window field the rows are placed by it, so the mark goes.
    {:ok, two} =
      [{"x", :number, [1, 2]}, {"t", :number, [1, 2]}]
      |> Table.new!()
      |> then(&Table.from_chunks([{"x", :number}, {"t", :number}], Table.chunks(&1), sorted: "x"))

    other = Schema.new!(%{"x" => %{type: :number}, "t" => %{type: :number, window: true}})
    {t5, [], 0} = Table.apply(two, %{insert: [%{"x" => 3, "t" => 0}], schema: other})
    assert {Table.sorted(t5), Table.column(t5, "x")} == {nil, [3, 1, 2]}
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
