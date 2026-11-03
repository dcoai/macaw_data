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
  defp table(kind, rows, cuts, sorted),
    do:
      table_of(
        [{:t, type(kind)}, {:id, :category}, {:h, :category}, {:v, :number}],
        rows,
        cuts,
        sorted && :t
      )

  defp table_of(columns, rows, cuts, sorted) do
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
      do: Table.from_chunks(columns, Table.chunks(joined), sorted: sorted) |> elem(1),
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

  defp rows_of(kind, steps, ids, vs \\ nil) do
    vs = vs || Enum.to_list(0..(length(steps) - 1)//1)

    for {{k, {id, h}}, v} <- Enum.zip(Enum.zip(steps, ids), vs),
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

      # An inverted window is the caller's fault (macaw_data#122): ask the ends in order.
      {from, to} = if from && to && from > to, do: {to, from}, else: {from, to}
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
  property "finishing a table by region, order and budget keeps the rows its rows keep" do
    check all(
            kind <- kinds(),
            steps <- list_of(one_of([constant(nil), integer(-12..12)]), max_length: 60),
            ids <-
              list_of(
                tuple({member_of([nil, "a", "b", "c"]), member_of([nil, "x", "y"])}),
                length: length(steps)
              ),
            vs <-
              list_of(one_of([constant(nil), integer(-4..4), member_of([0.5, 2.5, -1.5])]),
                length: length(steps)
              ),
            cuts <- list_of(integer(0..20), max_length: 4),
            sorted <- boolean(),
            from <- edge(steps),
            to <- edge(steps),
            low <- one_of([constant(nil), integer(-4..4)]),
            order <-
              list_of(tuple({member_of(["t", :v, "id", :h]), member_of([:asc, :desc])}),
                max_length: 2
              ),
            budget <- one_of([constant(nil), integer(1..12)]),
            reduce <- member_of(["lttb", "m4"]),
            region? <- boolean(),
            cut <- member_of([:none, :source, :capped]),
            one_series? <- boolean()
          ) do
      steps = if sorted, do: Enum.sort_by(steps, &key/1), else: steps
      # One series often, so the reducer has rows to choose between.
      ids = if one_series?, do: Enum.map(ids, fn _ -> {"a", "x"} end), else: ids
      rows = rows_of(kind, steps, ids, vs)
      table = table(kind, rows, cuts, sorted)
      schema = schema(kind, :one)
      order = Enum.uniq_by(order, &to_string(elem(&1, 0)))
      # A region's range is refused inverted (spec/01 §2.3), so its ends come in order.
      [from, to] = if from && to && from > to, do: [to, from], else: [from, to]

      fields =
        [order: order, budget: budget] ++
          if(region?,
            do: [
              region: %{
                "t" => [from && bound(kind, from), to && bound(kind, to)],
                "v" => [low, nil]
              }
            ],
            else: []
          )

      served =
        case cut do
          :none -> []
          :source -> [reduced_by: :source]
          :capped -> [capped: true]
        end

      request = Request.new!([now: @now] ++ fields)
      description = Description.new!(schema: schema)

      columnar =
        Finish.finish!(Delivery.new!(table, served: served), description, request, reduce: reduce)

      by_rows =
        Finish.finish!(Delivery.new!(Table.rows(table), served: served), description, request,
          reduce: reduce
        )

      assert %Table{} = columnar.rows
      assert Table.equal?(columnar.rows, packed(table, by_rows.rows))
      assert columnar.served == by_rows.served
    end
  end

  @tag verifies: "finish-columns"
  property "finishing a table by box keeps the positions its rows keep" do
    schema = Schema.new!(%{"p" => %{type: :point, window: true}, "v" => %{type: :number}})
    position = one_of([constant(nil), tuple({integer(-180..180), integer(-90..90)})])

    check all(
            positions <- list_of(position, max_length: 60),
            cuts <- list_of(integer(0..20), max_length: 4),
            west <- integer(-180..180),
            east <- integer(-180..180),
            south <- integer(-90..0),
            north <- integer(0..90)
          ) do
      rows = for {p, v} <- Enum.with_index(positions), do: %{p: p, v: v}
      table = table_of([{:p, :point}, {:v, :number}], rows, cuts, nil)
      box = %{west: west, south: south, east: east, north: north}

      columnar = finished(table, schema, box: box)
      by_rows = finished(Table.rows(table), schema, box: box)

      assert Table.equal?(columnar.rows, packed(table, by_rows.rows))
      assert columnar.served == by_rows.served
    end
  end

  @tag verifies: "finish-columns"
  test "no step reads a table's rows: every step of a table finishes on its columns" do
    alias Macaw.Data.Test.Trace

    schema = schema(:utc, :one)
    steps = for i <- 0..39, do: rem(i * 7, 30)
    ids = for i <- 0..39, do: {Enum.at(["a", "b", "c"], rem(i, 3)), "x"}
    table = table(:utc, rows_of(:utc, steps, ids), [10, 15], false)

    asks = [
      [window: [bound(:utc, 3), bound(:utc, 25)], region: %{"v" => [2, 35]}, latest: true],
      [window: [bound(:utc, 3), nil], order: [{"v", :desc}, {"t", :asc}], budget: 5],
      [budget: 6],
      [order: [{"t", :desc}]]
    ]

    points = Schema.new!(%{"p" => %{type: :point, window: true}, "v" => %{type: :number}})

    located =
      Table.new!([
        {:p, :point, for(i <- 0..9, do: {i * 10, 0})},
        {:v, :number, Enum.to_list(0..9)}
      ])

    box = %{west: 15, south: -1, east: 55, north: 1}

    for read <- [{Delivery, :named_rows, 1}, {Table, :rows, 1}] do
      for fields <- asks do
        assert Trace.calls(read, fn -> finished(table, schema, fields) end) == []
      end

      assert Trace.calls(read, fn -> finished(located, points, box: box) end) == []
    end

    assert Table.column(finished(located, points, box: box).rows, :v) == [2, 3, 4, 5]
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

  # A value of each sortable type, `nil` often, few distinct so ties are common: every
  # kind of time in one generator, so a column mixes them (and keeps the list form).
  defp sort_value(:number),
    do: one_of([constant(nil), integer(-3..3), member_of([0.5, 2.0, -1.5, 1.0])])

  defp sort_value(:text), do: one_of([constant(nil), member_of(["a", "b", "B", "ab", ""])])

  defp sort_value(:category),
    do: one_of([constant(nil), member_of(["ok", "warn", "bad", "new"])])

  defp sort_value(:time) do
    one_of([
      constant(nil)
      | for(kind <- [:utc, :micro, :zoned, :naive, :date], do: map(integer(-3..3), &at(kind, &1)))
    ])
  end

  # Values of one kind of time only, so the column packs to its buffer; of mixed kinds,
  # so it keeps the list form; any other type's values.
  defp sort_values(:time, n, true) do
    bind(member_of([:utc, :micro, :zoned, :naive, :date]), fn kind ->
      list_of(one_of([constant(nil), map(integer(-3..3), &at(kind, &1))]), length: n)
    end)
  end

  defp sort_values(type, n, _one_kind?), do: list_of(sort_value(type), length: n)

  @tag verifies: "finish-columns"
  property "a one-field order sorts its column's keys as Order.sort/3 sorts the rows" do
    alias Macaw.Data.Source.{Finish.Columns, Order}

    check all(
            type <- member_of([:number, :text, :category, :time]),
            declared? <- boolean(),
            n <- integer(0..60),
            one_kind? <- boolean(),
            values <- sort_values(type, n, one_kind?),
            cuts <- list_of(integer(0..20), max_length: 4),
            direction <- member_of([:asc, :desc]),
            field <- member_of(["f", :f, "missing"])
          ) do
      described =
        if type == :category and declared?,
          do: %{type: :category, order: ["bad", "warn", "ok"]},
          else: %{type: type}

      schema =
        Schema.new!(%{"f" => described, "missing" => %{type: :number}, "i" => %{type: :number}})

      rows = for {v, i} <- Enum.with_index(values), do: %{f: v, i: i}
      table = table_of([{:f, type}, {:i, :number}], rows, cuts, nil)
      order = [{field, direction}]

      {:ok, sorted} = Order.sort(Table.rows(table), order, schema)
      assert Columns.ordered(table, order, schema) == {:ok, Enum.map(sorted, &Table.get(&1, :i))}
    end
  end
end
