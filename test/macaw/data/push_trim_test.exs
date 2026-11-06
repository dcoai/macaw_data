defmodule Macaw.Data.PushTrimTest do
  @moduledoc """
  `Push.trim/2` (spec/01 §4, §4.2, macaw_data#123): a sliding window's holding drops the
  chunks wholly before its start, nothing copied, and a change before the trimmed start
  is counted, not a fault.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table, Window}
  alias Macaw.Data.Schema.Cache
  alias Macaw.Data.Source.Push
  alias Macaw.Data.Table.Chunk

  @schema Schema.new!(%{
            "id" => %{type: :category, identity: true},
            "t" => %{type: :number, window: true},
            "v" => %{type: :number}
          })
  @version Schema.version(@schema)

  # Reductions for a trim that drops one chunk and reads another of 8,192 rows.
  @trim_budget 5_000

  defp push(schema \\ @schema),
    do: Push.new!(:ticks, make_ref(), cache: Cache.new([{:ticks, schema}]), chunk_span: 10)

  defp row(t), do: %{"id" => "a", "t" => t, "v" => t}

  defp drain(push), do: Push.drain(push, fn _ -> flunk("describe asked") end)

  defp holding(ts, served \\ [], schema \\ @schema) do
    served = Keyword.merge([position: 0], served)
    rows = Enum.map(ts, &row/1)
    snapshot = Delivery.new!(rows, schema: Schema.version(schema), served: served)
    schema |> push() |> Push.snapshot(snapshot) |> drain()
  end

  defp change(push, seq, opts) do
    {rows, opts} = Keyword.pop(opts, :rows, [])
    d = Delivery.new!(rows, [schema: @version] ++ opts)
    {:ok, push} = Push.receive(push, Push.increment_message(push.ref, seq, d))
    drain(push)
  end

  defp ts(push), do: push |> Push.held() |> Delivery.table!() |> Table.column("t")

  defp chunks(push),
    do:
      for(
        {c, f, n} <- Table.chunks(Push.held(push).rows),
        do: {Chunk.id(c), Chunk.version(c), f, n}
      )

  @tag verifies: "push-trim"
  test "trim drops the chunks wholly before from, keeps every other by id and version, and narrows the window" do
    push = holding(0..34, window: [0, 34], complete_until: 20)
    [_first, second, third, fourth] = chunks(push)

    assert {:ok, trimmed} = Push.trim(push, 15)

    # The chunk [10, 20) straddles 15 and is kept whole; nothing is copied.
    assert chunks(trimmed) == [second, third, fourth]
    assert ts(trimmed) == Enum.to_list(10..34)

    served = Push.held(trimmed).served
    assert served.window == [15, 34]
    assert served.complete_until == 20

    # From exactly a chunk's start, that chunk stays; past every row, the last chunk does
    # not, and the window still keeps its upper end.
    assert {:ok, at_start} = Push.trim(push, 20)
    assert chunks(at_start) == [third, fourth]
    assert {:ok, past} = Push.trim(push, 40)
    assert chunks(past) == []
    assert Push.held(past).served.window == [40, 34]

    # Never widened: a from before the held start keeps it, and a second, earlier trim
    # keeps the first's start.
    assert {:ok, early} = Push.trim(push, -5)
    assert chunks(early) == chunks(push)
    assert Push.held(early).served.window == [0, 34]
    assert {:ok, again} = Push.trim(trimmed, 12)
    assert Push.held(again).served.window == [15, 34]
    assert chunks(again) == chunks(trimmed)

    # trim!/2 is the push itself.
    assert Push.trim!(push, 15) == trimmed
  end

  @tag verifies: "push-trim"
  test "a time window trims by instant, whatever kind of time from is" do
    times = Schema.new!(%{"t" => %{type: :time, window: true}, "v" => %{type: :number}})
    at = fn s -> DateTime.add(~U[2026-11-03 00:00:00Z], s, :second) end
    rows = for s <- 0..29, do: %{"t" => at.(s), "v" => s}

    push =
      Push.new!(:ticks, make_ref(),
        cache: Cache.new([{:ticks, times}]),
        chunk_span: Duration.new!(second: 10)
      )
      |> Push.snapshot(Delivery.new!(rows, schema: Schema.version(times), served: [position: 0]))
      |> drain()

    assert length(Table.chunks(Push.held(push).rows)) == 3

    assert {:ok, naive} = Push.trim(push, ~N[2026-11-03 00:00:10])
    assert {:ok, utc} = Push.trim(push, at.(10))
    assert Push.held(naive).rows == Push.held(utc).rows
    assert length(Table.chunks(Push.held(utc).rows)) == 2
    assert Push.held(naive).served.window == [~N[2026-11-03 00:00:10], nil]

    assert Push.trim(push, 10) == {:error, [{[:from], {:type, :time}}]}
  end

  @tag verifies: "push-trim"
  test "nothing held, no window field, a point window field and an open from are no-ops; a wrong type is a fault" do
    empty = push()
    assert Push.trim(empty, 10) == {:ok, empty}
    assert Push.trim(empty, :not_a_number) == {:ok, empty}

    held = holding(0..19)
    assert Push.trim(held, nil) == {:ok, held}
    assert Push.trim(held, ~U[2026-11-03 00:00:00Z]) == {:error, [{[:from], {:type, :number}}]}
    assert Push.trim(held, "15") == {:error, [{[:from], {:type, :number}}]}

    assert_raise Macaw.Data.Error, ~r/cannot be trimmed: from: must be a number/, fn ->
      Push.trim!(held, "15")
    end

    unwindowed = Schema.new!(%{"t" => %{type: :number}, "v" => %{type: :number}})
    loose = holding(0..19, [], unwindowed)
    assert Push.trim(loose, 15) == {:ok, loose}

    points = Schema.new!(%{"at" => %{type: :point, window: true}, "v" => %{type: :number}})
    at = %{lon: 1.0, lat: 2.0}

    placed =
      Push.new!(:ticks, make_ref(), cache: Cache.new([{:ticks, points}]))
      |> Push.snapshot(
        Delivery.new!([%{"at" => at, "v" => 1}],
          schema: Schema.version(points),
          served: [position: 0]
        )
      )
      |> drain()

    assert Push.trim(placed, 15) == {:ok, placed}
  end

  @tag verifies: "push-trimmed"
  test "after a trim, a change before its start is counted :trimmed; one at or after it applies as before" do
    push = holding(0..34, window: [0, 34]) |> Push.trim!(15)

    # A retraction of a dropped row, and a replace range wholly before the start: counted.
    push = change(push, 1, retracted: [row(3)], replace: [%{from: 0, to: 10, rows: []}])
    assert push.ignored == %{trimmed: 2}
    assert Push.take_errors(push) |> elem(0) == []
    assert ts(push) == Enum.to_list(10..34)

    # A retraction of a row still held in the straddling chunk applies, though before the
    # start; so does a replace reaching past it, and one after it.
    push = change(push, 2, retracted: [row(12)])
    assert ts(push) == Enum.to_list(10..11) ++ Enum.to_list(13..34)

    push = change(push, 3, replace: [%{from: 10, to: 16, rows: [row(14)]}])
    assert ts(push) == [14] ++ Enum.to_list(16..34)

    push = change(push, 4, replace: [%{from: 30, to: nil, rows: [row(31)]}])
    assert ts(push) == [14] ++ Enum.to_list(16..29) ++ [31]
    assert push.ignored == %{trimmed: 2}

    # A late insertion before the start is still placed, and the next trim drops it.
    push = change(push, 5, rows: [row(2)])
    assert hd(ts(push)) == 2
    assert {:ok, again} = Push.trim(push, 15)
    refute 2 in ts(again)

    # A retraction of a row never held after the start stays a fault.
    push = change(push, 6, retracted: [%{row(50) | "id" => "z"}])
    assert {[{:retract, :not_held, _}], push} = Push.take_errors(push)

    # A snapshot replaces the holding and clears the trimmed start: a retraction of a row
    # not held before it is a fault again.
    snapshot = Delivery.new!(Enum.map(20..29, &row/1), schema: @version, served: [position: 6])
    push = push |> Push.snapshot(snapshot) |> drain()
    push = change(push, 7, retracted: [%{row(3) | "id" => "z"}])
    assert {[{:retract, :not_held, _}], _push} = Push.take_errors(push)
  end

  @tag verifies: "push-trim"
  property "the kept rows are a suffix of the held rows holding every row at or after from" do
    check all(
            ts <- list_of(integer(-50..50), max_length: 80),
            from <- integer(-60..60),
            span <- member_of([1, 5, 10, 25])
          ) do
      push =
        Push.new!(:ticks, make_ref(), cache: Cache.new([{:ticks, @schema}]), chunk_span: span)
        |> Push.snapshot(
          Delivery.new!(Enum.map(ts, &row/1), schema: @version, served: [position: 0])
        )
        |> drain()

      held = ts(push)
      {:ok, trimmed} = Push.trim(push, from)
      kept = ts(trimmed)

      assert kept == Enum.take(held, -length(kept))
      assert Enum.filter(held, &(&1 >= from)) -- kept == []

      # Every chunk kept is a chunk held, the same by id and version.
      assert chunks(trimmed) == Enum.take(chunks(push), -length(chunks(trimmed)))

      # Only whole chunks are dropped: what was dropped is every row of its chunks.
      dropped = length(held) - length(kept)
      assert dropped in Enum.scan([0 | Enum.map(chunks(push), &elem(&1, 3))], &(&1 + &2))
    end
  end

  # -- the last value decides (macaw_data#201) ---------------------------------------------

  # What reading every value drops, the decision the last value stands in for.
  defp every_value_dropped(table, name, from) do
    table
    |> Table.chunks()
    |> Enum.reduce_while(0, fn {chunk, first, count}, n ->
      if Enum.all?(
           Chunk.values(chunk, name, first, count),
           &(&1 != nil and Window.compare(&1, from) == :lt)
         ),
         do: {:cont, n + count},
         else: {:halt, n}
    end)
  end

  defp assert_same_decision(push, from) do
    table = Push.held(push).rows
    held = Table.column(table, "t")

    # The held order the decision stands on, in the form the failure should name.
    positions = Enum.map(held, &Window.position/1)
    {present, absent} = Enum.split_while(positions, &(&1 != nil))
    assert present == Enum.sort(present)
    assert Enum.all?(absent, &is_nil/1)

    dropped = every_value_dropped(table, "t", from)
    assert {:ok, trimmed} = Push.trim(push, from)
    assert Table.column(Push.held(trimmed).rows, "t") == Enum.drop(held, dropped)
    trimmed
  end

  @time_schema Schema.new!(%{
                 "id" => %{type: :category, identity: true},
                 "t" => %{type: :time, window: true},
                 "v" => %{type: :number}
               })

  # A generated position as a value of the kind: days from a fixed date, and a fixed
  # offset for a zoned time, so each kind's order is its positions' order.
  defp at(_kind, nil), do: nil
  defp at(:integer, i), do: i
  defp at(:float, i), do: i * 1.0
  defp at(:utc, i), do: DateTime.add(~U[2026-01-01 00:00:00Z], i * 86_400)
  defp at(:naive, i), do: NaiveDateTime.add(~N[2026-01-01 00:00:00], i * 86_400)
  defp at(:date, i), do: Date.add(~D[2026-01-01], i)

  defp at(:zoned, i),
    do: %{at(:utc, i) | utc_offset: 3600, time_zone: "Etc/GMT-1", zone_abbr: "+01"}

  defp at(:mixed, i), do: at(Enum.at([:utc, :naive, :date, :zoned], Integer.mod(i, 4)), i)

  defp span(kind, n) when kind in [:integer, :float], do: n
  defp span(_kind, nil), do: nil
  defp span(_kind, n), do: Duration.new!(second: n * 86_400)

  defp schema_of(kind) when kind in [:integer, :float], do: @schema
  defp schema_of(_kind), do: @time_schema

  defp step(kind, push, seq, {:rows, is}),
    do: send_change(kind, push, seq, rows: Enum.map(is, &at_row(kind, &1)))

  defp step(kind, push, seq, {:retract, i}),
    do: send_change(kind, push, seq, retracted: [at_row(kind, i)])

  defp step(kind, push, seq, {:replace, from, to, is}) do
    range = %{from: at(kind, from), to: at(kind, to), rows: Enum.map(is, &at_row(kind, &1))}
    send_change(kind, push, seq, replace: [range])
  end

  defp step(kind, push, seq, {:settle, i}),
    do: send_change(kind, push, seq, served: [complete_until: at(kind, i)])

  defp at_row(kind, i), do: %{"id" => "a", "t" => at(kind, i), "v" => 1}

  defp send_change(kind, push, seq, opts) do
    {rows, opts} = Keyword.pop(opts, :rows, [])
    d = Delivery.new!(rows, [schema: Schema.version(schema_of(kind))] ++ opts)
    {:ok, push} = Push.receive(push, Push.increment_message(push.ref, seq, d))
    drain(push)
  end

  # A step of a holding's life, a position nil now and then.
  defp life_step do
    position = integer(-30..30)
    maybe = frequency([{9, position}, {1, constant(nil)}])

    one_of([
      map(list_of(maybe, max_length: 6), &{:rows, &1}),
      map(position, &{:retract, &1}),
      map(
        tuple({position, integer(0..12), list_of(position, max_length: 3)}),
        fn {from, width, is} -> {:replace, from, from + width, is} end
      ),
      map(position, &{:settle, &1}),
      map(position, &{:trim, &1})
    ])
  end

  @tag verifies: "push-trim-last-value"
  property "a chunk's last value decides as reading every value does, on every holding" do
    check all(
            kind <- member_of([:integer, :float, :utc, :naive, :date, :zoned, :mixed]),
            start <-
              list_of(frequency([{9, integer(-30..30)}, {1, constant(nil)}]), max_length: 40),
            span <- member_of([nil, 1, 5, 10, 25]),
            settled <- one_of([constant(nil), integer(0..30)]),
            steps <- list_of(life_step(), max_length: 8),
            view <- one_of([constant(nil), tuple({integer(0..60), integer(0..60)})]),
            from <- integer(-40..40),
            from_kind <- member_of([:same, :other])
          ) do
      schema = schema_of(kind)

      push =
        Push.new!(:ticks, make_ref(),
          cache: Cache.new([{:ticks, schema}]),
          chunk_span: span(kind, span)
        )
        |> Push.snapshot(
          Delivery.new!(Enum.map(start, &at_row(kind, &1)),
            schema: Schema.version(schema),
            served: [position: 0, complete_until: at(kind, settled)]
          )
        )
        |> drain()

      {push, _seq} =
        Enum.reduce(steps, {push, 1}, fn
          {:trim, i}, {push, seq} ->
            {assert_same_decision(push, at(kind, i)), seq}

          other, {push, seq} ->
            {step(kind, push, seq, other), seq + 1}
        end)

      push = viewed(push, view)

      from =
        case {kind, from_kind} do
          {kind, :other} when kind in [:integer, :float] -> at(:float, from)
          {_kind, :other} -> at(:naive, from)
          {kind, :same} -> at(kind, from)
        end

      assert_same_decision(push, from)
    end
  end

  # The holding as a run of its rows, so a chunk's view starts and ends inside it.
  defp viewed(push, nil), do: push

  defp viewed(push, {a, b}) do
    held = Push.held(push)
    size = Table.size(held.rows)
    start = rem(a, size + 1)
    count = rem(b, size - start + 1)
    %{push | held: %{held | rows: Table.slice(held.rows, start, count)}}
  end

  @tag verifies: "push-trim-last-value"
  test "a settled chunk's delta is read through: its last row retracted, placed, or all of them" do
    push =
      holding(0..14, position: 0, complete_until: 10)
      |> change(1, retracted: [row(9)])

    assert [{settled, _, 9}, {_open, _, 5} | _] = Table.chunks(Push.held(push).rows)
    assert Chunk.delta?(settled)

    # 8 is the chunk's last now, so 9 drops it where the row retracted would have kept it.
    assert {:ok, kept} = Push.trim(push, 8)
    assert ts(kept) == ts(push)
    assert {:ok, gone} = Push.trim(push, 9)
    assert ts(gone) == Enum.to_list(10..14)
    assert_same_decision(push, 8)
    assert_same_decision(push, 9)

    # A late row placed in the settled chunk becomes its last, and keeps it.
    placed = change(push, 2, rows: [row(9)])
    assert {:ok, again} = Push.trim(placed, 9)
    assert ts(again) == ts(placed)

    # A settled chunk with no rows left isn't a run of the table, so no run is empty.
    empty = change(push, 2, replace: [%{from: 0, to: 10, rows: []}])
    assert [{_open, 0, 5} | _] = Table.chunks(Push.held(empty).rows)
    assert_same_decision(empty, -100)
    assert_same_decision(empty, 12)
  end

  @tag verifies: "push-trim-last-value"
  test "a row of no window value keeps its chunk, whatever the values before it" do
    d = Delivery.new!(Enum.map([0, 1, 2, nil], &row/1), schema: @version, served: [position: 0])
    push = @schema |> push_without_span() |> Push.snapshot(d) |> drain()

    assert [{_chunk, 0, 4}] = Table.chunks(Push.held(push).rows)
    assert {:ok, kept} = Push.trim(push, 100)
    assert ts(kept) == [0, 1, 2, nil]
    assert_same_decision(push, 100)

    # On a span a row of no window value lies in no slot, so it is a chunk of its own.
    spanned = holding([0, 1, 2, nil])
    assert {:ok, trimmed} = Push.trim(spanned, 100)
    assert ts(trimmed) == [nil]
    assert_same_decision(spanned, 100)
  end

  @tag verifies: "push-trim-last-value"
  test "a trim costs the chunks it walks, never the rows in them" do
    start = ~U[2026-01-01 00:00:00Z]
    rows = for i <- 0..49_999, do: %{"id" => "a", "t" => DateTime.add(start, i), "v" => 1}

    snapshot =
      Delivery.new!(rows,
        schema: Schema.version(@time_schema),
        served: [position: 0, resolution: 1]
      )

    push = @time_schema |> push_without_span() |> Push.snapshot(snapshot) |> drain()

    [{_, _, first}, {_, _, second} | _] = chunks = Table.chunks(Push.held(push).rows)
    assert length(chunks) > 2 and second == Table.chunk_rows()

    # Late in the second chunk: one chunk dropped, and one read and kept.
    from = DateTime.add(start, first + second - 2)

    {:reductions, before} = Process.info(self(), :reductions)
    {:ok, trimmed} = Push.trim(push, from)
    {:reductions, later} = Process.info(self(), :reductions)

    assert length(Table.chunks(Push.held(trimmed).rows)) == length(chunks) - 1
    assert later - before < @trim_budget
  end

  defp push_without_span(schema),
    do: Push.new!(:ticks, make_ref(), cache: Cache.new([{:ticks, schema}]))
end
