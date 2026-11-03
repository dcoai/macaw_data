# advisories.exs — no dependency in mix.lock carries a security advisory or is retired,
# outside the project's reasoned allowlist, ci/advisories_allowlist.exs (collpa#142,
# dco-tek/macaw/macaw#214). The Macaw family's reference copy is claude-tools'
# macaw_ci/advisories.exs, vendored into each project's ci/ byte for byte.
#
#   elixir ci/advisories.exs              # runs `mix hex.audit`; exit 1 on any problem
#   elixir ci/advisories.exs AUDIT_FILE   # checks a saved `mix hex.audit` output instead
#
# The check is Hex's own `mix hex.audit`. An allowlist entry names one advisory, by any id
# the audit prints for it (`EEF-CVE-…`, `CVE-…`, `GHSA-…`), and why it does not apply or
# can't be acted on yet; a retired package has no entry, it is updated. An entry the audit
# no longer reports fails too, so the list can't go stale. The list defaults empty: prefer
# updating the lock. An audit that fails without a finding (Hex unreachable, a crash)
# fails the check: no answer is never a clean one.

defmodule Advisories do
  @allowlist "ci/advisories_allowlist.exs"

  @doc """
  Every problem in an audit's output and exit status against the allowlist, one line
  each. A failed audit that reported no finding is a problem itself.
  """
  def problems(output, status, entries) do
    case {status, problems(output, entries), findings(output)} do
      {0, problems, _findings} -> problems
      {status, [], []} -> ["mix hex.audit failed (exit #{status}) without a finding it reported"]
      {_status, problems, _findings} -> problems
    end
  end

  @doc "Every problem in an audit's output against the allowlist, one line each."
  def problems(output, entries) do
    findings = findings(output)
    ids = findings |> Enum.flat_map(& &1.ids) |> MapSet.new()

    malformed(entries) ++
      for(
        finding <- findings,
        not Enum.any?(entries, &(&1[:advisory] in finding.ids)),
        do: "#{finding.line}: not in #{@allowlist}"
      ) ++
      retired(output) ++
      for(
        %{advisory: id} <- entries,
        not MapSet.member?(ids, id),
        do: "#{@allowlist}: #{id} is no longer reported: remove the entry"
      )
  end

  # Each advisory: its heading line (`  bandit 1.13.1 - EEF-CVE-… (HIGH)`) and every id
  # the audit gives it, the heading's and the `aka:` line's.
  defp findings(output) do
    output
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      heading = Regex.run(~r/^\s+\S+ \S+ - (\S+) \(\w+\)\s*$/, line)
      aka = Regex.run(~r/^\s+aka: (.+)$/, line)

      case {heading, aka, acc} do
        {[_, id], _, acc} ->
          [%{line: String.trim(line), ids: [id]} | acc]

        {nil, [_, names], [last | acc]} ->
          [%{last | ids: last.ids ++ String.split(names, ~r/,\s*/, trim: true)} | acc]

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp retired(output) do
    if output =~ ~r/^Retired packages:/m,
      do: ["mix hex.audit lists retired packages: update them (no allowlist for these)"],
      else: []
  end

  defp malformed(entries) do
    for entry <- entries,
        not match?(
          %{advisory: id, reason: r} when is_binary(id) and is_binary(r) and r != "",
          entry
        ),
        do: "#{@allowlist}: an entry needs an advisory id and a reason; got #{inspect(entry)}"
  end

  def main(argv) do
    {entries, _} = Code.eval_file(@allowlist)

    {output, status} =
      case argv do
        # A saved output carries no status: it is judged by what it reports.
        [file] -> {File.read!(file), 0}
        [] -> System.cmd("mix", ["hex.audit"], stderr_to_stdout: true)
      end

    case problems(output, status, entries) do
      [] ->
        IO.puts("advisories OK: no advisory or retired package outside the allowlist")

      problems ->
        IO.puts(output)
        Enum.each(problems, &IO.puts/1)
        System.halt(1)
    end
  end
end

unless Application.get_env(:ci, :ci_no_main), do: Advisories.main(System.argv())
