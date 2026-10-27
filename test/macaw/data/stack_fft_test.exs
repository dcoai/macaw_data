defmodule Macaw.Data.StackFFTTest do
  # The engines of `stack` and `spectrum` (spec/04 §4.8, §4.11), ported with visualize's
  # tests of them (`Shape.ArcStackTest`'s stack cases and `Data.FFTTest`): each expected
  # stack order is d3-shape 3.2.0's, run by hand as the comments show.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{FFT, Stack}
  alias Macaw.Data.Test.Work

  doctest Stack
  doctest FFT

  defp layout(stack, data) do
    stack
    |> Stack.generate(data)
    |> Enum.map(fn s -> {s.key, s.index, Enum.map(s.points, &{&1.y0, &1.y1})} end)
  end

  describe "Stack offsets" do
    @tag verifies: "operations-stack-orders"
    test "diverging stacks positives up and negatives down from zero, independently" do
      data = [%{a: 1, b: -2, c: 3}, %{a: -1, b: 2, c: -3}, %{a: 0, b: 1, c: -1}]
      stack = Stack.new() |> Stack.keys([:a, :b, :c]) |> Stack.offset(:diverging)

      assert layout(stack, data) == [
               {:a, 0, [{0, 1}, {-1, 0}, {0, 0}]},
               {:b, 1, [{-2, 0}, {0, 2}, {0, 1}]},
               {:c, 2, [{1, 4}, {-4, -1}, {-1, 0}]}
             ]
    end

    @tag verifies: "operations-stack-orders"
    test "wiggle is the streamgraph baseline, zero for one datum, and not silhouette" do
      # Hand-computed from d3's stackOffsetWiggle: baselines 0, -1.125, -0.925.
      data = [%{a: 1, b: 2}, %{a: 3, b: 1}, %{a: 2, b: 3}]
      base = Stack.new() |> Stack.keys([:a, :b])

      assert layout(Stack.offset(base, :wiggle), data) == [
               {:a, 0, [{0, 1}, {-1.125, 1.875}, {-0.925, 1.075}]},
               {:b, 1, [{1, 3}, {1.875, 2.875}, {1.075, 4.075}]}
             ]

      assert layout(Stack.offset(base, :wiggle), [%{a: 1, b: 2}]) == [
               {:a, 0, [{0, 1}]},
               {:b, 1, [{1, 3}]}
             ]

      refute layout(Stack.offset(base, :wiggle), data) ==
               layout(Stack.offset(base, :silhouette), data)
    end

    @tag verifies: "operations-stack-orders"
    test "silhouette centers on zero and expand normalizes each column" do
      data = [%{a: 1, b: 2}, %{a: 3, b: 1}]
      base = Stack.new() |> Stack.keys([:a, :b])

      assert layout(Stack.offset(base, :silhouette), data) ==
               [{:a, 0, [{-1.5, -0.5}, {-2.0, 1.0}]}, {:b, 1, [{-0.5, 1.5}, {1.0, 2.0}]}]

      assert layout(Stack.offset(base, :expand), data) ==
               [{:a, 0, [{0, 1 / 3}, {0, 0.75}]}, {:b, 1, [{1 / 3, 1.0}, {0.75, 1.0}]}]
    end
  end

  describe "Stack orders" do
    @tag verifies: "operations-stack-orders"
    test "a value accessor reads each datum's value by key" do
      series =
        Stack.new()
        |> Stack.keys([:a, :b])
        |> Stack.value(fn d, key -> 10 * Map.fetch!(d, key) end)
        |> Stack.generate([%{a: 1, b: 2}])

      assert Enum.map(series, &{hd(&1.points).y0, hd(&1.points).y1}) == [{0, 10}, {10, 30}]
    end

    @tag verifies: "operations-stack-orders"
    test "series come back in key order with index the stacking position" do
      data = [%{a: 1, b: 2}, %{a: 3, b: 1}]

      series =
        Stack.new() |> Stack.keys([:a, :b]) |> Stack.order(:reverse) |> Stack.generate(data)

      assert Enum.map(series, & &1.key) == [:a, :b]
      assert Enum.map(series, & &1.index) == [1, 0]
      # b is at the bottom; a sits on top of it.
      assert Enum.map(hd(series).points, & &1.y0) == Enum.map(List.last(series).points, & &1.y1)

      sums = [%{a: 5, b: 1, c: 3}]

      by = fn order ->
        Stack.new()
        |> Stack.keys([:a, :b, :c])
        |> Stack.order(order)
        |> Stack.generate(sums)
        |> Enum.map(&{&1.key, &1.index})
      end

      assert by.(:ascending) == [a: 2, b: 0, c: 1]
      assert by.(:descending) == [a: 0, b: 2, c: 1]
    end

    @tag verifies: "operations-stack-orders"
    test "a fixed order stacks exactly as listed, unlisted keys above in key order" do
      data = [%{a: 5, b: 1, c: 3}, %{a: 1, b: 9, c: 2}]
      stack = Stack.new() |> Stack.keys([:a, :b, :c]) |> Stack.order({:keys, [:b, :c, :a]})
      series = Stack.generate(stack, data)

      assert Enum.map(series, &{&1.key, &1.index}) == [a: 2, b: 0, c: 1]
      [a, b, c] = Enum.map(series, &Enum.map(&1.points, fn p -> {p.y0, p.y1} end))
      assert b == [{0, 1}, {0, 9}]
      assert c == [{1, 4}, {9, 11}]
      assert a == [{4, 9}, {11, 12}]

      # The same keys over other data keep the same places: no value is read.
      assert Enum.map(Stack.generate(stack, [%{a: 100, b: 0, c: 50}]), & &1.index) == [2, 0, 1]

      four = Stack.new() |> Stack.keys([:a, :b, :c, :d])

      by = fn order ->
        four
        |> Stack.order(order)
        |> Stack.generate([%{a: 1, b: 2, c: 3, d: 4}])
        |> Enum.map(&{&1.key, &1.index})
      end

      assert by.({:keys, [:x, :c]}) == [a: 1, b: 2, c: 0, d: 3]
      assert by.({:keys, [:d, :a, :d]}) == [a: 1, b: 2, c: 3, d: 0]
      assert by.({:keys, [:x]}) == by.(:none)
      assert by.({:keys, []}) == by.(:none)
    end

    defp inside_out(columns) do
      keys = Enum.map(columns, &elem(&1, 0))
      n = columns |> hd() |> elem(1) |> length()
      data = for j <- 0..(n - 1), do: Map.new(columns, fn {k, vs} -> {k, Enum.at(vs, j)} end)

      Stack.new()
      |> Stack.keys(keys)
      |> Stack.order(:insideout)
      |> Stack.generate(data)
      |> Enum.map(&{&1.key, &1.index})
    end

    @tag verifies: "operations-stack-orders"
    test "insideout is d3's stackOrderInsideOut" do
      # Peaks: b 0, d 1, e 2, a 3, c 4; sums a 13, b 10, c 8, d 11, e 9: c e b d a.
      assert inside_out(
               a: [1, 1, 1, 9, 1],
               b: [6, 1, 1, 1, 1],
               c: [1, 1, 1, 1, 4],
               d: [1, 7, 1, 1, 1],
               e: [1, 1, 5, 1, 1]
             ) == [a: 4, b: 2, c: 0, d: 3, e: 1]

      # One datum: every peak at 0, so appearance is key order and sums decide the side.
      assert inside_out(a: [5], b: [1], c: [3], d: [2]) == [a: 0, b: 1, c: 2, d: 3]

      # A tied peak keeps the first index, and tied peaks keep key order.
      assert inside_out(a: [2, 2, 0], b: [0, 3, 3], c: [1, 0, 1]) == [a: 0, b: 2, c: 1]

      # Sums are signed: a negative series lowers its side's total.
      assert inside_out(a: [4, 0], b: [-3, -1], c: [0, 2], d: [1, 0]) == [a: 0, b: 2, c: 3, d: 1]
    end
  end

  describe "Stack's cost (#126)" do
    # Counted in reductions, as the FFT's is: an offset indexing each column of each series
    # was quadratic, sixteen times the work for four times the rows.
    @tag verifies: "operations-stack-linear"
    test "four times the rows is under five times the work, for every offset and order" do
      data = fn n ->
        for i <- 0..(n - 1), do: %{a: rem(i * 7, 11) - 3, b: rem(i * 5, 13), c: rem(i, 4)}
      end

      for offset <- [:none, :expand, :silhouette, :wiggle, :diverging],
          order <- [:none, :insideout] do
        stack =
          Stack.new() |> Stack.keys([:a, :b, :c]) |> Stack.order(order) |> Stack.offset(offset)

        {small, _} = Work.reductions(fn -> Stack.generate(stack, data.(2_000)) end)
        {large, series} = Work.reductions(fn -> Stack.generate(stack, data.(8_000)) end)

        assert length(hd(series).points) == 8_000

        assert large < small * 5,
               "#{offset}/#{order}: 8000 rows cost #{Float.round(large / small, 2)}x 2000's reductions"
      end
    end
  end

  describe "FFT.fft/1" do
    @tag verifies: "operations-spectrum-lines"
    property "a pure sine of k cycles over N samples peaks at bin k, and Parseval holds" do
      check all(
              exponent <- integer(3..9),
              k <- integer(1..3),
              amplitude <- float(min: 0.5, max: 10.0),
              max_runs: 60
            ) do
        n = Integer.pow(2, exponent)
        k = min(k, div(n, 2) - 1)
        samples = for i <- 0..(n - 1), do: amplitude * :math.sin(2 * :math.pi() * k * i / n)
        terms = FFT.fft(samples)
        magnitudes = FFT.magnitudes(terms)

        assert length(terms) == n
        half = Enum.take(magnitudes, div(n, 2))
        assert Enum.max_by(Enum.with_index(half), &elem(&1, 0)) |> elem(1) == k

        energy = Enum.sum(Enum.map(samples, &(&1 * &1)))
        spectral = Enum.sum(Enum.map(magnitudes, &(&1 * &1))) / n
        assert_in_delta energy, spectral, 1.0e-9 * max(1.0, energy)
      end
    end

    @tag verifies: "operations-spectrum-lines"
    test "a constant is DC alone; a length that is not a power of two raises" do
      [{dc, dc_im} | rest] = FFT.fft(List.duplicate(2, 8))
      assert dc == 16.0 and dc_im == 0.0
      assert Enum.all?(rest, fn {re, im} -> abs(re) < 1.0e-12 and abs(im) < 1.0e-12 end)

      assert_raise ArgumentError, ~r/power of two/, fn -> FFT.fft([1, 2, 3]) end

      # The tapers: hann and hamming over five ones, and a sequence under four untapered.
      assert Enum.map(FFT.window([1, 1, 1, 1, 1], :hann), &Float.round(&1, 3)) == [
               0.0,
               0.5,
               1.0,
               0.5,
               0.0
             ]

      assert Enum.map(FFT.window([1, 1, 1, 1, 1], :hamming), &Float.round(&1, 3)) == [
               0.08,
               0.54,
               1.0,
               0.54,
               0.08
             ]

      assert FFT.window([2, 2, 2], :hann) == [2.0, 2.0, 2.0]
    end
  end

  describe "FFT.spectrum/3" do
    @tag verifies: "operations-spectrum-lines"
    test "reads a tone's amplitude at its frequency under every window" do
      every = 1 / 256
      values = for i <- 0..511, do: 3 * :math.sin(2 * :math.pi() * 32 * i * every)

      for window <- FFT.windows() do
        lines = FFT.spectrum(values, every, window: window)
        assert length(lines) == 256
        peak = Enum.max_by(lines, & &1.magnitude)
        assert peak.frequency == 32.0
        assert_in_delta peak.magnitude, 3.0, 0.01
      end

      offset = Enum.map(values, &(&1 + 40))
      assert Enum.at(FFT.spectrum(offset, every), 1).magnitude > 10
      flat = FFT.spectrum(offset, every, detrend: true)
      assert Enum.at(flat, 0).magnitude < 0.01 and Enum.at(flat, 1).magnitude < 0.01
      assert_in_delta Enum.max_by(flat, & &1.magnitude).magnitude, 3.0, 0.01

      # The newest power of two: 300 values take the last 256.
      assert FFT.spectrum(Enum.take(values, 300), every) |> length() == 128
      assert FFT.spectrum([1.0], every) == []
      assert_raise ArgumentError, ~r/samples/, fn -> FFT.spectrum(values, every, samples: 100) end
      assert_raise ArgumentError, ~r/window/, fn -> FFT.spectrum(values, every, window: :flat) end
    end

    # The cost's growth by count, not by clock: four times the samples is 4 · 12/10 = 4.8
    # times the work of an n log n transform and sixteen times a quadratic one's.
    @tag verifies: "operations-spectrum-lines"
    test "four times the samples is under six times the work" do
      values = fn n -> for i <- 0..(n - 1), do: :math.sin(i / 7) + rem(i * 7919, 101) / 100 end
      {small, _} = Work.reductions(fn -> FFT.spectrum(values.(1024), 0.01) end)
      {large, lines} = Work.reductions(fn -> FFT.spectrum(values.(4096), 0.01) end)

      assert length(lines) == 2048

      assert large < small * 6,
             "4096 points cost #{Float.round(large / small, 2)}x 1024's reductions"
    end
  end
end
