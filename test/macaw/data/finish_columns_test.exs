defmodule Macaw.Data.FinishColumnsTest do
  @moduledoc """
  Finishing a table on its columns (spec/01 §2.4, macaw_data#105): every step keeps the
  rows its row twin keeps, and makes no row.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Derived, Schema, Table}
  alias Macaw.Data.Source.{Description, Finish, Request}

  @now ~U[2026-10-27 12:00:00Z]
  @base ~U[2026-01-01 00:00:00Z]

  # A `DateTime` in another zone, built by its fields: no time-zone database is involved.
  defp zoned(%DateTime{} = utc, {time_zone, zone_abbr, utc_offset, std_offset}) do
    wall = DateTime.add(utc, utc_offset + std_offset, :second)

    %{
      wall
      | time_zone: time_zone,
        zone_abbr: zone_abbr,
        utc_offset: utc_offset,
        std_offset: std_offset
    }
  end

  @zones [{"Europe/Paris", "CET", 3600, 0}, {"America/Denver", "MDT", -25_200, 3600}]

  # The window field's value at step `k` for each kind of window field, so the kinds share
  # one generator: a value of the kind, `nil` for a missing one.
  defp at(_kind, nil), do: nil
  defp at(:int, k), do: k
  defp at(:float, k), do: k * 0.5
  defp at(:utc, k), do: DateTime.add(@base, k, :second)
  defp at(:micro, k), do: DateTime.add(@base, k, :microsecond)
  defp at(:zoned, k), do: zoned(DateTime.add(@base, k, :second), Enum.at(@zones, rem(abs(k), 2)))
  defp at(:naive, k), do: NaiveDateTime.add(~N[2026-01-01 00:00:00], k, :second)
  defp at(:date, k), do: Date.add(~D[2026-01-01], k)

  # A bound of the kind: a zoned field's in UTC, the same instant.
  defp bound(:zoned, k), do: at(:utc, k)
  defp bound(kind, k), do: at(kind, k)

  defp type(kind) when kind in [:int, :float], do: :number
  defp type(_kind), do: :time

  defp schema(kind, identity) do
    ids =
      case identity do
        :one ->
          %{"id" => %{type: :category, identity: true}, "h" => %{type: :category}}

        :two ->
          %{"id" => %{type: :category, identity: true}, "h" => %{type: :category, identity: true}}
      end

    Schema.new!(
      Map.merge(ids, %{"t" => %{type: type(kind), window: true}, "v" => %{type: :number}})
    )
  end

  # The rows as a table of several chunks, cut where `cuts` says, the first and last view
  # partial when `trim` asks, and said to be sorted by its window field when `sorted`.
  defp table(kind, rows, cuts, sorted) do
    columns = [{:t, type(kind)}, {:id, :category}, {:h, :category}, {:v, :number}]

    pieces =
      rows
      |> split(cuts)
      |> Enum.map(fn piece ->
        Table.new!(for {name, type} <- columns, do: {name, type, Enum.map(piece, & &1[name])})
      end)

    [first | rest] = pieces

    joined =
      Enum.reduce(rest, first, fn piece, acc ->
        {:ok, joined} = Table.append(acc, piece)
        joined
      end)

    if sorted,
      do: Table.from_chunks(columns, Table.chunks(joined), sorted: :t) |> elem(1),
      else: joined
  end

  defp split(rows, cuts) do
    {pieces, rest} =
      Enum.reduce(cuts, {[], rows}, fn cut, {pieces, rest} ->
        {piece, rest} = Enum.split(rest, cut)
        {[piece | pieces], rest}
      end)

    Enum.reverse([rest | pieces])
  end

  defp rows_of(kind, steps, ids) do
    for {{k, {id, h}}, v} <- Enum.with_index(Enum.zip(steps, ids)),
        do: %{t: at(kind, k), id: id, h: h, v: v}
  end

  # The row twin: the table's rows finished as rows, packed under its columns.
  defp packed(table, rows) do
    Table.new!(
      for name <- Table.names(table),
          do: {name, Table.column_type(table, name), Enum.map(rows, &Table.get(&1, name))}
    )
  end

  defp finished(subject, schema, fields) do
    request = Request.new!([now: @now] ++ fields)
    Finish.finish!(Delivery.new!(subject), Description.new!(schema: schema), request)
  end

  defp kinds, do: member_of([:int, :float, :utc, :micro, :zoned, :naive, :date])

  # A window's bound: open, any step, or one a row holds, so a bound often meets a row.
  defp edge(steps) do
    case Enum.reject(steps, &is_nil/1) do
      [] -> one_of([constant(nil), integer(-14..14)])
      held -> one_of([constant(nil), integer(-14..14), member_of(held)])
    end
  end

  defp key(nil), do: 1_000_000
  defp key(k), do: k

  @tag verifies: "finish-columns"
  property "finishing a table by window and latest keeps the rows its rows keep" do
    check all(
            kind <- kinds(),
            identity <- member_of([:one, :two]),
            steps <- list_of(one_of([constant(nil), integer(-12..12)]), max_length: 60),
            ids <-
              list_of(
                tuple({member_of([nil, "a", "b", "c"]), member_of([nil, "x", "y"])}),
                length: length(steps)
              ),
            cuts <- list_of(integer(0..20), max_length: 4),
            sorted <- boolean(),
            from <- edge(steps),
            to <- edge(steps),
            ask <- member_of([:window, :latest, :both])
          ) do
      steps = if sorted, do: Enum.sort_by(steps, &key/1), else: steps
      rows = rows_of(kind, steps, ids)
      table = table(kind, rows, cuts, sorted)
      schema = schema(kind, identity)

      window = [from && bound(kind, from), to && bound(kind, to)]

      fields =
        case ask do
          :window -> [window: window]
          :latest -> [latest: true]
          :both -> [window: window, latest: true]
        end

      columnar = finished(table, schema, fields)
      by_rows = finished(Table.rows(table), schema, fields)

      assert %Table{} = columnar.rows
      assert Table.equal?(columnar.rows, packed(table, by_rows.rows))
      assert columnar.served == by_rows.served

      if ask != :latest do
        assert Table.equal?(
                 Derived.window(table, %{window: window}, schema),
                 packed(table, Derived.window(Table.rows(table), %{window: window}, schema))
               )
      end
    end
  end

  @tag verifies: "finish-columns"
  test "a window over a table sorted by its window field is one run of its chunks" do
    schema = schema(:int, :one)
    rows = rows_of(:int, [1, 2, 3, 4, 5, nil], List.duplicate({"a", "x"}, 6))
    table = table(:int, rows, [2, 2], true)

    finished = finished(table, schema, window: [2, 4])
    assert Table.column(finished.rows, :t) == [2, 3, 4]
    assert Table.sorted(finished.rows) == :t

    assert Table.column(finished(table, schema, window: [nil, 2]).rows, :t) == [1, 2]
    assert Table.column(finished(table, schema, window: [4, nil]).rows, :t) == [4, 5]
    assert Table.column(finished(table, schema, window: [9, nil]).rows, :t) == []
  end

  @tag verifies: "finish-columns"
  test "a table with no window field column keeps no row in a window and none for latest" do
    schema = schema(:int, :one)
    table = Table.new!([{:id, :category, ["a", "b"]}, {:v, :number, [1, 2]}])

    assert Table.size(finished(table, schema, window: [0, 9]).rows) == 0
    assert Table.size(finished(table, schema, latest: true).rows) == 0
  end
end
