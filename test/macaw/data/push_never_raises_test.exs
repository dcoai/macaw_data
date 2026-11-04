defmodule Macaw.Data.PushNeverRaisesTest do
  @moduledoc """
  `Macaw.Data.Source.Push.drain/2` answers every delivery `Macaw.Data.Delivery.new/2`
  accepts (spec/01 §4, spec/00 §5, macaw_data#166).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table}
  alias Macaw.Data.Schema.Cache
  alias Macaw.Data.Source.Push

  @schema Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})
  @version Schema.version(@schema)

  defp push(schema \\ @schema, opts \\ []),
    do: Push.new!(:ticks, make_ref(), [cache: Cache.new([{:ticks, schema}])] ++ opts)

  defp take(push, kind, rows, opts) do
    d = Delivery.new!(rows, [schema: @version] ++ opts)

    message =
      case kind do
        :snapshot -> Push.snapshot_message(push.ref, d)
        seq when is_integer(seq) -> Push.increment_message(push.ref, seq, d)
      end

    {:ok, push} = Push.receive(push, message)
    Push.drain(push, fn _name -> {:error, :down} end)
  end

  defp held_rows(push), do: push |> Push.held() |> Delivery.rows!()

  @tag verifies: "push-unread-rows"
  test "a snapshot of tuple rows without names is an error of the push, and nothing moves" do
    pushed = take(push(), :snapshot, [{1, 1}], served: [position: 3])

    assert {[{:table, [{[:names], :required}]}], taken} = Push.take_errors(pushed)
    assert Push.held(taken) == nil
    assert taken.position == 0

    held = take(push(), :snapshot, [%{"t" => 1, "v" => 1}], served: [position: 1])
    again = take(held, :snapshot, [{2, 2}], served: [position: 4])

    assert again.errors == [{:table, [{[:names], :required}]}]
    assert Push.held(again) == Push.held(held)
    assert again.position == 1
  end

  @tag verifies: "push-unread-rows"
  test "an increment of tuple rows without names consumes its number and applies nothing" do
    held =
      take(push(), :snapshot, [%{"t" => 1, "v" => 1}], served: [position: 0, complete_until: 1])

    pushed =
      take(held, 1, [{2, 2}],
        retracted: [%{"t" => 1, "v" => 1}],
        replace: [%{from: 0, to: 5, rows: [%{"t" => 3, "v" => 3}]}],
        served: [complete_until: 9, stale: true]
      )

    assert pushed.errors == [{:table, [{[:names], :required}]}]
    assert Push.held(pushed) == Push.held(held)
    assert Push.held(pushed).served.complete_until == 1
    refute Push.held(pushed).served.stale
    assert pushed.position == 1

    # The number is consumed: the next one applies, with no gap asked for.
    next = take(pushed, 2, [%{"t" => 2, "v" => 2}], [])
    assert next.errors == [{:table, [{[:names], :required}]}]
    assert Push.refetch(next) == nil
    assert Enum.map(held_rows(next), & &1["t"]) == [1, 2]
  end

  @tag verifies: "push-unread-rows"
  test "with nothing held, a refused increment leaves nothing held" do
    pushed = take(push(), 1, [{1, 1}], [])

    assert pushed.errors == [{:table, [{[:names], :required}]}]
    assert Push.held(pushed) == nil
  end

  @tag verifies: "push-unread-rows"
  test "tuple rows that don't fit their names are the width fault" do
    pushed = take(push(), :snapshot, [{1, 2, 3}], names: ["t", "v"], served: [position: 0])
    assert pushed.errors == [{:table, [{[:names], {:width, 2, 3}}]}]

    pushed = take(push(), 1, [{1, 2, 3}], names: ["t", "v"])
    assert pushed.errors == [{:table, [{[:names], {:width, 2, 3}}]}]
  end

  @tag verifies: "push-unread-rows"
  test "named tuple rows still apply, by snapshot and by increment" do
    pushed = take(push(), :snapshot, [{1, 10}], names: ["t", "v"], served: [position: 0])
    pushed = take(pushed, 1, [{2, 20}], names: ["t", "v"])

    assert pushed.errors == []
    assert held_rows(pushed) == [%{"t" => 1, "v" => 10}, %{"t" => 2, "v" => 20}]
  end

  @tag verifies: "push-unread-rows"
  test "an increment under a schema the held rows don't pack under leaves the holding" do
    held = take(push(), :snapshot, [%{"t" => 1, "v" => 1}], served: [position: 0])
    time = Schema.new!(%{"t" => %{type: :time, window: true}, "v" => %{type: :number}})
    held = %{held | cache: Cache.put(held.cache, :ticks, time)}

    d = Delivery.new!([%{"t" => ~U[2026-01-01 00:00:00Z], "v" => 2}], schema: time.version)
    {:ok, pushed} = Push.receive(held, Push.increment_message(held.ref, 1, d))
    pushed = Push.drain(pushed, fn _name -> {:error, :down} end)

    assert [{:table, [{["t", 0], {:type, :time}}]}] = pushed.errors
    assert Push.held(pushed) == Push.held(held)
    assert pushed.position == 1
  end

  @tag verifies: "push-unread-rows"
  test "a row key that spells nothing is no column, and a retraction its span can't slot is not held" do
    pushed =
      take(push(), :snapshot, [%{"t" => 1, "v" => 1}], served: [position: 0, resolution: 1])

    retraction = %{{1, 2} => 3, "t" => "no time", "v" => 1}

    pushed =
      take(pushed, 1, [%{"t" => 2, "v" => 2, {1, 2} => 3}],
        retracted: [retraction],
        served: [resolution: 1]
      )

    assert pushed.errors == [{:retract, :not_held, retraction}]
    assert Enum.map(held_rows(pushed), & &1["t"]) == [1, 2]
  end

  @tag verifies: "push-unread-rows"
  test "a date's claim under a lateness of hours bounds at its midnight less the lateness" do
    time = Schema.new!(%{"t" => %{type: :time, window: true}, "v" => %{type: :number}})
    push = push(time, lateness: Duration.new!(hour: 1))

    snapshot =
      Delivery.new!([],
        schema: time.version,
        served: [position: 0, complete_until: ~D[2026-01-02]]
      )

    {:ok, pushed} = Push.receive(push, Push.snapshot_message(push.ref, snapshot))

    late = %{"t" => ~U[2026-01-01 22:00:00Z], "v" => 1}
    timely = %{"t" => ~U[2026-01-01 23:30:00Z], "v" => 2}
    increment = Delivery.new!([late, timely], schema: time.version)
    {:ok, pushed} = Push.receive(pushed, Push.increment_message(pushed.ref, 1, increment))
    pushed = Push.drain(pushed, fn _name -> {:error, :down} end)

    assert pushed.errors == [{:late, late, ~N[2026-01-01 23:00:00]}]
    assert [%{"v" => 2}] = held_rows(pushed)
  end

  @tag verifies: "push-unread-rows"
  test "a resolution too fine or too coarse for a span lays chunks by row count" do
    for {schema, r} <- [
          {@schema, 1.0e-320},
          {@schema, 1.0e308},
          {@schema, 10 ** 400},
          {Schema.new!(%{"t" => %{type: :time, window: true}}), 1.0e-12},
          {Schema.new!(%{"t" => %{type: :time, window: true}}), 1.0e308}
        ] do
      description = Macaw.Data.Source.Description.new!(schema: schema)
      assert Macaw.Data.Source.Description.chunk_span(description, r) == nil
    end

    pushed =
      take(push(), :snapshot, [%{"t" => 1, "v" => 1}],
        served: [position: 0, resolution: 1.0e-320]
      )

    assert pushed.errors == []
    assert [%{"t" => 1}] = held_rows(pushed)
  end

  @tag verifies: "push-unread-rows"
  test "a window value past a float's precision over its span is its own slot" do
    pushed =
      take(push(), :snapshot, [%{"t" => 1.0e308, "v" => 1}],
        served: [position: 0, resolution: 1.0e-5]
      )

    assert pushed.errors == []
    assert [%{"t" => 1.0e308}] = held_rows(pushed)
  end

  @tag verifies: "push-unread-rows"
  test "Table.new/2 answers a window value of another kind than its origin's span as the column's fault" do
    origin = fn span -> [origin: %{source: :s, resolution: 1, window: "t", span: span}] end

    assert {:error, [{["t", 0], {:type, :time}}]} =
             Table.new([{"t", :time, [1]}], origin.(Duration.new!(second: 1)))

    assert {:error, [{["t", 0], {:type, :number}}]} =
             Table.new([{"t", :number, [~U[2026-01-01 00:00:00Z]]}], origin.(10))
  end

  @tag verifies: "push-unread-rows"
  test "Table.get/2 of a name of neither spelling is nil" do
    assert Table.get(%{"a" => 1}, 1) == nil
    assert Table.get(%{1 => :one}, 1) == :one
  end

  defp schemas do
    member_of([
      Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}}),
      Schema.new!(%{"t" => %{type: :time, window: true}, "v" => %{type: :number}}),
      Schema.new!(%{
        "t" => %{type: :time, window: true},
        "id" => %{type: :category, identity: true},
        "v" => %{type: :number}
      }),
      Schema.new!(%{"id" => %{type: :category, identity: true}, "v" => %{type: :text}}),
      Schema.new!(%{"t" => %{type: :text}, "v" => %{type: :number}})
    ])
  end

  defp value do
    one_of([
      integer(-5..5),
      float(min: -5.0, max: 5.0),
      boolean(),
      constant(nil),
      atom(:alphanumeric),
      string(:printable, max_length: 4),
      member_of([
        ~U[2026-01-01 00:00:00Z],
        ~N[2026-01-01 00:00:01],
        ~D[2026-01-02],
        "2026-01-01T00:00:02Z",
        make_ref(),
        {1, 2},
        [1],
        %{a: 1},
        10 ** 400,
        -(10 ** 400),
        1.0e308,
        -1.0e308,
        5.0e-324,
        ~U[-9999-01-01 00:00:01Z],
        ~U[9999-12-31 23:59:59.999999Z],
        ~D[-9999-01-01],
        ~N[9999-12-31 23:59:59]
      ])
    ])
  end

  defp row_map do
    gen all(
          pairs <-
            list_of(
              tuple(
                {member_of([
                   "t",
                   "v",
                   "id",
                   :t,
                   :v,
                   :id,
                   "other",
                   1,
                   {1, 2},
                   nil,
                   make_ref(),
                   %{a: 1}
                 ]), value()}
              ),
              max_length: 3
            )
        ) do
      Map.new(pairs)
    end
  end

  defp rows do
    one_of([
      list_of(row_map(), max_length: 3),
      list_of(tuple({value(), value()}), max_length: 3),
      list_of(tuple({value(), value(), value()}), max_length: 3),
      list_of(value(), max_length: 3),
      map(
        list_of(tuple({member_of(["t", "v", :id]), list_of(value(), length: 2)}), max_length: 3),
        &Map.new/1
      ),
      list_of(tuple({member_of(["t", "v"]), list_of(value(), length: 2)}), max_length: 2),
      constant(Table.new!([{"t", :number, [1, 2]}, {"v", :number, [3, 4]}])),
      constant(Table.new!([{"other", :text, ["a"]}]))
    ])
  end

  defp served do
    optional_map(%{
      window:
        one_of([
          constant(nil),
          list_of(value(), length: 2),
          constant(%{west: 0, south: 0, east: 1, north: 1})
        ]),
      resolution:
        one_of([
          value(),
          member_of([
            :second,
            :minute,
            :hour,
            1,
            0.5,
            1.0e-320,
            1.0e-12,
            1.0e300,
            1.0e308,
            10 ** 400,
            7
          ])
        ]),
      capped: boolean(),
      stale: boolean(),
      reduced_by: member_of([nil, :lttb]),
      complete_until:
        member_of([
          nil,
          0,
          2,
          10 ** 400,
          -1.0e308,
          ~U[-9999-01-01 00:00:01Z],
          1.5,
          ~U[2026-01-01 00:00:00Z],
          ~N[2026-01-01 00:00:00],
          ~D[2026-01-01]
        ])
    })
  end

  defp replacement do
    optional_map(%{
      from: value(),
      to: value(),
      identities: one_of([constant(nil), list_of(value(), max_length: 2)]),
      rows: list_of(row_map(), max_length: 2)
    })
  end

  defp delivery do
    gen all(
          rows <- rows(),
          names <- member_of([nil, [], ["t", "v"], ["v", "t"], [:t, :v], ["t", "v", "id"]]),
          served <- served(),
          position <- member_of([nil, 0, 1, 2, 5]),
          versioned <- boolean(),
          retracted <- list_of(row_map(), max_length: 2),
          replace <- list_of(replacement(), max_length: 2)
        ) do
      {rows,
       [
         names: names,
         served: Map.put(served, :position, position),
         retracted: retracted,
         replace: replace
       ], versioned}
    end
  end

  defp message do
    gen all(kind <- member_of([:snapshot, :increment]), seq <- integer(1..4), d <- delivery()) do
      {kind, seq, d}
    end
  end

  # A Duration of any sign or length is a lateness, whichever claim it is taken from.
  defp lateness do
    member_of([
      nil,
      0,
      1,
      -5,
      1.0e308,
      -1.0e308,
      10 ** 400,
      Duration.new!(second: 1),
      Duration.new!(day: 1),
      Duration.new!(second: -1),
      Duration.new!(month: 1),
      Duration.new!(year: 100_000),
      Duration.new!(year: -100_000),
      Duration.new!(second: 10 ** 30),
      Duration.new!([])
    ])
  end

  defp limit, do: member_of([100_000, 2, 1, 0, -1, 10 ** 400, -(10 ** 400)])

  defp chunk_span do
    member_of([
      nil,
      10,
      0.5,
      5.0e-324,
      1.0e308,
      10 ** 400,
      Duration.new!(second: 1),
      Duration.new!(day: 1),
      Duration.new!(second: 10 ** 30)
    ])
  end

  defp from do
    one_of([value(), member_of([0, 2, 1.5, ~U[2026-01-01 00:00:01Z], ~D[2026-01-02]])])
  end

  @tag verifies: ["push-unread-rows", "push-trim-box"]
  property "drain/2 and trim/2 answer a push for any delivery Delivery.new/2 accepts" do
    check all(
            first <- schemas(),
            second <- schemas(),
            lateness <- lateness(),
            limit <- limit(),
            chunk_span <- chunk_span(),
            from <- from(),
            messages <- list_of(message(), max_length: 4),
            max_runs: 300
          ) do
      push =
        Push.new!(:ticks, make_ref(),
          lateness: lateness,
          limit: limit,
          chunk_span: chunk_span,
          cache: Cache.new([{:ticks, first}])
        )

      describe = fn _ -> {:ok, first} end

      pushed =
        messages
        |> Enum.with_index()
        |> Enum.reduce(push, fn {{kind, seq, {rows, opts, versioned}}, i}, push ->
          schema = if rem(i, 2) == 0, do: first, else: second
          push = %{push | cache: Cache.put(push.cache, :ticks, schema)}
          opts = if versioned, do: [{:schema, schema.version} | opts], else: opts

          case Delivery.new(rows, opts) do
            {:ok, d} ->
              message =
                if kind == :snapshot,
                  do: Push.snapshot_message(push.ref, d),
                  else: Push.increment_message(push.ref, seq, d)

              {:ok, push} = Push.receive(push, message)
              push = Push.drain(push, describe)

              case Push.trim(push, from) do
                {:ok, %Push{} = trimmed} -> trimmed
                {:error, [{[:from], {:type, _type}}]} -> push
              end

            {:error, _faults} ->
              push
          end
        end)

      assert %Push{pending: []} = pushed
    end
  end
end
