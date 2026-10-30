defmodule Macaw.Data.Native do
  @moduledoc """
  The optional native kernels (spec/04 §1.7): Zig, compiled through Zigler when the build
  has a Zig of the version Zigler targets, each reading a column's packed Arrow buffers in
  place and answering exactly what the step's Elixir path answers. Without them every step
  runs its Elixir path, with the same results.

  - **`loaded?/0`** is decided once, when the application starts, and held in
    `:persistent_term`, so a step asks it for free.
  - **`config :macaw_data, native: :optional | :required`**, default `:optional`:
    `:required` fails the build without the toolchain, and the application's start when the
    built kernels don't load; `:optional` warns at compile time and runs the Elixir path.
  - **The 1 ms rule:** a call over at most `sync_rows/0` rows runs on a normal scheduler,
    well within a millisecond; a larger one on a dirty CPU scheduler (`scheduler/1`).
  - **Counted on normal schedulers:** a call on a normal scheduler is charged a few
    reductions whatever its time, and one on a dirty scheduler is charged by its time, so
    `normal_schedulers/1` makes every call in its process on a normal scheduler for a
    statement of work in reductions with the kernels (spec/04 §1.7, macaw_data#60).
  """

  require Logger

  alias Macaw.Data.Native.Kernels

  @key {__MODULE__, :loaded?}
  @elixir {__MODULE__, :elixir}
  @normal {__MODULE__, :normal_schedulers}
  # The interface version kernels.zig answers (`abi/0`), so a stale library is not used.
  @abi 6
  @sync_rows 8_192
  @finish_buckets 2_048
  @sync_entries 2_048

  @doc "Whether the native kernels are built and loaded: decided once, at the application's start."
  @spec loaded?() :: boolean()
  def loaded?, do: :persistent_term.get(@key, false)

  @doc """
  Whether a step in this process runs its kernels: they are loaded and the process is not
  inside `elixir/1`. Each step with a kernel asks this.
  """
  @spec active?() :: boolean()
  def active?, do: loaded?() and Process.get(@elixir) == nil

  @doc """
  `fun`'s result, every step in this process run on its Elixir path while it runs, kernels
  loaded or not. Reductions count no kernel's work, so a statement of work in reductions
  is measured here; and the Elixir path is the reference a kernel is held equal to. Not
  nested: the flag is cleared when `fun` returns.
  """
  @spec elixir((-> result)) :: result when result: term()
  def elixir(fun) when is_function(fun, 0) do
    Process.put(@elixir, true)
    result = fun.()
    Process.delete(@elixir)
    result
  end

  @doc """
  `fun`'s result, every kernel call in this process made on a normal scheduler while it
  runs, whatever its size: `scheduler/1` and `finish_scheduler/1` answer `:normal`, and
  `entry_limit/0` lifts the limit past which a normal `group_sum` call hands itself to a
  dirty one. The same kernel runs either way; only the scheduler changes.

  A kernel call on a normal scheduler is charged a fixed few reductions, whatever its
  time; one on a dirty CPU scheduler is charged by its time, about four a microsecond on
  the box #60 measured, so it counts more on a loaded host. A statement of work in
  reductions with the kernels, such as the frame's (spec/04 §1.5.1), is measured here, and
  `Macaw.Data.Test.Work` refuses a count with a dirty call in it. A call past the 1 ms rule
  then holds its scheduler longer than the rule allows, so this is for measuring, never
  for serving. Not nested: the flag is cleared when `fun` returns.
  """
  @spec normal_schedulers((-> result)) :: result when result: term()
  def normal_schedulers(fun) when is_function(fun, 0) do
    Process.put(@normal, true)
    result = fun.()
    Process.delete(@normal)
    result
  end

  @doc "Whether this build compiled the native kernels (the toolchain was present)."
  @spec built?() :: boolean()
  def built?, do: Kernels.built?()

  @doc "The `native:` setting this build was compiled under: `:optional` or `:required`."
  @spec mode() :: :optional | :required
  def mode, do: Kernels.mode()

  @doc """
  The most rows a kernel call works on a normal scheduler, 8,192, one canonical chunk: a
  few nanoseconds a row, and at worst, every row its own bucket, about half a millisecond
  building the answer's terms, within the BEAM's 1 ms rule.
  """
  @spec sync_rows() :: pos_integer()
  def sync_rows, do: @sync_rows

  @doc """
  Where a kernel call over `rows` rows runs: `:normal` up to `sync_rows/0`, else `:dirty`;
  `:normal` inside `normal_schedulers/1`.
  """
  @spec scheduler(non_neg_integer()) :: :normal | :dirty
  def scheduler(rows) when rows <= @sync_rows, do: :normal
  def scheduler(_rows), do: if(normal?(), do: :normal, else: :dirty)

  @doc """
  The most buckets a finish kernel (`m4`'s columns, `lttb`'s selection) reads on a normal
  scheduler, #{@finish_buckets}: a few tens of nanoseconds a bucket, well within the BEAM's
  1 ms rule; past it the kernel runs on a dirty CPU scheduler.
  """
  @spec finish_buckets() :: pos_integer()
  def finish_buckets, do: @finish_buckets

  @doc """
  Where a finish kernel over `buckets` runs: `:normal` up to `finish_buckets/0`, else
  `:dirty`; `:normal` inside `normal_schedulers/1`.
  """
  @spec finish_scheduler(non_neg_integer()) :: :normal | :dirty
  def finish_scheduler(buckets) when buckets <= @finish_buckets, do: :normal
  def finish_scheduler(_buckets), do: if(normal?(), do: :normal, else: :dirty)

  @doc """
  The most entries, groups and their float exponents' sums, an exact sum by group
  (`group_sum`) answers on a normal scheduler, #{@sync_entries}: its scan is a few
  nanoseconds a row, but each entry of its answer is a few terms at tens of nanoseconds
  each, so a call answering more is handed, before any term is built, to a dirty CPU
  scheduler, within the BEAM's 1 ms rule.
  """
  @spec sync_entries() :: pos_integer()
  def sync_entries, do: @sync_entries

  @doc """
  The limit a normal `group_sum` call is given: `sync_entries/0`, past which it answers
  `:dirty` and is made again on a dirty scheduler; `0`, no limit, inside
  `normal_schedulers/1`.
  """
  @spec entry_limit() :: non_neg_integer()
  def entry_limit, do: if(normal?(), do: 0, else: @sync_entries)

  defp normal?, do: Process.get(@normal) == true

  @doc false
  # At the application's start: whether the kernels loaded, held in `:persistent_term`. A
  # build under `native: :required` whose kernels don't load fails the start, with why.
  @spec start() :: :ok | {:error, term()}
  def start do
    result = probe()
    :persistent_term.put(@key, result == :ok)
    settle(result, mode())
  end

  @doc false
  # What the start answers for a probe's result under the `native:` setting.
  @spec settle(:ok | {:error, term()}, :optional | :required) :: :ok | {:error, term()}
  def settle(:ok, _mode), do: :ok
  def settle({:error, reason}, :required), do: {:error, {:native_kernels, reason}}
  def settle({:error, {:not_built, _stack}}, :optional), do: :ok

  def settle({:error, reason}, :optional) do
    Logger.warning(
      "macaw_data: the native kernels were built but did not load " <>
        "(#{inspect(reason)}); every step runs its Elixir path (spec/04 §1.7)"
    )

    :ok
  end

  # The kernels are asked their interface version in a process of its own: a library not
  # built (`:not_built`) or not loaded raises there, and its exit reason is the answer,
  # with nothing caught.
  defp probe do
    {pid, ref} = spawn_monitor(fn -> exit({:abi, Kernels.abi()}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:abi, @abi}} -> :ok
      {:DOWN, ^ref, :process, ^pid, {:abi, other}} -> {:error, {:abi, other, @abi}}
      {:DOWN, ^ref, :process, ^pid, reason} -> {:error, reason}
    end
  end
end
