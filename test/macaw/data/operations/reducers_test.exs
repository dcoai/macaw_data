defmodule Macaw.Data.Operations.ReducersTest do
  # A budget's reducer by name (spec/04 §7, spec/01 §2.4): any registered transform that
  # declares reduces/0, lttb by default, found in the registry finishing is given.
  use ExUnit.Case, async: true

  alias Macaw.Data.{Delivery, Operations, Schema, Table}
  alias Macaw.Data.Source.{Description, Finish, Request}

  @schema Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number}})
  @rows for t <- 1..200, do: %{t: t, v: rem(t * 7919, 23)}
  @delivery Delivery.new(@rows)

  defp finish(opts) do
    {:ok, description} = Description.new(schema: @schema)

    Finish.finish(
      @delivery,
      description,
      Request.new!(budget: 20, now: ~U[2026-10-27 00:00:00Z]),
      opts
    )
  end

  defp ts(delivery), do: Enum.map(Delivery.rows(delivery), & &1.t)

  @tag verifies: "operations-reducers-named"
  test "lttb is the default, and m4 reduces when named, as the step picks" do
    picks = fn node -> @rows |> then(&Operations.apply!(Operations.registry(), [node], &1)) end
    lttb = finish([])

    assert ts(lttb) ==
             Enum.map(Table.rows(picks.(%{op: "lttb", fields: [:t, :v], n: 20})), & &1.t)

    assert lttb.served.reduced_by == :runtime
    assert ts(finish(reduce: "lttb")) == ts(lttb)
    assert length(ts(lttb)) <= 20

    m4 = finish(reduce: "m4")
    assert ts(m4) == Enum.map(Table.rows(picks.(%{op: "m4", fields: [:t, :v], width: 5})), & &1.t)
    assert ts(finish(reduce: :m4)) == ts(m4)
    assert Table.size(m4 |> Delivery.table!()) <= 20
  end

  @tag verifies: "operations-reducers-named"
  test "an enabled package's reducer is named like any other" do
    hosted = Operations.registry([Macaw.Data.Test.Ops])
    every = finish(reduce: "every", operations: hosted)

    # every keeps n rows evenly, its count the budget itself at one row a unit.
    assert length(ts(every)) == 20
    assert hd(ts(every)) == 1 and List.last(ts(every)) == 200

    assert Finish.reduce(@delivery, @schema, 10, "every", hosted) |> ts() |> length() == 10
  end

  @tag verifies: "operations-reducers-named"
  test "an unknown name and a transform that does not reduce each raise naming it" do
    for {name, opts} <- [{"every", []}, {"sort", []}, {"frobnicate", []}, {42, []}] do
      assert_raise ArgumentError, ~r/^reduce: #{inspect(name)} names no registered reducer/, fn ->
        finish([reduce: name] ++ opts)
      end
    end

    assert_raise ArgumentError, ~r/names no registered reducer/, fn ->
      Finish.reduce(@delivery, @schema, nil, "sort")
    end
  end
end
