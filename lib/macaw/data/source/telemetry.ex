defmodule Macaw.Data.Source.Telemetry do
  @moduledoc """
  An in-process `:telemetry` collector, one push source per metric (spec/01 §10.3).

  `start_link(metrics: definitions)` attaches one handler for the definitions' events and
  collects. A definition is a `Telemetry.Metrics` struct, read by its fields (`name`,
  `event_name`, `measurement`, `tags`, `tag_values`, `keep`, `unit`, `description`,
  `reporter_options`) and its struct's name, so this library takes no dependency on
  `telemetry_metrics`. **`:telemetry` itself is optional:** without it the module compiles
  and `start_link/1` answers `{:error, :no_telemetry}`.

  Each metric is a source (`sources/1`, `source/2`) whose rows are `%{t: DateTime, value:
  v}` plus the metric's tags, and whose schema says so: `t` the `:time` window field;
  `value` labeled with the definition's description (else its name), in the definition's
  unit as a UCUM code (`Macaw.Data.Unit.from_telemetry/1`) with the quantity it implies,
  each tag a category. A counter's value is the count so far for its tags and a sum's the
  running total; a last value's, a summary's and a distribution's the measurement.
  `value`'s `metric_kind` is `:counter` for a counter or a sum and `:gauge` otherwise. The
  definition's `reporter_options[:macaw]` (`facts_key:` names another key) adds what only
  the application knows of it, exactly `polarity`, `bounds`, `target` and `metric_kind`,
  the last overriding the inference:

      summary("http.request.duration",
        unit: {:native, :millisecond},
        reporter_options: [macaw: [polarity: :lower_is_better, bounds: [0, nil], target: 250]]
      )

  The collector stamps every row on receipt with its own clock, strictly increasing, and
  keeps the newest `keep:` rows of each metric. Each metric honors a window of `DateTime`
  bounds, served up to the request's `now` and never past it, so one request with one
  `now` has one answer (spec/01 §2.3), and pushes (`Macaw.Data.Source.Push`): its schema
  first at subscription, then every `every:` milliseconds an increment of the rows new
  since the last flush, numbered from 1 for each subscription. A fetch under a
  subscription is its snapshot: it states the number of the last increment sent as its
  `position`, and leaves out the rows waiting for the next flush (spec/01 §4.1). Every
  delivery's rows are a `Macaw.Data.Table` of the metric's origin.

  A call to a collector that is gone answers `{:error, :noproc}`, one that does not answer
  in time `{:error, :timeout}`: the caller is never linked to the collector's fate.

  Ported from visualize's `Visualize.Feed.Telemetry`.
  """

  use GenServer

  @behaviour Macaw.Data.Source

  @compile {:no_warn_undefined, :telemetry}

  import Macaw.Data.Lists, only: [is_proper_list: 1]

  alias Macaw.Data.{Delivery, Fault, Quantity, Schema, Table, Unit}
  alias Macaw.Data.Source.{Description, Push, Request}

  @enforce_keys [:server, :metric]
  defstruct [:server, :metric]

  @type t :: %__MODULE__{server: GenServer.server(), metric: String.t()}

  @kinds %{
    Telemetry.Metrics.Counter => :counter,
    Telemetry.Metrics.Sum => :sum,
    Telemetry.Metrics.LastValue => :last_value,
    Telemetry.Metrics.Summary => :summary,
    Telemetry.Metrics.Distribution => :distribution
  }

  # The `value` field's metric kind, by the definition's kind.
  @metric_kinds %{
    counter: :counter,
    sum: :counter,
    last_value: :gauge,
    summary: :gauge,
    distribution: :gauge
  }

  # The facts the reporter options may say of `value`.
  @facts [:polarity, :bounds, :target, :metric_kind]

  # How long a source's call waits for the collector before answering `{:error, :timeout}`.
  @call_timeout 5_000

  @defaults [metrics: nil, keep: 10_000, every: 1000, clock: nil, name: nil, facts_key: :macaw]

  # -- starting -----------------------------------------------------------------------------

  @doc """
  The collector over `metrics:`, a list of `Telemetry.Metrics` definitions, attached and
  linked to the caller: `{:ok, pid}`, or `{:error, reason}` with nothing started. Options:
  `name:`, `keep:` (rows kept per metric, `10_000`), `every:` (the push interval in
  milliseconds, `1000`; `nil` pushes only on `flush/1`), `clock:` (a function of no
  argument answering microseconds, `System.os_time(:microsecond)` by default) and
  `facts_key:` (the reporter options' key for the application's facts, `:macaw`).

  The definitions and options are judged in the caller, before anything starts, every
  fault at once (spec/00 §5): `{[:metrics], :required}`; `{[:metrics], {:type,
  :metrics}}` for anything but a proper list; `{[:metrics, i], {:type, :metric}}` for an
  element that is no `Telemetry.Metrics` definition; `{[:metrics, i | path], reason}` for
  facts the schema refuses, or a fact key it does not take; `{[key], {:type, type}}` for
  an option of the wrong type and `{[key], :unknown_key}` for one it does not take.
  Without `:telemetry` it is `{:error, :no_telemetry}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start() | {:error, term()}
  def start_link(opts) do
    with :ok <- telemetry(),
         {:ok, opts} <- Macaw.Data.Options.known(opts, @defaults),
         :ok <- option_faults(opts),
         {:ok, metrics} <- metrics(opts[:metrics], opts[:facts_key]) do
      init = [metrics: metrics, keep: opts[:keep], every: opts[:every], clock: opts[:clock]]
      GenServer.start_link(__MODULE__, init, if(opts[:name], do: [name: opts[:name]], else: []))
    end
  end

  defp telemetry do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :attach_many, 4),
      do: :ok,
      else: {:error, :no_telemetry}
  end

  defp option_faults(opts) do
    faults =
      for {key, ok?, type} <- [
            {:metrics, opts[:metrics] != nil, nil},
            {:keep, is_integer(opts[:keep]) and opts[:keep] > 0, :pos_integer},
            {:every, opts[:every] == nil or (is_integer(opts[:every]) and opts[:every] > 0),
             :pos_integer},
            {:clock, opts[:clock] == nil or is_function(opts[:clock], 0), :clock},
            {:name, opts[:name] == nil or is_atom(opts[:name]) or is_tuple(opts[:name]), :name},
            {:facts_key, is_atom(opts[:facts_key]), :atom}
          ],
          not ok? do
        if type, do: {[key], {:type, type}}, else: {[key], :required}
      end

    if faults == [], do: :ok, else: {:error, faults}
  end

  @doc "As `start_link/1`, the pid alone, raising `Macaw.Data.Error` naming the faults."
  @spec start_link!(keyword()) :: pid()
  def start_link!(opts) do
    case start_link(opts) do
      {:ok, pid} ->
        pid

      {:error, reason} ->
        raise Macaw.Data.Error,
          reason: reason,
          what: "not a telemetry collector",
          words: &words/1
    end
  end

  @doc "Each metric's source, by its dotted name (`\"vm.memory.total\"`): `{:ok, sources}` or the call's error."
  @spec sources(GenServer.server()) :: {:ok, %{String.t() => t()}} | {:error, term()}
  def sources(server) do
    with {:ok, names} <- call(server, :names),
         do: {:ok, Map.new(names, &{&1, %__MODULE__{server: server, metric: &1}})}
  end

  @doc "One metric's source, by its dotted name; a name the collector lacks answers `{:error, {:unknown_metric, name}}` when it is asked."
  @spec source(GenServer.server(), String.t()) :: t()
  def source(server, name) when is_binary(name), do: %__MODULE__{server: server, metric: name}

  @doc "Every subscriber sent the rows new since the last flush, now: `:ok`, or the call's error."
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(server), do: call(server, :flush)

  # -- the source ------------------------------------------------------------------------------

  @impl Macaw.Data.Source
  def describe(%__MODULE__{server: server, metric: metric}, _context),
    do: call(server, {:describe, metric})

  # Only the window is served: a region and `latest` are finishing's. A fetch under a
  # subscription is its snapshot, at the position of its last increment.
  @impl Macaw.Data.Source
  def fetch(%__MODULE__{server: server, metric: metric}, %Request{window: window} = request),
    do: call(server, {:fetch, metric, window, request.now, request.subscription})

  @impl Macaw.Data.Source
  def subscribe(%__MODULE__{server: server, metric: metric}, pid) when is_pid(pid),
    do: call(server, {:subscribe, metric, pid})

  @impl Macaw.Data.Source
  def unsubscribe(%__MODULE__{server: server, metric: metric}, ref) do
    case call(server, {:unsubscribe, metric, ref}) do
      {:error, _reason} -> :ok
      :ok -> :ok
    end
  end

  # A call that answers a value whatever the collector does: it monitors the collector
  # instead of linking the caller's fate to it, and the monitor is an alias, so a reply
  # that arrives after the timeout is dropped rather than left in the caller's mailbox.
  defp call(server, request) do
    case GenServer.whereis(server) do
      nil ->
        {:error, :noproc}

      pid ->
        ref = Process.monitor(pid, alias: :demonitor)
        send(pid, {:"$gen_call", {ref, ref}, request})

        receive do
          {^ref, reply} ->
            Process.demonitor(ref, [:flush])
            reply

          {:DOWN, ^ref, :process, _pid, :noproc} ->
            {:error, :noproc}

          {:DOWN, ^ref, :process, _pid, reason} ->
            {:error, {:down, reason}}
        after
          @call_timeout ->
            Process.demonitor(ref, [:flush])
            {:error, :timeout}
        end
    end
  end

  # -- the handler, in the emitting process -----------------------------------------------------

  @doc false
  # Runs in the process that emits the event, as a reporter's handler does: `keep`, the
  # measurement and the tags are read here, and the collector only stamps and keeps.
  def handle_event(event, measurements, metadata, %{server: server, events: events}) do
    for {index, kind, metric} <- Map.get(events, event, []),
        keep?(metric, metadata, measurements) do
      case measure(kind, metric, measurements, metadata) do
        nil -> :skipped
        value -> send(server, {:measure, index, value, tags(metric, metadata)})
      end
    end

    :ok
  end

  defp keep?(metric, metadata, measurements) do
    case Map.get(metric, :keep) do
      nil -> true
      keep when is_function(keep, 1) -> keep.(metadata)
      keep when is_function(keep, 2) -> keep.(metadata, measurements)
    end
  end

  # A counter counts the event whatever it measured; every other kind reads its measurement.
  defp measure(:counter, _metric, _measurements, _metadata), do: 1

  defp measure(_kind, %{measurement: m}, measurements, _metadata) when is_atom(m),
    do: Map.get(measurements, m)

  defp measure(_kind, %{measurement: m}, measurements, _metadata) when is_function(m, 1),
    do: m.(measurements)

  defp measure(_kind, %{measurement: m}, measurements, metadata) when is_function(m, 2),
    do: m.(measurements, metadata)

  defp tags(%{tags: []}, _metadata), do: %{}

  defp tags(%{tags: tags} = metric, metadata) do
    values = (Map.get(metric, :tag_values) || (& &1)).(metadata)
    Map.new(tags, &{&1, Map.get(values, &1)})
  end

  # -- the metrics, judged in the caller --------------------------------------------------------

  defp metrics(definitions, facts_key) when is_proper_list(definitions) do
    shared =
      definitions
      |> Enum.filter(&definition?/1)
      |> Enum.map(&dotted/1)
      |> Enum.frequencies()

    {metrics, faults} =
      definitions
      |> Enum.with_index()
      |> Enum.reduce({%{}, []}, fn {definition, index}, {metrics, faults} ->
        case metric(definition, shared, facts_key) do
          {:ok, m} ->
            {Map.put(metrics, index, m), faults}

          {:error, found} ->
            {metrics, faults ++ for({path, r} <- found, do: {[:metrics, index | path], r})}
        end
      end)

    if faults == [], do: {:ok, metrics}, else: {:error, faults}
  end

  defp metrics(_definitions, _facts_key), do: {:error, [{[:metrics], {:type, :metrics}}]}

  # A definition is a struct of one of the five kinds with the fields this reads.
  defp definition?(%struct{name: name, event_name: event, tags: tags} = d)
       when is_map_key(@kinds, struct) and is_list(name) and is_list(event) and is_list(tags),
       do: Map.has_key?(d, :measurement) and Map.has_key?(d, :unit)

  defp definition?(_other), do: false

  defp dotted(definition), do: Enum.map_join(definition.name, ".", &to_string/1)

  # A metric's source is its dotted name; two definitions of one name (a summary and a
  # counter of `duration`) are each keyed by their kind as well.
  defp metric(definition, shared, facts_key) do
    if definition?(definition) do
      kind = Map.fetch!(@kinds, definition.__struct__)
      dotted = dotted(definition)
      name = if shared[dotted] > 1, do: "#{dotted}:#{kind}", else: dotted

      with {:ok, schema} <- schema(kind, dotted, definition, facts_key) do
        {:ok,
         %{
           definition: definition,
           kind: kind,
           name: name,
           schema: schema,
           rows: :queue.new(),
           count: 0,
           fresh: [],
           totals: %{},
           coverage: nil
         }}
      end
    else
      {:error, [{[], {:type, :metric}}]}
    end
  end

  defp schema(kind, name, definition, facts_key) do
    with {:ok, facts} <- facts(definition, facts_key) do
      value =
        %{type: :number, label: Map.get(definition, :description) || name}
        |> Map.merge(measure_of(kind, definition.unit))
        |> Map.put(:metric_kind, Map.fetch!(@metric_kinds, kind))
        |> Map.merge(facts)

      definition.tags
      |> Map.new(&{&1, %{type: :category}})
      |> Map.merge(%{t: %{type: :time, label: "Time"}, value: value})
      |> Schema.new()
    end
  end

  # The facts the application says of `value`, under the reporter options' key (a keyword
  # list, as a reporter's options are): exactly `@facts`, any other key refused as the
  # schema refuses a key it does not know. Their values are the schema's to check.
  defp facts(definition, facts_key) do
    options = Map.get(definition, :reporter_options) || []
    facts = if Keyword.keyword?(options), do: Keyword.get(options, facts_key, []), else: nil

    cond do
      not Keyword.keyword?(options) -> {:error, [{[:reporter_options], {:type, :keyword}}]}
      Keyword.keyword?(facts) -> known(Map.new(facts))
      true -> {:error, [{[:value], {:type, :description}}]}
    end
  end

  defp known(facts) do
    case facts |> Map.keys() |> Enum.reject(&(&1 in @facts)) |> Enum.sort() do
      [] -> {:ok, facts}
      unknown -> {:error, Enum.map(unknown, &{[:value, &1], :unknown_key})}
    end
  end

  # A counter counts events, whatever unit its definition gives; a unit the mapping
  # refuses leaves the value without a unit rather than a guess.
  defp measure_of(:counter, _unit), do: %{unit: "1", quantity: quantity("1")}

  defp measure_of(_kind, unit) do
    case Unit.from_telemetry(unit) do
      {:ok, code} ->
        Map.reject(%{unit: code, quantity: quantity(code)}, fn {_k, v} -> is_nil(v) end)

      {:error, _reason} ->
        %{}
    end
  end

  defp quantity(code) do
    case Quantity.of_unit(code) do
      {:ok, quantity} -> quantity
      {:error, _reason} -> nil
    end
  end

  # -- the collector --------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    clock = opts[:clock] || fn -> System.os_time(:microsecond) end
    Process.flag(:trap_exit, true)
    {:ok, attach(opts[:metrics], opts, clock)}
  end

  defp attach(metrics, opts, clock) do
    events =
      Enum.group_by(
        Enum.sort(metrics),
        fn {_index, m} -> m.definition.event_name end,
        fn {index, m} -> {index, m.kind, m.definition} end
      )

    id = {__MODULE__, self()}

    :ok =
      :telemetry.attach_many(id, Map.keys(events), &__MODULE__.handle_event/4, %{
        server: self(),
        events: events
      })

    started = clock.()
    if opts[:every], do: Process.send_after(self(), :flush, opts[:every])

    %{
      id: id,
      metrics: metrics,
      names: Map.new(metrics, fn {index, m} -> {m.name, index} end),
      subscribers: %{},
      keep: opts[:keep],
      every: opts[:every],
      clock: clock,
      last: started,
      started: started
    }
  end

  @impl GenServer
  def handle_call(:names, _from, state),
    do:
      {:reply, {:ok, state.metrics |> Map.values() |> Enum.map(& &1.name) |> Enum.sort()}, state}

  def handle_call(:flush, _from, state), do: {:reply, :ok, push(state)}

  def handle_call({:describe, name}, _from, state) do
    reply =
      with {:ok, m} <- lookup(state, name),
           do: {:ok, %Description{schema: m.schema, supports: [:window, :push]}}

    {:reply, reply, state}
  end

  def handle_call({:fetch, name, window, now, subscription}, _from, state) do
    reply =
      with {:ok, m} <- lookup(state, name),
           {:ok, from, to} <- bounds(window) do
        at = snapshot(state, name, subscription)
        served(m, from, to, DateTime.to_unix(now, :microsecond), at, state)
      end

    {:reply, reply, state}
  end

  def handle_call({:subscribe, name, pid}, _from, state) do
    case lookup(state, name) do
      {:ok, m} ->
        ref = make_ref()
        monitor = Process.monitor(pid)
        # The handshake: the schema before any delivery, before `subscribe/2` returns.
        send(pid, Push.schema_message(ref, m.schema))
        subscribers = Map.put(state.subscribers, ref, {name, pid, monitor, 0})
        {:reply, {:ok, ref}, %{state | subscribers: subscribers}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:unsubscribe, _name, ref}, _from, state) do
    case Map.pop(state.subscribers, ref) do
      {{_name, _pid, monitor, _seq}, subscribers} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, %{state | subscribers: subscribers}}

      {nil, _subscribers} ->
        {:reply, :ok, state}
    end
  end

  defp lookup(state, name) do
    case Map.fetch(state.names, name) do
      {:ok, index} -> {:ok, Map.fetch!(state.metrics, index)}
      :error -> {:error, {:unknown_metric, name}}
    end
  end

  # A window's bounds in microseconds: `DateTime` or `nil`, anything else refused.
  defp bounds(nil), do: {:ok, nil, nil}

  defp bounds([from, to] = window) do
    case {micro(from), micro(to)} do
      {{:ok, f}, {:ok, t}} -> {:ok, f, t}
      _other -> {:error, {:window, window}}
    end
  end

  defp bounds(window), do: {:error, {:window, window}}

  defp micro(nil), do: {:ok, nil}
  defp micro(%DateTime{} = time), do: {:ok, DateTime.to_unix(time, :microsecond)}
  defp micro(_other), do: :error

  # A fetch's subscription, when it is one of this metric's: the number of its last
  # increment, which a snapshot for it reflects (spec/01 §4.1); `nil` otherwise.
  defp snapshot(_state, _name, nil), do: nil

  defp snapshot(state, name, ref) do
    case Map.fetch(state.subscribers, ref) do
      {:ok, {^name, _pid, _monitor, seq}} -> seq
      _other -> nil
    end
  end

  # The rows within `[from, to]`, up to the request's `now`: a row stamped after it is not
  # served, so an event between two fetches at one `now` changes neither answer. The
  # window starts where the collector's data does, and a `from` before that is capped. A
  # snapshot at `position` leaves out the rows waiting for the next flush: they are the
  # next increment's, numbered past it.
  defp served(m, from, to, now, position, state) do
    coverage = m.coverage || state.started
    upper = if to, do: min(to, now), else: now
    lower = if from, do: max(from, coverage), else: coverage
    lower = min(lower, upper)
    kept = :queue.to_list(m.rows)
    kept = if position, do: Enum.drop(kept, -length(m.fresh)), else: kept

    rows =
      for {stamp, row} <- kept,
          (from == nil or stamp >= from) and stamp <= upper,
          do: row

    with {:ok, table} <- table(m, rows) do
      Delivery.new(table,
        served: [
          window: [datetime(lower), datetime(upper)],
          capped: from != nil and from < coverage,
          position: position
        ],
        schema: Schema.version(m.schema)
      )
    end
  end

  # The rows as a table of the metric's origin: a column per field of the schema, of its
  # type, `t` the window field. The collector stamps on receipt at no fixed rate, so its
  # chunks are runs of rows rather than spans of time.
  defp table(m, rows) do
    columns =
      for {name, %{type: type}} <- Enum.sort(m.schema.fields),
          do: {name, type, Enum.map(rows, &Table.get(&1, name))}

    Table.new(columns, origin: %{source: m.name, resolution: nil, window: "t", span: nil})
  end

  defp datetime(micro), do: DateTime.from_unix!(micro, :microsecond)

  @impl GenServer
  def handle_info({:measure, index, value, tags}, state) do
    stamp = max(state.clock.(), state.last + 1)
    m = Map.fetch!(state.metrics, index)
    {value, totals} = shown(m.kind, value, tags, m.totals)
    row = tags |> Map.put(:t, datetime(stamp)) |> Map.put(:value, value)
    fresh = if subscribed?(state, m.name), do: [row | m.fresh], else: m.fresh
    m = retained(%{m | totals: totals, fresh: fresh}, {stamp, row}, state.keep)
    {:noreply, %{state | last: stamp, metrics: Map.put(state.metrics, index, m)}}
  end

  def handle_info(:flush, state) do
    if state.every, do: Process.send_after(self(), :flush, state.every)
    {:noreply, push(state)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    subscribers = Map.reject(state.subscribers, fn {_ref, {_n, _p, m, _s}} -> m == monitor end)
    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl GenServer
  def terminate(_reason, state), do: :telemetry.detach(state.id)

  # Rows wait for a flush only while someone will receive them.
  defp subscribed?(state, name),
    do: Enum.any?(state.subscribers, fn {_ref, {n, _pid, _monitor, _seq}} -> n == name end)

  # What a reporter shows: a counter's count so far and a sum's running total, per tag set.
  defp shown(kind, value, tags, totals) when kind in [:counter, :sum] do
    total = Map.get(totals, tags, 0) + value
    {total, Map.put(totals, tags, total)}
  end

  defp shown(_kind, value, _tags, totals), do: {value, totals}

  # The newest `keep` rows; once one is dropped the collector covers from its oldest.
  defp retained(m, entry, keep) do
    rows = :queue.in(entry, m.rows)

    if m.count + 1 > keep do
      {{:value, _dropped}, rows} = :queue.out(rows)
      {:value, {oldest, _row}} = :queue.peek(rows)
      %{m | rows: rows, coverage: oldest}
    else
      %{m | rows: rows, count: m.count + 1}
    end
  end

  # Each metric's rows since the last flush, one increment to each of its subscribers,
  # numbered one past the subscription's last.
  defp push(state) do
    Enum.reduce(state.metrics, state, fn
      {_index, %{fresh: []}}, state ->
        state

      {index, m}, state ->
        rows = Enum.reverse(m.fresh)
        metrics = Map.put(state.metrics, index, %{m | fresh: []})

        case increment(m, rows) do
          {:ok, delivery} ->
            subscribers =
              Map.new(state.subscribers, fn
                {ref, {name, pid, monitor, seq}} when name == m.name ->
                  send(pid, Push.increment_message(ref, seq + 1, delivery))
                  {ref, {name, pid, monitor, seq + 1}}

                other ->
                  other
              end)

            %{state | subscribers: subscribers, metrics: metrics}

          # Rows a measurement made that no table holds (a value no number) are dropped
          # with the flush rather than stopping the collector.
          {:error, _faults} ->
            %{state | metrics: metrics}
        end
    end)
  end

  defp increment(m, rows) do
    with {:ok, table} <- table(m, rows) do
      Delivery.new(table,
        served: [window: [hd(rows).t, List.last(rows).t]],
        schema: Schema.version(m.schema)
      )
    end
  end

  @doc "A reason's words (spec/00 §5): this module's, else the library's."
  @spec format_error(term()) :: String.t()
  def format_error(reason), do: words(reason) || Fault.sentence(reason, words: &words/1)

  @doc false
  @spec words(term()) :: String.t() | nil
  def words(:no_telemetry), do: "the :telemetry application is not available"
  def words(:noproc), do: "the collector is not running"
  def words(:timeout), do: "the collector did not answer in time"
  def words({:unknown_metric, name}), do: "#{inspect(name)} is not a metric the collector holds"
  def words({:type, :metrics}), do: "must be a list of Telemetry.Metrics definitions"
  def words({:type, :metric}), do: "must be a Telemetry.Metrics definition"
  def words({:type, :pos_integer}), do: "must be a positive integer"
  def words({:type, :clock}), do: "must be a function of no argument answering microseconds"
  def words({:type, :name}), do: "must be a process name"
  def words({:type, :atom}), do: "must be an atom"
  def words({:type, :description}), do: "must be a keyword list of facts"
  def words({:window, _window}), do: "the window is not two DateTime bounds or nil"
  def words(_reason), do: nil
end
