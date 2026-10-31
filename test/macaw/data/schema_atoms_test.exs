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

  @tag verifies: "schema-json-read"
  test "reading an entry's color makes no atom, of a color's name, a ramp's or an unknown tag" do
    [color, ramp, tag, op] = names = for _ <- 1..4, do: fresh()

    entries =
      [
        ~s({"value":"a","color":{"$color":"#{color}"}}),
        ~s({"value":"b","color":{"$alpha":[{"$color":"#{color}"},0.5]}}),
        ~s({"value":"c","color":{"$ramp":["#{ramp}",0.5]}}),
        ~s({"value":"d","color":{"$#{tag}":"#{color}"}}),
        ~s({"value":"e","color":{"$blend":[{"$#{op}":[{"$color":"x"},0.5]}]}})
      ]
      |> Enum.join(",")

    # The first three are colors and read, a ramp by any name in a theme's grammar
    # (macaw_layers 0.3.1); the rest are no color, refused as one.
    assert {:error, faults} =
             Schema.from_json(~s([["s",{"type":"category","values":[#{entries}]}]]))

    assert Enum.map(faults, &elem(&1, 0)) ==
             for(i <- 3..4, do: ["s", :values, i, :color])

    assert made(names) == []
  end
end
