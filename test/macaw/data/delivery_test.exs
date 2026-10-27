defmodule Macaw.Data.DeliveryTest do
  @moduledoc "`Macaw.Data.Delivery` (spec/01 §3): one answer, its table, what it served, and where it came from."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table}

  doctest Delivery

  @rows [%{t: 1, v: 10}, %{t: 2, v: 20}]

  @tag verifies: "delivery-table"
  test "a delivery's rows are a table, read from every source shape at the edge" do
    assert Delivery.rows(Delivery.new(@rows)) == @rows
    assert Delivery.rows(Delivery.new(%{t: [1, 2], v: [10, 20]})) == @rows
    assert Delivery.rows(Delivery.new(t: [1, 2], v: [10, 20])) == @rows
    assert Delivery.rows(Delivery.new([])) == []

    table = Table.new!([{:v, :number, [1, 2]}])
    assert Delivery.new(table).table == table

    typed = Delivery.new([%{c: "#fff"}], types: %{c: :color})
    assert Table.column_type(typed.table, :c) == :color

    assert_raise ArgumentError, ~r/not a delivery's rows/, fn ->
      Delivery.new([%{t: "later"}], types: %{t: :time})
    end

    assert_raise ArgumentError, fn -> Delivery.new(Delivery.new(@rows)) end
  end

  @tag verifies: "delivery-absence"
  property "absence is never zero: a gap is nil through the delivery's table" do
    check all(values <- list_of(one_of([integer(), float(), constant(nil)]), max_length: 30)) do
      rows = Enum.map(values, &%{v: &1})
      read = Delivery.rows(Delivery.new(rows, types: %{v: :number}))
      assert Enum.map(read, & &1.v) |> Enum.map(&is_nil/1) == Enum.map(values, &is_nil/1)
    end
  end

  @tag verifies: "delivery-served"
  test "served: the window, resolution, capped, reduced_by, params and note, checked" do
    d =
      Delivery.new(@rows,
        served: [
          window: [0, 10],
          resolution: :minute,
          capped: true,
          reduced_by: :source,
          params: %{"region" => "eu"},
          note: "coarsened from raw"
        ]
      )

    assert d.served == %{
             window: [0, 10],
             resolution: :minute,
             capped: true,
             reduced_by: :source,
             params: %{"region" => "eu"},
             note: "coarsened from raw"
           }

    assert Delivery.new(@rows).served == %{
             window: nil,
             resolution: nil,
             capped: false,
             reduced_by: nil,
             params: %{},
             note: nil
           }

    assert Delivery.new(@rows, served: %{reduced_by: :runtime}).served.reduced_by == :runtime

    for bad <- [
          [window: [1]],
          [capped: :yes],
          [reduced_by: :feed],
          [reduced_by: :visualize],
          [params: [a: 1]],
          [note: :coarse],
          [color: "red"]
        ] do
      assert_raise ArgumentError, fn -> Delivery.new(@rows, served: bad) end
    end
  end

  @tag verifies: "delivery-box"
  test "a box window over a point field: four bounds, latitudes ordered and in range" do
    box = %{west: -10.5, south: 35.0, east: 30.0, north: 60.0}
    assert Delivery.new([], served: [window: box]).served.window == box

    # A box may cross the antimeridian: west east of east.
    assert Delivery.new([], served: [window: %{box | west: 170, east: -170}])

    for bad <- [
          %{box | south: 61.0},
          %{box | north: 91},
          %{box | west: -181},
          Map.delete(box, :north),
          Map.put(box, :up, 1)
        ] do
      assert_raise ArgumentError, fn -> Delivery.new([], served: [window: bad]) end
    end

    schema = Schema.new!(%{where: %{type: :point, window: true}})
    assert Schema.window_kind(schema) == :box
  end

  @tag verifies: "delivery-schema-origin"
  test "the schema version, never the schema, and the origin" do
    schema = Schema.new!(%{v: %{type: :number}})
    at = ~U[2026-10-27 12:00:00Z]

    d =
      Delivery.new(@rows,
        schema: Schema.version(schema),
        origin: %{source: :latency, request: String.duplicate("a", 64), as_of: at}
      )

    assert d.schema == Schema.version(schema)
    assert d.origin == %{source: :latency, request: String.duplicate("a", 64), as_of: at}

    assert Delivery.new(@rows, origin: %{source: "x", request: "r"}).origin ==
             %{source: "x", request: "r", as_of: nil}

    assert_raise ArgumentError, fn -> Delivery.new(@rows, schema: schema) end
    assert_raise ArgumentError, fn -> Delivery.new(@rows, schema: :ab) end

    for bad <- [
          %{source: :x},
          %{source: :x, request: 1},
          %{source: :x, request: "r", as_of: "now"},
          %{source: :x, request: "r", extra: 1},
          :x
        ] do
      assert_raise ArgumentError, fn -> Delivery.new(@rows, origin: bad) end
    end

    assert_raise ArgumentError, fn -> Delivery.new(@rows, rows: []) end
  end
end
