# Boots a minimal adopter app from this library's Hex package, without Zigler, as an
# adopter's default configuration would (macaw_data#76):
#
#     elixir ci/adopter_boot.exs [--ref REF] [--work DIR]
#
# - The package is `mix hex.build --unpack` of the working tree, or, with `--ref`, of
#   `git archive REF` (its dependencies fetched first), as a release is checked.
# - The package must hold no `.Elixir*` file: Zigler writes `.Elixir.<Module>.zig` beside a
#   module it compiles, and a package built from such a checkout would carry it.
# - The adopter depends on the package by path and lists no zigler, so the native kernels
#   are not built. It is compiled and started with `mix run`, which prints `loaded?`.
# - It fails on any `[error]` line in the build or the start, on a `loaded?` other than
#   false, and on any command that fails. Every command's whole output is printed.
#
# Work goes under `--work DIR`, default a fresh directory in the system's temporary one.

defmodule AdopterBoot do
  @probe ~S|IO.puts("macaw_data loaded?: #{inspect(Macaw.Data.Native.loaded?())}")|

  # The adopter is a fresh Mix project: nothing of this project's build reaches it.
  @clean_env [
    {"MIX_ENV", nil},
    {"MIX_BUILD_PATH", nil},
    {"MIX_BUILD_ROOT", nil},
    {"MIX_DEPS_PATH", nil},
    {"MIX_LOCKFILE", nil},
    {"MIX_EXS", nil},
    {"MACAW_DATA_NATIVE", nil},
    {"ZIG_EXECUTABLE_PATH", nil}
  ]

  def main(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: [ref: :string, work: :string])
    work = Path.expand(opts[:work] || fresh_dir())
    File.mkdir_p!(work)
    IO.puts("adopter boot: working in #{work}")

    source = source(opts[:ref], work)
    pkg = Path.join(work, "pkg")
    File.rm_rf!(pkg)
    run!("hex.build", source, ["hex.build", "--unpack", "-o", pkg], @clean_env)

    faults = dotfiles(pkg) ++ boot(pkg, Path.join(work, "adopter"))

    case faults do
      [] ->
        IO.puts("adopter boot OK: no error logged, loaded? false, no .Elixir* file packaged")

      _ ->
        Enum.each(faults, &IO.puts("adopter boot FAILED: " <> &1))
        System.halt(1)
    end
  end

  defp fresh_dir,
    do: Path.join(System.tmp_dir!(), "adopter_boot_#{System.unique_integer([:positive])}")

  # The working tree, or `git archive REF` with its dependencies fetched.
  defp source(nil, _work), do: File.cwd!()

  defp source(ref, work) do
    dir = Path.join(work, "src")
    tar = Path.join(work, "src.tar")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    run!("git archive", File.cwd!(), ["archive", "--format=tar", "-o", tar, ref], [], "git")
    :ok = :erl_tar.extract(String.to_charlist(tar), [{:cwd, String.to_charlist(dir)}])
    run!("deps.get (source)", dir, ["deps.get"], @clean_env)
    dir
  end

  defp dotfiles(pkg) do
    pkg
    |> Path.join("**/.Elixir*")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(&"the package holds #{Path.relative_to(&1, pkg)}")
  end

  defp boot(pkg, app) do
    File.rm_rf!(app)
    File.mkdir_p!(app)

    File.write!(Path.join(app, "mix.exs"), """
    defmodule Adopter.MixProject do
      use Mix.Project

      def project do
        [app: :adopter, version: "0.1.0", elixir: "~> 1.18", deps: [{:macaw_data, path: #{inspect(pkg)}}]]
      end

      def application, do: [extra_applications: [:logger]]
    end
    """)

    run!("deps.get (adopter)", app, ["deps.get"], @clean_env)
    compiled = run!("compile (adopter)", app, ["compile"], @clean_env)
    booted = run!("run (adopter)", app, ["run", "-e", @probe], @clean_env)

    errors =
      for out <- [compiled, booted],
          line <- String.split(out, "\n"),
          line =~ "[error]",
          do: "an error was logged: #{line}"

    loaded =
      case Regex.run(~r/^macaw_data loaded\?: (.*)$/m, booted) do
        [_, "false"] -> []
        [_, other] -> ["loaded? is #{other}, not false, without zigler"]
        nil -> ["the start printed no loaded?"]
      end

    errors ++ loaded
  end

  # A command's whole output, printed; a failed command fails the check at once.
  defp run!(label, dir, args, env, exe \\ "mix") do
    IO.puts("\n==> #{label}: #{exe} #{Enum.join(args, " ")} (in #{dir})")

    {out, status} =
      System.cmd(System.find_executable(exe), args, cd: dir, env: env, stderr_to_stdout: true)

    IO.write(out)

    if status != 0 do
      IO.puts("adopter boot FAILED: #{label} exited #{status}")
      System.halt(1)
    end

    out
  end
end

AdopterBoot.main(System.argv())
