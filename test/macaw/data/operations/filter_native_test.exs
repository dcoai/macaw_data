defmodule Macaw.Data.Operations.FilterNativeTest do
  # `filter`'s mask and the gather in native kernels (spec/04 §4.1.1): a chunk's selection
  # equals the Elixir path's for every test, value and column form, the kernel answering
  # the forms it reads; a gathered column equals `Column.gather/2`'s, slot for slot and bit
  # for bit. Without the kernels both sides are the Elixir path.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Native, Operations, Table}
  alias Macaw.Data.Native.Kernels
  alias Macaw.Data.Operations.Transforms.Filter
  alias Macaw.Data.Table.{Chunk, Column}
  alias Macaw.Data.Test.Storage

  @registry Operations.registry()
  @tests [:eq, :ne, :lt, :lte, :gt, :gte, :present, :absent]
  @big 0x7FFF_FFFF_FFFF_FF00
  @epoch ~U[2026-01-01 00:00:00.000000Z]

  defp checked(node) do
    {:ok, [checked]} = Operations.validate(@registry, [node], %{})
    checked
  end

  # A column's readings of each form, from integers.
  defp column(:int, is), do: {:number, Enum.map(is, &(&1 && &1 * 3))}
  defp column(:wide, is), do: {:number, Enum.map(is, &(&1 && @big - &1))}
  defp column(:float, is), do: {:number, Enum.map(is, &(&1 && &1 * 0.75 - 3.0))}

  # Small integers and floats pack as `macaw.integral`; an integer past 2^53 beside a
  # float, as the int/float union.
  defp column(:integral, is),
    do: {:number, Enum.map(is, &(&1 && if(rem(&1, 2) == 0, do: &1, else: &1 * 0.5)))}

  defp column(:union, is),
    do: {:number, Enum.map(is, &(&1 && if(rem(&1, 2) == 0, do: @big - &1, else: &1 * 0.5)))}

  defp column(:category, is),
    do: {:category, Enum.map(is, &(&1 && Enum.at(~w(a b c d), rem(&1, 4))))}

  defp column(:atoms, is),
    do: {:category, Enum.map(is, &(&1 && Enum.at([:a, "b", true, false], rem(&1, 4))))}

  defp column(:text, is), do: {:text, Enum.map(is, &(&1 && "t#{&1}"))}
  defp column(:time, is), do: {:time, Enum.map(is, &(&1 && DateTime.add(@epoch, &1, :second)))}

  # The values a node tests against: numbers of every size, strings, atoms, nil and a time.
  defp value_gen do
    one_of([
      integer(-20..60),
      float(min: -20.0, max: 60.0),
      member_of([@big - 7, @big - 7.0, 2 ** 70, -(2 ** 70), 9.3e18, -9.3e18, 0.5]),
      member_of(["a", "c", :b, "t7", nil, true, @epoch])
    ])
  end

  describe "the native mask against the Elixir path" do
    @tag verifies: "operations-filter-native-identical"
    property "every test, value and form: the same selection, the kernel answering the forms it reads" do
      check all(
              form <-
                member_of([
                  :int,
                  :wide,
                  :float,
                  :integral,
                  :union,
                  :category,
                  :atoms,
                  :text,
                  :time
                ]),
              is <-
                list_of(frequency([{8, integer(-10..20)}, {1, constant(nil)}]),
                  min_length: 1,
                  max_length: 400
                ),
              test <- member_of(@tests),
              value <- value_gen(),
              size <- member_of([:one, 7, 64]),
              offset <- integer(0..3),
              max_runs: 150
            ) do
        {type, readings} = column(form, is)
        table = Table.new!([{"v", type, readings}]) |> Storage.chunked(size)
        raw = %{op: "filter", field: "v", test: test, value: value}
        node = checked(raw)

        for {chunk, first, count} <- Table.chunks(table), offset < count do
          view = {chunk, first + offset, count - offset}
          native = Filter.native(node, view, "v")
          elixir = Filter.chunk_elixir(node, view, "v")
          if native != :fallback, do: assert(native == elixir)
          assert Filter.chunk(node, view, "v") == elixir

          # The forms the kernel reads, it answers.
          reads? =
            (test in [:present, :absent] and form not in [:union]) or
              (form in [:int, :wide, :float, :category] and
                 (not is_integer(value) or abs(value) < 2 ** 63))

          if Native.loaded?() and reads?, do: assert(native != :fallback)
        end

        run = fn -> Operations.apply!(@registry, [raw], table) end
        assert Table.equal?(run.(), Native.elixir(run))
      end
    end

    @tag verifies: "operations-filter-native-identical"
    test "an integer against a float compares exactly, past 2^53 too, as Erlang does" do
      readings = [@big, @big - 1, @big + 1, 2 ** 53, 2 ** 53 + 1, -(2 ** 53) - 1, 0, nil]
      table = Table.new!([{"v", :number, readings}])
      [view] = Table.chunks(table)

      for test <- @tests,
          value <- [2.0 ** 53, 9.223372036854775e18, -(2.0 ** 53), 0.0, -0.0, 1.5, 2 ** 53 + 1] do
        node = checked(%{op: "filter", field: "v", test: test, value: value})
        native = Filter.native(node, view, "v")
        if Native.loaded?(), do: assert(native != :fallback)
        if native != :fallback, do: assert(native == Filter.chunk_elixir(node, view, "v"))
      end
    end
  end

  describe "the native gather against Column.gather/2" do
    @tag verifies: "operations-filter-native-identical"
    property "every fixed-width form: the same slots and bits at any indexes, repeats and any order" do
      check all(
              form <-
                member_of([:int, :float, :integral, :category, :atoms, :time, :text, :union]),
              is <-
                list_of(frequency([{6, integer(-10..20)}, {1, constant(nil)}]),
                  min_length: 1,
                  max_length: 300
                ),
              picks <- list_of(integer(0..10_000), max_length: 300),
              max_runs: 150
            ) do
        {type, readings} = column(form, is)
        [{chunk, 0, n}] = Table.new!([{"v", type, readings}]) |> Table.chunks()
        indexes = Enum.map(picks, &rem(&1, n))
        storage = Chunk.packed(chunk, "v")
        native = Column.gather(storage, indexes)
        assert native == Native.elixir(fn -> Column.gather(storage, indexes) end)

        assert Column.values(native, length(indexes)) ==
                 Enum.map(indexes, &Enum.at(Column.values(storage, n), &1))
      end
    end
  end

  describe "the calls' bound" do
    @tag verifies: "operations-filter-native-bound"
    test "a mask and a gather over sync_rows rows, every other row kept, take under 1 ms on a normal scheduler; larger ones run dirty" do
      n = Native.sync_rows()

      table =
        Table.new!([{"v", :number, for(i <- 1..(3 * n), do: :math.sin(i) * 100)}])
        |> Storage.chunked(:one)

      [{chunk, 0, _}] = Table.chunks(table)
      node = checked(%{op: "filter", field: "v", test: :gt, value: 0.0})

      for count <- [n, 3 * n] do
        view = {chunk, 0, count}
        assert Filter.chunk(node, view, "v") == Filter.chunk_elixir(node, view, "v")
      end

      assert Native.scheduler(3 * n) == :dirty

      if Native.loaded?() do
        {:float64, data, validity} = Chunk.packed(chunk, "v")
        every_other = Enum.to_list(0..(2 * n - 1)//2)

        for call <- [
              fn ->
                Kernels.filter_mask(2, data, validity, 0, n, 4, 0.0, false, false, <<>>, 0)
              end,
              fn -> Kernels.take(data, 8, every_other) end,
              fn -> Kernels.take_bits(validity, every_other) end
            ] do
          for _ <- 1..5, do: call.()
          least = Enum.min(for _ <- 1..21, do: elem(:timer.tc(call), 0))
          assert least < 1_000, "a #{n}-row call took #{least} µs"
        end

        # A slot past the buffer is a fault, raised, never read.
        assert_raise ErlangError, fn -> Kernels.take(data, 8, [3 * n]) end
      end
    end
  end
end
