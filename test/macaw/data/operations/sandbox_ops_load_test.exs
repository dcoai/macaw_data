defmodule Macaw.Data.Operations.SandboxOpsLoadTest do
  # The load suite grows with the sandbox's reach (spec/04 §6.2): every operation of
  # macaw_data's package, called from a stored function over five thousand rows, gives the
  # same verdict idle and with every scheduler saturated, within the runner's default
  # bounds. Not async, so the saturation shares the runner with no other test; nothing here
  # asserts a time.
  use ExUnit.Case, async: false

  alias Macaw.Data.Derived.Sandbox
  alias Macaw.Data.Operations.{Aggregates, Transforms}
  alias Macaw.Data.Test.Saturate

  @rows for i <- 0..4_999,
            do: %{
              t: i,
              v: rem(i * 7919, 1000) / 10,
              k: "k#{rem(i, 7)}",
              a: rem(i, 13),
              b: rem(i, 5)
            }

  # One call of each table operation, every stack offset among them, and each statistic.
  @transforms [
    {"filter", ~S|%{field: "v", test: :gt, value: 50}|},
    {"take", ~S|%{n: 1000}|},
    {"window", ~S|%{field: "t", from: [3600, :second]}|},
    {"lttb", ~S|%{fields: ["t", "v"], n: 1000}|},
    {"m4", ~S|%{fields: ["t", "v"], width: 600}|},
    {"sort", ~S|%{field: "v", order: :descending}|},
    {"fold", ~S|%{fields: ["a", "b"]}|},
    {"stack", ~S|%{fields: ["a", "b"]}|},
    {"stack", ~S|%{fields: ["a", "b"], offset: :expand}|},
    {"stack", ~S|%{fields: ["a", "b"], offset: :silhouette}|},
    {"stack", ~S|%{fields: ["a", "b"], offset: :wiggle}|},
    {"stack", ~S|%{fields: ["a", "b"], offset: :diverging}|},
    {"bin", ~S|%{field: "v", fn: "mean"}|},
    {"aggregate", ~S|%{field: "v", fn: "median", by: "k"}|},
    {"sum", ~S|%{field: "v", by: "k"}|},
    {"spectrum", ~S|%{field: "v", time: "t"}|}
  ]

  defp idle_and_saturated(calls) do
    idle = calls.()
    busy = Saturate.start()
    on_exit(fn -> Saturate.stop(busy) end)
    saturated = calls.()
    :ok = Saturate.stop(busy)
    {idle, saturated}
  end

  @tag verifies: "operations-sandbox-load"
  test "every table operation of the package gives one verdict idle and saturated, within the default bounds" do
    assert @transforms |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() ==
             Transforms.all() |> Enum.map(& &1.name()) |> Enum.sort()

    compiled =
      for {name, options} <- @transforms do
        source =
          ~s'fn rows -> rows |> Macaw.Data.Ops.transform("#{name}", #{options}) |> Enum.count() end'

        {:ok, compiled} = Sandbox.compile(source)
        compiled
      end

    calls = fn -> Enum.map(compiled, &Sandbox.run(&1, [@rows])) end
    {idle, saturated} = idle_and_saturated(calls)

    assert Enum.all?(idle, &match?({:ok, count} when is_integer(count) and count > 0, &1)),
           inspect(idle)

    assert saturated == idle
  end

  @tag verifies: "operations-sandbox-load"
  test "every statistic of the package gives one verdict idle and saturated, within the default bounds" do
    compiled =
      for module <- Aggregates.all() do
        options = if module.name() == "quantile", do: "%{p: 0.95}", else: "%{}"

        source =
          ~s'fn rows -> rows |> Enum.map(& &1.v) |> Macaw.Data.Ops.aggregate("#{module.name()}", #{options}) end'

        {:ok, compiled} = Sandbox.compile(source)
        compiled
      end

    calls = fn -> Enum.map(compiled, &Sandbox.run(&1, [@rows])) end
    {idle, saturated} = idle_and_saturated(calls)

    assert Enum.all?(idle, &match?({:ok, _value}, &1)), inspect(idle)
    assert saturated == idle
  end
end
