defmodule Macaw.Data.Derived.Form do
  @moduledoc false
  # A derived source's map and JSON forms (spec/02 §1.5): every name a string, a pair list
  # wherever a JSON object's keys would lose a name's spelling, times `{"$time": …}`, the
  # schema in its own map form. `read/1` turns the map form back into the keys `new/1`
  # checks; `Macaw.Data.Derived` holds the public functions.

  alias Macaw.Data.Schema
  alias Macaw.Layers.{Limits, Scan}

  @keys [:id, :from, :schema, :elixir, :function, :per]

  @doc false
  def to_map(source) do
    %{
      "id" => source.id,
      "from" =>
        Enum.map(source.from, fn {name, window} -> [name_form(name), window_form(window)] end),
      "schema" => Schema.to_map(source.schema)
    }
    |> put_form("elixir", source.elixir)
    |> put_form("function", source.function)
    |> put_form("per", per_form(source.per))
  end

  defp put_form(map, _key, nil), do: map
  defp put_form(map, key, value), do: Map.put(map, key, value)

  defp name_form({:source, name}), do: %{"source" => name}
  defp name_form(name), do: name

  defp window_form(nil), do: nil
  defp window_form(%{last: n}), do: %{"last" => n}

  defp window_form(%{} = window) do
    Map.new(window, fn
      {:window, range} ->
        {"window", Enum.map(range, &time_form/1)}

      {:box, box} ->
        {"box", Map.new(box, fn {k, v} -> {Atom.to_string(k), v} end)}

      {:region, region} ->
        {"region",
         region |> Enum.sort() |> Enum.map(fn {f, r} -> [f, Enum.map(r, &time_form/1)] end)}

      {:latest, latest} ->
        {"latest", latest}
    end)
  end

  defp time_form(%DateTime{} = time), do: %{"$time" => DateTime.to_iso8601(time)}
  defp time_form(other), do: other

  defp per_form(nil), do: nil
  defp per_form(:identity), do: "identity"
  defp per_form({:identity, name}), do: ["identity", name_form(name)]

  @doc false
  # JSON read through the limits and the scan, then decoded to a map.
  def decode(json, opts) when is_binary(json) do
    limits = Limits.new(Keyword.get(opts, :limits, []))

    cond do
      byte_size(json) > limits.bytes ->
        {:error, [{[], {:limit, :bytes, limits.bytes, byte_size(json)}}]}

      match?({:error, _}, Scan.scan(json, limits)) ->
        {:error, fault} = Scan.scan(json, limits)
        {:error, [fault]}

      true ->
        case JSON.decode(json) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, _other} -> {:error, [{[], {:type, :derived}}]}
          {:error, reason} -> {:error, [{[], {:json, inspect(reason)}}]}
        end
    end
  end

  # The map form read into a source's keys: string keys mean the map form, whose names,
  # windows, schema and per are read back; atom keys are taken as Elixir gives them.
  @form_keys Map.new(@keys, &{Atom.to_string(&1), &1})

  @doc false
  def read(map) do
    if map |> Map.keys() |> Enum.any?(&is_binary/1),
      do: read_map_form(map),
      else: {:ok, map}
  end

  defp read_map_form(map) do
    {known, unknown} = Enum.split_with(map, fn {k, _v} -> Map.has_key?(@form_keys, k) end)

    case unknown do
      [] ->
        Enum.reduce_while(known, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
          key = Map.fetch!(@form_keys, k)

          case read_value(key, v) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
            {:error, errors} -> {:halt, {:error, errors}}
          end
        end)

      _keys ->
        {:error, for({k, _v} <- unknown, do: {[k], :unknown_key})}
    end
  end

  defp read_value(:from, inputs) when is_list(inputs) do
    {:ok,
     Enum.map(inputs, fn
       [name, window] -> {read_name(name), read_window(window)}
       other -> other
     end)}
  end

  defp read_value(:schema, pairs) when is_list(pairs) do
    case Schema.from_map(pairs) do
      {:ok, schema} ->
        {:ok, schema}

      {:error, errors} ->
        {:error, Enum.map(errors, fn {path, reason} -> {[:schema | path], reason} end)}
    end
  end

  defp read_value(:per, "identity"), do: {:ok, :identity}
  defp read_value(:per, ["identity", name]), do: {:ok, {:identity, read_name(name)}}
  defp read_value(_key, value), do: {:ok, value}

  defp read_name(%{"source" => name}), do: {:source, name}
  defp read_name(name), do: name

  defp read_window(nil), do: nil
  defp read_window(%{"last" => n} = window) when map_size(window) == 1, do: %{last: n}

  defp read_window(%{} = window) do
    keys = %{"window" => :window, "box" => :box, "region" => :region, "latest" => :latest}

    if window |> Map.keys() |> Enum.all?(&Map.has_key?(keys, &1)) do
      Map.new(window, fn
        {"window", range} when is_list(range) -> {:window, Enum.map(range, &read_time/1)}
        {"box", box} when is_map(box) -> {:box, read_box(box)}
        {"region", pairs} when is_list(pairs) -> {:region, read_region(pairs)}
        {k, v} -> {Map.fetch!(keys, k), v}
      end)
    else
      window
    end
  end

  defp read_window(other), do: other

  @box %{"west" => :west, "south" => :south, "east" => :east, "north" => :north}

  defp read_box(box) do
    if box |> Map.keys() |> Enum.all?(&Map.has_key?(@box, &1)),
      do: Map.new(box, fn {k, v} -> {Map.fetch!(@box, k), v} end),
      else: box
  end

  defp read_region(pairs) do
    if Enum.all?(pairs, &match?([field, range] when is_binary(field) and is_list(range), &1)),
      do: Map.new(pairs, fn [field, range] -> {field, Enum.map(range, &read_time/1)} end),
      else: pairs
  end

  defp read_time(%{"$time" => iso} = tag) when map_size(tag) == 1 do
    case DateTime.from_iso8601(iso) do
      {:ok, time, 0} -> time
      _other -> tag
    end
  end

  defp read_time(other), do: other
end
