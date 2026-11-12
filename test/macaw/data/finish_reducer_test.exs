defmodule Macaw.Data.FinishReducerTest do
  @moduledoc """
  A request names its reducer (spec/01 §2.3, §2.4, §6.1; macaw_data#246): each reader is
  reduced its own way, pooled readers from one fetch.
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.{Delivery, Schema, Table}
  alias Macaw.Data.Source.{Description, Finish, Request}

  @now ~U[2026-11-12 12:00:00Z]
  @numbers Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})
  @series Schema.new!(%{
            "t" => %{type: :number, window: true},
            "s" => %{type: :category},
            "v" => %{type: :number}
          })

  defp request(fields), do: Request.new!([now: @now] ++ fields)
  defp described(schema, supports \\ []), do: Description.new!(schema: schema, supports: supports)

  defp line(n \\ 1_000),
    do: Delivery.new!(for(t <- 1..n, do: %{"t" => t, "v" => :math.sin(t / 17) * 10 + rem(t, 7)}))

  defp two_series,
    do:
      Delivery.new!(
        for(t <- 1..400, s <- ["a", "b"], do: %{"t" => t, "s" => s, "v" => :math.cos(t / 9)})
      )

  defp ts(delivery), do: delivery |> Delivery.rows!() |> Enum.map(& &1["t"])

  defp as_table(%Delivery{} = d), do: %{d | rows: Delivery.table!(d), names: nil}

  describe "the request's reduce (spec/01 §2.3)" do
    @tag verifies: "request-reduce"
    test "defaults to nil, takes {name, count} by either spelling, held as the string, and :none" do
      assert request([]).reduce == nil
      assert request(reduce: {:m4, 800}).reduce == {"m4", 800}
      assert request(reduce: {"lttb", 20}).reduce == {"lttb", 20}
      assert request(reduce: :none).reduce == :none
      assert request(reduce: nil).reduce == nil
    end

    @tag verifies: "request-reduce"
    test "a reduce of another shape, and a count that is no positive integer, is each its fault" do
      assert Request.new(now: @now, reduce: :m4) == {:error, [{[:reduce], {:type, :reducer}}]}
      assert Request.new(now: @now, reduce: {1, 2}) == {:error, [{[:reduce], {:type, :reducer}}]}

      assert Request.new(now: @now, reduce: {:m4, 1, 2}) ==
               {:error, [{[:reduce], {:type, :reducer}}]}

      for count <- [0, -3, 1.5, "8", nil] do
        assert Request.new(now: @now, reduce: {:lttb, count}) ==
                 {:error, [{[:reduce], {:type, :pos_integer}}]}
      end

      # Every fault at once, with the other fields'.
      assert Request.new(budget: 0, reduce: "m4") ==
               {:error,
                [
                  {[:budget], {:type, :pos_integer}},
                  {[:now], :required},
                  {[:reduce], {:type, :reducer}}
                ]}
    end
  end

  describe "finishing by the request's reducer (spec/01 §2.4)" do
    @tag verifies: "finish-reducer"
    test "{m4, width} and {lttb, n} reduce as the reducer at that count, reduced_with naming it" do
      for form <- [& &1, &as_table/1] do
        d = form.(line())

        m4 = Finish.finish!(d, described(@numbers), request(reduce: {:m4, 10}))
        # One series, one field: the count is the reducer's own, as reduce: names it.
        assert ts(m4) == ts(Finish.reduce!(d, @numbers, 40, :m4))
        assert length(ts(m4)) <= 40
        assert {m4.served.reduced_by, m4.served.reduced_with} == {:runtime, {"m4", 10}}

        lttb = Finish.finish!(d, described(@numbers), request(reduce: {:lttb, 25}))
        assert ts(lttb) == ts(Finish.reduce!(d, @numbers, 25, "lttb"))
        assert length(ts(lttb)) == 25
        assert lttb.served.reduced_with == {"lttb", 25}

        # A budget alone reduces as before, reduced_with the budget's share.
        alone = Finish.finish!(d, described(@numbers), request(budget: 30))
        assert ts(alone) == ts(Finish.reduce!(d, @numbers, 30))
        assert alone.served.reduced_with == {"lttb", 30}

        # Within the budget, nothing is reduced and nothing said.
        small = form.(line(20))
        kept = Finish.finish!(small, described(@numbers), request(reduce: {:lttb, 25}))
        assert kept == small
        assert kept.served.reduced_with == nil
      end
    end

    @tag verifies: "finish-reducer"
    test "each series and field at the reducer's count, the budget still capping the union" do
      for form <- [& &1, &as_table/1] do
        d = form.(two_series())
        each = Finish.finish!(d, described(@series), request(reduce: {:lttb, 10}))
        counts = each |> Delivery.rows!() |> Enum.frequencies_by(& &1["s"])
        assert counts == %{"a" => 10, "b" => 10}
        assert each.served.reduced_with == {"lttb", 10}

        capped = Finish.finish!(d, described(@series), request(reduce: {:lttb, 10}, budget: 12))
        assert length(Delivery.rows!(capped)) == 12
        assert ts(capped) |> hd() == 1 and List.last(ts(capped)) == 400
      end
    end

    @tag verifies: "finish-reducer"
    test ":none keeps every row up to the budget, cut only by the stride" do
      for form <- [& &1, &as_table/1] do
        d = form.(line(100))
        assert Finish.finish!(d, described(@numbers), request(reduce: :none)) == d

        cut = Finish.finish!(d, described(@numbers), request(reduce: :none, budget: 50))
        assert length(ts(cut)) == 50 and hd(ts(cut)) == 1 and List.last(ts(cut)) == 100
        assert {cut.served.reduced_by, cut.served.reduced_with} == {:runtime, nil}

        assert Finish.finish!(d, described(@numbers), request(reduce: :none, budget: 500)) == d
      end
    end

    @tag verifies: "finish-reducer"
    test "the request's reducer wins over reduce:, and an ordered delivery keeps its head" do
      d = line()

      named = Finish.finish!(d, described(@numbers), request(reduce: {:m4, 5}), reduce: "lttb")
      assert named.served.reduced_with == {"m4", 5}

      head =
        Finish.finish!(
          d,
          described(@numbers),
          request(order: [{"t", :desc}], budget: 10, reduce: {:m4, 5})
        )

      assert ts(head) == Enum.to_list(1000..991//-1)
      assert {head.served.reduced_by, head.served.reduced_with} == {:runtime, nil}
    end

    @tag verifies: "finish-reducer"
    test "an unknown reducer and a count below its least are faults before any step" do
      assert Finish.finish(line(), described(@numbers), request(reduce: {:nope, 5})) ==
               {:error, [{[:reduce], {:unknown, :reducer, "nope"}}]}

      assert Finish.finish(line(), described(@numbers), request(reduce: {:lttb, 2})) ==
               {:error, [{[:reduce], {:least, 3}}]}

      assert Finish.reduce(line(), @numbers, request(reduce: {"window", 5})) ==
               {:error, [{[:reduce], {:unknown, :reducer, "window"}}]}

      assert_raise Macaw.Data.Error, fn ->
        Finish.finish!(line(), described(@numbers), request(reduce: {:lttb, 2}))
      end
    end
  end

  describe "pooled readers with their own reducers (spec/01 §6.1)" do
    @tag verifies: "finish-ceiling-pool"
    test "pooled/1 takes budgets or requests; reduce/5 takes a reader's request" do
      line_reader = request(budget: 60, reduce: {:m4, 10})
      sparse = request(budget: 15, reduce: {:lttb, 15})
      scatter = request(reduce: :none, budget: 40)

      assert Finish.pooled([line_reader, sparse]) == 60
      assert Finish.pooled([line_reader, 15, sparse]) == 60
      assert Finish.pooled([line_reader, scatter]) == nil
      assert Finish.pooled([line_reader, request(reduce: {:lttb, 5})]) == nil
      assert Finish.pooled([100, 4_000, 250]) == 4_000

      # The pooled fetch did not reduce (it asked every row): each reader reduced from it
      # by its own reducer equals that reader finished alone.
      fetched = Finish.finish!(line(), described(@numbers), request([]))

      for reader <- [line_reader, sparse, scatter] do
        assert Finish.reduce!(fetched, @numbers, reader) ==
                 Finish.finish!(line(), described(@numbers), reader)
      end

      assert {:ok, %Delivery{}} = Finish.reduce(fetched, @numbers, sparse, "m4")
      assert Table.size(Delivery.table!(Finish.reduce!(fetched, @numbers, sparse))) == 15
    end
  end

  describe "served.reduced_with (spec/01 §3)" do
    @tag verifies: "delivery-served"
    test "defaults to nil, holds a reducer and its count, and refuses anything else" do
      assert Delivery.new!([]).served.reduced_with == nil

      assert Delivery.new!([], served: [reduced_by: :source, reduced_with: {"m4", 3}]).served.reduced_with ==
               {"m4", 3}

      assert Delivery.new!([], served: [reduced_with: {:lttb, 9}]).served.reduced_with ==
               {:lttb, 9}

      for bad <- [:m4, {"m4", 0}, {"m4", 1.5}, {1, 2}, "m4"] do
        assert Delivery.new([], served: [reduced_with: bad]) ==
                 {:error, [{[:served, :reduced_with], {:type, :reducer}}]}
      end

      assert Delivery.format_error({[:served, :reduced_with], {:type, :reducer}}) =~
               "served.reduced_with"
    end
  end
end
