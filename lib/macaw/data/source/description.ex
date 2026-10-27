defmodule Macaw.Data.Source.Description do
  @moduledoc """
  What a source is (spec/01 §2.1): its schema, its parameters, the capabilities it
  honors, and whether it answers every viewer the same.

  - `schema`: a `Macaw.Data.Schema`;
  - `params`: the parameters it takes, by name (strings), each a `Macaw.Data.Parameter`;
  - `supports`: the capabilities it honors, distinct, among
    `:window | :box | :region | :latest | :budget | :push | :as_of`. Every one is optional:
    Macaw finishes what a source does not honor (spec/01 §2.4);
  - `viewer_independent`: `true` declares the source answers every viewer the same, which
    only allows pooling across viewers, fetched with the anonymous viewer (spec/01 §6).
    `false` by default.

  `new/1` builds one and reports every fault at once.
  """

  alias Macaw.Data.{Parameter, Schema}

  @capabilities [:window, :box, :region, :latest, :budget, :push, :as_of]

  @enforce_keys [:schema]
  defstruct [:schema, params: %{}, supports: [], viewer_independent: false]

  @typedoc "A capability a source may honor."
  @type capability :: :window | :box | :region | :latest | :budget | :push | :as_of

  @type t :: %__MODULE__{
          schema: Schema.t(),
          params: %{String.t() => Parameter.t()},
          supports: [capability()],
          viewer_independent: boolean()
        }

  @doc "The capabilities, in the order spec/01 §2.1 lists them."
  @spec capabilities() :: [capability(), ...]
  def capabilities, do: @capabilities

  @doc """
  A description of the given fields, `schema` required: `{:ok, description}` or every
  fault, `{path, reason}`, ordered by path.

      iex> alias Macaw.Data.{Schema, Source.Description}
      iex> {:ok, d} = Description.new(schema: Schema.new!(%{v: %{type: :number}}), supports: [:budget])
      iex> {d.supports, d.viewer_independent}
      {[:budget], false}
      iex> Description.new(schema: :nope, supports: [:region, :teleport, :region])
      {:error, [{[:schema], {:type, :schema}}, {[:supports, 1], {:enum, Description.capabilities()}}, {[:supports, 2], :duplicate}]}
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def new(fields) when is_list(fields) or is_map(fields) do
    given = Map.new(fields)

    faults =
      Enum.flat_map(given, fn {key, value} -> field(key, value) end) ++
        if(Map.has_key?(given, :schema), do: [], else: [{[:schema], :required}])

    case Enum.sort_by(faults, &elem(&1, 0)) do
      [] -> {:ok, struct!(__MODULE__, given)}
      faults -> {:error, faults}
    end
  end

  @doc "As `new/1`, raising `ArgumentError` naming every fault."
  @spec new!(keyword() | map()) :: t()
  def new!(fields) do
    case new(fields) do
      {:ok, description} -> description
      {:error, faults} -> raise ArgumentError, "not a description: #{inspect(faults)}"
    end
  end

  defp field(:schema, %Schema{}), do: []
  defp field(:schema, _), do: [{[:schema], {:type, :schema}}]

  defp field(:params, params) when is_map(params) and not is_struct(params) do
    Enum.flat_map(params, fn {name, parameter} ->
      cond do
        not (is_binary(name) and name != "") ->
          [{[:params, name], {:type, :name}}]

        true ->
          case Parameter.check(parameter) do
            :ok -> []
            {:error, faults} -> Enum.map(faults, fn {path, r} -> {[:params, name | path], r} end)
          end
      end
    end)
  end

  defp field(:params, _), do: [{[:params], {:type, :map}}]

  defp field(:supports, supports) when is_list(supports) do
    supports
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), []}, fn {c, i}, {seen, faults} ->
      cond do
        c not in @capabilities -> {seen, [{[:supports, i], {:enum, @capabilities}} | faults]}
        MapSet.member?(seen, c) -> {seen, [{[:supports, i], :duplicate} | faults]}
        true -> {MapSet.put(seen, c), faults}
      end
    end)
    |> elem(1)
  end

  defp field(:supports, _), do: [{[:supports], {:type, :list}}]
  defp field(:viewer_independent, b) when is_boolean(b), do: []
  defp field(:viewer_independent, _), do: [{[:viewer_independent], {:type, :boolean}}]
  defp field(key, _), do: [{[key], :unknown_key}]
end
