defmodule Macaw.Data.Derived.EngineLoadTest do
  # Load changes no fault's kind (spec/02 §6.4, §8.3; macaw_data#33, #67): the six kinds of
  # EngineTest, judged idle and then with every scheduler saturated, at EngineTest's bounds.
  # Under load a compile or a capped runaway outlasts its time without being blocked, and a
  # runner that read the clock alone called it hung. The `timeout:` is generous, as §6.4
  # asks: a first compile waits on the code server, which saturation keeps waiting. Not
  # async, so the saturation shares the runner with no other test; nothing here asserts a
  # time.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Macaw.Data.{Delivery, Derived, Schema}
  alias Macaw.Data.Derived.{Engine, Functions}
  alias Macaw.Data.Test.Saturate

  # A host's function that never answers: blocked in `receive`, it spends no reductions.
  defmodule Blocked do
    use Macaw.Data.Derived.Functions
    defsource(blocked(_inputs), do: receive(do: (:never_sent -> [])))
  end

  @hosts Schema.new!(%{
           t: %{type: :number, window: true},
           host: %{type: :category, identity: true},
           cpu: %{type: :number}
         })

  @kinds %{
    reductions:
      "fn _ -> Enum.reduce(1..100_000_000_000_000, 0, fn x, acc -> rem(acc + x, 7) end) end",
    hung: :blocked,
    memory: "fn _ -> Enum.to_list(1..100_000_000_000) end",
    raised: "fn _ -> Map.fetch!(%{}, :n) end",
    nonconforming: "fn _ -> [%{n: :none}] end",
    restricted: "fn %{hosts: rows} -> [%{n: Enum.count(rows, & &1.load)}] end"
  }

  # The source `a` faulting as `elixir` makes it, with EngineTest's bounds.
  defp fault(elixir) do
    a =
      if elixir == :blocked,
        do: Derived.new!(id: :a, from: [hosts: nil], schema: schema(), function: :blocked),
        else: Derived.new!(id: :a, from: [hosts: nil], schema: schema(), elixir: elixir)

    {:ok, engine} =
      Engine.new(%{["a"] => a},
        sources: [:hosts],
        debounce: 0,
        functions: Functions.registry([Blocked]),
        max_reductions: 1_000_000,
        timeout: 1_000,
        max_heap: 200_000
      )

    rows = for i <- 1..2, do: %{t: i, host: "h#{i}", cpu: i * 10}

    engine
    |> Engine.push(%{hosts: Delivery.new(rows)}, %{hosts: @hosts}, 0)
    |> Engine.run(0)
    |> Engine.faults()
    |> Map.fetch!(["a"])
  end

  defp schema, do: %{n: %{type: :number}}

  # Each kind's fault, a few times over.
  defp faults, do: for({kind, elixir} <- @kinds, _ <- 1..2, do: {kind, fault(elixir).kind})

  # EngineTest's chain whose first run answers (spec/02 §8.3): on a loaded host its compile
  # works past its time and can then wait on a server slow to answer, which was once judged
  # hung (macaw_data#67, #57).
  defp first_run do
    good = "fn %{hosts: rows} -> [%{n: 10 / (Enum.count(rows) - 3)}] end"
    a = Derived.new!(id: :a, from: [hosts: nil], schema: schema(), elixir: good)

    {:ok, engine} =
      Engine.new(%{["a"] => a}, sources: [:hosts], debounce: 0, timeout: 1_000)

    rows = for i <- 1..2, do: %{t: i, host: "h#{i}", cpu: i * 10}

    engine
    |> Engine.push(%{hosts: Delivery.new(rows)}, %{hosts: @hosts}, 0)
    |> Engine.run(0)
    |> Engine.faults()
  end

  @tag verifies: "derived-load"
  test "a first run that answers has no fault, idle and with every scheduler saturated" do
    idle = for _ <- 1..20, do: first_run()
    busy = Saturate.start()
    on_exit(fn -> Saturate.stop(busy) end)
    saturated = for _ <- 1..20, do: first_run()
    :ok = Saturate.stop(busy)

    assert Enum.uniq(idle) == [%{}]
    assert Enum.uniq(saturated) == [%{}]
  end

  @tag verifies: "derived-load"
  test "the six fault kinds are the same idle and with every scheduler saturated" do
    idle = faults()
    busy = Saturate.start()
    on_exit(fn -> Saturate.stop(busy) end)
    saturated = faults()
    :ok = Saturate.stop(busy)

    expected = for {kind, _} <- @kinds, _ <- 1..2, do: {kind, kind}
    assert idle == expected
    assert saturated == expected
  end
end
