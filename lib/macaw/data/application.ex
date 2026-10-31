defmodule Macaw.Data.Application do
  @moduledoc false
  # The application's start: whether the native kernels loaded is decided here, once
  # (spec/04 §1.7), and the sandbox's evaluator is warmed, so a bounded compile waits on no
  # code server (spec/02 §6.3). It runs no process of its own.

  use Application

  @impl true
  def start(_type, _args) do
    with :ok <- Macaw.Data.Native.start(),
         :ok <- Macaw.Data.Derived.Sandbox.warm() do
      Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
    end
  end
end
