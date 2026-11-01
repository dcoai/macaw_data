defmodule Macaw.Data.Derived.WindowColumnsTest do
  # `last: n` over a table works on its columns (spec/02 §2.2, macaw_data#47), and answers
  # what the row window answers over the table's rows: the same rows, in the same order,
  # as a table of the input's columns. Both order by the window field's key
  # (`Source.Order`), so a time sorts by its instant whatever its kind.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Derived, Schema, Table}
  alias Macaw.Data.Source.Order
  alias Macaw.Data.Test.Gen

  @paris {"Europe/Paris", "CET", 3600, 0}

  # -- generated inputs ---------------------------------------------------------------------

  # A time of a kind, its second drawn from a small range so ties and repeats occur.
  defp time(:utc, s, us), do: DateTime.from_unix!(s * 1_000_000 + us, :microsecond)

  defp time(:zoned, s, us) do
    {zone, abbr, offset, std} = @paris
    utc = time(:utc, s, us)
    local = NaiveDateTime.add(DateTime.to_naive(utc), offset + std, :second)

    %DateTime{
      year: local.year,
      month: local.month,
      day: local.day,
      hour: local.hour,
      minute: local.minute,
      second: local.second,
      microsecond: utc.microsecond,
      time_zone: zone,
      zone_abbr: abbr,
      utc_offset: offset,
      std_offset: std
    }
  end

  defp time(:naive, s, us), do: DateTime.to_naive(time(:utc, s, us))
  defp time(:date, s, _us), do: Date.add(~D[1970-01-01], s)

  defp kind_of(:mixed), do: member_of([:utc, :zoned, :naive, :date])
  defp kind_of(kind), do: constant(kind)

  # A window value of the column's kind: a time, or a number (an integer or a float).
  defp window_value(:number),
    do: one_of([integer(-5..5), Gen.float(min: -5.0, max: 5.0)])

  defp window_value(kind) do
    gen all(k <- kind_of(kind), s <- integer(0..8), us <- member_of([0, 1, 2, 999_999])) do
      time(k, s, us)
    end
  end

  defp maybe(gen, missing), do: frequency([{missing, constant(nil)}, {10, gen}])

  defp row(kind, missing) do
    fixed_map(%{
      t: maybe(window_value(kind), missing),
      host: maybe(member_of(["a", "b", "c"]), missing),
      iface: maybe(member_of(["eth0", "eth1"]), missing),
      cpu: Gen.float(min: 0.0, max: 100.0)
    })
  end

  defp schema(kind, identity) do
    t = if kind == :number, do: %{type: :number, window: true}, else: %{type: :time}

    Schema.new!(%{
      t: t,
      host: %{type: :category, identity: identity in [:one, :two]},
      iface: %{type: :category, identity: identity == :two},
      cpu: %{type: :number}
    })
  end

  @header [t: :time, host: :category, iface: :category, cpu: :number]

  defp header(:number), do: Keyword.put(@header, :t, :number)
  defp header(_kind), do: @header

  defp packed(header, rows) do
    {:ok, table} =
      Table.new(for {name, type} <- header, do: {name, type, Enum.map(rows, &Map.get(&1, name))})

    table
  end

  # Rows in their keys' order, `nil` last: what a source's table in event time holds.
  defp by_key(rows, kind) do
    key = if kind == :number, do: Order.key(:number), else: &Order.instant/1
    Order.sort_by(rows, [{:asc, key, & &1.t}])
  end

  # The rows as a table of several chunks, each a table's packed by itself, read through
  # views that may start and end inside a chunk; `sorted:` when they are in key order.
  defp chunked(header, groups, skip, sorted) do
    chunks = Enum.flat_map(groups, &Table.chunks(packed(header, &1)))
    {:ok, table} = Table.from_chunks(header, chunks, sorted: sorted)
    size = Table.size(table)
    Table.slice(table, min(skip, size), size)
  end

  defp input do
    gen all(
          kind <- member_of([:utc, :zoned, :naive, :date, :mixed, :number]),
          identity <- member_of([:none, :one, :two]),
          missing <- member_of([0, 1]),
          rows <- list_of(row(kind, missing), max_length: 40),
          in_order <- boolean(),
          cuts <- list_of(integer(0..40), max_length: 3),
          skip <- integer(0..3),
          n <- integer(1..6)
        ) do
      rows = if in_order, do: by_key(rows, kind), else: rows
      groups = split(rows, Enum.sort(cuts))
      sorted = if in_order, do: :t
      {kind, identity, rows, groups, skip, sorted, n}
    end
  end

  defp split(rows, cuts) do
    {groups, rest, _at} =
      Enum.reduce(cuts, {[], rows, 0}, fn cut, {groups, rest, at} ->
        {group, rest} = Enum.split(rest, max(cut - at, 0))
        {[group | groups], rest, max(cut, at)}
      end)

    Enum.reverse([rest | groups])
  end

  # -- the property ---------------------------------------------------------------------------

  @tag verifies: "derived-input-columns"
  property "last n over a table is Table.equal? to the row window over its rows" do
    check all({kind, identity, _rows, groups, skip, sorted, n} <- input(), max_runs: 300) do
      header = header(kind)
      schema = schema(kind, identity)
      table = chunked(header, groups, skip, sorted)

      columns = Derived.window(table, %{last: n}, schema)
      rows = Derived.window(Table.rows(table), %{last: n}, schema)

      assert Table.equal?(columns, packed(header, rows)),
             "#{inspect(kind)} #{inspect(identity)} last #{n}: " <>
               "#{inspect(Table.rows(columns))} != #{inspect(rows)}"
    end
  end

  # -- the order, fixed in both windows ---------------------------------------------------

  # `Window.position/1` keyed a `DateTime` in Unix microseconds, a `NaiveDateTime` in
  # Gregorian seconds as a float and a `Date` in Gregorian days, so kinds mixed sorted by
  # scale, and a naive time lost its microseconds (a double near 6.4e10 resolves ~8 µs).
  @tag verifies: "derived-input-columns"
  test "a time orders by its instant, whatever its kind, to the microsecond" do
    schema = Schema.new!(%{t: %{type: :time}, v: %{type: :number}})

    mixed = [
      %{t: ~U[2026-01-01 00:00:00Z], v: 1},
      %{t: ~D[2027-01-01], v: 2},
      %{t: ~N[2025-01-01 00:00:00], v: 3}
    ]

    assert Enum.map(Derived.window(mixed, %{last: 2}, schema), & &1.v) == [1, 2]

    assert Table.column(
             Derived.window(packed([t: :time, v: :number], mixed), %{last: 2}, schema),
             :v
           ) == [1, 2]

    naive = [
      %{t: ~N[2026-01-01 00:00:00.000002], v: 2},
      %{t: ~N[2026-01-01 00:00:00.000001], v: 1}
    ]

    assert Enum.map(Derived.window(naive, %{last: 1}, schema), & &1.v) == [2]

    assert Table.column(
             Derived.window(packed([t: :time, v: :number], naive), %{last: 1}, schema),
             :v
           ) == [2]
  end

  @tag verifies: "derived-input-columns"
  test "a table sorted by its window field and no identity is a slice of it, its chunks kept" do
    schema = Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number}})
    rows = for t <- 1..20_000, do: %{t: t, v: t * 2}

    header = [t: :number, v: :number]
    chunks = Table.chunks(packed(header, rows))
    {:ok, table} = Table.from_chunks(header, chunks, sorted: :t)

    last = Derived.window(table, %{last: 10_000}, schema)

    assert Table.column(last, :t) == Enum.to_list(10_001..20_000)

    assert Enum.map(Table.chunks(last), &elem(&1, 0)) --
             Enum.map(Table.chunks(table), &elem(&1, 0)) == []
  end
end
