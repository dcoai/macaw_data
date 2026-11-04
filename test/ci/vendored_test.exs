defmodule VendoredTest do
  @moduledoc """
  The vendored-copy guard, `ci/vendored.exs` (spec/00 §3, macaw_data#162, #165): the
  family's CI scripts in ci/ are the copies they were vendored as, and at a release the
  family's current ones. Its rules are shown on small trees; CI's `vendored` job runs it
  over this repository, and `mix hex.publish` runs its `--reference` form.
  """
  use ExUnit.Case, async: true

  Application.put_env(:ci, :ci_no_main, true)
  Code.require_file("ci/vendored.exs")

  @moduletag :tmp_dir

  @family %{"a.exs" => "IO.puts(:a)\n", "b.exs" => "IO.puts(:b)\n"}

  # A reference directory holding `scripts`, and a library root beside it.
  defp tree(dir, scripts) do
    reference = Path.join(dir, "macaw_ci")
    root = Path.join(dir, "lib_root")
    File.mkdir_p!(reference)
    File.mkdir_p!(Path.join(root, "ci"))
    for {name, bytes} <- scripts, do: File.write!(Path.join(reference, name), bytes)
    {root, reference}
  end

  defp reference!(dir) do
    {:ok, reference} = Vendored.reference(dir)
    reference
  end

  @tag verifies: "data-dependencies-vendored"
  test "this library's copies are the ones its manifest names, and every family script is listed" do
    assert Vendored.check(File.cwd!(), nil) == []

    assert Map.keys(Vendored.manifest(File.cwd!())) |> Enum.sort() ==
             [
               "advisories.exs",
               "raises.exs",
               "release_guard.exs",
               "spec_links.exs",
               "vendored.exs"
             ]
  end

  @tag verifies: "data-dependencies-vendored"
  test "--vendor copies the reference in and writes a manifest both checks pass", %{
    tmp_dir: dir
  } do
    {root, reference} = tree(dir, @family)
    Vendored.vendor(root, reference!(reference))

    assert File.read!(Path.join(root, "ci/a.exs")) == @family["a.exs"]
    assert Vendored.check(root, nil) == []
    assert Vendored.check(root, reference!(reference)) == []
  end

  @tag verifies: "data-dependencies-vendored"
  test "an edited copy, a missing copy and an empty manifest fail in CI", %{tmp_dir: dir} do
    {root, reference} = tree(dir, @family)
    Vendored.vendor(root, reference!(reference))

    File.write!(Path.join(root, "ci/a.exs"), "IO.puts(:edited)\n")
    File.rm!(Path.join(root, "ci/b.exs"))

    assert Vendored.check(root, nil) == [
             "ci/a.exs differs from the family copy it was vendored as: a change belongs in claude-tools' macaw_ci/a.exs, then vendor it again",
             "ci/b.exs is missing: vendor it again (--vendor)"
           ]

    File.rm!(Path.join(root, "ci/vendored_manifest.exs"))

    assert Vendored.check(root, nil) == [
             "ci/vendored_manifest.exs lists no script: vendor them with --vendor"
           ]
  end

  @tag verifies: "data-dependencies-vendored"
  test "at a release, a reference that moved on, gained a script or dropped one fails", %{
    tmp_dir: dir
  } do
    {root, reference} = tree(dir, @family)
    Vendored.vendor(root, reference!(reference))

    File.write!(Path.join(reference, "a.exs"), "IO.puts(:newer)\n")
    File.write!(Path.join(reference, "c.exs"), "IO.puts(:c)\n")
    File.rm!(Path.join(reference, "b.exs"))

    # CI, without the reference, can't see it: the copies are still as vendored.
    assert Vendored.check(root, nil) == []

    assert Vendored.check(root, reference!(reference)) == [
             "ci/c.exs: the family's script is not vendored: vendor it (--vendor)",
             "ci/b.exs is no longer a family script: remove it and vendor again",
             "ci/a.exs differs from the reference: vendor it again (--vendor)"
           ]
  end

  @tag verifies: "data-dependencies-vendored"
  test "a reference that isn't there is a failure, never a skipped check", %{tmp_dir: dir} do
    assert {:error, why} = Vendored.reference(Path.join(dir, "absent"))
    assert why =~ "no family reference at"
  end
end
