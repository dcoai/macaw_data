defmodule Macaw.Data.Derived.EngineContextTest do
  # What the engine calls a function with (spec/02 §2.3, §8.2), and a derived source read as
  # a source (§8.5). Ported from visualize's `Visualize.VirtualSource.ContextTest` without
  # its variables: a context holds the inputs' schemas and served facts, and nothing else.
  # Every pulse is driven by the `now` the test passes: nothing waits on a clock.
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Macaw.Data.{Delivery, Derived, Schema, Source}
  alias Macaw.Data.Derived.{Engine, Functions, Output}
  alias Macaw.Data.Source.Conformance

  # Host functions that hand their context back to the test, which is the engine's owner
  # and so the bounded call's first caller.
  defmodule Sources do
    use Macaw.Data.Derived.Functions

    defsource seen(inputs, context) do
      [owner | _] = Process.get(:"$callers")
      send(owner, {:context, inputs, context})
      [%{n: 1}]
    end

    defsource rows_only(inputs) do
      [owner | _] = Process.get(:"$callers")
      send(owner, {:rows_only, inputs})
      [%{n: 1}]
    end
  end

  @names ~w(hosts host cpu n state t)a
  setup_all do
    {:ok, names: @names}
  end

  @hosts Schema.new!(%{
           t: %{type: :number, window: true},
           host: %{type: :category, identity: true},
           state: %{
             type: :category,
             values: [%{value: :ok, name: "OK", color: "#2e7d32"}, :down],
             status: %{ok: :good}
           },
           cpu: %{type: :number, bounds: [0, 100], continuity: 60}
         })

  @rows [%{t: 1, host: "a", state: :ok, cpu: 10}, %{t: 2, host: "b", state: :down, cpu: 20}]

  defp host(id, function, extra \\ []) do
    Derived.new!(
      [id: id, from: [hosts: nil], schema: %{n: %{type: :number}}, function: function] ++ extra
    )
  end

  defp stored(id, elixir, extra \\ []) do
    Derived.new!(
      [id: id, from: [hosts: nil], schema: %{n: %{type: :number}}, elixir: elixir] ++ extra
    )
  end

  defp engine(sources, opts \\ []) do
    {:ok, engine} =
      Engine.new(
        sources,
        [sources: [:hosts], debounce: 0, functions: Functions.registry([Sources])] ++ opts
      )

    engine
  end

  # The source's answer at 0, with every fact a delivery carries.
  defp push(engine) do
    delivery = Delivery.new(@rows, served: [window: [0, 10], resolution: 5, capped: true])
    Engine.push(engine, %{hosts: delivery}, %{hosts: @hosts}, 0)
  end

  describe "what a function is called with" do
    @tag verifies: "derived-engine-run"
    test "a function of one argument is called with its inputs alone" do
      engine = engine(%{["a"] => host(:a, :rows_only)}) |> push() |> Engine.run(0)
      assert_received {:rows_only, %{"hosts" => @rows}}
      assert Delivery.rows(Engine.outputs(engine)[["a"]]) == [%{"n" => 1}]
    end

    @tag verifies: "derived-engine-run"
    test "a host function of two arguments receives exactly the documented context" do
      engine(%{["a"] => host(:a, :seen)}) |> push() |> Engine.run(0)

      assert_received {:context, %{"hosts" => @rows}, context}

      assert context == %{
               "inputs" => %{
                 "hosts" => %{
                   "schema" => %{
                     "t" => %{"type" => :number, "window" => true},
                     "host" => %{"type" => :category, "identity" => true},
                     "state" => %{
                       "type" => :category,
                       "values" => [
                         %{"value" => :ok, "name" => "OK", "color" => "#2e7d32"},
                         :down
                       ],
                       "status" => %{ok: :good}
                     },
                     "cpu" => %{"type" => :number, "bounds" => [0, 100], "continuity" => 60}
                   },
                   "window" => [0, 10],
                   "resolution" => 5,
                   "capped" => true
                 }
               }
             }
    end

    @tag verifies: "derived-engine-run"
    test "a stored function reads its context's values as it reads its rows'" do
      # `"category"` is no word, so the schema's `:category` is its string; `:ok` is one, so
      # the entry's value is the atom a row's `:ok` is, and `:down` (a rounding word) likewise.
      elixir = ~S"""
      fn %{hosts: rows}, c ->
        hosts = c["inputs"]["hosts"]
        state = hosts["schema"]["state"]
        [entry | _] = state["values"]

        checks = [
          state["type"] == "category",
          entry["value"] == :ok and entry["name"] == "OK",
          Enum.at(state["values"], 1) == :down,
          hosts["schema"]["cpu"]["continuity"] == 60,
          hosts["window"] == [0, 10] and hosts["resolution"] == 5 and hosts["capped"],
          c["vars"] == nil,
          Enum.count(rows) == 2
        ]

        [%{n: Enum.count(checks, & &1)}]
      end
      """

      engine = engine(%{["a"] => stored(:a, elixir)}) |> push() |> Engine.run(0)

      assert Engine.faults(engine) == %{}
      assert Delivery.rows(Engine.outputs(engine)[["a"]]) == [%{"n" => 7}]
    end

    @tag verifies: "derived-engine-run"
    test "a derived source's output is a delivery with no facts, under its output's schema" do
      a = stored(:a, "fn %{hosts: rows} -> [%{n: Enum.count(rows)}] end")
      b = Derived.new!(id: :b, from: [a: nil], schema: %{n: %{type: :number}}, function: :seen)

      engine = engine(%{["a"] => a, ["b"] => b}) |> push() |> Engine.run(0)

      assert_received {:context, %{"a" => [%{"n" => 2}]}, context}

      assert context == %{
               "inputs" => %{
                 "a" => %{
                   "schema" => %{"n" => %{"type" => :number}},
                   "window" => nil,
                   "resolution" => nil,
                   "capped" => false
                 }
               }
             }

      assert Engine.outputs(engine)[["a"]].schema == Schema.version(a.schema)
    end

    @tag verifies: "derived-engine-run"
    test "per identity, every entity's call is given the same context" do
      source =
        Derived.new!(
          id: :per,
          from: [hosts: nil],
          per: :identity,
          schema: %{host: %{type: :category, identity: true}, n: %{type: :number}},
          elixir:
            ~S|fn rows, c -> %{n: Enum.count(rows) + c["inputs"]["hosts"]["resolution"]} end|
        )

      engine = engine(%{["per"] => source}) |> push() |> Engine.run(0)

      assert Delivery.rows(Engine.outputs(engine)[["per"]]) == [
               %{"host" => "a", "n" => 6},
               %{"host" => "b", "n" => 6}
             ]
    end
  end

  describe "the engine's options and reading it" do
    @tag verifies: "derived-engine-run"
    test "schemas, sources read, runs and status by path; the default debounce is 250 ms" do
      a = stored(:a, "fn %{hosts: rows} -> [%{n: Enum.count(rows)}] end")
      {:ok, engine} = Engine.new(%{[:a] => a}, sources: [:hosts, :unread])

      assert Engine.schemas(engine) == %{["a"] => a.schema}
      assert Engine.sources_read(engine) == ["hosts"]
      assert Engine.status(engine) == %{["a"] => :loading}
      assert Engine.runs(engine) == %{["a"] => 0}

      engine = push(engine)
      assert Engine.due(engine) == 250
      assert Engine.run(engine, 249) == engine
      engine = Engine.run(engine, 250)
      assert Engine.status(engine) == %{["a"] => :live}
      assert Engine.runs(engine) == %{["a"] => 1}
    end

    @tag verifies: "derived-engine-defines"
    test "the bounds are tighten-only, and the registry default closed" do
      a = stored(:a, "fn %{hosts: rows} -> [%{n: Enum.count(rows)}] end")

      assert_raise ArgumentError, ~r/never raised/, fn ->
        Engine.new(%{[:a] => a}, sources: [:hosts], max_reductions: 100_000_001)
      end

      f = host(:f, :seen)

      assert {:error, [{["f"], [:function], {:undeclared, :function, "seen"}}]} =
               Engine.new(%{[:f] => f}, sources: [:hosts])
    end
  end

  describe "a derived source as a source (spec/02 §8.5)" do
    @tag verifies: "derived-output-kit"
    test "it describes its output schema, fetches its last good output, or loading before" do
      a = stored(:a, "fn %{hosts: rows} -> [%{n: Enum.count(rows)}] end")
      before = engine(%{["a"] => a})
      loading = Engine.source(before, ["a"])

      assert {:ok, description} = Source.describe(loading, nil)
      assert description.schema == a.schema
      assert description.supports == [] and description.params == %{}
      refute description.viewer_independent

      request = Macaw.Data.Source.Request.new!(now: ~U[2026-10-27 00:00:00Z])
      assert Source.fetch(loading, description, request) == {:error, :loading}
      assert Source.subscribe(loading, self()) == {:error, :no_push}

      engine = before |> push() |> Engine.run(0)
      source = Engine.source(engine, [:a], viewer_independent: true)
      assert %Output{viewer_independent: true} = source
      assert {:ok, delivery} = Source.fetch(source, description, request)
      assert Delivery.rows(delivery) == [%{"n" => 2}]
    end

    @tag verifies: "derived-output-kit"
    test "it passes the source conformance kit" do
      a = stored(:a, "fn %{hosts: rows} -> [%{n: Enum.count(rows)}] end")
      engine = engine(%{["a"] => a}) |> push() |> Engine.run(0)

      assert Conformance.check(Engine.source(engine, ["a"], viewer_independent: true),
               requests: [[]],
               budgets: [nil]
             ) == []
    end
  end
end
