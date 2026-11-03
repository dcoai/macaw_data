defmodule AdvisoriesTest do
  @moduledoc """
  The advisory guard, `ci/advisories.exs`, vendored from the family's
  `claude-tools/macaw_ci` (spec/00 §3, macaw_data#162): no locked dependency carries an
  advisory or is retired outside `ci/advisories_allowlist.exs`. Its rules are shown on
  saved audit outputs; CI's `audit` job runs it over the live `mix hex.audit`.
  """
  use ExUnit.Case, async: true

  Application.put_env(:ci, :ci_no_main, true)
  Code.require_file("ci/advisories.exs")

  @clean "No retired dependencies found\nNo advisories found\n"

  @seeded """
  Security advisories:
    bandit 1.13.1 - EEF-CVE-2026-105659 (HIGH)
      aka: CVE-2026-105659, GHSA-xxxx-yyyy-zzzz
  """

  defp entry(id), do: %{advisory: id, reason: "not reachable from this library"}

  @tag verifies: "data-dependencies-advisories"
  test "this library's allowlist is well formed and passes a clean audit" do
    {entries, _binding} = Code.eval_file("ci/advisories_allowlist.exs")
    assert Advisories.problems(@clean, 0, entries) == []
  end

  @tag verifies: "data-dependencies-advisories"
  test "a seeded advisory outside the list fails at its heading; any of its ids allows it" do
    assert Advisories.problems(@seeded, 1, []) == [
             "bandit 1.13.1 - EEF-CVE-2026-105659 (HIGH): not in ci/advisories_allowlist.exs"
           ]

    for id <- ["EEF-CVE-2026-105659", "CVE-2026-105659", "GHSA-xxxx-yyyy-zzzz"],
        do: assert(Advisories.problems(@seeded, 1, [entry(id)]) == [])
  end

  @tag verifies: "data-dependencies-advisories"
  test "a retired package, a stale entry, a malformed one and a failed audit each fail" do
    assert ["mix hex.audit lists retired packages: update them (no allowlist for these)"] =
             Advisories.problems("Retired packages:\n  foo 1.0.0 (security)\n", 1, [])

    assert [stale] = Advisories.problems(@clean, 0, [entry("CVE-2020-1")])
    assert stale =~ "CVE-2020-1 is no longer reported"

    assert [malformed | _stale] = Advisories.problems(@clean, 0, [%{advisory: "CVE-2020-1"}])
    assert malformed =~ "needs an advisory id and a reason"

    assert Advisories.problems("could not reach hex.pm\n", 1, []) == [
             "mix hex.audit failed (exit 1) without a finding it reported"
           ]
  end
end
