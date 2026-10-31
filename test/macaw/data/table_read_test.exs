defmodule Macaw.Data.TableReadTest do
  @moduledoc """
  Reading a packed column costs its slots, not its bits (spec/01 §1.1, macaw_data#41): an
  all-valid column decodes without expanding its validity bitmap, a slice cuts its
  bitmap as one integer, a gather takes an all-set bitmap without reading a bit, and a
  chunk's run is gathered from the chunk's storage at its offset. Each is held to a
  reading bit by bit.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Table
  alias Macaw.Data.Table.{Bitmap, Chunk, Column}
  alias Macaw.Data.Test.{Gen, Work}

  # A zone the column keeps whole, consistent with its offset, with no time-zone database.
  defp zoned(%DateTime{} = utc) do
    %{
      DateTime.add(utc, 3600, :second)
      | time_zone: "Etc/GMT-1",
        zone_abbr: "+01",
        utc_offset: 3600,
        std_offset: 0
    }
  end

  # Values for each packed form, `nil` mixed in when `gaps?`.
  defp values(form, n, gaps?) do
    one =
      case form do
        :int64 -> integer(-1_000..1_000)
        :float64 -> Gen.float(min: -1.0e6, max: 1.0e6)
        :integral -> one_of([integer(-1_000..1_000), Gen.float(min: -1.0e3, max: 1.0e3)])
        :utc -> map(integer(0..2_000_000_000), &DateTime.from_unix!/1)
        :zoned -> map(integer(0..2_000_000_000), &zoned(DateTime.from_unix!(&1)))
        :naive -> map(integer(0..2_000_000_000), &DateTime.to_naive(DateTime.from_unix!(&1)))
        :date -> map(integer(-1_000..30_000), &Date.add(~D[1970-01-01], &1))
        :text -> string(:alphanumeric, max_length: 6)
        :category -> member_of(~w(a b c d e))
        :booleans -> one_of([member_of(~w(a b)), boolean()])
        :bool -> boolean()
      end

    value = if gaps?, do: frequency([{4, one}, {1, constant(nil)}]), else: one
    list_of(value, length: n)
  end

  @types %{
    int64: :number,
    float64: :number,
    integral: :number,
    utc: :time,
    zoned: :time,
    naive: :time,
    date: :time,
    text: :text,
    category: :category,
    booleans: :category,
    bool: :category
  }

  # A bitmap's bits read one at a time, the reference the fast paths are held to.
  defp bit_by_bit(bitmap, indexes), do: Bitmap.pack(for i <- indexes, do: Bitmap.at(bitmap, i))

  describe "reading costs the slots, not the bits (spec/01 §1.1; #41)" do
    @tag verifies: "table-read-cost"
    property "values, slices and gathers of generated columns read back as bit by bit, a chunk's run gathered as its slice" do
      check all(
              form <- member_of(Map.keys(@types)),
              gaps? <- boolean(),
              n <- integer(1..70),
              values <- values(form, n, gaps?),
              first <- integer(0..(n - 1)),
              count <- integer(0..(n - first)),
              indexes <- list_of(integer(0..(n - 1)), max_length: 40),
              max_runs: 400
            ) do
        type = Map.fetch!(@types, form)
        {:ok, col} = Column.pack(type, values, "c")
        tuple = List.to_tuple(values)

        assert Column.values(col, n) == values

        sliced = Column.slice(col, first, count)
        assert Column.values(sliced, count) == Enum.slice(values, first, count)

        gathered = Column.gather(col, indexes)
        assert Column.values(gathered, length(indexes)) == Enum.map(indexes, &elem(tuple, &1))

        # A chunk's run gathers from the chunk's storage as from the run's slice, the same
        # buffers byte for byte.
        run = Enum.filter(indexes, &(&1 < count))
        {:ok, chunk} = Chunk.of_rows([{"c", type}], Enum.map(values, &%{"c" => &1}), nil)
        expected = Column.gather(Column.slice(Map.fetch!(chunk.columns, "c"), first, count), run)
        gathered = Chunk.gather(chunk, first, count, run, :key)
        reshaped = Chunk.reshape(chunk, first, count, run, :key, [{"c", type}], %{})

        assert Map.fetch!(gathered.columns, "c") == expected
        assert Map.fetch!(reshaped.columns, "c") == expected
      end
    end

    @tag verifies: "table-read-cost"
    property "a bitmap's slice and take equal reading it bit by bit, with every bit set or not" do
      check all(
              bits <- list_of(member_of([0, 1]), min_length: 1, max_length: 200),
              all? <- boolean(),
              first <- integer(0..(length(bits) - 1)),
              indexes <- list_of(integer(0..(length(bits) - 1)), max_length: 60),
              max_runs: 400
            ) do
        bits = if all?, do: Enum.map(bits, fn _ -> 1 end), else: bits
        n = length(bits)
        bitmap = Bitmap.pack(bits)
        count = n - first

        assert Bitmap.all?(bitmap, n) == Enum.all?(bits, &(&1 == 1))
        assert Bitmap.slice(bitmap, first, count) == bit_by_bit(bitmap, first..(n - 1)//1)
        assert Bitmap.take(bitmap, indexes, n) == bit_by_bit(bitmap, indexes)
        assert Bitmap.take(bitmap, indexes, nil) == bit_by_bit(bitmap, indexes)
      end
    end

    @tag verifies: "table-read-cost"
    test "an all-valid float column reads at most two reductions a row and a constant, expanding no bitmap" do
      n = Table.chunk_rows()
      {:ok, col} = Column.pack(:number, for(i <- 1..n, do: i / 7), "v")
      {reductions, values} = Work.reductions(fn -> Column.values(col, n) end)

      assert length(values) == n
      assert reductions <= 2 * n + 64, "#{reductions} reductions for #{n} rows"
    end
  end
end
