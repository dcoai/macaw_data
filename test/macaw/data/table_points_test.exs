defmodule Macaw.Data.TablePointsTest do
  @moduledoc """
  A `:point` column's packed form (spec/01 §1.1, macaw_data#234): two number columns and
  a validity bitmap, the list where a coordinate is past int64. Every operation a form
  supports answers what the list form of the same points answers, and its canonical
  streams are the list form's byte for byte, so no digest moves.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Table
  alias Macaw.Data.Table.{Canonical, Column}
  alias Macaw.Data.Table.Column.Append

  import Macaw.Data.Test.Storage, only: [storage: 2]

  # -- generators -------------------------------------------------------------------------

  # A coordinate of a mode, so a column's two children often take one form and sometimes
  # another: integers, floats (signed zeros among them), both within ±2^53, both with an
  # integer beyond it, and now and then one past int64.
  defp coordinate(:ints), do: integer(-1_000..1_000)
  defp coordinate(:floats), do: one_of([float(min: -180.0, max: 180.0), member_of([0.0, -0.0])])
  defp coordinate(:mixed), do: one_of([integer(-5..5), float(min: -5.0, max: 5.0)])
  defp coordinate(:wide), do: one_of([constant(2 ** 60), constant(-2 ** 63), constant(0.5)])
  defp coordinate(:past), do: one_of([constant(2 ** 64), integer(-3..3)])

  defp mode, do: member_of([:ints, :ints, :floats, :floats, :mixed, :wide, :past])

  defp points(max \\ 40) do
    bind(tuple({mode(), mode()}), fn {xm, ym} ->
      list_of(one_of([tuple({coordinate(xm), coordinate(ym)}), constant(nil)]), max_length: max)
    end)
  end

  defp packed(points) do
    {:ok, column} = Column.pack(:point, points, "p")
    column
  end

  defp flat({tags, words, bytes}),
    do: {IO.iodata_to_binary(tags), IO.iodata_to_binary(words), IO.iodata_to_binary(bytes)}

  # The canonical streams of `column`'s `n` points equal those of the list form of `points`.
  defp same_streams?(column, points),
    do:
      flat(Canonical.streams(column, length(points))) ==
        flat(Canonical.streams({:list, points}, length(points)))

  defp x_y({:point, x, y, _v}), do: {elem(x, 0), elem(y, 0)}
  defp x_y(_list), do: nil

  # -- the form ---------------------------------------------------------------------------

  @tag verifies: "table-points"
  test "a point column is two number columns and a validity bitmap; past int64 it is the list" do
    floats = Table.new!([{:p, :point, [{1.5, -2.0}, nil, {0.0, -0.0}]}])

    assert {:point, {:float64, _, <<0b101>>}, {:float64, _, <<0b101>>}, <<0b101>>} =
             storage(floats, :p)

    assert Table.column(floats, :p) === [{1.5, -2.0}, nil, {0.0, -0.0}]

    # Each coordinate takes the form its own values take, as a number column's do.
    mixed = Table.new!([{:p, :point, [{1, 2.5}, {3, 4}, {2 ** 60, 0.5}]}])
    assert {:point, {:int64, _, _}, {:integral, _, _, _}, _} = storage(mixed, :p)

    wide = Table.new!([{:p, :point, [{2 ** 60, 1}, {0.5, 1}]}])
    assert {:point, {:union, _, _, _, _}, {:int64, _, _}, _} = storage(wide, :p)
    assert Table.column(wide, :p) === [{2 ** 60, 1}, {0.5, 1}]

    past = Table.new!([{:p, :point, [{2 ** 64, 1}, {1, 2}]}])
    assert storage(past, :p) === {:list, [{2 ** 64, 1}, {1, 2}]}

    assert {:error, [{[:p, 0], {:type, :point}}]} = Table.new([{:p, :point, [{1, :x}]}])
  end

  @tag verifies: "table-points"
  property "a point column reads back every point as given, through every operation" do
    check all(
            points <- points(),
            first <- integer(0..max(length(points) - 1, 0)),
            count <- integer(0..max(length(points) - first, 0)),
            indexes <- list_of(integer(0..max(length(points) - 1, 0)), max_length: 20)
          ) do
      n = length(points)
      column = packed(points)
      assert Column.values(column, n) === points
      assert same_streams?(column, points)

      sliced = Column.slice(column, first, count)
      assert Column.values(sliced, count) === Enum.slice(points, first, count)
      assert same_streams?(sliced, Enum.slice(points, first, count))

      if n > 0 do
        gathered = Column.gather(column, indexes)
        expected = Enum.map(indexes, &Enum.at(points, &1))
        assert Column.values(gathered, length(indexes)) === expected
        assert same_streams?(gathered, expected)
      end
    end
  end

  @tag verifies: "table-points"
  property "pieces of a point column join end to end as their points, an open chunk's join exactly" do
    check all(pieces <- list_of(points(12), min_length: 1, max_length: 4)) do
      all = Enum.concat(pieces)
      columns = for p <- pieces, do: {packed(p), length(p)}

      case Column.concat(columns) do
        {:ok, joined} ->
          assert Column.values(joined, length(all)) === all
          assert same_streams?(joined, all)

        :general ->
          # Only where the pieces' coordinates are not each one joinable buffer form.
          shapes = Enum.uniq(for {column, _n} <- columns, do: x_y(column))
          refute match?([{x, y}] when x in [:int64, :float64] and y in [:int64, :float64], shapes)
      end

      # The held points as they lie, the added ones packed by themselves: a join is
      # byte for byte the column packing every point gives.
      [held | added] = pieces
      added = Enum.concat(added)
      at = length(held)
      whole = held ++ added

      case Append.append({Append.head(packed(whole), at), at}, {packed(added), length(added)}) do
        {:ok, column} -> assert column == packed(whole)
        :repack -> :ok
      end

      case Append.append({packed(held), at}, {packed(added), length(added)}) do
        {:ok, column} -> assert column == packed(whole)
        :repack -> :ok
      end
    end
  end

  @tag verifies: "table-points"
  test "an open chunk's float or integer points join, and mixing the two repacks" do
    held = [{1.5, 2.5}, nil]
    added = [{3.5, -0.0}]

    assert {:ok, column} = Append.append({packed(held), 2}, {packed(added), 1})
    assert column == packed(held ++ added)

    ints = [{1, 2}, nil]
    assert {:ok, column} = Append.append({packed(ints), 2}, {packed([{3, 4}]), 1})
    assert column == packed(ints ++ [{3, 4}])

    # Packing every point makes x integral, which neither piece's x is.
    assert :repack = Append.append({packed(ints), 2}, {packed(added), 1})
    assert :repack = Append.append({packed(ints), 2}, {packed([{2 ** 64, 1}]), 1})
  end

  @tag verifies: "table-points"
  property "a table with a point column has the digest of the same points held as a list" do
    check all(points <- points(60), size <- integer(1..25)) do
      table =
        Table.new!([{"p", :point, points}, {"i", :number, Enum.to_list(1..length(points)//1)}])

      header = [{"p", :point}, {"i", :number}]

      # The same chunks, every point column held as the list it was before.
      listed =
        for {chunk, 0, n} <- Table.chunks(table) do
          {Map.update!(chunk.columns, "p", &{:list, Column.values(&1, n)}), n}
        end

      digests =
        for {columns, n} <- listed,
            do:
              Macaw.Data.Table.Chunk.build(header, columns, n) |> Macaw.Data.Table.Chunk.digest()

      assert digests ==
               for(
                 {chunk, 0, _n} <- Table.chunks(table),
                 do: Macaw.Data.Table.Chunk.digest(chunk)
               )

      assert Table.digest(table) == Table.digest(Macaw.Data.Test.Storage.chunked(table, size))
    end
  end
end
