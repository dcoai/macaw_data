defmodule Macaw.Data.WindowKindsTest do
  @moduledoc """
  A window compares times on one scale whatever their kinds (spec/01 §2.4,
  macaw_data#124): a request window whose bound is another kind of time than the rows
  trims them by instant, as sort and `filter` compare, and no window `Window.check/2`
  passes makes finishing raise.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Derived, Schema, Table, Window}
  alias Macaw.Data.Source.{Description, Finish, Order, Request}

  @now ~U[2026-10-01 00:00:00Z]
  @schema Schema.new!(%{t: %{type: :time, window: true}, v: %{type: :number}})
  @kinds [:utc, :zoned, :naive, :date]

  # The instant `s` seconds after 2026-01-01 as a time of the kind: a date at its day.
  defp at(:utc, s), do: DateTime.add(~U[2026-01-01 00:00:00Z], s, :second)

  defp at(:zoned, s) do
    wall = DateTime.add(at(:utc, s), 3600, :second)
    %{wall | time_zone: "Europe/Paris", zone_abbr: "CET", utc_offset: 3600, std_offset: 0}
  end

  defp at(:naive, s), do: DateTime.to_naive(at(:utc, s))
  defp at(:date, s), do: DateTime.to_date(at(:utc, s))

  defp request(fields), do: Request.new!([now: @now] ++ fields)
  defp finish(subject, fields), do: finish(subject, @schema, fields)

  defp finish(subject, schema, fields),
    do: Finish.finish(Delivery.new!(subject), %Description{schema: schema}, request(fields))

  @tag verifies: "window-instant-scale"
  test "a window bound of another kind of time than the rows answers a value (the #124 snippet)" do
    rows = [%{t: ~U[2026-01-01 00:00:00Z], v: 1}, %{t: ~U[2026-01-02 00:00:00Z], v: 2}]

    assert {:ok, %Delivery{rows: [%{v: 2}]}} =
             finish(rows, window: [~N[2026-01-01 12:00:00], nil])

    assert {:ok, %Delivery{rows: [%{v: 1}, %{v: 2}]}} =
             finish(rows, window: [~D[2026-01-01], ~D[2026-01-02]])
  end

  @tag verifies: "window-instant-scale"
  test "every mixed pair of kinds compares by instant, both directions" do
    for a <- @kinds, b <- @kinds do
      assert Window.compare(at(a, 0), at(b, 0)) == :eq, "#{a} = #{b}"
      assert Window.comparable?(at(a, 0), at(b, 0))

      unless a == :date or b == :date do
        assert Window.compare(at(a, 0), at(b, 1)) == :lt, "#{a} < #{b}"
        assert Window.compare(at(a, 1), at(b, 0)) == :gt, "#{a} > #{b}"
      end

      assert Window.compare(at(a, 0), at(b, 86_400)) == :lt
      assert Window.within?(at(a, 3600), [at(b, 0), at(b, 86_400)])
      refute Window.within?(at(a, 180_000), [at(b, 0), at(b, 86_400)])
      assert Window.intersect([at(a, 0), nil], [at(b, 86_400), nil]) == [at(b, 86_400), nil]

      rows = [%{t: at(a, 0), v: 0}, %{t: at(a, 172_800), v: 1}]
      assert {:ok, %Delivery{rows: [%{v: 1}]}} = finish(rows, window: [at(b, 86_400), nil])
    end
  end

  @tag verifies: "window-instant-scale"
  test "a value with no reading on the bound's scale lies in no window, and nothing raises" do
    refute Window.comparable?(5, ~U[2026-01-01 00:00:00Z])
    refute Window.comparable?(nil, 5)
    refute Window.within?(5, [~U[2026-01-01 00:00:00Z], nil])
    refute Window.within?("2026", [nil, ~D[2026-01-01]])
    assert Window.within?("2026", [nil, nil])

    assert Window.newer([%{t: 5}, %{t: ~D[2026-01-02]}], :t, ~D[2026-01-01]) == [
             %{t: ~D[2026-01-02]}
           ]

    assert Window.before([%{t: "x"}, %{t: ~D[2026-01-01]}], :t, nil, ~D[2026-01-02]) == [
             %{t: ~D[2026-01-01]}
           ]

    assert Window.latest(5, ~D[2026-01-01]) == 5
    assert Window.earliest(~D[2026-01-01], 5) == ~D[2026-01-01]

    rows = [%{t: 5, v: 0}, %{t: ~N[2026-01-02 00:00:00], v: 1}, %{t: nil, v: 2}]

    assert {:ok, %Delivery{rows: [%{v: 1}]}} =
             finish(rows, window: [~U[2026-01-01 00:00:00Z], nil])
  end

  @tag verifies: "window-instant-scale"
  test "a region's ends of different kinds of time compare by instant; only an inverted one is refused" do
    assert Window.check(%{region: %{t: [~U[2026-01-01 00:00:00Z], ~D[2026-01-02]]}}, @schema) ==
             :ok

    assert Window.check(%{region: %{t: [~D[2026-01-02], ~N[2026-01-01 23:59:59]]}}, @schema) ==
             {:error, [{[:region, :t], {:window, :inverted}}]}
  end

  # -- the property: every kind in the rows and the bounds ----------------------------------

  defp time,
    do: gen(all(kind <- member_of(@kinds), s <- integer(-4..4), do: at(kind, s * 43_200)))

  defp bound, do: one_of([constant(nil), time()])

  # A row's window value: a time of any kind, nil, or a value with no instant.
  defp value, do: frequency([{8, time()}, {1, constant(nil)}, {1, member_of([7, "x"])}])

  defp input do
    gen all(
          one_kind <- one_of([constant(nil), member_of(@kinds)]),
          values <- list_of(value(), max_length: 30),
          from <- bound(),
          to <- bound(),
          cut <- integer(0..30),
          region? <- boolean()
        ) do
      # One kind of time in the rows packs the column; mixed kinds keep it a list.
      values =
        if one_kind,
          do: Enum.map(values, &if(Window.instant?(&1), do: retype(&1, one_kind), else: nil)),
          else: values

      rows = values |> Enum.with_index() |> Enum.map(fn {t, v} -> %{t: t, v: v} end)
      {rows, cut, [from, to], region?}
    end
  end

  defp retype(t, kind),
    do: at(kind, div(Order.instant(t) - Order.instant(at(:utc, 0)), 1_000_000))

  # The rows as a table of two chunks; a window column holding a value of no time is a
  # term column, which a `:time` column refuses.
  defp table(rows, cut) do
    {a, b} = Enum.split(rows, cut)
    type = if Enum.all?(rows, &(&1.t == nil or Window.instant?(&1.t))), do: :time, else: :term

    piece = fn rows ->
      Table.new!([{:t, type, Enum.map(rows, & &1.t)}, {:v, :number, Enum.map(rows, & &1.v)}])
    end

    {:ok, table} = Table.append(piece.(a), piece.(b))
    table
  end

  # The rows a window keeps by instant: the oracle, `Order.instant/1` compared directly. A
  # window with no bound keeps every row with a value, a closed bound only those with an
  # instant.
  defp kept(rows, [nil, nil]), do: Enum.reject(rows, &is_nil(&1.t))

  defp kept(rows, [from, to]) do
    Enum.filter(rows, fn %{t: t} ->
      i = Order.instant(t)

      i != nil and (from == nil or i >= Order.instant(from)) and
        (to == nil or i <= Order.instant(to))
    end)
  end

  @tag verifies: "window-instant-scale"
  property "finish/4, trim/3 and Derived.window/3 never raise and keep the rows by instant, table or rows" do
    check all({rows, cut, [from, to] = window, region?} <- input(), max_runs: 300) do
      expected = kept(rows, window)
      table = table(rows, cut)

      assert Window.trim(rows, :t, window) == expected

      # An inverted window or range is the caller's fault (macaw_data#122); its ends
      # swapped are the range asked.
      inverted = from && to && Window.compare(from, to) == :gt
      ordered = if inverted, do: [to, from], else: window

      if inverted do
        assert finish(rows, window: window) == {:error, [{[:window], {:window, :inverted}}]}
      end

      fields = if region?, do: [region: %{t: ordered}], else: [window: ordered]
      expected = kept(rows, ordered)

      assert {:ok, %Delivery{rows: by_rows}} = finish(rows, fields)
      assert by_rows == expected
      assert {:ok, %Delivery{rows: %Table{} = columnar}} = finish(table, fields)
      assert Enum.map(Table.rows(columnar), & &1.v) == Enum.map(expected, & &1.v)

      unless region? do
        assert Derived.window(rows, %{window: ordered}, @schema) == expected
        derived = Derived.window(table, %{window: ordered}, @schema)
        assert Enum.map(Table.rows(derived), & &1.v) == Enum.map(expected, & &1.v)
      end
    end
  end
end
