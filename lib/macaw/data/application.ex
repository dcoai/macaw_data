defmodule Macaw.Data.Application do
  @moduledoc false
  # The application's start: whether the native kernels loaded is decided here, once
  # (spec/04 §1.7). It runs no process of its own.

  use Application

  @impl true
  def start(_type, _args) do
    with :ok <- Macaw.Data.Native.start() do
      Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
    end
  end
end
