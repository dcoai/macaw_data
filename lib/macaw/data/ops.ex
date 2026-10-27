defmodule Macaw.Data.Ops do
  @moduledoc """
  What a derived source's stored function calls to reach the registered operations
  (spec/04 §6): an aggregate of values, or a transform over rows, by name, with the options
  a design's node would carry.

      fn %{hosts: rows} ->
        p95 = rows |> Enum.map(& &1.cpu) |> Macaw.Data.Ops.aggregate("quantile", %{p: 0.95})

        rows
        |> Macaw.Data.Ops.transform("filter", %{field: "cpu", test: :gte, value: p95})
        |> Macaw.Data.Ops.transform("sort", %{field: "cpu", order: :descending})
      end

  In a stored function the name is a literal string the checker holds to the engine's
  registry, and the call is compiled against that registry (`__run__/5`), so it runs
  exactly what was checked. Called from a host's own code, the functions use
  `macaw_data`'s own package. A fault in the options raises `ArgumentError` with
  `Macaw.Data.Operations.format_error/1`'s words.

      iex> Macaw.Data.Ops.aggregate([3, nil, 1, 2], "median")
      2
      iex> Macaw.Data.Ops.transform([%{v: 2}, %{v: 1}], "sort", %{field: :v})
      [%{v: 1}, %{v: 2}]
  """

  alias Macaw.Data.{Operations, Table}
  alias Macaw.Data.Operations.Registry

  @doc "As `aggregate/3` with no options."
  @spec aggregate(Enumerable.t(), String.t()) :: term()
  def aggregate(values, name), do: aggregate(values, name, %{})

  @doc "The named aggregate of `values`, `nil`s dropped, with its `options`."
  @spec aggregate(Enumerable.t(), String.t(), map()) :: term()
  def aggregate(values, name, options),
    do: __run__(:aggregate, Operations.registry(), name, values, options)

  @doc "As `transform/3` with no options."
  @spec transform(Table.source() | Table.t(), String.t()) :: [map()]
  def transform(rows, name), do: transform(rows, name, %{})

  @doc "The named transform run over `rows` with `options`, its answer as rows."
  @spec transform(Table.source() | Table.t(), String.t(), map()) :: [map()]
  def transform(rows, name, options),
    do: __run__(:transform, Operations.registry(), name, rows, options)

  @doc false
  # A call compiled against `registry` (spec/04 §6.1). Not on the allowlist: a stored
  # function that writes it is refused like any other unlisted call.
  @spec __run__(:aggregate | :transform, Registry.t(), String.t(), term(), map()) :: term()
  def __run__(:aggregate, %Registry{} = registry, name, values, options) when is_map(options) do
    case Operations.aggregate(registry, name, values, options) do
      {:ok, value} -> value
      {:error, faults} -> raise ArgumentError, words(name, faults)
    end
  end

  def __run__(:transform, %Registry{} = registry, name, rows, options) when is_map(options) do
    if Enum.any?(Map.keys(options), &(&1 in [:op, "op"])) do
      raise ArgumentError,
            "transform #{inspect(name)}: the options name no op; the name is the op (spec/04 §6)"
    end

    case Operations.apply(registry, [Map.put(options, "op", name)], rows, %{}) do
      {:ok, table} -> Table.rows(table)
      {:error, faults} -> raise ArgumentError, words(name, faults)
    end
  end

  defp words(name, faults),
    do: "#{name}: " <> Enum.map_join(faults, "; ", &Operations.format_error/1)
end
