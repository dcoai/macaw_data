defmodule Macaw.Data.Operations.Cache do
  @moduledoc """
  A caller's cache of steps' per-chunk parts (spec/04 §1.5; macaw_data#9 §6): the
  example caller of the caching contract, a plain value the caller holds and passes back.
  The operations hold no cache and no hidden state; the frame or the feed that owns this
  value knows when a chunk leaves its window.

  **The key** of a part is `{logical id, version, step key}`: `Chunk.id/1`, where the
  chunk sits, which scopes eviction; `Chunk.version/1`, its content digest (or a step
  output's derivation digest), which decides validity; and the part's step key
  (`Macaw.Data.Operations.Step.parts/4`), which carries the context as it resolved for
  the chunk. Nothing is hashed on lookup: the version is read from the chunk, computed
  once when its state was made, and a chunk whose digest is pending has none, so it
  never matches.

  `run/5` runs a step over a table a part at a time:

  - a part held under its key is **reused**;
  - a chunk with a delta whose base's part is held (under `Chunk.base_version/1`) is
    **updated** from it, where the step's inverse is exact (`Step.update/4`: counts,
    `bin` counts, integer sums);
  - any other part is **computed** (`Step.chunk/3`);

  and the parts are merged (`Step.merge/6`), which only the combine's or global step's
  merge recomputes. The result equals `Step.run/4`'s. `prune/2` evicts by logical id.

      cache = Cache.new()
      {table, cache} = Cache.run(cache, Sum, node, frame_1, %{})
      # the next frame: one new chunk computed, every other part reused
      {table, cache} = Cache.run(cache, Sum, node, frame_2, %{})
      cache = Cache.prune(cache, [frame_2])
  """

  alias Macaw.Data.Operations.Step
  alias Macaw.Data.Table
  alias Macaw.Data.Table.Chunk

  defstruct parts: %{}, last: %{reused: 0, updated: 0, computed: 0}

  @typedoc """
  The parts held by `{id, version, step key}`, and how the last run came by its parts:
  how many it reused, updated by inverse and computed.
  """
  @type t :: %__MODULE__{
          parts: %{{term(), String.t(), term()} => term()},
          last: %{
            reused: non_neg_integer(),
            updated: non_neg_integer(),
            computed: non_neg_integer()
          }
        }

  @doc "An empty cache."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  The step `module` (a column-native one, `Step.step?/1`) run over `table` with the parts
  `cache` holds, and the cache holding this run's parts. The table equals
  `Step.run(module, node, table, context)`'s. With `parallel: true` in the context, the
  parts it computes run as `Step.run/4`'s would (spec/04 §1.6).
  """
  @spec run(t(), module(), map(), Table.t(), map()) :: {Table.t(), t()}
  def run(%__MODULE__{} = cache, module, node, %Table{} = table, context) do
    table = Step.warmed(table)
    parts = Step.parts(module, node, table, context)
    found = Enum.map(parts, &found(module, node, &1, cache.parts))

    missing = for {:compute, part} <- found, do: part
    computed = Step.chunks(module, node, missing, Step.parallel?(table, context))

    {partials, {held, last, []}} =
      Enum.map_reduce(
        found,
        {cache.parts, %{reused: 0, updated: 0, computed: 0}, computed},
        &fill/2
      )

    output = Step.merge(module, node, partials, table, Enum.map(parts, & &1.key), context)
    {output, %__MODULE__{parts: held, last: last}}
  end

  # How a part is come by: held under its key, updated by inverse from its base's part
  # where that is exact, or to compute. A chunk with no version is computed and not held.
  defp found(module, node, %{view: {chunk, _first, _count}, key: key} = part, held) do
    id = Chunk.id(chunk)
    version = Chunk.version(chunk)
    base = Chunk.base_version(chunk)

    case held do
      _ when version == nil ->
        {:compute, part}

      %{{^id, ^version, ^key} => partial} ->
        {:reused, partial}

      %{{^id, ^base, ^key} => partial} ->
        case Step.update(module, node, part, partial) do
          {:ok, updated} -> {:updated, {id, version, key}, updated}
          :recompute -> {:compute, part}
        end

      _ ->
        {:compute, part}
    end
  end

  defp fill({:reused, partial}, {held, last, computed}),
    do: {partial, {held, bump(last, :reused), computed}}

  defp fill({:updated, key, partial}, {held, last, computed}),
    do: {partial, {Map.put(held, key, partial), bump(last, :updated), computed}}

  defp fill({:compute, %{view: {chunk, _, _}, key: key}}, {held, last, [partial | computed]}) do
    held =
      case Chunk.version(chunk) do
        nil -> held
        version -> Map.put(held, {Chunk.id(chunk), version, key}, partial)
      end

    {partial, {held, bump(last, :computed), computed}}
  end

  defp bump(last, how), do: Map.update!(last, how, &(&1 + 1))

  @doc """
  The cache with only the parts of chunks the `tables` still hold (spec/04 §1.5): the
  logical id scopes eviction, so a part of a chunk that left the window goes, and so does
  a part of a version no held chunk has, but for a chunk's base version, which its inverse
  updates start from.
  """
  @spec prune(t(), [Table.t()]) :: t()
  def prune(%__MODULE__{parts: parts} = cache, tables) when is_list(tables) do
    live =
      for table <- tables,
          {chunk, _first, _count} <- Table.chunks(table),
          version <- [Chunk.version(chunk), Chunk.base_version(chunk)],
          version != nil,
          into: MapSet.new(),
          do: {Chunk.id(chunk), version}

    %{cache | parts: Map.filter(parts, fn {{id, version, _key}, _} -> {id, version} in live end)}
  end

  @doc "How many parts the cache holds."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{parts: parts}), do: map_size(parts)
end
