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
  """

  require Logger

  alias Macaw.Data.Native.Kernels

  @key {__MODULE__, :loaded?}
  # The interface version kernels.zig answers (`abi/0`), so a stale library is not used.
  @abi 1
  @sync_rows 16_384

  @doc "Whether the native kernels are built and loaded: decided once, at the application's start."
  @spec loaded?() :: boolean()
  def loaded?, do: :persistent_term.get(@key, false)

  @doc "Whether this build compiled the native kernels (the toolchain was present)."
  @spec built?() :: boolean()
  def built?, do: Kernels.built?()

  @doc "The `native:` setting this build was compiled under: `:optional` or `:required`."
  @spec mode() :: :optional | :required
  def mode, do: Kernels.mode()

  @doc """
  The most rows a kernel call works on a normal scheduler, 16,384, two canonical chunks:
  at a few nanoseconds a row, well under the BEAM's 1 ms rule.
  """
  @spec sync_rows() :: pos_integer()
  def sync_rows, do: @sync_rows

  @doc "Where a kernel call over `rows` rows runs: `:normal` up to `sync_rows/0`, else `:dirty`."
  @spec scheduler(non_neg_integer()) :: :normal | :dirty
  def scheduler(rows) when rows <= @sync_rows, do: :normal
  def scheduler(_rows), do: :dirty

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
