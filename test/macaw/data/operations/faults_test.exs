defmodule Macaw.Data.Operations.FaultsTest do
  @moduledoc """
  Errors are values in the operations (spec/00 §5, spec/04 §3.1): a run refuses what it
  cannot read with a fault at its node, and never raises.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Operations, Schema, Table}
  alias Macaw.Data.Operations.{Cache, Step}
  alias Macaw.Data.Operations.Transforms.{Bin, Filter}

  @registry Operations.registry()

  @tag verifies: "operations-run-faults"
  test "a source that is no table, and a transform answering no table, are faults at their place" do
    for not_a_table <- [:rows, 42, "rows", [1, 2], [%{a: 1}, :b], %URI{}] do
      assert Operations.apply(@registry, [%{op: "take", n: 1}], not_a_table) ==
               {:error, [{["source"], :not_a_table}]}
    end

    assert Operations.format_error({["source"], :not_a_table}) == "source: is not a table"

    # A column map of unequal columns is Table.from/2's fault, under "source".
    assert Operations.apply(@registry, [%{op: "take", n: 1}], %{"a" => [1, 2], "b" => [3]}) ==
             {:error, [{["source", "b"], {:length, 2}}]}

    {:ok, junk} = Operations.registry([Macaw.Data.Test.Ops.Junk])

    assert Operations.apply(junk, [%{op: "take", n: 5}, %{op: "junk"}], [%{a: 1}]) ==
             {:error, [{[1, "op"], :not_a_table}]}
  end

  @tag verifies: "operations-run-faults"
  test "a step's fault stops the run at its index, and its words name the step and option" do
    rows = [%{v: 1}, %{v: "x"}]
    nodes = [%{op: "take", n: 2}, %{op: "bin", field: :v}, %{op: "take", n: 1}]

    assert Operations.apply(@registry, nodes, rows) ==
             {:error, [{[1, "field"], {:reads, :number}}]}

    assert_raise Macaw.Data.Error, "step 2, field: reads a value that is not a number", fn ->
      Operations.apply!(@registry, nodes, rows)
    end

    # The step and the cache answer the same fault, the cache unchanged.
    {:ok, table} = Table.from(rows)
    [checked] = checked(%{op: "bin", field: :v})
    fault = {"field", {:reads, :number}}

    assert Step.run(Bin, checked, table, %{}) == {:error, fault}
    assert Step.parts(Bin, checked, table, %{}) == {:error, fault}
    assert Cache.run(Cache.new(), Bin, checked, table, %{}) == {:error, fault}
    assert Bin.run(checked, table, %{}) == {:error, fault}
    assert Step.format_error(fault) == "field: reads a value that is not a number"

    [filter] = checked(%{op: "filter", field: :v, test: :lt, value: "2"})
    {:ok, numbers} = Table.from([%{v: 1}])
    assert {:ok, _table, %Cache{}} = Cache.run(Cache.new(), Filter, filter, table, %{})
    assert Step.run(Filter, filter, numbers, %{}) == {:error, {"value", {:reading, :number}}}
  end

  @tag verifies: "operations-run-faults"
  test "a typed column is read by its type alone; any other is read value by value" do
    # A number column read as a time is seconds; a time column read as a number is not.
    {:ok, timed} = Table.from([%{t: ~U[2026-01-01 00:00:00Z], v: 1}])
    assert {:ok, _} = Operations.apply(@registry, [%{op: "lttb", fields: [:v, :v], n: 3}], timed)

    assert Operations.apply(@registry, [%{op: "bin", field: :t}], timed) ==
             {:error, [{[0, "field"], {:reads, :number}}]}

    # Readings of a term column are read one by one: numbers pass, a string does not.
    mixed = Table.new!([{"v", :term, [1, 2.5, nil]}])
    assert {:ok, _} = Operations.apply(@registry, [%{op: "bin", field: "v"}], mixed)
    stringy = Table.new!([{"v", :term, [1, "2"]}])

    assert Operations.apply(@registry, [%{op: "stack", fields: ["v"]}], stringy) ==
             {:error, [{[0, "fields"], {:reads, :number}}]}

    # A pair is read as points: an aggregate of points takes it, one of numbers does not.
    pairs = [%{x: 0, y: 1}, %{x: 1, y: 3}]

    assert {:ok, _} =
             Operations.apply(
               @registry,
               [%{op: "aggregate", field: [:x, :y], fn: "slope"}],
               pairs
             )

    assert Operations.apply(@registry, [%{op: "aggregate", field: [:x, :y], fn: "sum"}], pairs) ==
             {:error, [{[0, "field"], {:reads, :number}}]}
  end

  defp checked(node) do
    {:ok, checked} = Operations.validate(@registry, [node], %{})
    checked
  end

  # -- generated: apply never raises ----------------------------------------------------------

  @names ["a", "b", "c", "d"]
  @schema Schema.new!(%{"a" => %{type: :number, identity: true}, "b" => %{type: :number}})

  defp value do
    one_of([
      integer(-5..5),
      float(min: -10.0, max: 10.0),
      string(:alphanumeric, max_length: 3),
      member_of([:ok, :soon, nil, true]),
      constant(~U[2026-01-01 00:00:00Z]),
      constant(~N[2026-01-01 00:00:00]),
      constant(~D[2026-01-02]),
      constant("2026-01-01T00:00:00Z"),
      list_of(integer(0..3), length: 2)
    ])
  end

  defp field, do: member_of(@names ++ [:a])

  defp step do
    one_of([
      fixed_map(%{
        op: constant("filter"),
        field: field(),
        test: member_of(~w(eq ne lt gte present)a),
        value: value()
      }),
      fixed_map(%{op: constant("take"), n: integer(0..4)}),
      fixed_map(%{
        op: constant("window"),
        field: field(),
        from: constant([1, :minute]),
        latest: boolean()
      }),
      fixed_map(%{op: constant("lttb"), fields: list_of(field(), length: 2), n: integer(3..5)}),
      fixed_map(%{op: constant("m4"), fields: list_of(field(), length: 2), width: integer(1..4)}),
      fixed_map(%{op: constant("sort"), field: field()}),
      fixed_map(%{op: constant("fold"), fields: list_of(field(), length: 1)}),
      fixed_map(%{op: constant("stack"), fields: list_of(field(), min_length: 1, max_length: 2)}),
      fixed_map(%{
        op: constant("bin"),
        field: field(),
        fn: member_of([nil, "sum", "min", "count"])
      }),
      fixed_map(%{
        op: constant("aggregate"),
        field: one_of([field(), list_of(field(), length: 2)]),
        fn: member_of(~w(count sum mean min max extent slope delta distinct)),
        by: one_of([constant(nil), field()])
      }),
      fixed_map(%{op: constant("sum"), field: field(), by: one_of([constant(nil), field()])}),
      fixed_map(%{
        op: constant("spectrum"),
        field: field(),
        time: one_of([constant(nil), field()])
      }),
      optional_map(%{op: value(), field: value(), n: value()})
    ])
  end

  defp rows, do: list_of(optional_map(Map.new(@names, &{&1, value()})), max_length: 6)

  defp source do
    one_of([
      rows(),
      map(rows(), fn rows ->
        with({:ok, table} <- Table.from(rows), do: table, else: (_ -> rows))
      end),
      member_of([:rows, 42, [1, 2]])
    ])
  end

  defp context do
    one_of([
      constant(%{}),
      map(member_of([:linear, :time, :log, :radial, "log"]), &%{scale: &1}),
      map(value(), &%{now: &1}),
      constant(%{schema: @schema})
    ])
  end

  @tag verifies: "operations-run-faults"
  property "apply never raises: over generated nodes, sources and contexts it answers a table or faults in words" do
    check all(
            nodes <- list_of(step(), min_length: 1, max_length: 3),
            source <- source(),
            context <- context()
          ) do
      case Operations.apply(@registry, nodes, source, context) do
        {:ok, %Table{}} ->
          :ok

        {:error, [_ | _] = faults} ->
          for fault <- faults, do: assert(is_binary(Operations.format_error(fault)))
      end
    end
  end

  # A time of each kind at hour `h` of 2026-01-01: UTC, another zone (built by its fields,
  # no time-zone database involved), naive, and a date (midnight).
  defp time_of(:utc, h), do: DateTime.add(~U[2026-01-01 00:00:00Z], h, :hour)

  defp time_of(:zoned, h) do
    wall = DateTime.add(~U[2026-01-01 00:00:00Z], h + 1, :hour)
    %{wall | time_zone: "Europe/Paris", zone_abbr: "CET", utc_offset: 3600, std_offset: 0}
  end

  defp time_of(:naive, h), do: NaiveDateTime.add(~N[2026-01-01 00:00:00], h, :hour)
  defp time_of(:date, h), do: Date.add(~D[2026-01-01], div(h, 24))

  defp mixed_time,
    do:
      one_of([
        constant(nil),
        bind(member_of([:utc, :zoned, :naive, :date]), fn kind ->
          map(integer(-48..48), &time_of(kind, &1))
        end)
      ])

  # The recurrence guard of macaw_data#141: a typed time column whose values are of
  # different kinds (the list form, spec/01 §1.1) reached `min`'s fold and raised. Every
  # aggregate the registry names, grouped and not, over such a column answers a table or
  # faults, never a raise; and min, max and extent answer what `aggregate/4` answers.
  @tag verifies: "operations-run-faults"
  property "apply never raises over a time column of mixed kinds, through every aggregate" do
    check all(
            times <- list_of(mixed_time(), min_length: 1, max_length: 12),
            groups <- list_of(member_of(["a", "b", nil]), length: length(times)),
            cuts <- list_of(integer(1..4), max_length: 3),
            name <- member_of(Operations.aggregates(@registry)),
            by? <- boolean()
          ) do
      table =
        times
        |> Enum.zip(groups)
        |> chunked(cuts)
        |> Enum.map(fn piece ->
          {ts, gs} = Enum.unzip(piece)
          Table.new!([{"t", :time, ts}, {"g", :category, gs}])
        end)
        |> Enum.reduce(fn piece, acc ->
          {:ok, joined} = Table.append(acc, piece)
          joined
        end)

      options = if name == "quantile", do: %{"p" => 0.5}, else: %{}
      node = Map.merge(%{"op" => "aggregate", "fn" => name, "field" => "t"}, options)
      node = if by?, do: Map.put(node, "by", "g"), else: node

      case Operations.apply(@registry, [node], table, %{}) do
        {:ok, %Table{} = out} ->
          if name in ~w(min max extent) and not by? do
            assert {:ok, value} = Operations.aggregate(@registry, name, times, options)
            assert Table.column(out, name) == [value]
          end

        {:error, [_ | _] = faults} ->
          assert name not in ~w(min max extent count distinct)
          for fault <- faults, do: assert(is_binary(Operations.format_error(fault)))
      end
    end
  end

  # The pairs cut into pieces of the sizes `cuts` gives, the rest last.
  defp chunked(pairs, cuts) do
    {pieces, rest} =
      Enum.reduce(cuts, {[], pairs}, fn cut, {pieces, rest} ->
        case Enum.split(rest, cut) do
          {[], rest} -> {pieces, rest}
          {piece, rest} -> {[piece | pieces], rest}
        end
      end)

    Enum.reverse(if(rest == [], do: pieces, else: [rest | pieces]))
  end
end
