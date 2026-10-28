defmodule Macaw.Data.SchemaAtomsTest do
  # Checked on the document's own names, never the node's atom count (macaw_data#1).
  use ExUnit.Case, async: true

  import Macaw.Data.Test.Atoms
  alias Macaw.Data.Schema

  @tag verifies: "schema-json-read"
  test "reading a schema's JSON makes no atom, of a name, a state, a role or an unknown word" do
    [name, state, label, other, word, key] = names = for _ <- 1..6, do: fresh()

    Schema.from_json(
      ~s([["#{name}",{"type":"category","order":["#{state}"],"status":[["x","#{label}"]]}],) <>
        ~s(["#{other}",{"type":"#{word}","#{key}":1}]])
    )

    assert made(names) == []
  end
end
