defmodule Macaw.Data.Native.Toolchain do
  @moduledoc false
  # Whether this build can compile the native kernels (spec/04 §1.7), decided at compile
  # time: Zigler among the dependencies and a Zig of the version it targets. Zig is asked
  # through `zig env`, which names its real executable: a version manager's shim (asdf's)
  # resolves its version from the working directory, and Zigler builds in a staging
  # directory outside the project, so Zigler is handed the executable itself.
  #
  # Where a Zig is looked for, in order, as Zigler looks: `ZIG_EXECUTABLE_PATH`; the
  # archive `ZIG_ARCHIVE_PATH` names; Zigler's own cache (`mix zig.get`); the `PATH`.

  # Zig is Zigler's, an optional dependency: called only once it is loaded.
  @compile {:no_warn_undefined, Zig}

  @typedoc "The toolchain found: `{:ok, executable}`, or `{:absent, why}`, a sentence."
  @type t :: {:ok, Path.t()} | {:absent, String.t()}

  @doc false
  @spec detect() :: t()
  def detect do
    if Code.ensure_loaded?(Zig) do
      want = Zig.version()

      case candidate(want) do
        nil -> {:absent, "no Zig executable was found (Zigler targets Zig #{want})"}
        exe -> ask(exe, want)
      end
    else
      {:absent, "Zigler is not among the dependencies"}
    end
  end

  @doc false
  # What the build does with the toolchain under the `native:` setting: `:build`; `{:skip,
  # warning}`, the Elixir path and a warning printed; `{:fail, message}`, the build fails.
  @spec decide(t(), term()) :: :build | {:skip, String.t()} | {:fail, String.t()}
  def decide({:ok, _exe}, mode) when mode in [:optional, :required], do: :build

  def decide({:absent, why}, :optional),
    do:
      {:skip,
       "macaw_data: the native kernels are not built, so every step runs its Elixir path " <>
         "(spec/04 §1.7): #{why}"}

  def decide({:absent, why}, :required),
    do:
      {:fail,
       "macaw_data: config :macaw_data, native: :required, but the native kernels can't " <>
         "be built: #{why}"}

  def decide(_toolchain, mode),
    do:
      {:fail,
       "macaw_data: config :macaw_data, native: #{inspect(mode)} is not :optional or " <>
         ":required (spec/04 §1.7)"}

  @doc false
  # Where Zigler stages this build's modules: `ZIGLER_STAGING_ROOT` where the environment
  # sets it, else `zigler/` in the build's own path. Zigler's default is the system's temp
  # directory, one `/tmp/<module>` for every checkout, worktree and build path on the host,
  # so two builds at once wrote each other's build.zig and module.zig (macaw_data#72).
  @spec staging_root(Path.t(), String.t() | nil) :: Path.t()
  def staging_root(_build_path, root) when is_binary(root) and root != "", do: root
  def staging_root(build_path, _root), do: Path.join(build_path, "zigler")

  defp candidate(want) do
    Enum.find_value(
      [
        System.get_env("ZIG_EXECUTABLE_PATH", ""),
        archived(System.get_env("ZIG_ARCHIVE_PATH", ""), want),
        archived(:filename.basedir(:user_cache, "zigler") |> to_string(), want),
        System.find_executable("zig") || ""
      ],
      fn path -> if path != "" and File.regular?(path), do: path end
    )
  end

  defp archived("", _want), do: ""

  defp archived(dir, want) do
    case Path.wildcard(Path.join(dir, "zig-*-#{want}/zig")) do
      [path | _] -> path
      [] -> ""
    end
  end

  # `zig env` prints the executable and its version (ZON since Zig 0.15, JSON before).
  defp ask(exe, want) do
    case System.cmd(exe, ["env"], stderr_to_stdout: true) do
      {out, 0} ->
        case {field(out, "zig_exe"), field(out, "version")} do
          {real, ^want} when is_binary(real) -> {:ok, real}
          {_real, nil} -> {:absent, "#{exe} env names no version"}
          {_real, other} -> {:absent, "#{exe} is Zig #{other}; Zigler targets Zig #{want}"}
        end

      {out, _status} ->
        {:absent, "#{exe} env failed: #{out |> String.split("\n") |> hd()}"}
    end
  end

  defp field(out, name) do
    case Regex.run(~r/^\s*\.?"?#{name}"?\s*[=:]\s*"([^"]*)"/m, out) do
      [_, value] -> value
      nil -> nil
    end
  end
end
