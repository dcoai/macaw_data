defmodule Macaw.Data.Derived.Form.Tags do
  @moduledoc false
  # The tag table of a derived source's map form (spec/02 §1.5): the kernel's tags and the
  # source's own, an input `$input`, a source's name `$source` and `per`'s `$identity`.
  use Macaw.Layers.Tags, live: ~w($input $source $identity)
end

defmodule Macaw.Data.Derived.Form do
  @moduledoc false
  # A derived source as a document of `macaw_layers`' JSON adapter (spec/02 §1.5): the
  # `Macaw.Layers.Form` and `Macaw.Layers.Version` callbacks, and the source's value and map
  # form each way. The kernel writes and reads every term (names as strings, `per`'s
  # `:identity` a `$atom`, times `$time`); this type writes its tuples under its own tags,
  # and the output schema through `Macaw.Data.Schema`'s own adapter. `Macaw.Data.Derived`
  # holds the public functions and judges what is read with `new/1`.

  @behaviour Macaw.Layers.Form
  @behaviour Macaw.Layers.Version

  alias Macaw.Data.Schema
  alias Macaw.Layers.{Fault, Version, Vocabulary}
  alias Macaw.Layers.Form, as: Adapter

  @keys ~w(id from schema elixir function per last window box region latest west south east north)a

  @doc false
  # The source's map form: `{:ok, map}`, or every value without a form, by path.
  def to_map(source) do
    value =
      source
      |> Map.from_struct()
      |> Map.delete(:schema)
      |> Map.reject(fn {_key, value} -> value == nil end)

    with {:ok, map} <- Adapter.to_map(value, __MODULE__),
         do: {:ok, Map.put(map, "schema", Schema.to_map(source.schema))}
  end

  @doc false
  # The source's JSON form, stamped with this type's version.
  def to_json(source) do
    with {:ok, map} <- to_map(source),
         do: {:ok, JSON.encode!(Map.put(map, Version.stamp(), current()))}
  end

  @doc false
  # A map form or a JSON document through the gates to the value it holds, for `new/1` to
  # judge: `{:ok, value}`, or the faults of the first gate that refuses it, else every fault
  # of reading the value and the schema.
  def read(input, opts) do
    with {:ok, map} <- Adapter.gates(input, __MODULE__, Keyword.take(opts, [:limits])) do
      {schema, map} = map |> Map.delete(Version.stamp()) |> Map.pop("schema", :absent)

      case {Adapter.from_map(map, __MODULE__), schema(schema)} do
        {{:ok, value}, {:ok, schema}} -> {:ok, put_schema(value, schema)}
        {value, schema} -> {:error, Fault.sort(faults(value) ++ faults(schema))}
      end
    end
  end

  # The output schema is read by its own adapter, its faults under `[:schema]`.
  defp schema(:absent), do: {:ok, :absent}

  defp schema(form) do
    case Schema.from_map(form) do
      {:ok, schema} -> {:ok, schema}
      {:error, faults} -> {:error, for({path, reason} <- faults, do: {[:schema | path], reason})}
    end
  end

  defp put_schema(value, :absent), do: value
  defp put_schema(value, schema), do: Map.put(value, :schema, schema)

  defp faults({:ok, _value}), do: []
  defp faults({:error, faults}), do: faults

  # -- the behaviors -----------------------------------------------------------------------

  @impl Version
  def current, do: 1

  # The line starts at 1: no document is older.
  @impl Version
  def step(document, _from), do: {:ok, document}

  @impl Adapter
  def tags, do: Macaw.Data.Derived.Form.Tags
  @impl Adapter
  def keys, do: Vocabulary.table(@keys)
  @impl Adapter
  def atoms, do: Vocabulary.table([:identity])

  # An input `{name, window}` as `{"$input": [name, window]}`, a source's name
  # `{"$source": name}`, and `{:identity, input}` as `{"$identity": input}`, each part in
  # its own form. A part with no form leaves the term to the kernel, which refuses it at
  # its path.
  @impl Adapter
  def encode_value({:source, name}) when is_binary(name), do: {:ok, %{"$source" => name}}
  def encode_value({:identity, name}), do: tagged("$identity", name)

  def encode_value({name, window})
      when (is_binary(name) or is_list(name) or is_tuple(name)) and
             (is_nil(window) or is_map(window)),
      do: tagged("$input", [name, window])

  def encode_value(_term), do: :default

  defp tagged(tag, payload) do
    case Adapter.encode_term(payload, __MODULE__, [{:tag, tag}]) do
      {:ok, form} -> {:ok, %{tag => form}}
      {:error, _faults} -> :default
    end
  end

  @impl Adapter
  def decode_value("$input", [name, window]), do: {:ok, {name, window}}
  def decode_value("$source", name) when is_binary(name), do: {:ok, {:source, name}}
  def decode_value("$identity", name), do: {:ok, {:identity, name}}
  def decode_value(_tag, _payload), do: :default

  # A request window's region is keyed by its input's fields: names, never this type's keys.
  @impl Adapter
  def name_map?([{:tag, "$input"}, 1, :region]), do: true
  def name_map?(_path), do: false
end
