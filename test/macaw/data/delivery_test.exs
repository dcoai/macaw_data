defmodule Macaw.Data.DeliveryTest do
  @moduledoc "`Macaw.Data.Delivery` (spec/01 §3): one answer, its table, what it served, and where it came from."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table}

  doctest Delivery

  @rows [%{t: 1, v: 10}, %{t: 2, v: 20}]

  @tag verifies: "delivery-table"
  test "a delivery reads every source shape as rows, and packs a table on demand" do
    assert Delivery.rows(Delivery.new(@rows)) == @rows
    assert Delivery.rows(Delivery.new(%{t: [1, 2], v: [10, 20]})) == @rows
    assert Delivery.rows(Delivery.new(t: [1, 2], v: [10, 20])) == @rows
    assert Delivery.rows(Delivery.new([])) == []
    assert Delivery.empty?(Delivery.new([]))
    refute Delivery.empty?(Delivery.new(@rows))

    table = Table.new!([{:v, :number, [1, 2]}])
    assert Delivery.new(table).rows == table
    assert Delivery.new(table) |> Delivery.table!() == table
    assert Delivery.rows(Delivery.new(table)) == [%{v: 1}, %{v: 2}]

    typed = Delivery.new([%{c: Macaw.Layers.Color.parse!("#fff")}], types: %{c: :color})
    assert Table.column_type(typed |> Delivery.table!(), :c) == :color

    # A value its declared type doesn't hold is the packing's fault, not the delivery's.
    late = Delivery.new([%{t: "later"}], types: %{t: :time})
    assert Delivery.rows(late) == [%{t: "later"}]
    assert {:error, _faults} = Delivery.table(late)
    assert_raise ArgumentError, ~r/do not pack/, fn -> Delivery.table!(late) end

    for not_rows <- [:rows, 42, "rows", %URI{}] do
      assert_raise ArgumentError, ~r/not a delivery's rows/, fn -> Delivery.new(not_rows) end
    end

    assert_raise ArgumentError, fn -> Delivery.new(Delivery.new(@rows)) end
  end

  @tag verifies: "delivery-rows-as-given"
  test "the rows are kept as the source gave them: the same term, nothing rewritten" do
    at = ~U[2026-10-29 00:00:00Z]
    rows = for i <- 1..50_000, do: {DateTime.add(at, i), i * 0.5, "s#{rem(i, 7)}"}
    big = Delivery.new(rows, names: [:t, :v, :s])
    assert Delivery.rows(big) === rows
    assert Table.rows(big) === rows

    given = [
      %{n: 1, x: 1.5, t: ~N[2026-10-29 01:00:00], s: "2026-10-29T01:00:00Z"},
      %{n: 2}
    ]

    assert Delivery.rows(Delivery.new(given)) === given

    # Packing normalizes, there and only there.
    packed = Delivery.table!(Delivery.new([%{v: 1}, %{v: 2.5}]))
    assert Table.column(packed, :v) == [1.0, 2.5]
  end

  @tag verifies: "delivery-tuple-rows"
  test "tuple rows and a tensor pass as they are; they are named for whoever reads them by name" do
    tuples = [{1, 4.0}, {2, 5.0}]
    d = Delivery.new(tuples, names: ["x", "y"])
    assert Delivery.rows(d) == tuples
    assert Delivery.named_rows(d) == [%{"x" => 1, "y" => 4.0}, %{"x" => 2, "y" => 5.0}]
    assert d |> Delivery.table!() |> Table.column("y") == [4.0, 5.0]
    assert Delivery.new(tuples) |> Delivery.table!(names: [:a, :b]) |> Table.column(:a) == [1, 2]

    assert_raise ArgumentError, ~r/tuple rows have no names/, fn ->
      Delivery.named_rows(Delivery.new(tuples))
    end

    assert_raise ArgumentError, ~r/do not fit their names/, fn ->
      Delivery.named_rows(Delivery.new(tuples, names: ["x"]))
    end

    tensor = Nx.tensor([[1, 2], [3, 4]])
    td = Delivery.new(tensor, names: [:a, :b])
    assert Delivery.rows(td) == [{1, 2}, {3, 4}]
    assert Delivery.named_rows(td) == [%{a: 1, b: 2}, %{a: 3, b: 4}]
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
