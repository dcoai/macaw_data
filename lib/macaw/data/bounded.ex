defmodule Macaw.Data.Bounded do
  @moduledoc """
  One call in a monitored process of its own, its cost counted rather than timed: the
  conformance kit's runner (spec/01 §9), ported from visualize's `Visualize.Bounded`.

  The cost is the reductions the call's process spends, collections included, which a
  loaded host does not change. A call that answers is judged by its own count, read as
  its function returns; a call still running is read every 10 ms and killed at the first
  reading over the cap. Liveness is a separate wall-clock bound, `timeout`, for a call
  blocked in `receive`, which spends no reductions and so is never stopped by a cap: a
  capped call is hung only once it has been blocked for `timeout` ms on end, waiting in
  `receive` with its reductions unchanged at every reading since. One still working is left
  to its cap, and one that worked and then waits on a server slow to answer on a loaded
  host has the whole bound again from its last work, so a slow call is never hung
  (macaw_data#33, #67). A call with no cap has only the clock, and past it is hung
  whatever it is doing.

  Nothing is rescued: a raise or an exit is read from the process's `:DOWN`. The process
  is spawned through `:proc_lib`, so a raise logs nothing at error level: the runtime would
  report it through the logger's proxy, after the caller had its answer, but proc_lib ends
  the process with the exception as its exit reason, the same `{exception, stack}`. Its own
  crash report is a SASL report, logged before the process exits (macaw_data#79).

      iex> {:ok, 3, _spent} = Macaw.Data.Bounded.run(fn -> 1 + 2 end, timeout: 1_000)
      iex> Macaw.Data.Bounded.run(fn -> receive(do: (:never -> :ok)) end, timeout: 10)
      :hung
  """

  # Milliseconds between two readings of a running call's reductions.
  @poll 10

  @typedoc "How a bounded call ended."
  @type outcome ::
          {:ok, term(), non_neg_integer()}
          | {:reductions, non_neg_integer()}
          | :hung
          | {:down, term()}

  @doc """
  `thunk` called in a process spawned through `:proc_lib` with `spawn:` options and
  `:monitor`, the caller in its `$callers`: `{:ok, value, reductions}`; `{:reductions,
  spent}` when it spent more than `reductions:` (`nil`, no cap); `:hung` when it had not
  answered within `timeout:` ms blocked in `receive` (with no cap, whatever it is doing);
  `{:down, reason}` when it exited first, a heap limit's kill as `:killed`. A process the
  caller kills is waited for, so nothing it does outlives the call.
  """
  @spec run((-> term()), keyword()) :: outcome()
  def run(thunk, opts) when is_function(thunk, 0) do
    cap = Keyword.get(opts, :reductions)
    timeout = Keyword.fetch!(opts, :timeout)
    parent = self()
    tag = make_ref()
    callers = [parent | Process.get(:"$callers", [])]

    {pid, monitor} =
      :proc_lib.spawn_opt(
        fn ->
          Process.put(:"$callers", callers)
          value = thunk.()
          {:reductions, spent} = Process.info(self(), :reductions)
          send(parent, {tag, value, spent})
        end,
        [:monitor | Keyword.get(opts, :spawn, [])]
      )

    now = System.monotonic_time(:millisecond)
    call = %{pid: pid, monitor: monitor, tag: tag, cap: cap, timeout: timeout, spent: nil}
    await(call, now + timeout, now)
  end

  # `deadline` is the clock's bound, which only a call with no cap is held to; `since` is
  # when a capped call was last seen working: not waiting, or its reductions moved.
  defp await(%{pid: pid, monitor: monitor, tag: tag} = call, deadline, since) do
    receive do
      {^tag, value, spent} ->
        Process.demonitor(monitor, [:flush])
        judged(value, spent, call.cap)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:down, reason}
    after
      wait(call.cap, deadline) ->
        now = System.monotonic_time(:millisecond)

        case reading(pid) do
          # Ended: its `:DOWN` or its result is in the mailbox.
          nil ->
            await(call, deadline, since)

          _reading when call.cap == nil ->
            stop(call, :hung)

          {_status, spent} when spent > call.cap ->
            stop(call, {:reductions, spent})

          {:waiting, spent} when spent == call.spent ->
            if now - since >= call.timeout,
              do: stop(call, :hung),
              else: await(call, deadline, since)

          {_working, spent} ->
            await(%{call | spent: spent}, deadline, now)
        end
    end
  end

  # With no cap there is nothing to read, and the wait is the deadline's: past it the call
  # is hung, whatever it is doing. With one, a reading every 10 ms for as long as it runs.
  defp wait(nil, deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
  defp wait(_cap, _deadline), do: @poll

  # The running call's status and reductions, or `nil` for a process that has just ended.
  defp reading(pid) do
    case Process.info(pid, [:status, :reductions]) do
      [status: status, reductions: spent] -> {status, spent}
      nil -> nil
    end
  end

  # The call killed and waited for. A result it sent before the kill landed is its answer,
  # judged by its own count, so the moment of a reading is never a verdict.
  defp stop(%{pid: pid, monitor: monitor, tag: tag, cap: cap}, verdict) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end

    receive do
      {^tag, value, spent} -> judged(value, spent, cap)
    after
      0 -> verdict
    end
  end

  defp judged(_value, spent, cap) when cap != nil and spent > cap, do: {:reductions, spent}
  defp judged(value, spent, _cap), do: {:ok, value, spent}
end
