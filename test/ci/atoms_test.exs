defmodule AtomGateTest do
  @moduledoc "The atom gate, `ci/atoms.exs` (spec/02 §6.5), ported from visualize's `vis.atoms` test."
  use ExUnit.Case, async: true

  Application.put_env(:ci, :ci_no_main, true)
  Code.require_file("ci/atoms.exs")

  @moduletag :tmp_dir

  defp lib(dir, text) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/x.ex"), text)
  end

  defp entry(match, count, class \\ :d),
    do: %{file: "lib/x.ex", match: match, count: count, class: class, reason: "bounded"}

  @tag verifies: "derived-atom-gate"
  test "the library holds no site the allowlist does not" do
    assert AtomGate.run(File.cwd!()) == []
  end

  @tag verifies: "derived-atom-gate"
  test "every way of making an atom from a string fails at its line", %{tmp_dir: dir} do
    lib(dir, """
    a = String.to_atom(s)
    b = :erlang.binary_to_atom(s, :utf8)
    c = List.to_atom(cs)
    d = :erlang.list_to_atom(cs)
    e = :"cell_\#{n}"
    f = String.to_existing_atom(s)
    # String.to_atom(s) in a comment makes none
    """)

    problems = AtomGate.run(dir, [])
    assert length(problems) == 5
    assert Enum.map(problems, &hd(String.split(&1, ": "))) == Enum.map(1..5, &"lib/x.ex:#{&1}")
  end

  @tag verifies: "derived-atom-gate"
  test "an allowlisted site passes, and an entry that no longer matches fails", %{tmp_dir: dir} do
    lib(dir, "a = :\"series_\#{k}\"\n")

    assert AtomGate.run(dir, [entry("series_", 1)]) == []
    assert [stale] = AtomGate.run(dir, [entry("series_", 2)])
    assert stale =~ "holds 1 line(s)"
    assert [_unallowed, _stale] = AtomGate.run(dir, [entry("style_", 1)])
  end

  @tag verifies: "derived-atom-gate"
  test "an entry needs a class and a reason", %{tmp_dir: dir} do
    lib(dir, "a = :\"series_\#{k}\"\n")
    assert [problem] = AtomGate.run(dir, [entry("series_", 1, :e)])
    assert problem =~ "an entry needs"
  end

  @tag verifies: "derived-atom-gate"
  test "a declared name is a string: an entry of class (b) or (c) fails", %{tmp_dir: dir} do
    lib(dir, "a = String.to_atom(name)\n")

    for class <- [:b, :c] do
      assert [problem] = AtomGate.run(dir, [entry("String.to_atom(name)", 1, class)])
      assert problem =~ "is a string"
    end
  end
end
