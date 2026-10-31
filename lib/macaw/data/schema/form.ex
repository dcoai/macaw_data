defmodule Macaw.Data.Schema.Form do
  @moduledoc false
  # A schema's JSON form (spec/01 §1.11): an adapter at the edge, which the schema's version
  # never goes through (§1.10). `Macaw.Data.Schema` holds the public functions, `to_map/1`,
  # `to_json/1`, `from_map/1` and `from_json/2`, each delegating here, and judges what is
  # read with `Schema.new/1`. The words it reads are the schema's own vocabularies, each read
  # through its closed table, and an entry's color is read by the colors' own reader, so no
  # atom is made from a document.

  alias Macaw.Data.{Quantity, Schema}
  alias Macaw.Layers.{Color, Limits, Scan, Vocabulary}

  @doc false
  @spec to_map(Schema.t()) :: [[term()]]
  def to_map(%Schema{fields: fields}), do: json_form(fields)

  @doc false
  @spec to_json(Schema.t()) :: String.t()
  def to_json(%Schema{} = schema), do: JSON.encode!(to_map(schema))

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
    limits = Limits.new(Keyword.get(opts, :limits, []))

    cond do
      byte_size(json) > limits.bytes ->
        {:error, [{[], {:limit, :bytes, limits.bytes, byte_size(json)}}]}

      match?({:error, _}, Scan.scan(json, limits)) ->
        {:error, fault} = Scan.scan(json, limits)
        {:error, [fault]}

      true ->
        case JSON.decode(json) do
          {:ok, map} -> from_map(map)
          {:error, reason} -> {:error, [{[], {:json, inspect(reason)}}]}
        end
    end
  end

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
