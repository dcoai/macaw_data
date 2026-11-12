# rules.exs — the family's rules for tests and state (dco-tek/macaw/macaw#280, spec/00
# §4.4), checked on the source's syntax tree. The Macaw family's reference copy is
# claude-tools' macaw_ci/rules.exs, vendored into each project's ci/ byte for byte.
#
#   elixir ci/rules.exs              # checks ./test and ./lib against ./ci/rules_allowlist.exs
#   elixir ci/rules.exs DIR          # the same under DIR
#   elixir ci/rules.exs --app [DIR]  # an application: ./test only
#   elixir ci/rules.exs --self-test  # the check's own cases
#
# Rule 1, time: a test proves cost by counting operations or reductions and waits on
# messages, so in test code these calls fail: the clocks that time code, the sleeps, and
# reading the node's atom count, which every process on the node moves:
#
#   :timer.tc   System.monotonic_time   :erlang.monotonic_time   :os.perf_counter
#   :timer.now_diff   Process.sleep   :timer.sleep
#   :erlang.system_info(:atom_count)   :erlang.memory(:atom)   :erlang.memory(:atom_used)
#
# Reading the date (`DateTime.utc_now/0`, `System.os_time/1`) isn't timing and is allowed.
#
# Rule 3, global state: a library reads no application environment, so under lib/ these
# fail (an application reads its own configuration at its edge, so --app skips lib/):
#
#   Application.get_env   fetch_env   fetch_env!   compile_env   compile_env!   get_all_env
#
# Test code is every file under test/, and a file under lib/ the allowlist names as test
# code that ships, such as a conformance kit; such a file is held to both rules.
#
# A call is matched in any form: called, piped into, or captured (`&Process.sleep/1`),
# under any alias of its module (`alias Process, as: P`). Text in a comment, a string or a
# doc is not a call. ci/rules_allowlist.exs holds two kinds of entry:
#
#   %{file: "test/x_test.exs", call: "Process.sleep", count: 1, reason: "..."}
#   %{test_code: "lib/my_lib/conformance.ex", reason: "..."}
#
# The first allows an honest use: the file, the call as written above, how many sites,
# and why. More sites than `count` fail, and so do fewer: a removed use shrinks the list,
# and a new one is a new decision, never quietly covered. The second names a file under
# lib/ that is test code. A malformed entry, a use whose call isn't banned in its file, a
# test_code entry for a file that isn't there, and a file that doesn't parse each fail.
# The list defaults empty.
#
# Exit 0 when the check holds, 1 with one line per problem, 2 on bad arguments.

defmodule Rules do
  @allowlist "ci/rules_allowlist.exs"

  # {module, function, nil | [args]}: nil matches any arity, a list only those literal args.
  @banned %{
    test: [
      {:timer, :tc, nil},
      {System, :monotonic_time, nil},
      {:erlang, :monotonic_time, nil},
      {:os, :perf_counter, nil},
      {:timer, :now_diff, nil},
      {Process, :sleep, nil},
      {:timer, :sleep, nil},
      {:erlang, :system_info, [:atom_count]},
      {:erlang, :memory, [:atom]},
      {:erlang, :memory, [:atom_used]}
    ],
    lib: [
      {Application, :get_env, nil},
      {Application, :fetch_env, nil},
      {Application, :fetch_env!, nil},
      {Application, :compile_env, nil},
      {Application, :compile_env!, nil},
      {Application, :get_all_env, nil}
    ]
  }

  @doc "The banned calls of a scope, `:test` or `:lib`, as written: `\"Process.sleep\"`."
  def banned(scope), do: @banned[scope] |> Enum.map(&name/1) |> Enum.uniq()

  @doc """
  Every banned call of the given scopes in a source: `[%{call:, line:}]` in line order, or
  `{:error, words}` when the source doesn't parse.
  """
  def scan(source, file, scopes) do
    case Code.string_to_quoted(source, file: file, columns: false) do
      {:ok, ast} ->
        banned = Enum.flat_map(scopes, &@banned[&1])
        {:ok, ast |> sites(banned) |> Enum.sort_by(& &1.line)}

      {:error, {meta, message, token}} ->
        {:error, "#{file}:#{line(meta)}: does not parse: #{message}#{token}"}
    end
  end

  defp line(meta) when is_list(meta), do: meta[:line]
  defp line(_meta), do: nil

  defp sites(ast, banned) do
    {_ast, {_aliases, found}} =
      Macro.prewalk(ast, {%{}, []}, fn
        {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [as]}]]} = node,
        {aliases, found} ->
          {node, {Map.put(aliases, as, Module.concat(parts)), found}}

        {{:., meta, [mod, fun]}, _, args} = node, {aliases, found} when is_atom(fun) ->
          case match(resolve(mod, aliases), fun, args, banned) do
            nil -> {node, {aliases, found}}
            ban -> {node, {aliases, [%{call: name(ban), line: meta[:line]} | found]}}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp resolve({:__aliases__, _, [first | rest]}, aliases),
    do: Module.concat([Map.get(aliases, first, first) | rest])

  defp resolve(mod, _aliases) when is_atom(mod), do: mod
  defp resolve(_mod, _aliases), do: nil

  defp match(mod, fun, args, banned) do
    Enum.find(banned, fn
      {^mod, ^fun, nil} -> true
      {^mod, ^fun, want} -> args == want
      _other -> false
    end)
  end

  defp name({mod, fun, _args}) do
    case Atom.to_string(mod) do
      "Elixir." <> elixir -> "#{elixir}.#{fun}"
      erlang -> ":#{erlang}.#{fun}"
    end
  end

  @doc """
  Every problem, one line each, from the sites found per file (`%{file => sites}`), the
  scopes each file was checked under (`%{file => [scope]}`) and the allowlist's use
  entries.
  """
  def check(found, scopes, uses) do
    {valid, malformed} = Enum.split_with(uses, &use?/1)

    malformed = Enum.map(malformed, &"ci/rules_allowlist.exs: malformed entry #{inspect(&1)}")

    misplaced =
      for %{file: file, call: call} <- valid,
          call not in Enum.flat_map(Map.get(scopes, file, [scope_of(file)]), &banned/1),
          do: "ci/rules_allowlist.exs: #{call} isn't banned in #{file}"

    allowed = Map.new(valid, &{{&1.file, &1.call}, &1.count})

    counted =
      for {file, sites} <- found, site <- sites, reduce: %{} do
        acc -> Map.update(acc, {file, site.call}, [site.line], &[site.line | &1])
      end

    over =
      for {{file, call}, lines} <- counted,
          length(lines) > Map.get(allowed, {file, call}, 0) do
        case Map.fetch(allowed, {file, call}) do
          {:ok, n} ->
            "#{file}: #{call} at #{list(lines)}: #{length(lines)} sites, the allowlist allows #{n}"

          :error ->
            "#{file}: #{call} at #{list(lines)}: banned (spec/00 §4.4); answer it another way or allowlist it with a reason"
        end
      end

    under =
      for {{file, call}, n} <- allowed,
          (got = length(Map.get(counted, {file, call}, []))) < n,
          do:
            "ci/rules_allowlist.exs: #{file} #{call}: allows #{n}, found #{got}; lower the count or remove the entry"

    Enum.sort(malformed ++ misplaced ++ over ++ under)
  end

  defp list(lines), do: lines |> Enum.sort() |> Enum.map_join(", ", &"line #{&1}")

  defp use?(%{file: file, call: call, count: count, reason: reason} = entry)
       when is_binary(file) and is_binary(call) and is_integer(count) and count > 0 and
              is_binary(reason) and reason != "" and map_size(entry) == 4,
       do: scope_of(file) != nil

  defp use?(_other), do: false

  defp test_code?(%{test_code: "lib/" <> _, reason: reason} = entry)
       when is_binary(reason) and reason != "" and map_size(entry) == 2,
       do: true

  defp test_code?(_other), do: false

  defp scope_of("test/" <> _), do: :test
  defp scope_of("lib/" <> _), do: :lib
  defp scope_of(_file), do: nil

  @doc "Run the check on a directory: `{:ok, files, entries}` or `{:error, lines}`."
  def run(dir, scopes) do
    with {:ok, entries} <- allowlist(dir) do
      {kits, uses} = Enum.split_with(entries, &(is_map(&1) and Map.has_key?(&1, :test_code)))
      {kits, bad_kits} = Enum.split_with(kits, &test_code?/1)
      kits = Enum.map(kits, & &1.test_code)

      kit_problems =
        Enum.map(bad_kits, &"ci/rules_allowlist.exs: malformed entry #{inspect(&1)}") ++
          for kit <- kits,
              not File.regular?(Path.join(dir, kit)),
              do: "ci/rules_allowlist.exs: test_code #{kit} isn't there"

      file_scopes =
        for scope <- scopes,
            file <- Path.wildcard(Path.join([dir, Atom.to_string(scope), "**", "*.{ex,exs}"])),
            reduce: %{} do
          acc -> Map.update(acc, Path.relative_to(file, dir), [scope], &[scope | &1])
        end

      file_scopes =
        Enum.reduce(kits, file_scopes, fn kit, acc ->
          if File.regular?(Path.join(dir, kit)),
            do: Map.update(acc, kit, [:test], &Enum.uniq([:test | &1])),
            else: acc
        end)

      {found, unparsed} =
        Enum.reduce(file_scopes, {%{}, []}, fn {rel, file_scope}, {found, errors} ->
          case scan(File.read!(Path.join(dir, rel)), rel, file_scope) do
            {:ok, sites} -> {Map.put(found, rel, sites), errors}
            {:error, words} -> {found, [words | errors]}
          end
        end)

      case Enum.sort(unparsed) ++ Enum.sort(kit_problems) ++ check(found, file_scopes, uses) do
        [] -> {:ok, map_size(found), length(entries)}
        problems -> {:error, problems}
      end
    end
  end

  defp allowlist(dir) do
    path = Path.join(dir, @allowlist)

    case File.read(path) do
      {:error, :enoent} ->
        {:ok, []}

      {:ok, text} ->
        case Code.string_to_quoted(text) do
          {:ok, ast} ->
            if Macro.quoted_literal?(ast) do
              case Code.eval_quoted(ast) do
                {list, _} when is_list(list) -> {:ok, list}
                _other -> {:error, ["#{@allowlist}: not a list"]}
              end
            else
              {:error, ["#{@allowlist}: not a literal list"]}
            end

          {:error, _} ->
            {:error, ["#{@allowlist}: does not parse"]}
        end
    end
  end

  @doc "The check's own cases: `[]` when every case holds, else one line per failure."
  def self_test do
    bad_test = ~S'''
    defmodule BadTest do
      alias Process, as: P
      def a, do: :timer.tc(fn -> 1 end)
      def b, do: Process.sleep(10)
      def c, do: 10 |> Process.sleep()
      def d, do: Enum.each([1], &Process.sleep/1)
      def e, do: P.sleep(1)
      def f, do: :timer.sleep(1)
      def g, do: :erlang.system_info(:atom_count)
      def h, do: System.monotonic_time(:millisecond)
      def i, do: :erlang.monotonic_time()
      def j, do: :os.perf_counter()
      def k, do: :timer.now_diff(a(), b())
      def l, do: :erlang.memory(:atom_used)
      def m, do: :erlang.memory(:atom)
    end
    '''

    good_test = ~S'''
    defmodule GoodTest do
      # Process.sleep(10) in a comment, and :timer.tc in a doc, aren't calls.
      @moduledoc "Process.sleep(10) and :timer.tc"
      def a, do: "Process.sleep(1)"
      def b, do: :erlang.system_info(:process_count)
      def c, do: Process.info(self(), :reductions)
      def d, do: Application.get_env(:app, :key)
      def e, do: {DateTime.utc_now(), System.os_time(:second), :erlang.memory(:total)}
    end
    '''

    bad_lib = ~S'''
    defmodule Bad do
      @ceiling Application.compile_env(:app, :ceiling)
      def a, do: Application.get_env(:app, :packages, [])
      def b, do: Application.fetch_env!(:app, :x)
      def c, do: Application.get_all_env(:app)
      def d, do: Application.fetch_env(:app, :x)
      def e, do: Application.compile_env!(:app, :y)
    end
    '''

    calls = fn source, scopes -> elem(scan(source, "x.ex", scopes), 1) |> Enum.map(& &1.call) end
    one = fn file, call, line -> %{file => [%{call: call, line: line}]} end
    use = fn file, call, n -> %{file: file, call: call, count: n, reason: "a reason"} end

    cases = [
      {"every banned test form is found, alias, pipe and capture included",
       calls.(bad_test, [:test]) ==
         [
           ":timer.tc",
           "Process.sleep",
           "Process.sleep",
           "Process.sleep",
           "Process.sleep",
           ":timer.sleep",
           ":erlang.system_info",
           "System.monotonic_time",
           ":erlang.monotonic_time",
           ":os.perf_counter",
           ":timer.now_diff",
           ":erlang.memory",
           ":erlang.memory"
         ]},
      {"comments, strings, docs, the date and other calls aren't sites",
       calls.(good_test, [:test]) == []},
      {"the lib/ ban isn't the test/ ban", calls.(bad_test, [:lib]) == []},
      {"every banned lib form is found",
       calls.(bad_lib, [:lib]) ==
         [
           "Application.compile_env",
           "Application.get_env",
           "Application.fetch_env!",
           "Application.get_all_env",
           "Application.fetch_env",
           "Application.compile_env!"
         ]},
      {"test code in lib/ is held to both bans",
       length(calls.(bad_test <> bad_lib, [:lib, :test])) == 19},
      {"a source that doesn't parse is an error",
       match?({:error, _}, scan("def (", "x.ex", [:test]))},
      {"a banned call with no entry fails",
       match?([_], check(one.("test/a_test.exs", "Process.sleep", 3), %{}, []))},
      {"an entry at its count passes",
       check(one.("test/a_test.exs", "Process.sleep", 3), %{}, [
         use.("test/a_test.exs", "Process.sleep", 1)
       ]) == []},
      {"more sites than the count fail",
       match?(
         [_],
         check(
           %{
             "test/a_test.exs" => [
               %{call: "Process.sleep", line: 3},
               %{call: "Process.sleep", line: 9}
             ]
           },
           %{},
           [use.("test/a_test.exs", "Process.sleep", 1)]
         )
       )},
      {"fewer sites than the count fail, so the list shrinks",
       match?(
         [_],
         check(%{"test/a_test.exs" => []}, %{}, [use.("test/a_test.exs", "Process.sleep", 1)])
       )},
      {"a malformed entry fails",
       match?([_], check(%{}, %{}, [use.("test/a_test.exs", "Process.sleep", 0)]))},
      {"an entry with no reason fails",
       match?(
         [_],
         check(%{}, %{}, [
           %{file: "test/a_test.exs", call: "Process.sleep", count: 1, reason: ""}
         ])
       )},
      {"an entry for a call not banned in its file fails",
       match?([_ | _], check(%{}, %{}, [use.("lib/a.ex", "Process.sleep", 1)]))},
      {"a test-code file in lib/ may allowlist a test call",
       check(one.("lib/kit.ex", "Process.sleep", 3), %{"lib/kit.ex" => [:test, :lib]}, [
         use.("lib/kit.ex", "Process.sleep", 1)
       ]) == []}
    ]

    for {name, false} <- cases, do: "self-test failed: #{name}"
  end
end

case System.argv() do
  ["--self-test"] ->
    case Rules.self_test() do
      [] ->
        IO.puts("rules.exs self-test: ok")

      failures ->
        Enum.each(failures, &IO.puts(:stderr, &1))
        System.halt(1)
    end

  args ->
    {app, rest} = if "--app" in args, do: {true, args -- ["--app"]}, else: {false, args}
    scopes = if app, do: [:test], else: [:test, :lib]

    dir =
      case rest do
        [] ->
          "."

        [dir] ->
          dir

        _ ->
          IO.puts(:stderr, "usage: elixir ci/rules.exs [--app] [DIR] | --self-test")
          System.halt(2)
      end

    case Rules.run(dir, scopes) do
      {:ok, files, entries} ->
        IO.puts(
          "rules (#{Enum.map_join(scopes, " and ", &"#{&1}/")}): #{files} files, #{entries} allowlisted, ok"
        )

      {:error, problems} ->
        Enum.each(problems, &IO.puts/1)
        System.halt(1)
    end
end
