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
  # The registry of `packages`, in order, each listed once: `{:ok, registry}`, or every
  # fault (spec/04 §2), each `{path, reason}`: `{[module], :not_a_package}` for a module
  # with no `__members__/0`, `{[package, member], :no_behavior}` for a member implementing
  # no behavior, `{[kind, name], {:named_twice, module, other}}` for two members of one
  # behavior with one name, and `{[:aggregate, name], {:step_key, key}}` for an aggregate
  # declaring a step's key as its own option.
  @spec build([module()], [String.t()]) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def build(packages, step_keys) do
    packages = Enum.uniq(packages)
    {listed, faults} = Enum.flat_map_reduce(packages, [], &members/2)
    {members, faults} = Enum.flat_map_reduce(listed, faults, &kind/2)

    {transforms, faults} =
      named(for({:transform, m, p} <- members, do: {m, p}), :transform, faults)

    {aggregates, faults} =
      named(for({:aggregate, m, p} <- members, do: {m, p}), :aggregate, faults)

    faults =
      faults ++
        for {name, {module, _package}} <- aggregates,
            {key, _option} <- module.options(),
            key in step_keys,
            do: {[:aggregate, name], {:step_key, key}}

    case faults do
      [] ->
        transforms = Map.new(transforms, fn {name, {module, _}} -> {name, module} end)
        aggregates = Map.new(aggregates, fn {name, {module, _}} -> {name, module} end)

        {:ok,
         %__MODULE__{
           packages: packages,
           transforms: transforms,
           aggregates: aggregates,
           digest: digest(transforms, aggregates)
         }}

      faults ->
        {:error, faults}
    end
  end

  defp members(package, faults) do
    Code.ensure_loaded(package)

    if function_exported?(package, :__members__, 0),
      do: {Enum.map(package.__members__(), &{&1, package}), faults},
      else: {[], faults ++ [{[package], :not_a_package}]}
  end

  # Which of the two behaviors a member implements, from its own @behaviour declarations.
  # A member of another Macaw behavior only is skipped here: its registry is the host's.
  defp kind({member, package}, faults) do
    Code.ensure_loaded(member)

    # spelling: allow, the attribute's name is Elixir's
    declared = member.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    cond do
      Transform in declared -> {[{:transform, member, package}], faults}
      Aggregate in declared -> {[{:aggregate, member, package}], faults}
      declared == [] -> {[], faults ++ [{[package, member], :no_behavior}]}
      true -> {[], faults}
    end
  end

  defp named(members, kind, faults) do
    Enum.reduce(members, {%{}, faults}, fn {module, package}, {acc, faults} ->
      name = module.name()

      case Map.fetch(acc, name) do
        {:ok, {^module, _}} ->
          {acc, faults}

        {:ok, {other, _other_package}} ->
          {acc, faults ++ [{[kind, name], {:named_twice, other, module}}]}

        :error ->
          {Map.put(acc, name, {module, package}), faults}
      end
    end)
  end

  # The kernel's term digest of every name and its module (spec/04 §2): a canonical
  # encoding of the term, where `term_to_binary/1` is a representation that need not agree
  # across OTP releases. Maps are canonical in it, so the order members were registered in
  # never moves it.
  defp digest(transforms, aggregates),
    do: Macaw.Data.Table.Digest.term(%{"transforms" => transforms, "aggregates" => aggregates})

  @doc "The transform module named `name`, by spelling, or `:error`."
  @spec transform(t(), String.t() | atom()) :: {:ok, module()} | :error
  def transform(%__MODULE__{transforms: transforms}, name), do: Map.fetch(transforms, spell(name))

  @doc "The aggregate module named `name`, by spelling, or `:error`."
  @spec aggregate(t(), String.t() | atom()) :: {:ok, module()} | :error
  def aggregate(%__MODULE__{aggregates: aggregates}, name), do: Map.fetch(aggregates, spell(name))

  defp spell(name) when is_atom(name), do: Atom.to_string(name)
  defp spell(name), do: name
end
