defmodule Macaw.Data.ConformanceLoadTest do
  @moduledoc """
  Load changes no verdict of the conformance kit (spec/01 §9). Each verdict is taken idle,
  then with every scheduler saturated by busy processes, and the two must agree. The
  module is not async, so the saturation shares the runner with no other test, and
  nothing here asserts a time. Ported from visualize's `ConformanceLoadTest`.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Macaw.Data.Source.Conformance
  alias Macaw.Data.Test.{Reference, Saturate}

  # A source whose fetch does its work where the test says: in its own process, in an
  # agent it calls, forever, or never (blocked in `receive`).
  defmodule Worker do
    @moduledoc false
    @behaviour Macaw.Data.Source

    alias Macaw.Data.{Delivery, Schema}
    alias Macaw.Data.Source.Description

    defstruct [:work, :agent]

    def schema, do: Schema.new!(%{n: %{type: :number}})

    @impl true
    def describe(_source, _context), do: Description.new(schema: schema())

    @impl true
    def fetch(%__MODULE__{work: :agent, agent: agent}, _request),
      do: {:ok, delivery(Agent.get(agent, fn _ -> sum(1_000_000) end))}

    def fetch(%__MODULE__{work: :forever}, _request), do: {:ok, delivery(forever(0))}

    def fetch(%__MODULE__{work: :blocked}, _request),
      do: receive(do: (:never_sent -> {:ok, delivery(0)}))

    defp delivery(n),
      do: Delivery.new([%{n: n}], types: %{n: :number}, schema: Schema.version(schema()))

    defp sum(n), do: Enum.reduce(1..n, 0, &(&1 + &2))
    defp forever(n), do: forever(rem(n + 1, 7))
  end

  # The verdicts of `calls`, idle and then saturated; the busy processes stopped on exit too.
  defp idle_and_saturated(calls) do
    idle = calls.()
    busy = Saturate.start()
    on_exit(fn -> Saturate.stop(busy) end)
    saturated = calls.()
    :ok = Saturate.stop(busy)
    {idle, saturated}
  end

  @tag verifies: "conformance-load"
  test "a correct source passes every check at the defaults, idle and saturated" do
    run = fn ->
      Conformance.check(%Reference{}, requests: [[], [window: [4, 12]], [window: [-5, 8]]])
    end

    assert idle_and_saturated(run) == {[], []}
  end

  @tag verifies: "conformance-load"
  test "a budget decides by the count: one reduction fails each call, a generous one passes" do
    run = fn ->
      {Conformance.check(:describe, %Reference{}, reductions: 1),
       Conformance.check(:deliveries, %Reference{}, reductions: 10_000_000, budgets: [nil])}
    end

    # The count is the verdict; how far past the budget a reading caught it is not.
    {idle, saturated} = idle_and_saturated(run)

    for findings <- [idle, saturated] do
      assert {[{:describe, {:reductions, :describe, spent, 1}}], []} = findings
      assert spent > 1
    end
  end

  @tag verifies: "conformance-load"
  test "a fetch that never stops is stopped at its budget, not reported hung" do
    source = %Worker{work: :forever}
    run = fn -> Conformance.check(:deliveries, source, reductions: 1_000_000, budgets: [nil]) end

    {idle, saturated} = idle_and_saturated(run)

    for findings <- [idle, saturated] do
      assert [{:deliveries, {:reductions, {:fetch, {[], nil}}, spent, 1_000_000}}] = findings
      assert spent > 1_000_000
    end
  end

  @tag verifies: "conformance-load"
  test "a fetch blocked in receive is hung at the liveness bound, idle and saturated" do
    source = %Worker{work: :blocked}
    run = fn -> Conformance.check(:deliveries, source, timeout: 50, budgets: [nil]) end
    finding = [{:deliveries, {:hung, {:fetch, {[], nil}}, 50}}]
    assert idle_and_saturated(run) == {finding, finding}

    assert Conformance.format(hd(finding)) ==
             "deliveries: fetch [] did not answer within 50 ms: it is blocked (hung), not slow"
  end

  @tag verifies: "conformance-load"
  test "work done in another process counts only when the kit is given that process" do
    agent = start_supervised!({Agent, fn -> nil end})
    source = %Worker{work: :agent, agent: agent}
    opts = [reductions: 100_000, budgets: [nil]]

    run = fn ->
      {Conformance.check(:deliveries, source, opts),
       Conformance.check(:deliveries, source, [processes: [agent]] ++ opts)}
    end

    {idle, saturated} = idle_and_saturated(run)

    for {alone, with_agent} <- [idle, saturated] do
      assert alone == []
      assert [{:deliveries, {:reductions, {:fetch, {[], nil}}, spent, 100_000}}] = with_agent
      assert spent > 100_000
    end
  end
end
