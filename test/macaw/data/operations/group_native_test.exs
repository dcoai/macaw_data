defmodule Macaw.Data.Operations.GroupNativeTest do
  # The exact sum by group in a native kernel (spec/04 §5.1): a chunk's groups for sum, mean
  # and count equal the Elixir fold's term for term, every number form it reads, grouped by
  # a dictionary column or not at all, chunked several ways and viewed from an offset;
  # where the Elixir path would raise it hands the view back. Without the kernels both
  # sides are the Elixir fold.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Native, Operations, Table}
  alias Macaw.Data.Native.Kernels
  alias Macaw.Data.Operations.Aggregates
  alias Macaw.Data.Operations.Transforms.Aggregate
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Test.Storage

  @registry Operations.registry()
  @max_int 0x7FFF_FFFF_FFFF_FFFF

  defp checked(node) do
    {:ok, [checked]} = Operations.validate(@registry, [node], %{})
    checked
  end

  # Floats of every kind the exact sum treats apart: normal, subnormal, signed zeros, near
  # the largest (but summing within range), and ordinary.
  defp float_gen do
    frequency([
      {6, float(min: -1.0e6, max: 1.0e6)},
      {2, map(integer(-50..50), &(&1 * 5.0e-324))},
      {1, member_of([0.0, -0.0])},
      {1, map(float(min: -1.0, max: 1.0), &(&1 * 1.0e300))},
      {1, map(integer(-40..40), &:math.pow(2.0, &1))}
    ])
  end

  # Integers small and near int64's ends, so a group's sum goes past int64.
  defp int_gen do
    frequency([
      {6, integer(-1_000_000..1_000_000)},
      {1, map(integer(0..1000), &(@max_int - &1))},
      {1, map(integer(0..1000), &(-@max_int + &1))}
    ])
  end

  defp rows_gen(value_gen) do
    list_of(
      tuple(
        {frequency([{10, member_of(~w(a b c d e))}, {1, constant(nil)}]),
         frequency([{8, value_gen}, {1, constant(nil)}])}
      ),
      min_length: 1,
      max_length: 600
    )
  end

  describe "the native groups against the Elixir fold" do
    @tag verifies: "operations-group-native-identical"
    property "sum, mean and count: the same groups, term for term, every form, grouping, chunking and offset" do
      check all(
              ints? <- boolean(),
              rows <- if(ints?, do: rows_gen(int_gen()), else: rows_gen(float_gen())),
              grouped? <- boolean(),
              size <- member_of([:one, 7, 64, 211]),
              offset <- integer(0..5),
              max_runs: 150
            ) do
        keys = Enum.map(rows, &elem(&1, 0))
        values = Enum.map(rows, &elem(&1, 1))

        table =
          Table.new!([{"s", :category, keys}, {"v", :number, values}]) |> Storage.chunked(size)

        by = if grouped?, do: %{by: "s"}, else: %{}

        for {aggregate, op} <- [
              {Aggregates.Sum, "sum"},
              {Aggregates.Mean, "mean"},
              {Aggregates.Count, "count"}
            ] do
          raw = Map.merge(%{op: "aggregate", field: "v", fn: op}, by)
          node = checked(raw)
          bound = Aggregate.group_bind(node, table)

          for {chunk, first, count} <- Table.chunks(table), offset < count do
            view = {chunk, first + offset, count - offset}
            native = Aggregate.group_native(aggregate, view, bound)
            elixir = Aggregate.group_chunk_elixir(node, aggregate, view, bound, "aggregate")
            if Native.loaded?(), do: assert(native != :fallback)
            if native != :fallback, do: assert(native == elixir)
            assert Aggregate.group_chunk(node, aggregate, view, bound, "aggregate") == elixir
          end

          # The step itself, with and without the kernels.
          run = fn -> Operations.apply!(@registry, [raw], table) end
          assert Table.equal?(run.(), Native.elixir(run))
        end

        sum = Map.merge(%{op: "sum", field: "v"}, by)
        run = fn -> Operations.apply!(@registry, [sum], table) end
        assert Table.equal?(run.(), Native.elixir(run))
      end
    end

    @tag verifies: "operations-group-native-identical"
    test "a form, aggregate or grouping the kernel doesn't read is the Elixir path's, and a code past the dictionary is handed back" do
      table =
        Table.new!([
          {"s", :category, ["a", "b", nil, "a"]},
          {"t", :category, ["x", "y", "x", "y"]},
          {"v", :number, [1, 2.5, 3, nil]}
        ])

      [view] = Table.chunks(table)

      for raw <- [
            %{op: "aggregate", field: "v", fn: "sum", by: "s"},
            %{op: "aggregate", field: "v", fn: "max", by: "s"},
            %{op: "aggregate", field: "v", fn: "sum", by: ["s", "t"]},
            %{op: "aggregate", field: ["v", "v"], fn: "count", by: "s"}
          ] do
        node = checked(raw)
        bound = Aggregate.group_bind(node, table)
        # The int/float union, another aggregate, two columns, a pair.
        assert Aggregate.group_native(node["fn"], view, bound) == :fallback
        run = fn -> Operations.apply!(@registry, [raw], table) end
        assert Table.equal?(run.(), Native.elixir(run))
      end

      if Native.loaded?() do
        ints = Table.new!([{"s", :category, ["a", "b"]}, {"v", :number, [1, 2]}])
        [{chunk, 0, 2}] = Table.chunks(ints)
        {:int64, vd, vv} = Chunk.packed(chunk, "v")
        {:dictionary, cd, cv, _dictionary, nil} = Chunk.packed(chunk, "s")
        assert is_list(Kernels.group_sum(0, vd, vv, true, cd, cv, 2, 0, 2, 0))
        # Code 1 past a dictionary of one string.
        assert Kernels.group_sum(0, vd, vv, true, cd, cv, 1, 0, 2, 0) == :fallback
      end
    end
  end

  describe "the call's bound" do
    @tag verifies: "operations-group-native-bound"
    test "a call answering sync_entries entries takes under 1 ms on a normal scheduler; past them, or past sync_rows rows, it runs dirty with the Elixir path's groups" do
      n = Native.sync_rows()
      e = Native.sync_entries()

      # 256 groups, each with floats of 7 exponents: 256 + 256 × 7 = sync_entries entries,
      # the most a normal call answers.
      full_keys = for i <- 0..(n - 1), do: "k#{rem(i, 256)}"
      full_values = for i <- 0..(n - 1), do: :math.pow(2.0, rem(div(i, 256), 7) * 40 - 120) * 1.37
      assert 256 + 256 * 7 == e

      # Every row its own group; and a view past sync_rows.
      many = for i <- 0..(2 * n + 3), do: "m#{i}"

      for {keys, values} <- [
            {full_keys, full_values},
            {Enum.map(0..(n - 1), &"k#{&1}"), full_values},
            {many, Enum.map(many, fn _ -> 0.5 end)}
          ] do
        table =
          Table.new!([{"s", :category, keys}, {"v", :number, values}]) |> Storage.chunked(:one)

        node = checked(%{op: "sum", field: "v", by: "s"})
        bound = Aggregate.group_bind(node, table)
        [view] = Table.chunks(table)
        native = Aggregate.group_native(Aggregates.Sum, view, bound)
        elixir = Aggregate.group_chunk_elixir(node, Aggregates.Sum, view, bound, "sum")
        if Native.loaded?(), do: assert(native == elixir)
      end

      assert Native.scheduler(2 * n) == :dirty

      if Native.loaded?() do
        table = Table.new!([{"s", :category, full_keys}, {"v", :number, full_values}])
        [{chunk, 0, ^n}] = Table.chunks(table)
        {:float64, vd, vv} = Chunk.packed(chunk, "v")
        {:dictionary, cd, cv, {offsets, _data}, nil} = Chunk.packed(chunk, "s")
        ncodes = div(byte_size(offsets), 4) - 1
        call = fn -> Kernels.group_sum(1, vd, vv, true, cd, cv, ncodes, 0, n, e) end
        assert is_list(call.())
        assert Kernels.group_sum(1, vd, vv, true, cd, cv, ncodes, 0, n, e - 1) == :dirty

        for _ <- 1..5, do: call.()
        least = Enum.min(for _ <- 1..21, do: elem(:timer.tc(call), 0))
        assert least < 1_000, "a #{n}-row sum answering #{e} entries took #{least} µs"
      end
    end
  end
end
