defmodule Macaw.Data.Derived.Join do
  @moduledoc """
  Joined fields (spec/02 §1.4): a reader of an input reads each per-identity source's
  answer for its own identity. Its rows carry, beside their own fields, every output
  field but the identity, named `"<id>.<field>"`, a string, never an atom, `nil` where the
  output holds nothing for the row's entity; its schema describes them as the outputs do.

  Which sources a reader sees is its owner's to decide; on a Macaw page, `macaw_compose`'s.
  Ported from visualize's `Visualize.VirtualSource.Join`, whose names were atoms.

      iex> alias Macaw.Data.Schema
      iex> hosts = Schema.new!(%{"host" => %{type: :category, identity: true}, "cpu" => %{type: :number}})
      iex> health = Schema.new!(%{"host" => %{type: :category, identity: true}, "state" => %{type: :category}})
      iex> outputs = [{"health", health, [%{"host" => "a", "state" => "ok"}]}]
      iex> Macaw.Data.Derived.Join.join([%{"host" => "a", "cpu" => 3}, %{"host" => "b", "cpu" => 9}], hosts, outputs)
      [%{"host" => "a", "cpu" => 3, "health.state" => "ok"}, %{"host" => "b", "cpu" => 9, "health.state" => nil}]
  """

  alias Macaw.Data.{Schema, Table}

  @typedoc "A per-identity source's id, its output schema and its last good output rows."
  @type output :: {String.t(), Schema.t(), [map()]}

  @doc "The rows with every output's fields for their identity (spec/02 §1.4)."
  @spec join([map()], Schema.t(), [output()]) :: [map()]
  def join(rows, %Schema{} = _schema, []), do: rows

  def join(rows, %Schema{} = schema, outputs) when is_list(rows) do
    indexes =
      for {id, output, answer} <- outputs do
        index = Map.new(answer, &{norm(Schema.identity(output, &1)), &1})
        {fields(id, output), index}
      end

    Enum.map(rows, fn row ->
      identity = norm(Schema.identity(schema, row))

      Enum.reduce(indexes, row, fn {fields, index}, row ->
        answer = Map.get(index, identity, %{})

        Enum.reduce(fields, row, fn {field, joined}, row ->
          Map.put(row, joined, Table.get(answer, field))
        end)
      end)
    end)
  end

  @doc """
  The input's schema with each joined field described as its output does, without
  `identity` or `window` (spec/02 §1.4); as it is with no output.
  """
  @spec schema(Schema.t(), [{String.t(), Schema.t()} | output()]) :: Schema.t()
  def schema(%Schema{} = schema, []), do: schema

  def schema(%Schema{} = schema, outputs) do
    joined =
      for output <- outputs,
          {id, out} = {elem(output, 0), elem(output, 1)},
          {field, name} <- fields(id, out),
          {:ok, description} = Schema.fetch(out, field),
          into: %{},
          do: {name, Map.drop(description, [:identity, :window])}

    Schema.new!(Map.merge(schema.fields, joined))
  end

  defp fields(id, output) do
    identity = output |> Schema.identity() |> Enum.map(&to_string/1)

    for {field, _description} <- Enum.sort(output.fields),
        to_string(field) not in identity,
        do: {field, "#{id}.#{field}"}
  end

  defp norm(identity) when is_map(identity),
    do: Map.new(identity, fn {field, value} -> {to_string(field), value} end)

  defp norm(identity), do: identity
end
