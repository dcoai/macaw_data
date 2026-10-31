defmodule Macaw.Data.OrderTest do
  @moduledoc "A request's row order (spec/01 §2.3): its shape, its fields and its comparison."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Source, Window}
  alias Macaw.Data.Source.{Description, Order, Request}

  doctest Order

  @now ~U[2026-10-27 12:00:00Z]

  @schema Schema.new!(%{
            "t" => %{type: :time},
            "p50" => %{type: :number},
            "host" => %{type: :text},
            "sev" => %{type: :category, order: ["ok", "warn", "bad"]},
            "team" => %{type: :category},
            "at" => %{type: :point},
            "c" => %{type: :color}
          })

  # A source that records its calls, so a refusal is shown to call nothing.
  defmodule Recorder do
    @behaviour Macaw.Data.Source
    defstruct []

    @impl true
    def describe(_source, _context),
      do: Description.new(schema: Schema.new!(%{"p50" => %{type: :number}}))

    @impl true
    def fetch(_source, request) do
      send(self(), {:fetched, request})
      {:ok, Delivery.new([%{"p50" => 1}])}
    end
  end

  @tag verifies: "request-order"
  test "a request carries an order, [] by default; its shape is checked with every other fault" do
    assert Request.new!(now: @now).order == []

    assert Request.new!(now: @now, order: [{"p50", :desc}, {:host, :asc}]).order ==
             [{"p50", :desc}, {:host, :asc}]

    assert Request.new(now: @now, order: [{"p50", :down}, {"", :asc}, :p50]) ==
             {:error,
              [
                {[:order, 0], {:type, :order}},
                {[:order, 1], {:type, :order}},
                {[:order, 2], {:type, :order}}
              ]}

    assert Request.new(now: @now, order: [{"p50", :asc}, {:p50, :desc}], budget: 0) ==
             {:error, [{[:budget], {:type, :pos_integer}}, {[:order, 1], {:duplicate, "p50"}}]}

    assert Request.new(now: @now, order: %{"p50" => :asc}) ==
             {:error, [{[:order], {:type, :order}}]}
  end

  @tag verifies: "request-order"
  test "an order's fields are the schema's, of a type with an order: Window.check and fetch/3" do
    order = [{"p5O", :desc}, {"at", :asc}, {"c", :asc}, {"p50", :desc}]

    assert Window.check(Request.new!(now: @now, order: order), @schema) ==
             {:error,
              [
                {[:order, 0], {:unknown_field, "p5O"}},
                {[:order, 1], {:invalid_for, :point}},
                {[:order, 2], {:invalid_for, :color}}
              ]}

    assert Window.check(%{order: [{:sev, :desc}, {:t, :asc}]}, @schema) == :ok

    assert Window.check(%{order: [{"p5O", :asc}]}, @schema) ==
             {:error, [{[:order, 0], {:unknown_field, "p5O"}}]}

    # fetch/3 refuses it as it refuses parameters: the source is never called.
    {:ok, d} = Source.describe(%Recorder{}, %{})

    assert Source.fetch(%Recorder{}, d, Request.new!(now: @now, order: [{"p5O", :desc}])) ==
             {:error, {:order, [{[:order, 0], {:unknown_field, "p5O"}}]}}

    refute_received {:fetched, _}

    assert {:ok, %Delivery{}} =
             Source.fetch(%Recorder{}, d, Request.new!(now: @now, order: [{:p50, :desc}]))

    assert_received {:fetched, %Request{order: [{:p50, :desc}]}}
  end

  @tag verifies: "order-compare"
  test "rows compare by their field's type: a time by its instant, never DateTime's term order" do
    times = [
      ~U[2026-10-02 00:00:00Z],
      ~U[2026-09-30 23:59:59Z],
      ~U[2025-12-31 00:00:00Z],
      ~U[2026-10-01 00:00:00.000001Z]
    ]

    rows = for {t, i} <- Enum.with_index(times), do: %{"t" => t, "i" => i}

    assert rows |> Order.sort([{"t", :asc}], @schema) |> Enum.map(& &1["i"]) == [2, 1, 3, 0]
    assert rows |> Order.sort([{:t, :desc}], @schema) |> Enum.map(& &1["i"]) == [0, 3, 1, 2]

    # Numbers by value, integers and floats alike; text by its string.
    nums = for v <- [10, 2.5, -1, 3], do: %{"p50" => v}

    assert nums |> Order.sort([{"p50", :desc}], @schema) |> Enum.map(& &1["p50"]) == [
             10,
             3,
             2.5,
             -1
           ]

    names = for h <- ["b", "a", "c"], do: %{"host" => h}
    assert names |> Order.sort([{"host", :asc}], @schema) |> Enum.map(& &1["host"]) == ~w(a b c)

    # A category by its declared order, unlisted states after, by spelling; without an
    # order, by spelling, an atom and a string alike.
    sevs = for s <- ["bad", :ok, "zz", "warn", "aa"], do: %{"sev" => s}

    assert sevs |> Order.sort([{"sev", :asc}], @schema) |> Enum.map(& &1["sev"]) ==
             [:ok, "warn", "bad", "aa", "zz"]

    teams = for s <- ["red", :blue, "green"], do: %{"team" => s}

    assert teams |> Order.sort([{"team", :asc}], @schema) |> Enum.map(& &1["team"]) ==
             [:blue, "green", "red"]
  end

  @tag verifies: "order-compare"
  test "a missing reading sorts last in either direction; keys decide in turn; the sort is stable" do
    rows = [
      %{"p50" => nil, "i" => 0},
      %{"p50" => 2, "i" => 1},
      %{"i" => 2},
      %{"p50" => 5, "i" => 3}
    ]

    assert rows |> Order.sort([{"p50", :asc}], @schema) |> Enum.map(& &1["i"]) == [1, 3, 0, 2]
    assert rows |> Order.sort([{"p50", :desc}], @schema) |> Enum.map(& &1["i"]) == [3, 1, 0, 2]

    keyed =
      for {sev, p, i} <- [{"ok", 1, 0}, {"bad", 1, 1}, {"ok", 9, 2}, {"bad", 1, 3}],
          do: %{"sev" => sev, "p50" => p, "i" => i}

    assert keyed
           |> Order.sort([{"sev", :desc}, {"p50", :desc}], @schema)
           |> Enum.map(& &1["i"]) == [1, 3, 2, 0]

    # Rows read by either spelling of the field's name; [] leaves them as they are.
    atoms = [%{p50: 2}, %{p50: 1}]
    assert Order.sort(atoms, [{"p50", :asc}], @schema) == [%{p50: 1}, %{p50: 2}]
    assert Order.sort(atoms, [], @schema) == atoms

    assert_raise ArgumentError, ~r/lacks/, fn -> Order.sort(atoms, [{"nope", :asc}], @schema) end
  end

  @tag verifies: "order-compare"
  property "a time order is the order of the instants, ascending and descending, gaps last" do
    check all(
            seconds <- list_of(one_of([constant(nil), integer(-2_000_000_000..2_000_000_000)])),
            direction <- member_of([:asc, :desc])
          ) do
      rows =
        for {s, i} <- Enum.with_index(seconds),
            do: %{"t" => s && DateTime.from_unix!(s), "i" => i}

      sorted = Order.sort(rows, [{"t", direction}], @schema)
      {present, gaps} = Enum.split_with(sorted, & &1["t"])

      assert gaps == Enum.filter(rows, &is_nil(&1["t"]))
      unix = Enum.map(present, &DateTime.to_unix(&1["t"]))
      assert unix == Enum.sort(unix, direction)
    end
  end
end
