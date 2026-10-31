defmodule Macaw.Data.Operations.HotPathsTest do
  @moduledoc """
  The frame loop's per-row paths without per-row overhead (macaw_data#41): `filter`
  scanning a packed number column (spec/04 §4.1), a chunk's groups in one pass by
  dictionary codes (§4.10), and the exact sum by exponent (§5). Each is held to a reading
  value by value, row by row, or an exact oracle, and its cost pinned in reductions.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Macaw.Data.{Exact, Native, Operations, Table}
  alias Macaw.Data.Operations.Aggregates
  alias Macaw.Data.Operations.Transforms.{Aggregate, Filter}
  alias Macaw.Data.Test.{Gen, Work}

  @registry Operations.registry()
  @tests [:eq, :ne, :lt, :lte, :gt, :gte, :present, :absent]

  defp checked(node) do
    {:ok, [checked]} = Operations.validate(@registry, [node], %{})
    checked
  end

  # Every view of a slice of the table: views that start and end inside their chunks.
  defp views(table, from, count), do: Table.chunks(Table.slice(table, from, count))

  describe "filter scans a packed number column (spec/04 §4.1; #41)" do
    defp passes?(:present, r, _v), do: r != nil
    defp passes?(:absent, r, _v), do: r == nil
    defp passes?(:eq, r, v), do: Operations.same?(r, v)
    defp passes?(:ne, r, v), do: not Operations.same?(r, v)
    defp passes?(_ordering, nil, _v), do: false
    defp passes?(:lt, r, v), do: r < v
    defp passes?(:lte, r, v), do: r <= v
    defp passes?(:gt, r, v), do: r > v
    defp passes?(:gte, r, v), do: r >= v

    # The selection of the rows reading value by value keeps.
    defp expected(readings, test, value) do
      kept = for {r, i} <- Enum.with_index(readings), passes?(test, r, value), do: i
      n = length(kept)

      cond do
        kept == [] -> :none
        n == length(readings) -> :all
        List.last(kept) == hd(kept) + n - 1 -> {:run, hd(kept), n}
        true -> {:rows, kept}
      end
    end

    @tag verifies: "operations-filter-scan"
    property "every test keeps the rows reading value by value keeps, a run cut and rows apart gathered" do
      check all(
              ints? <- boolean(),
              gaps? <- boolean(),
              values <-
                list_of(
                  if(ints?, do: integer(-50..50), else: Gen.float(min: -50.0, max: 50.0)),
                  min_length: 1,
                  max_length: 60
                ),
              holes <- list_of(boolean(), length: length(values)),
              test <- member_of(@tests),
              value <- one_of([integer(-50..50), Gen.float(min: -50.0, max: 50.0)]),
              from <- integer(0..(length(values) - 1)),
              max_runs: 400
            ) do
        values =
          if gaps?,
            do: Enum.zip_with(values, holes, &if(&2, do: nil, else: &1)),
            else: values

        table = Table.new!([{"v", :number, values}])
        node = checked(%{op: "filter", field: "v", test: test, value: value})

        for {_chunk, first, count} = view <- views(table, from, length(values) - from) do
          readings = Enum.slice(values, first, count)
          assert Filter.chunk(node, view, "v") == expected(readings, test, value)
        end
      end
    end

    @tag verifies: "operations-filter-scan"
    test "an ordering over an all-valid float column costs at most 3 reductions a row" do
      n = Table.chunk_rows()
      table = Table.new!([{"v", :number, for(i <- 1..n, do: :math.sin(i / 50) * 100)}])
      [view] = Table.chunks(table)
      node = checked(%{op: "filter", field: "v", test: :gt, value: 0.0})

      {reductions, {:rows, kept}} =
        Work.reductions(fn -> Native.elixir(fn -> Filter.chunk(node, view, "v") end) end)

      assert length(kept) == Enum.count(Table.column(table, "v"), &(&1 > 0.0))
      assert reductions <= 3 * n, "#{reductions} reductions for #{n} rows"
    end
  end

  describe "a chunk's groups in one pass (spec/04 §4.10; #41)" do
    # The groups row by row: keys in order of first appearance, each one's state of the
    # aggregate's streaming form over its non-nil readings, its first row and its count.
    defp grouped(keys, readings, aggregate) do
      init = aggregate.init(%{})

      {order, groups, rows} =
        keys
        |> Enum.zip(readings)
        |> Enum.with_index()
        |> Enum.reduce({[], %{}, %{}}, fn {{key, reading}, i}, {order, groups, rows} ->
          {order, state, row} =
            case groups do
              %{^key => state} ->
                {first, n} = rows[key]
                {order, state, {first, n + 1}}

              _ ->
                {[key | order], init, {i, 1}}
            end

          state = if reading == nil, do: state, else: aggregate.step(state, reading, %{})
          {order, Map.put(groups, key, state), Map.put(rows, key, row)}
        end)

      {Enum.reverse(order), groups, rows}
    end

    @tag verifies: "operations-group-chunk"
    property "count, sum and mean by a category, a number, two columns and none group as row by row" do
      check all(
              rows <-
                list_of(
                  tuple(
                    {one_of([member_of(~w(a b c)), constant(nil)]), integer(0..3),
                     one_of([Gen.float(min: -1.0e3, max: 1.0e3), integer(-9..9), constant(nil)])}
                  ),
                  min_length: 1,
                  max_length: 50
                ),
              fun <- member_of(~w(count sum mean)),
              by <- member_of([nil, "k", "x", ["k", "x"]]),
              from <- integer(0..(length(rows) - 1)),
              max_runs: 300
            ) do
        {ks, xs, vs} =
          Enum.reduce(Enum.reverse(rows), {[], [], []}, fn {k, x, v}, {a, b, c} ->
            {[k | a], [x | b], [v | c]}
          end)

        table = Table.new!([{"k", :category, ks}, {"x", :number, xs}, {"v", :number, vs}])
        given = %{op: "aggregate", field: "v", fn: fun}
        node = checked(if by, do: Map.put(given, :by, by), else: given)
        aggregate = node["fn"]
        bound = Aggregate.group_bind(node, table)

        for {_chunk, first, count} = view <- views(table, from, length(rows) - from) do
          slice = &Enum.slice(&1, first, count)

          keys =
            case by do
              nil -> List.duplicate([], count)
              "k" -> Enum.map(slice.(ks), &[&1])
              "x" -> Enum.map(slice.(xs), &[&1])
              _both -> Enum.zip_with(slice.(ks), slice.(xs), &[&1, &2])
            end

          {order, groups, rows} = grouped(keys, slice.(vs), aggregate)

          assert Aggregate.group_chunk(node, aggregate, view, bound, "aggregate") ==
                   {order, groups, rows}
        end
      end
    end

    @tag verifies: "operations-group-chunk"
    test "summing a chunk of 8192 rows by a category column costs at most 16 reductions a row" do
      n = Table.chunk_rows()

      table =
        Table.new!([
          {"v", :number, for(i <- 1..n, do: :math.sin(i / 50) * 100)},
          {"k", :category, for(i <- 1..n, do: Enum.at(~w(a b c d), rem(i, 4)))}
        ])

      [view] = Table.chunks(table)
      node = checked(%{op: "sum", field: "v", by: "k"})
      bound = Aggregate.group_bind(node, table)

      {reductions, {order, _groups, _rows}} =
        Work.reductions(fn ->
          Native.elixir(fn -> Aggregate.group_chunk(node, Aggregates.Sum, view, bound, "sum") end)
        end)

      assert order == [["b"], ["c"], ["d"], ["a"]]
      assert reductions <= 16 * n, "#{reductions} reductions for #{n} rows"
    end
  end

  describe "the exact sum by exponent (spec/04 §5; #41)" do
    # A finite float as the integer multiple of 2^-1074 it is.
    defp units(f) do
      <<sign::1, exp::11, frac::52>> = <<f::float>>
      m = if exp == 0, do: frac, else: frac ||| 1 <<< 52
      u = m <<< max(exp - 1, 0)
      if sign == 1, do: -u, else: u
    end

    # The floats beside `f` in order, as their bit patterns ordered as integers.
    defp neighbors(f) do
      <<x::signed-64>> = <<f::float>>
      key = if x < 0, do: -(x &&& 0x7FFFFFFFFFFFFFFF), else: x

      for k <- [key - 1, key + 1],
          bits = if(k < 0, do: -k ||| 1 <<< 63, else: k),
          <<g::float>> <- [<<bits::64>>],
          do: g
    end

    defp even?(f) do
      <<_::63, low::1>> = <<f::float>>
      low == 0
    end

    @tag verifies: "operations-statistics-exact"
    property "sum's value is the exact sum rounded once, ties to even" do
      check all(
              values <-
                list_of(
                  frequency([
                    {6, Gen.float(min: -1.0e6, max: 1.0e6)},
                    {2, map(integer(-1_000..1_000), &(&1 * 5.0e-324))},
                    {1, map(integer(-5..5), &(&1 * 1.0e306))},
                    {2, integer(-1_000..1_000)}
                  ]),
                  min_length: 1,
                  max_length: 30
                ),
              Enum.any?(values, &is_float/1),
              max_runs: 500
            ) do
        state = Enum.reduce(values, Exact.zero(), &Exact.add(&2, &1))
        f = Exact.value(state)

        exact =
          Enum.reduce(values, 0, fn
            v, t when is_integer(v) -> t + (v <<< 1074)
            v, t -> t + units(v)
          end)

        d = abs(units(f) - exact)

        for g <- neighbors(f) do
          dg = abs(units(g) - exact)
          assert d < dg or (d == dg and even?(f)), "#{inspect(values)}: #{f} vs #{g}"
        end
      end
    end

    @tag verifies: "operations-statistics-exact"
    test "adding a float costs at most 5 reductions" do
      values = for i <- 1..10_000, do: :math.sin(i) * :math.pow(10, rem(i, 13) - 6)

      {reductions, state} =
        Work.reductions(fn -> Enum.reduce(values, Exact.zero(), &Exact.add(&2, &1)) end)

      assert is_float(Exact.value(state))

      assert reductions <= 5 * length(values),
             "#{reductions} reductions for #{length(values)} adds"
    end
  end
end
