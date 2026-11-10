defmodule Macaw.Data.TableColorsTest do
  @moduledoc """
  A `:color` column's packed form (spec/01 §1.1, macaw_data#235): a tuple of its distinct
  terms in first-appearance order, an int32 code per value and a validity bitmap, under a
  tag of its own. Every operation a form supports answers what the list form of the same
  values answers, and its canonical streams are the list form's byte for byte, so no
  digest moves.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Table
  alias Macaw.Data.Table.{Canonical, Chunk, Column}
  alias Macaw.Data.Table.Column.Append
  alias Macaw.Layers.Color

  import Macaw.Data.Test.Storage, only: [storage: 2, chunked: 2]

  # Color terms of every shape: theme colors, ramps (at positions a map key tells apart
  # and `==` does not: 1 and 1.0, 0.0 and -0.0), a blend, a contrast, a transform of a
  # literal, a literal and a series slot.
  @pool [
    {:color, :red},
    {:color, :blue},
    {:ramp, :viridis, 0.5},
    {:ramp, :viridis, 1},
    {:ramp, :viridis, 1.0},
    {:ramp, :viridis, 0.0},
    {:ramp, :viridis, -0.0},
    {:blend, [{:color, :red}, {:color, :blue}]},
    {:contrast, {:color, :red}},
    {:intensity, Color.parse!("#ff0000"), 0.5},
    Color.parse!("#00ff00"),
    {:series, 3}
  ]

  # A column draws from a few of the pool, so pieces share some terms and not others.
  defp colors(max \\ 40) do
    bind(list_of(member_of(@pool), min_length: 1, max_length: 4), fn few ->
      list_of(one_of([member_of(few), constant(nil)]), max_length: max)
    end)
  end

  defp packed(values) do
    {:ok, column} = Column.pack(:color, values, "k")
    column
  end

  defp flat({tags, words, bytes}),
    do: {IO.iodata_to_binary(tags), IO.iodata_to_binary(words), IO.iodata_to_binary(bytes)}

  defp same_streams?(column, values) do
    n = length(values)
    flat(Canonical.streams(column, n)) == flat(Canonical.streams({:list, values}, n))
  end

  # -- the form ---------------------------------------------------------------------------

  @tag verifies: "table-colors"
  test "a color column is its distinct terms, a code per value and a validity bitmap" do
    values = [{:color, :red}, nil, {:ramp, :viridis, 1}, {:color, :red}, {:ramp, :viridis, 1.0}]
    table = Table.new!([{:k, :color, values}])

    assert {:terms, codes, <<0b11101>>, terms} = storage(table, :k)
    assert codes == <<0::32-little, 0::32, 1::32-little, 0::32-little, 2::32-little>>
    # 1 and 1.0 are two terms, as a map key tells them; so are 0.0 and -0.0.
    assert terms == {{:color, :red}, {:ramp, :viridis, 1}, {:ramp, :viridis, 1.0}}
    assert Table.column(table, :k) === values

    zeros = Table.new!([{:k, :color, [{:ramp, :viridis, 0.0}, {:ramp, :viridis, -0.0}]}])
    assert {:terms, _, _, {{:ramp, :viridis, +0.0}, {:ramp, :viridis, -0.0}}} = storage(zeros, :k)

    # Its own tag: no reader of a text dictionary mistakes it for one.
    refute match?({:dictionary, _, _, _, _}, storage(table, :k))
    assert {:error, [{[:k, 0], {:type, :color}}]} = Table.new([{:k, :color, ["#ff0000"]}])
  end

  @tag verifies: "table-colors"
  property "a color column reads back every value as given, through every operation" do
    check all(
            values <- colors(),
            first <- integer(0..max(length(values) - 1, 0)),
            count <- integer(0..max(length(values) - first, 0)),
            indexes <- list_of(integer(0..max(length(values) - 1, 0)), max_length: 20)
          ) do
      n = length(values)
      column = packed(values)
      assert Column.values(column, n) === values
      assert same_streams?(column, values)

      sliced = Column.slice(column, first, count)
      assert Column.values(sliced, count) === Enum.slice(values, first, count)
      assert same_streams?(sliced, Enum.slice(values, first, count))

      if n > 0 do
        gathered = Column.gather(column, indexes)
        expected = Enum.map(indexes, &Enum.at(values, &1))
        assert Column.values(gathered, length(indexes)) === expected
        assert same_streams?(gathered, expected)
      end
    end
  end

  @tag verifies: "table-colors"
  property "pieces of a color column join end to end as their values, an open chunk's join exactly" do
    check all(pieces <- list_of(colors(12), min_length: 1, max_length: 4)) do
      all = Enum.concat(pieces)
      assert {:ok, joined} = Column.concat(for p <- pieces, do: {packed(p), length(p)})
      assert Column.values(joined, length(all)) === all
      assert same_streams?(joined, all)

      # The held values as they lie, cut to the terms they hold, and the added ones
      # packed by themselves: the join is the column packing every value gives.
      [held | added] = pieces
      added = Enum.concat(added)
      at = length(held)
      whole = held ++ added
      tail = {packed(added), length(added)}

      assert Append.append({Append.head(packed(whole), at), at}, tail) == {:ok, packed(whole)}
      assert Append.append({packed(held), at}, tail) == {:ok, packed(whole)}
    end
  end

  @tag verifies: "table-colors"
  test "a value that is no color is refused at its path, in any piece" do
    bad = {:blend, [{:color, :red}, self()]}

    assert Column.piece(:color, [{:color, :red}, bad, nil, bad], "k", 10) ==
             {:error, [{["k", 11], {:type, :color}}, {["k", 13], {:type, :color}}]}
  end

  @tag verifies: "table-colors"
  property "a table with a color column has the digest of the same values held as a list" do
    check all(values <- colors(60), size <- integer(1..25)) do
      table =
        Table.new!([{"k", :color, values}, {"i", :number, Enum.to_list(1..length(values)//1)}])

      header = [{"k", :color}, {"i", :number}]

      for {chunk, 0, n} <- Table.chunks(table) do
        listed = Map.update!(chunk.columns, "k", &{:list, Column.values(&1, n)})
        assert Chunk.digest(Chunk.build(header, listed, n)) == Chunk.digest(chunk)
      end

      assert Table.digest(table) == Table.digest(chunked(table, size))
    end
  end
end
