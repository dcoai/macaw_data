defmodule Macaw.Data.TableAppendJoinTest do
  @moduledoc """
  An increment into a holding laid by row count joins its rows after the last chunk's as
  they lie (spec/01 §1.1.4, macaw_data#233): a holding with no window field, a window
  field with no span (a number window at no resolution), a `:point` window, or no origin
  at all. Whatever path `Table.apply/2` takes, every chunk it answers is exactly the
  chunk the full rewrite builds, byte for byte, digest and all. The full rewrite is
  `Macaw.Data.Test.ApplyReference`, `Table.Apply` as it was before.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Schema, Table}
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Test.ApplyReference

  @t0 ~U[2026-01-01 00:00:00Z]
  @rows Table.chunk_rows()

  @header [
    {"c", :category},
    {"k", :color},
    {"p", :point},
    {"s", :text},
    {"t", :number},
    {"u", :time},
    {"v", :number}
  ]

  # How the holding is laid, each by row count: its origin and the schema's window field.
  @layouts [:number, :point, :none, :no_origin]

  defp schema(layout) do
    fields = %{
      "c" => %{type: :category},
      "k" => %{type: :color},
      "p" => %{type: :point},
      "s" => %{type: :text},
      "t" => %{type: :number},
      "u" => %{type: :time},
      "v" => %{type: :number}
    }

    fields =
      case layout do
        :number -> put_in(fields, ["t", :window], true)
        :point -> put_in(fields, ["p", :window], true)
        _ -> fields
      end

    Schema.new!(fields)
  end

  defp origin(:number, offset),
    do: [origin: %{source: "s", resolution: nil, window: "t", span: nil, offset: offset}]

  defp origin(:no_origin, _offset), do: []
  defp origin(_layout, offset), do: [origin: %{source: "s", resolution: nil, offset: offset}]

  # -- generators -------------------------------------------------------------------------

  # A column's values come in a mode, so a holding and an increment often share a form
  # (the join applies) and sometimes don't (the rewrite does).
  defp value("v", :ints), do: one_of([integer(-50..50), constant(nil)])
  defp value("v", :floats), do: one_of([float(min: -50.0, max: 50.0), constant(nil)])
  defp value("v", :mixed), do: one_of([integer(-5..5), float(min: -5.0, max: 5.0)])
  defp value("v", :wide), do: one_of([constant(2 ** 64), constant(0.5), constant(nil)])
  defp value("s", :ints), do: member_of(["a", "b", "é", "", nil])
  defp value("s", :floats), do: member_of(["x", <<255>>, nil])
  defp value("s", :mixed), do: member_of(["a", <<0b10_000000>>, "zz", nil])
  defp value("s", :wide), do: member_of(["a", 1, nil])
  defp value("c", :ints), do: member_of(["x", "y", :z, nil])
  defp value("c", :floats), do: member_of(["y", "w", "x", nil])
  defp value("c", :mixed), do: member_of(["x", true, false, nil])
  defp value("c", :wide), do: member_of([true, false, nil])
  defp value("u", :ints), do: map(integer(0..5), &DateTime.add(@t0, &1))
  defp value("u", :floats), do: map(integer(0..5), &DateTime.add(@t0, &1 * 1000, :millisecond))
  defp value("u", :mixed), do: member_of([@t0, DateTime.add(@t0, 1, :microsecond), nil])
  defp value("u", :wide), do: member_of([@t0, ~N[2026-01-01 00:00:00], nil])
  defp value("p", :ints), do: tuple({integer(-180..180), integer(-90..90)})

  defp value("p", :floats),
    do: tuple({float(min: -180.0, max: 180.0), float(min: -9.0, max: 9.0)})

  defp value("p", :mixed),
    do: one_of([tuple({integer(-5..5), float(min: -5.0, max: 5.0)}), constant(nil)])

  defp value("p", :wide), do: member_of([{2 ** 64, 0}, {0.5, -0.0}, nil])

  defp value("k", :ints), do: member_of([{:color, :red}, {:color, :blue}, nil])
  defp value("k", :floats), do: member_of([{:ramp, :viridis, 0.5}, {:ramp, :viridis, 1}, nil])

  defp value("k", :mixed),
    do: member_of([{:contrast, {:color, :red}}, {:blend, [{:color, :red}, {:color, :blue}]}])

  defp value("k", :wide), do: member_of([{:color, :red}, nil])
  defp value(_c, :none), do: constant(nil)
  # Values a column's type does not hold: the increment is refused whole, its faults compared.
  defp value("v", :bad), do: member_of(["x", 1, nil])
  defp value("p", :bad), do: member_of([{1, :x}, {0, 0}])
  defp value(c, :bad), do: value(c, :wide)

  defp modes(:held), do: member_of([:ints, :ints, :ints, :floats, :mixed, :wide, :none])

  defp modes(:increment),
    do: member_of([:ints, :ints, :ints, :ints, :floats, :mixed, :wide, :none, :bad])

  @columns ~w(c k p s u v)

  defp rows(positions, of) do
    bind(fixed_map(for c <- @columns, into: %{}, do: {c, modes(of)}), fn modes ->
      positions
      |> Enum.map(fn p ->
        fixed_map(for(c <- @columns, into: %{"t" => constant(p)}, do: {c, value(c, modes[c])}))
      end)
      |> fixed_list()
    end)
  end

  # Positions after `last`, at it, anywhere, or none; mostly in order.
  defp positions(last) do
    one_of([
      list_of(integer(last..(last + 25)), max_length: 12),
      list_of(constant(last), min_length: 1, max_length: 3),
      list_of(one_of([integer(0..(last + 15)), constant(nil)]), max_length: 12)
    ])
  end

  defp case_gen do
    gen all(
          layout <- member_of(@layouts),
          # Where the holding starts among the source's rows: so its last chunk has room
          # for all, some or none of an increment's rows.
          offset <- member_of([0, 0, @rows - 30, @rows - 5]),
          held_at <- list_of(one_of([integer(0..60), constant(nil)]), max_length: 30),
          held <- rows(Enum.sort_by(held_at, &order_key/1), :held),
          steps <-
            list_of(
              tuple({positions(Enum.max([0 | Enum.reject(held_at, &is_nil/1)])), integer(0..2)}),
              min_length: 1,
              max_length: 4
            ),
          steps <-
            fixed_list(
              Enum.map(steps, fn {ps, retracts} ->
                tuple({rows(ps, :increment), constant(retracts)})
              end)
            )
        ) do
      %{layout: layout, offset: offset, held: held, steps: steps}
    end
  end

  defp order_key(nil), do: {1, 0}
  defp order_key(p), do: {0, p}

  # -- the holding and its changes --------------------------------------------------------

  defp table(%{layout: layout, offset: offset, held: rows}) do
    Table.new!(
      for({name, type} <- @header, do: {name, type, Enum.map(rows, & &1[name])}),
      origin(layout, offset)
    )
  end

  defp state(%Table{} = table) do
    header = for name <- Table.names(table), do: {name, Table.column_type(table, name)}
    %{header: header, origin: Table.origin(table), chunks: chunks(table), next: table.next}
  end

  defp chunks(table), do: for({chunk, 0, _n} <- Table.chunks(table), do: chunk)

  # Each step applied through both, from the same state; the next step from the result.
  defp run(%{layout: layout, steps: steps} = c) do
    Enum.reduce(steps, table(c), fn {inserts, retracts}, table ->
      held = for chunk <- chunks(table), {row, _} <- Chunk.read(chunk), do: row
      change = change(inserts, Enum.take(held, retracts), layout)
      assert same?(table, change)
      {table, _faults, _unheld} = Table.apply(table, change)
      table
    end)
  end

  defp change(inserts, retracts, layout),
    do: %{
      insert: inserts,
      retract: retracts,
      replace: [],
      schema: schema(layout),
      settled: nil,
      thinned: false
    }

  # `Table.apply/2` against the full rewrite from the same chunks: the same chunks, a chunk
  # left with no row being none; the same next position, faults and unheld count.
  defp same?(table, change) do
    {applied, faults, unheld} = Table.apply(table, change)
    {chunks, next, ref_faults, ref_unheld} = ApplyReference.run(state(table), change)

    assert chunks(applied) == Enum.reject(chunks, &(Chunk.size(&1) == 0))
    {applied.next, faults, unheld} == {next, ref_faults, ref_unheld}
  end

  @tag verifies: "table-open-write"
  property "every chunk an increment appends by row count is the full rewrite's, byte for byte" do
    check all(c <- case_gen(), max_runs: 300) do
      run(c)
    end
  end

  @tag verifies: "table-open-write"
  test "an increment filling the last chunk and starting the next is the full rewrite's" do
    for layout <- @layouts, held <- [@rows - 3, @rows] do
      rows =
        for i <- 0..(held - 1) do
          %{"t" => i, "v" => i / 2, "s" => "s", "c" => "c", "u" => @t0, "p" => nil, "k" => nil}
        end

      table = table(%{layout: layout, offset: 0, held: rows})

      inserts =
        for i <- held..(held + 9),
            do: %{"t" => i, "v" => i / 4, "s" => "é", "c" => "d", "u" => @t0}

      assert same?(table, change(inserts, [], layout))
    end
  end
end
