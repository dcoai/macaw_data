defmodule Macaw.Data.TablePackedFormsCostTest do
  @moduledoc """
  What the packed `:point` form costs (spec/01 §1.1, macaw_data#234): reading one row at
  any place in its chunk, a chunk's digest, and a drain into a holding that has a point
  column or a point window, each near the cost of the same data in number columns and
  never a walk of the column's list.
  """
  # Counted work: no other test loads or purges code meanwhile (`Macaw.Data.Test.Work`).
  use ExUnit.Case, async: false

  alias Macaw.Data.{Delivery, Schema, Table}
  alias Macaw.Data.Schema.Cache
  alias Macaw.Data.Source.Push
  alias Macaw.Data.Test.Work

  @n 8_192

  # Reductions for `row/2` at any row of an 8,192-row chunk with a point column: measured
  # 126 at rows 0, 4,096 and 8,000 (88, 4,184 and 8,088 as a list; two number columns 132).
  @row_budget 270
  # Reductions for `Table.digest/1` of that chunk: measured 80,399 (328,424 as a list; two
  # float columns 37,352).
  @digest_budget 120_000
  # Reductions for draining 1,000 rows into a holding of 7,000: a point window, measured
  # 335,823 (1,077,844 with the column a list); a number window beside a point column,
  # measured 313,447 (1,289,525; two number columns 285,490).
  @point_window_budget 420_000
  @point_column_budget 400_000

  defp lon(i), do: -180 + rem(i * 37, 3600) / 10
  defp lat(i), do: -90 + rem(i * 53, 1800) / 10

  defp red(f), do: elem(Work.reductions(f), 0)

  defp points do
    Table.new!([
      {"v", :number, Enum.map(0..(@n - 1), &(&1 / 1))},
      {"p", :point, Enum.map(0..(@n - 1), &{lon(&1), lat(&1)})}
    ])
  end

  @tag verifies: "table-points-cost"
  test "row/2 over a point column costs the same at every row, near a number column's" do
    table = points()

    for i <- [0, 4_096, 8_000] do
      work = red(fn -> Table.row(table, i) end)
      assert work < @row_budget, "row #{i}: #{work}"
    end
  end

  @tag verifies: "table-points-cost"
  test "a chunk's digest hashes a point column from its coordinates' buffers" do
    table = points()
    work = red(fn -> Table.digest(table) end)
    assert work < @digest_budget, "digest: #{work}"
  end

  defp drain_work(schema, row) do
    version = Schema.version(schema)
    push = Push.new!(:ticks, make_ref(), cache: Cache.new([{:ticks, schema}]))
    describe = fn _ -> {:error, :pushed} end
    snapshot = Delivery.new!(Enum.map(0..6_999, row), schema: version, served: [position: 0])
    push = push |> Push.snapshot(snapshot) |> Push.drain(describe)
    increment = Delivery.new!(Enum.map(7_000..7_999, row), schema: version)
    {:ok, push} = Push.receive(push, Push.increment_message(push.ref, 1, increment))

    {work, drained} =
      Work.reductions(fn -> Push.drain(push, describe) end, native: :normal_schedulers)

    assert drained.errors == []
    work
  end

  @tag verifies: "table-points-cost"
  test "a drain into a holding with a point window or a point column joins the open chunk" do
    window =
      drain_work(
        Schema.new!(%{"at" => %{type: :point, window: true}, "v" => %{type: :number}}),
        &%{"at" => {lon(&1), lat(&1)}, "v" => &1 / 1}
      )

    column =
      drain_work(
        Schema.new!(%{
          "t" => %{type: :number, window: true},
          "p" => %{type: :point},
          "v" => %{type: :number}
        }),
        &%{"t" => &1, "p" => {lon(&1), lat(&1)}, "v" => &1 / 1}
      )

    assert window < @point_window_budget, "point window: #{window}"
    assert column < @point_column_budget, "point column: #{column}"
  end
end
