defmodule Macaw.Data.PushAccessorsTest do
  @moduledoc """
  What a holder reads of a `Push` without its fields (spec/01 §4, macaw_data#123): the
  errors it recorded, taken, and whether a drain has anything to apply.
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.{Delivery, Schema}
  alias Macaw.Data.Schema.Cache
  alias Macaw.Data.Source.Push

  doctest Push

  @schema Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})
  @version Schema.version(@schema)

  defp push, do: Push.new!(:ticks, make_ref(), cache: Cache.new([{:ticks, @schema}]))
  defp rows(ts), do: for(t <- ts, do: %{"t" => t, "v" => t})
  defp delivery(rows, served \\ []), do: Delivery.new!(rows, schema: @version, served: served)

  defp increment(push, seq, rows),
    do: send_in(push, Push.increment_message(push.ref, seq, delivery(rows)))

  defp snapshotted(push, rows, position),
    do: send_in(push, Push.snapshot_message(push.ref, delivery(rows, position: position)))

  defp send_in(push, message) do
    {:ok, push} = Push.receive(push, message)
    push
  end

  defp drain(push), do: Push.drain(push, fn _ -> flunk("describe asked") end)

  @tag verifies: "push-accessors"
  test "take_errors/1 gives the recorded errors in order and leaves none; taking again gives none" do
    push = push() |> increment(1, rows([1])) |> drain()
    assert {[], push} = Push.take_errors(push)

    # A gap, then rows that don't pack, then an unresolvable version: in that order.
    push = push |> increment(3, rows([3])) |> drain()
    push = push |> snapshotted(rows([1, 2]), 2) |> drain()
    push = push |> increment(4, [%{"t" => 4, "v" => "not a number"}]) |> drain()

    unknown = Delivery.new!(rows([5]), schema: "no such version")
    push = push |> send_in(Push.increment_message(push.ref, 5, unknown))
    push = Push.drain(push, fn _name -> {:error, :down} end)

    assert {[{:gap, 2, 2}, {:table, [{["v", 0], {:type, :number}}]}, {:describe, :ticks, :down}],
            taken} = Push.take_errors(push)

    assert taken.errors == []
    assert {[], ^taken} = Push.take_errors(taken)

    # Taking the errors changes nothing else: what is held, the position, the refetch.
    assert Push.held(taken) == Push.held(push)
    assert Push.refetch(taken) == Push.refetch(push)
    assert taken.position == push.position

    # Errors recorded after a take are the next take's alone.
    later = taken |> increment(7, rows([7])) |> drain()
    assert {[{:gap, 6, 6}], _push} = Push.take_errors(later)
  end

  @tag verifies: "push-accessors"
  test "pending?/1 is true while a drain has something to apply, and false once it has not" do
    refute Push.pending?(push())

    # A schema message is cached at once, nothing buffered.
    fresh = push()
    {:ok, schema_only} = Push.receive(fresh, Push.schema_message(fresh.ref, @schema))
    refute Push.pending?(schema_only)

    snapshotted = push() |> snapshotted(rows([1, 2]), 2)
    assert Push.pending?(snapshotted)
    refute snapshotted |> drain() |> Push.pending?()

    fetched = Push.snapshot(push(), delivery(rows([1]), position: 1))
    assert Push.pending?(fetched)

    incremented = push() |> increment(1, rows([1]))
    assert Push.pending?(incremented)
    drained = drain(incremented)
    refute Push.pending?(drained)

    # An increment past a gap waits after the drain, and pending? says so until a
    # snapshot fills the gap.
    waiting = drained |> increment(3, rows([3])) |> drain()
    assert Push.refetch(waiting) == {:gap, 2, 2}
    assert Push.pending?(waiting)

    filled = waiting |> snapshotted(rows([1, 2]), 2) |> drain()
    assert Push.refetch(filled) == nil
    refute Push.pending?(filled)

    # A message of another subscription buffers nothing.
    assert Push.receive(filled, Push.increment_message(make_ref(), 4, delivery(rows([4])))) ==
             :ignore
  end

  @tag verifies: "push-readers"
  test "cache/1 and position/1 read the subscription's cache and the last number taken" do
    cache = Cache.new([{:ticks, @schema}])
    fresh = Push.new!(:ticks, make_ref(), cache: cache)
    assert Push.cache(fresh) == cache
    assert Push.position(fresh) == 0

    # A pushed schema is cached at once.
    bare = Push.new!(:ticks, make_ref())
    {:ok, schemed} = Push.receive(bare, Push.schema_message(bare.ref, @schema))
    assert {:ok, @schema} = Cache.fetch(Push.cache(schemed), :ticks, @version)

    assert fresh |> snapshotted(rows([1, 2]), 2) |> drain() |> Push.position() == 2
    assert fresh |> increment(1, rows([1])) |> drain() |> Push.position() == 1

    # A faulted increment's number is consumed all the same (spec/01 §4.1).
    faulted = fresh |> increment(1, [%{"t" => 1, "v" => "not a number"}]) |> drain()
    assert Push.position(faulted) == 1
  end

  @tag verifies: "push-readers"
  test "drained/1 counts the snapshots and increments the last drain applied, each without a fault" do
    assert Push.drained(push()) == 0

    # A snapshot, then two increments in order: three applied.
    push =
      push() |> snapshotted(rows([1, 2]), 2) |> increment(3, rows([3])) |> increment(4, rows([4]))

    push = drain(push)
    assert Push.drained(push) == 3

    # Each drain counts afresh: nothing buffered, nothing applied.
    assert push |> drain() |> Push.drained() == 0

    # A repeat and a stale snapshot are ignored, not applied.
    repeated = push |> increment(4, rows([4])) |> snapshotted(rows([1]), 1) |> drain()
    assert Push.drained(repeated) == 0

    # Rows that don't pack, and a retraction of a row not held beside rows that apply: a
    # fault recorded for each, so neither counts.
    unpacked = push |> increment(5, [%{"t" => 5, "v" => "not a number"}]) |> drain()
    assert Push.drained(unpacked) == 0

    partly =
      Delivery.new!(rows([6]), schema: @version, retracted: [%{"t" => 99, "v" => 99}])

    partial = unpacked |> send_in(Push.increment_message(push.ref, 6, partly)) |> drain()
    assert {[{:table, _faults}, {:retract, :not_held, _row}], _push} = Push.take_errors(partial)
    assert Push.drained(partial) == 0

    # Increments past a gap wait uncounted; the drain that fills the gap counts every
    # increment it releases.
    waiting = partial |> increment(8, rows([8])) |> increment(9, rows([9])) |> drain()
    assert Push.drained(waiting) == 0
    filled = waiting |> increment(7, rows([7])) |> drain()
    assert Push.drained(filled) == 3
    refute Push.pending?(filled)
  end
end
