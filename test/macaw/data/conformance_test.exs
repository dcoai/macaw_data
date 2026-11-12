defmodule Macaw.Data.ConformanceTest do
  @moduledoc """
  The source conformance kit (spec/01 §9): run on the test sources through `use`, and held
  to its negatives by fake sources whose every flaw must fail the check it targets. Ported
  from visualize's `Visualize.Feed.ConformanceTest`.
  """
  # A raising source is a finding, logged at no error level (macaw_data#79, BoundedTest).
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Macaw.Data.Source.Conformance
  alias Macaw.Data.Test.Reference
  alias Macaw.Data.Test.Sources.{Asked, Broken, Fleet, Places}

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
      [params: %{"scale" => 3}],
      [params: %{"floor" => 5}]
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

  # A source whose rows do not pack under its schema: a number field holding a string.
  defmodule Unpacked do
    @moduledoc false
    @behaviour Macaw.Data.Source
    alias Macaw.Data.{Delivery, Schema}
    defstruct []

    @schema Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number}})

    @impl true
    def describe(_source, _context),
      do: {:ok, %Macaw.Data.Source.Description{schema: @schema}}

    @impl true
    def fetch(_source, _request),
      do: Delivery.new([%{t: 1, v: 1}, %{t: 2, v: "x"}], schema: Schema.version(@schema))
  end

  @tag verifies: "conformance-monitor"
  test "the monitor check: honest sources pass; a snapshot ahead, rows that do not pack and a moving answer fail" do
    assert Conformance.check(:monitor, Broken.new(), @opts) == []

    findings =
      Conformance.check(:monitor, Broken.new(:snapshot_ahead), @opts) ++
        Conformance.check(:monitor, %Unpacked{}, @opts) ++
        Conformance.check(:monitor, Broken.new(:clock), @opts)

    assert Enum.any?(findings, &match?({:monitor, {:monitor_push, {[], nil}, :not_held}}, &1))

    assert Enum.any?(
             findings,
             &match?({:monitor, {:monitor_status, _, {:down, {:table, _}}}}, &1)
           )

    assert Enum.any?(findings, &match?({:monitor, {:monitor_rows, _, _, _}}, &1))
    for finding <- findings, do: assert(is_binary(Conformance.format(finding)))
  end

  # Each flaw, the check it targets and the finding that names it.
  @expected [
    unstable_version: {:describe, :unstable},
    wrong_version: {:describe, :version},
    hand_built: {:describe, :description_invalid},
    stale_version: {:deliveries, :version},
    served_window_lie: {:deliveries, :outside_served},
    missing_row: {:deliveries, :missing},
    capped_lie: {:deliveries, :capped},
    stale_not_boolean: {:deliveries, :malformed},
    uncapped_lie: {:deliveries, :uncapped},
    reduction_unrecorded: {:deliveries, :unrecorded_reduction},
    runtime_claim: {:deliveries, :reduced_by},
    reducer_claim: {:deliveries, :reduced_with},
    snapshot_ahead: {:monitor, :monitor_push},
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
    nil_unread: {:deliveries, :raised},
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

    @tag verifies: "conformance-nil-default"
    test "a nil default is asked given nil, whatever the requests name" do
      for call <- [[], [[params: %{"floor" => 1}]]] do
        opts = [budgets: [nil]] ++ if(call == [], do: [], else: [requests: call])
        assert [] == Conformance.check(:deliveries, Asked.new(self()), opts)
        assert_received {:asked, %{"floor" => nil}}
      end

      findings =
        Conformance.check(:deliveries, Broken.new(:nil_unread),
          requests: [[params: %{"floor" => 1}]],
          budgets: [nil]
        )

      assert [{:deliveries, {:raised, {:fetch, {ask, nil}}, _reason}} = finding] = findings
      assert ask == [params: %{"floor" => nil}]
      assert is_binary(Conformance.format(finding))
    end

    @tag verifies: "conformance-nil-default"
    test "a source with no nil default is asked nothing more" do
      source = Asked.new(self(), %{"scale" => %{type: :number, default: 1}})
      assert [] == Conformance.check(:deliveries, source, requests: [[], []], budgets: [nil])
      assert_received {:asked, _}
      assert_received {:asked, _}
      refute_received {:asked, _}
    end

    @tag verifies: "conformance-stale"
    test "a stale answer is honest; a stale that is not a boolean is malformed" do
      assert Conformance.check(Broken.new(:stale), @opts) == []

      findings = Conformance.check(:deliveries, Broken.new(:stale_not_boolean), @opts)
      assert {:deliveries, {:malformed, _probe, :stale, "yes"} = reason} = hd(findings)
      assert Enum.all?(findings, &match?({:deliveries, {:malformed, _, :stale, "yes"}}, &1))
      assert Conformance.format({:deliveries, reason}) =~ "stale"
    end

    @tag verifies: "conformance-stale"
    test "a down source answering a stale delivery is answered_down, never stale rows" do
      findings = Conformance.check(:errors, Broken.new(), down: Broken.new(:stale))

      assert Enum.any?(
               findings,
               &match?(
                 {:errors, {:answered_down, {:fetch, _}, {:ok, %{served: %{stale: true}}}}},
                 &1
               )
             )
    end

    @tag verifies: "conformance-flaws"
    test "every flaw is expected to fail a check, and every check is failed by a flaw" do
      assert Enum.sort(Keyword.keys(@expected)) ==
               Enum.sort(Broken.flaws() -- [:down, :identified, :stale])

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

      # The kit's own options are findings, never a raise, so its test fails with them.
      assert Conformance.check(:deliveries, Broken.new(), requests: [[budget: 5]]) ==
               [deliveries: {:request, [budget: 5]}]

      assert Conformance.check(:deliveries, Broken.new(), windows: [], viewers: [%{}]) ==
               [deliveries: {:option, :windows}, deliveries: {:viewers, :two}]

      assert Conformance.format({:deliveries, {:request, [budget: 5]}}) =~ "keyword list of"
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
      assert [everything: {:unknown_check, checks}] =
               Conformance.check(:everything, Broken.new(), [])

      assert checks == Conformance.checks()

      assert Conformance.format({:everything, {:unknown_check, checks}}) =~
               "not a conformance check"
    end
  end
end
