defmodule Macaw.Data.Operations do
  @moduledoc """
  `macaw_data`'s own package of operations, the registry, and running them (spec/04).

  **The package.** `__members__/0` is the table operations of spec/04 §4 and the
  statistics of §5, each a module implementing `Macaw.Data.Transform` or
  `Macaw.Data.Aggregate`.

  **The registry** (`registry/1`) is built from an explicit list of packages, this one
  always among them: default closed, and a module that is merely loaded is not reachable
  (spec/04 §2).

  **Running.** `validate/3` checks a list of nodes against the registry and the context,
  answering every fault at once; `apply/4` runs checked nodes in order over a table;
  `aggregate/4` reduces values by a named aggregate; `outputs/4` names the columns after
  every node. Each fault is `{path, reason}` (spec/04 §3.1) and `format_error/1` words one.

      iex> alias Macaw.Data.Operations
      iex> registry = Operations.registry([Macaw.Data.Test.Ops])
      iex> {:ok, table} = Operations.apply(registry, [%{op: "double", field: "v"}], [%{v: 2}], %{})
      iex> Macaw.Data.Table.rows(table)
      [%{:v => 2, "double" => 4}]
      iex> Operations.validate(registry, [%{op: "doubel"}], %{})
      {:error, [{[0, "op"], {:unknown, :transform, "doubel"}}]}
  """

  alias Macaw.Data.Operations.{Aggregates, Option, Registry, Transforms}
  alias Macaw.Data.Table

  # The keys of the steps that name an aggregate, which an aggregate may not declare as
  # its own (spec/04 §1.2).
  @step_keys ~w(op field by as fn thresholds values)

  @typedoc "A fault: the path (a node's index, then its key) and the reason (spec/04 §3.1)."
  @type fault :: {[non_neg_integer() | String.t()], term()}

  @doc "The modules of `macaw_data`'s package: its table operations and statistics."
  @spec __members__() :: [module()]
  def __members__, do: Transforms.all() ++ Aggregates.all()

  @doc "The keys of the steps that name an aggregate, which an aggregate may not declare."
  @spec step_keys() :: [String.t()]
  def step_keys, do: @step_keys

  # -- the registry -----------------------------------------------------------------------

  @doc """
  The registry of this package and `packages`, in order, each once (spec/04 §2). Raises
  `ArgumentError` for a module that is not a package, a member implementing no behavior,
  a name two members of one behavior share, and an aggregate declaring a step's key.
  """
  @spec registry([module()]) :: Registry.t()
  def registry(packages \\ []) when is_list(packages),
    do: Registry.build([__MODULE__ | packages], @step_keys)

  @doc "The transform named `name`, by spelling: `{:ok, module}` or `:error`."
  @spec transform(Registry.t(), String.t() | atom()) :: {:ok, module()} | :error
  defdelegate transform(registry, name), to: Registry

  @doc "The aggregate named `name`, by spelling: `{:ok, module}` or `:error`."
  @spec aggregate(Registry.t(), String.t() | atom()) :: {:ok, module()} | :error
  defdelegate aggregate(registry, name), to: Registry

  @doc "Every transform's name, sorted."
  @spec transforms(Registry.t()) :: [String.t()]
  def transforms(%Registry{transforms: transforms}), do: transforms |> Map.keys() |> Enum.sort()

  @doc "Every aggregate's name, sorted."
  @spec aggregates(Registry.t()) :: [String.t()]
  def aggregates(%Registry{aggregates: aggregates}), do: aggregates |> Map.keys() |> Enum.sort()

  @doc "The registry's packages, this one first."
  @spec packages(Registry.t()) :: [module()]
  def packages(%Registry{packages: packages}), do: packages

  @doc "A digest of every member's name and module, which a compile cache keys by."
  @spec digest(Registry.t()) :: String.t()
  def digest(%Registry{digest: digest}), do: digest

  # -- validating -------------------------------------------------------------------------

  @doc """
  Every node checked (spec/04 §3.1): `{:ok, checked}`, each node's options by their
  strings with defaults filled in, enum values their atoms, a named aggregate its module
  and a frame-bound `"plot"` the frame's width in whole pixels; or `{:error, faults}`,
  every fault of every node, ordered by path.
  """
  @spec validate(Registry.t(), [map()], map()) :: {:ok, [map()]} | {:error, [fault(), ...]}
  def validate(%Registry{} = registry, nodes, context) when is_list(nodes) and is_map(context) do
    {checked, faults} =
      nodes
      |> Enum.with_index()
      |> Enum.map(fn {node, i} -> check_node(registry, node, i, context) end)
      |> Enum.unzip()

    case List.flatten(faults) do
      [] -> {:ok, checked}
      faults -> {:error, Enum.sort(faults)}
    end
  end

  defp check_node(_registry, node, i, _context) when not is_map(node),
    do: {nil, [{[i], :not_a_node}]}

  defp check_node(registry, node, i, context) do
    node = Map.new(node, fn {key, value} -> {spell(key), value} end)

    case Map.fetch(node, "op") do
      :error ->
        {nil, [{[i, "op"], :required}]}

      {:ok, op} when is_binary(op) or (is_atom(op) and op not in [nil, true, false]) ->
        case Registry.transform(registry, spell(op)) do
          {:ok, module} -> check_options(registry, module, node, i, context)
          :error -> {nil, [{[i, "op"], {:unknown, :transform, spell(op)}}]}
        end

      {:ok, _other} ->
        {nil, [{[i, "op"], {:type, :name}}]}
    end
  end

  defp check_options(registry, module, node, i, context) do
    name = module.name()

    needs =
      for need <- module.needs(), not Map.has_key?(context, need), do: {[i, "op"], {:needs, need}}

    {checked, faults} = check_declared(registry, module.options(), node, i, context)

    # A named aggregate's options are the node's too (spec/04 §3.1).
    {declared, checked, faults} =
      Enum.reduce(module.options(), {keys(module.options()), checked, faults}, fn
        {key, %Option{type: :aggregate}}, {declared, checked, faults} ->
          case Map.get(checked, key) do
            aggregate when is_atom(aggregate) and aggregate != nil ->
              {more, more_faults} =
                check_declared(registry, aggregate.options(), node, i, context)

              {declared ++ keys(aggregate.options()), Map.merge(checked, more),
               faults ++ more_faults}

            _none ->
              {declared, checked, faults}
          end

        _option, acc ->
          acc
      end)

    unread =
      for key <- Map.keys(node),
          key != "op",
          key not in declared,
          do: {[i, key], {:invalid_for, name}}

    {Map.put(checked, "op", name), needs ++ faults ++ unread}
  end

  defp keys(options), do: Enum.map(options, &elem(&1, 0))

  defp check_declared(registry, options, node, i, context) do
    Enum.reduce(options, {%{}, []}, fn {key, option}, {checked, faults} ->
      case check_value(registry, option, Map.fetch(node, key), context) do
        {:ok, value} -> {Map.put(checked, key, value), faults}
        {:error, reason} -> {checked, [{[i, key], reason} | faults]}
      end
    end)
  end

  defp check_value(_registry, %Option{required: true}, :error, _context), do: {:error, :required}
  defp check_value(_registry, %Option{default: default}, :error, _context), do: {:ok, default}

  defp check_value(registry, %Option{frame: :width} = option, {:ok, plot}, context)
       when plot in [:plot, "plot"] do
    case context do
      %{frame: %{width: width}} -> Option.check(registry, option, ceil(width))
      _no_frame -> {:error, {:needs, :frame}}
    end
  end

  defp check_value(registry, option, {:ok, value}, _context),
    do: Option.check(registry, option, value)

  defp spell(key) when is_atom(key), do: Atom.to_string(key)
  defp spell(key), do: key

  # -- running ----------------------------------------------------------------------------

  @doc """
  The nodes run in order over `source`, a `Macaw.Data.Table` or anything
  `Macaw.Data.Table.from/2` reads, each step's table the next one's input:
  `{:ok, table}`, or `validate/3`'s `{:error, faults}` before any step runs. A step whose
  reading is wrong only at run time raises `ArgumentError` naming the step (spec/04 §3.1).
  """
  @spec apply(Registry.t(), [map()], Table.source() | Table.t(), map()) ::
          {:ok, Table.t()} | {:error, [fault(), ...]}
  def apply(%Registry{} = registry, nodes, source, context \\ %{}) do
    with {:ok, checked} <- validate(registry, nodes, context) do
      {:ok, Enum.reduce(checked, table!(source), &run(registry, &1, &2, context))}
    end
  end

  @doc "As `apply/4`, raising `ArgumentError` naming every fault."
  @spec apply!(Registry.t(), [map()], Table.source() | Table.t(), map()) :: Table.t()
  def apply!(%Registry{} = registry, nodes, source, context \\ %{}) do
    case apply(registry, nodes, source, context) do
      {:ok, table} -> table
      {:error, faults} -> raise ArgumentError, Enum.map_join(faults, "; ", &format_error/1)
    end
  end

  defp run(registry, %{"op" => op} = node, table, context) do
    {:ok, module} = Registry.transform(registry, op)

    case module.run(node, table, context) do
      %Table{} = table ->
        table

      other ->
        raise ArgumentError,
              "transform #{inspect(op)} (#{inspect(module)}) answered #{inspect(other)}, " <>
                "not a Macaw.Data.Table (spec/04 §1.1)"
    end
  end

  defp table!(source) do
    case Table.from(source) do
      {:ok, table} -> table
      {:error, faults} -> raise ArgumentError, "not a table: #{inspect(faults)}"
    end
  end

  @doc """
  The value of `values` by the aggregate named `name`, its `options` checked against its
  declaration and every `nil` reading dropped: `{:ok, value}` or `{:error, faults}`, each
  fault at its option's key (`[]` for the name itself).
  """
  @spec aggregate(Registry.t(), String.t() | atom(), Enumerable.t(), map()) ::
          {:ok, term()} | {:error, [fault(), ...]}
  def aggregate(%Registry{} = registry, name, values, options) when is_map(options) do
    case Registry.aggregate(registry, name) do
      :error ->
        {:error, [{[], {:unknown, :aggregate, spell(name)}}]}

      {:ok, module} ->
        given = Map.new(options, fn {key, value} -> {spell(key), value} end)
        {checked, faults} = check_declared(registry, module.options(), given, nil, %{})
        faults = for {[nil, key], reason} <- faults, do: {[key], reason}

        unread =
          for key <- Map.keys(given),
              key not in keys(module.options()),
              do: {[key], {:invalid_for, module.name()}}

        case Enum.sort(faults ++ unread) do
          [] -> {:ok, module.reduce(Enum.reject(values, &is_nil/1), checked)}
          faults -> {:error, faults}
        end
    end
  end

  @doc """
  The columns after every node, by each transform's `outputs/2`, over input `columns`
  (`[{name, type}]`): `{:ok, columns}` or `validate/3`'s `{:error, faults}`.
  """
  @spec outputs(Registry.t(), [map()], Macaw.Data.Transform.columns(), map()) ::
          {:ok, Macaw.Data.Transform.columns()} | {:error, [fault(), ...]}
  def outputs(%Registry{} = registry, nodes, columns, context \\ %{}) do
    with {:ok, checked} <- validate(registry, nodes, context) do
      {:ok,
       Enum.reduce(checked, columns, fn %{"op" => op} = node, columns ->
         {:ok, module} = Registry.transform(registry, op)
         module.outputs(node, columns)
       end)}
    end
  end

  # -- for members ------------------------------------------------------------------------

  @doc "A table's columns in order, each with its type: what `outputs/2` is given."
  @spec columns(Table.t()) :: Macaw.Data.Transform.columns()
  def columns(%Table{} = table),
    do: for(name <- Table.names(table), do: {name, Table.column_type(table, name)})

  @doc """
  A table of `rows` with `columns`, in their order and of their types, each read from a
  row by either spelling (`Macaw.Data.Table.get/2`): how a member that works on rows
  answers the table its `outputs/2` names.
  """
  @spec table([map()], Macaw.Data.Transform.columns()) :: Table.t()
  def table(rows, columns) do
    Table.new!(
      for {name, type} <- columns, do: {name, type, Enum.map(rows, &Table.get(&1, name))}
    )
  end

  @doc """
  Whether two readings are one value: equal, or an atom and a string spelling it, so a
  category is one value whichever spelling a row or a node gives it (spec/04 §4.1).

      iex> Macaw.Data.Operations.same?(:ok, "ok")
      true
      iex> Macaw.Data.Operations.same?(1, 1.0)
      true
      iex> Macaw.Data.Operations.same?(nil, "nil")
      false
  """
  @spec same?(term(), term()) :: boolean()
  def same?(a, b) when is_atom(a) and is_binary(b) and a not in [nil, true, false],
    do: Atom.to_string(a) == b

  def same?(a, b) when is_binary(a) and is_atom(b) and b not in [nil, true, false],
    do: a == Atom.to_string(b)

  def same?(a, b), do: a == b

  # -- words ------------------------------------------------------------------------------

  @doc """
  One fault as a sentence.

      iex> Macaw.Data.Operations.format_error({[1, "order"], {:type, {:enum, [:ascending, :descending]}}})
      "step 2, order: is one of ascending or descending"
      iex> Macaw.Data.Operations.format_error({[0, "op"], {:unknown, :transform, "sankey"}})
      "step 1, op: transform \\"sankey\\" is not available"
  """
  @spec format_error(fault()) :: String.t()
  def format_error({path, reason}), do: "#{where(path)}: #{why(reason)}"

  defp where([i]) when is_integer(i), do: "step #{i + 1}"
  defp where([i, key]) when is_integer(i), do: "step #{i + 1}, #{key}"
  defp where([key]), do: key
  defp where([]), do: "the name"

  defp why(:required), do: "is required"
  defp why(:not_a_node), do: "is not a node (a map with an op)"
  defp why({:invalid_for, op}), do: "is not read by #{op}"
  defp why({:unknown, kind, name}), do: "#{kind} #{inspect(name)} is not available"
  defp why({:needs, need}), do: "needs a #{need}, which the caller does not give"
  defp why({:type, type}), do: "is #{words(type)}"

  defp words(:field), do: "a field name"
  defp words(:name), do: "a column name"
  defp words(:number), do: "a number"
  defp words({:number, low, high}), do: "a number from #{low} to #{high}"
  defp words(:positive), do: "a number above zero"
  defp words(:integer), do: "an integer"
  defp words({:integer, min}), do: "an integer of at least #{min}"
  defp words(:power_of_two), do: "a power of two"
  defp words(:boolean), do: "true or false"
  defp words({:enum, atoms}), do: "one of " <> or_list(Enum.map(atoms, &Atom.to_string/1))
  defp words({:keys, _}), do: "a fixed order of keys"
  defp words({:list, type}), do: "a list, each #{words(type)}"
  defp words({:pair, type}), do: "a pair, each #{words(type)}"
  defp words({:one_of, types}), do: types |> Enum.map(&words/1) |> or_list()
  defp words(:duration), do: "a duration [n, unit], unit one of " <> or_list(units())
  defp words(:aggregate), do: "the name of an aggregate"
  defp words(:term), do: "any value"

  defp units, do: Enum.map(Option.units(), fn {unit, _} -> Atom.to_string(unit) end)

  defp or_list([one]), do: one
  defp or_list(many), do: Enum.join(Enum.drop(many, -1), ", ") <> " or " <> List.last(many)
end
