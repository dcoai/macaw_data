defmodule Macaw.Data.TableApplyKeysTest do
  @moduledoc """
  An increment's row keys are matched to the header once per increment (spec/01 §1.1.4,
  macaw_data#215): rows that spell the columns' names as strings or atoms, mixed in a row
  and across rows, with keys no column spells, and retractions spelled the same way, apply
  exactly as matching each key against every column did (`Macaw.Data.Test.ApplyReference`).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Schema, Table}
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Test.ApplyReference

  @t0 ~U[2026-01-01 00:00:00Z]

  @names ~w(t v c)

  defp schema,
    do:
      Schema.new!(%{
        "t" => %{type: :time, window: true},
        "v" => %{type: :number},
        "c" => %{type: :category}
      })

  defp header, do: [{"t", :time}, {"v", :number}, {"c", :category}]

  # A key that spells a column, as the string or the atom, or none: a key of another
  # kind (a number, a tuple, a list) or a name the header lacks.
  @atoms %{"t" => :t, "v" => :v, "c" => :c}

  defp key(name), do: member_of([name, name, @atoms[name]])

  defp extra, do: member_of([1, 1.0, {:t}, ["t"], "zz", :zz, nil])

  defp value("t"),
    do:
      one_of([
        map(integer(0..40), &DateTime.add(@t0, &1)),
        map(integer(0..40), &(DateTime.add(@t0, &1) |> DateTime.to_naive()))
      ])

  defp value("v"), do: one_of([integer(-5..5), float(min: -5.0, max: 5.0), constant(nil)])
  defp value("c"), do: member_of(["x", :y, "y", nil])

  defp row do
    gen all(
          keys <- fixed_list(Enum.map(@names, &key/1)),
          values <- fixed_list(Enum.map(@names, &value/1)),
          extras <- list_of(tuple({extra(), integer(0..3)}), max_length: 2)
        ) do
      Map.new(Enum.zip(keys, values) ++ extras)
    end
  end

  defp table(rows) do
    rows = Enum.sort_by(rows, &DateTime.to_unix(&1["t"], :microsecond))

    Table.new!(for({name, type} <- header(), do: {name, type, Enum.map(rows, & &1[name])}),
      origin: %{source: "s", resolution: 1, window: "t", span: Duration.new!(second: 10)}
    )
  end

  defp held_row do
    gen all(
          t <- integer(0..30),
          v <- integer(-5..5),
          c <- member_of(["x", "y", nil])
        ) do
      %{"t" => DateTime.add(@t0, t), "v" => v, "c" => c}
    end
  end

  defp chunks(table), do: for({chunk, 0, _n} <- Table.chunks(table), do: chunk)

  defp state(table),
    do: %{header: header(), origin: Table.origin(table), chunks: chunks(table), next: table.next}

  # A held row spelled again with other keys, for a retraction.
  defp respelled(row, keys), do: Map.new(row, fn {k, v} -> {Map.get(keys, k, k), v} end)

  @tag verifies: "table-apply-keys"
  property "rows spelling the columns any way apply as matching each key against every column" do
    check all(
            held <- list_of(held_row(), min_length: 1, max_length: 30),
            inserts <- list_of(row(), max_length: 12),
            retracts <- integer(0..2),
            atoms? <- boolean(),
            settled <- member_of([nil, DateTime.add(@t0, 10)])
          ) do
      table = table(held)
      spelled = if atoms?, do: @atoms, else: %{}
      held_rows = for chunk <- chunks(table), {row, _} <- Chunk.read(chunk), do: row

      change = %{
        insert: inserts,
        retract: held_rows |> Enum.take(retracts) |> Enum.map(&respelled(&1, spelled)),
        replace: [],
        schema: schema(),
        settled: settled,
        thinned: false
      }

      {applied, faults, unheld} = Table.apply(table, change)
      {ref, next, ref_faults, ref_unheld} = ApplyReference.run(state(table), change)

      assert chunks(applied) == Enum.reject(ref, &(Chunk.size(&1) == 0))
      assert {applied.next, faults, unheld} == {next, ref_faults, ref_unheld}
    end
  end
end
