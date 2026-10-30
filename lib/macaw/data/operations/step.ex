defmodule Macaw.Data.Operations.Step do
  @moduledoc """
  Running a transform a chunk at a time (spec/04 §1.4): a per-chunk part and a merge,
  so a table's chunks are worked one by one, and a caller may keep each chunk's part
  across frames.

  A **column-native step** declares, beside `Macaw.Data.Transform`'s callbacks:

  - **its class** (`class/1`), which decides its merge. A **per-row** step (`:row`) works
    each chunk by itself and its merge is concatenation: the chunks it keeps whole, the
    runs it cuts, and the chunks it gathers, in order.
  - **the context it reads** (`reads/0`): only those keys of the caller's context reach
    it. `bind/3`, when the step has it, resolves them over the whole input once (`window`'s
    `now`, the newest reading when the caller gives none).
  - **the context as it resolves for a chunk** (`resolve/3`), given the bound context and
    the chunk's place: `:at`, the row of the input its run starts at, and `:rows`, the
    input's row count. It reads the chunk's own columns, never another chunk's.
  - **its part** (`chunk/3`), from the view and the context resolved for it. A per-row
    step's part is a selection of the view's rows: `:all`, the view unchanged; `:none`;
    `{:run, first, count}`, a run of it, cut without copying; or `{:rows, indexes}`, the
    rows at those indexes, every column gathered (`Macaw.Data.Table.Chunk.gather/5`).

  **The step key** of a chunk is the step's identity (the kernel's digest of its module
  and checked node, as `Macaw.Data.Operations.step_digest/2`), the context as it resolved
  for the chunk, and the run of the chunk the view reads when it is not the whole chunk.
  So a key changes only when what the chunk's part depends on changes: `window` keys a
  chunk wholly inside it without `now`. A cache keys a part by
  `{Chunk.id/1, Chunk.version/1, step key}` (spec/01 §1.1.3); a gathered output chunk's id
  is `{input id, step key}`.
  """

  alias Macaw.Data.Table
  alias Macaw.Data.Table.Chunk
  alias Macaw.Layers.Document

  @typedoc "A per-row step's selection of a view's rows."
  @type selection ::
          :all
          | :none
          | {:run, non_neg_integer(), non_neg_integer()}
          | {:rows, [non_neg_integer()]}

  @typedoc """
  One chunk's work: the view the input reads, the context as it resolved for it, and the
  step key its part is cached by.
  """
  @type part :: %{view: Table.view(), context: term(), key: term()}

  @doc "Whether `module` is a column-native step: it declares a class and its parts."
  @spec step?(module()) :: boolean()
  def step?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :class, 1) and
      function_exported?(module, :chunk, 3)
  end

  @doc """
  The step run over `table`: each chunk's part, merged as the step's class says
  (spec/04 §1.4). The same table whatever the chunking.
  """
  @spec run(module(), map(), Table.t(), map()) :: Table.t()
  def run(module, node, %Table{} = table, context) when is_map(context) do
    table = warmed(table)
    parts = parts(module, node, table, context)
    partials = Enum.map(parts, &chunk(module, node, &1))
    merge(module, node, partials, table, Enum.map(parts, & &1.key))
  end

  @doc """
  Each chunk's work, in order: its view, the context as it resolved for it and its step
  key. Nothing of a chunk's part is computed here, so a caller holding a part under its
  key need not compute it again.
  """
  @spec parts(module(), map(), Table.t(), map()) :: [part()]
  def parts(module, node, %Table{} = table, context) when is_map(context) do
    table = warmed(table)
    views = Table.chunks(table)
    rows = Table.size(table)
    declared = Map.take(context, module.reads())

    bound =
      if function_exported?(module, :bind, 3),
        do: module.bind(node, table, declared),
        else: declared

    identity = Document.digest(%{"module" => module, "node" => node})

    {parts, _at} =
      Enum.map_reduce(views, 0, fn {chunk, first, count} = view, at ->
        resolved = module.resolve(node, view, Map.merge(bound, %{at: at, rows: rows}))
        run = if first == 0 and count == Chunk.size(chunk), do: nil, else: {first, count}
        {%{view: view, context: resolved, key: {identity, resolved, run}}, at + count}
      end)

    parts
  end

  # A table holding a chunk whose size is pending (a cold chunk under a predicate delete)
  # is warmed first, as every read of one is (spec/01 §1.1.4).
  defp warmed(table) do
    if Enum.any?(Table.chunks(table), &(elem(&1, 2) == nil)), do: Table.warm(table), else: table
  end

  @doc """
  One chunk's part. A per-row step's is the views its selection keeps: none, the input's
  view or a run of it, or one gathered chunk named `{input id, step key}`. Any other
  class's is the step's own partial.
  """
  @spec chunk(module(), map(), part()) :: term()
  def chunk(module, node, %{view: view, context: context, key: key}) do
    case module.class(node) do
      :row -> row_part(module.chunk(node, view, context), view, key)
      _class -> module.chunk(node, view, context)
    end
  end

  defp row_part(:all, view, _key), do: [view]
  defp row_part(:none, _view, _key), do: []
  defp row_part({:run, _first, 0}, _view, _key), do: []

  defp row_part({:run, a, n}, {chunk, first, count}, _key) when a + n <= count,
    do: [{chunk, first + a, n}]

  defp row_part({:rows, []}, _view, _key), do: []

  defp row_part({:rows, indexes}, {chunk, first, count}, key),
    do: [{Chunk.gather(chunk, first, count, indexes, key), 0, length(indexes)}]

  @doc """
  The parts merged into the step's table, as its class says, given in the input's chunk
  order with their step keys (`parts/4`):

  - **per row:** concatenated in order, under the input's columns and keeping its order
    (`sorted/1`);
  - **a combine:** folded in chunk order by the step's `combine/3`, associative, so any
    grouping of the same partials gives the same table, then answered by its `finish/3`,
    given the input and the output's step key: the step's identity over the parts' keys.
  """
  @spec merge(module(), map(), [term()], Table.t(), [term()]) :: Table.t()
  def merge(module, node, partials, %Table{} = input, keys \\ []) do
    case module.class(node) do
      :row ->
        {:ok, table} =
          Table.from_chunks(header(input), Enum.concat(partials), sorted: Table.sorted(input))

        table

      :combine ->
        merged =
          case partials do
            [] -> nil
            [first | rest] -> Enum.reduce(rest, first, &module.combine(node, &2, &1))
          end

        identity = Document.digest(%{"module" => module, "node" => node})
        module.finish(node, merged, %{input: input, key: {identity, keys}})
    end
  end

  @doc """
  A combine's or a global step's output: one chunk of `columns` (`{name, type, values}`)
  over every chunk of `input`, named by `key` over the inputs' ids and versions
  (`Macaw.Data.Table.Chunk.combine/3`), nothing hashed.
  """
  @spec output(Table.t(), term(), [{Table.name(), Table.type(), [term()]}]) :: Table.t()
  def output(%Table{} = input, key, columns) do
    inputs = for {chunk, _first, _count} <- Table.chunks(input), do: chunk
    header = for {name, type, _values} <- columns, do: {name, type}
    {:ok, chunk} = Chunk.combine(inputs, key, columns)
    {:ok, table} = Table.from_chunks(header, [chunk])
    table
  end

  defp header(input),
    do: for(name <- Table.names(input), do: {name, Table.column_type(input, name)})
end
