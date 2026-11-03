defmodule Macaw.Data.Options do
  @moduledoc false
  # A function's keyword options held to the ones it takes (spec/00 §5): every key it
  # does not take is a fault, `{[key], :unknown_key}`, never a raise, as
  # `Keyword.validate!/2` would. The options come back with the defaults filled in.

  @doc false
  @spec known(term(), keyword()) :: {:ok, keyword()} | {:error, [{[term()], term()}, ...]}
  def known(opts, defaults) when is_list(opts) do
    case for(item <- opts, fault = fault(item, defaults), do: fault) do
      [] -> {:ok, Keyword.merge(defaults, opts)}
      faults -> {:error, faults}
    end
  end

  def known(_opts, _defaults), do: {:error, [{[], {:type, :keyword}}]}

  @doc false
  # A constructor's fields, given as a list of pairs or a map, as a map: `{:ok, map}`, or
  # `{[], {:type, :keyword}}` for a list holding anything but pairs, or a struct, which
  # `Map.new/1` would raise on (macaw_data#159). A key it does not take is the caller's
  # to refuse, by name.
  @spec fields(list() | map()) :: {:ok, map()} | {:error, [{[], {:type, :keyword}}, ...]}
  def fields(fields) when is_map(fields) and not is_struct(fields), do: {:ok, fields}

  def fields(fields) when is_list(fields) do
    if Enum.all?(fields, &match?({_key, _value}, &1)),
      do: {:ok, Map.new(fields)},
      else: {:error, [{[], {:type, :keyword}}]}
  end

  def fields(_struct), do: {:error, [{[], {:type, :keyword}}]}

  defp fault({key, _value}, defaults) when is_atom(key) do
    if Keyword.has_key?(defaults, key), do: nil, else: {[key], :unknown_key}
  end

  defp fault(_item, _defaults), do: {[], {:type, :keyword}}
end
