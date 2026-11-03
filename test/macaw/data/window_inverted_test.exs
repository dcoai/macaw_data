defmodule Macaw.Data.WindowInvertedTest do
  @moduledoc """
  An inverted request window is refused as an inverted region range is (macaw_data#122,
  spec/01 §2.3): by `Window.check/2`, so by finishing, a derived source's request and
  `Source.fetch/3`, before any source sees it.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Derived, Schema, Source, Window}
  alias Macaw.Data.Source.{Conformance, Description, Finish, Request}
  alias Macaw.Data.Test.Reference

  @now ~U[2026-11-03 00:00:00Z]
  @inverted {:error, [{[:window], {:window, :inverted}}]}

  @numbers Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})
  @times Schema.new!(%{"t" => %{type: :time, window: true}, "v" => %{type: :number}})

  # A source that records its calls, so a refusal is shown to call nothing.
  defmodule Recorder do
    @behaviour Macaw.Data.Source
    defstruct []

    @impl true
    def describe(_source, _context) do
      Description.new(
        schema: Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})
      )
    end

    @impl true
    def fetch(_source, request) do
      send(self(), {:fetched, request})
      {:ok, Delivery.new!([%{"t" => 1, "v" => 1}])}
    end
  end

  @kinds [
    ~U[2026-01-02 00:00:00Z],
    %{
      ~U[2026-01-02 01:00:00Z]
      | time_zone: "Europe/Paris",
        zone_abbr: "CET",
        utc_offset: 3600,
        std_offset: 0
    },
    ~N[2026-01-02 00:00:00],
    ~D[2026-01-02]
  ]

  @tag verifies: "request-window-inverted"
  test "an inverted number or time window is refused, of a request and of the axes alone" do
    assert Window.check(Request.new!(now: @now, window: [9, 1]), @numbers) == @inverted
    assert Window.check(%{window: [9, 1]}, @numbers) == @inverted
    assert Window.check(%{window: [9.5, 9]}, @numbers) == @inverted

    later = ~U[2026-01-02 00:00:01Z]
    assert Window.check(%{window: [later, ~U[2026-01-02 00:00:00Z]]}, @times) == @inverted

    # Ends of two kinds of time compare on the instant scale: a range when ordered, and
    # inverted when not.
    for a <- @kinds, b <- @kinds do
      assert Window.check(%{window: [a, b]}, @times) == :ok
      assert Window.check(%{window: [later, b]}, @times) == @inverted
      assert Window.check(%{window: [b, later]}, @times) == :ok
    end

    # An equal pair is an instant, and an open end is never inverted.
    assert Window.check(%{window: [5, 5]}, @numbers) == :ok
    assert Window.check(%{window: [nil, 1]}, @numbers) == :ok
    assert Window.check(%{window: [9, nil]}, @numbers) == :ok
    assert Window.check(%{window: [nil, nil]}, @numbers) == :ok

    # A window not of the field's type is that fault alone, not also inverted.
    assert Window.check(%{window: [@now, 1]}, @numbers) ==
             {:error, [{[:window], {:type, :number}}]}

    # With other faults, every one at once by path.
    assert Window.check(%{window: [9, 1], region: %{"t" => [3, 2]}, latest: true}, @numbers) ==
             {:error,
              [
                {[:latest], {:window, :no_identity}},
                {[:region, "t"], {:window, :inverted}},
                {[:window], {:window, :inverted}}
              ]}
  end

  @tag verifies: "request-window-inverted"
  property "a window is inverted exactly when a region over the window field is" do
    check all(
            from <- one_of([constant(nil), integer(-20..20), float(min: -20.0, max: 20.0)]),
            to <- one_of([constant(nil), integer(-20..20), float(min: -20.0, max: 20.0)])
          ) do
      window = Window.check(%{window: [from, to]}, @numbers)

      region =
        case Window.check(%{region: %{"t" => [from, to]}}, @numbers) do
          :ok -> :ok
          {:error, [{[:region, "t"], reason}]} -> {:error, [{[:window], reason}]}
        end

      assert window == region
      assert window == if(from && to && from > to, do: @inverted, else: :ok)
    end
  end

  @tag verifies: "request-window-inverted"
  test "finish/4, fetch/3 and a derived source's request answer the fault, the source never called" do
    d = Delivery.new!([%{"t" => 1, "v" => 2}])
    described = Description.new!(schema: @numbers)
    request = Request.new!(now: @now, window: [9, 1])

    assert Finish.finish(d, described, request) == @inverted

    assert_raise Macaw.Data.Error, ~r/\{:window, :inverted\}/, fn ->
      Finish.finish!(d, described, request)
    end

    {:ok, description} = Source.describe(%Recorder{}, %{})

    assert Source.fetch(%Recorder{}, description, request) ==
             {:error, {:window, [{[:window], {:window, :inverted}}]}}

    refute_received {:fetched, _}

    hosts = Schema.new!(%{"t" => %{type: :number, window: true}, "cpu" => %{type: :number}})

    derived =
      Derived.new!(
        id: :inverted,
        from: [{"hosts", %{window: [9, 1]}}],
        schema: %{"cpu" => %{type: :number}},
        elixir: "fn rows -> rows end"
      )

    assert Derived.validate(derived, inputs: %{"hosts" => hosts}) ==
             {:error, [{[:from, 0, :window, :window], {:window, :inverted}}]}
  end

  @tag verifies: "contract-fetch"
  test "fetch/3 refuses a backward window or region range without calling the source" do
    {:ok, description} = Source.describe(%Recorder{}, %{})

    for {request, path} <- [
          {Request.new!(now: @now, window: [9, 1]), [:window]},
          {Request.new!(now: @now, region: %{"t" => [3, 2]}), [:region, "t"]},
          {Request.new!(now: @now, window: [9, 1], region: %{"v" => [1, 0]}), [:region, "v"]}
        ] do
      assert {:error, {:window, faults}} = Source.fetch(%Recorder{}, description, request)
      assert {path, {:window, :inverted}} in faults
      refute_received {:fetched, _}
    end

    # An ordered window, and any other fault the schema finds, reach the source, which
    # answers it as its own.
    assert {:ok, %Delivery{}} =
             Source.fetch(%Recorder{}, description, Request.new!(now: @now, window: [1, 9]))

    assert_received {:fetched, %Request{window: [1, 9]}}

    assert {:ok, %Delivery{}} =
             Source.fetch(%Recorder{}, description, Request.new!(now: @now, latest: true))

    assert_received {:fetched, %Request{latest: true}}

    assert {:ok, %Delivery{}} =
             Source.fetch(%Recorder{}, description, Request.new!(now: @now, window: [@now, 1]))

    assert_received {:fetched, %Request{window: [@now, 1]}}
  end

  @tag verifies: "request-window-inverted"
  test "the conformance kit asks inverted windows, and a conforming source passes" do
    assert Conformance.check(:errors, %Reference{}, []) == []
  end
end
