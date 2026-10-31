defmodule Macaw.Data.ConformanceOrderTest do
  @moduledoc """
  The kit's `:order` clauses (spec/01 §9): a source naming `:order` serves its rows in the
  order asked, says so, and under a budget serves the first rows in it; `:runtime` and
  `:sample` are Macaw's to state.
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.{Delivery, Schema}
  alias Macaw.Data.Source.{Conformance, Description, Order}

  # A source of p50 latencies that orders and caps its own rows; each flaw breaks one part.
  defmodule Ranked do
    @behaviour Macaw.Data.Source
    defstruct flaw: nil

    @schema Schema.new!(%{
              "t" => %{type: :number, window: true},
              "p50" => %{type: :number},
              "host" => %{type: :text}
            })

    @rows for t <- 1..40, do: %{"t" => t, "p50" => rem(t * 17, 23), "host" => "h#{rem(t, 4)}"}

    @impl true
    def describe(_source, _context),
      do: Description.new(schema: @schema, supports: [:window, :order, :budget])

    @impl true
    def fetch(%{flaw: flaw}, request) do
      # A request the schema cannot answer is an error value, never a raise.
      case Macaw.Data.Window.check(request, @schema) do
        :ok -> answer(flaw, request)
        {:error, faults} -> {:error, {:unreadable, faults}}
      end
    end

    defp answer(flaw, request) do
      rows = Macaw.Data.Window.trim(@rows, "t", request.window)
      {rows, ordered} = served(flaw, rows, request)

      budget = request.budget
      over = budget != nil and length(rows) > budget
      rows = if over, do: Enum.take(rows, budget), else: rows

      {:ok,
       Delivery.new(rows,
         schema: Schema.version(@schema),
         served: [
           window: request.window || [1, 40],
           ordered: ordered,
           reduced_by: if(over, do: :source)
         ]
       )}
    end

    # The rows as each flaw serves them, and what it states.
    defp served(_flaw, rows, %{order: []}), do: {rows, nil}
    defp served(:ignores, rows, _request), do: {rows, :source}
    defp served(:unstated, rows, request), do: {Order.sort(rows, request.order, @schema), nil}

    defp served(:claims_runtime, rows, request),
      do: {Order.sort(rows, request.order, @schema), :runtime}

    # A sample, sorted: in the order, but not its first rows.
    defp served(:samples, rows, %{budget: budget} = request) when budget != nil,
      do: {rows |> Enum.take_every(2) |> Order.sort(request.order, @schema), :source}

    defp served(_honest, rows, request), do: {Order.sort(rows, request.order, @schema), :source}
  end

  @requests [
    [],
    [order: [{"p50", :desc}]],
    [window: [5, 30], order: [{"host", :asc}, {"t", :desc}]]
  ]

  use Conformance, name: "Ranked", source: %Ranked{}, requests: @requests, budgets: [nil, 5]

  @opts [requests: @requests, budgets: [nil, 5]]

  @tag verifies: "conformance-order"
  test "an ordering source passes; each way of breaking the order is its own finding" do
    assert Conformance.check(%Ranked{}, @opts) == []

    for {flaw, check, reason} <- [
          {:ignores, :supports, :not_ordered},
          {:unstated, :supports, :order_unstated},
          {:samples, :supports, :not_first},
          {:claims_runtime, :deliveries, :ordered}
        ] do
      findings = Conformance.check(check, %Ranked{flaw: flaw}, @opts)

      assert Enum.any?(findings, &(elem(elem(&1, 1), 0) == reason)),
             "#{flaw}: expected a #{reason} finding, got #{inspect(findings)}"

      for finding <- findings, do: assert(is_binary(Conformance.format(finding)))
    end
  end

  @tag verifies: "conformance-order"
  test "a source naming :order with no request to probe it is a finding; order is a request key" do
    assert {:supports, {:no_probe, :order}} in Conformance.check(:supports, %Ranked{},
             requests: [[]],
             budgets: [nil]
           )

    assert Conformance.format({:supports, {:no_probe, :order}}) =~ "names :order"

    assert [deliveries: {:probe, [order: [{"nope", :asc}]], [{[:order, 0], _}]}] =
             Conformance.check(:deliveries, %Ranked{},
               requests: [[order: [{"nope", :asc}]]],
               budgets: [nil]
             )
  end
end
