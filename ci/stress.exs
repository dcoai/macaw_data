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
# A failed run's report names the tests that failed in it: ExUnit's failure blocks, found
# anywhere in its whole output (log lines can bury them past any tail), then the tail. The
# report ends with a tally, each failing test once with the number of runs it failed in, so
# a flake failing in several runs reads as one line (dco-tek/macaw/macaw#320).
#
# Exit 0 when every run passes, 1 naming each failed run's seed, failing tests and output's
# tail, 2 on bad arguments.

defmodule Stress do
  @tail 40
  @ansi ~r/\e\[[0-9;]*m/
  @heading ~r/^ {2,}\d+\) ((?:test|doctest|property) .+ \(.+\)|.+: failure on setup_all callback.*)$/

  @doc """
  Run `rounds` rounds of `at_once` concurrent runs of `command` (a list: the executable
  and its arguments), each with `--seed N` appended from `seeds`. `run` executes one
  command in a slot, `run.(command, slot)` with `slot` in `0..at_once - 1` and no two runs
  of a round in one slot, and answers `{output, status}`. Answers `[]` when every run
  passed, else `[%{seed:, status:, failures:, tail:}]`, `failures` as `failures/1` answers
  them.
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
      {_seed, {_output, 0}} ->
        []

      {seed, {output, status}} ->
        [%{seed: seed, status: status, failures: failures(output), tail: tail(output)}]
    end)
  end

  defp tail(output),
    do: output |> String.split("\n") |> Enum.take(-@tail) |> Enum.join("\n")

  @doc """
  The failure blocks ExUnit wrote in `output`, in order: `[%{test:, block:}]`, `test` the
  heading without its number (`test a name (Module)`), `block` the heading and the indented
  lines under it (location, assertion, code, left, right, stacktrace). Colors are stripped,
  and a line that isn't indented, such as a log line, ends a block.
  """
  def failures(output) do
    output
    |> String.replace(@ansi, "")
    |> String.split("\n")
    |> Enum.reduce([], fn line, blocks ->
      case {Regex.run(@heading, line), blocks} do
        {[_, test], blocks} ->
          [%{test: test, lines: [line], open: true} | blocks]

        {nil, [%{open: true} = block | rest]} ->
          if line == "" or String.starts_with?(line, " "),
            do: [%{block | lines: [line | block.lines]} | rest],
            else: [%{block | open: false} | rest]

        {nil, blocks} ->
          blocks
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn %{test: test, lines: lines} ->
      block = lines |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.reverse()
      %{test: test, block: Enum.join(block, "\n")}
    end)
  end

  @doc """
  Each test that failed in `failed` runs, once, with the number of runs it failed in: most
  first, then by name, `[{test, runs}]`.
  """
  def tally(failed) do
    failed
    |> Enum.flat_map(fn run -> run.failures |> Enum.map(& &1.test) |> Enum.uniq() end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {test, runs} -> {-runs, test} end)
  end

  @doc "One failed run's report: its seed, its failing tests' blocks, then its output's tail."
  def report(%{seed: seed, status: status, failures: failures, tail: tail}, command) do
    named =
      case failures do
        [] -> "no failing test named in its output"
        failures -> Enum.map_join(failures, "\n\n", & &1.block)
      end

    "--- seed #{seed} failed (exit #{status}); reproduce: #{Enum.join(command, " ")} --seed #{seed}\n" <>
      "#{named}\n--- its output's last #{@tail} lines:\n#{tail}\n"
  end

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

    buried =
      Enum.join(
        [
          "12:00:00.001 [info] starting",
          "",
          "\e[31m  1) test a (A)\e[0m",
          "     test/a_test.exs:3",
          "     left:  1",
          "     right: 2",
          "",
          "12:00:00.002 [error] a log line between blocks",
          "  2) test b in a describe (B)",
          "     test/b_test.exs:9",
          "     ** (RuntimeError) x",
          "",
          "Finished in 1.0 seconds",
          "12 tests, 2 failures"
        ],
        "\n"
      )

    cases = [
      {"every run passing is []", stress(["t"], 3, 6, seeds, echo) == []},
      {"each failed run names its seed and status",
       stress(["t"], 1, 4, seeds, odd) == [
         %{seed: 1, status: 1, failures: [], tail: "boom"},
         %{seed: 3, status: 1, failures: [], tail: "boom"}
       ]},
      {"failure blocks buried in log lines are found, colors stripped",
       failures(buried) == [
         %{
           test: "test a (A)",
           block: "  1) test a (A)\n     test/a_test.exs:3\n     left:  1\n     right: 2"
         },
         %{
           test: "test b in a describe (B)",
           block:
             "  2) test b in a describe (B)\n     test/b_test.exs:9\n     ** (RuntimeError) x"
         }
       ]},
      {"a run with no heading names none, and its report says so",
       failures("** (CompileError) lib/x.ex:1\nboom") == [] and
         report(%{seed: 7, status: 1, failures: [], tail: "boom"}, ["mix", "test"]) =~
           "no failing test named in its output"},
      {"the tally counts a test failing in two runs once, with 2, most first",
       tally([
         %{failures: [%{test: "test a (A)"}, %{test: "test b (B)"}]},
         %{failures: [%{test: "test a (A)"}]},
         %{failures: []}
       ]) == [{"test a (A)", 2}, {"test b (B)", 1}]},
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
            for run <- failed, do: IO.puts(Stress.report(run, command))

            IO.puts("stress: the failing tests, each with the number of runs it failed in")

            case Stress.tally(failed) do
              [] -> IO.puts("  none named; read each run's output above")
              tally -> for {test, runs} <- tally, do: IO.puts("  #{runs}× #{test}")
            end

            IO.puts("stress: #{length(failed)} of #{rounds * at_once} runs failed")
            System.halt(1)
        end
    end
end
