defmodule Macaw.Data.Ops do
  @moduledoc """
  What a derived source's stored function calls to reach the registered operations
  (spec/04 §6): an aggregate of values, or a transform over rows, by name, with the options
  a design's node would carry.

      fn %{hosts: rows} ->
        p95 = rows |> Enum.map(& &1.cpu) |> Macaw.Data.Ops.aggregate!("quantile", %{p: 0.95})

        rows
        |> Macaw.Data.Ops.transform!("filter", %{field: "cpu", test: :gte, value: p95})
        |> Macaw.Data.Ops.transform!("sort", %{field: "cpu", order: :descending})
      end

  In a stored function the name is a literal string the checker holds to the engine's
  registry, and the call is compiled against that registry (`__run__/5`), so it runs
  exactly what was checked. Called from a host's own code, the functions use
  `macaw_data`'s own package.

  **Errors are values** (spec/00 §5). `aggregate/2,3` answers `{:ok, value}` and
  `transform/2,3` `{:ok, rows}`, or `{:error, faults}`: `Macaw.Data.Operations`' faults
  (spec/04 §3.1), worded by `format_error/1`.

  **Where a fault is placed** (spec/04 §6, macaw_data#139): a transform call runs a
  one-step pipeline, so its faults are at that step, `[0, key]` for an option and
  `[0, "op"]` for its name or an `op` option. An aggregate call is no step, so its faults
  name none: `[]` for an unknown name, `[key]` for an option, `["values"]` for a reading.
  Options that are no map are at `["options"]` either way.

  In a stored function a fault's atoms are spelled as its literals are (spec/02 §6.3), so it matches a
  reason with its own words. `aggregate!/2,3` and `transform!/2,3` answer the value alone,
  or raise `Macaw.Data.Error` with the faults' words, which the runner reports as `:raised`.

      iex> Macaw.Data.Ops.aggregate([3, nil, 1, 2], "median")
      {:ok, 2}
      iex> Macaw.Data.Ops.transform!([%{v: 2}, %{v: 1}], "sort", %{field: :v})
      [%{v: 1}, %{v: 2}]
      iex> Macaw.Data.Ops.aggregate(["a"], "sum")
      {:error, [{["values"], {:reads, :number}}]}
      iex> Macaw.Data.Ops.aggregate([1, 2], "mode")
      {:error, [{[], {:unknown, :aggregate, "mode"}}]}
      iex> Macaw.Data.Ops.transform([%{v: 1}], "mode")
      {:error, [{[0, "op"], {:unknown, :transform, "mode"}}]}
  """

  alias Macaw.Data.{Operations, Table}
  alias Macaw.Data.Derived.Sandbox.Names
  alias Macaw.Data.Operations.Registry

  @doc "As `aggregate/3` with no options."
  @spec aggregate(Enumerable.t(), String.t()) :: {:ok, term()} | {:error, [Operations.fault()]}
  def aggregate(values, name), do: aggregate(values, name, %{})

  @doc """
  The named aggregate of `values`, `nil`s dropped, with its `options`: `{:ok, value}` or
  `Macaw.Data.Operations.aggregate/4`'s `{:error, faults}`, which name no step: `[]` for
  an unknown name, `[key]` for an option, `["values"]` for a reading.
  """
  @spec aggregate(Enumerable.t(), String.t(), map()) ::
          {:ok, term()} | {:error, [Operations.fault()]}
  def aggregate(values, name, options),
    do: run(:aggregate, Operations.registry(), name, values, options)

  @doc "As `aggregate/2`, the value alone, raising `Macaw.Data.Error` naming every fault."
  @spec aggregate!(Enumerable.t(), String.t()) :: term()
  def aggregate!(values, name), do: aggregate!(values, name, %{})

  @doc "As `aggregate/3`, the value alone, raising `Macaw.Data.Error` naming every fault."
  @spec aggregate!(Enumerable.t(), String.t(), map()) :: term()
  def aggregate!(values, name, options), do: value!(name, aggregate(values, name, options))

  @doc "As `transform/3` with no options."
  @spec transform(Table.source() | Table.t(), String.t()) ::
          {:ok, [map()]} | {:error, [Operations.fault()]}
  def transform(rows, name), do: transform(rows, name, %{})

  @doc """
  The named transform run over `rows` with `options`, `{:ok, rows}` its answer as rows, or
  `Macaw.Data.Operations.apply/4`'s `{:error, faults}` of its one step: `[0, key]` for an
  option, `[0, "op"]` for an unknown name. Options that name an `op` are
  `{[0, "op"], {:invalid_for, name}}`: the name is the op.
  """
  @spec transform(Table.source() | Table.t(), String.t(), map()) ::
          {:ok, [map()]} | {:error, [Operations.fault()]}
  def transform(rows, name, options),
    do: run(:transform, Operations.registry(), name, rows, options)

  @doc "As `transform/2`, the rows alone, raising `Macaw.Data.Error` naming every fault."
  @spec transform!(Table.source() | Table.t(), String.t()) :: [map()]
  def transform!(rows, name), do: transform!(rows, name, %{})

  @doc "As `transform/3`, the rows alone, raising `Macaw.Data.Error` naming every fault."
  @spec transform!(Table.source() | Table.t(), String.t(), map()) :: [map()]
  def transform!(rows, name, options), do: value!(name, transform(rows, name, options))

  @doc """
  A fault in words, `Macaw.Data.Operations.format_error/1`'s, its reason read back from
  the spellings a stored function holds it in.

      iex> Macaw.Data.Ops.format_error({[0, "n"], "required"})
      "step 1, n: is required"
  """
  @spec format_error(Operations.fault()) :: String.t()
  def format_error({path, reason}), do: Operations.format_error({path, unspelled(reason)})

  @doc false
  # A call compiled against `registry` (spec/04 §6.1). Not on the allowlist: a stored
  # function that writes it is refused like any other unlisted call. A fault's atoms come
  # back spelled as the function's literals are (spec/02 §6.3).
  @spec __run__(atom(), Registry.t(), String.t(), term(), term()) :: term()
  def __run__(kind, %Registry{} = registry, name, subject, options)
      when kind in [:aggregate, :transform] do
    case run(kind, registry, name, subject, options) do
      {:ok, value} -> {:ok, value}
      {:error, faults} -> {:error, Enum.map(faults, fn {path, why} -> {path, spelled(why)} end)}
    end
  end

  def __run__(:aggregate!, %Registry{} = registry, name, subject, options),
    do: value!(name, run(:aggregate, registry, name, subject, options))

  def __run__(:transform!, %Registry{} = registry, name, subject, options),
    do: value!(name, run(:transform, registry, name, subject, options))

  defp run(_kind, _registry, _name, _subject, options) when not is_map(options),
    do: {:error, [{["options"], {:type, :map}}]}

  defp run(:aggregate, registry, name, values, options) do
    if Enumerable.impl_for(values),
      do: Operations.aggregate(registry, name, values, options),
      else: {:error, [{["values"], {:type, {:list, :term}}}]}
  end

  defp run(:transform, registry, name, rows, options) do
    if Enum.any?(Map.keys(options), &(&1 in [:op, "op"])) do
      {:error, [{[0, "op"], {:invalid_for, name}}]}
    else
      with {:ok, table} <-
             Operations.apply(registry, [Map.put(options, "op", name)], rows, %{}),
           do: {:ok, Table.rows(table)}
    end
  end

  defp value!(_name, {:ok, value}), do: value

  defp value!(name, {:error, faults}),
    do:
      raise(Macaw.Data.Error,
        reason: faults,
        message: "#{name}: " <> Enum.map_join(faults, "; ", &format_error/1)
      )

  # The words of Operations' reasons (spec/04 §2, §3.1), by their spellings: read back
  # from the strings a stored function holds them in. A fixed table; no atom is made.
  @words Map.new(
           ~w(required not_a_node invalid_for unknown transform aggregate needs type reads
              reading context not_a_table number time positive comparable point field name
              integer boolean enum keys list pair one_of duration term power_of_two frame
              projection text scale identity schema now map)a ++ Table.types(),
           &{Atom.to_string(&1), &1}
         )

  defp spelled(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.map(&spelled/1) |> List.to_tuple()

  defp spelled(reason) when is_list(reason), do: Enum.map(reason, &spelled/1)
  defp spelled(reason), do: Names.spelling(reason)

  defp unspelled(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.map(&unspelled/1) |> List.to_tuple()

  defp unspelled(reason) when is_list(reason), do: Enum.map(reason, &unspelled/1)
  defp unspelled(word) when is_binary(word), do: Map.get(@words, word, word)
  defp unspelled(other), do: other
end
