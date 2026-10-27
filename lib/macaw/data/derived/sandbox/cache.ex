defmodule Macaw.Data.Derived.Sandbox.Cache do
  @moduledoc """
  Compiled functions by source (spec/02 §6.3, visualize D-194): a **value**, held by whatever owns
  the functions (the engine, a builder), not a process or a table, as the schema
  cache is (spec/01 §1.12).

  An entry is keyed by the SHA-256 of the source, the arities and the fields it was checked
  against, and the digest of the registry its `Macaw.Data.Ops` calls were checked and
  compiled against (spec/04 §6.1), and holds the compilation's answer, a refusal included,
  so a source is checked and compiled once. A compilation the runner cut short
  (`:reductions`, `:hung`, `:memory`) is not kept, since it says nothing about the source.
  The cache never evicts.
  """

  alias Macaw.Data.Derived.Sandbox
  alias Macaw.Data.Operations

  defstruct entries: %{}

  @type t :: %__MODULE__{entries: map()}

  @doc "The empty cache."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  `compile(cache, source, opts)`: `{:ok, compiled, cache}` or `{:error, faults, cache}`,
  as `Macaw.Data.Derived.Sandbox.compile/2` answers, compiled at most once per
  source, arities and fields.
  """
  @spec compile(t(), String.t(), keyword()) ::
          {:ok, Sandbox.Compiled.t(), t()} | {:error, [Sandbox.fault(), ...], t()}
  def compile(%__MODULE__{} = cache, source, opts \\ []) when is_binary(source) do
    opts = Keyword.put_new_lazy(opts, :operations, &Operations.registry/0)

    key =
      {Sandbox.hash(source), opts |> Keyword.get(:arity, [1, 2]) |> List.wrap() |> Enum.sort(),
       names(opts[:fields]), Operations.digest(opts[:operations])}

    case Map.fetch(cache.entries, key) do
      {:ok, {:ok, compiled}} ->
        {:ok, compiled, cache}

      {:ok, {:error, faults}} ->
        {:error, faults, cache}

      :error ->
        answer = Sandbox.compile(source, opts)

        cache =
          if keep?(answer),
            do: %{cache | entries: Map.put(cache.entries, key, answer)},
            else: cache

        case answer do
          {:ok, compiled} -> {:ok, compiled, cache}
          {:error, faults} -> {:error, faults, cache}
        end
    end
  end

  defp names(nil), do: nil
  defp names(names), do: names |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.uniq()

  defp keep?({:error, [{nil, {:compile, {_kind, _detail}}}]}), do: false
  defp keep?(_answer), do: true
end
