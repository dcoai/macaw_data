defmodule Macaw.Data.PushChangelogTest do
  @moduledoc """
  The changelog (spec/01 §2.5, §4.1–§4.4): numbered increments and the snapshot's
  handoff by position.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table}
  alias Macaw.Data.Schema.Cache
  alias Macaw.Data.Source.Push

  @schema Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})
  @version Schema.version(@schema)

  defp push, do: Push.new(:ticks, make_ref(), cache: Cache.new([{:ticks, @schema}]))

  defp rows(ts), do: for(t <- ts, do: %{"t" => t, "v" => t})

  defp delivery(rows, served \\ []),
    do: Delivery.new(rows, schema: @version, served: served)

  defp snapshot(rows, position), do: delivery(rows, position: position)

  defp increment(push, seq, rows),
    do: send_in(push, Push.increment_message(push.ref, seq, delivery(rows)))

  defp snapshotted(push, rows, position),
    do: send_in(push, Push.snapshot_message(push.ref, snapshot(rows, position)))

  defp send_in(push, message) do
    {:ok, push} = Push.receive(push, message)
    push
  end

  defp drain(push), do: Push.drain(push, fn _ -> flunk("describe asked") end)

  # The held rows, sorted, as a multiset to compare.
  defp held(push) do
    case Push.held(push) do
      nil ->
        []

      delivery ->
        delivery
        |> Delivery.named_rows()
        |> Enum.map(&Map.new(&1, fn {k, v} -> {to_string(k), v} end))
        |> Enum.sort_by(&{&1["t"], &1["v"]})
    end
  end

  @tag verifies: "push-numbered"
  test "a repeated or older increment is dropped whole, increments apply by number, and identical rows are both held" do
    push =
      push()
      |> increment(1, rows([1]))
      |> increment(1, rows([1]))
      |> drain()

    assert held(push) == rows([1])
    assert push.ignored == %{repeat: 1}

    # Out of order within one drain: applied by number, no gap.
    push = push |> increment(3, rows([3])) |> increment(2, rows([2])) |> drain()
    assert held(push) == rows([1, 2, 3])
    assert push.errors == [] and Push.refetch(push) == nil

    # An older one, after a drain, is dropped whole too.
    push = push |> increment(2, rows([9])) |> drain()
    assert held(push) == rows([1, 2, 3])
    assert push.ignored == %{repeat: 2}

    # Two identical rows are two rows, in one increment or across two.
    push = push |> increment(4, rows([5, 5])) |> increment(5, rows([5])) |> drain()
    assert held(push) == rows([1, 2, 3, 5, 5, 5])
  end

  @tag verifies: "push-gap"
  test "a gap is recorded and answered with a refetch, and the snapshot that fills it applies what was held back" do
    push = push() |> increment(1, rows([1])) |> drain()
    push = push |> increment(4, rows([4])) |> increment(5, rows([5])) |> drain()

    assert held(push) == rows([1])
    assert push.errors == [{:gap, 2, 3}]
    assert Push.refetch(push) == {:gap, 2, 3}

    # The snapshot reflects increments up to 3: 4 and 5, held back, apply after it.
    push = push |> snapshotted(rows([1, 2, 3]), 3) |> drain()
    assert held(push) == rows([1, 2, 3, 4, 5])
    assert Push.refetch(push) == nil

    # A snapshot fetched by the holder hands off the same way.
    push = push |> increment(7, rows([7])) |> drain()
    assert Push.refetch(push) == {:gap, 6, 6}
    push = push |> Push.snapshot(snapshot(rows([1, 2, 3, 4, 5, 6]), 6)) |> drain()
    assert held(push) == rows([1, 2, 3, 4, 5, 6, 7])
    assert Push.refetch(push) == nil
  end

  @tag verifies: "push-handoff"
  property "a snapshot hands off by position: no increment is applied twice or lost" do
    check all(
            n <- integer(1..25),
            position <- integer(0..n),
            stale <- integer(0..n),
            cut <- integer(0..n),
            drains <- list_of(boolean(), length: n + 3)
          ) do
      # The source's changelog: increment i inserts row i. The snapshot reflects the
      # first `position` of them, and arrives after `cut` increments were sent; a stale
      # snapshot of `min(stale, position)` arrives after the real one.
      changes = for i <- 1..n, do: {:increment, i}
      sent = Enum.take(changes, cut) ++ [{:snapshot, position}] ++ Enum.drop(changes, cut)
      sent = sent ++ [{:snapshot, min(stale, position) - 1}]

      push =
        sent
        |> Enum.zip(drains)
        |> Enum.reduce(push(), fn {message, drain?}, push ->
          push =
            case message do
              {:increment, i} -> increment(push, i, rows([i]))
              {:snapshot, p} when p >= 0 -> snapshotted(push, rows(Enum.to_list(1..p//1)), p)
              {:snapshot, _none} -> push
            end

          if drain?, do: drain(push), else: push
        end)
        |> drain()

      # The held relation is the snapshot plus every later increment: each row once.
      assert held(push) == rows(Enum.to_list(1..n))
      assert push.errors == []
    end
  end

  test "a snapshot older than the position held is dropped whole, one with no position recorded" do
    push = push() |> increment(1, rows([1])) |> increment(2, rows([2])) |> drain()
    push = push |> snapshotted(rows([]), 0) |> drain()
    assert held(push) == rows([1, 2])
    assert push.ignored == %{stale_snapshot: 1}

    {:ok, push} = Push.receive(push, Push.snapshot_message(push.ref, delivery(rows([9]))))
    push = drain(push)
    assert held(push) == rows([1, 2])
    assert push.errors == [{:snapshot, :no_position}]
  end

  test "the held relation keeps the window field's order" do
    push = push() |> increment(1, rows([5, 1])) |> increment(2, rows([3])) |> drain()
    assert Table.column(Push.held(push) |> Delivery.table!(), "t") == [1, 3, 5]
  end
end
