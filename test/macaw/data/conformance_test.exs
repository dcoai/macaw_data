defmodule Macaw.Data.ConformanceTest do
  @moduledoc """
  The source conformance kit (spec/01 §9): run on the test sources through `use`, and held
  to its negatives by fake sources whose every flaw must fail the check it targets. Ported
  from visualize's `Visualize.Feed.ConformanceTest`.
  """
  # A raising source's process logs its crash; the kit reports it as a finding.
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Macaw.Data.Source.Conformance
  alias Macaw.Data.Test.Reference
  alias Macaw.Data.Test.Sources.{Broken, Fleet, Places}

  doctest Conformance

  # -- the sources through `use` -------------------------------------------------------

  use Conformance,
    name: "Reference",
    source: %Reference{},
    requests: [
      [],
      [window: [4, 12]],
      [window: [-5, 8]],
      [window: [nil, 6]],
      [params: %{"scale" => 3}]
    ]

  use Conformance,
    name: "Broken, honest",
    source: Broken.new(),
    requests: [[], [window: [2, 10]], [window: [nil, 6]], [window: [12, nil]]],
    push: &Broken.emit/1,
    down: Broken.new(:down),
    quiet: 30

  use Conformance,
    name: "Fleet",
    source: Fleet.new(),
    requests: [
      [],
      [window: [2, 8]],
      [region: %{x: [2, 6]}],
      [window: [1, 9], region: %{y: [0, 4]}, latest: true],
      [latest: true]
    ]

  use Conformance,
    name: "Places",
    source: Places.new(),
    requests: [
      [],
      [box: %{west: -10, south: 35, east: 30, north: 60}],
      [box: %{west: 175, south: -20, east: -175, north: -15}]
    ]

  # -- the negatives -----------------------------------------------------------------------

  @opts [
    requests: [[], [window: [2, 10]], [window: [nil, 6]], [window: [12, nil]], [window: [-3, 8]]],
    budgets: [nil, 5],
    push: &Broken.emit/1,
    quiet: 30
  ]

  # Each flaw, the check it targets and the finding that names it.
  @expected [
    unstable_version: {:describe, :unstable},
    wrong_version: {:describe, :version},
    hand_built: {:describe, :description_invalid},
    stale_version: {:deliveries, :version},
    served_window_lie: {:deliveries, :outside_served},
    missing_row: {:deliveries, :missing},
    capped_lie: {:deliveries, :capped},
    uncapped_lie: {:deliveries, :uncapped},
    reduction_unrecorded: {:deliveries, :unrecorded_reduction},
    runtime_claim: {:deliveries, :reduced_by},
    resolution_lie: {:deliveries, :resolution},
    window_overrun: {:supports, :window_served},
    budget_overrun: {:supports, :over_budget},
    push_undeclared: {:supports, :push_undeclared},
    as_of_ignored: {:supports, :as_of_moved},
    as_of_origin_lie: {:supports, :as_of_origin},
    no_handshake: {:push, :handshake},
    data_before_schema: {:push, :before_schema},
    misnumbered: {:push, :numbering},
    raises: {:errors, :raised},
    ticks_as_time: {:deliveries, :window_value},
    no_window_field: {:describe, :no_window_field},
    stamp_as_number: {:deliveries, :not_an_instant},
    misspelled_unit: {:describe, :measure},
    no_identity: {:deliveries, :no_identity},
    keeps_pushing: {:unsubscribe, :pushed_after_unsubscribe},
    clock: {:determinism, :answer_moved},
    viewer_dependent: {:viewers, :viewer_dependent}
  ]

  @fleet [
    requests: [[region: %{x: [2, 6]}], [window: [1, 9], latest: true]],
    budgets: [nil]
  ]

  describe "the kit's negatives" do
    @tag verifies: "conformance-honest"
    test "an honest source passes every check" do
      assert Conformance.check(Broken.new(), [{:down, Broken.new(:down)} | @opts]) == []
      assert Conformance.check(Broken.new(:identified), @opts) == []
    end

    @tag verifies: "conformance-flaws"
    test "every flaw is expected to fail a check, and every check is failed by a flaw" do
      assert Enum.sort(Keyword.keys(@expected)) ==
               Enum.sort(Broken.flaws() -- [:down, :identified])

      assert @expected |> Keyword.values() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() ==
               Enum.sort(Conformance.checks())
    end

    for {flaw, {check, reason}} <- @expected do
      @tag verifies: "conformance-flaws"
      test "#{flaw} fails #{check} with #{reason}" do
        findings = Conformance.check(unquote(check), Broken.new(unquote(flaw)), @opts)

        assert Enum.any?(findings, &(elem(elem(&1, 1), 0) == unquote(reason))),
               "#{unquote(flaw)}: expected a #{unquote(reason)} finding, got #{inspect(findings)}"

        for finding <- findings, do: assert(is_binary(Conformance.format(finding)))
      end
    end

    @tag verifies: "conformance-flaws"
    test "a source breaking the region, latest or box is found by the supports check" do
      for {flaw, reason} <- [
            region_overrun: :region_row,
            latest_twice: :latest_twice,
            stale_latest: :not_latest
          ] do
        findings = Conformance.check(:supports, Fleet.new(flaw), @fleet)

        assert Enum.any?(findings, &(elem(elem(&1, 1), 0) == reason)),
               "#{flaw}: #{inspect(findings)}"
      end

      box = [requests: [[box: %{west: -10, south: 35, east: 30, north: 60}]], budgets: [nil]]

      assert [supports: {:box_row, _probe, {-74.0, 40.7}}] =
               Conformance.check(:supports, Places.new(:box_overrun), box)
    end

    @tag verifies: "conformance-flaws"
    test "a row without its declared identity is a finding naming the field" do
      findings = Conformance.check(:deliveries, Broken.new(:no_identity), @opts)

      assert {:deliveries, {:no_identity, _probe, "unit"} = reason} =
               Enum.find(findings, &match?({_, {:no_identity, _, _}}, &1))

      assert Conformance.format({:deliveries, reason}) =~ ~s(no value for "unit")
    end

    @tag verifies: "conformance-flaws"
    test "a measure the vocabulary refuses is its own finding, naming the field" do
      assert [{:describe, {:measure, "v", {:unit, "mss", {:unknown_atom, "mss"}}}} = finding] =
               Conformance.check(:describe, Broken.new(:misspelled_unit), @opts)

      assert Conformance.format(finding) =~ ~s(field "v")
    end

    @tag verifies: "conformance-errors"
    test "a down source that answers is a finding; a raising one is a finding, not a crash" do
      findings = Conformance.check(:errors, Broken.new(), down: Broken.new())

      assert Enum.any?(findings, &match?({:errors, {:answered_down, :describe, {:ok, _}}}, &1))
      assert Enum.any?(findings, &match?({:errors, {:answered_down, {:fetch, _}, _}}, &1))
      assert Enum.any?(findings, &match?({:errors, {:answered_down, :subscribe, _}}, &1))

      assert [{:errors, {:raised, {:fetch, {:unreadable, request}}, {%ArgumentError{}, _}}} | _] =
               Conformance.check(:errors, Broken.new(:raises), [])

      assert request.window == [:not, :a_time]
    end

    @tag verifies: "conformance-probes"
    test "a capability the options cannot probe is a finding" do
      findings = Conformance.check(:supports, Broken.new(), requests: [[]], budgets: [nil])

      assert {:supports, {:no_probe, :window}} in findings
      assert {:supports, {:no_probe, :budget}} in findings
      assert {:supports, {:no_probe, :push}} in findings
      assert Conformance.check(:push, Broken.new(), []) == [push: {:no_probe, :push}]

      assert {:supports, {:no_probe, :region}} in Conformance.check(:supports, Fleet.new(), [])
      assert {:supports, {:no_probe, :box}} in Conformance.check(:supports, Places.new(), [])
    end

    @tag verifies: "conformance-probes"
    test "a request the schema cannot answer is the run's to fix, named as a probe" do
      assert [deliveries: {:probe, [box: _], _faults}] =
               Conformance.check(:deliveries, Broken.new(),
                 requests: [[box: %{west: 0, south: 0, east: 1, north: 1}]],
                 budgets: [nil]
               )

      assert_raise ArgumentError, ~r/keyword list of/, fn ->
        Conformance.check(:deliveries, Broken.new(), requests: [[budget: 5]])
      end
    end

    @tag verifies: "conformance-honest"
    test "a source that cannot describe stops each check with the reason" do
      for check <- Conformance.checks() -- [:errors] do
        assert Conformance.check(check, Broken.new(:down), @opts) == [
                 {check, {:describe_error, :down}}
               ]
      end
    end

    @tag verifies: "conformance-honest"
    test "each finding reads as a line naming its check" do
      assert Conformance.format({:deliveries, {:capped, {[window: [2, 10]], nil}, [2, 10]}}) ==
               "deliveries: fetch [window: [2, 10]]: capped is true, but the served window [2, 10] reaches the asked from"
    end
  end

  describe "the macro" do
    @tag verifies: "conformance-use"
    test "writes one test per check into the describe block" do
      names = for {name, 1} <- __MODULE__.__info__(:functions), do: Atom.to_string(name)

      for block <- ["Reference", "Fleet", "Places"], check <- Conformance.checks() do
        assert Enum.any?(names, &String.starts_with?(&1, "test #{block} #{check}: ")),
               "no #{check} test in #{block}"
      end
    end

    @tag verifies: "conformance-use"
    test "refuses a missing source and an unknown option at compile time" do
      assert_raise ArgumentError, ~r/needs source:/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Macaw.Data.ConformanceTest.NoSource do
              use ExUnit.Case
              use Macaw.Data.Source.Conformance, requests: [[]]
            end
          end
        )
      end

      assert_raise ArgumentError, ~r/unknown keys \[:windows\]/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Macaw.Data.ConformanceTest.Unknown do
              use ExUnit.Case
              use Macaw.Data.Source.Conformance, source: nil, windows: [[0, 1]]
            end
          end
        )
      end
    end

    @tag verifies: "conformance-use"
    test "an unknown check is refused" do
      assert_raise ArgumentError, ~r/not a conformance check/, fn ->
        Conformance.check(:everything, Broken.new(), [])
      end
    end
  end
end
