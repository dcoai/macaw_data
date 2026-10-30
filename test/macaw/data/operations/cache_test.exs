defmodule Macaw.Data.Operations.CacheTest do
  @moduledoc """
  The caching contract (spec/04 §1.5; macaw_data#9 §6, #24): a caller's cache keys a
  step's per-chunk parts by `{logical id, version, step key}`, reuses them across runs and
  rebuilds, updates a changed chunk's part by inverse only where that is exact, and
  evicts by logical id.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Macaw.Data.Test.Trace, only: [calls: 2]

  alias Macaw.Data.{Operations, Schema, Table}
  alias Macaw.Data.Operations.{Cache, Step}
  alias Macaw.Data.Table.Chunk

  @registry Operations.registry()

  @schema Schema.new!(%{
            "id" => %{type: :category, identity: true},
            "t" => %{type: :number, window: true},
            "v" => %{type: :number}
          })

  # Spans of 100: chunks [0, 100), [100, 200), [200, 300).
  @origin %{source: "taps", resolution: 1, window: "t", span: 100}

  defp row(id, t, v), do: %{"id" => id, "t" => t, "v" => v}

  defp sorted(rows), do: Enum.sort_by(rows, & &1["t"])

  defp table(rows) do
    rows = sorted(rows)

    Table.new!(
      for(
        {name, type} <- [{"id", :category}, {"t", :number}, {"v", :number}],
        do: {name, type, Enum.map(rows, & &1[name])}
      ),
      origin: @origin
    )
  end

  defp rows(f), do: for(t <- 0..299, do: row(Enum.at(~w(a b c), rem(t, 3)), t, f.(t)))

  defp apply!(table, fields) do
    change =
      Map.merge(
        %{insert: [], retract: [], replace: [], schema: @schema, settled: 300, thinned: false},
        Map.new(fields)
      )

    {table, [], 0} = Table.apply(table, change)
    table
  end

  # A checked node and the module its op names.
  defp step(node) do
    {:ok, [checked]} = Operations.validate(@registry, [node], %{})
    {:ok, module} = Operations.Registry.transform(@registry, checked["op"])
    {module, checked}
  end

  @steps [
    %{op: "sum", field: "v", by: "id"},
    %{op: "aggregate", field: "v", fn: "count", by: "id"},
    %{op: "bin", field: "v", thresholds: 4},
    %{op: "filter", field: "v", test: :gt, value: 4},
    %{op: "take", n: 150},
    %{op: "sort", field: "v"},
    %{op: "m4", fields: ["t", "v"], width: 10},
    %{op: "lttb", fields: ["t", "v"], n: 20}
  ]

  describe "reuse" do
    @tag verifies: "operations-cache-reuse"
    test "a per-chunk run with cached parts equals a full run, and a second run reuses every part" do
      table = table(rows(&rem(&1 * 7, 10)))

      for node <- @steps do
        {module, node} = step(node)
        full = Step.run(module, node, table, %{})

        {first, cache} = Cache.run(Cache.new(), module, node, table, %{})
        assert Table.equal?(first, full)
        assert cache.last == %{reused: 0, updated: 0, computed: 3}

        # A lookup hashes no content: the versions are read from the chunks.
        hashed =
          calls({Macaw.Data.Table.Digest, :digest, 3}, fn ->
            {again, cache} = Cache.run(cache, module, node, table, %{})
            send(self(), {:again, again, cache})
          end)

        # Only this pattern counts: another async test's global trace pattern may also match
        # calls made here (#37).
        assert Enum.filter(hashed, &(&1 == {Macaw.Data.Table.Digest, :digest})) == []
        assert_received {:again, again, cache}
        assert Table.equal?(again, full)
        assert cache.last == %{reused: 3, updated: 0, computed: 0}
      end
    end

    @tag verifies: "operations-cache-reuse"
    test "a rebuild of the same contents hits every part; a chunk of other contents misses alone" do
      values = rows(&rem(&1 * 7, 10))
      {module, node} = step(%{op: "sum", field: "v", by: "id"})
      {_, cache} = Cache.run(Cache.new(), module, node, table(values), %{})

      # Built again from the same rows: another struct, the same ids and digests.
      {_, rebuilt} = Cache.run(cache, module, node, table(values), %{})
      assert rebuilt.last == %{reused: 3, updated: 0, computed: 0}

      # One value of the middle chunk changed: that chunk alone is computed.
      changed = List.update_at(values, 150, &%{&1 | "v" => 99})
      {out, cache} = Cache.run(cache, module, node, table(changed), %{})
      assert cache.last == %{reused: 2, updated: 0, computed: 1}
      assert Table.equal?(out, Step.run(module, node, table(changed), %{}))
    end

    @tag verifies: "operations-cache-reuse"
    test "a chunk whose digest is pending is warmed before its key is read" do
      table = table(rows(&rem(&1, 10)))
      [{warm, 0, n} | rest] = Table.chunks(table)
      base = warm.columns
      cold = Chunk.cold(Chunk.header(warm), Chunk.id(warm), Chunk.digest(warm), n, fn -> base end)
      cold = %{table | chunks: [{cold, 0, n} | rest]}

      changed = apply!(cold, replace: [%{from: 10, to: 20, identities: ["a"], rows: []}])
      [{pending, 0, nil} | _] = Table.chunks(changed)
      assert Chunk.version(pending) == nil

      {module, node} = step(%{op: "aggregate", field: "v", fn: "count", by: "id"})
      {out, cache} = Cache.run(Cache.new(), module, node, changed, %{})
      assert Table.equal?(out, Step.run(module, node, Table.warm(changed), %{}))
      assert Enum.all?(Map.keys(cache.parts), fn {_id, version, _key} -> is_binary(version) end)
    end
  end

  describe "inverse updates" do
    defp changes_gen do
      gen all(
            retract <- list_of(integer(0..299), max_length: 8),
            inserts <-
              list_of(tuple({member_of(~w(a b c d)), integer(0..299), integer(0..9)}),
                max_length: 8
              ),
            from <- integer(0..290),
            ids <- member_of([nil, ["a"], ["b"]]),
            replace? <- boolean()
          ) do
        held = sorted(rows(&rem(&1 * 7, 10)))
        range = %{from: from, to: from + 5, identities: ids}

        in_range? = fn r ->
          r["t"] >= from and r["t"] < from + 5 and (ids == nil or r["id"] in ids)
        end

        retract =
          retract
          |> Enum.uniq()
          |> Enum.map(&Enum.at(held, &1))
          |> Enum.reject(&(replace? and in_range?.(&1)))

        insert =
          for {id, t, v} <- inserts, r = row(id, t, v), not (replace? and in_range?.(r)), do: r

        replace = if replace?, do: [Map.put(range, :rows, [])], else: []
        %{retract: retract, insert: insert, replace: replace}
      end
    end

    # Whether a removed base row was its group's first row in its chunk.
    defp first_removed?(chunk, by) do
      changes = Chunk.changes(chunk)
      keys = Chunk.values(%{chunk | delta: nil, read: nil}, by, 0, chunk.base_rows)

      firsts =
        keys
        |> Enum.with_index()
        |> Enum.uniq_by(&elem(&1, 0))
        |> MapSet.new(&elem(&1, 1))

      not MapSet.disjoint?(firsts, changes.gone)
    end

    @tag verifies: "operations-cache-inverse"
    property "count by groups, bin counts and an integer sum update a changed chunk by inverse, equal to its recompute" do
      table = table(rows(&rem(&1 * 7, 10)))

      nodes = [
        {%{op: "aggregate", field: "v", fn: "count", by: "id"}, "id"},
        {%{op: "sum", field: "v", by: "id"}, "id"},
        {%{op: "sum", field: "v"}, nil},
        {%{op: "bin", field: "v", thresholds: 5}, nil}
      ]

      check all(changes <- changes_gen(), max_runs: 40) do
        applied = apply!(table, Map.to_list(changes))

        for {node, by} <- nodes do
          {module, node} = step(node)
          {_, cache} = Cache.run(Cache.new(), module, node, table, %{})
          {out, after_} = Cache.run(cache, module, node, applied, %{})
          assert Table.equal?(out, Step.run(module, node, applied, %{}))

          for %{view: {chunk, _, _}, key: key} = part <- Step.parts(module, node, applied, %{}),
              Chunk.delta?(chunk) do
            base = Map.get(cache.parts, {Chunk.id(chunk), Chunk.base_version(chunk), key})

            case base && Step.update(module, node, part, base) do
              {:ok, updated} ->
                assert updated == Step.chunk(module, node, part)

              :recompute ->
                # Only a removed first row of a group (or the whole chunk's, ungrouped)
                # stops a count or an integer sum.
                assert node["op"] != "bin"
                assert first_removed?(chunk, by || "t")

              nil ->
                # The bins moved with the extent: another key, so no base part.
                assert node["op"] == "bin"
            end
          end

          assert after_.last.reused + after_.last.updated + after_.last.computed == 3
        end
      end
    end
  end

  describe "recompute" do
    @tag verifies: "operations-cache-recompute"
    test "a float sum, mean, min, max, m4 and lttb recompute a changed chunk" do
      table = table(rows(&(&1 * 0.5)))
      applied = apply!(table, retract: [row("c", 152, 76.0)], insert: [row("a", 160, 1.25)])

      for node <- [
            %{op: "sum", field: "v", by: "id"},
            %{op: "aggregate", field: "v", fn: "mean", by: "id"},
            %{op: "aggregate", field: "v", fn: "min"},
            %{op: "aggregate", field: "v", fn: "max"},
            %{op: "m4", fields: ["t", "v"], width: 10},
            %{op: "lttb", fields: ["t", "v"], n: 20}
          ] do
        {module, node} = step(node)
        {_, cache} = Cache.run(Cache.new(), module, node, table, %{})
        {out, cache} = Cache.run(cache, module, node, applied, %{})
        assert cache.last == %{reused: 2, updated: 0, computed: 1}, inspect(node)
        assert Table.equal?(out, Step.run(module, node, applied, %{}))
      end
    end

    @tag verifies: "operations-cache-recompute"
    test "a group whose first row is removed recomputes its chunk" do
      table = table(rows(&rem(&1, 10)))
      {module, node} = step(%{op: "aggregate", field: "v", fn: "count", by: "id"})
      {_, cache} = Cache.run(Cache.new(), module, node, table, %{})

      # t 100 is group b's first row in the chunk [100, 200).
      first = apply!(table, retract: [row("b", 100, 0)])
      {out, after_} = Cache.run(cache, module, node, first, %{})
      assert after_.last == %{reused: 2, updated: 0, computed: 1}
      assert Table.equal?(out, Step.run(module, node, first, %{}))

      # t 103 is not: the chunk is updated, and the groups keep their order.
      later = apply!(table, retract: [row("b", 103, 3)], insert: [row("d", 150, 3)])
      {out, after_} = Cache.run(cache, module, node, later, %{})
      assert after_.last == %{reused: 2, updated: 1, computed: 0}
      assert Table.equal?(out, Step.run(module, node, later, %{}))
      assert Table.column(out, "id") == ~w(a b c d)
    end
  end

  describe "eviction" do
    @tag verifies: "operations-cache-prune"
    test "prune keeps the parts of held chunks, at their version or base version" do
      table = table(rows(&rem(&1, 10)))
      {module, node} = step(%{op: "aggregate", field: "v", fn: "count", by: "id"})
      {_, cache} = Cache.run(Cache.new(), module, node, table, %{})
      assert Cache.size(cache) == 3

      # A changed chunk adds its new version's part; its base's is kept for updates.
      changed = apply!(table, retract: [row("b", 103, 3)])
      {_, cache} = Cache.run(cache, module, node, changed, %{})
      assert Cache.size(cache) == 4
      assert Cache.size(Cache.prune(cache, [changed])) == 4

      # The oldest chunk leaves the window: its part goes.
      trimmed = Table.trim(changed, 100)
      assert Cache.size(Cache.prune(cache, [trimmed])) == 3

      # Compacted, the base version is the new digest: the old base's part goes.
      compacted = Table.compact(changed)
      assert Cache.size(Cache.prune(cache, [compacted])) == 3
    end
  end
end
