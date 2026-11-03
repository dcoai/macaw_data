defmodule Macaw.Data.WindowPositionTest do
  @moduledoc """
  A time's position is its instant on `Order.instant/1`'s one scale, integer microseconds,
  whatever its kind (spec/01 §2.4, macaw_data#127): `latest` tells naive times a
  microsecond apart, and a reducer keeps the same rows of one series whichever kind of
  time it is given as, the rows the `lttb` and `m4` transforms keep over the time column.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Operations, Schema, Table, Window}
  alias Macaw.Data.Operations.Transforms.{Lttb, M4}
  alias Macaw.Data.Source.{Description, Finish, Order, Request}

  @now ~U[2026-10-27 00:00:00Z]
  @base ~U[2026-01-01 00:00:00Z]

  defp as(:utc, us), do: DateTime.add(@base, us, :microsecond)
  defp as(:naive, us), do: DateTime.to_naive(as(:utc, us))
  defp as(:date, us), do: DateTime.to_date(as(:utc, us))

  @tag verifies: "window-position-instant"
  test "naive times a microsecond apart have different, ordered positions (the #127 snippet)" do
    a = Window.position(~N[2026-01-01 00:00:00.000001])
    b = Window.position(~N[2026-01-01 00:00:00.000002])
    refute a == b
    assert b - a === 1

    for t <- [~U[2026-01-01 00:00:00.5Z], ~N[2026-01-01 00:00:00.5], ~D[2026-01-01]],
        do: assert(Window.position(t) == Order.instant(t))

    assert Window.position(~D[2026-01-02]) - Window.position(~D[2026-01-01]) == 86_400_000_000
    assert Window.position(~N[2026-01-01 00:00:00]) == Window.position(~D[2026-01-01])
    assert Window.position(2.5) == 2.5
    assert Window.position("2026") == nil
  end

  defp finish(subject, schema, fields) do
    request = Request.new!([now: @now] ++ fields)
    Finish.finish(Delivery.new!(subject), Description.new!(schema: schema), request)
  end

  @tag verifies: "window-position-instant"
  property "latest keeps each identity's later time for any microsecond spacing, rows and table" do
    schema =
      Schema.new!(%{
        t: %{type: :time, window: true},
        id: %{type: :category, identity: true},
        v: %{type: :number}
      })

    check all(
            kind <- member_of([:naive, :utc]),
            spacing <- list_of(integer(1..3), min_length: 1, max_length: 12),
            ids <- list_of(member_of(["a", "b"]), length: length(spacing)),
            seed <- integer(0..1000)
          ) do
      steps = Enum.scan(spacing, &(&1 + &2))

      rows =
        for {{us, id}, v} <- Enum.with_index(Enum.zip(steps, ids)),
            do: %{t: as(kind, us), id: id, v: v}

      :rand.seed(:exsss, {seed, 1, 2})
      shuffled = Enum.shuffle(rows)

      expected =
        rows
        |> Enum.group_by(& &1.id)
        |> Map.values()
        |> Enum.map(fn group -> List.last(group).v end)
        |> Enum.sort()

      assert {:ok, %Delivery{rows: kept}} = finish(shuffled, schema, latest: true)
      assert kept |> Enum.map(& &1.v) |> Enum.sort() == expected

      table =
        Table.new!([
          {:t, :time, Enum.map(shuffled, & &1.t)},
          {:id, :category, Enum.map(shuffled, & &1.id)},
          {:v, :number, Enum.map(shuffled, & &1.v)}
        ])

      assert {:ok, %Delivery{rows: %Table{} = columnar}} = finish(table, schema, latest: true)
      assert columnar |> Table.column(:v) |> Enum.sort() == expected
    end
  end

  # -- the rescaling guard: the reducers keep the same rows whatever the kind ---------------

  defp series(kind, steps, ys) do
    times = steps |> Enum.scan(&(&1 + &2)) |> Enum.map(&as(kind, &1))
    Enum.zip_with(times, ys, &%{t: &1, v: &2})
  end

  defp reduced(rows, budget, method) do
    schema = Schema.new!(%{t: %{type: :time, window: true}, v: %{type: :number}})
    {:ok, delivery} = Finish.reduce(Delivery.new!(rows), schema, budget, method)
    Enum.map(Delivery.rows!(delivery), &Order.instant(&1.t))
  end

  # The rows the transform keeps over the time column on its own time scale; a series
  # within the budget is kept whole, as `Finish.reduce/5` keeps it.
  defp transformed(rows, budget, _module) when length(rows) <= budget,
    do: Enum.map(rows, &Order.instant(&1.t))

  defp transformed(rows, budget, module) do
    {count, per} = module.reduces()
    least = if module == Lttb, do: 3, else: 1

    {:ok, [node]} =
      Operations.validate(
        Operations.registry(),
        [%{"op" => module.name(), "fields" => ["t", "v"], count => max(least, div(budget, per))}],
        %{}
      )

    table =
      Table.new!([{"t", :time, Enum.map(rows, & &1.t)}, {"v", :number, Enum.map(rows, & &1.v)}])

    node |> module.run(table, %{}) |> Table.column("t") |> Enum.map(&Order.instant/1)
  end

  defp ys(n), do: list_of(one_of([float(min: 0.0, max: 100.0), integer(0..5)]), length: n)

  @tag verifies: "window-position-instant"
  property "a series reduces to the same rows as dates, naive times and UTC times, and as the transforms keep" do
    check all(
            n <- integer(40..400),
            day_steps <- list_of(member_of([0, 1, 1, 2, 5]), length: n),
            us_steps <- list_of(integer(1..5_000_000), length: n),
            ys <- ys(n),
            budget <- integer(5..60),
            method <- member_of(["lttb", "m4"]),
            max_runs: 60
          ) do
      module = if method == "lttb", do: Lttb, else: M4
      day = 86_400_000_000
      by_days = Enum.map(day_steps, &(&1 * day))

      dates = reduced(series(:date, by_days, ys), budget, method)
      assert reduced(series(:naive, by_days, ys), budget, method) == dates
      assert reduced(series(:utc, by_days, ys), budget, method) == dates
      assert transformed(series(:date, by_days, ys), budget, module) == dates

      naive = reduced(series(:naive, us_steps, ys), budget, method)
      assert reduced(series(:utc, us_steps, ys), budget, method) == naive
      assert transformed(series(:naive, us_steps, ys), budget, module) == naive
    end
  end
end
