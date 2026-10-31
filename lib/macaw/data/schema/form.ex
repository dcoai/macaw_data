defmodule Macaw.Data.Schema.Form do
  @moduledoc false
  # A schema's JSON form (spec/01 §1.11): an adapter at the edge, which the schema's version
  # never goes through (§1.10). `Macaw.Data.Schema` holds the public functions, `to_map/1`,
  # `to_json/1`, `from_map/1` and `from_json/2`, each delegating here, and judges what is
  # read with `Schema.new/1`. The words it reads are the schema's own vocabularies, each read
  # through its closed table, and an entry's color is read by the colors' own reader, so no
  # atom is made from a document.
  #
  # The map form is the bare list of pairs, for a document that embeds a schema (a derived
  # source's `"schema"`), whose own stamp versions it. The JSON document is an object at its
  # root, `{"$version": 1, "fields": pairs}`, on its own version line (`Macaw.Layers.Version`),
  # read through the kernel's gates (`Macaw.Layers.Form.gates/3`) and no gate of its own.

  @behaviour Macaw.Layers.Version

  alias Macaw.Data.{Quantity, Schema}
  alias Macaw.Layers.{Color, Version, Vocabulary}
  alias Macaw.Layers.Form, as: Adapter

  @stamp Version.stamp()

  # The line starts at 1: no stamped document is older. The list written before the line
  # (macaw_data#84) is lifted to version 1 by its root, not by a step.
  @impl Version
  def current, do: 1

  @impl Version
  def step(document, _from), do: {:ok, document}

  @doc false
  @spec to_map(Schema.t()) :: [[term()]]
  def to_map(%Schema{fields: fields}), do: json_form(fields)

  @doc false
  @spec to_json(Schema.t()) :: String.t()
  def to_json(%Schema{} = schema),
    do: JSON.encode!(%{@stamp => current(), "fields" => to_map(schema)})

  @doc false
  @spec from_map(term()) :: {:ok, Schema.t()} | {:error, [Schema.error(), ...]}
  def from_map(pairs) when is_list(pairs) do
    if Enum.all?(pairs, &match?([name, d] when is_binary(name) and is_map(d), &1)),
      do: pairs |> Map.new(fn [name, d] -> {name, read_description(d)} end) |> Schema.new(),
      else: {:error, [{[], {:type, :schema}}]}
  end

  def from_map(_other), do: {:error, [{[], {:type, :schema}}]}

  @doc false
  @spec from_json(binary(), keyword()) :: {:ok, Schema.t()} | {:error, [Schema.error(), ...]}
  def from_json(json, opts \\ []) when is_binary(json) do
    gates = Keyword.take(opts, [:limits])

    with {:ok, document} <- json |> Adapter.gates(__MODULE__, gates) |> legacy(json, gates),
         do: fields(document)
  end

  # The kernel's gates refuse a root that is no object by its type, once its bytes and its
  # nesting are within the limits. A list there is the legacy document, the bare pairs
  # written before the version line: lifted to version 1, the version whose content it is,
  # and held to the gates again as that document's map form.
  defp legacy({:error, [{[], {:type, :map}}]} = refused, json, gates) do
    case JSON.decode(json) do
      {:ok, pairs} when is_list(pairs) ->
        Adapter.gates(%{@stamp => 1, "fields" => pairs}, __MODULE__, gates)

      _other ->
        refused
    end
  end

  defp legacy(gated, _json, _gates), do: gated

  # The document holds the stamp and the fields, and nothing else: another key, and no
  # fields, are the kernel's faults at the key.
  defp fields(%{"fields" => pairs} = document) do
    case document |> Map.keys() |> Kernel.--([@stamp, "fields"]) |> Enum.sort() do
      [] -> from_map(pairs)
      extra -> {:error, for(key <- extra, do: {[key], :unknown_key})}
    end
  end

  defp fields(_document), do: {:error, [{["fields"], :required}]}

  # Names, states and roles are strings already (`new/1`); the adapter writes the keys
  # and the words of the vocabulary as theirs.
  defp json_form(fields) do
    fields
    |> Enum.map(fn {name, description} -> [name, write_description(description)] end)
    |> Enum.sort_by(&hd/1)
  end

  defp write_description(description) do
    Map.new(description, fn
      {:values, values} -> {"values", Enum.map(values, &write_value/1)}
      {:status, status} -> {"status", status |> Enum.map(&Tuple.to_list/1) |> Enum.sort()}
      {key, value} -> {Atom.to_string(key), Schema.spell(value)}
    end)
  end

  defp write_value(%{} = entry),
    do: Map.new(entry, fn {key, value} -> {Atom.to_string(key), write_entry(key, value)} end)

  defp write_value(value), do: value

  # An entry's color in the colors' JSON form (`Macaw.Layers.Color.Form`): a literal as its
  # `$rgb`, a typed color by its tags. `new/1` admits only colors the form writes.
  defp write_entry(:color, color) do
    {:ok, form} = Color.Form.encode_value(color)
    form
  end

  defp write_entry(_key, value), do: value

  @attribute_table Vocabulary.table(Schema.attributes())
  @entry_table Vocabulary.table(Schema.entry_keys())
  @word_tables %{
    type: Vocabulary.table(Schema.vocabularies().type),
    polarity: Vocabulary.table(Schema.vocabularies().polarity),
    metric_kind: Vocabulary.table(Schema.vocabularies().metric_kind),
    quantity: Vocabulary.table(Quantity.all())
  }

  defp read_description(description) when is_map(description) do
    Map.new(description, fn {key, value} ->
      case Vocabulary.fetch(@attribute_table, key) do
        {:ok, :status} -> {:status, read_status(value)}
        {:ok, :values} when is_list(value) -> {:values, Enum.map(value, &read_value/1)}
        {:ok, word} when is_map_key(@word_tables, word) -> {word, read_word(word, value)}
        {:ok, key} -> {key, value}
        :error -> {key, value}
      end
    end)
  end

  defp read_description(other), do: other

  defp read_word(word, value) when is_binary(value),
    do: Vocabulary.read(@word_tables[word], value)

  defp read_word(_word, value), do: value

  defp read_status(pairs) when is_list(pairs) do
    if Enum.all?(pairs, &match?([_state, _role], &1)),
      do: Map.new(pairs, fn [state, role] -> {state, role} end),
      else: pairs
  end

  defp read_status(other), do: other

  defp read_value(entry) when is_map(entry) do
    Map.new(entry, fn {key, value} ->
      case Vocabulary.fetch(@entry_table, key) do
        {:ok, :color} -> {:color, read_color(value)}
        {:ok, key} -> {key, value}
        :error -> {key, value}
      end
    end)
  end

  defp read_value(value), do: value

  @color_tags Color.Form.tags()

  # A color's map form, read inside out by the colors' own reader (`Macaw.Layers.Color.Form`),
  # which makes no atom: each operand's form before the tag that holds it. A form it does
  # not read, and a bare string, stay as they are, for `new/1` to refuse as no color.
  defp read_color(%{} = form) when map_size(form) == 1 do
    [{tag, payload}] = Map.to_list(form)

    with true <- tag in @color_tags,
         {:ok, color} <- Color.Form.decode_value(tag, read_payload(payload)) do
      color
    else
      _unread -> form
    end
  end

  defp read_color(other), do: other

  defp read_payload(list) when is_list(list), do: Enum.map(list, &read_color/1)
  defp read_payload(payload), do: read_color(payload)
end
