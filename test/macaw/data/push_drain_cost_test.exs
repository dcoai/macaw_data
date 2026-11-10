defmodule Macaw.Data.PushDrainCostTest do
  @moduledoc """
  What a drain costs on the live loop's holding (spec/01 §4, macaw_data#204): an
  increment's rows are joined after the open chunk's as they lie, so a drain costs the
  rows it brings, not the rows already held; and the first drain after a snapshot reads
  the served window's ends from the window column's positions, never folding its values.
  """
  # Counted work: no other test loads or purges code meanwhile (`Macaw.Data.Test.Work`).
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table, Window}
  alias Macaw.Data.Schema.Cache
  alias Macaw.Data.Source.Push
  alias Macaw.Data.Test.{LiveLoop, Work}

  # Reductions for draining one 1,000-row increment into the 50,000-row holding: with the
  # open chunk nearly full (7,056 rows), and the first drain after the snapshot. Measured
  # 243,533 and 591,168 (439,545 and 785,932 before macaw_data#215, 1,551,511 and
  # 10,266,302 before macaw_data#204).
  @drain_budget 300_000
  @first_budget 670_000
  # How much more a drain into a nearly full open chunk may cost than into a nearly empty
  # one: measured 36,891 (1,054,975 before).
  @growth_budget 80_000
  # A late 1,000-row increment, from 500 seconds before the open chunk's last row, into
  # the nearly full chunk: measured 351,539 (611,563 before macaw_data#215, 1,567,584
  # before macaw_data#214).
  @late_budget 430_000

  defp describe(_name), do: {:error, :pushed}

  # The loop with its next increment received, not yet drained: from `back` seconds
  # before the next reading.
  defp received(loop, back \\ 0) do
    increment =
      Delivery.new!(LiveLoop.readings(loop.next - back, LiveLoop.step()),
        schema: Schema.version(LiveLoop.schema()),
        served: [resolution: 1]
      )

    message = Push.increment_message(loop.ref, Push.position(loop.push) + 1, increment)
    {:ok, push} = Push.receive(loop.push, message)
    push
  end

  defp open_rows(push) do
    {_chunk, _first, n} =
      push |> Push.held() |> Map.fetch!(:rows) |> Table.chunks() |> List.last()

    n
  end

  defp drain_work(push) do
    {work, drained} =
      Work.reductions(fn -> Push.drain(push, &describe/1) end, native: :normal_schedulers)

    assert drained.errors == []
    work
  end

  defp frames(loop, n), do: Enum.reduce(1..n//1, loop, fn _, loop -> LiveLoop.push(loop) end)

  @tag verifies: "push-drain-cost"
  test "the first drain after a snapshot reads the window's ends, never every value" do
    first = LiveLoop.start(nil) |> received() |> drain_work()
    assert first < @first_budget, "first drain after the snapshot: #{first}"
  end

  @tag verifies: "push-drain-cost"
  test "a 1,000-row drain costs the rows it brings, not the rows the open chunk holds" do
    empty = frames(LiveLoop.start(nil), 1)
    full = frames(empty, 7)
    assert open_rows(received(empty)) == 56 and open_rows(received(full)) == 7_056

    nearly_empty = empty |> received() |> drain_work()
    nearly_full = full |> received() |> drain_work()

    assert nearly_full < @drain_budget, "drain into a nearly full open chunk: #{nearly_full}"
    assert nearly_full - nearly_empty < @growth_budget, "#{nearly_empty} to #{nearly_full}"
  end

  @tag verifies: "push-drain-cost"
  test "a late 1,000-row drain costs the rows after the first it moves, not every row held" do
    full = frames(LiveLoop.start(nil), 8)
    assert open_rows(received(full)) == 7_056

    late = full |> received(500) |> drain_work()
    assert late < @late_budget, "late drain into a nearly full open chunk: #{late}"
  end

  # -- the served window's ends -----------------------------------------------------------

  @t0 ~U[2026-01-01 00:00:00Z]

  defp schema(type),
    do: Schema.new!(%{"t" => %{type: type, window: true}, "v" => %{type: :number}})

  # A window value at second `s`: of one kind of time or another, at another precision,
  # so equal instants are different terms; or a number, an integer or a float.
  defp at(s, :time) do
    member_of([
      DateTime.add(@t0, s),
      @t0 |> DateTime.add(s) |> Map.put(:microsecond, {0, 3}),
      @t0 |> DateTime.add(s) |> DateTime.to_naive(),
      if(rem(s, 86_400) == 0,
        do: DateTime.to_date(DateTime.add(@t0, s)),
        else: DateTime.add(@t0, s)
      )
    ])
  end

  defp at(s, :number), do: member_of([s, s / 1])

  defp values(type, n),
    do:
      list_of(one_of([bind(integer(0..20), &at(&1 * 43_200, type)), constant(nil)]),
        max_length: n
      )

  defp fold(values, f), do: Enum.reduce(values, nil, &f.(&2, &1))

  @tag verifies: "push-drain-cost"
  property "the served window's ends after a snapshot are the fold of every value's, the first of equals" do
    check all(
            type <- member_of([:time, :number]),
            held <- values(type, 30),
            added <- values(type, 10)
          ) do
      schema = schema(type)
      push = Push.new!(:ticks, make_ref(), cache: Cache.new([{:ticks, schema}]))
      rows = fn ts -> Enum.with_index(ts, fn t, i -> %{"t" => t, "v" => i} end) end
      version = Schema.version(schema)
      snapshot = Delivery.new!(rows.(held), schema: version, served: [position: 0])
      push = push |> Push.snapshot(snapshot) |> Push.drain(&describe/1)
      before = Table.column(Push.held(push).rows, "t")

      increment = Delivery.new!(rows.(added), schema: version)
      {:ok, push} = Push.receive(push, Push.increment_message(push.ref, 1, increment))
      push = Push.drain(push, &describe/1)
      assert push.errors == []

      after_ = Table.column(Push.held(push).rows, "t")
      to = Window.latest(fold(before, &Window.latest/2), fold(added, &Window.latest/2))

      assert Push.held(push).served.window == [fold(after_, &Window.earliest/2), to]
    end
  end

  # -- a holding laid by row count --------------------------------------------------------

  # Reductions for draining one 1,000-row increment into a holding laid by row count
  # (macaw_data#233): a number window at no resolution, so no span, and no window field.
  # Measured 237,832 and 147,780 with 6,000 rows held (1,025,878 and 683,820 before, every
  # held row of the last chunk read and packed again).
  @unslotted_budget 320_000
  @unwindowed_budget 210_000
  # How much more the same drain may cost with 7,000 rows held than with 500: the chunk is
  # hashed whole again, its held rows not read. Measured 68,871 (about 800,000 before).
  @unslotted_growth 100_000

  defp unslotted(window?, held) do
    fields = %{"t" => %{type: :number}, "v" => %{type: :number}, "w" => %{type: :number}}
    schema = Schema.new!(if window?, do: put_in(fields, ["t", :window], true), else: fields)
    rows = fn from, n -> for i <- from..(from + n - 1)//1, do: %{"t" => i, "v" => i / 2} end
    ref = make_ref()

    snapshot =
      Delivery.new!(rows.(0, held), schema: Schema.version(schema), served: [position: 0])

    {:ok, push} = Push.receive(Push.new!(:rows, ref), Push.schema_message(ref, schema))
    {:ok, push} = Push.receive(push, Push.snapshot_message(ref, snapshot))
    push = Push.drain(push, &describe/1)
    increment = Delivery.new!(rows.(held, 1_000), schema: Schema.version(schema))
    {:ok, push} = Push.receive(push, Push.increment_message(ref, push.position + 1, increment))
    push
  end

  @tag verifies: "push-drain-cost"
  test "a drain into a holding laid by row count costs the rows it brings, not the rows held" do
    windowed = unslotted(true, 6_000) |> drain_work()
    unwindowed = unslotted(false, 6_000) |> drain_work()
    assert windowed < @unslotted_budget, "number window with no span: #{windowed}"
    assert unwindowed < @unwindowed_budget, "no window field: #{unwindowed}"

    few = unslotted(true, 500) |> drain_work()
    many = unslotted(true, 7_000) |> drain_work()
    assert many - few < @unslotted_growth, "#{few} to #{many}"
  end
end
