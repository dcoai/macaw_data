defmodule Macaw.Data.SpecVersionsTest do
  # A spec names the libraries it builds on, never their versions (#238, as macaw's
  # dco-tek/macaw/macaw#297): versions live in mix.exs, `.tool-versions` and the CHANGELOG,
  # and a version in a spec goes stale with the next release. A document format's own
  # version and an external standard's (UCUM's essence table) are not library versions.
  use ExUnit.Case, async: true

  @libraries ~w(macaw[a-z_]* surfex Nx Zigler Zig Elixir Erlang OTP Phoenix LiveView StreamData)

  # `vX.Y`, a library then a version, a requirement, and a bare release after `since`,
  # `from` or `until`, which a section number (§1.1.4) never follows.
  @version Regex.compile!(
             "\\bv\\d+\\.\\d+(\\.\\d+)?\\b" <>
               "|\\b(#{Enum.join(@libraries, "|")})`?\\s+v?\\d+\\.\\d+" <>
               "|~>\\s*\\d" <>
               "|\\b(since|from|until)\\s+\\d+\\.\\d+\\.\\d+\\b"
           )

  test "no spec file names a library version" do
    found =
      for path <- Path.wildcard("spec/**/*.md"),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          match <- Regex.scan(@version, line) |> Enum.map(&hd/1),
          do: "#{path}:#{n}: #{match}"

    assert found == [], "library versions in the spec:\n" <> Enum.join(found, "\n")
  end

  test "the guard finds each kind of version, and none of what is kept" do
    for line <- [
          "done, v0.2.0;",
          "moves to macaw_layers 0.5.0 (#216)",
          "on Elixir 1.20",
          "(`.tool-versions`: Zigler 0.16.0, Zig 0.16.0)",
          ~s({:zigler, "~> 0.16.0", runtime: false}),
          "answered as `{:ok, digest}` since 0.5.0"
        ] do
      assert Regex.match?(@version, line), line
    end

    for line <- [
          "its essence table, version 2.2 of 2024-06-17",
          ~s({"$version": 1, "fields": []}),
          "([01 §1.1.4](01-sources.md#sources-table-delta), §2.1 of UCUM's specification)",
          "a factor of 6.02214076e23, from 1.0 to 2.0"
        ] do
      refute Regex.match?(@version, line), line
    end
  end
end
