defmodule Macaw.Data.Test.TraceTest do
  # The call-tracing helper the work-as-calls tests rely on (#37): concurrent traces, on the
  # same function or on others, each see every call of their own and nothing else.
  use ExUnit.Case, async: true

  import Macaw.Data.Test.Trace

  defmodule Callee do
    @moduledoc false
    def a(x), do: x + 1
    def b(x), do: x * 2
  end

  # `n` calls to each of a/1 and b/1, after every task has started, so the traces overlap.
  defp both(n, go) do
    receive do: (^go -> :ok)
    for i <- 1..n, do: {Callee.a(i), Callee.b(i)}
  end

  # Runs each `{pattern, n}` in its own task, released together.
  defp concurrently(traces) do
    go = make_ref()

    tasks =
      for {pattern, n} <- traces do
        Task.async(fn -> calls(pattern, fn -> both(n, go) end) end)
      end

    for %Task{pid: pid} <- tasks, do: send(pid, go)
    Task.await_many(tasks, 30_000)
  end

  test "a trace sees each call the function makes to the pattern, in order" do
    assert calls({Callee, :_, :_}, fn -> Callee.b(Callee.a(1)) end) == [
             {Callee, :a},
             {Callee, :b}
           ]

    assert calls({Callee, :a, 1}, fn -> Callee.b(Callee.a(1)) end) == [{Callee, :a}]
    assert calls({Callee, :a, 2}, fn -> Callee.a(1) end) == []
  end

  test "concurrent traces of one function each see every call: one ending does not end another" do
    runs = [100, 20_000, 10, 5_000, 1]
    seen = concurrently(for n <- runs, do: {{Callee, :a, 1}, n})
    assert seen == for(n <- runs, do: List.duplicate({Callee, :a}, n))
  end

  test "a trace sees no call another concurrent trace's pattern matches" do
    [as, bs, all] =
      concurrently([
        {{Callee, :a, 1}, 3_000},
        {{Callee, :b, 1}, 3_000},
        {{Callee, :_, :_}, 3_000}
      ])

    assert as == List.duplicate({Callee, :a}, 3_000)
    assert bs == List.duplicate({Callee, :b}, 3_000)
    assert all == List.flatten(List.duplicate([{Callee, :a}, {Callee, :b}], 3_000))
  end

  test "a call outside the traced process is not seen" do
    assert calls({Callee, :a, 1}, fn -> Task.await(Task.async(fn -> Callee.a(1) end)) end) == []
  end
end
