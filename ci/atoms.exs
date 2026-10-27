# No atom from untrusted input (spec/02 §6.5): fails on a call that makes an atom
# from a string (`String.to_atom`, `:erlang.binary_to_atom`, `List.to_atom`,
# `:erlang.list_to_atom`) or an interpolated atom literal (`:"…#{…}…"`) on any line
# of a `.ex` file under `lib/`, outside the allowlist `ci/atoms_allowlist.exs`.
#
#     elixir ci/atoms.exs          # report and exit 1 on any problem
#
# Each allowlist entry names a file, a fragment of the lines it allows, how many lines
# of the file hold that fragment, its class and its reason; an entry whose count isn't
# what the file holds fails too, so the list can't go stale. A comment line makes no atom
# and is passed over. `String.to_existing_atom` makes none and isn't matched.
#
# The classes are visualize's (D-195): (a) a closed library vocabulary, (a-host) a
# vocabulary host code registers, and (d) a set the library bounds. A name a document or
# a client declares, class (b), and one derived from such names, class (c), is a string,
# so an entry of either fails. Ported from visualize's `mix vis.atoms`; its test loads
# this file with `:ci_no_main` set, so nothing runs on load.

defmodule AtomGate do
  @scanned "lib"
  @allowlist "ci/atoms_allowlist.exs"
  @classes [:a, :"a-host", :d]
  @pattern ~r/String\.to_atom|binary_to_atom|List\.to_atom|list_to_atom|:"[^"]*#\{|:'[^']*#\{/

  @doc "Every problem under `root`, one line each; `[]` when there is none."
  def run(root) do
    {entries, _binding} = root |> Path.join(@allowlist) |> Code.eval_file()
    run(root, entries)
  end

  @doc "The check against a given allowlist."
  def run(root, entries) do
    sites = sites(root)
    malformed(entries) ++ unallowed(sites, entries) ++ stale(sites, entries)
  end

  # Every `{file, line_number, text}` that makes an atom from a string.
  defp sites(root) do
    root
    |> Path.join(@scanned <> "/**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      file = Path.relative_to(path, root)

      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {text, _n} -> site?(text) end)
      |> Enum.map(fn {text, n} -> {file, n, String.trim(text)} end)
    end)
  end

  defp site?(text) do
    not String.starts_with?(String.trim_leading(text), "#") and Regex.match?(@pattern, text)
  end

  defp malformed(entries) do
    for entry <- entries, problem = malformed_entry(entry), do: problem
  end

  defp malformed_entry(%{file: file, match: match, count: count, class: class, reason: reason})
       when is_binary(file) and is_binary(match) and is_integer(count) and count > 0 and
              class in @classes and is_binary(reason) and reason != "",
       do: nil

  defp malformed_entry(%{class: class} = entry) when class in [:b, :c],
    do:
      "#{@allowlist}: a name a document or a client declares is a string, never an " <>
        "allowed atom; got #{inspect(entry)}"

  defp malformed_entry(entry),
    do:
      "#{@allowlist}: an entry needs file, match, count, a class of #{inspect(@classes)} " <>
        "and a reason; got #{inspect(entry)}"

  defp unallowed(sites, entries) do
    for {file, n, text} <- sites,
        not Enum.any?(entries, &(&1.file == file and String.contains?(text, &1.match))),
        do: "#{file}:#{n}: makes an atom from a string: #{text}"
  end

  defp stale(sites, entries) do
    for %{file: file, match: match, count: count} <- entries,
        held =
          Enum.count(sites, fn {f, _n, text} -> f == file and String.contains?(text, match) end),
        held != count,
        do:
          "#{@allowlist}: #{file} holds #{held} line(s) with #{inspect(match)}, the entry says #{count}"
  end

  def main do
    case run(File.cwd!()) do
      [] ->
        IO.puts("atoms OK: no atom from a string outside the allowlist")

      problems ->
        Enum.each(problems, &IO.puts/1)
        System.halt(1)
    end
  end
end

unless Application.get_env(:ci, :ci_no_main), do: AtomGate.main()
