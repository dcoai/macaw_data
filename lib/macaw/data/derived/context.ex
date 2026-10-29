defmodule Macaw.Data.Derived.Context do
  @moduledoc """
  The context a derived source's function of two arguments is called with (spec/02 §2.3):
  each input's schema as data and its delivery's served facts. It holds no clock and no
  variables: a variable is an input like any other.

  Every name is a string: a field's, a description's key, a value entry's key. A value is
  the term the schema or the delivery holds, read through `value`: a stored function's by
  the rule its literals follow (a word's atom, else the string), a host's as given.

      iex> alias Macaw.Data.{Delivery, Schema}
      iex> schema = Schema.new!(%{cpu: %{type: :number, bounds: [0, 100]}})
      iex> delivery = Delivery.new([%{cpu: 3}], served: [window: [0, 10], capped: true])
      iex> Macaw.Data.Derived.Context.new([%{key: "hosts", delivery: delivery, schema: schema}])
      %{"inputs" => %{"hosts" => %{"schema" => %{"cpu" => %{"bounds" => [0, 100], "type" => :number}},
        "window" => [0, 10], "resolution" => nil, "capped" => true}}}

  Ported from visualize's `Visualize.VirtualSource.Context`, its `"vars"` left out
  (spec/02 §2.3).
  """

  alias Macaw.Data.{Delivery, Schema}

  @typedoc "An input as the owner gathered it: its key, its delivery and its schema."
  @type input :: %{key: term(), delivery: Delivery.t(), schema: Schema.t()}

  @doc """
  The context of the inputs: `key` gives an input's key as the first argument keys it
  (its string by default), `value` a value as the function reads it (as given by default).
  """
  @spec new([input()], (term() -> term()), (term() -> term())) :: map()
  def new(inputs, key \\ &to_string/1, value \\ & &1) when is_list(inputs) do
    %{"inputs" => Map.new(inputs, &{key.(&1.key), input(&1, value)})}
  end

  defp input(%{delivery: %Delivery{served: served}, schema: %Schema{} = schema}, value) do
    %{
      "schema" => schema(schema, value),
      "window" => term(served.window, value),
      "resolution" => term(served.resolution, value),
      "capped" => served.capped
    }
  end

  @doc """
  A schema as data, as a term: each field's name its string, each description's keys
  their strings, a value entry a map of its keys' strings, and every value read through
  `value`.
  """
  @spec schema(Schema.t(), (term() -> term())) :: map()
  def schema(%Schema{fields: fields}, value \\ & &1) do
    Map.new(fields, fn {name, description} ->
      {name, Map.new(description, &description(&1, value))}
    end)
  end

  defp description({:values, values}, value) when is_list(values),
    do: {"values", Enum.map(values, &entry(&1, value))}

  defp description({key, term}, value), do: {to_string(key), term(term, value)}

  defp entry(entry, value) when is_map(entry) and not is_struct(entry),
    do: Map.new(entry, fn {key, term} -> {to_string(key), term(term, value)} end)

  defp entry(term, value), do: term(term, value)

  # A value within a term: a map's keys and values (a `status` maps values to roles), a
  # list's and a tuple's elements; a struct (an instant, a literal color) and a typed
  # color are values whole, so a color reaches the function as the term it is.
  defp term(map, value) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {term(k, value), term(v, value)} end)

  defp term(list, value) when is_list(list), do: Enum.map(list, &term(&1, value))

  defp term(tuple, value) when is_tuple(tuple) do
    if Schema.color?(tuple),
      do: tuple,
      else: tuple |> Tuple.to_list() |> Enum.map(&term(&1, value)) |> List.to_tuple()
  end

  defp term(other, value), do: value.(other)
end
