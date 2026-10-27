defmodule Macaw.Data.EventTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Event

  @now ~U[2026-10-27 12:00:00Z]

  defp valid(extra \\ %{}),
    do: Map.merge(%{name: "pick", instance: "cell-1", initiator: :visitor, time: @now}, extra)

  test "the fields are spec 02 §8's, in its order" do
    assert Event.fields() ==
             [
               :name,
               :instance,
               :element,
               :identity,
               :value,
               :initiator,
               :time,
               :point,
               :modifiers,
               :row
             ]

    assert Event.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
             Enum.sort(Event.fields())
  end

  test "new/1 builds a full event, defaulting element, modifiers and the optional fields" do
    assert {:ok, %Event{} = e} =
             Event.new(valid(%{identity: %{"service" => "api"}, row: %{"latency" => 12}}))

    assert e.element == %{frame: nil, item: nil, path: []}
    assert e.modifiers == []
    assert e.point == nil

    assert {:ok, e} =
             Event.new(
               name: "brush",
               instance: "c",
               initiator: :system,
               time: @now,
               element: %{item: "bar-3", path: ["bar-3", "frame"]}
             )

    assert e.element == %{frame: nil, item: "bar-3", path: ["bar-3", "frame"]}
  end

  test "new/1 names every bad field at once, unknown fields included" do
    assert {:error, faults} =
             Event.new(%{
               name: "",
               instance: nil,
               initiator: :robot,
               time: "now",
               point: {1, :x},
               modifiers: [:hyper],
               element: %{path: :nope},
               row: [1],
               cell: "old field"
             })

    assert Keyword.keys(faults) |> Enum.sort() ==
             Enum.sort([
               :cell,
               :name,
               :instance,
               :initiator,
               :time,
               :point,
               :modifiers,
               :element,
               :row
             ])

    assert faults[:cell] == "is not an event field"
    assert faults[:initiator] == "must be :visitor or :system"
  end

  test "the recorded form drops the row and the point, and keeps the rest" do
    {:ok, e} =
      Event.new(
        valid(%{point: {10, 20}, row: %{"secret" => 1}, identity: %{"id" => 7}, value: :v})
      )

    r = Event.recordable(e)
    refute Map.has_key?(r, :row)
    refute Map.has_key?(r, :point)
    assert r.identity == %{"id" => 7}
    assert r.value == :v
    assert Map.keys(r) |> Enum.sort() == Enum.sort(Event.fields() -- [:row, :point])
  end

  property "no row value or point ever survives into the recorded form" do
    check all(
            row <- map_of(string(:alphanumeric, min_length: 1), string(:printable, min_length: 8)),
            x <- float(),
            y <- float(),
            marker = "row-marker-#{System.unique_integer([:positive])}"
          ) do
      row = Map.put(row, "marker", marker)
      {:ok, e} = Event.new(valid(%{row: row, point: {x, y}}))
      text = e |> Event.recordable() |> inspect(limit: :infinity, printable_limit: :infinity)
      refute text =~ marker
      refute Map.has_key?(Event.recordable(e), :point)
    end
  end

  property "every well-formed event is accepted" do
    check all(
            name <- string(:alphanumeric, min_length: 1),
            instance <- string(:alphanumeric, min_length: 1),
            initiator <- member_of([:visitor, :system]),
            modifiers <- list_of(member_of([:shift, :alt, :ctrl, :meta]), max_length: 4),
            path <- list_of(string(:alphanumeric), max_length: 4)
          ) do
      assert {:ok, _} =
               Event.new(%{
                 name: name,
                 instance: instance,
                 initiator: initiator,
                 time: @now,
                 modifiers: modifiers,
                 element: %{path: path}
               })
    end
  end
end
