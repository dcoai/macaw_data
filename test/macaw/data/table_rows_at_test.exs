defmodule Macaw.Data.TableRowsAtTest do
  @moduledoc """
  `Macaw.Data.Table.rows_at/2` reads many rows by index in one gather (spec/01 §1.1;
  macaw_data#205): each row is the one `Macaw.Data.Table.row/2` answers, in the order
  given, at a cost per row that does not walk a `:list` column from its chunk's start.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Error
  alias Macaw.Data.Table
  alias Macaw.Data.Test.Storage
  alias Macaw.Data.Test.Work

  defp time_gen do
    one_of([
      constant(nil),
      map(integer(-1_000_000_000_000..4_000_000_000_000), &DateTime.from_unix!(&1, :microsecond))
    ])
  end

  # Columns of every storage form, with gaps, of one generated length: packed numbers,
  # dictionary text and categories, times, points, and a `:term` column held as a list.
  defp columns_gen do
    gen all(
          n <- integer(0..40),
          numbers <- list_of(one_of([integer(), float(), constant(nil)]), length: n),
          texts <- list_of(one_of([string(:printable, max_length: 4), constant(nil)]), length: n),
          categories <- list_of(member_of([:ok, "ok", "warn", true, nil]), length: n),
          times <- list_of(time_gen(), length: n),
          points <- list_of(one_of([tuple({float(), float()}), constant(nil)]), length: n),
          terms <-
            list_of(one_of([integer(), tuple({atom(:alphanumeric)}), constant(nil)]), length: n)
        ) do
      [
        {"n", :number, numbers},
        {"s", :text, texts},
        {"c", :category, categories},
        {"t", :time, times},
        {"p", :point, points},
        {"x", :term, terms}
      ]
    end
  end

  # The same rows in one of several layouts: canonical, rechunked small, or sliced out of
  # the middle of a longer table.
  defp layout(columns, :canonical, _pad), do: Table.new!(columns)
  defp layout(columns, {:chunked, size}, _pad), do: Storage.chunked(Table.new!(columns), size)

  defp layout(columns, :sliced, pad) do
    padded = for {name, type, values} <- columns, do: {name, type, pad ++ values ++ pad}
    Table.slice(Storage.chunked(Table.new!(padded), 5), length(pad), length(elem(hd(columns), 2)))
  end

  describe "rows_at/2" do
    @tag verifies: "table-rows-at"
    property "is row/2 mapped over the same indexes, in any order, repeats and past the end" do
      check all(
              columns <- columns_gen(),
              n = length(elem(hd(columns), 2)),
              how <-
                one_of([
                  constant(:canonical),
                  constant(:sliced),
                  tuple({constant(:chunked), integer(1..9)})
                ]),
              pad <- list_of(constant(nil), max_length: 3),
              indexes <- list_of(integer(0..(n + 3)), max_length: 60)
            ) do
        table = layout(columns, how, pad)

        assert Table.rows_at(table, indexes) == {:ok, Enum.map(indexes, &Table.row(table, &1))}
        assert Table.rows_at!(table, indexes) == Enum.map(indexes, &Table.row(table, &1))
      end
    end

    @tag verifies: "table-rows-at"
    test "answers the rows in the order given, nil past the end, and [] for no indexes" do
      table = Table.new!([{"t", :number, [10, 20, 30]}, {"x", :term, [:a, {:b}, nil]}])

      assert Table.rows_at(table, [2, 0, 2, 5]) ==
               {:ok,
                [
                  %{"t" => 30, "x" => nil},
                  %{"t" => 10, "x" => :a},
                  %{"t" => 30, "x" => nil},
                  nil
                ]}

      assert Table.rows_at(table, []) == {:ok, []}
      assert Table.rows_at(table, [3, 4]) == {:ok, [nil, nil]}
    end

    @tag verifies: "table-rows-at"
    test "an index that is no non-negative integer, or a list that is no list, is its fault" do
      table = Table.new!([{"t", :number, [10, 20, 30]}])
      index = {:type, :non_neg_integer}

      assert Table.rows_at(table, [0, -1, 1.0, :a, 2]) ==
               {:error, [{[1], index}, {[2], index}, {[3], index}]}

      for bad <- [[0 | 1], [0, 1 | :tail], :nope, 1, %{0 => 0}, "01", {0, 1}] do
        assert Table.rows_at(table, bad) == {:error, [{[], {:type, :indexes}}]}
        error = assert_raise Error, fn -> Table.rows_at!(table, bad) end
        assert error.reason == [{[], {:type, :indexes}}]
      end

      error = assert_raise Error, fn -> Table.rows_at!(table, [-1]) end
      assert error.reason == [{[0], index}]
    end

    @tag verifies: "table-rows-at-cost"
    test "1,000 indexes over a :list column cost a gather, not a walk from each chunk's start" do
      n = 3 * Table.chunk_rows()

      table =
        Table.new!([
          {"t", :number, Enum.to_list(0..(n - 1))},
          {"c", :category, for(i <- 1..n, do: Enum.at(~w(x y z), rem(i, 3)))},
          {"x", :term, for(i <- 1..n, do: {i, :x})}
        ])

      indexes = Enum.to_list(0..(n - 1)//div(n, 1_000)) |> Enum.take(1_000)
      {reductions, {:ok, rows}} = Work.reductions(fn -> Table.rows_at(table, indexes) end)

      assert length(rows) == 1_000
      assert reductions <= 80 * 1_000, "#{reductions} reductions for 1,000 rows"
    end
  end
end
