defmodule Macaw.Data.PushTest do
  @moduledoc "Push (spec/01 §4): the handshake, increments merged by the window field, coalescing."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Source, Table}
  alias Macaw.Data.Schema.Cache
  alias Macaw.Data.Source.{Description, Push}

  @schema Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})
  @types %{"t" => :number, "v" => :number}

  # A pushing source: subscribing sends the schema, then one increment per row of `rows`.
  defmodule Ticker do
    @behaviour Macaw.Data.Source
    alias Macaw.Data.{Delivery, Schema}
    alias Macaw.Data.Source.{Description, Push}

    defstruct rows: []

    @schema Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})

    @impl true
    def describe(_source, _context), do: Description.new(schema: @schema, supports: [:push])

    @impl true
    def fetch(_source, _request),
      do: {:ok, Delivery.new!([], types: %{"t" => :number, "v" => :number})}

    @impl true
    def subscribe(%__MODULE__{rows: rows}, pid) do
      ref = make_ref()
      send(pid, Push.schema_message(ref, @schema))

      for {row, seq} <- Enum.with_index(rows, 1),
          do: send(pid, Push.increment_message(ref, seq, increment([row])))

      {:ok, ref}
    end

    @impl true
    def unsubscribe(_source, _ref), do: :ok

    def increment(rows),
      do:
        Delivery.new!(rows,
          types: %{"t" => :number, "v" => :number},
          schema: Schema.version(@schema)
        )
  end

  defp increment(rows, served \\ []),
    do: Delivery.new!(rows, types: @types, schema: Schema.version(@schema), served: served)

  defp no_describe(_name), do: flunk("describe asked although the schema was pushed")

  defp received(push) do
    receive do
      message ->
        case Push.receive(push, message) do
          {:ok, push} -> received(push)
          :ignore -> flunk("a foreign message: #{inspect(message)}")
        end
    after
      0 -> push
    end
  end

  defp ts(push), do: Table.column(Push.held(push) |> Delivery.table!(), "t")

  @tag verifies: "push-handshake"
  test "the handshake's schema comes first, so the increments resolve without asking describe" do
    source = %Ticker{rows: [%{"t" => 1, "v" => 10}, %{"t" => 2, "v" => 20}]}
    {:ok, ref} = Source.subscribe(source, self())

    push = Push.new!(:ticks, ref) |> received()
    assert Cache.fetch(push.cache, :ticks, Schema.version(@schema)) == {:ok, @schema}
    assert length(push.pending) == 2

    push = Push.drain(push, &no_describe/1)
    assert ts(push) == [1, 2]
    assert Push.held(push).served.window == [1, 2]
    assert push.pending == [] and push.errors == []
  end

  @tag verifies: "push-handshake"
  test "a message of another subscription is ignored; one under this ref is not" do
    push = Push.new!(:ticks, make_ref())
    assert Push.receive(push, Push.schema_message(make_ref(), @schema)) == :ignore
    assert Push.receive(push, {:other, 1}) == :ignore
    assert {:ok, _push} = Push.receive(push, Push.schema_message(push.ref, @schema))
  end

  @tag verifies: "push-unknown-version"
  test "an increment naming a version not cached asks describe once, then caches it" do
    ref = make_ref()
    push = Push.new!(:ticks, ref)

    {:ok, push} =
      Push.receive(push, Push.increment_message(ref, 1, increment([%{"t" => 1, "v" => 1}])))

    {:ok, push} =
      Push.receive(push, Push.increment_message(ref, 2, increment([%{"t" => 2, "v" => 1}])))

    me = self()

    describe = fn name ->
      send(me, {:described, name})
      {:ok, @schema}
    end

    push = Push.drain(push, describe)
    assert ts(push) == [1, 2]
    assert_received {:described, :ticks}
    refute_received {:described, _}

    failing = Push.new!(:gone, ref)

    {:ok, failing} =
      Push.receive(failing, Push.increment_message(ref, 1, increment([%{"t" => 1, "v" => 1}])))

    failing = Push.drain(failing, fn _ -> {:error, :no_source} end)
    assert Push.held(failing) == nil and failing.errors != []
  end

  @tag verifies: "push-merge"
  test "increments merge by the window field: newer appended, late placed, an identical row held again" do
    ref = make_ref()
    cache = Cache.new([{:ticks, @schema}])

    push =
      Enum.reduce(
        [
          increment([%{"t" => 1, "v" => 1}, %{"t" => 3, "v" => 3}], window: [0, 3]),
          increment([%{"t" => 3, "v" => 3}, %{"t" => 5, "v" => 5}]),
          increment([%{"t" => 2, "v" => 2}, %{"t" => 1, "v" => 1}])
        ]
        |> Enum.with_index(1),
        Push.new!(:ticks, ref, cache: cache),
        fn {d, seq}, push ->
          {:ok, push} = Push.receive(push, Push.increment_message(ref, seq, d))
          Push.drain(push, &no_describe/1)
        end
      )

    assert ts(push) == [1, 1, 2, 3, 3, 5]
    assert Push.held(push).served.window == [0, 5]
  end

  @tag verifies: "push-stale"
  test "a stale snapshot makes the holding stale; each applied increment's stale replaces it" do
    ref = make_ref()
    cache = Cache.new([{:ticks, @schema}])
    stale = increment([%{"t" => 1, "v" => 1}], window: [0, 1], position: 0, stale: true)

    push =
      Push.new!(:ticks, ref, cache: cache) |> Push.snapshot(stale) |> Push.drain(&no_describe/1)

    assert Push.held(push).served.stale == true

    step = fn push, seq, served ->
      {:ok, push} =
        Push.receive(
          push,
          Push.increment_message(ref, seq, increment([%{"t" => seq + 1, "v" => seq}], served))
        )

      Push.drain(push, &no_describe/1)
    end

    push = step.(push, 1, [])
    assert {ts(push), Push.held(push).served.stale} == {[1, 2], false}

    push = step.(push, 2, stale: true)
    assert {ts(push), Push.held(push).served.stale} == {[1, 2, 3], true}

    # An increment not applied (another resolution) leaves the holding's stale as it was.
    push = step.(push, 3, resolution: 60)
    assert {Push.held(push).served.stale, elem(Push.refetch(push), 0)} == {true, :resolution}

    fresh = increment([%{"t" => 9, "v" => 9}], window: [0, 9], position: 3)
    push = push |> Push.snapshot(fresh) |> Push.drain(&no_describe/1)
    assert {ts(push), Push.held(push).served.stale} == {[9], false}
  end

  @tag verifies: "push-note"
  property "the holding's stale and note are the last applied answer's" do
    note =
      one_of([
        constant(nil),
        constant("upstream down; last good answer"),
        string(:alphanumeric, min_length: 1)
      ])

    said = tuple({boolean(), note})

    check all(
            {stale, said_note} <- said,
            increments <- list_of(tuple({said, boolean()}), max_length: 8)
          ) do
      ref = make_ref()

      snapshot =
        increment([%{"t" => 0, "v" => 0}],
          window: [0, 0],
          position: 0,
          stale: stale,
          note: said_note
        )

      push =
        Push.new!(:ticks, ref, cache: Cache.new([{:ticks, @schema}]))
        |> Push.snapshot(snapshot)
        |> Push.drain(&no_describe/1)

      {push, expected} =
        increments
        |> Enum.with_index(1)
        |> Enum.reduce({push, {stale, said_note}}, fn {{{s, n}, applied?}, seq},
                                                      {push, expected} ->
          # An increment at another resolution is not applied (spec/01 §4.3).
          served = [stale: s, note: n] ++ if(applied?, do: [], else: [resolution: 60])

          message =
            Push.increment_message(ref, seq, increment([%{"t" => seq, "v" => seq}], served))

          {:ok, push} = Push.receive(push, message)
          {Push.drain(push, &no_describe/1), if(applied?, do: {s, n}, else: expected)}
        end)

      held = Push.held(push).served
      assert {held.stale, held.note} == expected
    end
  end

  @tag verifies: "push-note"
  test "what was done to the snapshot's rows, and its params, stay the snapshot's; the holding states no order" do
    ref = make_ref()

    snapshot =
      increment([%{"t" => 1, "v" => 1}, %{"t" => 0, "v" => 2}],
        window: [0, 1],
        position: 0,
        capped: true,
        reduced_by: :source,
        reduced_with: {"m4", 2},
        ordered: :source,
        params: %{"floor" => 1}
      )

    push =
      Push.new!(:ticks, ref, cache: Cache.new([{:ticks, @schema}]))
      |> Push.snapshot(snapshot)
      |> Push.drain(&no_describe/1)

    taken = fn served ->
      Map.take(served, [:capped, :reduced_by, :reduced_with, :ordered, :params])
    end

    kept = %{
      capped: true,
      reduced_by: :source,
      reduced_with: {"m4", 2},
      ordered: nil,
      params: %{"floor" => 1}
    }

    assert taken.(Push.held(push).served) == kept
    assert ts(push) == [0, 1]

    said = [
      capped: false,
      reduced_by: :runtime,
      reduced_with: {"lttb", 3},
      ordered: :runtime,
      params: %{}
    ]

    {:ok, push} =
      Push.receive(push, Push.increment_message(ref, 1, increment([%{"t" => 2, "v" => 3}], said)))

    push = Push.drain(push, &no_describe/1)
    assert taken.(Push.held(push).served) == kept

    # An increment's own cut is not read either: the holding is thinned as its snapshot was.
    fresh = increment([%{"t" => 5, "v" => 5}], window: [5, 5], position: 1)
    push = push |> Push.snapshot(fresh) |> Push.drain(&no_describe/1)

    {:ok, push} =
      Push.receive(
        push,
        Push.increment_message(ref, 2, increment([%{"t" => 6, "v" => 6}], capped: true))
      )

    push = Push.drain(push, &no_describe/1)
    assert %{capped: false, reduced_by: nil, params: %{}} = Push.held(push).served
  end

  @tag verifies: "push-note"
  test "a push source noting its staleness passes the kit's push and monitor checks, and a monitor reader keeps its note" do
    alias Macaw.Data.Monitor
    alias Macaw.Data.Source.Conformance
    alias Macaw.Data.Test.Sources.Broken

    source = Broken.new(:stale)

    assert [] ==
             Conformance.check(source,
               requests: [[], [window: [2, 10]]],
               push: &Broken.emit/1,
               quiet: 30
             )

    source = Broken.new(:stale)
    monitor = Monitor.new!(%{a: source}, %{a: [source: :a, ask: [window: [0, nil]]]})
    at = ~U[2026-11-01 00:00:00Z]
    monitor = Monitor.tick!(monitor, now: 0, at: at)
    note = "upstream down; last good answer"
    assert %{stale: true, note: ^note} = Monitor.deliveries(monitor).a.served

    :ok = Broken.emit(source)
    monitor = pump(monitor) |> Monitor.tick!(now: 1, at: at)
    delivery = Monitor.deliveries(monitor).a
    assert %{stale: true, note: ^note} = delivery.served
    assert (100 + 1) in Enum.map(Delivery.rows!(delivery), &Table.get(&1, :t))
  end

  defp pump(monitor) do
    receive do
      {:macaw_source, _ref, _message} = message ->
        {:ok, monitor} = Macaw.Data.Monitor.handle_message(monitor, message)
        pump(monitor)
    after
      50 -> monitor
    end
  end

  @tag verifies: "push-coalesce"
  test "pushes between two pulses buffer, and one drain merges them all, in the order received" do
    ref = make_ref()
    push = Push.new!(:ticks, ref, cache: Cache.new([{:ticks, @schema}]))

    push =
      Enum.reduce(1..50, push, fn t, push ->
        {:ok, push} =
          Push.receive(push, Push.increment_message(ref, t, increment([%{"t" => t, "v" => t}])))

        push
      end)

    assert Push.held(push) == nil and length(push.pending) == 50
    push = Push.drain(push, &no_describe/1)
    assert ts(push) == Enum.to_list(1..50)
    assert push.pending == []
  end

  @tag verifies: "push-merge"
  test "with no window field the newest rows are kept up to the limit, the delivery marked capped" do
    schema = Schema.new!(%{"msg" => %{type: :text}})
    ref = make_ref()
    push = Push.new!(:log, ref, cache: Cache.new([{:log, schema}]), limit: 3)

    push =
      Enum.reduce(1..5, push, fn i, push ->
        d =
          Delivery.new!([%{"msg" => "m#{i}"}],
            types: %{"msg" => :text},
            schema: Schema.version(schema)
          )

        {:ok, push} = Push.receive(push, Push.increment_message(ref, i, d))
        push
      end)
      |> Push.drain(&no_describe/1)

    assert Table.column(Push.held(push) |> Delivery.table!(), "msg") == ["m3", "m4", "m5"]
    assert Push.held(push).served.capped
  end

  @tag verifies: "push-merge"
  property "however the rows are split into increments and ordered, the held rows are each row once, by time" do
    check all(
            times <- uniq_list_of(integer(1..200), min_length: 1, max_length: 60),
            splits <- list_of(integer(1..6), min_length: 1)
          ) do
      rows = for t <- times, do: %{"t" => t, "v" => t * 2}
      ref = make_ref()
      push = Push.new!(:ticks, ref, cache: Cache.new([{:ticks, @schema}]))

      {chunks, _} =
        Enum.reduce(Stream.cycle(splits) |> Enum.take(length(rows)), {[], rows}, fn
          _n, {acc, []} -> {acc, []}
          n, {acc, left} -> {acc ++ [Enum.take(left, n)], Enum.drop(left, n)}
        end)

      # Each chunk is pushed twice under its number: a repeat adds nothing.
      numbered = Enum.with_index(chunks, 1)

      push =
        Enum.reduce(numbered ++ numbered, push, fn {chunk, seq}, push ->
          {:ok, push} = Push.receive(push, Push.increment_message(ref, seq, increment(chunk)))
          Push.drain(push, &no_describe/1)
        end)

      assert ts(push) == Enum.sort(times)
    end
  end

  test "a non-pushing source answers no_push, and its description does not claim push" do
    {:ok, %Description{supports: supports}} = Source.describe(%Macaw.Data.Test.Reference{}, nil)
    refute :push in supports
    assert Source.subscribe(%Macaw.Data.Test.Reference{}, self()) == {:error, :no_push}
  end
end
