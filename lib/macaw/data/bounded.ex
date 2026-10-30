defmodule Macaw.Data.Bounded do
  @moduledoc """
  One call in a monitored process of its own, its cost counted rather than timed: the
  conformance kit's runner (spec/01 §9), ported from visualize's `Visualize.Bounded`.

  The cost is the reductions the call's process spends, collections included, which a
  loaded host does not change. A call that answers is judged by its own count, read as
  its function returns; a call still running is read every 10 ms and killed at the first
  reading over the cap. Liveness is a separate wall-clock bound, `timeout`, for a call
  blocked in `receive`, which spends no reductions and so is never stopped by a cap: past
  it, a capped call is hung only when it is blocked, waiting in `receive` at two readings
  10 ms apart with its reductions unchanged. One still working is left to its cap, so a
  slow call on a loaded host is never hung (macaw_data#33). A call with no cap has only
  the clock, and past it is hung whatever it is doing.

  Nothing is rescued: a raise or an exit is read from the process's `:DOWN`.

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
  `thunk` called in a process spawned with `spawn:` options and `:monitor`, the caller in
  its `$callers`: `{:ok, value, reductions}`; `{:reductions, spent}` when it spent more
  than `reductions:` (`nil`, no cap); `:hung` when it had not answered within `timeout:`
  ms and is blocked in `receive` (with no cap, whatever it is doing); `{:down, reason}`
  when it exited first, a heap limit's kill as `:killed`. A process
  the caller kills is waited for, so nothing it does outlives the call.
  """
  @spec run((-> term()), keyword()) :: outcome()
  def run(thunk, opts) when is_function(thunk, 0) do
    cap = Keyword.get(opts, :reductions)
    timeout = Keyword.fetch!(opts, :timeout)
    parent = self()
    tag = make_ref()
    callers = [parent | Process.get(:"$callers", [])]

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          Process.put(:"$callers", callers)
          value = thunk.()
          {:reductions, spent} = Process.info(self(), :reductions)
          send(parent, {tag, value, spent})
        end,
        [:monitor | Keyword.get(opts, :spawn, [])]
      )

    call = %{pid: pid, monitor: monitor, tag: tag, cap: cap, last: nil}
    await(call, System.monotonic_time(:millisecond) + timeout)
  end

  defp await(%{pid: pid, monitor: monitor, tag: tag} = call, deadline) do
    receive do
      {^tag, value, spent} ->
        Process.demonitor(monitor, [:flush])
        judged(value, spent, call.cap)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:down, reason}
    after
      wait(call.cap, deadline) ->
        reading = reading(pid)
        past? = System.monotonic_time(:millisecond) >= deadline

        cond do
          reading == nil -> await(call, deadline)
          over?(reading, call.cap) -> stop(call, {:reductions, elem(reading, 1)})
          past? and hung?(call, reading) -> stop(call, :hung)
          true -> await(%{call | last: reading}, deadline)
        end
    end
  end

  # With no cap there is nothing to read before the deadline, and the wait is the
  # deadline's; with one, a reading every 10 ms, past the deadline too.
  defp wait(nil, deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp wait(_cap, deadline) do
    left = deadline - System.monotonic_time(:millisecond)
    if left > 0, do: min(@poll, left), else: @poll
  end

  # The running call's status and reductions, or `nil` for a process that has just ended,
  # whose `:DOWN` or result is in the mailbox.
  defp reading(pid) do
    case Process.info(pid, [:status, :reductions]) do
      [status: status, reductions: spent] -> {status, spent}
      nil -> nil
    end
  end

  defp over?({_status, spent}, cap) when cap != nil, do: spent > cap
  defp over?(_reading, _cap), do: false

  # Past the deadline: a call with no cap has only the clock, so it is hung whatever it is
  # doing. A capped call is hung only when it is blocked in `receive`: waiting at this
  # reading and the one before, its reductions unchanged between them. One still working
  # is left to its cap, so a slow call on a loaded host is never hung.
  defp hung?(%{cap: nil}, _reading), do: true
  defp hung?(%{last: {:waiting, spent}}, {:waiting, spent}), do: true
  defp hung?(_call, _reading), do: false

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
