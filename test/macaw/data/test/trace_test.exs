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
  end

  test "a pattern that matches no function fails, rather than seeing no calls" do
    assert_raise ArgumentError, ~r/no function matches/, fn ->
      calls({Callee, :a, 2}, fn -> Callee.a(1) end)
    end

    assert_raise ArgumentError, ~r/no function matches/, fn ->
      calls({Callee, :renamed, :_}, fn -> Callee.a(1) end)
    end
  end

  # The module the next test writes and loads: absent when this file is compiled. Its call
  # is checked as a remote call to a literal module once every test file is required, and
  # tests start while the rest are still being required, so without this the check would
  # warn exactly when it ran before the test did. Under --warnings-as-errors that aborted a
  # suite whose every test passed, at random with the seed and the load (macaw_data#72).
  @compile {:no_warn_undefined, :macaw_data_trace_test_lazy}

  # A module on the code path but not loaded until its first call, as modules are in the
  # test environment: a pattern set before it loads would match nothing.
  @tag :tmp_dir
  test "a module not loaded yet is traced from its first call", %{tmp_dir: dir} do
    module = :macaw_data_trace_test_lazy

    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [f: 0]},
      {:function, 1, :f, 0, [{:clause, 1, [], [], [{:atom, 1, :ok}]}]}
    ]

    {:ok, ^module, beam} = :compile.forms(forms)
    File.write!(Path.join(dir, "#{module}.beam"), beam)
    true = :code.add_patha(String.to_charlist(dir))
    on_exit(fn -> :code.del_path(String.to_charlist(dir)) end)
    refute :code.is_loaded(module)

    assert calls({module, :f, 0}, fn -> module.f() end) == [{module, :f}]
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
