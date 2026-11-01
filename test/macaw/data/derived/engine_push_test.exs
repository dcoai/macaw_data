defmodule Macaw.Data.Derived.EnginePushTest do
  # A pushed delivery is new when it is not, value for value, the one last seen
  # (spec/02 §8.2; macaw_data#106): everything but its rows exactly, and its rows by the
  # table's identity (spec/01 §1.1.2), as an answer's change is told (spec/02 §8.2).
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Derived, Schema, Table}
  alias Macaw.Data.Derived.Engine
  alias Macaw.Data.Test.Gen

  @given Schema.new!(%{n: %{type: :number}})

  # `a` answers its input's rows as given; `b` reads `a`.
  defp engine do
    a =
      Derived.new!(
        id: :a,
        from: [given: nil],
        schema: %{n: %{type: :number}},
        elixir: "fn %{given: rows} -> rows end"
      )

    b =
      Derived.new!(
        id: :b,
        from: [a: nil],
        schema: %{n: %{type: :number}},
        elixir: "fn %{a: rows} -> [%{n: Enum.count(rows)}] end"
      )

    {:ok, engine} =
      Engine.new(%{["a"] => a, ["b"] => b}, sources: [:given], debounce: 0)

    engine
  end

  defp push(engine, delivery, now),
    do: Engine.push(engine, %{given: delivery}, %{given: @given}, now)

  # Whether the second push, after the first's pulse ran, marks `a`'s readers.
  defp marked?(first, second) do
    engine = engine() |> push(first, 0) |> Engine.run(0) |> push(second, 1)
    Engine.due(engine) != nil
  end

  # -- generated deliveries -------------------------------------------------------------------

  defp value, do: one_of([integer(-3..3), Gen.float(min: -3.0, max: 3.0), constant(-0.0)])

  # One run of values and another: the same, or the first with one change only an exact
  # comparison tells apart (an integer as a float, 0.0 as -0.0), a value replaced or a row
  # dropped.
  defp values do
    gen all(
          first <- list_of(value(), min_length: 1, max_length: 6),
          change <- member_of([:same, :float, :zero, :value, :drop]),
          at <- integer(0..5),
          other <- value()
        ) do
      i = rem(at, length(first))

      second =
        case change do
          :same -> first
          :drop -> List.delete_at(first, i)
          :value -> List.replace_at(first, i, other)
          :float -> List.update_at(first, i, &if(is_integer(&1), do: &1 * 1.0, else: &1))
          :zero -> List.update_at(first, i, &if(&1 === 0.0, do: -0.0, else: 0.0))
        end

      {first, second}
    end
  end

  defp table(values) do
    {:ok, table} = Table.new([{:n, :number, values}])
    table
  end

  # The table cut into two chunks at `cut`: the same values, laid out apart.
  defp recut(table, cut) do
    {:ok, recut} =
      Table.from_chunks(
        [n: :number],
        Table.chunks(Table.slice(table, 0, cut)) ++ Table.chunks(Table.slice(table, cut, 99))
      )

    recut
  end

  # -- the change of a pushed delivery ---------------------------------------------------------

  @tag verifies: "derived-engine-push"
  property "a push marks the readers exactly when the rows differ by identity or a served fact does" do
    check all(
            {first, second} <- values(),
            form <- member_of([:rows, :table]),
            cut <- integer(0..6),
            {note_a, note_b} <- member_of([{nil, nil}, {"x", "x"}, {"x", "y"}]),
            max_runs: 100
          ) do
      {rows_a, rows_b, rows_differ?} =
        case form do
          :rows ->
            {a, b} = {Enum.map(first, &%{n: &1}), Enum.map(second, &%{n: &1})}
            {a, b, a !== b}

          :table ->
            {a, b} = {table(first), recut(table(second), cut)}
            {a, b, Table.size(a) != Table.size(b) or Table.column(a, :n) !== Table.column(b, :n)}
        end

      a = Delivery.new(rows_a, served: [note: note_a])
      b = Delivery.new(rows_b, served: [note: note_b])

      assert marked?(a, b) == (rows_differ? or note_a != note_b)
    end
  end

  @tag verifies: "derived-engine-push"
  test "1 then 1.0 marks the readers, and the answer downstream changes" do
    assert marked?(Delivery.new([%{n: 1}]), Delivery.new([%{n: 1.0}]))

    engine =
      engine()
      |> push(Delivery.new([%{n: 1}]), 0)
      |> Engine.run(0)
      |> push(Delivery.new([%{n: 1.0}]), 1)
      |> Engine.run(1)

    assert Table.column(Engine.outputs(engine)[["a"]].rows, "n") === [1.0]
    assert Engine.runs(engine)[["a"]] == 2
  end

  @tag verifies: "derived-engine-push"
  test "one table chunked two ways marks nothing, and its rows as a list are another form" do
    table = table(Enum.map(1..10, &(&1 * 1.0)))

    refute marked?(Delivery.new(table), Delivery.new(recut(table, 4)))
    refute marked?(Delivery.new([%{n: 1}]), Delivery.new([%{n: 1}]))
    assert marked?(Delivery.new(table), Delivery.new(Table.rows(table)))
  end

  @tag verifies: "derived-engine-push"
  test "a retracted row's 1 then 1.0 marks the readers" do
    assert marked?(
             Delivery.new([%{n: 2}], retracted: [%{n: 1}]),
             Delivery.new([%{n: 2}], retracted: [%{n: 1.0}])
           )
  end

  # The engine's own answer check: a watermark of 1 then 1.0 is a changed answer, so `b`
  # runs again (spec/02 §8.6).
  @tag verifies: "derived-engine-push"
  test "a served watermark of 1 then 1.0 is a change, to the push and to the answer" do
    at = fn cu -> Delivery.new([%{n: 2}], served: [complete_until: cu]) end
    assert marked?(at.(1), at.(1.0))

    engine =
      engine()
      |> push(at.(1), 0)
      |> Engine.run(0)
      |> push(at.(1.0), 1)
      |> Engine.run(1)

    assert Engine.outputs(engine)[["a"]].served.complete_until === 1.0
    assert Engine.runs(engine)[["b"]] == 2
  end
end
