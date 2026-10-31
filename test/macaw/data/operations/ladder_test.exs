defmodule Macaw.Data.Operations.LadderTest do
  @moduledoc """
  `m4` and `lttb` on the bucket ladder (spec/04 §4.4, §4.5, §4.5.1; macaw_data#9 §5, #22):
  buckets `2^k` wide from origin 0 in the scale's space, levels with hysteresis, partials
  that merge across chunk edges and fold into coarser levels, and `lttb` as MinMaxLTTB
  held to the exact `Reduce.lttb/3` within its tolerance.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Native, Operations, Reduce, Table}
  alias Macaw.Data.Operations.Step
  alias Macaw.Data.Operations.Transforms.{Ladder, Lttb, M4}
  alias Macaw.Data.Operations.Transforms.Ladder.Packed
  alias Macaw.Data.Test.{Gen, Storage, Work}

  @registry Operations.registry()

  defp checked(node) do
    {:ok, [checked]} = Operations.validate(@registry, [node], %{})
    checked
  end

  defp run(table, node, context \\ %{}), do: Operations.apply!(@registry, [node], table, context)

  defp table(rows, type \\ :number) do
    Table.new!([
      {"t", type, Enum.map(rows, &elem(&1, 0))},
      {"v", :number, Enum.map(rows, &elem(&1, 1))},
      {"i", :number, Enum.to_list(0..(length(rows) - 1)//1)}
    ])
  end

  defp wave(n), do: for(i <- 0..(n - 1), do: {i, :math.sin(i / 37) * 10 + rem(i * 7919, 13)})

  describe "levels (spec/04 §4.5.1)" do
    @tag verifies: "operations-ladder-levels"
    test "the level is the coarsest whose bucket is at most the ideal width, kept within a factor of 2" do
      assert Ladder.level(8.0, nil) == 3
      assert Ladder.level(7.99, nil) == 2
      assert Ladder.level(0.3, nil) == -2
      assert Ladder.level(1.0e9, nil) == 29
      assert Ladder.level(nil, nil) == 0
      assert Ladder.level(nil, 4) == 4

      # Hysteresis: 2^2 is within a factor of 2 of 7.99 and of 8.0; 2^5 is not.
      assert Ladder.level(8.0, 2) == 2
      assert Ladder.level(15.9, 3) == 3
      assert Ladder.level(8.0, 5) == 3
      assert Ladder.level(4.0, 3) == 3
      assert Ladder.level(1.9, 3) == 0

      assert Ladder.bucket(17, 3) == 2
      assert Ladder.bucket(-1, 3) == -1
      assert Ladder.bucket(17, -1) == 34
      assert Ladder.bucket(2.75, -2) == 11
    end

    @tag verifies: "operations-ladder-levels"
    test "a span oscillating around a power of two keeps one level, and unchanged chunks keep their keys" do
      node = checked(%{op: "m4", fields: ["t", "v"], width: 10})
      rows = wave(4_000)

      # 10 columns over a span near 640: a quarter pixel near 16, level 4 at first (650).
      frames =
        for last <- [650, 630, 660, 625, 645, 638] do
          rows |> Enum.take(last + 1) |> table() |> Storage.chunked(64)
        end

      {levels, keys} =
        Enum.map_reduce(frames, nil, fn frame, previous ->
          context = if previous, do: %{level: previous}, else: %{}
          parts = Step.parts(M4, node, frame, context)
          level = hd(parts).context.level
          {{level, Enum.map(parts, & &1.key)}, level}
        end)
        |> elem(0)
        |> Enum.unzip()

      assert Enum.uniq(levels) == [4]

      # Each frame's whole 64-row chunks keep the keys they had a frame before.
      for [a, b] <- Enum.chunk_every(keys, 2, 1, :discard) do
        common = min(length(a), length(b)) - 1
        assert Enum.take(a, common) == Enum.take(b, common)
      end

      # Without the previous level, the frames would move between levels 4 and 3.
      assert Ladder.level(650 / 40, nil) == 4
      assert Ladder.level(630 / 40, nil) == 3
    end

    @tag verifies: "operations-ladder-levels"
    test "a zoom within a level keeps every key, and a zoom out folds finer partials exactly" do
      frame = wave(3_000) |> table() |> Storage.chunked(256)

      keys = fn width ->
        Enum.map(
          Step.parts(M4, checked(%{op: "m4", fields: ["t", "v"], width: width}), frame, %{
            level: 5
          }),
          & &1.key
        )
      end

      assert keys.(20) == keys.(24)

      bound = M4.bind(checked(%{op: "m4", fields: ["t", "v"], width: 20}), frame, %{})

      for {chunk, first, count} = view <- Table.chunks(frame),
          {from, to} <- [{2, 4}, {-1, 3}, {3, 3}] do
        _ = {chunk, first, count}
        fine = Ladder.partial(view, bound, from, "m4")
        assert Ladder.coarsen(fine, to) == Ladder.partial(view, bound, to, "m4")
      end

      # Partials at two levels merge at the coarser.
      [a, b | _] = Table.chunks(frame)

      assert Ladder.combine(Ladder.partial(a, bound, 2, "m4"), Ladder.partial(b, bound, 4, "m4")) ==
               Ladder.combine(
                 Ladder.partial(a, bound, 4, "m4"),
                 Ladder.partial(b, bound, 4, "m4")
               )
    end
  end

  describe "m4 on the ladder (spec/04 §4.5)" do
    # Exact M4 over the columns each bucket's start lies in: a run's first, last, least and
    # greatest rows per column, earliest on a tie, deduplicated, in input order.
    defp shifted_m4(rows, bound, width) do
      %{extent: {lo, hi}, level: k} = bound

      column = fn s ->
        s
        |> Ladder.bucket(k)
        |> Kernel.*(Ladder.pow2(k))
        |> Kernel.-(lo)
        |> Kernel./(hi - lo)
        |> Kernel.*(width)
        |> floor()
        |> max(0)
        |> min(width - 1)
      end

      rows
      |> Enum.with_index()
      |> Enum.group_by(fn {{s, _y}, _i} -> column.(s) end)
      |> Enum.flat_map(fn {_c, members} ->
        first = hd(members)
        last = List.last(members)
        low = Enum.min_by(members, fn {{_s, y}, _i} -> y end)
        high = Enum.max_by(members, fn {{_s, y}, _i} -> y end)
        Enum.map([first, last, low, high], &elem(&1, 1))
      end)
      |> Enum.uniq()
      |> Enum.sort()
    end

    @tag verifies: "operations-m4-ladder"
    test "linear, time and log: exact M4 over columns moved to the bucket edge, within a bucket" do
      raw = wave(5_000)

      for {scale, rows, type, space} <- [
            {:linear, raw, :number, fn t -> t end},
            {:time,
             Enum.map(raw, fn {t, v} ->
               {DateTime.add(~U[2026-01-01 00:00:00Z], t * 1_000, :millisecond), v}
             end), :time, &DateTime.to_unix(&1, :microsecond)},
            {:log, Enum.map(raw, fn {t, v} -> {t + 1, v} end), :number, &:math.log2/1}
          ] do
        input = table(rows, type)
        node = checked(%{op: "m4", fields: ["t", "v"], width: 37})
        bound = M4.bind(node, input, %{scale: scale})
        {lo, hi} = bound.extent
        assert Ladder.pow2(bound.level) <= (hi - lo) / 37 / 4

        expected = shifted_m4(Enum.map(rows, fn {t, v} -> {space.(t), v} end), bound, 37)
        kept = run(input, %{op: "m4", fields: ["t", "v"], width: 37}, %{scale: scale})
        assert Table.column(kept, "i") == expected

        for size <- [7, 1_000] do
          assert Table.equal?(
                   run(
                     Storage.chunked(input, size),
                     %{op: "m4", fields: ["t", "v"], width: 37},
                     %{scale: scale}
                   ),
                   kept
                 )
        end
      end
    end

    @tag verifies: "operations-m4-ladder"
    test "where the buckets' edges are the pixels', it is Reduce.m4 itself, however chunked" do
      rows = wave(1_025)
      input = table(rows)

      expected =
        rows
        |> Enum.with_index()
        |> Reduce.m4(32, fn {{t, v}, _i} -> {t, v} end)
        |> Enum.map(&elem(&1, 1))

      for size <- [1, 7, 100, :one] do
        kept = run(Storage.chunked(input, size), %{op: "m4", fields: ["t", "v"], width: 32})
        assert Table.column(kept, "i") == expected
      end
    end
  end

  describe "lttb as MinMaxLTTB (spec/04 §4.4)" do
    # The mean absolute error of a reduced line read at every input x, over the y extent.
    defp error(rows, kept) do
      {lo, hi} = rows |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
      segments = kept |> Enum.chunk_every(2, 1, :discard) |> List.to_tuple()

      {sum, _} =
        Enum.reduce(rows, {0, 0}, fn {x, y}, {sum, s} ->
          s = advance(segments, s, x)
          [{x0, y0}, {x1, y1}] = elem(segments, s)
          at = if x1 == x0, do: y0, else: y0 + (y1 - y0) * (x - x0) / (x1 - x0)
          {sum + abs(y - at), s}
        end)

      sum / length(rows) / (hi - lo)
    end

    defp advance(segments, s, x) do
      [_, {x1, _}] = elem(segments, s)
      if x > x1 and s + 1 < tuple_size(segments), do: advance(segments, s + 1, x), else: s
    end

    defp series_gen do
      gen all(
            kind <- member_of([:sine, :walk, :spikes]),
            seed <- integer(1..10_000),
            count <- integer(600..3_000)
          ) do
        :rand.seed(:exsss, {seed, seed, seed})

        case kind do
          :sine ->
            for i <- 0..(count - 1), do: {i, :math.sin(i / 90) * 10 + :rand.uniform() * 3}

          :walk ->
            Enum.scan(0..(count - 1), {0, 0.0}, fn i, {_, y} -> {i, y + :rand.normal()} end)

          :spikes ->
            for i <- 0..(count - 1),
                do: {i, if(:rand.uniform() < 0.01, do: 40.0, else: :rand.uniform())}
        end
      end
    end

    @tag verifies: "operations-lttb-minmax"
    property "within twice the exact algorithm's error plus 0.005, at most n rows, ends kept" do
      check all(rows <- series_gen(), n <- member_of([20, 60, 150]), max_runs: 25) do
        input = table(rows)
        kept = run(input, %{op: "lttb", fields: ["t", "v"], n: n})
        picked = Enum.map(Table.column(kept, "i"), &Enum.at(rows, &1))
        exact = Reduce.lttb(rows, n)

        assert error(rows, picked) <= 2 * error(rows, exact) + 0.005
        assert Table.size(kept) <= n
        assert hd(picked) == hd(rows) and List.last(picked) == List.last(rows)

        for size <- [7, 500] do
          assert Table.equal?(
                   run(Storage.chunked(input, size), %{op: "lttb", fields: ["t", "v"], n: n}),
                   kept
                 )
        end
      end
    end

    @tag verifies: "operations-lttb-minmax"
    test "the same rows every run, and n or fewer rows come back whole" do
      input = table(wave(2_000))
      node = %{op: "lttb", fields: ["t", "v"], n: 100}
      assert Table.equal?(run(input, node), run(input, node))
      assert Table.size(run(input, node)) == 100

      small = table(wave(40))
      assert Table.equal?(run(small, %{node | n: 40}), small)
    end
  end

  describe "merging partials (spec/04 §4.5.1; #39)" do
    @tag verifies: "operations-ladder-merge"
    test "a combine costs the chunks, not the buckets, and every grouping gives one partial" do
      frame = wave(4_000) |> table() |> Storage.chunked(2_000)
      [a, b] = Table.chunks(frame)
      bound = M4.bind(checked(%{op: "m4", fields: ["t", "v"], width: 20}), frame, %{})

      # Level 10: two or three buckets a chunk, bucket 1 straddling the edge (rows 1999 and
      # 2000); level 0: 2,000 a chunk.
      cost = fn k ->
        pa = Ladder.partial(a, bound, k, "m4")
        pb = Ladder.partial(b, bound, k, "m4")
        {reductions, _} = Work.reductions(fn -> Ladder.combine(pa, pb) end)
        reductions
      end

      few = cost.(10)
      many = cost.(0)
      assert abs(many - few) <= 20, "ten buckets #{few}, thousands #{many}"

      # Any tree over the same partials gives the same merged partial, so a cache may hold
      # merges of any grouping.
      seven = wave(3_000) |> table() |> Storage.chunked(431)

      for module <- [M4, Lttb] do
        node =
          if module == M4,
            do: checked(%{op: "m4", fields: ["t", "v"], width: 20}),
            else: checked(%{op: "lttb", fields: ["t", "v"], n: 50})

        bound = module.bind(node, seven, %{})
        partials = for view <- Table.chunks(seven), do: Ladder.partial(view, bound, 2, "m4")
        [first | rest] = partials
        left = Enum.reduce(rest, first, &Ladder.combine(&2, &1))
        right = partials |> Enum.reverse() |> Enum.reduce(&Ladder.combine/2)
        {front, back} = Enum.split(partials, 3)

        middle =
          Ladder.combine(
            Enum.reduce(front, &Ladder.combine(&2, &1)),
            Enum.reduce(back, &Ladder.combine(&2, &1))
          )

        assert left == right and left == middle
      end
    end

    # A merged partial's runs with every ref a row of the whole input: view `v`'s row `r`
    # is the rows of the views before it plus `r`.
    defp global_runs({_k, views, _pieces} = merged) do
      offsets = views |> Enum.scan(0, fn {_c, _f, n}, at -> at + n end) |> then(&[0 | &1])
      at = fn {v, r} -> Enum.at(offsets, v) + r end
      point = fn v, {r, s, y} -> {at.(if v, do: {v, r}, else: r), s, y} end

      for segment <- Ladder.runs(merged) do
        case segment do
          {:gap, ref} ->
            {:gap, at.(ref)}

          {:run, buckets} ->
            {:run,
             for {b, {v, {f, l, lo, hi}}} <- buckets do
               {b, {point.(v, f), point.(v, l), point.(v, lo), point.(v, hi)}}
             end}
        end
      end
    end

    @tag verifies: "operations-ladder-merge"
    test "a merged partial reads as one chunk's: runs and gaps joined, a straddled bucket merged" do
      rows = for {t, v} <- wave(900), do: {t, if(rem(t, 97) in [5, 6], do: nil, else: v)}
      input = table(rows)
      bound = %{x: "t", y: "v", x_name: "t", y_name: "v", kind: :linear}

      for k <- [0, 3, 6], size <- [7, 64, 211, 450] do
        merged =
          input
          |> Storage.chunked(size)
          |> Table.chunks()
          |> Enum.map(&Ladder.partial(&1, bound, k, "m4"))
          |> Enum.reduce(&Ladder.combine(&2, &1))

        [one] = input |> Storage.chunked(:one) |> Table.chunks()
        assert global_runs(merged) == global_runs(Ladder.partial(one, bound, k, "m4"))
      end
    end

    @tag verifies: "operations-ladder-merge"
    property "rows whose x is out of order answer m4 and lttb as over one chunk" do
      check all(
              seed <- integer(1..10_000),
              count <- integer(50..600),
              size <- member_of([1, 7, 64, 211]),
              max_runs: 30
            ) do
        :rand.seed(:exsss, {seed, seed, seed})
        # A shuffled x with repeats, and an occasional gap.
        rows =
          for _ <- 1..count do
            t = :rand.uniform(count)
            v = if :rand.uniform() < 0.03, do: nil, else: :rand.normal() * 10
            {t, v}
          end

        input = table(rows)

        for node <- [
              %{op: "m4", fields: ["t", "v"], width: 13},
              %{op: "lttb", fields: ["t", "v"], n: 17}
            ] do
          whole = run(Storage.chunked(input, :one), node)
          assert Table.equal?(run(Storage.chunked(input, size), node), whole), "#{node.op}"
        end
      end
    end
  end

  describe "a chunk's partial in one pass (spec/04 §4.5.1; #41)" do
    # The partial as the ladder defines it: rows split into runs by gaps (each run of gap
    # rows its first row), each run's rows grouped by bucket floor(s / 2^k), computed
    # exactly, each bucket's first and last row and its least and greatest y, the earlier
    # on a tie, ascending by bucket.
    defp defined(xs, ys, bound, k) do
      rows = Enum.zip([xs, ys, 0..(length(xs) - 1)//1])

      rows
      |> Enum.chunk_by(fn {x, y, _i} -> x == nil or y == nil end)
      |> Enum.map(fn
        [{x, y, i} | _] when x == nil or y == nil ->
          {:gap, i}

        run ->
          buckets =
            run
            |> Enum.map(fn {x, y, i} ->
              s = Ladder.space(x, bound, "m4")
              {exact_bucket(s, k), {i, s, y}}
            end)
            |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
            |> Enum.map(fn {b, points} ->
              {b,
               {List.first(points), List.last(points), Enum.min_by(points, &elem(&1, 2)),
                Enum.max_by(points, &elem(&1, 2))}}
            end)
            |> Enum.sort()

          {:run, buckets}
      end)
    end

    defp exact_bucket(s, k) when is_integer(s) and k >= 0, do: Integer.floor_div(s, 2 ** k)
    defp exact_bucket(s, k) when is_integer(s), do: s * 2 ** -k
    defp exact_bucket(s, k), do: floor(s / if(k >= 0, do: 2 ** k, else: :math.pow(2, k)))

    @tag verifies: "operations-ladder-walk"
    property "a chunk's partial equals the one the ladder defines, on every scale" do
      check all(
              kind <- member_of([:linear, :time, :log]),
              k <- integer(-4..8),
              rows <-
                list_of(
                  tuple(
                    {frequency([
                       {6, integer(1..5_000)},
                       {3, Gen.float(min: 0.5, max: 5_000.0)},
                       {1, constant(nil)}
                     ]),
                     frequency([
                       {8, Gen.float(min: -100.0, max: 100.0)},
                       {2, integer(-5..5)},
                       {1, constant(nil)}
                     ])}
                  ),
                  min_length: 1,
                  max_length: 300
                ),
              sorted? <- boolean(),
              max_runs: 300
            ) do
        rows = if sorted?, do: Enum.sort_by(rows, &(elem(&1, 0) || 0)), else: rows
        {xs, ys} = Enum.unzip(rows)

        input =
          Table.new!([
            {"t", :number, xs},
            {"v", :number, ys}
          ])

        [view] = Table.chunks(input)
        bound = %{x: "t", y: "v", x_name: "t", y_name: "v", kind: kind}

        for x <- xs, x != nil do
          s = Ladder.space(x, bound, "m4")
          assert Ladder.bucket(s, k) == exact_bucket(s, k)
        end

        assert Ladder.partial(view, bound, k, "m4") ==
                 {k, [view], [{0, Packed.pack(defined(xs, ys, bound, k))}]}
      end
    end

    @tag verifies: "operations-ladder-walk"
    test "a sorted chunk of integer x and float y costs at most 12 reductions a row, and 1.5 a bucket packed" do
      n = Table.chunk_rows()
      input = table(for i <- 0..(n - 1), do: {i * 3, :math.sin(i / 50) * 100})
      [view] = Table.chunks(input)
      bound = %{x: "t", y: "v", x_name: "t", y_name: "v", kind: :linear}

      # The Elixir walk's work, whatever the kernels: at level 0 every row is a bucket of
      # its own, the most packing a chunk does.
      for k <- [0, 4, 9] do
        {reductions, {_k, _views, [{0, piece}]}} =
          Work.reductions(fn -> Native.elixir(fn -> Ladder.partial(view, bound, k, "m4") end) end)

        buckets = for {:run, run} <- Packed.unpack(piece), reduce: 0, do: (b -> b + length(run))
        budget = 12 * n + div(3 * buckets, 2)
        assert reductions <= budget, "#{reductions} reductions for #{n} rows at level #{k}"
      end
    end
  end

  describe "gaps at chunk edges (spec/04 §4.5.1)" do
    @tag verifies: "operations-ladder-gaps"
    test "a gap on a chunk boundary survives m4 and lttb, as over one chunk" do
      # Rows 100 and 101 are a gap: 100 ends a chunk of 101 rows, 101 starts the next.
      rows = for {t, v} <- wave(400), do: {t, if(t in [100, 101], do: nil, else: v)}
      input = table(rows)

      for node <- [
            %{op: "m4", fields: ["t", "v"], width: 20},
            %{op: "lttb", fields: ["t", "v"], n: 30}
          ] do
        whole = run(Storage.chunked(input, :one), node)
        gaps = for {nil, i} <- Enum.zip(Table.column(whole, "v"), Table.column(whole, "i")), do: i
        assert gaps == [100]

        for size <- [101, 100, 7, 1] do
          assert Table.equal?(run(Storage.chunked(input, size), node), whole),
                 "#{node.op} at #{size}"
        end
      end
    end
  end
end
