defmodule Macaw.Data.SourceTest do
  @moduledoc "`Macaw.Data.Source` (spec/01 §2): the behavior, its description and its request."
  use ExUnit.Case, async: true

  alias Macaw.Data.{Delivery, Schema, Source}
  alias Macaw.Data.Source.{Description, Request}
  alias Macaw.Data.Test.Reference

  doctest Description
  doctest Request

  @now ~U[2026-10-27 12:00:00Z]

  # A source that pushes, answers malformed things on request, and records its calls.
  defmodule Pusher do
    @behaviour Macaw.Data.Source
    defstruct answer: :good

    @impl true
    def describe(%{answer: :bad}, _context), do: :whatever

    def describe(_source, context),
      do:
        Description.new(
          schema: Schema.new!(%{v: %{type: :number}}),
          supports: [:push],
          params: Map.get(context, :params, %{})
        )

    @impl true
    def fetch(%{answer: :bad}, _request), do: {:rows, []}

    def fetch(_source, request),
      do:
        (
          send(self(), {:fetched, request})
          {:ok, Delivery.new([%{v: 1}])}
        )

    @impl true
    def subscribe(_source, pid),
      do:
        (
          send(pid, :subscribed)
          {:ok, make_ref()}
        )

    @impl true
    def unsubscribe(_source, _ref), do: :ok
  end

  @tag verifies: "contract-describe"
  test "describe/2 answers a description from the host's context, never a viewer" do
    assert {:ok, %Description{} = d} = Source.describe(%Reference{}, %{})
    assert d.params["scale"] == %{type: :number, default: 1, doc: "multiplies v"}
    assert d.supports == [:window, :budget]
    assert d.viewer_independent

    assert {:ok, %Description{params: %{"x" => _}}} =
             Source.describe(%Pusher{}, %{params: %{"x" => %{type: :text, default: ""}}})

    assert Source.describe(%Pusher{answer: :bad}, %{}) == {:error, {:bad_describe, :whatever}}
    assert Description.capabilities() == [:window, :box, :region, :latest, :budget, :push, :as_of]
  end

  @tag verifies: "contract-description"
  test "a description is checked: schema, parameters, capabilities and viewer independence" do
    schema = Schema.new!(%{v: %{type: :number}})

    assert {:ok, %Description{params: %{}, supports: [], viewer_independent: false}} =
             Description.new(schema: schema)

    assert Description.new(
             schema: schema,
             params: %{
               "bins" => %{type: :number, default: "x"},
               "" => %{type: :text},
               :sym => %{type: :text}
             },
             supports: :all,
             viewer_independent: :maybe,
             reveals: []
           ) ==
             {:error,
              [
                {[:params, :sym], {:type, :name}},
                {[:params, ""], {:type, :name}},
                {[:params, "bins", :default], {:type, :number}},
                {[:reveals], :unknown_key},
                {[:supports], {:type, :list}},
                {[:viewer_independent], {:type, :boolean}}
              ]}

    assert Description.new(supports: []) == {:error, [{[:schema], :required}]}

    # An unknown capability names the seven there are.
    assert {:error, [{[:supports, 0], {:enum, caps}}]} =
             Description.new(schema: schema, supports: [:teleport])

    assert caps == Description.capabilities()
    assert_raise ArgumentError, ~r/not a description/, fn -> Description.new!(schema: :x) end
  end

  @tag verifies: "contract-request"
  test "a request carries every axis, now given; every fault at once" do
    box = %{west: -10, south: 35, east: 30, north: 60}

    assert {:ok, r} =
             Request.new(
               params: %{"scale" => 2},
               window: [nil, 10],
               box: box,
               region: %{"t" => [0, 5], "v" => [1, nil]},
               latest: true,
               budget: 50,
               as_of: ~U[2026-01-01 00:00:00Z],
               viewer: {:user, 7},
               now: @now
             )

    assert {r.box, r.latest, r.viewer} == {box, true, {:user, 7}}

    assert Request.new(
             window: [1],
             box: %{box | south: 61},
             region: %{"t" => 3},
             latest: 1,
             budget: 0,
             as_of: "x",
             now: "now",
             viewer: :anyone,
             zoom: 1
           ) ==
             {:error,
              [
                {[:as_of], {:type, :time}},
                {[:box], {:type, :box}},
                {[:budget], {:type, :pos_integer}},
                {[:latest], {:type, :boolean}},
                {[:now], {:type, :time}},
                {[:region, "t"], {:type, :range}},
                {[:window], {:type, :window}},
                {[:zoom], :unknown_key}
              ]}

    assert Request.new(region: %{}, now: @now) == {:error, [{[:region], {:type, :region}}]}
    assert_raise ArgumentError, ~r/not a request/, fn -> Request.new!([]) end
  end

  @tag verifies: "contract-fetch"
  test "fetch/3 checks the parameters first; the source gets every one, defaults filled" do
    {:ok, d} =
      Source.describe(%Pusher{}, %{
        params: %{"x" => %{type: :number, default: 3}, "y" => %{type: :text}}
      })

    assert Source.fetch(%Pusher{}, d, Request.new!(now: @now, params: %{"x" => "big"})) ==
             {:error, {:params, [{["x"], {:type, :number}}, {["y"], :required}]}}

    refute_received {:fetched, _}

    assert {:ok, %Delivery{}} =
             Source.fetch(%Pusher{}, d, Request.new!(now: @now, params: %{"y" => "a"}))

    assert_received {:fetched, %Request{params: %{"x" => 3, "y" => "a"}}}

    {:ok, rd} = Source.describe(%Reference{}, %{})

    {:ok, delivery} =
      Source.fetch(
        %Reference{},
        rd,
        Request.new!(now: @now, window: [3, 5], params: %{"scale" => 10})
      )

    assert Enum.map(Delivery.rows(delivery), & &1["v"]) == [30, 40, 50]

    assert Source.fetch(%Pusher{answer: :bad}, d, Request.new!(now: @now, params: %{"y" => "a"})) ==
             {:error, {:bad_fetch, {:rows, []}}}
  end

  @tag verifies: "contract-push-dispatch"
  test "subscribe/2 reaches a pushing source, and a non-pushing one refuses; unsubscribe is :ok" do
    assert {:ok, ref} = Source.subscribe(%Pusher{}, self())
    assert_received :subscribed
    assert Source.unsubscribe(%Pusher{}, ref) == :ok

    assert Source.subscribe(%Reference{}, self()) == {:error, :no_push}
    assert Source.unsubscribe(%Reference{}, make_ref()) == :ok
  end

  @tag verifies: "contract-describer"
  test "describer/1 is the cache's describe function over named sources" do
    describe = Source.describer(%{"latency" => {%Reference{}, %{}}})
    {:ok, schema} = describe.("latency")
    assert Schema.window_field(schema) == "t"
    assert describe.("nope") == {:error, :no_source}

    {:ok, s, _cache} =
      Schema.Cache.resolve(Schema.Cache.new(), "latency", Schema.version(schema), describe)

    assert s == schema
  end
end
