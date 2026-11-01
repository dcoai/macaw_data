defmodule Macaw.Data.Operations.GlobalTest do
  @moduledoc """
  The global steps and the reshapes (spec/04 §1.4; macaw_data#9 §5, #23): `sort`,
  `stack`, `spectrum` and the non-combining `aggregate` and `bin` merge over every
  chunk's part, their outputs named by their step key over their inputs; `fold` and
  `stack` gather with repeated indexes and add columns. No step transposes.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Macaw.Data.Test.Trace, only: [calls: 2]

  alias Macaw.Data.{FFT, Operations, Schema, Stack, Table}
  alias Macaw.Data.Operations.Step
  alias Macaw.Data.Operations.Transforms.Filter
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Test.Storage

  @registry Operations.registry()
  @header [{"t", :number}, {"v", :number}, {"w", :number}, {"k", :category}, {"s", :text}]

  defp run(table, node, context \\ %{}), do: Operations.apply!(@registry, [node], table, context)

  defp checked(node) do
    {:ok, [checked]} = Operations.validate(@registry, [node], %{})
    checked
  end

  defp table_of(rows, header \\ @header),
    do: Table.new!(for({name, type} <- header, do: {name, type, Enum.map(rows, & &1[name])}))

  defp number_gen, do: one_of([integer(-9..9), float(min: -9.0, max: 9.0), constant(nil)])

  defp rows_gen do
    list_of(
      gen all(
            t <- integer(0..500),
            v <- number_gen(),
            w <- number_gen(),
            k <- member_of(["a", "b", :c, nil]),
            s <- one_of([string(:alphanumeric, max_length: 2), constant(nil)])
          ) do
        %{"t" => t, "v" => v, "w" => w, "k" => k, "s" => s}
      end,
      max_length: 60
    )
  end

  defp node_gen do
    one_of([
      gen(
        all(
          f <- member_of(["v", "k", "s"]),
          o <- member_of([:ascending, :descending]),
          do: %{op: "sort", field: f, order: o}
        )
      ),
      constant(%{op: "fold", fields: ["v", "w", "nope"]}),
      gen all(
            order <-
              member_of([:none, :ascending, :descending, :inside_out, :reverse, :appearance]),
            offset <- member_of([:none, :expand, :silhouette, :wiggle, :diverging])
          ) do
        %{op: "stack", fields: ["v", "w"], order: order, offset: offset}
      end,
      gen(
        all(
          time <- member_of([nil, "t"]),
          do: Map.reject(%{op: "spectrum", field: "v", time: time}, fn {_, v} -> v == nil end)
        )
      ),
      gen all(
            f <- member_of(["median", "distinct", "variance", "delta"]),
            by <- member_of([nil, "k"])
          ) do
        Map.reject(%{op: "aggregate", field: "v", fn: f, by: by}, fn {_, v} -> v == nil end)
      end,
      constant(%{op: "aggregate", field: "v", fn: "quantile", p: 0.9, by: "k"}),
      gen(all(n <- integer(1..5), do: %{op: "bin", field: "v", thresholds: n, fn: "median"}))
    ])
  end

  # -- the rows' answers, each step as it was written over rows ---------------------------

  # Numbers by value and strings by spelling are term order within their kind; a nil
  # follows every reading in either direction.
  defp oracle(rows, %{op: "sort", field: f, order: o}) do
    {absent, present} = Enum.split_with(rows, &(&1[f] == nil))
    Enum.sort_by(present, & &1[f], if(o == :descending, do: :desc, else: :asc)) ++ absent
  end

  defp oracle(rows, %{op: "fold"}) do
    for row <- rows, f <- ["v", "w"], row[f] != nil do
      row |> Map.drop(["v", "w"]) |> Map.merge(%{"key" => f, "value" => row[f]})
    end
  end

  defp oracle(rows, %{op: "stack", order: order, offset: offset}) do
    fields = ["v", "w"]

    {keys, order} =
      case order do
        :inside_out -> {fields, :insideout}
        :appearance -> {Enum.sort_by(fields, &peak(rows, &1)), :none}
        other -> {fields, other}
      end

    series =
      Stack.new()
      |> Stack.keys(keys)
      |> Stack.value(fn row, f -> row[f] || 0 end)
      |> Stack.order(order)
      |> Stack.offset(offset)
      |> Stack.generate(rows)
      |> Map.new(&{&1.key, &1})

    for f <- fields, s = series[f], s != nil, p <- s.points do
      Map.merge(p.data, %{
        "key" => f,
        "series" => s.index,
        "value" => p.value,
        "y0" => p.y0,
        "y1" => p.y1
      })
    end
  end

  defp oracle(rows, %{op: "spectrum"} = node) do
    sampled = Enum.filter(rows, &is_number(&1["v"]))

    every =
      if node[:time] do
        gaps =
          sampled
          |> Enum.map(& &1["t"])
          |> Enum.reject(&is_nil/1)
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [a, b] -> b - a end)
          |> Enum.filter(&(&1 > 0))
          |> Enum.sort()

        if gaps == [], do: 1, else: Enum.at(gaps, div(length(gaps), 2))
      else
        1
      end

    for line <- FFT.spectrum(Enum.map(sampled, & &1["v"]), every, window: :hann, detrend: false),
        do: %{"frequency" => line.frequency, "magnitude" => line.magnitude}
  end

  defp oracle(rows, %{op: "aggregate", fn: f} = node) do
    {:ok, aggregate} = Operations.aggregate(@registry, f)
    options = if node[:p], do: %{"p" => node[:p]}, else: %{}
    by = List.wrap(node[:by])
    key = fn row -> Enum.map(by, &row[&1]) end
    order = rows |> Enum.map(key) |> Enum.uniq()
    order = if order == [] and by == [], do: [[]], else: order

    for k <- order do
      values = for row <- rows, key.(row) == k, row["v"] != nil, do: row["v"]
      by |> Enum.zip(k) |> Map.new() |> Map.put(f, aggregate.reduce(values, options))
    end
  end

  defp oracle(rows, %{op: "bin", thresholds: n}) do
    {:ok, median} = Operations.aggregate(@registry, "median")
    values = for row <- rows, row["v"] != nil, do: row["v"]

    case values do
      [] ->
        []

      _ ->
        {d0, d1} = Enum.min_max(values)
        inner = for i <- 1..(n - 1)//1, do: d0 + i * (d1 - d0) / n
        edges = Enum.chunk_every([d0] ++ inner ++ [d1], 2, 1, :discard)
        last = length(edges) - 1

        held =
          Enum.group_by(values, fn v ->
            Enum.find_index(edges, fn [x0, x1] -> v >= x0 and v < x1 end) || if(v == d1, do: last)
          end)

        for {[x0, x1], i} <- Enum.with_index(edges) do
          in_bin = Map.get(held, i, [])

          %{
            "x0" => x0,
            "x1" => x1,
            "y0" => 0,
            "count" => median.reduce(in_bin, %{}),
            "values" => in_bin
          }
        end
    end
  end

  defp peak(rows, f) do
    rows
    |> Enum.map(&(&1[f] || 0))
    |> Enum.with_index()
    |> Enum.max_by(fn {v, _i} -> v end, fn -> {0, 0} end)
    |> elem(1)
  end

  defp expected(table, rows, node) do
    columns = Operations.outputs(@registry, [node], Operations.columns(table)) |> elem(1)
    Table.new!(for {name, type} <- columns, do: {name, type, Enum.map(rows, & &1[name])})
  end

  describe "the global steps (spec/04 §1.4)" do
    @tag verifies: "operations-step-global"
    property "every chunking gives the rows' answer" do
      check all(rows <- rows_gen(), node <- node_gen(), max_runs: 40) do
        table = table_of(rows)
        read = Table.rows(table)
        expected = expected(table, oracle(read, node), node)

        for size <- [1, 7, :one] do
          assert Table.equal?(run(Storage.chunked(table, size), node), expected)
        end

        assert Table.equal?(run(table, node), expected)
      end
    end

    @tag verifies: "operations-step-global"
    test "sort, stack and fold are global or per row as they state, and reshape their rows" do
      assert checked(%{op: "sort", field: "v"}) |> Macaw.Data.Operations.Transforms.Sort.class() ==
               :global

      assert checked(%{op: "stack", fields: ["v"]})
             |> Macaw.Data.Operations.Transforms.Stack.class() == :global

      assert checked(%{op: "spectrum", field: "v"})
             |> Macaw.Data.Operations.Transforms.Spectrum.class() == :global

      assert checked(%{op: "fold", fields: ["v"]})
             |> Macaw.Data.Operations.Transforms.Fold.class() == :row

      assert checked(%{op: "aggregate", field: "v", fn: "median"})
             |> Macaw.Data.Operations.Transforms.Aggregate.class() == :global

      assert checked(%{op: "bin", field: "v", fn: "quantile", p: 0.5})
             |> Macaw.Data.Operations.Transforms.Bin.class() == :global

      # fold's chunks are the input's rows gathered with repeats, named after them.
      table =
        table_of(for i <- 1..10, do: %{"t" => i, "v" => i, "w" => -i, "k" => "a", "s" => "x"})

      [{input, 0, 10}] = Table.chunks(table)
      [{folded, 0, 20}] = Table.chunks(run(table, %{op: "fold", fields: ["v", "w"]}))
      assert match?({id, _key} when id == input.id, Chunk.id(folded))
    end
  end

  describe "global outputs are named by their inputs (spec/04 §1.4)" do
    @tag verifies: "operations-step-global-cache"
    test "a sort's output is named by its key over its inputs, so the next step still caches" do
      rows =
        for i <- 1..300,
            do: %{"t" => i, "v" => rem(i * 37, 101), "w" => i, "k" => "a", "s" => "x"}

      table = Storage.chunked(table_of(rows), 64)
      sort = %{op: "sort", field: "v"}
      [{once, _, _}] = Table.chunks(run(table, sort))
      [{again, _, _}] = Table.chunks(run(table, sort))
      assert Chunk.id(once) == Chunk.id(again)
      assert Chunk.version(once) == Chunk.version(again)
      assert {:combined, _digest} = Chunk.id(once)
      assert Chunk.digest(once) == nil

      changed =
        Storage.chunked(table_of(List.replace_at(rows, 299, %{hd(rows) | "v" => 1000})), 64)

      [{other, _, _}] = Table.chunks(run(changed, sort))
      refute Chunk.id(other) == Chunk.id(once)

      filter = checked(%{op: "filter", field: "v", test: :gt, value: 50})
      keys = fn t -> Enum.map(Step.parts(Filter, filter, t, %{}), & &1.key) end
      assert keys.(run(table, sort)) == keys.(run(table, sort))
    end

    @tag verifies: "operations-step-global-cache"
    test "a sort across chunks of different dictionaries reads every category back" do
      a = table_of([%{"k" => "pear"}, %{"k" => "fig"}, %{"k" => :apple}], [{"k", :category}])

      b =
        table_of([%{"k" => "kiwi"}, %{"k" => "apple"}, %{"k" => nil}, %{"k" => "fig"}], [
          {"k", :category}
        ])

      {:ok, table} = Table.append(a, b)
      assert length(Table.chunks(table)) == 2

      sorted = run(table, %{op: "sort", field: "k"})
      # By spelling, an atom's as its string's, and nil last either way.
      assert Table.column(sorted, "k") == ["apple", "apple", "fig", "fig", "kiwi", "pear", nil]

      assert Table.column(run(table, %{op: "sort", field: "k", order: :descending}), "k") ==
               ["pear", "kiwi", "fig", "fig", "apple", "apple", nil]
    end
  end

  describe "sort compares by the column's type (spec/04 §4.6)" do
    # Instants from 1990 to 2040 at second resolution, so day, month and year all vary and
    # the struct's field order (day first) disagrees with time's.
    defp instant_gen do
      map(integer(631_152_000..2_208_988_800), &DateTime.from_unix!/1)
    end

    defp typed_rows_gen do
      list_of(
        gen all(
              i <- integer(),
              t <- one_of([instant_gen(), constant(nil)]),
              n <- one_of([integer(-50..50), float(min: -50.0, max: 50.0), constant(nil)]),
              k <- one_of([member_of(["b", "a", "ca", :c, :ab, "B"]), constant(nil)])
            ) do
          %{"i" => i, "t" => t, "n" => n, "k" => k}
        end,
        max_length: 60
      )
    end

    @typed [{"i", :number}, {"t", :time}, {"n", :number}, {"k", :category}]

    # The type's own comparison, independent of `Source.Order`: `DateTime.compare/2` for a
    # time, numeric for a number, a string's for a category's spelling; nil last.
    defp by_type("t"), do: &(DateTime.compare(&1, &2) != :gt)
    defp by_type("n"), do: &(&1 <= &2)
    defp by_type("k"), do: &(to_string(&1) <= to_string(&2))

    defp typed_oracle(rows, field, order) do
      {absent, present} = Enum.split_with(rows, &(&1[field] == nil))
      before? = by_type(field)

      sorter =
        if order == :descending,
          do: fn a, b -> before?.(b[field], a[field]) end,
          else: fn a, b -> before?.(a[field], b[field]) end

      Enum.sort(present, sorter) ++ absent
    end

    @tag verifies: "operations-sort-type"
    property "sort agrees with each type's comparison, DateTime.compare/2 for a time, stably" do
      check all(
              rows <- typed_rows_gen(),
              field <- member_of(["t", "n", "k"]),
              order <- member_of([:ascending, :descending]),
              max_runs: 60
            ) do
        table = table_of(rows, @typed)
        expected = Enum.map(typed_oracle(Table.rows(table), field, order), & &1["i"])
        node = %{op: "sort", field: field, order: order}

        for size <- [1, 7, :one] do
          sorted = run(Storage.chunked(table, size), node)
          assert Table.column(sorted, "i") == expected
        end

        assert Table.column(run(table, node), "i") == expected
      end
    end

    @tag verifies: "operations-sort-type"
    test "a time column sorts by instant across years, months and days, nil last" do
      times = [
        ~U[2026-10-02 00:00:00Z],
        nil,
        ~U[2026-09-30 00:00:00Z],
        ~U[2026-10-01 00:00:00Z],
        ~U[2025-12-31 00:00:00Z]
      ]

      table = Storage.chunked(Table.new!([{"t", :time, times}]), 2)

      assert Table.column(run(table, %{op: "sort", field: "t"}), "t") == [
               ~U[2025-12-31 00:00:00Z],
               ~U[2026-09-30 00:00:00Z],
               ~U[2026-10-01 00:00:00Z],
               ~U[2026-10-02 00:00:00Z],
               nil
             ]

      assert Table.column(run(table, %{op: "sort", field: "t", order: :descending}), "t") == [
               ~U[2026-10-02 00:00:00Z],
               ~U[2026-10-01 00:00:00Z],
               ~U[2026-09-30 00:00:00Z],
               ~U[2025-12-31 00:00:00Z],
               nil
             ]
    end
  end

  describe "no transposes (spec/04 §1.4)" do
    @tag verifies: "operations-step-no-transpose"
    test "every table operation runs without Table.rows/1 or Operations.table/2" do
      rows =
        for i <- 0..199,
            do: %{"t" => i, "v" => rem(i * 7, 13), "w" => i, "k" => "k#{rem(i, 3)}", "s" => "s"}

      table =
        Table.new!(for({name, type} <- @header, do: {name, type, Enum.map(rows, & &1[name])}),
          origin: %{source: "s", resolution: 1, window: "t", span: 50}
        )

      schema = Schema.new!(%{"k" => %{type: :category, identity: true}, "t" => %{type: :number}})

      nodes = [
        %{op: "filter", field: "v", test: :gt, value: 3},
        %{op: "take", n: 10},
        %{op: "window", field: "t", from: [50, :second]},
        %{op: "window", field: "t", latest: true},
        %{op: "lttb", fields: ["t", "v"], n: 20},
        %{op: "m4", fields: ["t", "v"], width: 10},
        %{op: "sort", field: "v"},
        %{op: "fold", fields: ["v", "w"]},
        %{op: "stack", fields: ["v", "w"], offset: :expand},
        %{op: "bin", field: "v"},
        %{op: "bin", field: "v", fn: "median"},
        %{op: "aggregate", field: "v", fn: "mean", by: "k"},
        %{op: "aggregate", field: "v", fn: "median", by: "k"},
        %{op: "sum", field: "v", by: "k"},
        %{op: "spectrum", field: "v", time: "t"}
      ]

      assert Enum.sort(Enum.uniq(Enum.map(nodes, & &1.op))) ==
               Enum.sort(Operations.transforms(@registry))

      every = fn -> for node <- nodes, do: run(table, node, %{schema: schema}) end
      assert calls({Table, :rows, 1}, every) == []
      assert calls({Operations, :table, 2}, every) == []
    end
  end
end
