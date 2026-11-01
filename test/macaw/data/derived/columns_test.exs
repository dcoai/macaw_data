defmodule Macaw.Data.Derived.ColumnsTest do
  # A derived function's input read as columns (spec/02 §2.2, macaw_data#107): every
  # accessor answers what the row view answers over the same table, whatever its column
  # forms, its gaps, its chunks and its views; and the kernels' path what the Elixir path
  # answers.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Native, Table}
  alias Macaw.Data.Derived.Columns
  alias Macaw.Data.Operations.Aggregates
  alias Macaw.Data.Source.Order
  alias Macaw.Data.Test.Gen

  doctest Columns

  @paris {"Europe/Paris", "CET", 3600, 0}

  # -- generated inputs ---------------------------------------------------------------------

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

  defp a_time(kind) do
    gen all(k <- kind_of(kind), s <- integer(-3..8), us <- member_of([0, 1, 2, 999_999])) do
      time(k, s, us)
    end
  end

  # A number of a kind: the kinds pack into int64, float64, integral, a union and a list.
  defp a_number(:int), do: integer(-5..5)
  defp a_number(:float), do: Gen.float(min: -5.0, max: 5.0)
  defp a_number(:mixed), do: one_of([integer(-5..5), Gen.float(min: -5.0, max: 5.0)])

  defp a_number(:wide),
    do: one_of([integer(-5..5), Gen.float(min: -5.0, max: 5.0), constant(9_007_199_254_740_993)])

  defp a_number(:huge), do: one_of([integer(-5..5), constant(36_893_488_147_419_103_232)])

  defp maybe(gen, missing), do: frequency([{missing, constant(nil)}, {10, gen}])

  defp row(times, numbers, missing) do
    fixed_map(%{
      "t" => maybe(a_time(times), missing),
      "v" => maybe(a_number(numbers), missing),
      "s" => maybe(member_of(["x", "yy", ""]), missing),
      "c" => maybe(member_of(["a", "b", :c]), missing)
    })
  end

  @header [{"t", :time}, {"v", :number}, {"s", :text}, {"c", :category}]

  defp packed(rows) do
    {:ok, table} =
      Table.new(for {name, type} <- @header, do: {name, type, Enum.map(rows, &Map.get(&1, name))})

    table
  end

  # The rows as a table of several chunks, each packed by itself, read through a view
  # that may start inside the first.
  defp chunked(groups, skip) do
    chunks = Enum.flat_map(groups, &Table.chunks(packed(&1)))
    {:ok, table} = Table.from_chunks(@header, chunks)
    size = Table.size(table)
    Table.slice(table, min(skip, size), size)
  end

  defp split(rows, cuts) do
    {groups, rest, _at} =
      Enum.reduce(cuts, {[], rows, 0}, fn cut, {groups, rest, at} ->
        {group, rest} = Enum.split(rest, max(cut - at, 0))
        {[group | groups], rest, max(cut, at)}
      end)

    Enum.reverse([rest | groups])
  end

  defp input do
    gen all(
          times <- member_of([:utc, :zoned, :naive, :date, :mixed]),
          numbers <- member_of([:int, :float, :mixed, :wide, :huge]),
          missing <- member_of([0, 1, 4]),
          rows <- list_of(row(times, numbers, missing), max_length: 40),
          cuts <- list_of(integer(0..40), max_length: 3),
          skip <- integer(0..3)
        ) do
      chunked(split(rows, Enum.sort(cuts)), skip)
    end
  end

  # -- the row view's answers ----------------------------------------------------------------

  defp present(table, name),
    do: table |> Table.rows() |> Enum.map(& &1[name]) |> Enum.reject(&is_nil/1)

  # The first least or greatest by key, as the row view finds it.
  defp first_by(values, key, side) do
    Enum.reduce(values, nil, fn value, best ->
      cond do
        best == nil -> value
        side == :lt and key.(value) < key.(best) -> value
        side == :gt and key.(value) > key.(best) -> value
        true -> best
      end
    end)
  end

  defp accessors(table) do
    %{
      names: Columns.names(table),
      size: Columns.size(table),
      types: for(name <- ["t", "v", "s", "c"], do: Columns.type(table, name)),
      columns: for(name <- ["t", "v", "s", "c"], do: Columns.column(table, name)),
      valid: for(name <- ["t", "v", "s", "c"], do: Columns.valid(table, name)),
      counts: for(name <- ["t", "v", "s", "c"], do: Columns.count(table, name)),
      numbers: Columns.numbers(table, "v"),
      instants: Columns.instants(table, "t"),
      sum: Columns.sum(table, "v"),
      mean: Columns.mean(table, "v"),
      extremes:
        {Columns.min(table, "v"), Columns.max(table, "v"), Columns.min(table, "t"),
         Columns.max(table, "t")}
    }
  end

  # -- the properties --------------------------------------------------------------------------

  @tag verifies: "derived-columns-accessors"
  property "every accessor agrees with the row view, over every column form, gaps, chunks and views" do
    check all(table <- input(), max_runs: 300) do
      rows = Table.rows(table)
      names = ["t", "v", "s", "c"]
      got = accessors(table)

      assert got.names == names
      assert got.size == length(rows)
      assert got.types == [:time, :number, :text, :category]
      assert got.columns == for(name <- names, do: Enum.map(rows, & &1[name]))
      assert got.valid == for(name <- names, do: Enum.map(rows, &(&1[name] != nil)))
      assert got.counts == for(name <- names, do: Enum.count(rows, &(&1[name] != nil)))
      assert got.numbers === Enum.map(rows, & &1["v"])
      assert got.instants === Enum.map(rows, &Order.instant(&1["t"]))

      numbers = present(table, "v")
      times = present(table, "t")
      assert got.sum === Aggregates.Sum.reduce(numbers, %{})
      assert got.mean === Aggregates.Mean.reduce(numbers, %{})

      assert got.extremes ===
               {first_by(numbers, & &1, :lt), first_by(numbers, & &1, :gt),
                first_by(times, &Order.instant/1, :lt), first_by(times, &Order.instant/1, :gt)}

      # Either spelling names a column, and a part of the input is the rows it holds.
      assert Columns.column(table, :v) == got.columns |> Enum.at(1)
      n = div(length(rows), 2)
      assert Columns.rows(Columns.take(table, n)) == Enum.take(rows, n)
      assert Columns.rows(Columns.take(table, -n)) == Enum.take(rows, -n)
      assert Columns.rows(Columns.slice(table, 1, n)) == Enum.slice(rows, 1, n)
    end
  end

  @tag verifies: "derived-columns-native"
  property "the kernels' path answers what the Elixir path answers" do
    check all(table <- input(), max_runs: 300) do
      assert accessors(table) === Native.elixir(fn -> accessors(table) end)
    end
  end

  @tag verifies: "derived-columns-native"
  test "a whole canonical chunk and a long input read through the kernels as through Elixir" do
    n = 20_000
    floats = for i <- 1..n, do: :math.sin(i / 7) * 1.0e3
    ints = for i <- 1..n, do: if(rem(i, 5) == 0, do: nil, else: rem(i * 7919, 1013) - 500)

    us =
      for i <- 1..n,
          do:
            DateTime.from_unix!(1_700_000_000_000_000 + rem(i * 104_729, n) * 1_000, :microsecond)

    table = Table.new!([{"f", :number, floats}, {"i", :number, ints}, {"t", :time, us}])

    for name <- ["f", "i"], fun <- [:sum, :mean, :min, :max, :count] do
      assert apply(Columns, fun, [table, name]) ===
               Native.elixir(fn -> apply(Columns, fun, [table, name]) end)
    end

    assert Columns.sum(table, "i") === Enum.sum(Enum.reject(ints, &is_nil/1))
    assert Columns.min(table, "t") == Enum.min_by(us, &DateTime.to_unix(&1, :microsecond))
    assert Columns.max(table, "t") == Native.elixir(fn -> Columns.max(table, "t") end)
  end

  @tag verifies: "derived-columns-accessors"
  test "a name the input lacks and a typed read of another type raise ArgumentError" do
    table = Table.new!([{"s", :text, ["a"]}, {"v", :number, [nil]}])
    assert_raise ArgumentError, ~r/no column "w"/, fn -> Columns.column(table, "w") end
    assert_raise ArgumentError, ~r/:text, not :number/, fn -> Columns.sum(table, :s) end
    assert_raise ArgumentError, ~r/not :time/, fn -> Columns.instants(table, "v") end
    assert Columns.sum(table, "v") === 0
    assert Columns.mean(table, "v") == nil
    assert Columns.min(table, "v") == nil
  end
end
