defmodule Macaw.Data.Parameter do
  @moduledoc """
  A parameter: the one shape for every typed option, a source's or a component's
  (spec/01 §2.2).

      %{type: type, default: value, values: [value] | nil,
        legal_for: {slot, field, fact} | nil, bindable: false, doc: "…"}

  A parameter's `type` is a data-model type (`:time`, `:number`, `:category`, `:text`,
  `:color` or `:point`, spec/01 §1.2), `{:document, type}` for a nested document of a
  document type, or `:term`, a value its owner validates itself, allowed only for
  options migrated from untyped forms. `values` is a closed list of legal values;
  `legal_for` says the legal values follow from a bound slot's described schema, which
  the runtime that binds slots resolves (macaw_compose spec 05 §1.1); `bindable` says
  whether the value may be bound to state, closed by default.

  **A parameter with no `default` is required.** `validate/2` checks a map of given values
  against a map of parameters: every fault at once, by name, a missing one filled from its
  default.

  macaw_data owns the shape (the owner's decision, 2026-10-27): sources take parameters
  before any component exists, and macaw_compose's components use the same shape.
  """

  alias Macaw.Data.Schema

  @types [:time, :number, :category, :text, :color, :point]
  @keys [:type, :default, :values, :legal_for, :bindable, :doc]

  @typedoc "A parameter's type."
  @type type ::
          :time | :number | :category | :text | :color | :point | {:document, atom()} | :term

  @typedoc "A parameter."
  @type t :: %{
          required(:type) => type(),
          optional(:default) => term(),
          optional(:values) => [term()] | nil,
          optional(:legal_for) => {term(), term(), atom()} | nil,
          optional(:bindable) => boolean(),
          optional(:doc) => String.t()
        }

  @typedoc "A fault: the path to the value, and why."
  @type fault :: {list(), term()}

  @doc "The keys a parameter takes, `:type` first."
  @spec keys() :: [atom(), ...]
  def keys, do: @keys

  @doc """
  `:ok`, or every fault of a parameter declaration, each `{path, reason}` from the
  parameter: `[:type]` required and one of the types, `[:default]` and each of `[:values, i]`
  a value of the type, the default among `values` when both are given, `[:legal_for]` a
  `{slot, field, fact}`, `[:bindable]` a boolean, `[:doc]` a string, and no other key.

      iex> Macaw.Data.Parameter.check(%{type: :number, default: 5, doc: "bins"})
      :ok
      iex> Macaw.Data.Parameter.check(%{type: :category, values: ["a", "b"], default: "c"})
      {:error, [{[:default], :not_in_values}]}
  """
  @spec check(term()) :: :ok | {:error, [fault(), ...]}
  def check(parameter) when is_map(parameter) and not is_struct(parameter) do
    type = Map.get(parameter, :type)

    faults =
      Enum.flat_map(parameter, fn {key, value} -> key(key, value, type) end) ++
        if(Map.has_key?(parameter, :type), do: [], else: [{[:type], :required}]) ++
        in_values(parameter)

    case Enum.sort_by(faults, &elem(&1, 0)) do
      [] -> :ok
      faults -> {:error, faults}
    end
  end

  def check(_other), do: {:error, [{[], {:type, :parameter}}]}

  defp key(:type, type, _),
    do: if(type?(type), do: [], else: [{[:type], {:enum, @types ++ [:term]}}])

  defp key(:default, value, type),
    do:
      if(type?(type) and not conforms?(type, value), do: [{[:default], {:type, type}}], else: [])

  defp key(:values, nil, _type), do: []

  defp key(:values, [_ | _] = values, type) do
    for {v, i} <- Enum.with_index(values),
        type?(type),
        not conforms?(type, v),
        do: {[:values, i], {:type, type}}
  end

  defp key(:values, _other, _type), do: [{[:values], {:type, :values}}]
  defp key(:legal_for, nil, _type), do: []
  defp key(:legal_for, {_slot, _field, fact}, _type) when is_atom(fact), do: []
  defp key(:legal_for, _other, _type), do: [{[:legal_for], {:type, :legal_for}}]
  defp key(:bindable, b, _type) when is_boolean(b), do: []
  defp key(:bindable, _other, _type), do: [{[:bindable], {:type, :boolean}}]
  defp key(:doc, doc, _type) when is_binary(doc), do: []
  defp key(:doc, _other, _type), do: [{[:doc], {:type, :string}}]
  defp key(key, _value, _type), do: [{[key], :unknown_key}]

  defp in_values(%{values: [_ | _] = values, default: default}) do
    if default in values, do: [], else: [{[:default], :not_in_values}]
  end

  defp in_values(_parameter), do: []

  defp type?(type) when type in @types or type == :term, do: true
  defp type?({:document, type}) when is_atom(type) and not is_nil(type), do: true
  defp type?(_other), do: false

  @doc """
  Whether a value is one of a type: a `DateTime` for `:time`, a number for `:number`, a
  string, an atom (other than `nil`, `true` and `false`) or a number for `:category`, a
  string for `:text`, a data color for `:color` (`Macaw.Data.Schema.color?/1`), a
  `{longitude, latitude}` pair for `:point`, a map for `{:document, type}`, anything for
  `:term`. `nil` is no value of any type but `:term`.
  """
  @spec conforms?(type(), term()) :: boolean()
  def conforms?(:term, _value), do: true
  def conforms?(_type, nil), do: false
  def conforms?(:time, value), do: match?(%DateTime{}, value)
  def conforms?(:number, value), do: is_number(value)

  def conforms?(:category, value),
    do: is_binary(value) or is_number(value) or (is_atom(value) and not is_boolean(value))

  def conforms?(:text, value), do: is_binary(value)
  def conforms?(:color, value), do: Schema.color?(value)

  def conforms?(:point, {lon, lat}) when is_number(lon) and is_number(lat),
    do: lon >= -180 and lon <= 180 and lat >= -90 and lat <= 90

  def conforms?(:point, _value), do: false
  def conforms?({:document, _type}, value), do: is_map(value) and not is_struct(value)
  def conforms?(_type, _value), do: false

  @doc """
  The given values checked against a map of parameters by name (strings), every fault at
  once by name: `{:ok, values}` with each missing parameter's default filled in, or
  `{:error, faults}`. A name no parameter has is `{[name], :unknown_param}`; a missing
  parameter with no default `{[name], :required}`; a value not of its type
  `{[name], {:type, type}}`; one outside its `values` `{[name], {:enum, values}}`.

      iex> params = %{"bins" => %{type: :number, default: 10}, "agg" => %{type: :category, values: ["max", "mean"]}}
      iex> Macaw.Data.Parameter.validate(params, %{"agg" => "max"})
      {:ok, %{"agg" => "max", "bins" => 10}}
      iex> Macaw.Data.Parameter.validate(params, %{"agg" => "sum", "zoom" => 2})
      {:error, [{["agg"], {:enum, ["max", "mean"]}}, {["zoom"], :unknown_param}]}
  """
  @spec validate(%{String.t() => t()}, map()) :: {:ok, map()} | {:error, [fault(), ...]}
  def validate(parameters, given) when is_map(parameters) and is_map(given) do
    unknown =
      for name <- Map.keys(given),
          not Map.has_key?(parameters, name),
          do: {[name], :unknown_param}

    {values, faults} =
      Enum.reduce(parameters, {%{}, unknown}, fn {name, parameter}, {values, faults} ->
        case value(parameter, Map.fetch(given, name)) do
          {:ok, value} -> {Map.put(values, name, value), faults}
          {:error, reason} -> {values, [{[name], reason} | faults]}
        end
      end)

    case Enum.sort_by(faults, &elem(&1, 0)) do
      [] -> {:ok, values}
      faults -> {:error, faults}
    end
  end

  defp value(%{default: default}, :error), do: {:ok, default}
  defp value(_parameter, :error), do: {:error, :required}

  defp value(%{type: type} = parameter, {:ok, value}) do
    values = Map.get(parameter, :values)

    cond do
      not conforms?(type, value) -> {:error, {:type, type}}
      is_list(values) and value not in values -> {:error, {:enum, values}}
      true -> {:ok, value}
    end
  end
end
