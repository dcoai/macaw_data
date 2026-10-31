defmodule Macaw.Data.Test.Work do
  @moduledoc """
  The work a function does, counted rather than timed. Ported from visualize's
  `Visualize.Work` (visualize spec/12 §6, D-114, #462, #703); its numbers are visualize's.

  A cost claim in the default suite — a scroll costs its strip, not its window; a curve
  is built in work linear in its points — is a claim about the **algorithm**, and a
  wall-clock reading of it is a claim about the machine: a scheduler preemption during
  the cheaper of two timed runs flips a ratio, and an absolute bound moves with the box.
  Reductions are the BEAM's own count of the work a process executes: function calls and
  BIF work, which a preemption or a busy box does not add to.

  **The count is the run's execution, with no garbage collection in it** (#703). A
  collection is charged to the process that pays for it, and that charge is not a
  property of the code: how many collections a run takes depends on the heap its process
  brings to it, and what each one is charged moves with the load of the machine. A run
  that mostly allocates counted 233,000 to 528,000 reductions over the same 43
  collections, idle and loaded; in CI two counts of one gallery render in fresh processes
  were 8.5 % apart. So the run is counted in a process whose heap already holds
  everything the run allocates, and it collects nothing: that run counted 200,007 every
  time.

  The function runs twice, each time in a process of its own. The first run loads any
  module it calls first and measures the words it allocates, read from the collections
  traced in it. The second is spawned with a minimum heap of those words and a margin,
  and with a binary heap that does not trigger a collection either. The counted run is
  traced too, and a collection in it is an error that says so, rather than a count with
  the collection in it.

  **A call on a dirty scheduler is charged by its time** (macaw_data#60). A native kernel
  called on a normal scheduler costs its caller a fixed few reductions, whatever it does;
  called on a dirty CPU scheduler, the same kernel is charged about four reductions a
  microsecond it ran, so its count rises with the load (m4's finish: 1,577 to 7,355 for
  one input). The counted run's scheduling is traced too, and a run that went to a dirty
  scheduler is an error that names the cause, as a collection is: a count with the kernels
  in it is taken inside `Macaw.Data.Native.normal_schedulers/1`.

  **The count is exact but for one BIF** (macaw_data#66). The run's trace goes to a
  process held suspended through it: a tracer waiting in `receive` is woken by each trace
  message, and the counted process was now and then charged for the wake-up, 4 reductions
  at a time. That was most of the residue a count used to have: the per-chunk frame read
  168,683 to 168,692, and with the trace held it reads one count every time, idle (168,688
  in one VM, 168,687 to 168,690 across VMs). What remains is `:maps.from_list/1` building
  a map of more than 32 keys, which `MapSet.new/1`, `Map.new/1`, a comprehension `into:` a
  map and `Map.filter/2` all call: its charge moves from call to call, idle or loaded, the
  same work charged differently, inherent to the runtime (macaw_data#86). The BIF sorts the
  keys' hashes with OTP's `erts_qsort` and charges its steps, 40 to a reduction, and the
  sort's pivot is a hash of the array's address and, past 128 items, of the scheduler's
  random: up to 128 keys the charge moves only with where the runtime put the array (20 to
  22 for 33 keys, 56 to 62 for 100), and past it, with the quicksort's random count of
  steps, a floor and a long tail (616 to 748 for 1,000 keys over 5,000 counts, sd 16;
  `Macaw.Data.Test.WorkTest` states its bound and the bound's basis). The frame's counts
  move by 4 at most from it, saturated (168,684 to
  168,691; its merges 167,635 to 167,642). So a guard that wants a count exact compares the
  least of several, or allows that bound. A signal another process sends the counted one
  is charged to it too (a `process_info/2` request a few reductions, a link or a monitor up
  to 1,212): the counted function runs in a process nothing else is told of. So is the
  runtime's own: a module purged anywhere in the VM sends every process a check of its
  literal area, a few reductions each (a loop of 200,006 read 200,008 and 200,010 while
  another process purged modules, macaw_data#81). A guard that wants a count exact runs
  where no other test loads or purges code: not async.

  The function must do its work in the process it runs in — everything the suite
  measures this way is synchronous — and must not depend on the caller's process: its
  dictionary, its mailbox or `self()`.
  """

  # The counted heap's margin over what the first run allocated, and its floor in words.
  @margin 4
  @floor 100_000

  # A binary heap no run reaches, so binaries trigger no collection (words).
  @bin_vheap 1_000_000_000

  @doc """
  The reductions one run of `fun` spends, its collections excluded, and its result.

  The function must be pure enough to run twice, and every caller passes one that is.
  The result comes back as a message, so a function that raises raises again in the
  caller, with its stack trace.

      iex> {work, 6} = Macaw.Data.Test.Work.reductions(fn -> Enum.sum([1, 2, 3]) end)
      iex> work > 0
      true
  """
  @spec reductions((-> result)) :: {pos_integer(), result} when result: term()
  def reductions(fun) when is_function(fun, 0) do
    %{words: words} = run(fun, [])
    heap = words + div(words, @margin) + @floor

    case run(fun, min_heap_size: heap, min_bin_vheap_size: @bin_vheap) do
      %{collections: 0, dirty: 0, work: work, result: result} ->
        {work, result}

      %{dirty: n} when n > 0 ->
        raise "the counted run made #{n} calls on a dirty scheduler, each charged by its " <>
                "time, so the count moves with the load: count the kernels inside " <>
                "Macaw.Data.Native.normal_schedulers/1 (Macaw.Data.Test.Work, macaw_data#60)"

      %{collections: n} ->
        raise "the counted run collected #{n} times in a heap of #{heap} words, sized " <>
                "for the #{words} its first run allocated: the function does not " <>
                "allocate the same on every run (Macaw.Data.Test.Work, visualize#703)"
    end
  end

  # `fun` run in a process spawned for it alone, with `options`, its collections and its
  # scheduling traced to a collector held suspended (`collector/0`): the reductions it
  # spent, its result, how many times it collected, how many words it allocated — each
  # collection's young heap at its start, less what the one before it left, and what the
  # last one left against the heap at the end — and how many times it came back from a
  # dirty scheduler. The process knows its callers as a task does, so a log it writes is
  # captured with the test's. Every wait is on a message, with no `after`: the test's own
  # timeout bounds a run that never ends (spec/12 §6).
  defp run(fun, options) do
    parent = self()
    callers = [parent | Process.get(:"$callers", [])]
    tag = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          Process.put(:"$callers", callers)
          receive do: (^tag -> :ok)
          {:reductions, before} = Process.info(self(), :reductions)
          result = fun.()
          {:reductions, after_} = Process.info(self(), :reductions)
          {:heap_size, heap} = Process.info(self(), :heap_size)
          send(parent, {tag, after_ - before, heap, result})
        end,
        [:monitor | options]
      )

    collector = collector()
    :erlang.trace(pid, true, [:garbage_collection, :running, {:tracer, collector}])
    send(pid, tag)

    receive do
      {^tag, work, heap, result} ->
        receive do: ({:DOWN, ^monitor, :process, ^pid, _reason} -> :ok)
        delivered = :erlang.trace_delivered(pid)
        receive do: ({:trace_delivered, ^pid, ^delivered} -> :ok)
        {collections, words, dirty} = traced(pid, heap, collected(collector))
        %{work: work, result: result, collections: collections, words: words, dirty: dirty}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        collected(collector)
        crashed(reason)
    end
  end

  # The process the counted run's trace goes to, suspended, so a trace message only joins
  # its queue: a tracer waiting in `receive` is woken by each one, and the counted process
  # is now and then charged for that wake-up, 4 reductions at a time (macaw_data#66).
  # Linked, so it ends with the caller whatever happens.
  defp collector do
    collector = spawn_link(fn -> receive do: (:never_sent -> :ok) end)
    true = :erlang.suspend_process(collector)
    collector
  end

  # The collector's queue, every trace message of the run, read from outside it; then the
  # collector, done with, is ended.
  defp collected(collector) do
    {:messages, traces} = Process.info(collector, :messages)
    Process.unlink(collector)
    Process.exit(collector, :kill)
    traces
  end

  # What was traced from `pid`, all delivered (`:erlang.trace_delivered/1`), in order: how
  # many collections, the words allocated, and how many times it was scheduled back in from
  # a dirty scheduler, which a dirty call returns through
  # (`erts_internal:dirty_nif_finalizer/1`). Every other schedule in or out is a preemption
  # or a wait, which charges nothing.
  defp traced(pid, heap, traces) do
    {left, words, n, dirty} = Enum.reduce(traces, {0, 0, 0, 0}, &trace(pid, &1, &2))
    {n, words + heap - left, dirty}
  end

  defp trace(pid, {:trace, pid, start, info}, {left, words, n, dirty})
       when start in [:gc_minor_start, :gc_major_start],
       do: {left, words + info[:heap_size] + info[:mbuf_size] - left, n + 1, dirty}

  defp trace(pid, {:trace, pid, finish, info}, {_left, words, n, dirty})
       when finish in [:gc_minor_end, :gc_major_end],
       do: {info[:heap_size], words, n, dirty}

  defp trace(pid, {:trace, pid, :in, {:erts_internal, :dirty_nif_finalizer, _}}, acc),
    do: put_elem(acc, 3, elem(acc, 3) + 1)

  defp trace(pid, {:trace, pid, running, _mfa}, acc) when running in [:in, :out], do: acc

  defp crashed({exception, stacktrace}) when is_exception(exception),
    do: reraise(exception, stacktrace)

  defp crashed(reason), do: exit(reason)
end
