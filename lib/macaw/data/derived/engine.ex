defmodule Macaw.Data.Derived.Engine do
  @moduledoc """
  Where derived sources run (spec/02 §8): a **value** its owner holds and calls from its
  own callbacks, as a `Macaw.Data.Source.Push` is held. One owner, and no second process
  between the owner and its sources' rows. On a Macaw page the owner is `macaw_compose`'s
  runtime.

  `new/2` defines the sources (every input resolved, cycles refused by name, ranks
  assigned). `push/4` shows the engine its sources' latest deliveries: a source that
  changed marks the derived sources that read it, and the first mark makes a **pulse** due
  `debounce:` milliseconds later. `run/2` runs a due pulse: the marked sources in rank
  order, each at most once, every call bounded (`Macaw.Data.Derived.Sandbox.run/3`). A
  source that fails keeps its last good output, and the pulse goes no further along it.
  The engine never reads a clock: `now` is the owner's monotonic milliseconds.

      iex> alias Macaw.Data.{Delivery, Derived, Schema}
      iex> alias Macaw.Data.Derived.Engine
      iex> count = Derived.new!(id: :count, from: [hosts: nil],
      ...>   schema: %{n: %{type: :number}}, elixir: "fn %{hosts: rows} -> [%{n: Enum.count(rows)}] end")
      iex> {:ok, engine} = Engine.new(%{["count"] => count}, sources: [:hosts], debounce: 0)
      iex> hosts = Schema.new!(%{host: %{type: :category}})
      iex> engine = Engine.push(engine, %{hosts: Delivery.new([%{host: "a"}, %{host: "b"}])}, %{hosts: hosts}, 0)
      iex> engine = Engine.run(engine, 0)
      iex> Delivery.rows(Engine.outputs(engine)[["count"]])
      [%{"n" => 2}]
      iex> Engine.status(engine)
      %{["count"] => :live}

  Ported from visualize's `Visualize.VirtualSource.Engine`, without its variables (a
  variable is an input, spec/02 §2.3) and with sources in place of feeds.
  """

  alias Macaw.Data.{Delivery, Derived, Operations, Schema}
  alias Macaw.Data.Derived.{Context, Output, Sandbox}
  alias Macaw.Data.Derived.Sandbox.Cache
  alias Macaw.Data.Derived.Sandbox.Names, as: Spelling
  alias Macaw.Layers.Names

  defstruct derived: %{},
            sources: [],
            inputs: %{},
            ranks: %{},
            order: [],
            readers: %{},
            functions: %{},
            compiled: %{},
            arities: %{},
            cache: %Cache{},
            outputs: %{},
            faults: %{},
            runs: %{},
            seen: %{},
            source_schemas: %{},
            checked: %{},
            marked: MapSet.new(),
            due: nil,
            debounce: 250,
            run_opts: [],
            operations: nil

  @type path :: [String.t(), ...]
  @type ref :: {:derived, path()} | {:source, String.t()}

  @typedoc "A scope's path, `[]` the outermost (spec/02 §3)."
  @type scope :: [atom() | String.t()]

  @type t :: %__MODULE__{}

  @typedoc "A definition fault: the source's path, where in it, and why (spec/02 §8.1)."
  @type error :: {path(), list(), term()}

  @typedoc "A source's fault (spec/02 §8.3): its kind and its detail, never a value."
  @type fault :: %{kind: atom(), detail: term()}

  # -- defining (spec/02 §8.1) -------------------------------------------------------------

  @doc "As `new/2` with no options."
  @spec new(%{list() => Derived.t()}) :: {:ok, t()} | {:error, [error(), ...]}
  def new(derived), do: new(derived, [])

  @doc """
  The engine over derived sources by path, defined (spec/02 §8.1): `{:ok, engine}`, or
  `{:error, errors}`: every input that resolves to nothing, every host function the
  registry lacks, then every cycle by name. Options (spec/02 §8.4): `sources:` (the names
  of the sources the derived sources may read, `[]`), `functions:` (the registry, `%{}`,
  default closed), `packages:` (the packages of operations a stored function may reach
  besides `macaw_data`'s own, `[]`, default closed, spec/04 §6.1), `debounce:`
  (milliseconds, `250`), and `max_reductions:`, `timeout:` and `max_heap:` (each call's
  bounds, tighten-only).
  """
  @spec new(%{list() => Derived.t()}, keyword()) :: {:ok, t()} | {:error, [error(), ...]}
  def new(derived, opts) when is_map(derived) do
    opts =
      Keyword.validate!(opts,
        sources: [],
        functions: %{},
        packages: [],
        debounce: 250,
        max_reductions: 100_000_000,
        timeout: 30_000,
        max_heap: 10_000_000
      )

    run_opts =
      opts |> Keyword.take([:max_reductions, :timeout, :max_heap]) |> Sandbox.tightened!()

    sources = opts[:sources] |> Enum.map(&Names.name/1) |> Enum.uniq()
    functions = opts[:functions]
    derived = Map.new(derived, fn {path, source} -> {Enum.map(path, &Names.name/1), source} end)
    paths = Map.keys(derived)

    {inputs, errors} =
      Enum.reduce(derived, {%{}, []}, fn {path, source}, {inputs, errors} ->
        {resolved, faults} = references(source, path, paths, sources, functions)
        {Map.put(inputs, path, resolved), errors ++ faults}
      end)

    errors = if errors == [], do: cycles(inputs), else: errors

    case Enum.sort(errors) do
      [] ->
        engine = %__MODULE__{
          derived: derived,
          sources: sources,
          inputs: inputs,
          functions: functions,
          debounce: opts[:debounce],
          run_opts: run_opts,
          operations: Operations.registry(opts[:packages])
        }

        {:ok, engine |> rank() |> compile()}

      errors ->
        {:error, errors}
    end
  end

  # Every input resolved from the scope its source stands in: a derived source from the
  # inside out, else a source (spec/02 §3).
  defp references(source, path, paths, sources, functions) do
    scope = Enum.drop(path, -1)

    {resolved, faults} =
      source.from
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {{name, window}, i}, faults ->
        case lookup(paths, sources, scope, name) do
          {:ok, ref} -> {{Derived.key(name), name, ref, window}, faults}
          :error -> {nil, [{path, [:from, i], {:unknown_input, name}} | faults]}
        end
      end)

    faults =
      case source.function do
        name when is_binary(name) ->
          if Names.key(functions, name) == :error,
            do: [{path, [:function], {:undeclared, :function, name}} | faults],
            else: faults

        nil ->
          faults
      end

    {resolved, Enum.reverse(faults)}
  end

  # `{:source, name}` is a source; a path a derived source; a short id a derived source
  # from the inside out, else the source of its spelling.
  defp lookup(_paths, sources, _scope, {:source, name}), do: named_source(sources, name)

  defp lookup(paths, sources, scope, name) do
    case Derived.resolve(paths, scope, name) do
      {:ok, path} -> {:ok, {:derived, path}}
      :error when is_list(name) -> :error
      :error -> named_source(sources, name)
    end
  end

  defp named_source(sources, name) do
    case Enum.find(sources, &Names.same?(&1, name)) do
      nil -> :error
      source -> {:ok, {:source, source}}
    end
  end

  @doc """
  What a name read from a scope names (spec/02 §8.4): `{:derived, path}` for a derived
  source, resolved from the inside out, else `{:source, name}` for a source the engine may
  read, else `:error`.
  """
  @spec resolve(t(), scope(), term()) :: ref() | :error
  def resolve(%__MODULE__{derived: derived, sources: sources}, scope, name) do
    case lookup(Map.keys(derived), sources, scope, name) do
      {:ok, ref} -> ref
      :error -> :error
    end
  end

  # Each cycle named (spec/02 §3), at its first member's `from`.
  defp cycles(inputs) do
    reads =
      Map.new(inputs, fn {path, refs} ->
        {path, for({_key, _name, {:derived, from}, _window} <- refs, do: from)}
      end)

    for [first | _] = members <- Derived.cycles(reads), do: {first, [:from], {:cycle, members}}
  end

  # Ranks: a derived source over sources alone is 0, any other one more than its greatest
  # derived input. The pulse order is by rank, then path.
  defp rank(engine) do
    ranks =
      Enum.reduce(Map.keys(engine.inputs), %{}, fn path, ranks -> rank_of(engine, path, ranks) end)

    readers =
      Enum.reduce(engine.inputs, %{}, fn {path, refs}, readers ->
        Enum.reduce(refs, readers, fn {_key, _name, ref, _window}, acc ->
          Map.update(acc, ref, [path], &[path | &1])
        end)
      end)

    order = Enum.sort_by(Map.keys(ranks), &{Map.fetch!(ranks, &1), &1})
    %{engine | ranks: ranks, order: order, readers: readers}
  end

  defp rank_of(engine, path, ranks) do
    case Map.fetch(ranks, path) do
      {:ok, _rank} ->
        ranks

      :error ->
        derived = for {_key, _name, {:derived, from}, _window} <- engine.inputs[path], do: from
        ranks = Enum.reduce(derived, ranks, &rank_of(engine, &1, &2))
        rank = derived |> Enum.map(&(Map.fetch!(ranks, &1) + 1)) |> Enum.max(fn -> 0 end)
        Map.put(ranks, path, rank)
    end
  end

  # Every stored function compiled once into the cache; a host's captured by the arity
  # `defsource` recorded (spec/02 §7).
  defp compile(engine) do
    Enum.reduce(engine.derived, engine, fn
      {path, %{elixir: text}}, engine when is_binary(text) ->
        case Cache.compile(engine.cache, text, [operations: engine.operations] ++ engine.run_opts) do
          {:ok, compiled, cache} ->
            %{
              engine
              | cache: cache,
                compiled: Map.put(engine.compiled, path, compiled.fun),
                arities: Map.put(engine.arities, path, compiled.arity)
            }

          {:error, faults, cache} ->
            %{engine | cache: cache} |> fault(path, :restricted, faults)
        end

      {path, %{function: name}}, engine ->
        {:ok, key} = Names.key(engine.functions, name)
        {module, arity} = Map.fetch!(engine.functions, key)

        # The function's atom is the one its module defines: found, never made.
        {function, ^arity, _text} =
          Enum.find(module.__derived__(), fn {f, _a, _t} ->
            Atom.to_string(f) == Names.name(name)
          end)

        %{
          engine
          | compiled: Map.put(engine.compiled, path, Function.capture(module, function, arity)),
            arities: Map.put(engine.arities, path, arity)
        }
    end)
  end

  # -- pulses (spec/02 §8.2) ---------------------------------------------------------------

  @doc """
  The sources' latest deliveries and their schemas, each by name, shown to the engine at
  the owner's monotonic millisecond `now` (spec/02 §8.2): every derived source that reads
  a source whose delivery is not the one last seen is marked, and the first mark makes the
  next pulse due `debounce` later.
  """
  @spec push(t(), map(), map(), integer()) :: t()
  def push(%__MODULE__{} = engine, deliveries, schemas, now) do
    read = for {{:source, name}, _readers} <- engine.readers, do: name

    Enum.reduce(read, engine, fn name, engine ->
      delivery = by_name(deliveries, name)

      engine = %{
        engine
        | source_schemas: put_present(engine.source_schemas, name, by_name(schemas, name))
      }

      if delivery == Map.get(engine.seen, name) do
        engine
      else
        %{engine | seen: Map.put(engine.seen, name, delivery)} |> mark({:source, name}, now)
      end
    end)
  end

  # An owner keys its deliveries and schemas by atom or string.
  defp by_name(map, name) do
    case Names.key(map, name) do
      {:ok, key} -> Map.fetch!(map, key)
      :error -> nil
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp mark(engine, ref, now), do: mark_paths(engine, Map.get(engine.readers, ref, []), now)

  defp mark_paths(engine, [], _now), do: engine

  defp mark_paths(engine, paths, now) do
    due = engine.due || now + engine.debounce
    %{engine | marked: Enum.into(paths, engine.marked), due: due}
  end

  @doc "The monotonic millisecond the next pulse is due, or `nil` (spec/02 §8.2)."
  @spec due(t()) :: integer() | nil
  def due(%__MODULE__{due: due}), do: due

  @doc """
  The due pulse run at `now` (spec/02 §8.2): the marked sources in rank order, each at
  most once; a changed answer marks its readers, which run later in the same pulse. The
  engine is returned as it is when no pulse is due.
  """
  @spec run(t(), integer()) :: t()
  def run(%__MODULE__{due: due} = engine, now) when is_integer(due) and now >= due do
    engine =
      Enum.reduce(engine.order, engine, fn path, engine ->
        if MapSet.member?(engine.marked, path), do: compute(engine, path, now), else: engine
      end)

    %{engine | marked: MapSet.new(), due: nil}
  end

  def run(%__MODULE__{} = engine, _now), do: engine

  # One source run: its inputs gathered and windowed, checked in context, called bounded,
  # its answer held to its schema. A changed answer marks its readers.
  defp compute(engine, path, now) do
    source = Map.fetch!(engine.derived, path)

    with {:ok, inputs} <- gather(engine, path),
         {:ok, engine} <- in_context(engine, path, source, inputs),
         {:ok, fun} <- function(engine, path) do
      engine = %{engine | runs: Map.update(engine.runs, path, 1, &(&1 + 1))}

      case call(source, fun, inputs, context(engine, path, source, inputs), engine.run_opts) do
        {:ok, rows} -> answered(engine, path, source, rows, now)
        {:error, kind, detail} -> fault(engine, path, kind, detail)
      end
    else
      :waiting -> engine
      {:restricted, engine} -> engine
      :no_function -> engine
    end
  end

  # Every input's rows in its window, its schema and its delivery, or `:waiting` while
  # one has none (spec/02 §8.2).
  defp gather(engine, path) do
    Enum.reduce_while(engine.inputs[path], {:ok, []}, fn {key, name, ref, window}, {:ok, acc} ->
      case input(engine, ref) do
        {%Delivery{} = delivery, %Schema{} = schema} ->
          rows = delivery |> Delivery.rows() |> Derived.window(window, schema)
          input = %{key: key, name: name, rows: rows, schema: schema, delivery: delivery}
          {:cont, {:ok, acc ++ [input]}}

        _missing ->
          {:halt, :waiting}
      end
    end)
  end

  defp input(engine, {:source, name}), do: {engine.seen[name], engine.source_schemas[name]}

  defp input(engine, {:derived, path}),
    do: {engine.outputs[path], Map.fetch!(engine.derived, path).schema}

  # Validated given its inputs' schemas before it first runs, and again when one of their
  # versions changes (spec/02 §8.2); a refusal is the fault `:restricted`.
  defp in_context(engine, path, source, inputs) do
    key = Enum.map(inputs, & &1.schema.version)

    result =
      case Map.fetch(engine.checked, path) do
        {:ok, {^key, result}} ->
          result

        _stale ->
          schemas = Map.new(inputs, &{&1.key, &1.schema})

          Derived.validate(source,
            inputs: schemas,
            functions: engine.functions,
            operations: engine.operations
          )
      end

    engine = %{engine | checked: Map.put(engine.checked, path, {key, result})}

    case result do
      :ok -> {:ok, engine}
      {:error, errors} -> {:restricted, fault(engine, path, :restricted, errors)}
    end
  end

  # A function of two arguments' context (spec/02 §2.3), read as its inputs are: a stored
  # function's values by its literals' rule, a host's as given. `[]` for one of one.
  defp context(engine, path, source, inputs) do
    case Map.get(engine.arities, path) do
      2 -> [Context.new(inputs, &argument_key(source, &1), value(source))]
      _one -> []
    end
  end

  defp argument_key(%{elixir: elixir}, key) when is_binary(elixir), do: Spelling.spelling(key)
  defp argument_key(_source, key), do: key

  defp value(%{elixir: elixir}) when is_binary(elixir), do: &Spelling.spelling/1
  defp value(_source), do: & &1

  defp function(engine, path) do
    case Map.fetch(engine.compiled, path) do
      {:ok, fun} -> {:ok, fun}
      :error -> :no_function
    end
  end

  # One bounded call: the whole inputs, or per identity every entity's call in one batch.
  defp call(%{per: nil} = source, fun, inputs, context, opts),
    do: Sandbox.run(fun, [Derived.argument(source, inputs) | context], opts)

  defp call(source, fun, inputs, context, opts) do
    batch = fn -> Derived.per(source, inputs, &apply(fun, [&1 | context])) end

    case Sandbox.run(batch, [], opts) do
      {:ok, {:ok, rows}} -> {:ok, rows}
      {:ok, {:error, kind, detail}} -> {:error, kind, detail}
      {:error, kind, detail} -> {:error, kind, detail}
    end
  end

  # -- answers and faults (spec/02 §8.3) ---------------------------------------------------

  defp answered(engine, path, source, rows, now) do
    case Derived.conform(source, rows) do
      {:ok, rows} ->
        previous = engine.outputs[path]
        changed? = previous == nil or Delivery.rows(previous) != rows
        delivery = Delivery.new(rows, schema: Schema.version(source.schema))

        engine = %{
          engine
          | outputs: Map.put(engine.outputs, path, if(changed?, do: delivery, else: previous)),
            faults: Map.delete(engine.faults, path)
        }

        if changed?, do: mark(engine, {:derived, path}, now), else: engine

      {:error, detail} ->
        fault(engine, path, :nonconforming, detail)
    end
  end

  # The last good output stays, and nothing is marked: the pulse stops here.
  defp fault(engine, path, kind, detail),
    do: %{engine | faults: Map.put(engine.faults, path, %{kind: kind, detail: detail})}

  # -- reading it (spec/02 §8.4) -----------------------------------------------------------

  @doc """
  Every derived source's last good output by path, a `%Macaw.Data.Delivery{}` naming its
  output schema's version.
  """
  @spec outputs(t()) :: %{path() => Delivery.t()}
  def outputs(%__MODULE__{outputs: outputs}), do: outputs

  @doc "The sources some derived source reads, sorted."
  @spec sources_read(t()) :: [String.t()]
  def sources_read(%__MODULE__{inputs: inputs}) do
    inputs
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(fn
      {_key, _name, {:source, source}, _window} -> [source]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Every derived source's output schema, by path."
  @spec schemas(t()) :: %{path() => Schema.t()}
  def schemas(%__MODULE__{derived: derived}),
    do: Map.new(derived, fn {path, source} -> {path, source.schema} end)

  @doc """
  Every derived source's state by path (spec/02 §8.3): `:loading` before its first
  answer, `:live` after, and `{:down, {:derived, id, kind}}` while it fails.
  """
  @spec status(t()) :: %{path() => :loading | :live | {:down, term()}}
  def status(%__MODULE__{} = engine) do
    Map.new(engine.derived, fn {path, source} ->
      state =
        case {Map.fetch(engine.faults, path), Map.has_key?(engine.outputs, path)} do
          {{:ok, %{kind: kind}}, _output} -> {:down, {:derived, source.id, kind}}
          {:error, true} -> :live
          {:error, false} -> :loading
        end

      {path, state}
    end)
  end

  @doc "Every failing derived source's fault by path, `%{kind: kind, detail: detail}`."
  @spec faults(t()) :: %{path() => fault()}
  def faults(%__MODULE__{faults: faults}), do: faults

  @doc "How many times each derived source has run, by path."
  @spec runs(t()) :: %{path() => non_neg_integer()}
  def runs(%__MODULE__{} = engine),
    do: Map.new(engine.derived, fn {path, _source} -> {path, Map.get(engine.runs, path, 0)} end)

  @doc "As `source/3` with no options."
  @spec source(t(), list()) :: Output.t()
  def source(engine, path), do: source(engine, path, [])

  @doc """
  The derived source at `path` as a `Macaw.Data.Source` (spec/02 §8.5): a
  `%Macaw.Data.Derived.Output{}` over its last good output and its output schema.
  `viewer_independent:` is the owner's to declare (`false`): the engine sees its inputs'
  deliveries, not their descriptions.
  """
  @spec source(t(), list(), keyword()) :: Output.t()
  def source(%__MODULE__{} = engine, path, opts) when is_list(path) do
    opts = Keyword.validate!(opts, viewer_independent: false)
    path = Enum.map(path, &Names.name/1)
    %{schema: schema} = Map.fetch!(engine.derived, path)

    %Output{
      schema: schema,
      delivery: Map.get(engine.outputs, path),
      viewer_independent: opts[:viewer_independent]
    }
  end
end
