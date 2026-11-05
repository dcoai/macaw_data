defmodule Macaw.Data.EnginesNeverRaiseTest do
  @moduledoc """
  The engines a caller may call directly answer numbers past a float's range, and a list of
  the wrong shape, as values (spec/00 §5, spec/04 §4.4, §4.11, macaw_data#192). The steps hold
  their own bounds; these are the same arithmetic reached without a step.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Error, FFT, Reduce, Stack}

  @extreme [
    1.0e308,
    -1.0e308,
    1.7976931348623157e308,
    -1.7976931348623157e308,
    8.98846567431158e307,
    1.0e154,
    -1.0e154,
    5.0e-324,
    -5.0e-324,
    10 ** 308,
    -(10 ** 308),
    10 ** 400,
    -(10 ** 400),
    0,
    0.0,
    1,
    -1
  ]

  defp reading, do: one_of([member_of(@extreme), float(), integer()])
  defp pair, do: tuple({reading(), reading()})

  # A list of the wrong shape as well as of extreme numbers, a term of no kind among them.
  defp elements(element) do
    one_of([
      list_of(element, max_length: 40),
      list_of(one_of([element, constant(nil), constant(:a), constant({1, 2, 3})]),
        max_length: 40
      ),
      map(list_of(element, min_length: 1, max_length: 8), &improper/1)
    ])
  end

  defp improper(list), do: Enum.reduce(Enum.reverse(list), :tail, &[&1 | &2])

  # Answers a value, and its twin answers that value alone or raises exactly its reason.
  defp assert_answers(call, twin) do
    case call.() do
      {:ok, value} ->
        assert twin.() == value

      {:error, reason} ->
        error = assert_raise Error, twin
        assert error.reason == reason
    end
  end

  describe "each call #192 reported" do
    @tag verifies: "data-errors-readers"
    test "Reduce answers an overflow, and its twin raises it" do
      points = [{1.0e308, 1.0e308}, {-1.0e308, -1.0e308}, {1.0e308, 1.0e308}, {-1.0e308, 1.0e308}]

      assert Reduce.lttb(points, 3) == {:error, {:values, :overflow}}
      assert Reduce.m4([{1.0e308, 1}, {-1.0e308, 2}], 2) == {:error, {:values, :overflow}}

      assert %Error{reason: {:values, :overflow}} =
               assert_raise(Error, fn -> Reduce.lttb!(points, 3) end)

      assert_raise Error, ~r/float's range/, fn ->
        Reduce.m4!([{1.0e308, 1}, {-1.0e308, 2}], 2)
      end
    end

    @tag verifies: "data-errors-readers"
    test "FFT answers an overflow, and its twin raises it" do
      assert FFT.fft([1.0e308, 1.0e308]) == {:error, {:values, :overflow}}
      assert FFT.magnitudes([{1.0e308, 1.0e308}]) == {:error, {:values, :overflow}}
      assert FFT.window([10 ** 400], :none) == {:error, {:values, :overflow}}

      assert_raise Error, fn -> FFT.fft!([1.0e308, 1.0e308]) end
      assert_raise Error, fn -> FFT.magnitudes!([{1.0e308, 1.0e308}]) end
      assert_raise Error, fn -> FFT.window!([10 ** 400], :none) end
    end
  end

  describe "the wrong shape" do
    @tag verifies: "data-errors-readers"
    test "Reduce names the argument at fault" do
      assert Reduce.lttb([{0, 0} | :b], 3) == {:error, {:data, :list}}
      assert Reduce.lttb(:nope, 3) == {:error, {:data, :list}}
      assert Reduce.lttb([1, 2, 3, 4], 3) == {:error, {:data, :pair}}
      assert Reduce.lttb([{0, 0}], 2) == {:error, {:n, 2}}
      assert Reduce.lttb([{0, 0}], 3.0) == {:error, {:n, 3.0}}
      assert Reduce.lttb([{0, 0}], 3, :get) == {:error, {:accessor, :get}}

      assert Reduce.m4([{0, 0} | :b], 3) == {:error, {:data, :list}}
      assert Reduce.m4([1], 3) == {:error, {:data, :pair}}
      assert Reduce.m4([{0, 1}], 0) == {:error, {:width, 0}}
      assert Reduce.m4([{0, 1}], 10 ** 400) == {:error, {:width, 10 ** 400}}
      assert Reduce.m4([{0, 1}], 1, :get) == {:error, {:accessor, :get}}

      assert Reduce.format_error({:data, :list}) =~ "proper list"
      assert Reduce.format_error({:data, :pair}) =~ "pair"
      assert Reduce.format_error({:width, 0}) =~ "width"
      assert Reduce.format_error({:accessor, :get}) =~ "accessor"
    end

    @tag verifies: "data-errors-readers"
    test "FFT names the argument at fault" do
      assert FFT.fft([1, 2 | 3]) == {:error, {:values, :number}}
      assert FFT.spectrum([1, 2 | 3], 1) == {:error, {:values, :number}}
      assert FFT.spectrum([1, 2], 1, [{:window, :none} | :b]) == {:error, {:opts, :keyword}}
      assert FFT.magnitudes([{1, 2} | :b]) == {:error, {:values, :number}}
      assert FFT.magnitudes([1]) == {:error, {:values, :number}}
      assert FFT.window([1 | 2], :none) == {:error, {:values, :number}}
      assert FFT.window([:a], :none) == {:error, {:values, :number}}
      assert FFT.window([1], :flat) == {:error, {:window, :flat}}
      assert FFT.format_error({:opts, :keyword}) =~ "keyword"
    end
  end

  describe "what a float holds answers as it did" do
    @tag verifies: "data-errors-readers"
    test "just inside each bound" do
      assert {:ok, [_, _]} = FFT.fft([3.0e307, 3.0e307])
      assert FFT.magnitudes([{1.0e154, 0.0}]) == {:ok, [1.0e154]}

      assert {:ok, [_, _, _]} =
               Reduce.lttb([{1, 1.0e300}, {2, -1.0e300}, {3, 1.0e300}, {4, 0}], 3)

      assert {:ok, [_, _]} = Reduce.m4([{7.0e307, 1}, {-7.0e307, 2}], 2)
      assert FFT.window([1.0e308], :none) == {:ok, [1.0e308]}
    end

    @tag verifies: "data-errors-readers"
    test "n or fewer elements are not read, as before" do
      assert Reduce.lttb([1, :a], 3) == {:ok, [1, :a]}
    end
  end

  describe "no engine raises" do
    @tag verifies: "data-errors-readers"
    property "Reduce.lttb/3 and m4/3 over extreme pairs and wrong shapes" do
      check all(data <- elements(pair()), n <- integer(-1..8), width <- integer(-1..8)) do
        assert_answers(fn -> Reduce.lttb(data, n) end, fn -> Reduce.lttb!(data, n) end)
        assert_answers(fn -> Reduce.m4(data, width) end, fn -> Reduce.m4!(data, width) end)
      end
    end

    @tag verifies: "data-errors-readers"
    property "FFT.fft/1, magnitudes/1 and window/2 over extreme terms and wrong shapes" do
      check all(
              data <- elements(one_of([reading(), pair()])),
              power <- integer(0..4),
              terms <- list_of(one_of([reading(), pair()]), length: 2 ** power),
              kind <- member_of([:hann, :hamming, :none, :flat])
            ) do
        for sequence <- [data, terms] do
          assert_answers(fn -> FFT.fft(sequence) end, fn -> FFT.fft!(sequence) end)
          assert_answers(fn -> FFT.magnitudes(sequence) end, fn -> FFT.magnitudes!(sequence) end)

          assert_answers(fn -> FFT.window(sequence, kind) end, fn ->
            FFT.window!(sequence, kind)
          end)
        end
      end
    end

    @tag verifies: "data-errors-readers"
    property "FFT.spectrum/3 over extreme readings, intervals and wrong shapes" do
      check all(
              values <- elements(reading()),
              every <- reading(),
              opts <- member_of([[], [detrend: true], [window: :none], [{:samples, 2} | :b]])
            ) do
        assert_answers(fn -> FFT.spectrum(values, every, opts) end, fn ->
          FFT.spectrum!(values, every, opts)
        end)
      end
    end

    @tag verifies: "data-errors-readers"
    property "Stack.stacked/2 and generate/2 over extreme readings, every offset and order" do
      check all(
              rows <- list_of(fixed_map(%{"a" => reading(), "b" => reading()}), max_length: 12),
              offset <- member_of([:none, :expand, :silhouette, :wiggle, :diverging]),
              order <- member_of([:none, :ascending, :descending, :insideout, :reverse])
            ) do
        stack =
          Stack.new() |> Stack.keys(["a", "b"]) |> Stack.offset(offset) |> Stack.order(order)

        assert_answers(fn -> Stack.stacked(stack, rows) end, fn -> Stack.stacked!(stack, rows) end)

        assert_answers(fn -> Stack.generate(stack, rows) end, fn ->
          Stack.generate!(stack, rows)
        end)
      end
    end
  end
end
