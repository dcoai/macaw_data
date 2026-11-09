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
  alias Macaw.Data.Test.{Gen, Storage}

  @registry Operations.registry()
  @tests [:eq, :ne, :lt, :lte, :gt, :gte, :present, :absent]
  @orderings [:lt, :lte, :gt, :gte]
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

  # The same instants in a zone an hour east (`macaw.zoned`), as wall clocks (`:naive`),
  # and as days (`:date`).
  defp column(:zoned, is),
    do: {:time, Enum.map(is, &(&1 && east(DateTime.add(@epoch, &1, :second))))}

  defp column(:naive, is),
    do: {:time, Enum.map(is, &(&1 && NaiveDateTime.add(~N[2026-01-01 00:00:00], &1, :second)))}

  defp column(:date, is), do: {:time, Enum.map(is, &(&1 && Date.add(~D[2026-01-01], &1)))}

  defp east(utc) do
    %{DateTime.add(utc, 3600) | utc_offset: 3600, time_zone: "Etc/GMT-1", zone_abbr: "+01"}
  end

  # The kind of value an ordering compares a form's readings with (spec/04 §4.1).
  defp kind(form) when form in [:int, :wide, :float, :integral, :union], do: :number
  defp kind(form) when form in [:time, :zoned, :naive, :date], do: :time
  defp kind(form) when form in [:category, :atoms], do: :category
  defp kind(:text), do: :text

  # The values a node tests against: numbers of every size, strings, atoms, nil and a time.
  defp value_gen do
    one_of([
      number_gen(),
      member_of(["a", "c", :b, "t7", nil, true, @epoch])
    ])
  end

  defp number_gen do
    one_of([
      integer(-20..60),
      Gen.float(min: -20.0, max: 60.0),
      member_of([@big - 7, @big - 7.0, 2 ** 70, -(2 ** 70), 9.3e18, -9.3e18, 0.5])
    ])
  end

  # A value of each kind an ordering reads: a time as a DateTime (UTC or zoned), a Date, a
  # NaiveDateTime or an ISO 8601 string, each near the generated readings.
  defp kind_gen(:number), do: number_gen()
  defp kind_gen(:text), do: member_of(["t1", "t15", "t7", "t", "u", ""])
  defp kind_gen(:category), do: member_of(["a", "c", :b, "bb", 3])

  defp kind_gen(:time) do
    bind(integer(-15..25), fn s ->
      t = DateTime.add(@epoch, s, :second)
      d = DateTime.add(@epoch, s * 86_400, :second)

      member_of([
        t,
        east(t),
        DateTime.add(t, 1, :microsecond),
        DateTime.to_naive(t),
        DateTime.to_date(d),
        DateTime.to_iso8601(t),
        d
      ])
    end)
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
                  :time,
                  :zoned,
                  :naive,
                  :date
                ]),
              is <-
                list_of(frequency([{8, integer(-10..20)}, {1, constant(nil)}]),
                  min_length: 1,
                  max_length: 400
                ),
              test <- member_of(@tests),
              any <- value_gen(),
              of_kind <- kind_gen(kind(form)),
              size <- member_of([:one, 7, 64]),
              offset <- integer(0..3),
              max_runs: 200
            ) do
        # An ordering's value is of the column's kind, and so is a time's under eq and ne
        # (any other is refused, below).
        value =
          if test in @orderings or (kind(form) == :time and test in [:eq, :ne]),
            do: of_kind,
            else: any

        {type, readings} = column(form, is)
        table = Table.new!([{"v", type, readings}]) |> Storage.chunked(size)
        raw = %{op: "filter", field: "v", test: test, value: value}
        node = checked(raw)
        bound = Filter.bound(node, table)

        for {chunk, first, count} <- Table.chunks(table), offset < count do
          view = {chunk, first + offset, count - offset}
          native = Filter.native(node, view, bound)
          elixir = Filter.chunk_elixir(node, view, bound)
          if native != :fallback, do: assert(native == elixir)
          assert Filter.chunk(node, view, bound) == elixir

          # The forms the kernel reads, it answers: a time's instants under an ordering
          # (#96) and under eq and ne (#102) among them, but for a date column's days.
          reads? =
            (test in [:present, :absent] and form not in [:union]) or
              (form in [:int, :wide, :float, :category] and
                 (not is_integer(value) or abs(value) < 2 ** 63)) or
              (form in [:time, :zoned, :naive] and test not in [:present, :absent])

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
        bound = Filter.bound(node, table)
        native = Filter.native(node, view, bound)
        if Native.loaded?(), do: assert(native != :fallback)
        if native != :fallback, do: assert(native == Filter.chunk_elixir(node, view, bound))
      end
    end
  end

  describe "a time's eq and ne against a value with no instant" do
    @tag verifies: "operations-filter-native-identical"
    test "is refused alike with and without the kernels" do
      for form <- [:time, :zoned, :naive, :date],
          value <- [5, "not a time", nil, 2.5],
          test <- [:eq, :ne] do
        {type, readings} = column(form, [1, nil, 2])
        table = Table.new!([{"v", type, readings}])
        node = %{op: "filter", field: "v", test: test, value: value}
        run = fn -> Operations.apply(@registry, [node], table) end
        fault = {:error, [{[0, "value"], {:reading, :time}}]}

        assert run.() == fault
        assert Native.elixir(run) == fault
      end
    end
  end

  describe "an ordering against a value of another kind" do
    @tag verifies: "operations-filter-native-identical"
    test "is refused alike with and without the kernels, naming the field and its type" do
      for {form, value} <- [
            {:int, @epoch},
            {:float, "3"},
            {:int, nil},
            {:time, 5},
            {:naive, "not a time"},
            {:zoned, nil},
            {:date, 2.5},
            {:text, 7},
            {:text, :t1},
            {:category, nil}
          ],
          test <- @orderings do
        {type, readings} = column(form, [1, nil, 2])
        table = Table.new!([{"v", type, readings}])

        run = fn ->
          Operations.apply(
            @registry,
            [%{op: "filter", field: "v", test: test, value: value}],
            table
          )
        end

        fault = {:error, [{[0, "value"], {:reading, type}}]}

        assert run.() == fault
        assert Native.elixir(run) == fault
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
      bound = Filter.bound(node, table)

      for count <- [n, 3 * n] do
        view = {chunk, 0, count}
        assert Filter.chunk(node, view, bound) == Filter.chunk_elixir(node, view, bound)
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

        # A slot past the buffer is a fault, answered as a term, never read (macaw_data#101).
        assert Kernels.take(data, 8, [3 * n]) == {:fault, :short_buffer}
      end
    end
  end
end
