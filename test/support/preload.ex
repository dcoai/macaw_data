defmodule Macaw.Data.Test.Preload do
  @moduledoc """
  Every module the suite can reach, loaded before the first test (macaw_data#289).

  A release boots in embedded mode: every module of every application is loaded at
  start. `mix test` runs interactive, where a module loads the first time it is called,
  through the one `:code_server`, and that server is busy all suite long: test files
  compile, stored functions compile in the sandbox, the type checker loads what it
  checks. A call into a module not yet loaded waits its turn there, and under load
  (the family's stress job, six suites at once) the wait reaches seconds. `:telemetry`'s
  handler table calls `telemetry_ets` for the first time inside the first attach,
  a `gen_server:call` with the default 5 s deadline, so `Macaw.Data.Source.Telemetry`'s
  collectors failed to start 2 to 7 times in 18 stressed runs.

  Loading them all first, as a release does, takes about 400 ms and makes the suite run
  the code as a host runs it.
  """

  @otp [:kernel, :stdlib, :compiler, :crypto, :elixir, :ex_unit, :logger]

  @doc "The applications whose modules are loaded: OTP's and Elixir's the suite uses, this one, and its dependencies."
  @spec apps() :: [atom()]
  def apps, do: Enum.uniq(@otp ++ [:macaw_data | Mix.Project.deps_apps()])

  @doc "Every module of `apps/0`."
  @spec modules() :: [module()]
  def modules do
    for app <- apps(),
        _ = Application.load(app),
        module <- Application.spec(app, :modules) || [],
        do: module
  end

  @doc "Load every module of `apps/0`: `:ok`, or `{:error, [{module, reason}]}`."
  @spec all() :: :ok | {:error, [{module(), term()}]}
  def all, do: :code.ensure_modules_loaded(modules())
end
