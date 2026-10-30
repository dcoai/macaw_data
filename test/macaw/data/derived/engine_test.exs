defmodule Macaw.Data.Derived.EngineTest do
  # The engine (spec/02 §8): defined, pulsed in rank order, faults kept local. Every pulse
  # is driven by the `now` the test passes: nothing waits on a clock. Ported from
  # visualize's `Visualize.VirtualSource.EngineTest`: sources in place of feeds, a request
  # window in place of a box.
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Macaw.Data.{Delivery, Derived, Schema}
  alias Macaw.Data.Derived.{Engine, Functions}

  doctest Engine

  # A host's function that never answers: blocked in `receive`, it spends no reductions.
  defmodule Blocked do
    use Macaw.Data.Derived.Functions
    defsource(blocked(_inputs), do: receive(do: (:never_sent -> [])))
  end

  @names ~w(hosts host cpu n a b c d sum total state health trend load x)a
  setup_all do
    {:ok, names: @names}
  end

  @hosts Schema.new!(%{
           t: %{type: :number, window: true},
           host: %{type: :category, identity: true},
           cpu: %{type: :number}
         })

  defp source(id, from, elixir, schema \\ %{n: %{type: :number}}, extra \\ []) do
    Derived.new!([id: id, from: from, schema: schema, elixir: elixir] ++ extra)
  end

  defp rows(n), do: for(i <- 1..n, do: %{t: i, host: "h#{rem(i, 2)}", cpu: i * 10})

  defp push(engine, rows, now \\ 0),
    do: Engine.push(engine, %{hosts: Delivery.new(rows)}, %{hosts: @hosts}, now)

  defp count, do: "fn %{hosts: rows} -> [%{n: Enum.count(rows)}] end"

  describe "new/2: defining (spec/02 §8.1)" do
    @tag verifies: "derived-engine-defines"
    test "every input resolves, and a host function is registered" do
      a = source(:a, [nowhere: nil], count())

      f =
        Derived.new!(
          id: :f,
          from: [hosts: nil],
          schema: %{n: %{type: :number}},
          function: :f
        )

      assert {:error, errors} = Engine.new(%{["a"] => a, ["f"] => f}, sources: [:hosts])

      assert errors == [
               {["a"], [:from, 0], {:unknown_input, "nowhere"}},
               {["f"], [:function], {:undeclared, :function, "f"}}
             ]
    end

    @tag verifies: "derived-engine-defines"
    test "a cycle is refused, named, a source reading itself included" do
      a = source(:a, [b: nil], "fn %{b: r} -> r end")
      b = source(:b, [a: nil], "fn %{a: r} -> r end")
      c = source(:c, [c: nil], "fn %{c: r} -> r end")
      d = source(:d, [a: nil], "fn %{a: r} -> r end")

      assert {:error, errors} = Engine.new(%{["a"] => a, ["b"] => b, ["c"] => c, ["d"] => d})

      assert errors == [
               {["a"], [:from], {:cycle, [["a"], ["b"]]}},
               {["c"], [:from], {:cycle, [["c"]]}}
             ]
    end

    @tag verifies: ["derived-engine-defines", "derived-engine-run"]
    test "inputs resolve from the source's own scope, inside out, then to a source" do
      outer = source(:sum, [hosts: nil], count())
      inner = source(:sum, [hosts: nil], "fn %{hosts: r} -> [%{n: 0 * Enum.count(r)}] end")
      reader = source(:total, [sum: nil], "fn %{sum: [%{n: n}]} -> [%{n: n}] end")

      sources = %{[:sum] => outer, [:cell, :sum] => inner, [:cell, :total] => reader}
      {:ok, engine} = Engine.new(sources, sources: [:hosts], debounce: 0)

      assert Engine.resolve(engine, [:cell], :sum) == {:derived, ["cell", "sum"]}
      assert Engine.resolve(engine, [:other], :sum) == {:derived, ["sum"]}
      assert Engine.resolve(engine, [:cell], :hosts) == {:source, "hosts"}
      assert Engine.resolve(engine, [:cell], :nothing) == :error

      engine = engine |> push(rows(3)) |> Engine.run(0)
      assert Delivery.rows(Engine.outputs(engine)[["cell", "total"]]) == [%{"n" => 0}]
    end
  end

  describe "pulses (spec/02 §8.2)" do
    setup do
      # A diamond: a and b read the source, c reads both, d reads c.
      a = source(:a, [hosts: nil], count())

      b =
        source(:b, [hosts: nil], "fn %{hosts: r} -> [%{n: Enum.sum(Enum.map(r, & &1.cpu))}] end")

      c = source(:c, [a: nil, b: nil], "fn %{a: [%{n: x}], b: [%{n: y}]} -> [%{n: x + y}] end")
      d = source(:d, [c: nil], "fn %{c: [%{n: n}]} -> [%{n: n * 2}] end")

      {:ok, engine} =
        Engine.new(%{["a"] => a, ["b"] => b, ["c"] => c, ["d"] => d},
          sources: [:hosts],
          debounce: 100
        )

      {:ok, engine: engine}
    end

    @tag verifies: "derived-engine-pulses"
    test "rank order, each source at most once per pulse, no glitch", %{engine: engine} do
      engine = push(engine, rows(2), 0)
      assert Engine.due(engine) == 100

      # Not yet due: nothing runs.
      assert Engine.run(engine, 99) == engine

      engine = Engine.run(engine, 100)
      assert Engine.due(engine) == nil
      assert Engine.runs(engine) == %{["a"] => 1, ["b"] => 1, ["c"] => 1, ["d"] => 1}
      assert Delivery.rows(Engine.outputs(engine)[["c"]]) == [%{"n" => 2 + 30}]
      assert Delivery.rows(Engine.outputs(engine)[["d"]]) == [%{"n" => 64}]
      assert Engine.status(engine) |> Map.values() |> Enum.uniq() == [:live]
    end

    @tag verifies: "derived-engine-pulses"
    test "changes within the debounce are one pulse; an unchanged source marks nothing", %{
      engine: engine
    } do
      engine = engine |> push(rows(2), 0) |> push(rows(3), 40) |> push(rows(4), 90)
      assert Engine.due(engine) == 100
      engine = Engine.run(engine, 100)
      assert Engine.runs(engine)[["c"]] == 1
      assert Delivery.rows(Engine.outputs(engine)[["a"]]) == [%{"n" => 4}]

      same = push(engine, rows(4), 200)
      assert Engine.due(same) == nil
    end

    @tag verifies: "derived-engine-pulses"
    test "an answer that does not change marks no reader", %{engine: engine} do
      engine = engine |> push(rows(2), 0) |> Engine.run(100)
      # Same count and sum, other rows: a and b run, their answers are unchanged.
      swapped = [%{t: 1, host: "h1", cpu: 20}, %{t: 2, host: "h0", cpu: 10}]
      engine = engine |> push(swapped, 200) |> Engine.run(300)
      assert Engine.runs(engine) == %{["a"] => 2, ["b"] => 2, ["c"] => 1, ["d"] => 1}
    end

    @tag verifies: "derived-engine-pulses"
    test "a source waits while an input has no delivery" do
      a = source(:a, [hosts: nil], count())
      {:ok, engine} = Engine.new(%{["a"] => a}, sources: [:hosts], debounce: 0)
      engine = Engine.push(engine, %{}, %{}, 0) |> Engine.run(0)
      assert Engine.status(engine) == %{["a"] => :loading}
      assert Engine.runs(engine) == %{["a"] => 0}
    end
  end

  describe "names a stored function reads (spec/02 §2.2)" do
    @tag verifies: "derived-engine-run"
    test "a row's fields and category values are read as the function's own literals are" do
      checks = Schema.new!(%{day: %{type: :number}, state: %{type: :category}})

      # `:ok` is a word Elixir's functions take, so the row's `:ok` and the literal are one
      # atom; `:warning` is no word, so both are its string; `day` is a word, so the
      # function's `%{day: d}` matches the row's field, and `row.state` reads it by spelling.
      elixir = """
      fn %{checks: rows} ->
        [%{n: Enum.count(rows, fn %{day: d} = row -> d > 1 and row.state in [:ok, :warning] end)}]
      end
      """

      source = source(:a, [checks: nil], elixir)
      {:ok, engine} = Engine.new(%{["a"] => source}, sources: [:checks], debounce: 0)

      rows = [
        %{day: 1, state: :ok},
        %{day: 2, state: :ok},
        %{day: 3, state: :warning},
        %{day: 4, state: :error}
      ]

      engine =
        engine
        |> Engine.push(%{checks: Delivery.new(rows)}, %{checks: checks}, 0)
        |> Engine.run(0)

      assert Delivery.rows(Engine.outputs(engine)[["a"]]) == [%{"n" => 2}]
    end
  end

  describe "faults (spec/02 §8.3)" do
    defp chain(elixir) do
      a =
        if elixir == :blocked,
          do:
            Derived.new!(
              id: :a,
              from: [hosts: nil],
              schema: %{n: %{type: :number}},
              function: :blocked
            ),
          else: source(:a, [hosts: nil], elixir)

      d = source(:d, [a: nil], "fn %{a: [%{n: n}]} -> [%{n: n + 1}] end")

      {:ok, engine} =
        Engine.new(%{["a"] => a, ["d"] => d},
          sources: [:hosts],
          debounce: 0,
          functions: Functions.registry([Blocked]),
          max_reductions: 1_000_000,
          timeout: 50,
          max_heap: 200_000
        )

      engine
    end

    @tag verifies: "derived-engine-fault-kept"
    test "a fault keeps the last good output and the pulse stops there" do
      a = "fn %{hosts: rows} -> [%{n: 10 / (Enum.count(rows) - 3)}] end"
      engine = chain(a) |> push(rows(2)) |> Engine.run(0)
      assert Delivery.rows(Engine.outputs(engine)[["a"]]) == [%{"n" => -10.0}]
      assert Delivery.rows(Engine.outputs(engine)[["d"]]) == [%{"n" => -9.0}]

      engine = engine |> push(rows(3)) |> Engine.run(0)
      assert Engine.faults(engine) == %{["a"] => %{kind: :raised, detail: ArithmeticError}}
      assert Engine.status(engine)[["a"]] == {:down, {:derived, "a", :raised}}
      assert Delivery.rows(Engine.outputs(engine)[["a"]]) == [%{"n" => -10.0}]
      assert Engine.runs(engine) == %{["a"] => 2, ["d"] => 1}

      # A good answer clears it.
      engine = engine |> push(rows(4)) |> Engine.run(0)
      assert Engine.faults(engine) == %{}
      assert Delivery.rows(Engine.outputs(engine)[["d"]]) == [%{"n" => 11.0}]
    end

    @tag verifies: "derived-engine-fault-kept"
    test "the six kinds" do
      kinds = %{
        reductions:
          "fn _ -> Enum.reduce(1..100_000_000_000_000, 0, fn x, acc -> rem(acc + x, 7) end) end",
        hung: :blocked,
        memory: "fn _ -> Enum.to_list(1..100_000_000_000) end",
        raised: "fn _ -> Map.fetch!(%{}, :n) end",
        nonconforming: "fn _ -> [%{n: :none}] end",
        restricted: "fn %{hosts: rows} -> [%{n: Enum.count(rows, & &1.load)}] end"
      }

      for {kind, elixir} <- kinds do
        engine = chain(elixir) |> push(rows(2)) |> Engine.run(0)
        assert %{kind: ^kind} = Engine.faults(engine)[["a"]], "#{kind}"
        assert Engine.status(engine)[["d"]] == :loading
      end

      engine = chain(kinds.nonconforming) |> push(rows(2)) |> Engine.run(0)
      assert Engine.faults(engine)[["a"]].detail == {0, "n", {:type, :number}}

      engine = chain(kinds.restricted) |> push(rows(2)) |> Engine.run(0)

      assert [{[:elixir], {:check, 1, {:unknown_field, "load"}}}] =
               Engine.faults(engine)[["a"]].detail
    end
  end

  describe "per identity (spec/02 §1.3)" do
    defp health(elixir, window \\ nil) do
      health =
        source(
          :health,
          [hosts: window],
          elixir,
          %{
            host: %{type: :category, identity: true},
            state: %{type: :category, values: [:ok, :error]},
            n: %{type: :number}
          },
          per: :identity
        )

      {:ok, engine} = Engine.new(%{[:health] => health}, sources: [:hosts], debounce: 0)
      engine
    end

    @tag verifies: "derived-engine-run"
    test "once per entity, joined back by identity, in order of first appearance" do
      engine =
        health(
          "fn rows -> %{n: Enum.count(rows), state: if(Enum.count(rows) > 2, do: :error, else: :ok)} end"
        )
        |> push(rows(5))
        |> Engine.run(0)

      assert Delivery.rows(Engine.outputs(engine)[["health"]]) == [
               %{"host" => "h1", "n" => 3, "state" => :error},
               %{"host" => "h0", "n" => 2, "state" => :ok}
             ]
    end

    @tag verifies: "derived-engine-run"
    test "a window of the last n rows is each entity's newest n" do
      engine =
        health("fn rows -> %{n: Enum.sum(Enum.map(rows, & &1.cpu))} end", %{last: 2})
        |> push(rows(5))
        |> Engine.run(0)

      # h1: cpu 10, 30, 50 → the newest two, 30 + 50; h0: 20 + 40. In the window h0 comes first.
      assert Delivery.rows(Engine.outputs(engine)[["health"]]) == [
               %{"host" => "h0", "n" => 60},
               %{"host" => "h1", "n" => 80}
             ]
    end

    @tag verifies: "derived-engine-run"
    test "a row naming another entity does not conform" do
      engine = health(~S|fn _ -> %{host: "other"} end|) |> push(rows(2)) |> Engine.run(0)

      assert Engine.faults(engine)[["health"]] == %{
               kind: :nonconforming,
               detail: {0, "host", :identity}
             }
    end

    @tag verifies: "derived-engine-run"
    test "a request window is finished as the runtime finishes a delivery" do
      engine =
        health("fn rows -> %{n: Enum.count(rows)} end", %{window: [2, 3]})
        |> push(rows(5))
        |> Engine.run(0)

      assert Delivery.rows(Engine.outputs(engine)[["health"]]) == [
               %{"host" => "h0", "n" => 1},
               %{"host" => "h1", "n" => 1}
             ]
    end
  end

  describe "watermarks (spec/02 §8.6)" do
    @tag verifies: "derived-watermarks"
    test "a derived source's complete_until is the minimum of its inputs', idle inputs left out" do
      sum = "fn %{a: a, b: b} -> [%{n: Enum.count(a) + Enum.count(b)}] end"
      both = source(:both, [a: nil, b: nil], sum)
      capped = source(:capped, [a: %{window: [0, 40]}], "fn %{a: a} -> [%{n: Enum.count(a)}] end")
      next = source(:next, [both: nil], "fn %{both: [%{n: n}]} -> [%{n: n}] end")

      {:ok, engine} =
        Engine.new(%{["both"] => both, ["capped"] => capped, ["next"] => next},
          sources: [:a, :b],
          debounce: 0,
          idle_after: %{b: 1_000}
        )

      at = fn cu, rows -> Delivery.new(rows, served: [complete_until: cu]) end
      row = fn t -> %{t: t, host: "h", cpu: 1} end
      schemas = %{a: @hosts, b: @hosts}
      watermark = fn engine, path -> Engine.outputs(engine)[path].served.complete_until end

      # The minimum of the inputs'; a request window's upper bound caps it; a derived
      # input contributes its output's.
      engine =
        engine
        |> Engine.push(%{a: at.(50, [row.(1)]), b: at.(30, [row.(2)])}, schemas, 0)
        |> Engine.run(0)

      assert watermark.(engine, ["both"]) == 30
      assert watermark.(engine, ["capped"]) == 40
      assert watermark.(engine, ["next"]) == 30

      # A watermark-only change is a changed answer: the reader runs again.
      runs = Engine.runs(engine)[["next"]]

      engine =
        engine
        |> Engine.push(%{a: at.(50, [row.(1)]), b: at.(35, [row.(2)])}, schemas, 10)
        |> Engine.run(10)

      assert watermark.(engine, ["both"]) == 35
      assert watermark.(engine, ["next"]) == 35
      assert Engine.runs(engine)[["next"]] == runs + 1

      # b has delivered nothing for idle_after: left out when a moves on; no clock read,
      # only the now given.
      engine =
        engine
        |> Engine.push(%{a: at.(60, [row.(1), row.(3)]), b: at.(35, [row.(2)])}, schemas, 1_010)
        |> Engine.run(1_010)

      assert watermark.(engine, ["both"]) == 60

      # It rejoins on its next delivery.
      engine =
        engine
        |> Engine.push(
          %{a: at.(60, [row.(1), row.(3)]), b: at.(40, [row.(2), row.(4)])},
          schemas,
          1_020
        )
        |> Engine.run(1_020)

      assert watermark.(engine, ["both"]) == 40

      # An input with no claim leaves none.
      engine =
        engine
        |> Engine.push(%{a: at.(nil, [row.(5)]), b: at.(40, [row.(2), row.(4)])}, schemas, 1_030)
        |> Engine.run(1_030)

      assert watermark.(engine, ["both"]) == nil

      # Every input idle (a debounce longer than idle_after): none is left out.
      {:ok, slow} =
        Engine.new(%{["both"] => both},
          sources: [:a, :b],
          debounce: 200,
          idle_after: %{a: 100, b: 100}
        )

      slow =
        slow
        |> Engine.push(%{a: at.(50, [row.(1)]), b: at.(30, [row.(2)])}, schemas, 0)
        |> Engine.run(200)

      assert watermark.(slow, ["both"]) == 30

      # A description's idle_after is a positive integer of milliseconds.
      alias Macaw.Data.Source.Description
      assert {:ok, %{idle_after: 1_000}} = Description.new(schema: @hosts, idle_after: 1_000)
      assert {:ok, %{idle_after: nil}} = Description.new(schema: @hosts)

      for bad <- [0, -5, 1.5, "1s"] do
        assert Description.new(schema: @hosts, idle_after: bad) ==
                 {:error, [{[:idle_after], {:type, :pos_integer}}]}
      end
    end
  end
end
