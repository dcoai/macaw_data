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
  `Step.run(module, node, table, context)`'s.
  """
  @spec run(t(), module(), map(), Table.t(), map()) :: {Table.t(), t()}
  def run(%__MODULE__{} = cache, module, node, %Table{} = table, context) do
    table = Step.warmed(table)
    parts = Step.parts(module, node, table, context)

    {partials, {held, last}} =
      Enum.map_reduce(parts, {cache.parts, %{reused: 0, updated: 0, computed: 0}}, fn part, acc ->
        part(module, node, part, acc)
      end)

    output = Step.merge(module, node, partials, table, Enum.map(parts, & &1.key), context)
    {output, %__MODULE__{parts: held, last: last}}
  end

  defp part(module, node, %{view: {chunk, _first, _count}, key: key} = part, {held, last}) do
    id = Chunk.id(chunk)

    case Chunk.version(chunk) do
      nil ->
        {Step.chunk(module, node, part), {held, bump(last, :computed)}}

      version ->
        case held do
          %{{^id, ^version, ^key} => partial} ->
            {partial, {held, bump(last, :reused)}}

          _ ->
            {partial, how} = fresh(module, node, part, held, id, Chunk.base_version(chunk))
            {partial, {Map.put(held, {id, version, key}, partial), bump(last, how)}}
        end
    end
  end

  # An inverse update from the base's part where it is held and exact, else computed.
  defp fresh(module, node, %{key: key} = part, held, id, base) do
    with %{{^id, ^base, ^key} => partial} <- held,
         {:ok, updated} <- Step.update(module, node, part, partial) do
      {updated, :updated}
    else
      _ -> {Step.chunk(module, node, part), :computed}
    end
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
