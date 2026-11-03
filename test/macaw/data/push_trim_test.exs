defmodule Macaw.Data.PushTrimTest do
  @moduledoc """
  `Push.trim/2` (spec/01 §4, §4.2, macaw_data#123): a sliding window's holding drops the
  chunks wholly before its start, nothing copied, and a change before the trimmed start
  is counted, not a fault.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table}
  alias Macaw.Data.Schema.Cache
  alias Macaw.Data.Source.Push
  alias Macaw.Data.Table.Chunk

  @schema Schema.new!(%{
            "id" => %{type: :category, identity: true},
            "t" => %{type: :number, window: true},
            "v" => %{type: :number}
          })
  @version Schema.version(@schema)

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
end
