# vendored.exs — the Macaw family's CI scripts in ci/ are the copies they were vendored
# as, and at a release the family's current ones (spec/00 §3, macaw_data#162, #165).
#
#     elixir ci/vendored.exs                    # CI: every copy hashes to its manifest entry
#     elixir ci/vendored.exs --reference [DIR]  # release: and every copy is the reference's
#     elixir ci/vendored.exs --vendor [DIR]     # copy the reference in, rewrite the manifest
#
# The family's scripts (advisories.exs, raises.exs, release_guard.exs, spec_links.exs) live
# in claude-tools' macaw_ci/ and are copied into ci/ byte for byte, because CI can't reach
# claude-tools. A copy drifts two ways: edited here, which CI catches against the SHA-256
# each copy had when it was vendored (ci/vendored_manifest.exs); or left behind when the
# reference moves on, which only a machine holding the reference can see, so `mix
# hex.publish` runs the `--reference` form. DIR defaults to $MACAW_CI_REFERENCE, else
# ~/Projects/claude-tools/macaw_ci. A reference that isn't there fails: no answer is
# never a clean one. This script is macaw_data's own, not a family copy.
#
# Exit 0 when every copy holds, 1 with one line per problem, 2 on bad arguments.

defmodule Vendored do
  @manifest "ci/vendored_manifest.exs"
  @default_reference "~/Projects/claude-tools/macaw_ci"

  @doc "A copy's SHA-256, lowercase hex."
  def hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  Every problem, one line each. `copies` maps each script name to its bytes in ci/, or
  `nil` when missing; `manifest` maps each vendored name to its hash; `reference` maps each
  family script to its bytes, or is `nil` when the reference isn't checked.
  """
  def problems(copies, manifest, reference) do
    manifest_problems(copies, manifest) ++ reference_problems(copies, manifest, reference)
  end

  defp manifest_problems(_copies, manifest) when map_size(manifest) == 0,
    do: ["#{@manifest} lists no script: vendor them with --vendor"]

  defp manifest_problems(copies, manifest) do
    for {name, expected} <- Enum.sort(manifest),
        problem = copy_problem(name, Map.get(copies, name), expected),
        do: problem
  end

  defp copy_problem(name, nil, _expected),
    do: "ci/#{name} is missing: vendor it again (--vendor)"

  defp copy_problem(name, bytes, expected) do
    if hash(bytes) == expected,
      do: nil,
      else:
        "ci/#{name} differs from the family copy it was vendored as: a change belongs in claude-tools' macaw_ci/#{name}, then vendor it again"
  end

  defp reference_problems(_copies, _manifest, nil), do: []

  defp reference_problems(copies, manifest, reference) do
    unlisted =
      for name <- Enum.sort(Map.keys(reference)),
          not Map.has_key?(manifest, name),
          do: "ci/#{name}: the family's script is not vendored: vendor it (--vendor)"

    gone =
      for name <- Enum.sort(Map.keys(manifest)),
          not Map.has_key?(reference, name),
          do: "ci/#{name} is no longer a family script: remove it and vendor again"

    behind =
      for {name, bytes} <- Enum.sort(reference),
          Map.has_key?(manifest, name),
          copy = Map.get(copies, name),
          copy != nil and copy != bytes,
          do: "ci/#{name} differs from the reference: vendor it again (--vendor)"

    unlisted ++ gone ++ behind
  end

  @doc "The reference's scripts, `{:ok, %{name => bytes}}`, or why it can't be read."
  def reference(dir) do
    if File.dir?(dir) do
      {:ok,
       for(
         name <- File.ls!(dir),
         String.ends_with?(name, ".exs"),
         into: %{},
         do: {name, File.read!(Path.join(dir, name))}
       )}
    else
      {:error,
       "no family reference at #{dir}: set MACAW_CI_REFERENCE or pass DIR (a release needs it)"}
    end
  end

  @doc "The manifest under `root`: `%{name => hash}`, empty when there is none."
  def manifest(root) do
    path = Path.join(root, @manifest)

    if File.exists?(path) do
      {manifest, _binding} = Code.eval_file(path)
      manifest
    else
      %{}
    end
  end

  @doc "Every problem of the copies under `root`, against `reference` when given."
  def check(root, reference) do
    manifest = manifest(root)
    names = Map.keys(manifest) ++ Map.keys(reference || %{})

    copies =
      Map.new(names, fn name ->
        case File.read(Path.join([root, "ci", name])) do
          {:ok, bytes} -> {name, bytes}
          {:error, _} -> {name, nil}
        end
      end)

    problems(copies, manifest, reference)
  end

  @doc "Copy every reference script into `root`'s ci/ and write the manifest of their hashes."
  def vendor(root, reference) do
    for {name, bytes} <- reference, do: File.write!(Path.join([root, "ci", name]), bytes)

    entries =
      for {name, bytes} <- Enum.sort(reference),
          do: "  #{inspect(name)} => #{inspect(hash(bytes))}"

    File.write!(Path.join(root, @manifest), """
    # The Macaw family's CI scripts vendored into ci/, each with the SHA-256 it had when it
    # was vendored, read by ci/vendored.exs (spec/00 §3, macaw_data#165). Written by
    # `elixir ci/vendored.exs --vendor`; never edited by hand.
    %{
    #{Enum.join(entries, ",\n")}
    }
    """)
  end

  defp reference_dir([dir]), do: Path.expand(dir)

  defp reference_dir([]),
    do: Path.expand(System.get_env("MACAW_CI_REFERENCE") || @default_reference)

  def main(argv) do
    case argv do
      [] ->
        report(check(File.cwd!(), nil), "every vendored copy is the one its manifest names")

      ["--reference" | dir] when length(dir) < 2 ->
        case reference(reference_dir(dir)) do
          {:ok, reference} ->
            report(
              check(File.cwd!(), reference),
              "every vendored copy is the family's current one"
            )

          {:error, why} ->
            report([why], "")
        end

      ["--vendor" | dir] when length(dir) < 2 ->
        case reference(reference_dir(dir)) do
          {:ok, reference} ->
            vendor(File.cwd!(), reference)
            IO.puts("vendored #{map_size(reference)} scripts; review the diff and commit it")

          {:error, why} ->
            report([why], "")
        end

      _other ->
        IO.puts(:stderr, "usage: elixir ci/vendored.exs [--reference [DIR] | --vendor [DIR]]")
        System.halt(2)
    end
  end

  defp report([], ok), do: IO.puts("vendored OK: " <> ok)

  defp report(problems, _ok) do
    Enum.each(problems, &IO.puts(:stderr, "vendored: " <> &1))
    System.halt(1)
  end
end

unless Application.get_env(:ci, :ci_no_main), do: Vendored.main(System.argv())
