# stress.exs — run the suite many times at once, so a flake shows itself rather than on a
# loaded runner (dco-tek/macaw/macaw#280, spec/00 §4.4). The Macaw family's reference copy
# is claude-tools' macaw_ci/stress.exs, vendored into each project's ci/ byte for byte.
#
#   elixir ci/stress.exs                       # 3 rounds of 6 concurrent `mix test`, random seeds
#   elixir ci/stress.exs --rounds 5 --at-once 4
#   elixir ci/stress.exs -- mix test --only db # the command each run is, after --
#   elixir ci/stress.exs --self-test           # the runner's own cases
#
# Six concurrent suites found macaw#279 within minutes. Each run gets its own seed, passed
# as `--seed N`, so a failure names the seed that reproduces it. A pipeline schedule runs
# this as the project's `stress` job: a failed run fails the job, and a failed scheduled
# pipeline is red on the project and notifies its owner.
#
# Each of the runs at once has its own copy of the checkout, a slot, compiled once before
# the first round. Suites that share a directory share what they write in it (ExUnit's
# `tmp_dir` is a fixed path under the working directory), which no host running one suite
# does, so a failure there would be the runner's, not the code's.
#
# Exit 0 when every run passes, 1 naming each failed run's seed with its output's tail, 2
# on bad arguments.

defmodule Stress do
  @tail 40

  @doc """
  Run `rounds` rounds of `at_once` concurrent runs of `command` (a list: the executable
  and its arguments), each with `--seed N` appended from `seeds`. `run` executes one
  command in a slot, `run.(command, slot)` with `slot` in `0..at_once - 1` and no two runs
  of a round in one slot, and answers `{output, status}`. Answers `[]` when every run
  passed, else `[%{seed:, status:, tail:}]`.
  """
  def stress(command, rounds, at_once, seeds, run) do
    seeds
    |> Enum.take(rounds * at_once)
    |> Enum.chunk_every(at_once)
    |> Enum.flat_map(fn round ->
      round
      |> Enum.with_index()
      |> Task.async_stream(
        fn {seed, slot} -> {seed, run.(command ++ ["--seed", Integer.to_string(seed)], slot)} end,
        max_concurrency: at_once,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.map(fn {:ok, result} -> result end)
    end)
    |> Enum.flat_map(fn
      {_seed, {_output, 0}} -> []
      {seed, {output, status}} -> [%{seed: seed, status: status, tail: tail(output)}]
    end)
  end

  defp tail(output),
    do: output |> String.split("\n") |> Enum.take(-@tail) |> Enum.join("\n")

  @doc """
  Copy the checkout at `from` into `n` slots under `root`, every entry but `tmp/` (ExUnit's
  directories, which each slot makes its own), and answer their paths.
  """
  def slots(from, root, n) do
    entries = File.ls!(from) -- ["tmp"]

    for i <- 0..(n - 1) do
      slot = Path.join(root, "slot-#{i}")
      File.mkdir_p!(slot)
      for entry <- entries, do: File.cp_r!(Path.join(from, entry), Path.join(slot, entry))
      slot
    end
  end

  @doc "The options and the command, or `{:error, words}`."
  def parse(argv) do
    {flags, command} =
      case Enum.split_while(argv, &(&1 != "--")) do
        {flags, ["--" | command]} -> {flags, command}
        {flags, []} -> {flags, ["mix", "test"]}
      end

    case OptionParser.parse(flags, strict: [rounds: :integer, at_once: :integer]) do
      {opts, [], []} when command != [] ->
        rounds = Keyword.get(opts, :rounds, 3)
        at_once = Keyword.get(opts, :at_once, 6)

        if rounds > 0 and at_once > 0,
          do: {:ok, rounds, at_once, command},
          else: {:error, "--rounds and --at-once are positive"}

      _other ->
        {:error,
         "usage: elixir ci/stress.exs [--rounds N] [--at-once N] [-- COMMAND...] | --self-test"}
    end
  end

  def system([exe | args], dir), do: System.cmd(exe, args, cd: dir, stderr_to_stdout: true)

  @doc "The runner's own cases: `[]` when every case holds, else one line per failure."
  def self_test do
    seeds = Stream.iterate(1, &(&1 + 1))
    echo = fn command, _slot -> {Enum.join(command, " "), 0} end

    odd = fn command, _slot ->
      if rem(String.to_integer(List.last(command)), 2) == 1, do: {"boom", 1}, else: {"ok", 0}
    end

    me = self()

    seen = fn command, slot ->
      send(me, {:ran, command, slot})
      {"", 0}
    end

    root = Path.join(System.tmp_dir!(), "stress-self-test-#{System.unique_integer([:positive])}")
    from = Path.join(root, "from")
    File.mkdir_p!(Path.join([from, "tmp", "x"]))
    File.mkdir_p!(Path.join([from, "lib"]))
    File.write!(Path.join(from, "mix.exs"), "x")
    File.write!(Path.join([from, "lib", "a.ex"]), "a")
    copied = slots(from, Path.join(root, "slots"), 2)

    copies? =
      length(copied) == 2 and
        Enum.all?(copied, &(File.read(Path.join(&1, "mix.exs")) == {:ok, "x"})) and
        Enum.all?(copied, &(File.read(Path.join([&1, "lib", "a.ex"])) == {:ok, "a"})) and
        not Enum.any?(copied, &File.exists?(Path.join(&1, "tmp")))

    File.rm_rf!(root)

    cases = [
      {"every run passing is []", stress(["t"], 3, 6, seeds, echo) == []},
      {"each failed run names its seed and status",
       stress(["t"], 1, 4, seeds, odd) == [
         %{seed: 1, status: 1, tail: "boom"},
         %{seed: 3, status: 1, tail: "boom"}
       ]},
      {"rounds × at_once runs, each with its own --seed, a round's runs in distinct slots",
       stress(["mix", "test"], 2, 3, seeds, seen) == [] and
         Enum.sort(for(_ <- 1..6, do: receive(do: ({:ran, c, slot} -> {c, slot})))) ==
           Enum.sort(for n <- 1..6, do: {["mix", "test", "--seed", "#{n}"], rem(n - 1, 3)})},
      {"each slot is a copy of the checkout without its tmp/", copies?},
      {"the defaults are 3 rounds of 6 of mix test", parse([]) == {:ok, 3, 6, ["mix", "test"]}},
      {"a command after --",
       parse(["--rounds", "1", "--", "mix", "test", "--only", "db"]) ==
         {:ok, 1, 6, ["mix", "test", "--only", "db"]}},
      {"a bad flag or a zero count is an error",
       match?({:error, _}, parse(["--nope"])) and match?({:error, _}, parse(["--rounds", "0"]))}
    ]

    for {name, false} <- cases, do: "self-test failed: #{name}"
  end
end

case System.argv() do
  ["--self-test"] ->
    case Stress.self_test() do
      [] ->
        IO.puts("stress.exs self-test: ok")

      failures ->
        Enum.each(failures, &IO.puts(:stderr, &1))
        System.halt(1)
    end

  argv ->
    case Stress.parse(argv) do
      {:error, words} ->
        IO.puts(:stderr, words)
        System.halt(2)

      {:ok, rounds, at_once, command} ->
        root = Path.join(System.tmp_dir!(), "stress-#{System.unique_integer([:positive])}")
        slots = Stress.slots(File.cwd!(), root, at_once)

        # Each slot is compiled once, one at a time, so no run compiles and none races another.
        for slot <- slots do
          {output, status} =
            System.cmd("mix", ["compile"],
              cd: slot,
              env: [{"MIX_ENV", System.get_env("MIX_ENV", "test")}],
              stderr_to_stdout: true
            )

          if status != 0 do
            IO.puts(output)
            System.halt(1)
          end
        end

        seeds = Stream.repeatedly(fn -> :rand.uniform(1_000_000) end)
        run = fn command, slot -> Stress.system(command, Enum.at(slots, slot)) end
        failed = Stress.stress(command, rounds, at_once, seeds, run)
        File.rm_rf!(root)

        case failed do
          [] ->
            IO.puts(
              "stress: #{rounds * at_once} runs of #{Enum.join(command, " ")}, #{at_once} at once, each in its own copy: all passed"
            )

          failed ->
            for %{seed: seed, status: status, tail: tail} <- failed do
              IO.puts(
                "--- seed #{seed} failed (exit #{status}); reproduce: #{Enum.join(command, " ")} --seed #{seed}\n#{tail}\n"
              )
            end

            IO.puts("stress: #{length(failed)} of #{rounds * at_once} runs failed")
            System.halt(1)
        end
    end
end
