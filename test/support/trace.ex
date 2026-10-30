defmodule Macaw.Data.Test.Trace do
  @moduledoc false
  # Which functions a piece of code calls, for the tests that state work as calls made
  # (spec/01 §1.1.2, §1.1.3): a digest computed once, a lookup that never hashes.

  @doc """
  Every call `fun` makes, in this process, to a function `pattern` matches
  (`{module, name, arity}`, `:_` for any), in order, as `{module, name}`. Traced to a
  collector, since a process is not its own tracer.
  """
  def calls(pattern, fun) do
    collector = spawn_link(fn -> collect([]) end)
    :erlang.trace_pattern(pattern, true, [:global])
    :erlang.trace(self(), true, [:call, {:tracer, collector}])
    fun.()
    :erlang.trace(self(), false, [:call])
    :erlang.trace_pattern(pattern, false, [:global])
    ref = :erlang.trace_delivered(self())
    receive do: ({:trace_delivered, _, ^ref} -> :ok)
    send(collector, {:done, self()})
    receive do: ({:calls, calls} -> calls)
  end

  defp collect(calls) do
    receive do
      {:trace, _pid, :call, {module, name, _args}} -> collect([{module, name} | calls])
      {:done, from} -> send(from, {:calls, Enum.reverse(calls)})
    end
  end
end
