# Refuses a Hex publish from anything but the clean, pushed release tag:
#
#     elixir ci/release_guard.exs VERSION
#
# Each Macaw library runs it ahead of `mix hex.publish` through an alias in mix.exs:
#
#     aliases: ["hex.publish": ["cmd elixir ci/release_guard.exs #{@version}", "hex.publish"]]
#
# It exits non-zero, one line per reason, when the working tree has changes, when HEAD
# doesn't carry the tag vVERSION, or when that tag isn't on origin. A package built
# from anything else isn't the release its tag names (dco-tek/macaw/macaw#190).
#
# Copied into each Macaw repository unchanged; the reference copy and the drift check
# that keeps the copies equal live in claude-tools (macaw_ci/, macaw_ci_drift.exs).

defmodule ReleaseGuard do
  def main([version]) do
    tag = "v" <> version

    reasons =
      Enum.reject(
        [
          dirty(),
          at_tag(tag),
          pushed(tag)
        ],
        &is_nil/1
      )

    case reasons do
      [] ->
        IO.puts("release guard: HEAD is #{tag}, clean, and on origin")

      _ ->
        Enum.each(reasons, &IO.puts(:stderr, "release guard: " <> &1))
        System.halt(1)
    end
  end

  def main(_args) do
    IO.puts(:stderr, "usage: elixir ci/release_guard.exs VERSION")
    System.halt(2)
  end

  defp dirty do
    case git(["status", "--porcelain"]) do
      {"", 0} -> nil
      {_changes, 0} -> "the working tree has changes; publish from a clean checkout of the tag"
      {out, _} -> "git status failed: " <> String.trim(out)
    end
  end

  defp at_tag(tag) do
    case git(["tag", "--points-at", "HEAD"]) do
      {out, 0} ->
        tags = String.split(out, "\n", trim: true)

        cond do
          tag in tags -> nil
          tags == [] -> "HEAD is not a tag; check out #{tag}"
          true -> "HEAD is #{Enum.join(tags, ", ")}, not #{tag}"
        end

      {out, _} ->
        "git tag failed: " <> String.trim(out)
    end
  end

  defp pushed(tag) do
    case git(["ls-remote", "--tags", "origin", "refs/tags/" <> tag]) do
      {"", 0} -> "#{tag} is not on origin; push the tag first"
      {_ref, 0} -> nil
      {out, _} -> "could not read origin's tags: " <> String.trim(out)
    end
  end

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)
end

ReleaseGuard.main(System.argv())
