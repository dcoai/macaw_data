defmodule Macaw.Data.PushHeldSortedTest do
  @moduledoc """
  A push holding says it is sorted by its window field (spec/01 §2.6, macaw_data#239):
  with a chunk span or without one, after the snapshot and after every increment, and
  finishing keeps it.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table, Window}
  alias Macaw.Data.Schema.Cache
  alias Macaw.Data.Source.{Description, Finish, Push, Request}

  @epoch ~U[2026-01-01 00:00:00.000000Z]
  @now ~U[2026-11-12 00:00:00Z]

  defp schema(kind),
    do: Schema.new!(%{"t" => %{type: kind, window: true}, "v" => %{type: :number}})

  defp types(kind), do: %{"t" => kind, "v" => :number}

  # A reading's window value as the source sends it: a number, a DateTime, or a time as
  # its ISO string.
  defp value(nil, _kind, _form), do: nil
  defp value(t, :number, _form), do: t
  defp value(t, :time, :datetime), do: DateTime.add(@epoch, t, :second)
  defp value(t, :time, :iso), do: @epoch |> DateTime.add(t, :second) |> DateTime.to_iso8601()

  defp delivery(ts, kind, form, schema, served) do
    rows = for t <- ts, do: %{"t" => value(t, kind, form), "v" => t || 0}
    Delivery.new!(rows, types: types(kind), schema: Schema.version(schema), served: served)
  end

  defp span(false, _kind), do: nil
  defp span(true, :number), do: 100
  defp span(true, :time), do: Duration.new!(second: 100)

  # The positions of the held window column, `nil` last, in order.
  defp in_order?(table) do
    positions = table |> Table.column("t") |> Enum.map(&Window.position/1)
    {present, absent} = Enum.split_while(positions, &(&1 != nil))
    Enum.all?(absent, &is_nil/1) and present == Enum.sort(present)
  end

  @tag verifies: "push-held-sorted"
  property "the holding is sorted by its window field, with or without a span, through increments" do
    check all(
            kind <- member_of([:number, :time]),
            span? <- boolean(),
            form <- member_of([:datetime, :iso]),
            snapshot <- list_of(one_of([integer(0..5_000), constant(nil)]), max_length: 40),
            increments <-
              list_of(list_of(one_of([integer(0..6_000), constant(nil)]), max_length: 12),
                max_length: 4
              ),
            max_runs: 200
          ) do
      schema = schema(kind)
      ref = make_ref()

      push =
        Push.new!(:ticks, ref,
          cache: Cache.new([{:ticks, schema}]),
          chunk_span: span(span?, kind)
        )

      push =
        push
        |> Push.snapshot(delivery(snapshot, kind, form, schema, position: 0))
        |> Push.drain(fn _ -> flunk("describe asked") end)

      held = Push.held(push).rows
      assert Table.sorted(held) == "t"
      assert in_order?(held)
      assert Table.size(held) == length(snapshot)

      push =
        increments
        |> Enum.with_index(1)
        |> Enum.reduce(push, fn {ts, seq}, push ->
          d = delivery(ts, kind, :datetime, schema, [])
          {:ok, push} = Push.receive(push, Push.increment_message(ref, seq, d))
          push = Push.drain(push, fn _ -> flunk("describe asked") end)

          held = Push.held(push).rows
          assert Table.sorted(held) == "t"
          assert in_order?(held)
          push
        end)

      assert Table.size(Push.held(push).rows) ==
               length(snapshot) + length(List.flatten(increments))

      # Finishing keeps the mark: a window and a budget alike.
      description = Description.new!(schema: schema, supports: [:push])
      request = Request.new!(now: @now, budget: 5)
      {:ok, finished} = Finish.finish(Push.held(push), description, request)
      assert Table.sorted(finished.rows) == "t"
    end
  end

  @tag verifies: "push-held-sorted"
  test "a holding with no window field is sorted by none" do
    schema = Schema.new!(%{"n" => %{type: :number}})
    ref = make_ref()

    push =
      Push.new!(:plain, ref, cache: Cache.new([{:plain, schema}]))
      |> Push.snapshot(
        Delivery.new!([%{"n" => 3}, %{"n" => 1}],
          types: %{"n" => :number},
          schema: Schema.version(schema),
          served: [position: 0]
        )
      )
      |> Push.drain(fn _ -> flunk("describe asked") end)

    assert Table.sorted(Push.held(push).rows) == nil
    assert Table.column(Push.held(push).rows, "n") == [3, 1]
  end

  @tag verifies: "push-held-sorted"
  test "a spanless push's snapshot of ISO times out of order is held, sorted, at their instants" do
    schema = schema(:time)
    ref = make_ref()
    ts = [30, 10, nil, 20]

    push =
      Push.new!(:ticks, ref, cache: Cache.new([{:ticks, schema}]))
      |> Push.snapshot(delivery(ts, :time, :iso, schema, position: 0))
      |> Push.drain(fn _ -> flunk("describe asked") end)

    assert Push.take_errors(push) |> elem(0) == []
    held = Push.held(push).rows
    assert Table.sorted(held) == "t"

    assert Table.column(held, "t") == [
             value(10, :time, :datetime),
             value(20, :time, :datetime),
             value(30, :time, :datetime),
             nil
           ]
  end
end
