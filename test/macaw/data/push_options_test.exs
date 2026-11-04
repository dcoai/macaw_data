defmodule Macaw.Data.PushOptionsTest do
  @moduledoc """
  `Push.new/3` checks its options' values, and `Push.trim/2` answers a box window
  (spec/01 §4, macaw_data#177).
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.{Delivery, Error, Fault, Schema, Table}
  alias Macaw.Data.Schema.Cache
  alias Macaw.Data.Source.{Description, Push}

  @numbered Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})
  @timed Schema.new!(%{"t" => %{type: :time, window: true}, "v" => %{type: :number}})
  @plain Schema.new!(%{"t" => %{type: :number}, "v" => %{type: :number}})

  # Keeps the compiler from judging a deliberately bad value.
  defp opaque(value), do: :erlang.binary_to_term(:erlang.term_to_binary(value))

  defp at(@timed, t), do: DateTime.add(~U[2026-01-01 00:00:00Z], t, :second)
  defp at(_schema, t), do: t

  defp rows(schema, ts), do: for(t <- ts, do: %{"t" => at(schema, t), "v" => t})

  defp push(schema, opts),
    do: Push.new!(:ticks, make_ref(), [cache: Cache.new([{:ticks, schema}])] ++ opts)

  # A snapshot and an increment drained, one late row among them.
  defp driven(schema, opts) do
    push = push(schema, opts)

    snapshot =
      Delivery.new!(rows(schema, [1, 2, 3, 4, 5]),
        schema: schema.version,
        served: [position: 0, complete_until: at(schema, 3), resolution: 1]
      )

    increment =
      Delivery.new!(rows(schema, [2, 6]),
        schema: schema.version,
        served: [complete_until: at(schema, 4), resolution: 1]
      )

    {:ok, push} =
      push
      |> Push.snapshot(snapshot)
      |> Push.receive(Push.increment_message(push.ref, 1, increment))

    Push.drain(push, fn _name -> flunk("describe asked") end)
  end

  describe "a value it can't use" do
    @tag verifies: "push-options"
    test "is its fault by path, and the twin raises it" do
      for {key, type, bad} <- [
            {:limit, :integer, ["x", nil, :infinity, 2.5, 100.0, 1.0e308, [], %{}]},
            {:lateness, :lateness, ["x", :a, true, [], %{}, {1, 2}, %Duration{second: "x"}]},
            {:chunk_span, :chunk_span,
             [
               "x",
               true,
               0,
               0.0,
               -1,
               %{},
               Duration.new!([]),
               Duration.new!(second: -1),
               Duration.new!(month: 1),
               %Duration{second: "x"},
               %Duration{microsecond: 5}
             ]},
            {:cache, :cache,
             [5, nil, %{}, %Cache{entries: 5}, %Cache{entries: %{{:a, "v"} => 1}}]}
          ],
          value <- bad do
        opts = [{key, opaque(value)}]
        faults = [{[key], {:type, type}}]

        assert Push.new(:ticks, make_ref(), opts) == {:error, faults}
        error = assert_raise Error, fn -> Push.new!(:ticks, make_ref(), opts) end
        assert error.reason == faults
        assert Fault.sentence(faults) =~ "must be a"
      end
    end

    @tag verifies: "push-options"
    test "every one is reported at once" do
      opts = opaque(cache: 1, limit: "x", lateness: "y", chunk_span: 0)

      assert Push.new(:ticks, make_ref(), opts) ==
               {:error,
                [
                  {[:cache], {:type, :cache}},
                  {[:limit], {:type, :integer}},
                  {[:lateness], {:type, :lateness}},
                  {[:chunk_span], {:type, :chunk_span}}
                ]}
    end

    @tag verifies: "push-options"
    test "a Duration holding no integers is no span to the description or the table either" do
      bad = opaque(%Duration{second: "x"})

      assert {:error, [{[:chunk_span], {:type, :duration}}]} =
               Description.new(schema: @timed, chunk_span: bad)

      assert {:error, [{[:origin, :span], {:type, :duration}}]} =
               Table.new([{"t", :time, []}],
                 origin: %{source: :s, resolution: 1, window: "t", span: bad}
               )
    end
  end

  describe "a value that works today" do
    @tag verifies: "push-options"
    test "a limit of zero or below holds nothing, and any integer above is a limit" do
      for limit <- [0, -1, -(10 ** 400)] do
        pushed = driven(@plain, limit: limit)
        assert Table.size(Push.held(pushed).rows) == 0
        assert Push.held(pushed).served.capped
        assert pushed.errors == []
      end

      assert Table.size(Push.held(driven(@plain, limit: 3)).rows) == 3
      assert Table.size(Push.held(driven(@plain, limit: 10 ** 400)).rows) == 7
    end

    @tag verifies: "push-options"
    test "a lateness of either sign, and a Duration of any sign or length, is taken" do
      # A negative lateness bounds past the claim: 3 + 5, so both rows are late.
      negative = driven(@numbered, lateness: -5)
      assert [{:late, _, 8}, {:late, _, 8}] = negative.errors
      assert Table.size(Push.held(negative).rows) == 5

      for lateness <- [0, 1, 1.5, 10 ** 400, 1.0e308, -1.0e308] do
        assert %Push{} = driven(@numbered, lateness: lateness)
      end

      for lateness <- [
            Duration.new!(second: 1),
            Duration.new!(second: -1),
            Duration.new!(month: 1),
            Duration.new!(year: 100_000),
            Duration.new!([])
          ] do
        assert %Push{} = driven(@timed, lateness: lateness)
      end
    end

    @tag verifies: "push-options"
    test "a value of the wrong kind for the window field is still the delivery's fault" do
      assert [{:lateness, :incompatible, _claim} | _] =
               driven(@timed, lateness: 1).errors

      assert [{:lateness, :incompatible, _claim} | _] =
               driven(@numbered, lateness: Duration.new!(second: 1)).errors

      assert [{:table, _faults} | _] = driven(@timed, chunk_span: 10).errors

      assert [{:table, _faults} | _] =
               driven(@numbered, chunk_span: Duration.new!(second: 1)).errors
    end

    @tag verifies: "push-options"
    test "a span of either kind, and nil for each option but limit, is kept" do
      for span <- [10, 0.5, 5.0e-324, 1.0e308, 10 ** 400] do
        assert %{errors: []} = driven(@numbered, chunk_span: span)
      end

      assert %{errors: []} = driven(@timed, chunk_span: Duration.new!(second: 1))

      # An integer span past what a float holds, over float values of either sign.
      span = 10 ** 400

      snapshot =
        Delivery.new!([%{"t" => -5.0, "v" => 1}, %{"t" => 5.0, "v" => 2}],
          schema: @numbered.version,
          served: [position: 0]
        )

      pushed =
        push(@numbered, chunk_span: span)
        |> Push.snapshot(snapshot)
        |> Push.drain(fn _name -> flunk("describe asked") end)

      assert pushed.errors == []
      assert Enum.map(Delivery.rows!(Push.held(pushed)), & &1["t"]) == [-5.0, 5.0]

      assert {:ok, %Push{lateness: nil, chunk_span: nil}} =
               Push.new(:t, make_ref(), lateness: nil, chunk_span: nil)
    end
  end

  describe "a box window" do
    defp boxed(ts, from) do
      box = %{west: 0, south: 0, east: 1, north: 1}

      snapshot =
        Delivery.new!(rows(@numbered, ts),
          schema: @numbered.version,
          served: [position: 0, window: box, complete_until: 2]
        )

      pushed =
        push(@numbered, chunk_span: 10)
        |> Push.snapshot(snapshot)
        |> Push.drain(fn _name -> flunk("describe asked") end)

      {box, pushed, Push.trim(pushed, from)}
    end

    @tag verifies: "push-trim-box"
    test "stays as it is while the chunks wholly before from drop" do
      {box, pushed, answer} = boxed([1, 2, 11, 12, 21], 11)
      assert {:ok, trimmed} = answer

      assert Push.held(trimmed).served.window == box
      assert Push.held(trimmed).served.complete_until == 2
      assert Enum.map(Delivery.rows!(Push.held(trimmed)), & &1["t"]) == [11, 12, 21]
      assert trimmed.trimmed == 11
      assert Table.size(Push.held(pushed).rows) == 5

      assert Push.trim!(pushed, 11) == trimmed
    end

    @tag verifies: "push-trim-box"
    test "a from of the wrong type is still its fault, and nothing before from is no drop" do
      {box, pushed, answer} = boxed([1, 2], 0)
      assert {:ok, trimmed} = answer
      assert Push.held(trimmed).served.window == box
      assert Table.size(Push.held(trimmed).rows) == 2
      assert Push.trim(pushed, "x") == {:error, [{[:from], {:type, :number}}]}
    end

    @tag verifies: "push-trim-box"
    test "an increment after the trim still applies, and the served window is a range again" do
      {_box, pushed, _answer} = boxed([1, 2, 11], 11)
      {:ok, trimmed} = Push.trim(pushed, 11)

      increment = Delivery.new!(rows(@numbered, [12]), schema: @numbered.version)
      {:ok, next} = Push.receive(trimmed, Push.increment_message(trimmed.ref, 1, increment))
      next = Push.drain(next, fn _name -> flunk("describe asked") end)

      assert next.errors == []
      assert Enum.map(Delivery.rows!(Push.held(next)), & &1["t"]) == [11, 12]
      assert [_from, 12] = Push.held(next).served.window
    end
  end
end
