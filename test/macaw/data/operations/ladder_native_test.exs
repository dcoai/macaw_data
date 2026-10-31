defmodule Macaw.Data.Operations.LadderNativeTest do
  # The ladder partial's native kernel (spec/04 §4.5.2): its piece equals the Elixir walk's,
  # term for term, on every form and kind it reads, and on the edges where it hands the
  # view back. Without the kernels both sides are the Elixir walk.
  use ExUnit.Case, async: true
  use ExUnitProperties

  # The walk's raises, run in processes of their own (`outcome/1`), are logged there.
  @moduletag :capture_log

  alias Macaw.Data.{Native, Table}
  alias Macaw.Data.Native.Kernels
  alias Macaw.Data.Operations.Transforms.Ladder
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Test.{Gen, Work}

  @epoch ~U[1970-01-01 00:00:00.000000Z]
  @forms [:int, :float, :utc, :naive, :zoned, :date]

  # An x reading of each form the kernel reads, from an integer `i`.
  defp x_of(:int, i), do: i
  defp x_of(:float, i), do: i * 0.37 - 400.0
  defp x_of(:utc, i), do: DateTime.add(@epoch, i * 7_919_311, :microsecond)
  defp x_of(:naive, i), do: @epoch |> DateTime.add(i * 3_001, :millisecond) |> DateTime.to_naive()
  defp x_of(:date, i), do: Date.add(~D[1969-12-01], i)

  # A zoned instant, five hours east of UTC: its wall clock built from the UTC instant.
  defp x_of(:zoned, i) do
    utc = DateTime.add(@epoch, i * 1_000_003, :microsecond)
    wall = NaiveDateTime.add(DateTime.to_naive(utc), 18_000)

    %DateTime{
      year: wall.year,
      month: wall.month,
      day: wall.day,
      hour: wall.hour,
      minute: wall.minute,
      second: wall.second,
      microsecond: wall.microsecond,
      time_zone: "Etc/GMT-5",
      zone_abbr: "+05",
      utc_offset: 18_000,
      std_offset: 0,
      calendar: Calendar.ISO
    }
  end

  defp type_of(form) when form in [:int, :float], do: :number
  defp type_of(_form), do: :time

  # A view of one chunk's rows from `offset`, so the kernel reads its buffers past a first
  # slot.
  defp view(xs, ys, form, offset) do
    table = Table.new!([{"t", type_of(form), xs}, {"v", :number, ys}])
    [{chunk, 0, n}] = Table.chunks(table)
    {chunk, offset, n - offset}
  end

  defp bound(kind), do: %{x: "t", y: "v", x_name: "t", y_name: "v", kind: kind}

  # What `fun` answers, or the exception it raises, run in a process of its own: where the
  # walk raises (a level past a float's powers of two), the kernel must hand the view back
  # so the same exception is raised.
  defp outcome(fun) do
    {pid, ref} = spawn_monitor(fn -> exit({:answered, fun.()}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:answered, answer}} -> {:answered, answer}
      {:DOWN, ^ref, :process, ^pid, {exception, _stack}} -> {:raised, exception}
    end
  end

  # The kernel called on the view as `Ladder.partial/4` calls it.
  defp kernel({chunk, first, count}, kind, k) do
    {xf, xd, xv} =
      case Chunk.packed(chunk, "t") do
        {:int64, d, v} -> {0, d, v}
        {:float64, d, v} -> {1, d, v}
        {:date, d, v} -> {3, d, v}
        tuple -> {2, elem(tuple, 1), elem(tuple, 2)}
      end

    {yf, yd, yv} =
      case Chunk.packed(chunk, "v") do
        {:int64, d, v} -> {0, d, v}
        {:float64, d, v} -> {1, d, v}
      end

    kd = if kind == :time, do: 1, else: 0
    Kernels.ladder(xf, xd, xv, yf, yd, yv, first, count, kd, k)
  end

  # The property's runs, and the most reductions generating all their cases may cost:
  # 12,000,000, measured 9,609,000 (macaw_data#68). The property's body adds about 6.3
  # million over its 400 cases, a case's walk at most about 25,000. With StreamData's own
  # `float(min:, max:)` the same cases cost 975,170,667 reductions to generate, 99 % of the
  # property, which took 17 to 32 s on a loaded host and met ExUnit's 60 s timeout at load
  # 45: that float's cost grows with the generation size, and the size grows with the run
  # (Macaw.Data.Test.Gen). Its work is bounded, so it needs no timeout of its own.
  @runs 400
  @generation 12_000_000

  # A case: an x form and kind, a level, rows with gaps, and how they are laid out.
  defp cases do
    gen all(
          form <- member_of(@forms),
          kind <- member_of([:linear, :time]),
          k <- one_of([integer(-8..24), member_of([-1100, -70, -40, 40, 63, 70, 1100])]),
          rows <-
            list_of(
              tuple(
                {frequency([{8, integer(-2_000..20_000)}, {1, constant(nil)}]),
                 frequency([{6, Gen.float(min: -100.0, max: 100.0)}, {1, constant(nil)}])}
              ),
              min_length: 1,
              max_length: 400
            ),
          int_y? <- boolean(),
          sorted? <- boolean(),
          offset <- integer(0..9)
        ) do
      {form, kind, k, rows, int_y?, sorted?, offset}
    end
  end

  describe "the property's own work" do
    test "generating its cases costs a stated count of reductions, whatever the box's load" do
      # One case at each size the property reaches, its run index, from fixed seeds: what
      # the property generates, counted rather than timed.
      {work, lengths} =
        Work.reductions(fn ->
          for size <- 1..@runs do
            [{_, _, _, rows, _, _, _}] =
              cases() |> StreamData.resize(size) |> StreamData.seeded(size) |> Enum.take(1)

            length(rows)
          end
        end)

      assert Enum.max(lengths) > 300, "the largest case has #{Enum.max(lengths)} rows"
      assert work <= @generation, "generating #{@runs} cases cost #{work} reductions"
    end
  end

  describe "the kernel against the Elixir walk" do
    @tag verifies: "operations-ladder-native-identical"
    property "on every x form, both kinds, gaps, unsorted x and levels far either side of 0" do
      check all({form, kind, k, rows, int_y?, sorted?, offset} <- cases(), max_runs: @runs) do
        rows = if sorted?, do: Enum.sort_by(rows, &(elem(&1, 0) || 0)), else: rows
        rows = List.duplicate({1, 1.0}, offset) ++ rows
        xs = for {i, _} <- rows, do: i && x_of(form, i)
        ys = for {_, y} <- rows, do: if(int_y? and y, do: round(y), else: y)
        v = view(xs, ys, form, offset)

        expected = outcome(fn -> Ladder.partial_elixir(v, bound(kind), k, "m4") end)
        assert outcome(fn -> Ladder.partial(v, bound(kind), k, "m4") end) == expected

        # Within a float's exact powers of two and int64, the kernel itself answered.
        if Native.loaded?() and k in -8..24 do
          {:answered, {^k, [^v], [{0, segments}]}} = expected
          assert kernel(v, kind, k) == segments
        end
      end
    end

    @tag verifies: "operations-ladder-native-identical"
    test "an x past int64 once scaled, or a level past a float's powers, is handed back" do
      big = Table.new!([{"t", :number, [4_000_000_000_000_000, 5]}, {"v", :number, [1.0, 2.0]}])
      [v] = Table.chunks(big)

      assert Ladder.partial(v, bound(:time), 0, "m4") ==
               Ladder.partial_elixir(v, bound(:time), 0, "m4")

      assert Ladder.partial(v, bound(:linear), -70, "m4") ==
               Ladder.partial_elixir(v, bound(:linear), -70, "m4")

      if Native.loaded?() do
        assert kernel(v, :time, 0) == :fallback
        assert kernel(v, :linear, -70) == :fallback
        assert kernel(v, :linear, 0) != :fallback
      end
    end
  end

  describe "the call's bound" do
    @tag verifies: "operations-ladder-native-bound"
    test "a sync_rows call stays under 1 ms at its largest answer, and a larger view runs dirty with the same answer" do
      n = Native.sync_rows()
      rows = for i <- 0..(2 * n), do: %{"t" => i * 3, "v" => :math.sin(i / 50) * 100}
      {:ok, chunk} = Chunk.of_rows([{"t", :number}, {"v", :number}], rows, nil)
      sync = {chunk, 0, n}
      dirty = {chunk, 0, 2 * n + 1}

      for v <- [sync, dirty], k <- [0, 4] do
        assert Ladder.partial(v, bound(:linear), k, "m4") ==
                 Ladder.partial_elixir(v, bound(:linear), k, "m4")
      end

      # At level 0 every row of x = 3i is a bucket of its own: the largest answer a call
      # builds, so its slowest.
      if Native.loaded?() do
        for _ <- 1..5, do: kernel(sync, :linear, 0)
        # The least of 21: the call's own cost, not the box's load around it.
        times = for _ <- 1..21, do: elem(:timer.tc(fn -> kernel(sync, :linear, 0) end), 0)
        least = Enum.min(times)
        assert least < 1_000, "a #{n}-row call took #{least} µs"
      end
    end
  end
end
