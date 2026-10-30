defmodule Macaw.Data.Operations.ParallelTest do
  @moduledoc """
  Execution (spec/04 §1.6; macaw_data#9 §7, #25): inline by default, parallel on request
  above a size threshold, and bit-identical either way, since the merge folds the parts
  in chunk order whatever worked them.
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.{Operations, Table}
  alias Macaw.Data.Operations.{Cache, Step}
  alias Macaw.Data.Test.Storage

  @registry Operations.registry()

  defmodule Probe do
    @moduledoc false
    # A per-row step that tells the test which process worked each chunk, and passes it
    # through.
    def outputs(_node, columns), do: columns
    def class(_node), do: :row
    def reads, do: []
    def keyed(_node), do: %{}
    def resolve(_node, {_chunk, _first, count}, %{at: at}), do: {at, count}

    def chunk(%{"to" => to}, _view, {at, _count}) do
      send(to, {:worked, at, self()})
      :all
    end
  end

  # `n` generated rows: a time, a float reading, an integer, a category, a second float.
  defp rows(n, seed) do
    :rand.seed(:exsss, {seed, seed, seed})

    Table.new!([
      {"t", :number, Enum.to_list(0..(n - 1))},
      {"v", :number, for(_ <- 1..n, do: :rand.normal() * 1.0e3)},
      {"i", :number, for(_ <- 1..n, do: :rand.uniform(100))},
      {"k", :category, for(_ <- 1..n, do: Enum.random(~w(a b c d e)))},
      {"w", :number, for(_ <- 1..n, do: :rand.uniform() * 50)}
    ])
  end

  @nodes [
    %{op: "filter", field: "v", test: :gt, value: 0},
    %{op: "take", n: 9000},
    %{op: "window", field: "t", from: [12_000, :second]},
    %{op: "window", field: "t", latest: true},
    %{op: "sum", field: "v", by: "k"},
    %{op: "sum", field: "i"},
    %{op: "aggregate", field: "v", fn: "mean", by: "k"},
    %{op: "aggregate", field: "v", fn: "median", by: "k"},
    %{op: "bin", field: "v", thresholds: 20},
    %{op: "bin", field: "w", thresholds: 10, fn: "sum"},
    %{op: "m4", fields: ["t", "v"], width: 300},
    %{op: "lttb", fields: ["t", "v"], n: 200},
    %{op: "sort", field: "v"},
    %{op: "fold", fields: ["v", "w"]},
    %{op: "stack", fields: ["v", "w"]},
    %{op: "spectrum", field: "v", time: "t"}
  ]

  @schema Macaw.Data.Schema.new!(%{
            "k" => %{type: :category, identity: true},
            "t" => %{type: :number, window: true}
          })

  describe "identical results" do
    @tag verifies: "operations-parallel-identical"
    test "a parallel run and an inline run are the same bits, cached or not" do
      for seed <- 1..3 do
        table = rows(3 * Table.chunk_rows() + 517 * seed, seed)
        assert length(Table.chunks(table)) == 4
        assert Step.parallel?(table, %{parallel: true})

        for node <- @nodes do
          context = %{schema: @schema}
          inline = Operations.apply!(@registry, [node], table, context)

          parallel =
            Operations.apply!(@registry, [node], table, Map.put(context, :parallel, true))

          assert Table.equal?(parallel, inline), inspect(node)
          assert Table.digest(parallel) == Table.digest(inline)

          {:ok, [checked]} = Operations.validate(@registry, [node], context)
          {:ok, module} = Operations.Registry.transform(@registry, checked["op"])
          context = Map.put(context, :parallel, true)
          {cached, _cache} = Cache.run(Cache.new(), module, checked, table, context)
          assert Table.equal?(cached, inline), inspect(node)
        end
      end
    end

    @tag verifies: "operations-parallel-identical"
    test "a float sum over chunks of mixed magnitudes is the same bits" do
      values = for i <- 1..40_000, do: :math.sin(i) * :math.pow(10, rem(i, 17) - 8)
      table = Table.new!([{"v", :number, values}])
      assert Step.parallel?(table, %{parallel: true})
      node = %{op: "sum", field: "v"}
      [inline] = Table.column(Operations.apply!(@registry, [node], table), "sum")

      [parallel] =
        Table.column(Operations.apply!(@registry, [node], table, %{parallel: true}), "sum")

      assert <<inline::float>> == <<parallel::float>>
    end
  end

  describe "the threshold" do
    defp workers(table, context) do
      Step.run(Probe, %{"to" => self()}, table, context)

      table
      |> Table.chunks()
      |> Enum.map(fn _ -> receive do: ({:worked, at, pid} -> {at, pid}) end)
    end

    @tag verifies: "operations-parallel-threshold"
    test "parallel parts run in other processes only when asked and above the threshold" do
      at = Step.parallel_rows()
      assert at == 2 * Table.chunk_rows()

      above = rows(at, 1)
      assert length(Table.chunks(above)) == 2
      assert Step.parallel?(above, %{parallel: true})

      worked = workers(above, %{parallel: true})
      assert Enum.all?(worked, fn {_at, pid} -> pid != self() end)
      assert worked |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [0, Table.chunk_rows()]

      # Not asked: inline.
      refute Step.parallel?(above, %{})
      assert Enum.all?(workers(above, %{}), fn {_at, pid} -> pid == self() end)

      # Below the threshold: inline.
      below = rows(at - 1, 1)
      refute Step.parallel?(below, %{parallel: true})
      assert Enum.all?(workers(below, %{parallel: true}), fn {_at, pid} -> pid == self() end)

      # One chunk, however long: inline.
      one = Storage.chunked(above, :one)
      refute Step.parallel?(one, %{parallel: true})
      assert Enum.all?(workers(one, %{parallel: true}), fn {_at, pid} -> pid == self() end)
    end
  end
end
