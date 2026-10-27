defmodule Macaw.Data.SchemaAtomsTest do
  # The atom table is the node's: nothing else may run while it is counted.
  use ExUnit.Case, async: false

  alias Macaw.Data.Schema

  # A string no atom has been made of.
  defp fresh, do: "zz#{System.unique_integer([:positive])}s"

  @tag verifies: "schema-json-read"
  test "reading a schema's JSON makes no atom, of a name, a state, a role or an unknown word" do
    read = fn ->
      Schema.from_json(
        ~s([["#{fresh()}",{"type":"category","order":["#{fresh()}"],"status":[["x","#{fresh()}"]]}],) <>
          ~s(["#{fresh()}",{"type":"#{fresh()}","#{fresh()}":1}]])
      )
    end

    # Warm up: load every module the read reaches.
    read.()
    before = :erlang.system_info(:atom_count)
    for _ <- 1..200, do: read.()
    assert :erlang.system_info(:atom_count) == before
  end
end
