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
  and checked node, as `Macaw.Data.Operations.step_digest/2`, or of the options its parts
  depend on when it names them, `keyed/1`), the context as it resolved for the chunk, and
  the run of the chunk the view reads when it is not the whole chunk.
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
    partials = chunks(module, node, parts, parallel?(table, context))
    merge(module, node, partials, table, Enum.map(parts, & &1.key), context)
  end

  @doc """
  The rows at or above which a run asked for parallel chunks runs them in parallel
  (spec/04 §1.6): two canonical chunks' worth, `2 × Table.chunk_rows/0`. Fixed, not a
  setting; below it a process per chunk costs more than the chunk's work.
  """
  @spec parallel_rows() :: pos_integer()
  def parallel_rows, do: 2 * Table.chunk_rows()

  @doc """
  Whether a run over `table` works its chunks in parallel (spec/04 §1.6): only when the
  caller asks, `parallel: true` in the context, and the input holds at least two chunks
  and `parallel_rows/0` rows. Inline otherwise, the default, since a caller such as a
  frame task already runs many steps at once.
  """
  @spec parallel?(Table.t(), map()) :: boolean()
  def parallel?(%Table{} = table, context) when is_map(context) do
    Map.get(context, :parallel) == true and length(Table.chunks(table)) >= 2 and
      Table.size(table) >= parallel_rows()
  end

  @doc """
  Each part's `chunk/3`, in the parts' order: inline, or with `parallel` across the
  schedulers, one task a part, ordered. Either way the merge receives the same partials
  in the same order, so a run's result is the same bits inline or parallel (spec/04
  §1.6).
  """
  @spec chunks(module(), map(), [part()], boolean()) :: [term()]
  def chunks(module, node, parts, parallel)

  def chunks(module, node, parts, false), do: Enum.map(parts, &chunk(module, node, &1))

  def chunks(module, node, parts, true) do
    parts
    |> Task.async_stream(&chunk(module, node, &1),
      ordered: true,
      timeout: :infinity,
      max_concurrency: System.schedulers_online()
    )
    |> Enum.map(fn {:ok, partial} -> partial end)
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

    keyed = if function_exported?(module, :keyed, 1), do: module.keyed(node), else: node
    identity = Document.digest(%{"module" => module, "node" => keyed})

    {parts, _at} =
      Enum.map_reduce(views, 0, fn {chunk, first, count} = view, at ->
        resolved = module.resolve(node, view, Map.merge(bound, %{at: at, rows: rows}))
        run = if first == 0 and count == Chunk.size(chunk), do: nil, else: {first, count}
        {%{view: view, context: resolved, key: {identity, resolved, run}}, at + count}
      end)

    parts
  end

  @doc """
  The table with every chunk whose digest or size is pending (a cold chunk under a
  predicate delete) warmed, as every read of one is (spec/01 §1.1.4); any other table as
  it is. `parts/4` and `run/4` warm their input so; a caller merging parts it holds warms
  the input it merges them over the same way, so the output names the same versions.
  """
  @spec warmed(Table.t()) :: Table.t()
  def warmed(%Table{} = table) do
    if Enum.any?(Table.chunks(table), fn {chunk, _first, count} ->
         count == nil or Chunk.version(chunk) == nil
       end),
       do: Table.warm(table),
       else: table
  end

  @doc """
  A combine's part of a chunk with a delta, by inverse update from its base's part
  (spec/04 §1.5): `base` is the part the step computed for the chunk's base, under the
  same step key (a cache holds it under `{Chunk.id/1, Chunk.base_version/1, key}`).
  `{:ok, part}`, equal to `chunk/3`'s, where the step's update is exact (counts, `bin`
  counts, integer sums); `:recompute` where it is not, or the part's view is not its whole
  chunk, or the chunk has no delta. Only the delta's rows are worked.
  """
  @spec update(module(), map(), part(), term()) :: {:ok, term()} | :recompute
  def update(module, node, %{view: {chunk, 0, count}, context: context}, base) do
    if module.class(node) == :combine and function_exported?(module, :update, 4) and
         Chunk.delta?(chunk) and count == Chunk.size(chunk) and Chunk.version(chunk) != nil do
      changes = Chunk.changes(chunk)

      change = %{
        changes
        | removed: module.chunk(node, changes.removed, context),
          inserted: module.chunk(node, changes.inserted, context)
      }

      module.update(node, base, change, context)
    else
      :recompute
    end
  end

  def update(_module, _node, _part, _base), do: :recompute

  @doc """
  One chunk's part. A per-row step's is the views its selection keeps: none, the input's
  view or a run of it, or one gathered chunk named `{input id, step key}`. Any other
  class's is the step's own partial.
  """
  @spec chunk(module(), map(), part()) :: term()
  def chunk(module, node, %{view: view, context: context, key: key}) do
    case module.class(node) do
      :row -> row_part(module.chunk(node, view, context), view, key, module, node)
      _class -> module.chunk(node, view, context)
    end
  end

  defp row_part({:reshape, [], _added}, _view, _key, _module, _node), do: []

  # A reshape: the view's rows at `indexes`, repeats allowed, under the step's output
  # columns, the added ones from their values and the others gathered from the input.
  defp row_part({:reshape, indexes, added}, {chunk, first, count}, key, module, node) do
    header = module.outputs(node, Chunk.header(chunk))
    reshaped = Chunk.reshape(chunk, first, count, indexes, key, header, added)
    [{reshaped, 0, length(indexes)}]
  end

  defp row_part(selection, view, key, _module, _node), do: row_part(selection, view, key)

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

  - **per row:** concatenated in order, under the step's output columns (`outputs/2`:
    the input's, but for a reshape), keeping the input's order (`sorted/1`) while its
    sorted column is kept;
  - **a combine:** folded in chunk order by the step's `combine/3`, associative, so any
    grouping of the same partials gives the same table, then answered by its `finish/3`,
    given the input, the output's step key (the step's identity over the parts' keys) and
    the context it declares, as the parts were given it;
  - **global:** every partial, in chunk order, given to the step's `finish/3` with the
    same.
  """
  @spec merge(module(), map(), [term()], Table.t(), [term()], map()) :: Table.t()
  def merge(module, node, partials, %Table{} = input, keys \\ [], context \\ %{}) do
    case module.class(node) do
      :row ->
        header = module.outputs(node, header(input))
        sorted = if List.keymember?(header, Table.sorted(input), 0), do: Table.sorted(input)
        {:ok, table} = Table.from_chunks(header, Enum.concat(partials), sorted: sorted)
        table

      :combine ->
        merged =
          case partials do
            [] -> nil
            [first | rest] -> Enum.reduce(rest, first, &module.combine(node, &2, &1))
          end

        module.finish(node, merged, at(module, node, input, keys, context))

      :global ->
        module.finish(node, partials, at(module, node, input, keys, context))
    end
  end

  defp at(module, node, input, keys, context) do
    identity = Document.digest(%{"module" => module, "node" => node})
    %{input: input, key: {identity, keys}, context: Map.take(context, module.reads())}
  end

  @doc """
  A global step's rows gathered across the input's chunks (spec/04 §1.4): `picks` are
  `{view, row}` in output order, the view its place in `Table.chunks(input)`, repeats
  allowed. The output's columns are `columns` (`{name, type}`), each a column of `added`
  (a map from name to its values, in output order) or else the input's column of that
  name, read once a view; one chunk named by `key` over the inputs (`output/3`). Every
  value is read back and packed again, so a dictionary is the output's own: codes are
  remapped across chunks.
  """
  @spec gather(
          Table.t(),
          [{non_neg_integer(), non_neg_integer()}],
          [{Table.name(), Table.type()}],
          map(),
          term()
        ) ::
          Table.t()
  def gather(%Table{} = input, picks, columns, added, key) do
    views = input |> Table.chunks() |> List.to_tuple()

    values =
      for {name, type} <- columns do
        case added do
          %{^name => given} ->
            {name, type, given}

          _ ->
            read =
              views
              |> Tuple.to_list()
              |> Enum.map(fn {chunk, first, count} ->
                chunk |> Chunk.values(name, first, count) |> List.to_tuple()
              end)
              |> List.to_tuple()

            {name, type, Enum.map(picks, fn {v, i} -> elem(elem(read, v), i) end)}
        end
      end

    output(input, key, values)
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
