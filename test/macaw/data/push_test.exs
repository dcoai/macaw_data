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
      do: {:ok, Delivery.new([], types: %{"t" => :number, "v" => :number})}

    @impl true
    def subscribe(%__MODULE__{rows: rows}, pid) do
      ref = make_ref()
      send(pid, Push.schema_message(ref, @schema))

      for row <- rows,
          do: send(pid, Push.delivery_message(ref, increment([row])))

      {:ok, ref}
    end

    @impl true
    def unsubscribe(_source, _ref), do: :ok

    def increment(rows),
      do:
        Delivery.new(rows,
          types: %{"t" => :number, "v" => :number},
          schema: Schema.version(@schema)
        )
  end

  defp increment(rows, served \\ []),
    do: Delivery.new(rows, types: @types, schema: Schema.version(@schema), served: served)

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

  defp ts(push), do: Table.column(Push.held(push).table, "t")

  @tag verifies: "push-handshake"
  test "the handshake's schema comes first, so the increments resolve without asking describe" do
    source = %Ticker{rows: [%{"t" => 1, "v" => 10}, %{"t" => 2, "v" => 20}]}
    {:ok, ref} = Source.subscribe(source, self())

    push = Push.new(:ticks, ref) |> received()
    assert Cache.fetch(push.cache, :ticks, Schema.version(@schema)) == {:ok, @schema}
    assert length(push.pending) == 2

    push = Push.drain(push, &no_describe/1)
    assert ts(push) == [1, 2]
    assert Push.held(push).served.window == [1, 2]
    assert push.pending == [] and push.errors == []
  end

  @tag verifies: "push-handshake"
  test "a message of another subscription is ignored; one under this ref is not" do
    push = Push.new(:ticks, make_ref())
    assert Push.receive(push, Push.schema_message(make_ref(), @schema)) == :ignore
    assert Push.receive(push, {:other, 1}) == :ignore
    assert {:ok, _push} = Push.receive(push, Push.schema_message(push.ref, @schema))
  end

  @tag verifies: "push-unknown-version"
  test "an increment naming a version not cached asks describe once, then caches it" do
    ref = make_ref()
    push = Push.new(:ticks, ref)

    {:ok, push} =
      Push.receive(push, Push.delivery_message(ref, increment([%{"t" => 1, "v" => 1}])))

    {:ok, push} =
      Push.receive(push, Push.delivery_message(ref, increment([%{"t" => 2, "v" => 1}])))

    me = self()
    describe = fn name -> send(me, {:described, name}) && {:ok, @schema} end

    push = Push.drain(push, describe)
    assert ts(push) == [1, 2]
    assert_received {:described, :ticks}
    refute_received {:described, _}

    failing = Push.new(:gone, ref)

    {:ok, failing} =
      Push.receive(failing, Push.delivery_message(ref, increment([%{"t" => 1, "v" => 1}])))

    failing = Push.drain(failing, fn _ -> {:error, :no_source} end)
    assert Push.held(failing) == nil and failing.errors != []
  end

  @tag verifies: "push-merge"
  test "increments merge by the window field: newer appended, late placed, a held row not added twice" do
    ref = make_ref()
    cache = Cache.new([{:ticks, @schema}])

    push =
      Enum.reduce(
        [
          increment([%{"t" => 1, "v" => 1}, %{"t" => 3, "v" => 3}], window: [0, 3]),
          increment([%{"t" => 3, "v" => 3}, %{"t" => 5, "v" => 5}]),
          increment([%{"t" => 2, "v" => 2}, %{"t" => 1, "v" => 1}])
        ],
        Push.new(:ticks, ref, cache: cache),
        fn d, push ->
          {:ok, push} = Push.receive(push, Push.delivery_message(ref, d))
          Push.drain(push, &no_describe/1)
        end
      )

    assert ts(push) == [1, 2, 3, 5]
    assert Push.held(push).served.window == [0, 5]
  end

  @tag verifies: "push-coalesce"
  test "pushes between two pulses buffer, and one drain merges them all, in the order received" do
    ref = make_ref()
    push = Push.new(:ticks, ref, cache: Cache.new([{:ticks, @schema}]))

    push =
      Enum.reduce(1..50, push, fn t, push ->
        {:ok, push} =
          Push.receive(push, Push.delivery_message(ref, increment([%{"t" => t, "v" => t}])))

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
    push = Push.new(:log, ref, cache: Cache.new([{:log, schema}]), limit: 3)

    push =
      Enum.reduce(1..5, push, fn i, push ->
        d =
          Delivery.new([%{"msg" => "m#{i}"}],
            types: %{"msg" => :text},
            schema: Schema.version(schema)
          )

        {:ok, push} = Push.receive(push, Push.delivery_message(ref, d))
        push
      end)
      |> Push.drain(&no_describe/1)

    assert Table.column(Push.held(push).table, "msg") == ["m3", "m4", "m5"]
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
      push = Push.new(:ticks, ref, cache: Cache.new([{:ticks, @schema}]))

      {chunks, _} =
        Enum.reduce(Stream.cycle(splits) |> Enum.take(length(rows)), {[], rows}, fn
          _n, {acc, []} -> {acc, []}
          n, {acc, left} -> {acc ++ [Enum.take(left, n)], Enum.drop(left, n)}
        end)

      # Each chunk is pushed twice: a repeat at the seam adds nothing.
      push =
        Enum.reduce(chunks ++ chunks, push, fn chunk, push ->
          {:ok, push} = Push.receive(push, Push.delivery_message(ref, increment(chunk)))
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
