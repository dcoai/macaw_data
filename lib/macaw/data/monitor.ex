defmodule Macaw.Data.Monitor do
  @moduledoc """
  The loop over a set of sources, as a value (spec/01 §6.3): subscribe where a source
  pushes, poll where it cannot, ask each source with a `Macaw.Data.Source.Request` whose
  `now` is the owner's clock, finish each answer, and hand each reader one finished
  `Macaw.Data.Delivery`, pooled at the largest budget and each reduced to its own
  (spec/01 §6.1).

  **It is not a process.** The process that owns the sources (a page's, a LiveView's, a
  board's) holds the monitor in its state, calls `tick/2` each frame and
  `handle_message/2` from its `handle_info/2`, and reads `deliveries/1` and `status/1`.
  The process that made the monitor is the one subscribed, whichever process ticks it, so
  the pushes arrive in its mailbox. The monitor runs nothing of its own: describe, fetch
  and subscribe are the source contract's (spec/01 §2), called in the caller.

  - **Sources** are named, each a source (described with no context) or `{source,
    context}`. **Readers** are named, each reading one source with its request fields
    (`ask`): `window`, `box`, `region`, `latest`, `order`, `params`, `as_of`, `viewer`,
    `budget` and `reduce`. A request's `now` is `tick/2`'s `at:`; a `subscription` is the
    monitor's.
  - **Readers of one source asking one request but for their budgets and reducers are one
    pool:** one subscription, one holding, one fetch at `Macaw.Data.Source.Finish.pooled/1`
    of their requests, the holding finished once for the request, then each reader
    reduced its own way (`Macaw.Data.Source.Finish.reduce/5` with its request) through the
    pool's `Macaw.Data.Operations.Cache`, so a reduction costs the chunks that changed.
  - **A pool's holding is a `Macaw.Data.Source.Push`:** a fetch is handed to it as a
    snapshot by its position, and every message buffers in it until the next tick drains
    them: one drain, one trim and one finishing per pool per tick, whatever the push rate.
    A gap or a change of resolution is answered by a fetch. A sliding window drops the
    holding's chunks before it. A pull pool is fetched every `every:` milliseconds.
  - **Errors and staleness are states,** never raises: `status/1` is each reader's
    `:loading`, `:live`, `:stale` or `{:down, reason}`. A source that fails to describe,
    subscribe or fetch is asked again after `every:`, doubled at each consecutive failure
    up to `backoff_max:`; one live and unanswered past `stale_after:` is `:stale`.

  Ported from visualize's `Visualize.Feed.Monitor`, its slots become readers.

  ## Examples

      iex> alias Macaw.Data.Monitor
      iex> alias Macaw.Data.Source.Signal
      iex> sources = %{wave: Signal.new!(:sine, [:t, :v], window: 100, tick: 500)}
      iex> readers = %{chart: [source: :wave, ask: [budget: 20]], table: [source: :wave, ask: [budget: 50]]}
      iex> {:ok, monitor} = Monitor.new(sources, readers)
      iex> {:ok, monitor} = Monitor.tick(monitor, now: 0, at: ~U[2026-11-01 00:00:00Z])
      iex> Monitor.status(monitor)
      %{chart: :live, table: :live}
      iex> %{chart: chart, table: table} = Monitor.deliveries(monitor)
      iex> {Macaw.Data.Table.size(chart.rows), Macaw.Data.Table.size(table.rows), chart.served.reduced_by}
      {20, 50, :runtime}
  """

  alias Macaw.Data.{Delivery, Fault, Schema, Source, Window}
  alias Macaw.Data.Monitor.Given
  alias Macaw.Data.Operations.Cache, as: Parts
  alias Macaw.Data.Schema.Cache
  alias Macaw.Data.Source.{Description, Finish, Push, Request}

  @defaults [every: 1000, backoff_max: 30_000, stale_after: nil, limit: 100_000]

  defstruct sources: %{},
            readers: %{},
            pools: %{},
            refs: %{},
            cache: %Cache{},
            every: 1000,
            backoff_max: 30_000,
            stale_after: nil,
            limit: 100_000,
            owner: nil

  @typedoc "A source's or a reader's name: any term."
  @type name :: term()

  @type status :: :loading | :live | :stale | {:down, term()}

  @typedoc "A source: described with no context, or a source and its context."
  @type source :: Source.t() | {Source.t(), term()}

  @typedoc "A reader: the source it reads and its request fields."
  @type reader ::
          [source: name(), ask: keyword() | map()] | %{source: name(), ask: keyword() | map()}

  @type t :: %__MODULE__{
          sources: %{name() => map()},
          readers: %{name() => map()},
          pools: %{term() => map()},
          refs: %{reference() => term()},
          cache: Cache.t(),
          every: non_neg_integer(),
          backoff_max: pos_integer(),
          stale_after: pos_integer() | nil,
          limit: integer(),
          owner: pid()
        }

  # -- building --------------------------------------------------------------------------------

  @doc """
  A monitor over sources and readers by name, calling nothing: `{:ok, monitor}`, or every
  fault at once (spec/00 §5). Options: `every:` (a pull pool's poll interval and the first
  retry, milliseconds, `1000`), `backoff_max:` (the longest retry, `30_000`),
  `stale_after:` (milliseconds without an answer before a live reader is `:stale`, `nil`
  for never) and `limit:` (the most rows held for a source whose schema has no window
  field, `Macaw.Data.Source.Push.new/3`'s, `100_000`).

  The faults: `{[:sources], {:type, :map}}` and `{[:readers], {:type, :map}}`;
  `{[:sources, name], {:type, :source}}` for an entry that is no struct nor `{struct,
  context}`; `{[:readers, name], {:type, :reader}}` for a reader that is no keyword list
  or map of `source` and `ask`; `{[:readers, name, :source], {:unknown_source, source}}`
  for a source the monitor lacks; `{[:readers, name, :ask, key], :unknown_key}` for a
  field a reader does not ask, and `Macaw.Data.Source.Request.new/1`'s faults under
  `[:readers, name, :ask]`; and an option's `{[key], {:type, type}}` or `{[key],
  :unknown_key}`.
  """
  @spec new(term(), term(), keyword()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def new(sources, readers, opts \\ []) do
    with {:ok, opts} <- Macaw.Data.Options.known(opts, @defaults) do
      faults = Given.options(opts) ++ Given.sources(sources)
      {readers, reader_faults} = Given.readers(readers, sources)

      case faults ++ reader_faults do
        [] ->
          monitor = struct!(__MODULE__, [owner: self()] ++ opts)
          monitor = Enum.reduce(sources, monitor, fn {name, s}, m -> put_entry(m, name, s) end)
          {:ok, Enum.reduce(readers, monitor, fn {name, r}, m -> join(m, name, r) end)}

        faults ->
          {:error, faults}
      end
    end
  end

  @doc "As `new/3`, the monitor alone, raising `Macaw.Data.Error` naming the faults."
  @spec new!(term(), term(), keyword()) :: t()
  def new!(sources, readers, opts \\ []) do
    case new(sources, readers, opts) do
      {:ok, monitor} ->
        monitor

      {:error, faults} ->
        raise Macaw.Data.Error, reason: faults, what: "not a monitor", words: &words/1
    end
  end

  defp put_entry(monitor, name, given) do
    {source, context} = Given.source(given)

    entry = %{
      source: source,
      context: context,
      description: nil,
      status: :loading,
      due: nil,
      failures: 0
    }

    %{monitor | sources: Map.put(monitor.sources, name, entry)}
  end

  # A reader joins the pool of its source and its request but for budget and reducer.
  defp join(monitor, name, %{source: source, ask: ask} = reader) do
    key = {source, Map.drop(ask, [:budget, :reduce])}
    monitor = %{monitor | readers: Map.put(monitor.readers, name, Map.put(reader, :pool, key))}

    pools =
      Map.update(monitor.pools, key, pool(source, key, [name]), fn pool ->
        %{pool | readers: Enum.sort([name | pool.readers] |> Enum.uniq()), finished: nil}
      end)

    %{monitor | pools: pools}
  end

  defp pool(source, {_source, ask}, readers) do
    %{
      source: source,
      ask: ask,
      readers: Enum.sort(readers),
      ref: nil,
      push: nil,
      received: 0,
      schema: nil,
      refetch: true,
      due: nil,
      failures: 0,
      last_ok: nil,
      status: :loading,
      error: nil,
      shared: nil,
      finished: nil,
      out: %{},
      parts: Parts.new()
    }
  end

  # -- the loop ---------------------------------------------------------------------------------

  @doc """
  One turn of the loop at `now:` (the owner's monotonic clock in milliseconds, which polls,
  retries and staleness are counted on) and `at:` (the owner's wall clock, a `DateTime`,
  every request's `now`): `{:ok, monitor}`, or `{[:now], {:type, :integer}}`, `{[:at],
  {:type, :datetime}}` and `{[key], :unknown_key}`, every one at once, with nothing done.
  Every source, in name order, is described if it is not yet and its retry is due; then
  every pool of it is subscribed where it pushes, fetched if it holds nothing, its push
  asks a refetch, its request moved or its poll is due, its buffered pushes drained into
  its holding, its chunks before the window dropped, and finished for each reader when it
  changed.
  """
  @spec tick(t(), keyword()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def tick(%__MODULE__{} = monitor, opts) do
    with {:ok, opts} <- Macaw.Data.Options.known(opts, now: nil, at: nil),
         :ok <- clock_faults(opts) do
      now = opts[:now]
      at = opts[:at]

      monitor =
        monitor.sources
        |> Map.keys()
        |> Enum.sort()
        |> Enum.reduce(monitor, &turn(&2, &1, now, at))

      {:ok, monitor}
    end
  end

  @doc "As `tick/2`, the monitor alone, raising `Macaw.Data.Error` naming the faults."
  @spec tick!(t(), keyword()) :: t()
  def tick!(%__MODULE__{} = monitor, opts) do
    case tick(monitor, opts) do
      {:ok, monitor} ->
        monitor

      {:error, faults} ->
        raise Macaw.Data.Error, reason: faults, what: "not a tick", words: &words/1
    end
  end

  defp clock_faults(opts) do
    faults =
      if(is_integer(opts[:now]), do: [], else: [{[:now], {:type, :integer}}]) ++
        if match?(%DateTime{}, opts[:at]), do: [], else: [{[:at], {:type, :datetime}}]

    if faults == [], do: :ok, else: {:error, faults}
  end

  defp turn(monitor, name, now, at) do
    monitor = described(monitor, name, now)

    case monitor.sources[name].description do
      nil ->
        monitor

      _described ->
        monitor.pools
        |> Enum.filter(fn {_key, pool} -> pool.source == name end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()
        |> Enum.reduce(monitor, &step(&2, &1, now, at))
    end
  end

  # -- 1. describe ------------------------------------------------------------------------------

  defp described(monitor, name, now) do
    entry = monitor.sources[name]

    cond do
      entry.description != nil -> monitor
      not due?(entry, now) -> monitor
      true -> describe(monitor, name, now)
    end
  end

  defp describe(monitor, name, now) do
    entry = monitor.sources[name]

    case Source.describe(entry.source, entry.context) do
      {:ok, %Description{schema: schema} = description} ->
        case Push.new(name, make_ref(), push_options(monitor, description)) do
          {:ok, _push} ->
            entry = %{entry | description: description, status: :live, due: nil, failures: 0}
            monitor = %{monitor | cache: Cache.put(monitor.cache, name, schema)}
            put_entry_state(monitor, name, entry) |> described_pools(name, schema)

          {:error, faults} ->
            failed_source(monitor, name, {:description, faults}, now)
        end

      {:error, reason} ->
        failed_source(monitor, name, reason, now)
    end
  end

  # Every pool of a source described starts holding by a push merge of its own: a pull
  # pool's under a reference no message names.
  defp described_pools(monitor, name, schema) do
    description = monitor.sources[name].description

    update_pools(monitor, name, fn pool ->
      %{
        pool
        | schema: pool.schema || schema,
          push: Push.new!(name, make_ref(), push_options(monitor, description)),
          received: 0,
          refetch: true
      }
    end)
  end

  defp failed_source(monitor, name, reason, now) do
    entry = monitor.sources[name]
    failures = entry.failures + 1

    entry = %{
      entry
      | status: {:down, reason},
        failures: failures,
        due: now + retry(monitor, failures)
    }

    put_entry_state(monitor, name, entry)
  end

  # The wait before the next try after `failures` in a row: `every:`, doubled at each,
  # never past `backoff_max:`.
  defp retry(%__MODULE__{every: every, backoff_max: max}, failures),
    do: min(every * Integer.pow(2, min(failures - 1, 30)), max)

  # The push merge's options: the monitor's cache and limit, the description's lateness
  # and chunk span. `Push.new/3` judged them when the source was described.
  defp push_options(monitor, %Description{} = description) do
    [
      cache: monitor.cache,
      limit: monitor.limit,
      lateness: description.lateness,
      chunk_span: description.chunk_span
    ]
  end

  defp due?(%{due: nil}, _now), do: true
  defp due?(%{due: due}, now), do: now >= due

  # -- 2. a pool's turn -------------------------------------------------------------------------

  defp step(monitor, key, now, at) do
    pool = monitor.pools[key]
    description = monitor.sources[pool.source].description

    case asked(monitor, pool, pool.schema || description.schema, at) do
      {:ok, request} ->
        monitor
        |> subscribed(key, description, now)
        |> fetched(key, description, now, request)
        |> drained(key, now)
        |> trimmed(key, request)
        |> finished(key, description, now, request)

      {:error, faults} ->
        # What is held is let go with the request it answered: the subscription kept, the
        # holding fetched again once a request that holds is asked.
        pool = %{
          pool
          | status: {:down, {:request, faults}},
            push:
              pool.push &&
                Push.new!(pool.source, pool.ref || make_ref(), push_options(monitor, description)),
            received: 0,
            shared: nil,
            finished: nil,
            out: %{},
            refetch: true
        }

        put_pool(monitor, key, pool)
    end
  end

  # The pool's request at `at`: its readers' shared fields, the largest of their budgets
  # (`Finish.pooled/1`), checked against the schema. A request the schema cannot answer is
  # not asked.
  defp asked(monitor, pool, schema, at) do
    with {:ok, request} <-
           Request.new(Map.merge(pool.ask, %{now: at, budget: pooled(monitor, pool, at)})),
         :ok <- Window.check(request, schema),
         do: {:ok, request}
  end

  defp pooled(monitor, pool, at) do
    pool.readers
    |> Enum.map(&reader_request(monitor, &1, at))
    |> Finish.pooled()
  end

  defp reader_request(monitor, name, at) do
    reader = monitor.readers[name]
    {:ok, request} = Request.new(Map.put(reader.ask, :now, at))
    request
  end

  defp subscribed(monitor, key, description, now) do
    pool = monitor.pools[key]

    if :push in description.supports and pool.ref == nil and due?(pool, now) do
      entry = monitor.sources[pool.source]

      case Source.subscribe(entry.source, monitor.owner) do
        {:ok, ref} ->
          push = Push.new!(pool.source, ref, push_options(monitor, description))

          %{monitor | refs: Map.put(monitor.refs, ref, key)}
          |> put_pool(key, %{pool | ref: ref, push: push, received: 0, refetch: true})

        {:error, reason} ->
          # Polled meanwhile, as a pull pool is; subscribed again when due.
          failed(monitor, key, reason, now)
      end
    else
      monitor
    end
  end

  defp failed(monitor, key, reason, now) do
    pool = monitor.pools[key]
    failures = pool.failures + 1
    due = now + retry(monitor, failures)
    put_pool(monitor, key, %{pool | status: {:down, reason}, failures: failures, due: due})
  end

  # -- 3. fetch ---------------------------------------------------------------------------------

  defp fetched(monitor, key, description, now, request) do
    if fetch?(monitor.pools[key], now),
      do: fetch(monitor, key, description, now, request),
      else: monitor
  end

  defp fetch?(%{push: push, due: due} = pool, now) do
    cond do
      Push.held(push) == nil -> due == nil or now >= due
      pool.refetch -> true
      # A gap in the numbering, or an increment at another resolution.
      Push.refetch(push) != nil -> true
      pool.ref == nil -> due == nil or now >= due
      true -> false
    end
  end

  # A fetch is the snapshot of what the source holds, handed to the merge by its position:
  # asked under the subscription, so the source says which increments it reflects. What was
  # received before it is applied first.
  defp fetch(monitor, key, description, now, request) do
    pool = monitor.pools[key]
    entry = monitor.sources[pool.source]

    case Source.fetch(entry.source, description, %{request | subscription: pool.ref}) do
      {:error, reason} ->
        failed(monitor, key, reason, now)

      {:ok, delivery} ->
        describe = describer(entry, pool.source)
        push = Push.drain(pool.push, describe)
        push = push |> Push.snapshot(handed(delivery, push, pool.schema)) |> Push.drain(describe)
        {faults, push} = Push.take_errors(push)
        pool = %{pool | received: 0, due: now + monitor.every, failures: 0}

        case Enum.find(faults, &snapshot_fault?/1) do
          nil ->
            adopted(
              monitor,
              key,
              faulted(live(%{pool | push: push, refetch: false}, now), faults)
            )

          reason ->
            put_pool(monitor, key, %{pool | push: push, status: {:down, reason}, error: reason})
        end
    end
  end

  defp describer(entry, name), do: Source.describer(%{name => {entry.source, entry.context}})

  # A fetched delivery as a snapshot: one naming no version is the described schema's, and
  # one stating no position (a pull source's, or one that does not read the request's
  # subscription) is taken at the position held.
  defp handed(%Delivery{} = delivery, push, schema) do
    served = Map.update!(delivery.served, :position, &(&1 || Push.position(push)))
    %{delivery | schema: delivery.schema || Schema.version(schema), served: served}
  end

  defp snapshot_fault?({:schema_version, _name, _version, _held}), do: true
  defp snapshot_fault?({:unknown_schema, _name, _version}), do: true
  defp snapshot_fault?({:table, _faults}), do: true
  defp snapshot_fault?(_fault), do: false

  defp faulted(pool, []), do: pool
  defp faulted(pool, faults), do: %{pool | error: List.last(faults)}

  # The schema the holding is in, from the merge's cache, put in the monitor's.
  defp adopted(monitor, key, pool) do
    with %Delivery{schema: version} <- Push.held(pool.push),
         {:ok, schema} <- Cache.fetch(Push.cache(pool.push), pool.source, version) do
      %{monitor | cache: Cache.put(monitor.cache, pool.source, schema)}
      |> put_pool(key, %{pool | schema: schema})
    else
      _none -> put_pool(monitor, key, pool)
    end
  end

  defp live(pool, now), do: %{pool | status: :live, last_ok: now, error: nil}

  # -- 4. drain ---------------------------------------------------------------------------------

  # Everything received since the last tick applied at once: one drain per tick, whatever
  # the push rate. A pool answered when a message was taken without a fault; each fault is
  # its error.
  defp drained(monitor, key, now) do
    pool = monitor.pools[key]

    if pool.push != nil and Push.pending?(pool.push) do
      entry = monitor.sources[pool.source]

      {faults, push} =
        pool.push |> Push.drain(describer(entry, pool.source)) |> Push.take_errors()

      answered? = pool.received > length(faults)
      pool = %{pool | push: push, received: 0}
      pool = if answered?, do: live(pool, now), else: pool
      adopted(monitor, key, faulted(pool, faults))
    else
      monitor
    end
  end

  # -- 5. trim ----------------------------------------------------------------------------------

  # The holding without its chunks wholly before the window: a sliding window drops the
  # oldest chunks, copying none. Rows of the first chunk kept that fall before it are the
  # finishing's.
  defp trimmed(monitor, key, %Request{window: [from, _to]}) when from != nil do
    pool = monitor.pools[key]

    case pool.push && Push.trim(pool.push, from) do
      {:ok, push} -> put_pool(monitor, key, %{pool | push: push})
      _nothing -> monitor
    end
  end

  defp trimmed(monitor, _key, _request), do: monitor

  # -- 6. finish --------------------------------------------------------------------------------

  # The holding finished for the pool's request once per change of either, its window,
  # box, region, latest and order applied whatever the source honors, since pushes merge
  # into it unasked; then each reader reduced to its own budget by its own reducer, through
  # the pool's cache. An unchanged holding asked the same keeps every reader's delivery. A
  # finishing's faults are the pool's, `{:down, {:finish, faults}}`: the last deliveries are
  # kept, and it is asked again each tick.
  defp finished(monitor, key, description, now, request) do
    pool = monitor.pools[key]

    case pool.push && Push.held(pool.push) do
      nil ->
        monitor

      held ->
        at = request.now

        readers =
          Map.new(pool.readers, fn name ->
            r = reader_request(monitor, name, at)
            {name, {r.budget, r.reduce}}
          end)

        from = {held, %{request | now: nil, subscription: nil, budget: nil}, pool.schema, readers}

        pool =
          if same?(from, pool.finished),
            do: pool,
            else: finish(monitor, pool, held, description, request, from)

        put_pool(monitor, key, stale(pool, now, monitor))
    end
  end

  # Two finishings alike: the same holding by contents, the same request and schema, and
  # the same readers' budgets and reducers.
  defp same?(_from, nil), do: false

  defp same?({held, request, schema, readers}, {held2, request2, schema2, readers2}),
    do:
      request == request2 and schema == schema2 and readers == readers2 and
        same_held?(held, held2)

  defp same_held?(a, a), do: true

  defp same_held?(
         %Delivery{rows: %Macaw.Data.Table{} = a} = d1,
         %Delivery{rows: %Macaw.Data.Table{} = b} = d2
       ),
       do: d1.served == d2.served and d1.schema == d2.schema and Macaw.Data.Table.equal?(a, b)

  defp same_held?(_a, _b), do: false

  defp finish(monitor, pool, held, description, request, from) do
    # The holding's budget is the source's to have honored; every other step is applied.
    supports = Enum.filter(description.supports, &(&1 == :budget))
    shared = %Description{schema: pool.schema, supports: supports}

    with {:ok, out} <- Finish.finish(held, shared, %{request | budget: nil, reduce: nil}),
         {:ok, outs, parts} <- reduced(monitor, pool, out, request.now) do
      parts = prune(parts, held)
      recovered(%{pool | shared: out, out: outs, parts: parts, finished: from})
    else
      {:error, faults} -> %{pool | status: {:down, {:finish, faults}}}
    end
  end

  # Each reader reduced its own way from the one finished answer: a reader's request in the
  # budget's place (spec/01 §6.1), through the pool's cache. The position handed out is no
  # snapshot's.
  defp reduced(monitor, pool, out, at) do
    out = %{out | served: %{out.served | position: nil}}

    Enum.reduce_while(pool.readers, {:ok, %{}, pool.parts}, fn name, {:ok, outs, parts} ->
      case Finish.reduce(out, pool.schema, reader_request(monitor, name, at), parts) do
        {:ok, reduced, parts} -> {:cont, {:ok, Map.put(outs, name, reduced), parts}}
        {:error, faults} -> {:halt, {:error, faults}}
      end
    end)
  end

  defp prune(parts, %Delivery{rows: %Macaw.Data.Table{} = table}), do: Parts.prune(parts, [table])
  defp prune(parts, _held), do: parts

  defp recovered(%{status: {:down, {:finish, _faults}}} = pool), do: %{pool | status: :live}
  defp recovered(pool), do: pool

  defp stale(%{status: :live, last_ok: last} = pool, now, %{stale_after: after_ms})
       when is_integer(after_ms) and is_integer(last) and now - last > after_ms,
       do: %{pool | status: :stale}

  defp stale(pool, _now, _monitor), do: pool

  # -- the owner's calls ------------------------------------------------------------------------

  @doc """
  A message the owner received: `{:ok, monitor}` with a pushed schema cached, or a
  snapshot or an increment buffered in its pool's holding for the next tick; `:ignore`
  for a message that is none of the source contract's (spec/01 §4). A push of a
  subscription the monitor no longer holds is dropped.
  """
  @spec handle_message(t(), term()) :: {:ok, t()} | :ignore
  def handle_message(%__MODULE__{} = monitor, {:macaw_source, ref, message} = received)
      when is_reference(ref) do
    with {:ok, key} <- Map.fetch(monitor.refs, ref),
         %{push: %Push{} = push} = pool <- monitor.pools[key],
         {:ok, push} <- Push.receive(push, received) do
      pool = %{pool | push: push, received: pool.received + rows_message(message)}
      {:ok, monitor |> schema_message(pool.source, message) |> put_pool(key, pool)}
    else
      _not_held -> {:ok, monitor}
    end
  end

  def handle_message(%__MODULE__{}, _message), do: :ignore

  defp schema_message(monitor, name, {:schema, %Schema{} = schema}),
    do: %{monitor | cache: Cache.put(monitor.cache, name, schema)}

  defp schema_message(monitor, _name, _message), do: monitor

  defp rows_message({:schema, _schema}), do: 0
  defp rows_message(_rows), do: 1

  @doc """
  The monitor with readers' requests changed, `%{reader => fields}` as `new/3` takes a
  reader's `ask`: `{:ok, monitor}` or the faults under `[:readers, name]`. A reader whose
  request but for budget and reducer moved leaves its pool for the pool of its new
  request. A pool all of whose readers move together keeps its subscription and holding,
  and is fetched again at the next tick unless it pushes and what it holds answers the
  new window: its window field's range starting within what it holds, everything else
  asked the same, and under `latest` a `to` no earlier. A budget or reducer that changed
  refinishes from the holding, and refetches where the source honors `:budget` and the
  pool's largest budget moved.
  """
  @spec ask(t(), term()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def ask(%__MODULE__{} = monitor, asks) when is_map(asks) and not is_struct(asks) do
    checked =
      for {name, fields} <- Enum.sort(asks) do
        case {Map.fetch(monitor.readers, name), Given.ask(fields)} do
          {:error, _} ->
            {:error, [{[:readers, name], :unknown_reader}]}

          {{:ok, _}, {:ok, ask}} ->
            {:ok, name, ask}

          {{:ok, _}, {:error, faults}} ->
            {:error, for({p, r} <- faults, do: {[:readers, name | p], r})}
        end
      end

    case for({:error, faults} <- checked, fault <- faults, do: fault) do
      [] -> {:ok, moved(monitor, for({:ok, name, ask} <- checked, do: {name, ask}))}
      faults -> {:error, faults}
    end
  end

  def ask(%__MODULE__{}, _asks), do: {:error, [{[:readers], {:type, :map}}]}

  # Readers moved to their new requests: pools that move whole are rekeyed, keeping what
  # they hold; every other reader leaves its pool and joins its new one.
  defp moved(monitor, asks) do
    budgets_before = budgets(monitor)

    by_pool = Enum.group_by(asks, fn {name, _ask} -> monitor.readers[name].pool end)

    monitor =
      Enum.reduce(by_pool, monitor, fn {key, moves}, monitor ->
        pool = monitor.pools[key]

        new_keys =
          moves
          |> Enum.map(fn {_n, ask} -> {pool.source, Map.drop(ask, [:budget, :reduce])} end)
          |> Enum.uniq()

        whole? =
          length(moves) == length(pool.readers) and match?([_], new_keys) and
            (hd(new_keys) == key or not Map.has_key?(monitor.pools, hd(new_keys)))

        if whole?,
          do: rekeyed(monitor, key, hd(new_keys), moves),
          else: Enum.reduce(moves, monitor, fn {name, ask}, m -> rejoined(m, name, ask) end)
      end)

    refetched_for_budgets(monitor, budgets_before)
  end

  defp rekeyed(monitor, key, key, moves) do
    readers =
      Enum.reduce(moves, monitor.readers, fn {name, ask}, readers ->
        Map.update!(readers, name, &%{&1 | ask: ask})
      end)

    %{monitor | readers: readers}
  end

  defp rekeyed(monitor, old_key, {_source, new_ask} = new_key, moves) do
    pool = monitor.pools[old_key]
    refetch = pool.refetch or not covers?(pool, pool.ask, new_ask)
    pool = %{pool | ask: new_ask, refetch: refetch, finished: nil}

    readers =
      Enum.reduce(moves, monitor.readers, fn {name, ask}, readers ->
        Map.update!(readers, name, &%{&1 | ask: ask, pool: new_key})
      end)

    refs = if pool.ref, do: Map.put(monitor.refs, pool.ref, new_key), else: monitor.refs
    pools = monitor.pools |> Map.delete(old_key) |> Map.put(new_key, pool)
    %{monitor | readers: readers, pools: pools, refs: refs}
  end

  # A reader leaves its pool, dropped once empty, and joins its new one, fresh unless it
  # exists.
  defp rejoined(monitor, name, ask) do
    reader = monitor.readers[name]
    monitor = left(monitor, name)
    join(monitor, name, %{source: reader.source, ask: ask})
  end

  defp left(monitor, name) do
    %{pool: key} = monitor.readers[name]
    pool = monitor.pools[key]
    readers = List.delete(pool.readers, name)
    monitor = %{monitor | readers: Map.delete(monitor.readers, name)}

    if readers == [] do
      unsubscribe(monitor, pool)

      %{
        monitor
        | pools: Map.delete(monitor.pools, key),
          refs: Map.reject(monitor.refs, fn {_r, k} -> k == key end)
      }
    else
      put_pool(monitor, key, %{
        pool
        | readers: readers,
          finished: nil,
          out: Map.delete(pool.out, name)
      })
    end
  end

  # Each pool's largest budget, by pool key.
  defp budgets(monitor) do
    at = ~U[1970-01-01 00:00:00Z]
    Map.new(monitor.pools, fn {key, pool} -> {key, pooled(monitor, pool, at)} end)
  end

  # A pool whose largest budget moved is fetched again where its source honors `:budget`:
  # it serves a new budget only if asked.
  defp refetched_for_budgets(monitor, before) do
    at = ~U[1970-01-01 00:00:00Z]

    Enum.reduce(monitor.pools, monitor, fn {key, pool}, monitor ->
      description = monitor.sources[pool.source].description
      honors? = description != nil and :budget in description.supports
      moved? = Map.get(before, key, :new) != pooled(monitor, pool, at)
      pool = %{pool | finished: nil}
      put_pool(monitor, key, %{pool | refetch: pool.refetch or (honors? and moved?)})
    end)
  end

  # Whether a push pool's holding answers the new request without a fetch: only its window
  # moved, starting within what it holds, and under `latest` with a `to` no earlier.
  defp covers?(%{ref: nil}, _was, _asked), do: false

  defp covers?(pool, was, asked) do
    Map.delete(was, :window) == Map.delete(asked, :window) and
      to_kept?(Map.get(was, :latest, false), Map.get(was, :window), Map.get(asked, :window)) and
      from_held?(pool, Map.get(asked, :window))
  end

  defp to_kept?(true, [_, old], [_, new]) do
    case {old, new} do
      {_old, nil} -> true
      {nil, _new} -> false
      {old, new} -> Window.comparable?(new, old) and Window.compare(new, old) != :lt
    end
  end

  defp to_kept?(true, _old, _new), do: false
  defp to_kept?(false, _old, _new), do: true

  defp from_held?(%{push: %Push{} = push}, [from, _to]) when from != nil do
    case Push.held(push) do
      %Delivery{served: %{window: [held, _]}} when held != nil ->
        Window.comparable?(from, held) and Window.compare(from, held) != :lt

      _none ->
        false
    end
  end

  defp from_held?(_pool, _window), do: false

  @doc """
  The monitor with readers' budgets changed, `%{reader => budget}`, each `nil` or a
  positive integer: `ask/2` with only the budget moved.
  """
  @spec budget(t(), term()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def budget(%__MODULE__{} = monitor, budgets) when is_map(budgets) and not is_struct(budgets) do
    asks =
      for {name, budget} <- budgets do
        case Map.fetch(monitor.readers, name) do
          {:ok, reader} -> {name, Map.put(reader.ask, :budget, budget)}
          :error -> {name, %{budget: budget}}
        end
      end

    ask(monitor, Map.new(asks))
  end

  def budget(%__MODULE__{}, _budgets), do: {:error, [{[:readers], {:type, :map}}]}

  @doc """
  The monitor with a source added or replaced under a name, described at the next tick:
  `{:ok, monitor}`, or `{[:sources, name], {:type, :source}}`. A replaced source's pools
  are unsubscribed and start again, its readers kept.
  """
  @spec put_source(t(), name(), term()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def put_source(%__MODULE__{} = monitor, name, given) do
    case Given.source(given) do
      nil ->
        {:error, [{[:sources, name], {:type, :source}}]}

      _source ->
        monitor =
          Enum.reduce(monitor.pools, monitor, fn {key, pool}, monitor ->
            if pool.source == name do
              unsubscribe(monitor, pool)
              refs = Map.reject(monitor.refs, fn {_r, k} -> k == key end)
              %{monitor | refs: refs} |> put_pool(key, pool(name, key, pool.readers))
            else
              monitor
            end
          end)

        {:ok, put_entry(monitor, name, given)}
    end
  end

  @doc "The monitor without a source and its readers, its pools unsubscribed."
  @spec remove_source(t(), name()) :: t()
  def remove_source(%__MODULE__{} = monitor, name) do
    monitor =
      monitor.readers
      |> Enum.filter(fn {_r, reader} -> reader.source == name end)
      |> Enum.reduce(monitor, fn {r, _reader}, m -> left(m, r) end)

    %{monitor | sources: Map.delete(monitor.sources, name)}
  end

  @doc """
  The monitor with a reader added or replaced, as `new/3` takes one: `{:ok, monitor}` or
  its faults under `[:readers, name]`.
  """
  @spec put_reader(t(), name(), term()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def put_reader(%__MODULE__{} = monitor, name, given) do
    case Given.reader(given, monitor.sources) do
      {:ok, reader} ->
        monitor = if Map.has_key?(monitor.readers, name), do: left(monitor, name), else: monitor
        {:ok, join(monitor, name, reader)}

      {:error, faults} ->
        {:error, for({path, r} <- faults, do: {[:readers, name | path], r})}
    end
  end

  @doc "The monitor without a reader; its pool unsubscribed once it has none."
  @spec remove_reader(t(), name()) :: t()
  def remove_reader(%__MODULE__{} = monitor, name) do
    if Map.has_key?(monitor.readers, name), do: left(monitor, name), else: monitor
  end

  @doc "Every pool fetched again at the next tick, push pools included, whatever it holds."
  @spec refetch(t()) :: t()
  def refetch(%__MODULE__{} = monitor),
    do: %{monitor | pools: Map.new(monitor.pools, fn {k, p} -> {k, %{p | refetch: true}} end)}

  @doc "Every subscription stopped; the monitor's end."
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = monitor) do
    Enum.each(monitor.pools, fn {_key, pool} -> unsubscribe(monitor, pool) end)
  end

  defp unsubscribe(_monitor, %{ref: nil}), do: :ok

  defp unsubscribe(monitor, %{ref: ref, source: name}) do
    case monitor.sources[name] do
      %{source: source} -> Source.unsubscribe(source, ref)
      nil -> :ok
    end
  end

  # -- the answers ------------------------------------------------------------------------------

  @doc "Each reader's finished delivery, for the readers that have one."
  @spec deliveries(t()) :: %{name() => Delivery.t()}
  def deliveries(%__MODULE__{pools: pools}) do
    for {_key, pool} <- pools, {name, out} <- pool.out, into: %{}, do: {name, out}
  end

  @doc """
  Each reader's state: `:loading` until its first answer, `:live`, `:stale` past
  `stale_after:`, or `{:down, reason}`: its source's describe error, a request its schema
  cannot answer (`{:request, faults}`), a subscribe or fetch error, a snapshot the holding
  could not take, or a finishing's faults (`{:finish, faults}`).
  """
  @spec status(t()) :: %{name() => status()}
  def status(%__MODULE__{readers: readers} = monitor) do
    Map.new(readers, fn {name, reader} ->
      source = monitor.sources[reader.source]
      pool = monitor.pools[reader.pool]

      status =
        case {source.description, source.status} do
          {nil, {:down, _} = down} -> down
          {nil, _} -> :loading
          _described -> pool.status
        end

      {name, status}
    end)
  end

  @doc "Each reader's pool's last error that left it live, for the readers that have one."
  @spec errors(t()) :: %{name() => term()}
  def errors(%__MODULE__{readers: readers, pools: pools}) do
    for {name, %{pool: key}} <- readers,
        error = pools[key].error,
        error != nil,
        into: %{},
        do: {name, error}
  end

  @doc """
  Each reader's holding, for the readers whose pool holds one: the delivery its push merge
  keeps (`Macaw.Data.Source.Push.held/1`), shared by the pool's readers. `deliveries/1` is
  it finished.
  """
  @spec held(t()) :: %{name() => Delivery.t()}
  def held(%__MODULE__{readers: readers, pools: pools}) do
    for {name, %{pool: key}} <- readers,
        %{push: %Push{} = push} <- [pools[key]],
        %Delivery{} = held <- [Push.held(push)],
        into: %{},
        do: {name, held}
  end

  @doc "The schema cache, holding every version the deliveries name, by source name."
  @spec cache(t()) :: Cache.t()
  def cache(%__MODULE__{cache: cache}), do: cache

  defp put_entry_state(monitor, name, entry),
    do: %{monitor | sources: Map.put(monitor.sources, name, entry)}

  defp put_pool(monitor, key, pool), do: %{monitor | pools: Map.put(monitor.pools, key, pool)}

  defp update_pools(monitor, name, fun) do
    pools =
      Map.new(monitor.pools, fn
        {key, %{source: ^name} = pool} -> {key, fun.(pool)}
        other -> other
      end)

    %{monitor | pools: pools}
  end

  @doc "A reason's words (spec/00 §5): this module's, else the library's."
  @spec format_error(term()) :: String.t()
  def format_error(reason), do: words(reason) || Fault.sentence(reason, words: &words/1)

  @doc false
  @spec words(term()) :: String.t() | nil
  def words({:type, :map}), do: "must be a map by name"
  def words({:type, :source}), do: "must be a source, or {source, context}"
  def words({:type, :reader}), do: "must be a keyword list or map of source and ask"
  def words({:type, :pos_integer}), do: "must be a positive integer"
  def words({:type, :non_neg_integer}), do: "must be a non-negative integer"
  def words({:type, :datetime}), do: "must be a DateTime"
  def words({:unknown_source, name}), do: "#{inspect(name)} is not a source the monitor holds"
  def words(:unknown_reader), do: "is not a reader the monitor holds"
  def words(_reason), do: nil
end
