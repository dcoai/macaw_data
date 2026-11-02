defmodule Macaw.Data.DeliveryTest do
  @moduledoc "`Macaw.Data.Delivery` (spec/01 §3): one answer, its table, what it served, and where it came from."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table}

  doctest Delivery

  @rows [%{t: 1, v: 10}, %{t: 2, v: 20}]

  @tag verifies: "delivery-table"
  test "a delivery reads every source shape as rows, and packs a table on demand" do
    assert Delivery.rows(Delivery.new!(@rows)) == @rows
    assert Delivery.rows(Delivery.new!(%{t: [1, 2], v: [10, 20]})) == @rows
    assert Delivery.rows(Delivery.new!(t: [1, 2], v: [10, 20])) == @rows
    assert Delivery.rows(Delivery.new!([])) == []
    assert Delivery.empty?(Delivery.new!([]))
    refute Delivery.empty?(Delivery.new!(@rows))

    table = Table.new!([{:v, :number, [1, 2]}])
    assert Delivery.new!(table).rows == table
    assert Delivery.new!(table) |> Delivery.table!() == table
    assert Delivery.rows(Delivery.new!(table)) == [%{v: 1}, %{v: 2}]

    typed = Delivery.new!([%{c: Macaw.Layers.Color.parse!("#fff")}], types: %{c: :color})
    assert Table.column_type(typed |> Delivery.table!(), :c) == :color

    # A value its declared type doesn't hold is the packing's fault, not the delivery's.
    late = Delivery.new!([%{t: "later"}], types: %{t: :time})
    assert Delivery.rows(late) == [%{t: "later"}]
    assert {:error, _faults} = Delivery.table(late)
    assert_raise ArgumentError, ~r/do not pack/, fn -> Delivery.table!(late) end

    assert {:ok, %Delivery{rows: @rows}} = Delivery.new(@rows)

    for not_rows <- [:rows, 42, "rows", %URI{}] do
      assert Delivery.new(not_rows) == {:error, [{[:rows], {:type, :rows}}]}
    end

    assert Delivery.new(Delivery.new!(@rows)) == {:error, [{[:rows], :delivery}]}

    assert_raise ArgumentError,
                 "not a delivery: rows: a delivery carries rows, not another delivery",
                 fn ->
                   Delivery.new!(Delivery.new!(@rows))
                 end
  end

  @tag verifies: "delivery-rows-as-given"
  test "the rows are kept as the source gave them: the same term, nothing rewritten" do
    at = ~U[2026-10-29 00:00:00Z]
    rows = for i <- 1..50_000, do: {DateTime.add(at, i), i * 0.5, "s#{rem(i, 7)}"}
    big = Delivery.new!(rows, names: [:t, :v, :s])
    assert Delivery.rows(big) === rows
    assert Table.rows(big) === rows

    given = [
      %{n: 1, x: 1.5, t: ~N[2026-10-29 01:00:00], s: "2026-10-29T01:00:00Z"},
      %{n: 2}
    ]

    assert Delivery.rows(Delivery.new!(given)) === given

    # Packing normalizes, there and only there.
    packed = Delivery.table!(Delivery.new!([%{v: 1}, %{v: 2.5}]))
    assert Table.column(packed, :v) == [1.0, 2.5]
  end

  @tag verifies: "delivery-tuple-rows"
  test "tuple rows and a tensor pass as they are; they are named for whoever reads them by name" do
    tuples = [{1, 4.0}, {2, 5.0}]
    d = Delivery.new!(tuples, names: ["x", "y"])
    assert Delivery.rows(d) == tuples
    assert Delivery.named_rows(d) == {:ok, [%{"x" => 1, "y" => 4.0}, %{"x" => 2, "y" => 5.0}]}
    assert Delivery.named_rows!(d) == [%{"x" => 1, "y" => 4.0}, %{"x" => 2, "y" => 5.0}]
    assert d |> Delivery.table!() |> Table.column("y") == [4.0, 5.0]
    assert Delivery.new!(tuples) |> Delivery.table!(names: [:a, :b]) |> Table.column(:a) == [1, 2]

    assert Delivery.named_rows(Delivery.new!(tuples)) == {:error, [{[:names], :required}]}

    assert_raise ArgumentError, ~r/tuple rows have no names/, fn ->
      Delivery.named_rows!(Delivery.new!(tuples))
    end

    assert Delivery.named_rows(Delivery.new!(tuples, names: ["x"])) ==
             {:error, [{[:names], {:width, 1, 2}}]}

    assert_raise ArgumentError, ~r/do not fit their names/, fn ->
      Delivery.named_rows!(Delivery.new!(tuples, names: ["x"]))
    end

    tensor = Nx.tensor([[1, 2], [3, 4]])
    td = Delivery.new!(tensor, names: [:a, :b])
    assert Delivery.rows(td) == [{1, 2}, {3, 4}]
    assert Delivery.named_rows!(td) == [%{a: 1, b: 2}, %{a: 3, b: 4}]
  end

  @tag verifies: "delivery-absence"
  property "absence is never zero: a gap is nil through the delivery's table" do
    check all(values <- list_of(one_of([integer(), float(), constant(nil)]), max_length: 30)) do
      rows = Enum.map(values, &%{v: &1})
      read = Delivery.rows(Delivery.new!(rows, types: %{v: :number}))
      assert Enum.map(read, & &1.v) |> Enum.map(&is_nil/1) == Enum.map(values, &is_nil/1)
    end
  end

  @tag verifies: "delivery-served"
  test "served: the window, resolution, capped, reduced_by, params and note, checked" do
    d =
      Delivery.new!(@rows,
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
             ordered: nil,
             params: %{"region" => "eu"},
             note: "coarsened from raw",
             position: nil,
             complete_until: nil
           }

    assert Delivery.new!(@rows).served == %{
             window: nil,
             resolution: nil,
             capped: false,
             reduced_by: nil,
             ordered: nil,
             params: %{},
             note: nil,
             position: nil,
             complete_until: nil
           }

    assert Delivery.new!(@rows, served: %{reduced_by: :runtime}).served.reduced_by == :runtime

    for by <- [:source, :runtime, :sample],
        do: assert(Delivery.new!(@rows, served: [ordered: by]).served.ordered == by)

    for {bad, fault} <- [
          {[window: [1]], {[:served, :window], {:type, :window}}},
          {[capped: :yes], {[:served, :capped], {:type, :boolean}}},
          {[reduced_by: :feed], {[:served, :reduced_by], {:enum, [nil, :source, :runtime]}}},
          {[reduced_by: :visualize], {[:served, :reduced_by], {:enum, [nil, :source, :runtime]}}},
          {[ordered: true], {[:served, :ordered], {:enum, [nil, :source, :runtime, :sample]}}},
          {[ordered: :feed], {[:served, :ordered], {:enum, [nil, :source, :runtime, :sample]}}},
          {[params: [a: 1]], {[:served, :params], {:type, :map}}},
          {[note: :coarse], {[:served, :note], {:type, :string}}},
          {[color: "red"], {[:served, :color], :unknown_key}},
          {:capped, {[:served], {:type, :keyword}}}
        ] do
      assert Delivery.new(@rows, served: bad) == {:error, [fault]}
    end
  end

  @tag verifies: "delivery-position"
  test "served holds a snapshot's position" do
    assert Delivery.new!(@rows).served.position == nil
    assert Delivery.new!(@rows, served: [position: 0]).served.position == 0
    assert Delivery.new!(@rows, served: [position: 42]).served.position == 42

    for bad <- [-1, 1.0, "3", :first] do
      assert Delivery.new(@rows, served: [position: bad]) ==
               {:error, [{[:served, :position], {:type, :non_neg_integer}}]}

      assert_raise ArgumentError, ~r/served.position: not a non-negative integer/, fn ->
        Delivery.new!(@rows, served: [position: bad])
      end
    end
  end

  @tag verifies: "delivery-changes"
  test "a delivery carries retracted rows and range replacements, checked" do
    d = Delivery.new!(@rows)
    assert {d.retracted, d.replace} == {[], []}

    d =
      Delivery.new!(@rows,
        retracted: [%{t: 1, v: 3}],
        replace: [%{from: 0, to: nil, identities: ["a"], rows: [%{t: 2, v: 1}]}, %{from: 5}]
      )

    assert d.retracted == [%{t: 1, v: 3}]

    assert d.replace == [
             %{from: 0, to: nil, identities: ["a"], rows: [%{t: 2, v: 1}]},
             %{from: 5, to: nil, identities: nil, rows: []}
           ]

    for {bad, fault} <- [
          {[retracted: [%{t: 1}, {1, 3}]], {[:retracted, 1], {:type, :row}}},
          {[retracted: %{t: 1}], {[:retracted], {:type, :list}}},
          {[replace: [%{from: 0, until: 3}]], {[:replace, 0], {:type, :replacement}}},
          {[replace: [%{from: 0}, %{identities: "a"}]], {[:replace, 1], {:type, :replacement}}},
          {[replace: [%{rows: [[t: 1]]}]], {[:replace, 0], {:type, :replacement}}},
          {[replace: %{from: 0}], {[:replace], {:type, :list}}}
        ] do
      assert Delivery.new(@rows, bad) == {:error, [fault]}
    end
  end

  @tag verifies: "delivery-complete-until"
  test "served holds complete_until, a time or a number" do
    assert Delivery.new!(@rows).served.complete_until == nil
    assert Delivery.new!(@rows, served: [complete_until: 7]).served.complete_until == 7

    for t <- [~U[2026-10-30 00:00:00Z], ~N[2026-10-30 00:00:00], ~D[2026-10-30], 2.5] do
      assert Delivery.new!(@rows, served: [complete_until: t]).served.complete_until == t
    end

    for bad <- ["2026-10-30", :now, [1, 2]] do
      assert Delivery.new(@rows, served: [complete_until: bad]) ==
               {:error, [{[:served, :complete_until], {:type, :instant}}]}

      assert_raise ArgumentError, ~r/complete_until/, fn ->
        Delivery.new!(@rows, served: [complete_until: bad])
      end
    end
  end

  @tag verifies: "delivery-box"
  test "a box window over a point field: four bounds, latitudes ordered and in range" do
    box = %{west: -10.5, south: 35.0, east: 30.0, north: 60.0}
    assert Delivery.new!([], served: [window: box]).served.window == box

    # A box may cross the antimeridian: west east of east.
    assert Delivery.new!([], served: [window: %{box | west: 170, east: -170}])

    for bad <- [
          %{box | south: 61.0},
          %{box | north: 91},
          %{box | west: -181},
          Map.delete(box, :north),
          Map.put(box, :up, 1)
        ] do
      assert Delivery.new([], served: [window: bad]) ==
               {:error, [{[:served, :window], {:type, :window}}]}
    end

    schema = Schema.new!(%{where: %{type: :point, window: true}})
    assert Schema.window_kind(schema) == :box
  end

  @tag verifies: "delivery-schema-origin"
  test "the schema version, never the schema, and the origin" do
    schema = Schema.new!(%{v: %{type: :number}})
    at = ~U[2026-10-27 12:00:00Z]

    d =
      Delivery.new!(@rows,
        schema: Schema.version(schema),
        origin: %{source: :latency, request: String.duplicate("a", 64), as_of: at}
      )

    assert d.schema == Schema.version(schema)
    assert d.origin == %{source: :latency, request: String.duplicate("a", 64), as_of: at}

    assert Delivery.new!(@rows, origin: %{source: "x", request: "r"}).origin ==
             %{source: "x", request: "r", as_of: nil}

    assert Delivery.new(@rows, schema: schema) == {:error, [{[:schema], {:type, :version}}]}
    assert Delivery.new(@rows, schema: :ab) == {:error, [{[:schema], {:type, :version}}]}

    for bad <- [
          %{source: :x},
          %{source: :x, request: 1},
          %{source: :x, request: "r", as_of: "now"},
          %{source: :x, request: "r", extra: 1},
          :x
        ] do
      assert Delivery.new(@rows, origin: bad) == {:error, [{[:origin], {:type, :origin}}]}
    end

    assert Delivery.new(@rows, rows: []) == {:error, [{[:rows], :unknown_key}]}
  end

  @tag verifies: "delivery-faults"
  test "every fault is answered at once, in the order of the fields, in words" do
    assert Delivery.new(:x, names: "a", served: [capped: 1, up: 2], schema: 1, color: "red") ==
             {:error,
              [
                {[:rows], {:type, :rows}},
                {[:color], :unknown_key},
                {[:names], {:type, :names}},
                {[:served, :capped], {:type, :boolean}},
                {[:served, :up], :unknown_key},
                {[:schema], {:type, :version}}
              ]}

    assert Delivery.new(@rows, :served) == {:error, [{[:opts], {:type, :keyword}}]}
    assert Delivery.new(@rows, [:served]) == {:error, [{[:opts], {:type, :keyword}}]}

    assert_raise ArgumentError,
                 "not a delivery: names: not a list of atoms or strings; served.up: not a served fact (spec/01 §3)",
                 fn -> Delivery.new!(@rows, names: [1], served: [up: 2]) end

    assert Delivery.format_error({[:replace, 2], {:type, :replacement}}) =~
             ~r/^replace\[2\]: not a range replacement/
  end

  @keys [:served, :schema, :origin, :types, :names, :retracted, :replace, :rows, :up]
  @facts [
    :window,
    :resolution,
    :capped,
    :reduced_by,
    :ordered,
    :params,
    :note,
    :position,
    :complete_until,
    :up
  ]

  @tag verifies: "delivery-faults"
  property "new/2 never raises: it answers a delivery or faults in words, and new!/2 raises them" do
    check all(
            rows <-
              one_of([
                term(),
                list_of(map_of(atom(:alphanumeric), one_of([integer(), float(), constant(nil)])),
                  max_length: 3
                )
              ]),
            served <- one_of([term(), list_of(tuple({member_of(@facts), term()}), max_length: 3)]),
            opts <- list_of(tuple({member_of(@keys), term()}), max_length: 4)
          ) do
      opts = [{:served, served} | opts]

      case Delivery.new(rows, opts) do
        {:ok, %Delivery{rows: ^rows}} ->
          assert Delivery.new!(rows, opts).rows === rows

        {:error, [_ | _] = faults} ->
          for {path, _reason} = fault <- faults do
            assert is_list(path)
            assert is_binary(Delivery.format_error(fault))
          end

          message = "not a delivery: " <> Enum.map_join(faults, "; ", &Delivery.format_error/1)
          assert_raise ArgumentError, message, fn -> Delivery.new!(rows, opts) end
      end
    end
  end
end
