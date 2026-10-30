defmodule Macaw.Data.Operations.FinishNativeTest do
  # m4's and lttb's finishes in a native kernel (spec/04 §4.5.4): over the merged packed
  # pieces, their refs equal the Elixir path's (`M4.refs/3`, `Lttb.refs/2`), every chunking,
  # form, scale and level, gaps and unsorted x included; where it can't answer exactly it
  # hands the partial back. Without the kernels both sides are the Elixir path.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Native, Operations, Table}
  alias Macaw.Data.Native.Kernels
  alias Macaw.Data.Operations.Transforms.{Ladder, Lttb, M4}
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Test.Storage

  @registry Operations.registry()
  @epoch ~U[1970-01-01 00:00:00.000000Z]

  defp checked(node) do
    {:ok, [checked]} = Operations.validate(@registry, [node], %{})
    checked
  end

  defp x_of(:int, i), do: i * 3
  defp x_of(:float, i), do: i * 0.37 - 40.0
  defp x_of(:positive, i), do: i * 0.37 + 0.5
  defp x_of(:utc, i), do: DateTime.add(@epoch, i * 7_919_311, :microsecond)

  defp type_of(:utc), do: :time
  defp type_of(_form), do: :number

  # The merged partial `finish/3` reads: each chunk's partial combined in chunk order and
  # coarsened to the step's level.
  defp merged(module, node, input, context) do
    bound = module.bind(node, input, context)

    merged =
      input
      |> Table.chunks()
      |> Enum.map(&module.chunk(node, &1, bound))
      |> Enum.reduce(&Ladder.combine(&2, &1))

    {Ladder.coarsen(merged, max(elem(merged, 0), bound.level)), bound}
  end

  defp rows_gen do
    list_of(
      tuple(
        {frequency([{12, integer(0..3_000)}, {1, constant(nil)}]),
         frequency([{10, float(min: -100.0, max: 100.0)}, {1, constant(nil)}])}
      ),
      min_length: 2,
      max_length: 700
    )
  end

  describe "the finishes against the Elixir path" do
    @tag verifies: "operations-ladder-finish-identical"
    property "m4's columns and lttb's selection: the same refs, every form, scale, chunking and level" do
      check all(
              {form, scale} <-
                member_of([
                  {:int, "linear"},
                  {:int, "time"},
                  {:float, "linear"},
                  {:float, "time"},
                  {:utc, "linear"},
                  {:utc, "time"},
                  {:positive, "log"}
                ]),
              rows <- rows_gen(),
              sorted? <- boolean(),
              int_y? <- boolean(),
              size <- member_of([:one, 7, 64, 211]),
              width <- member_of([1, 3, 17, 200]),
              n <- member_of([3, 5, 40, 400]),
              level <- one_of([constant(nil), integer(-6..12)]),
              max_runs: 150
            ) do
        rows = if sorted?, do: Enum.sort_by(rows, &(elem(&1, 0) || 0)), else: rows
        xs = for {i, _} <- rows, do: i && x_of(form, i)
        ys = for {_, y} <- rows, do: if(int_y? and y, do: round(y * 1000), else: y)

        input =
          Table.new!([{"t", type_of(form), xs}, {"v", :number, ys}]) |> Storage.chunked(size)

        context = if level, do: %{scale: scale, level: level}, else: %{scale: scale}

        m4 = checked(%{op: "m4", fields: ["t", "v"], width: width})
        {m, bound} = merged(M4, m4, input, context)
        elixir = M4.refs(m, bound.extent, width)
        native = Ladder.m4_native(m, bound.extent, width)
        if Native.loaded?(), do: assert(native != :fallback)
        if native != :fallback, do: assert(:lists.usort(native) == :lists.usort(elixir))

        lttb = checked(%{op: "lttb", fields: ["t", "v"], n: n})
        {l, bound} = merged(Lttb, lttb, input, context)

        unless bound.whole? do
          elixir = Lttb.refs(l, n)
          native = Ladder.lttb_native(l, n)
          if Native.loaded?(), do: assert(native != :fallback)
          if native != :fallback, do: assert(native == elixir)
        end

        # The steps themselves, with and without the kernels.
        for node <- [m4, lttb] do
          run = fn -> Operations.apply!(@registry, [node], input, context) end
          assert Table.equal?(run.(), Native.elixir(run))
        end
      end
    end

    @tag verifies: "operations-ladder-finish-identical"
    test "the kernels answer the common forms, and hand back what they can't answer exactly" do
      input =
        Table.new!([
          {"t", :number, Enum.to_list(0..999)},
          {"v", :number, Enum.map(0..999, &(&1 * 0.5))}
        ])

      m4 = checked(%{op: "m4", fields: ["t", "v"], width: 10})
      {m, bound} = merged(M4, m4, input, %{})

      if Native.loaded?() do
        assert is_list(Ladder.m4_native(m, bound.extent, 10))

        assert is_list(
                 Ladder.lttb_native(
                   elem(
                     merged(Lttb, checked(%{op: "lttb", fields: ["t", "v"], n: 9}), input, %{}),
                     0
                   ),
                   9
                 )
               )

        # A piece kept as a term (its points of mixed types) is the Elixir path's.
        {k, views, [{v, _piece} | rest]} = m
        p = {0, 1, 2.0}
        mixed = Ladder.Packed.pack([{:run, [{0, {p, {1, 1, 2}, p, p}}]}])
        assert Ladder.m4_native({k, views, [{v, mixed} | rest]}, bound.extent, 10) == :fallback
        assert Ladder.lttb_native({k, views, [{v, mixed} | rest]}, 9) == :fallback

        # An extent past int64 is too.
        assert Ladder.m4_native(m, {0, 2 ** 70}, 10) == :fallback
      end

      # Integer y at int64's ends: a difference past int64 is the Elixir path's, and the
      # step's answer is the same either way.
      top = 0x7FFF_FFFF_FFFF_FFFF
      ys = for i <- 0..999, do: if(rem(i, 2) == 0, do: top - i, else: -top + i)
      wide = Table.new!([{"t", :number, Enum.to_list(0..999)}, {"v", :number, ys}])

      for node <- [
            checked(%{op: "m4", fields: ["t", "v"], width: 10}),
            checked(%{op: "lttb", fields: ["t", "v"], n: 9})
          ] do
        run = fn -> Operations.apply!(@registry, [node], wide) end
        assert Table.equal?(run.(), Native.elixir(run))
      end

      if Native.loaded?() do
        {l, _bound} = merged(Lttb, checked(%{op: "lttb", fields: ["t", "v"], n: 9}), wide, %{})
        assert Ladder.lttb_native(l, 9) == :fallback
      end
    end
  end

  describe "the call's bound" do
    @tag verifies: "operations-ladder-finish-bound"
    test "a finish over the buckets a normal scheduler takes stays under 1 ms, and a larger runs dirty" do
      n = Native.finish_buckets()
      rows = for i <- 0..(8 * n + 3), do: %{"t" => i, "v" => :math.sin(i / 3) * 100}
      {:ok, chunk} = Chunk.of_rows([{"t", :number}, {"v", :number}], rows, nil)

      # Level 2: four rows a bucket, so each bucket's least and greatest are two rows, two
      # candidates a bucket for lttb's selection, its slowest; n buckets in the sync call.
      bound = %{x: "t", y: "v", x_name: "t", y_name: "v", kind: :linear}
      sync = Ladder.partial({chunk, 0, 4 * n}, bound, 2, "m4")
      dirty = Ladder.partial({chunk, 0, 8 * n + 4}, bound, 2, "m4")
      assert Native.finish_scheduler(n) == :normal and Native.finish_scheduler(2 * n) == :dirty

      for p <- [sync, dirty] do
        native = Ladder.m4_native(p, {0, 8 * n}, 1000)

        if Native.loaded?(),
          do: assert(:lists.usort(native) == :lists.usort(M4.refs(p, {0, 8 * n}, 1000)))

        native = Ladder.lttb_native(p, 1000)
        if Native.loaded?(), do: assert(native == Lttb.refs(p, 1000))
      end

      if Native.loaded?() do
        {_k, _views, pieces} = sync

        for call <- [
              fn -> Kernels.m4_finish(pieces, 2, 1, 0, 8 * n, 1000) end,
              fn -> Kernels.lttb_finish(pieces, 1000) end
            ] do
          for _ <- 1..5, do: call.()
          least = Enum.min(for _ <- 1..21, do: elem(:timer.tc(call), 0))
          assert least < 1_000, "a #{n}-bucket finish took #{least} µs"
        end
      end
    end
  end
end
