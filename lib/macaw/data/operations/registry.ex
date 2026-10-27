defmodule Macaw.Data.Operations.Registry do
  @moduledoc """
  The transforms and aggregates of the enabled packages, by name (spec/04 §2), built by
  `Macaw.Data.Operations.registry/1`.

  Names are strings matched by spelling. The registry holds `macaw_data`'s own package
  and exactly the packages a host lists: a module that is merely loaded is not reachable.
  """

  alias Macaw.Data.{Aggregate, Transform}

  @enforce_keys [:packages, :transforms, :aggregates, :digest]
  defstruct [:packages, :transforms, :aggregates, :digest]

  @type t :: %__MODULE__{
          packages: [module()],
          transforms: %{String.t() => module()},
          aggregates: %{String.t() => module()},
          digest: String.t()
        }

  @doc false
  # The registry of `packages`, in order, each listed once. Raises `ArgumentError` for a
  # module that is not a package, a member implementing no behavior, two members of one
  # behavior with one name, and an aggregate declaring a step's key as its own option.
  @spec build([module()], [String.t()]) :: t()
  def build(packages, step_keys) do
    packages = Enum.uniq(packages)

    members =
      for package <- packages, member <- members!(package) do
        {kind(member, package), member, package}
      end

    transforms = named(for({:transform, m, p} <- members, do: {m, p}), "transform")
    aggregates = named(for({:aggregate, m, p} <- members, do: {m, p}), "aggregate")

    for {name, {module, package}} <- aggregates,
        {key, _option} <- module.options(),
        key in step_keys do
      raise ArgumentError,
            "aggregate #{inspect(name)} (#{inspect(module)}, package #{inspect(package)}) " <>
              "declares #{inspect(key)}, a key of the steps that name it (spec/04 §1.2)"
    end

    transforms = Map.new(transforms, fn {name, {module, _}} -> {name, module} end)
    aggregates = Map.new(aggregates, fn {name, {module, _}} -> {name, module} end)

    %__MODULE__{
      packages: packages,
      transforms: transforms,
      aggregates: aggregates,
      digest: digest(transforms, aggregates)
    }
  end

  defp members!(package) do
    Code.ensure_loaded(package)

    function_exported?(package, :__members__, 0) ||
      raise ArgumentError,
            "#{inspect(package)} is not a package: it has no __members__/0 (spec/04 §2)"

    package.__members__()
  end

  # Which of the two behaviors a member implements, from its own @behaviour declarations.
  # A member of another Macaw behavior only is skipped here: its registry is the host's.
  defp kind(member, package) do
    Code.ensure_loaded(member)

    # spelling: allow, the attribute's name is Elixir's
    declared = member.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    cond do
      Transform in declared ->
        :transform

      Aggregate in declared ->
        :aggregate

      declared == [] ->
        raise ArgumentError,
              "#{inspect(member)}, a member of #{inspect(package)}, implements no behavior " <>
                "(spec/04 §2)"

      true ->
        :other
    end
  end

  defp named(members, kind) do
    Enum.reduce(members, %{}, fn {module, package}, acc ->
      name = module.name()

      case Map.fetch(acc, name) do
        {:ok, {^module, _}} ->
          acc

        {:ok, {other, other_package}} ->
          raise ArgumentError,
                "#{kind} #{inspect(name)} is named twice: by #{inspect(other)} (package " <>
                  "#{inspect(other_package)}) and #{inspect(module)} (package " <>
                  "#{inspect(package)}) (spec/04 §2)"

        :error ->
          Map.put(acc, name, {module, package})
      end
    end)
  end

  defp digest(transforms, aggregates) do
    term = {Enum.sort(transforms), Enum.sort(aggregates)}
    :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
  end

  @doc "The transform module named `name`, by spelling, or `:error`."
  @spec transform(t(), String.t() | atom()) :: {:ok, module()} | :error
  def transform(%__MODULE__{transforms: transforms}, name), do: Map.fetch(transforms, spell(name))

  @doc "The aggregate module named `name`, by spelling, or `:error`."
  @spec aggregate(t(), String.t() | atom()) :: {:ok, module()} | :error
  def aggregate(%__MODULE__{aggregates: aggregates}, name), do: Map.fetch(aggregates, spell(name))

  defp spell(name) when is_atom(name), do: Atom.to_string(name)
  defp spell(name), do: name
end
