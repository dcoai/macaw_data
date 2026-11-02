defmodule Macaw.Data.FinishChunksTest do
  @moduledoc """
  A finished table keeps the held table's chunks (spec/01 §2.4, macaw_data#132): its
  window keeps every chunk inside it as it is and cuts only the edges to views, so a
  caller's per-chunk cache survives a finish.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table}
  alias Macaw.Data.Source.{Description, Finish, Request}
  alias Macaw.Data.Table.Chunk

  @schema Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})
  @description %Description{schema: @schema, supports: []}

  # A source's table of readings at `ts`, ascending, on slots `span` wide.
  defp held(ts, span) do
    Table.new!([{"t", :number, ts}, {"v", :number, Enum.map(ts, &(&1 * 0.5))}],
      origin: %{source: "held", resolution: 1, window: "t", span: span}
    )
  end

  defp named({chunk, first, count}), do: {Chunk.id(chunk), Chunk.version(chunk), first, count}

  @tag verifies: "finish-keeps-chunks"
  property "a window's views are the held chunks inside it, only the first and the last cut" do
    check all(
            n <- integer(1..400),
            span <- member_of([16, 50, 128]),
            a <- integer(-20..420),
            width <- integer(0..420),
            max_runs: 150
          ) do
      table = held(Enum.to_list(0..(n - 1)), span)
      request = Request.new!(window: [a, a + width], now: ~U[2026-11-02 00:00:00Z])

      {:ok, out} =
        Finish.finish(%Delivery{Delivery.new!([]) | rows: table}, @description, request)

      held_views = Enum.map(Table.chunks(table), &named/1)
      out_views = Enum.map(Table.chunks(out.rows), &named/1)

      by_id =
        Map.new(held_views, fn {id, version, first, count} -> {id, {version, first, count}} end)

      # Every kept chunk is a held one, by id and version, its rows a run of the held view.
      for {id, version, first, count} <- out_views do
        assert {^version, hf, hc} = by_id[id]
        assert first >= hf and first + count <= hf + hc
      end

      # Every chunk between the first and the last is the held view itself.
      inner = out_views |> Enum.drop(1) |> Enum.drop(-1)
      assert Enum.all?(inner, &(&1 in held_views))

      kept = for t <- Table.column(table, "t"), t >= a and t <= a + width, do: t
      assert Table.column(out.rows, "t") == kept
    end
  end

  @tag verifies: "finish-keeps-chunks"
  test "with no step to do, the delivery is the held table" do
    table = held(Enum.to_list(0..299), 50)
    delivery = %Delivery{Delivery.new!([]) | rows: table}

    {:ok, out} =
      Finish.finish(
        delivery,
        @description,
        Request.new!(budget: 1_000, now: ~U[2026-11-02 00:00:00Z])
      )

    assert out.rows == table
  end
end
