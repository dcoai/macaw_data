defmodule Macaw.Data.Test.Trace do
  @moduledoc false
  # Which functions a piece of code calls, for the tests that state work as calls made
  # (spec/01 §1.1.2, §1.1.3): a digest computed once, a lookup that never hashes.
  #
  # Each call traces in a trace session of its own (OTP 27+). Legacy tracing is node-wide:
  # a pattern one async test turned on was collected by another's traced process, and one
  # test turning a pattern off ended another's tracing of it mid-run (#37). A session's
  # patterns and process flags are its own, so nothing is shared between tests and there
  # is nothing to lock.

  @doc """
  Every call `fun` makes, in this process, to a function `pattern` matches
  (`{module, name, arity}`, `:_` for any), in order, as `{module, name}`. Traced to a
  collector, since a process is not its own tracer.
  """
  def calls({_, _, _} = pattern, fun) do
    me = self()
    collector = spawn_link(fn -> collect(me, []) end)
    session = :trace.session_create(__MODULE__, collector, [])
    :trace.function(session, pattern, true, [:global])
    :trace.process(session, me, true, [:call])
    fun.()
    :trace.process(session, me, false, [:call])
    ref = :erlang.trace_delivered(me)
    receive do: ({:trace_delivered, ^me, ^ref} -> :ok)
    true = :trace.session_destroy(session)
    send(collector, :done)

    receive do
      {:calls, ^collector, calls} ->
        for {module, name, arity} <- calls,
            matches?(pattern, {module, name, arity}),
            do: {module, name}
    end
  end

  # The session traces only `pattern`; the filter states it, so a call this helper did not
  # ask for can never be counted.
  defp matches?({module, name, arity}, {m, n, a}),
    do: part?(module, m) and part?(name, n) and part?(arity, a)

  defp part?(:_, _), do: true
  defp part?(want, got), do: want == got

  defp collect(to, calls) do
    receive do
      {:trace, _pid, :call, {module, name, args}} ->
        collect(to, [{module, name, length(args)} | calls])

      :done ->
        send(to, {:calls, self(), Enum.reverse(calls)})
    end
  end
end
