defmodule Macaw.Data.Source.Signal do
  @moduledoc """
  A generated source (spec/01 §10.1): rows that are a pure function of the tick, so a
  design under construction moves and replays without a host supplying any data.

  A signal is a kind (`:sine`, `:square`, `:random` or `:discrete`), its fields and a
  wave's shape: `window` (rows in a tick's own window, `24`), `period` (`12`), `min` and
  `max` (`0` and `100`) and `seed` (`0`). The first field is the tick, every other a value
  column following the kind's wave, each shifted from the last so no two columns are one
  line. `rows/2` is the window of rows ending at a tick, `rows/3` the rows of a span of
  ticks: the same tick always gives the same rows.

  As a source it is pulled, never pushed. Its present tick is fixed (`tick:`, moved with
  `at/2`) or read from the request's `now`, `every:` milliseconds a tick counted from
  `origin:` (the Unix epoch by default), so one request with one `now` has one answer
  (spec/01 §2.3). Its schema describes the tick as the `:number` window field, labeled
  `"Tick"`, and every other field `:number`, under whatever `describe:` adds field by
  field. It honors `:window`: a window is ticks, served up to the present tick, at most
  `limit:` rows (`10_000`) and `capped` beyond. Its rows are a chunked
  `Macaw.Data.Table` of the signal's origin, a tick its resolution, so a tick's row sits in
  the same chunk on every fetch.

  Ported from visualize's `Visualize.Signals` and `Visualize.Feed.Signals`: the same rows
  for the same tick.

  ## Examples

      iex> alias Macaw.Data.Source.Signal
      iex> {:ok, sine} = Signal.new(:sine, [:t, :value], window: 3, period: 4)
      iex> Signal.rows(sine, 2) |> Enum.map(&{&1.t, round(&1.value)})
      [{0, 50}, {1, 100}, {2, 50}]
      iex> Signal.rows(sine, 0) |> Enum.map(& &1.t)
      [0]

      iex> alias Macaw.Data.Source
      iex> {:ok, signal} = Source.Signal.new(:discrete, [:t, :n], tick: 10, describe: %{n: %{label: "Count"}})
      iex> {:ok, %{supports: [:window]} = description} = Source.describe(signal, nil)
      iex> Macaw.Data.Schema.fetch(description.schema, :n, :label)
      {:ok, "Count"}
      iex> request = Source.Request.new!(window: [4, 99], now: ~U[2026-11-01 00:00:00Z])
      iex> {:ok, delivery} = Source.fetch(signal, description, request)
      iex> {Macaw.Data.Table.column(delivery.rows, "t"), delivery.served.window}
      {[4, 5, 6, 7, 8, 9, 10], [4, 10]}

      iex> Macaw.Data.Source.Signal.new(:saw, [:t], every: 0)
      {:error, [{[:every], {:type, :pos_integer}}, {[:kind], {:enum, [:sine, :square, :random, :discrete]}}]}
  """

  @behaviour Macaw.Data.Source

  import Macaw.Data.Lists, only: [is_proper_list: 1]

  alias Macaw.Data.{Delivery, Fault, Schema, Table}
  alias Macaw.Data.Source.{Description, Request}

  @kinds [:sine, :square, :random, :discrete]

  # Tick 0 of a clocked signal given no `origin:`.
  @epoch ~U[1970-01-01 00:00:00Z]

  @defaults [
    window: 24,
    period: 12,
    min: 0,
    max: 100,
    seed: 0,
    describe: %{},
    tick: 0,
    every: nil,
    origin: @epoch,
    limit: 10_000
  ]

  @enforce_keys [:kind, :fields, :schema]
  defstruct [
    :kind,
    :fields,
    :schema,
    window: 24,
    period: 12,
    min: 0,
    max: 100,
    seed: 0,
    tick: 0,
    every: nil,
    origin: @epoch,
    limit: 10_000
  ]

  @type kind :: :sine | :square | :random | :discrete

  @type t :: %__MODULE__{
          kind: kind(),
          fields: [atom() | String.t(), ...],
          schema: Schema.t(),
          window: pos_integer(),
          period: number(),
          min: number(),
          max: number(),
          seed: integer(),
          tick: non_neg_integer(),
          every: pos_integer() | nil,
          origin: DateTime.t(),
          limit: pos_integer()
        }

  @doc "The four kinds."
  @spec kinds() :: [kind(), ...]
  def kinds, do: @kinds

  @doc """
  A signal of the kind over the fields, the first the tick and the rest values:
  `{:ok, signal}`, or every fault at once by path (spec/00 §5). Options: the wave's
  `window:`, `period:`, `min:`, `max:` and `seed:`, and the source's `describe:` (a map of
  field descriptions merged over the defaults, field by field), `tick:` (the present
  tick, `0`), `every:` (milliseconds a tick, counted from `origin:` to the request's
  `now`; `nil` for the fixed tick) and `limit:` (the most rows one fetch serves).

  The faults: `{[:kind], {:enum, kinds}}`; `{[:fields], {:type, :fields}}` for anything
  but a list of distinct atom or string names, at least one; `{[key], {:type, type}}` for
  an option of the wrong type (`:pos_integer` for `window`, `every` and `limit`,
  `:number` for `period` (positive), `min` and `max`, `:integer` for `seed`,
  `:non_neg_integer` for `tick`, `:datetime` for `origin`, `:map` for `describe`);
  `{[key], :unknown_key}` for an option it does not take; and the schema's own faults
  under `[:describe]` for descriptions it refuses.
  """
  @spec new(term(), term(), keyword()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def new(kind, fields, opts \\ []) do
    case Macaw.Data.Options.known(opts, @defaults) do
      {:ok, opts} ->
        faults = kind_faults(kind) ++ fields_faults(fields) ++ option_faults(opts)

        with [] <- faults,
             {:ok, schema} <- schema(fields, opts[:describe]) do
          opts = Keyword.delete(opts, :describe)
          {:ok, struct!(__MODULE__, [kind: kind, fields: fields, schema: schema] ++ opts)}
        else
          {:error, faults} -> {:error, faults}
          faults -> {:error, Enum.sort_by(faults, &elem(&1, 0))}
        end

      {:error, faults} ->
        {:error, faults}
    end
  end

  @doc "As `new/3`, the signal alone, raising `Macaw.Data.Error` naming the faults."
  @spec new!(term(), term(), keyword()) :: t()
  def new!(kind, fields, opts \\ []) do
    case new(kind, fields, opts) do
      {:ok, signal} ->
        signal

      {:error, faults} ->
        raise Macaw.Data.Error, reason: faults, what: "not a signal", words: &words/1
    end
  end

  defp kind_faults(kind) when kind in @kinds, do: []
  defp kind_faults(_kind), do: [{[:kind], {:enum, @kinds}}]

  defp fields_faults([_ | _] = fields) when is_proper_list(fields) do
    if Enum.all?(fields, &(is_atom(&1) or is_binary(&1))) and
         Enum.uniq_by(fields, &to_string/1) == fields,
       do: [],
       else: [{[:fields], {:type, :fields}}]
  end

  defp fields_faults(_fields), do: [{[:fields], {:type, :fields}}]

  defp option_faults(opts) do
    for {key, ok?, type} <- [
          {:window, pos_integer?(opts[:window]), :pos_integer},
          {:period, is_number(opts[:period]) and opts[:period] > 0, :number},
          {:min, is_number(opts[:min]), :number},
          {:max, is_number(opts[:max]), :number},
          {:seed, is_integer(opts[:seed]), :integer},
          {:describe, is_map(opts[:describe]) and not is_struct(opts[:describe]), :map},
          {:tick, is_integer(opts[:tick]) and opts[:tick] >= 0, :non_neg_integer},
          {:every, opts[:every] == nil or pos_integer?(opts[:every]), :pos_integer},
          {:origin, match?(%DateTime{}, opts[:origin]), :datetime},
          {:limit, pos_integer?(opts[:limit]), :pos_integer}
        ],
        not ok?,
        do: {[key], {:type, type}}
  end

  defp pos_integer?(n), do: is_integer(n) and n > 0

  # The schema: the tick the `:number` window field, labeled, every value `:number`, the
  # caller's descriptions merged over them field by field.
  defp schema([time | values], describe) do
    defaults =
      values
      |> Map.new(&{&1, %{type: :number}})
      |> Map.put(time, %{type: :number, window: true, label: "Tick"})

    merged =
      Enum.reduce(describe, defaults, fn {field, extra}, acc ->
        case {Enum.find(Map.keys(acc), &same?(&1, field)), extra} do
          {nil, _extra} -> Map.put(acc, field, extra)
          {name, %{} = extra} -> Map.update!(acc, name, &Map.merge(&1, extra))
          {name, extra} -> Map.put(acc, name, extra)
        end
      end)

    case Schema.new(merged) do
      {:ok, schema} ->
        {:ok, schema}

      {:error, faults} ->
        {:error, for({path, reason} <- faults, do: {[:describe | path], reason})}
    end
  end

  defp same?(a, b) when (is_atom(a) or is_binary(a)) and (is_atom(b) or is_binary(b)),
    do: to_string(a) == to_string(b)

  defp same?(_a, _b), do: false

  @doc "A signal moved to a fixed tick."
  @spec at(t(), non_neg_integer()) :: t()
  def at(%__MODULE__{} = signal, tick) when is_integer(tick) and tick >= 0,
    do: %{signal | tick: tick}

  @doc """
  The window of rows ending at the tick: one row a tick from `tick − window + 1` to
  `tick`, none below zero, the tick field the tick and each value field its kind's value
  there. Rows are maps keyed by the fields as given.
  """
  @spec rows(t(), non_neg_integer()) :: [map()]
  def rows(%__MODULE__{window: window} = signal, tick) when is_integer(tick) and tick >= 0,
    do: rows(signal, tick - window + 1, tick)

  @doc """
  One row a tick from `max(from, 0)` to `to`, whatever the signal's `window`; none when
  `to` is below that.

      iex> {:ok, counter} = Macaw.Data.Source.Signal.new(:discrete, [:t, :n], window: 2)
      iex> Macaw.Data.Source.Signal.rows(counter, -1, 2) |> Enum.map(& &1.t)
      [0, 1, 2]
  """
  @spec rows(t(), integer(), integer()) :: [map()]
  def rows(%__MODULE__{fields: [time | values]} = signal, from, to)
      when is_integer(from) and is_integer(to) do
    count = length(values)
    indexed = Enum.with_index(values)

    for t <- max(from, 0)..to//1 do
      Enum.reduce(indexed, %{time => t}, fn {field, n}, row ->
        Map.put(row, field, value(signal, t, n, count))
      end)
    end
  end

  # -- the kinds ------------------------------------------------------------------------------

  defp value(%{kind: :sine, min: min, max: max, period: period}, t, n, count) do
    phase = n / count
    min + (max - min) * (1 + :math.sin(2 * :math.pi() * (t / period + phase))) / 2
  end

  defp value(%{kind: :square, min: min, max: max, period: period}, t, n, count) do
    within = :math.fmod(t / period + n / count, 1.0)
    if within < 0.5, do: max, else: min
  end

  defp value(%{kind: :random, min: min, max: max, seed: seed}, t, n, _count) do
    # One stream per column and tick, so a tick always draws the same value.
    state = :rand.seed_s(:exsss, {seed, n, t})
    {u, _} = :rand.uniform_real_s(state)
    min + (max - min) * u
  end

  defp value(%{kind: :discrete, min: min, max: max}, t, n, _count) do
    span = trunc(max) - trunc(min) + 1
    trunc(min) + rem(t + n, max(span, 1))
  end

  # -- the source -----------------------------------------------------------------------------

  @impl Macaw.Data.Source
  def describe(%__MODULE__{schema: schema}, _context),
    do: {:ok, %Description{schema: schema, supports: [:window]}}

  # Only the tick's range is served; a region and `latest` are finishing's (spec/01 §2.4).
  @impl Macaw.Data.Source
  def fetch(%__MODULE__{} = signal, %Request{window: window} = request) do
    now = present(signal, request.now)

    case span(window, now, signal) do
      {:ok, from, to} ->
        first = max(from, to - signal.limit + 1)

        with {:ok, table} <- table(signal, rows(signal, first, to)) do
          Delivery.new(table,
            served: [window: [max(first, 0), to], resolution: 1, capped: first > max(from, 0)],
            schema: Schema.version(signal.schema)
          )
        end

      :error ->
        {:error, {:window, window}}
    end
  end

  # The rows as a table of the signal's origin: a column per field of the schema, of its
  # type, laid on the chunks a tick's span gives.
  defp table(%__MODULE__{schema: schema} = signal, rows) do
    columns =
      for {name, %{type: type}} <- Enum.sort(schema.fields),
          do: {name, type, Enum.map(rows, &Table.get(&1, name))}

    span = Description.chunk_span(%Description{schema: schema}, 1)

    origin = %{
      source: identity(signal),
      resolution: 1,
      window: Schema.window_field(schema),
      span: span
    }

    Table.new(columns, origin: origin)
  end

  # What names the signal's chunks: its wave, never its clock, so a tick's chunk is the same
  # whatever the present.
  defp identity(%__MODULE__{} = s) do
    %{
      kind: s.kind,
      fields: Enum.map(s.fields, &to_string/1),
      window: s.window,
      period: s.period,
      min: s.min,
      max: s.max,
      seed: s.seed
    }
  end

  # The present tick: the fixed one, or the whole ticks from the origin to the request's
  # `now`.
  defp present(%__MODULE__{every: nil, tick: tick}, _now), do: tick

  defp present(%__MODULE__{every: every, origin: origin}, now),
    do: max(div(DateTime.diff(now, origin, :millisecond), every), 0)

  # The ticks a window asks for, bounded by the present: `nil` is the signal's own window.
  defp span(nil, now, signal), do: {:ok, now - signal.window + 1, now}

  defp span([from, to], now, _signal)
       when (is_number(from) or is_nil(from)) and (is_number(to) or is_nil(to)) do
    from = if from == nil, do: 0, else: ceil(from)
    to = if to == nil, do: now, else: min(floor(to), now)
    {:ok, from, to}
  end

  defp span(_window, _now, _signal), do: :error

  @doc "A reason's words (spec/00 §5): this module's, else the library's."
  @spec format_error(term()) :: String.t()
  def format_error(reason), do: words(reason) || Fault.sentence(reason, words: &words/1)

  @doc false
  # This module's words for a reason, `nil` for one the library's vocabulary words.
  @spec words(term()) :: String.t() | nil
  def words({:type, :fields}),
    do: "must be a list of distinct field names, atoms or strings, the tick first"

  def words({:type, :pos_integer}), do: "must be a positive integer"
  def words({:type, :non_neg_integer}), do: "must be a non-negative integer"
  def words({:type, :datetime}), do: "must be a DateTime"
  def words({:type, :map}), do: "must be a map of field descriptions"
  def words({:window, _window}), do: "the window is not ticks: two numbers or nil"
  def words(_reason), do: nil
end
