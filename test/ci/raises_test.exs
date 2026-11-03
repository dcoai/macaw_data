defmodule RaisesTest do
  @moduledoc """
  The raise guard, `ci/raises.exs`, vendored from the family's `claude-tools/macaw_ci`
  (spec/00 §5, macaw_data#130, #160): errors are values. Its own behavior is tested where
  it lives; here it holds this library, and its rules are shown on small trees.
  """
  use ExUnit.Case, async: true

  Application.put_env(:ci, :ci_no_main, true)
  Code.require_file("ci/raises.exs")

  # The problems the guard finds in `files`, `{path, source}` under lib/, against `entries`.
  defp problems(files, entries) do
    scans = for {file, source} <- files, do: {file, Raises.scan(source, file)}
    Raises.problems(scans, entries)
  end

  defp library do
    for file <- Enum.sort(Path.wildcard("lib/**/*.ex")), do: {file, File.read!(file)}
  end

  @tag verifies: "data-errors-guard"
  test "the library holds no raise the allowlist does not, and the allowlist no stale entry" do
    {entries, _binding} = Code.eval_file("ci/raises_allowlist.exs")
    assert problems(library(), entries) == []
  end

  @tag verifies: "data-errors-guard"
  test "a raise, a throw or an exit outside the list fails at its line; a raise in a doc is no site" do
    source = """
    defmodule X do
      @moduledoc "raise in a doc is no site"
      def new(a), do: if(a, do: {:ok, a}, else: {:error, :no})
      def read(a), do: a || raise(ArgumentError, "bad input")
      def stop(a), do: a || exit(:no)
      def jump(a), do: a || :erlang.throw(:no)
    end
    """

    assert problems([{"lib/x.ex", source}], []) == [
             "lib/x.ex:4: X.read/1 calls raise: not in ci/raises_allowlist.exs",
             "lib/x.ex:5: X.stop/1 calls exit: not in ci/raises_allowlist.exs",
             "lib/x.ex:6: X.jump/1 calls :erlang.throw: not in ci/raises_allowlist.exs"
           ]
  end

  @tag verifies: "data-errors-guard"
  test "a listed twin passes; a :bang entry without its twin, a stale entry and a misclassed one fail" do
    source = """
    defmodule X do
      def new(a), do: if(a, do: {:ok, a}, else: {:error, :no})
      def new!(a), do: if(a, do: a, else: raise(ArgumentError, "no"))
      def helper!(a), do: a || raise("no")
      def f(a), do: a || raise("no")
    end
    """

    entry = fn at, class -> %{at: at, class: class, reason: "a reason"} end

    entries = [
      entry.({X, :new!, 1}, :bang),
      entry.({X, :helper!, 1}, :bang),
      entry.({X, :f, 1}, :compile),
      entry.({X, :gone, 0}, :invariant)
    ]

    assert problems([{"lib/x.ex", source}], entries) == [
             "ci/raises_allowlist.exs: X.helper!/1 is listed as :bang but X.helper/1 isn't defined",
             "ci/raises_allowlist.exs: X.f/1 is listed as :compile but is a def, not a macro or the module body",
             "ci/raises_allowlist.exs: X.gone/0 no longer raises: remove the entry"
           ]
  end
end
