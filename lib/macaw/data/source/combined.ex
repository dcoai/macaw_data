defmodule Macaw.Data.Source.Combined do
  @moduledoc """
  One source over several, routed by window (spec/01 §10.2): live data and its history as
  one source, say an in-process telemetry source holding the last hour in front of a store
  holding everything.

  The parts are `Macaw.Data.Source`s, listed freshest first, each a source (described with
  no context) or `{source, context}` (described with its own: `fetch/2` takes no context,
  so each part's is held here). A fetch asks the first part for the window; what it served
  starts at its delivery's served window (else its earliest row), and the part of the
  window before that goes to the next part, and so on. Each later part's rows are trimmed
  to the half-open window it was asked for, `[from, served)`, so a row at a seam comes from
  the fresher part alone, and keeps only rows at least the first part's resolution before
  `served`, so no two rows lie closer than the resolution the union states, whatever grid
  each part's rows lie on (macaw_data#282); a part serving from after the window's end
  hands on that end, whole. The schema must have a `:time` or `:number` window field to
  route by.

  **The combination's schema is the first part's, whole**: its version, labels and facts.
  Every later part's schema must be compatible with it (`Macaw.Data.Schema.compatibility/2`)
  and window over the same field. Its versions may differ, as a process's live source and a
  store's history always do. A later part's rows are read in the first schema's words
  before routing: keyed by the first part's spellings, numbers converted into its units,
  and fields only the later schema describes dropped. The first part's rows are never
  touched.

  **It is described by its parts** (spec/01 §2.1, §10.2): the first part's parameters,
  `lateness`, `idle_after` and `chunk_span`, and viewer independent only when every part
  is. Every later part is asked the first's parameters, so it must declare each, taking
  every value the first's takes; otherwise describe and fetch answer `{:error,
  {:combined_params, faults}}`, each `{position, name, :missing | {:narrower, first,
  later}}`.

  A combination honors `:window`, pushes when its first part does (its subscription is the
  first's, its pushes pass through unchanged), and honors `:as_of` when every part does.
  Its request goes to every part with only the window routed, and its `subscription` to
  the first alone. What finishing does over the union no part is asked: a region,
  `latest`, an order, a budget and its reducer (macaw_data#273), since a part's own cut
  is no cut of the union. `as_of`, `params`, `viewer` and `now` reach every part as they
  are.

  **Its delivery states what the parts said of their answers** (spec/01 §10.2): `stale`
  when any part asked answered stale; the parts' `note`s, each once, the freshest first,
  joined by `"; "`; the first part's `params`, `position` and `resolution`; `capped` when
  the oldest part asked stops short of the window or says it cut; and `complete_until` the
  least claim of the parts asked, none when any claims none, but the first part's for a
  snapshot taken for a subscription. `reduced_by`, `reduced_with`, `ordered` and `origin`
  are none: no part is asked a budget, a reducer or an order, finishing states them of the
  union, and a part's origin names that part.

  **No later part's rows are finer than the first part's resolution**, the union's: where
  it has a spacing (a number, or a name such as `:minute` over a `:time` field), a later
  part keeping rows at a finer resolution, read in the first's units, or at none, is
  `{:error, {:combined_resolution, position, theirs, first}}`. A coarser history combines.

  **Parts that deliver tables are concatenated at the seam as tables**: each kept run of a
  part's table is a slice of it, and the combination's rows are one `Macaw.Data.Table` of
  their chunks, copied nowhere, when every part kept a table of the same columns. A part
  whose rows are rows, or are read in the first schema's words, makes the combination's
  rows rows.

  Ported from visualize's `Visualize.Feed.Combine`.

  ## Examples

      iex> alias Macaw.Data.Source
      iex> alias Macaw.Data.Source.{Combined, Signal}
      iex> live = Signal.new!(:discrete, [:t, :n], tick: 9, limit: 3)
      iex> history = Signal.new!(:discrete, [:t, :n], tick: 9)
      iex> {:ok, combined} = Combined.new([live, history])
      iex> {:ok, description} = Source.describe(combined, nil)
      iex> request = Source.Request.new!(window: [2, 9], now: ~U[2026-11-01 00:00:00Z])
      iex> {:ok, delivery} = Source.fetch(combined, description, request)
      iex> {Macaw.Data.Table.column(delivery.rows, "t"), delivery.served.window, delivery.served.capped}
      {[2, 3, 4, 5, 6, 7, 8, 9], [2, 9], false}

      iex> Macaw.Data.Source.Combined.new([])
      {:error, [{[], {:type, :parts}}]}
  """

  @behaviour Macaw.Data.Source

  import Macaw.Data.Lists, only: [is_proper_list: 1]

  alias Macaw.Data.{Delivery, Fault, Schema, Source, Table, Unit, Window}
  alias Macaw.Data.Source.{Description, Request}
  alias Macaw.Data.Table.Subset

  @enforce_keys [:parts]
  defstruct [:parts]

  @typedoc "A part: a source, described with no context, or a source and its context."
  @type part :: Source.t() | {Source.t(), term()}

  @type t :: %__MODULE__{parts: [{Source.t(), term()}, ...]}

  @doc """
  One source over several, freshest first, each a source or `{source, context}`:
  `{:ok, combined}`, or every fault (spec/00 §5): `{[], {:type, :parts}}` for anything but
  a non-empty list, `{[i], {:type, :part}}` for an element that is no struct nor
  `{struct, context}`, and `{[key], :unknown_key}` for an option it does not take (it takes
  none yet). Whether each part is a source is its describe's to say.
  """
  @spec new(term(), keyword()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def new(parts, opts \\ [])

  def new([_ | _] = parts, opts) when is_proper_list(parts) do
    with {:ok, _opts} <- Macaw.Data.Options.known(opts, []) do
      case for({part, i} <- Enum.with_index(parts), part(part) == nil, do: {[i], {:type, :part}}) do
        [] -> {:ok, %__MODULE__{parts: Enum.map(parts, &part/1)}}
        faults -> {:error, faults}
      end
    end
  end

  def new(_parts, _opts), do: {:error, [{[], {:type, :parts}}]}

  @doc "As `new/2`, the combination alone, raising `Macaw.Data.Error` naming the faults."
  @spec new!(term(), keyword()) :: t()
  def new!(parts, opts \\ []) do
    case new(parts, opts) do
      {:ok, combined} ->
        combined

      {:error, faults} ->
        raise Macaw.Data.Error, reason: faults, what: "not a combination", words: &words/1
    end
  end

  defp part({%_{} = source, context}), do: {source, context}
  defp part(%_{} = source), do: {source, nil}
  defp part(_other), do: nil

  # The combination's description (`description/2`): `{:error, {:combined_schema,
  # incompatibilities}}` listing every field of every later part whose schema is not
  # compatible with the first's, each `{position, field, reason}`, and `{position,
  # window_field, {:window, first, later}}` for a later part windowing over another field
  # (`nil` for none); `{:error, :combined_window_field}` when the schema has no `:time` or
  # `:number` window field; `{:error, {:combined_params, faults}}` for a later part that
  # does not take the first's parameters (`takes_params/1`); and the first error of a part
  # that cannot describe. Its own context is not read: each part is described with its own.
  @impl Macaw.Data.Source
  def describe(%__MODULE__{parts: parts}, _context) do
    with {:ok, description, _described, _readings} <- resolve(parts), do: {:ok, description}
  end

  # The combination's description and, per part, its own and how its rows read as the
  # first's.
  defp resolve(parts) do
    with {:ok, [%Description{schema: schema} = first | _] = described} <-
           describe_all(parts, []),
         :ok <- compatible(described),
         :ok <- has_window(schema),
         :ok <- takes_params(described) do
      time = Schema.window_field(schema)
      readings = Enum.map(described, &reading(&1, schema.version, schema, time))
      {:ok, description(first, described), described, readings}
    end
  end

  # What the combination is (spec/01 §2.1, §10.2), each fact by one rule: the first part's
  # schema, parameters, `lateness`, `idle_after` and `chunk_span`, since its subscription,
  # its increments and its units are the first part's and every part is asked its
  # parameters; viewer independent only when every part is, as one part answering by
  # viewer makes the union do so; `:window`, `:push` when the first part pushes, and
  # `:as_of` when every part answers as of the instant asked.
  defp description(%Description{} = first, described) do
    as_of = if Enum.all?(described, &(:as_of in &1.supports)), do: [:as_of], else: []

    %Description{
      schema: first.schema,
      params: first.params,
      supports: [:window | Enum.filter(first.supports, &(&1 == :push))] ++ as_of,
      viewer_independent: Enum.all?(described, &(&1.viewer_independent == true)),
      lateness: first.lateness,
      idle_after: first.idle_after,
      chunk_span: first.chunk_span
    }
  end

  # Every part is asked the request's parameters as they are, the first part's defaults
  # filled in (`Source.fetch/3`), so every later part must take each of the first's: declare
  # it (`:missing`), accepting every value the first's accepts (`{:narrower, first,
  # later}`). A later part's own other parameters are asked at their defaults.
  defp takes_params([%Description{params: params} | later]) do
    faults =
      for {%Description{params: theirs}, position} <- Enum.with_index(later, 1),
          {name, ours} <- Enum.sort(params),
          reason = param_fault(ours, Map.get(theirs, name)),
          reason != nil,
          do: {position, name, reason}

    if faults == [], do: :ok, else: {:error, {:combined_params, faults}}
  end

  defp param_fault(_ours, nil), do: :missing

  defp param_fault(ours, theirs),
    do: if(accepts?(ours, theirs), do: nil, else: {:narrower, ours, theirs})

  # Whether `theirs` takes every value `ours` does (spec/01 §2.2): of its type, or any
  # value as a `:term`; within its closed values, if it has any; and `nil` where ours
  # takes `nil`, a default of `nil` (or a `:term`, which takes anything).
  defp accepts?(ours, theirs) do
    type? = theirs.type == :term or theirs.type == ours.type
    values = Map.get(theirs, :values)

    values? =
      values == nil or
        (Map.get(ours, :values) != nil and
           Enum.all?(Map.get(ours, :values), &(&1 in values)))

    nil? = not takes_nil?(ours) or takes_nil?(theirs)
    type? and values? and nil?
  end

  defp takes_nil?(parameter),
    do:
      Map.get(parameter, :type) == :term or
        (Map.has_key?(parameter, :default) and parameter.default == nil)

  defp describe_all([], acc), do: {:ok, Enum.reverse(acc)}

  defp describe_all([{source, context} | rest], acc) do
    case Source.describe(source, context) do
      {:error, reason} -> {:error, reason}
      {:ok, description} -> describe_all(rest, [description | acc])
    end
  end

  defp compatible([%Description{schema: first} | later]) do
    time = Schema.window_field(first)

    faults =
      later
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {%Description{schema: schema}, position} ->
        fields =
          case Schema.compatibility(first, schema) do
            :ok -> []
            {:error, faults} -> faults
          end

        (fields ++ same_window(time, Schema.window_field(schema)))
        |> Enum.sort_by(fn {field, _reason} -> to_string(field) end)
        |> Enum.map(fn {field, reason} -> {position, field, reason} end)
      end)

    if faults == [], do: :ok, else: {:error, {:combined_schema, faults}}
  end

  # Routing asks a later part for a window over its own window field, so it must be the
  # first's, compared as a string. A first schema with none is `has_window/1`'s to refuse.
  defp same_window(nil, _theirs), do: []

  defp same_window(ours, theirs) do
    if theirs != nil and to_string(theirs) == to_string(ours),
      do: [],
      else: [{ours, {:window, ours, theirs}}]
  end

  defp has_window(schema) do
    with field when field != nil <- Schema.window_field(schema),
         {:ok, type} when type in [:time, :number] <- Schema.fetch(schema, field, :type) do
      :ok
    else
      _none -> {:error, :combined_window_field}
    end
  end

  # How a part's rows read as the first schema's: `:same` for a part of the first's
  # version; otherwise its columns by name as a string, each to the first's spelling and
  # the unit conversion its numbers need, the names only it describes, and the window
  # field's conversion, both ways.
  defp reading(%Description{schema: %Schema{version: version}}, version, _first, _time),
    do: :same

  defp reading(%Description{schema: %Schema{fields: theirs} = schema}, _, first, time) do
    columns =
      Map.new(first.fields, fn {name, description} ->
        {to_string(name), {name, conversion(description, Schema.fetch(schema, name))}}
      end)

    only_theirs =
      for {name, _} <- theirs,
          not Map.has_key?(columns, to_string(name)),
          into: MapSet.new(),
          do: to_string(name)

    window =
      case Map.fetch!(columns, to_string(time)) do
        {_name, {from, to}} -> {{to, from}, {from, to}}
        {_name, nil} -> nil
      end

    %{columns: columns, only_theirs: only_theirs, window: window}
  end

  # `{from, to}` when a number field's units differ; compatibility made sure they convert.
  defp conversion(%{type: :number, unit: to}, {:ok, %{unit: from}}) when from != to,
    do: {from, to}

  defp conversion(_ours, _theirs), do: nil

  @impl Macaw.Data.Source
  def fetch(%__MODULE__{parts: parts}, %Request{} = request) do
    with {:ok, %Description{schema: schema}, described, readings} <- resolve(parts) do
      time = Schema.window_field(schema)
      # Only the window is routed. What finishing does over the union no part is asked: a
      # region, `latest`, an order, a budget and its reducer. A part's own cut is no cut of
      # the union (macaw_data#273): it would reduce its slice alone, to the whole budget,
      # and the combination could not say so. `as_of`, `params`, `viewer` and `now` say
      # which relation is read, and reach every part as they are.
      [from, to] = request.window || [nil, nil]
      asked = %{request | region: nil, latest: false, order: [], budget: nil, reduce: nil}

      {:ok, type} = Schema.fetch(schema, time, :type)

      route(
        Enum.zip([parts, described, readings]),
        {time, type},
        from,
        {to, true},
        asked,
        [],
        {nil, nil},
        schema
      )
    end
  end

  # Each part is asked for `[from, upper]`, `upper` what the fresher parts served from (the
  # window's `to` for the first), exclusive once a fresher part served from it: `{bound,
  # inclusive?}`. `kept` is built oldest first, since the route goes back in time. `first`
  # is what the first part's answer says of every later one: how its rows are spelled
  # (`nil` until it is fetched) and the spacing its resolution states, which no row may
  # break at a seam (`seam/6`).
  defp route([], _time, from, _upper, _request, kept, _first, schema),
    do: combined(kept, from, schema)

  defp route([part | rest], time, from, {bound, _} = upper, request, kept, first, schema) do
    {{source, _context}, description, reading} = part
    {field, type} = time
    {spelling, step} = first

    with {:ok, window} <- asked(reading, [from, bound], length(kept)),
         {:ok, delivery} <- Source.fetch(source, description, %{request | window: window}),
         {:ok, delivery} <- read(delivery, reading, spelling, length(kept)),
         {:ok, rows, reached} <- seam(delivery, field, from, upper, step, length(kept)) do
      served = served_from(delivery, reached)
      kept = [%{kept: rows, delivery: delivery, from: served, position: length(kept)} | kept]

      first =
        if spelling == nil,
          do: {spelling(delivery), spacing(delivery.served.resolution, type)},
          else: first

      # The subscription is the first part's alone: a later part's fetch is no snapshot
      # for it.
      request = %{request | subscription: nil}

      if covered?(served, from),
        do: combined(kept, from, schema),
        else: route(rest, time, from, below(served, upper), request, kept, first, schema)
    end
  end

  # The next part's upper bound: where the fresher parts served from, exclusive, so a row
  # at the seam is the fresher part's; the bound as it was where they served nothing or
  # served from past it, as a part serving from after the window's end does.
  defp below(nil, upper), do: upper
  defp below(served, {nil, _inclusive?}), do: {served, false}

  defp below(served, {bound, _inclusive?} = upper) do
    if Window.comparable?(served, bound) and Window.compare(served, bound) == :gt,
      do: upper,
      else: {served, false}
  end

  # How the first part's rows key each column, by the column's string: a column its first
  # row lacks, or a first part that served none, takes the schema's string.
  defp spelling(%Delivery{rows: %Table{} = table}),
    do: Map.new(Table.names(table), &{spelled(&1), &1})

  defp spelling(%Delivery{} = delivery) do
    case Delivery.named_rows(delivery) do
      {:ok, [row | _]} when is_map(row) -> Map.new(Map.keys(row), &{spelled(&1), &1})
      _rows -> %{}
    end
  end

  # The window asked of a part in its own units, and its delivery in the first's words.
  defp asked(%{window: {to_theirs, _to_ours}}, window, i), do: bounds(window, to_theirs, i)
  defp asked(_reading, window, _i), do: {:ok, window}

  defp read(delivery, :same, _spelling, _i), do: {:ok, delivery}

  defp read(%Delivery{} = delivery, reading, spelling, i) do
    with {:ok, rows} <- part_rows(delivery, i),
         {:ok, rows} <- convert_rows(rows, reading, spelling || %{}, i),
         {:ok, window} <- served_window(delivery.served.window, reading.window, i),
         {:ok, claim} <- served_claim(delivery.served.complete_until, reading.window, i),
         {:ok, resolution} <- served_resolution(delivery.served.resolution, reading.window, i) do
      served = %{delivery.served | window: window, complete_until: claim, resolution: resolution}
      {:ok, %{delivery | rows: rows, names: nil, served: served}}
    end
  end

  # A later part's claim (spec/01 §4.4), a value of its window field, in the first's units.
  defp served_claim(nil, _window, _i), do: {:ok, nil}

  defp served_claim(claim, {_to_theirs, to_ours}, i) do
    case value(claim, to_ours) do
      {:ok, claim} -> {:ok, claim}
      {:error, reason} -> {:error, {:combined_part, i, [{[:served, :complete_until], reason}]}}
    end
  end

  defp served_claim(claim, nil, _i), do: {:ok, claim}

  # A later part's resolution (spec/01 §3), a spacing in its window field's units when a
  # number, in the first's; a name (`:minute`) is the same in either.
  defp served_resolution(r, {_to_theirs, to_ours}, i) when is_number(r) do
    case value(r, to_ours) do
      {:ok, r} -> {:ok, r}
      {:error, reason} -> {:error, {:combined_part, i, [{[:served, :resolution], reason}]}}
    end
  end

  defp served_resolution(r, _window, _i), do: {:ok, r}

  defp served_window(window, {_to_theirs, to_ours}, i), do: bounds(window, to_ours, i)
  defp served_window(window, nil, _i), do: {:ok, window}

  defp part_rows(delivery, i) do
    case Delivery.named_rows(delivery) do
      {:ok, rows} -> {:ok, rows}
      {:error, faults} -> {:error, {:combined_part, i, faults}}
    end
  end

  defp convert_rows(rows, reading, spelling, i) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, n}, {:ok, acc} ->
      case row(row, reading, spelling) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, field, reason} -> {:halt, {:error, {:combined_part, i, [{[n, field], reason}]}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp bounds(nil, _units, _i), do: {:ok, nil}

  defp bounds([from, to], units, i) do
    with {:ok, from} <- bound(from, units, i),
         {:ok, to} <- bound(to, units, i),
         do: {:ok, [from, to]}
  end

  defp bound(v, units, i) do
    case value(v, units) do
      {:ok, v} -> {:ok, v}
      {:error, reason} -> {:error, {:combined_part, i, [{[:window], reason}]}}
    end
  end

  defp row(row, %{columns: columns, only_theirs: only_theirs}, spelling) when is_map(row) do
    Enum.reduce_while(row, {:ok, %{}}, fn {key, v}, {:ok, acc} ->
      spelled = spelled(key)

      case Map.fetch(columns, spelled) do
        {:ok, {name, units}} ->
          case value(v, units) do
            {:ok, v} -> {:cont, {:ok, Map.put(acc, Map.get(spelling, spelled, name), v)}}
            {:error, reason} -> {:halt, {:error, key, reason}}
          end

        :error ->
          if MapSet.member?(only_theirs, spelled),
            do: {:cont, {:ok, acc}},
            else: {:cont, {:ok, Map.put(acc, key, v)}}
      end
    end)
  end

  defp spelled(key) when is_atom(key), do: Atom.to_string(key)
  defp spelled(key), do: key

  defp value(v, {from, to}) when is_number(v), do: Unit.convert(v, from, to)
  defp value(v, _units), do: {:ok, v}

  # The freshest part keeps its own end; every later part is strictly before what the
  # fresher ones served, and at least the first part's spacing `step` before it (macaw_data
  # #282), so no row lies closer to a fresher part's than the union's resolution says. A
  # part whose rows are a table keeps them as one: one run sliced, nothing copied; else the
  # kept rows gathered from it. Answers the rows kept and, for a part stating no served
  # window, the earliest time it reached (`reached/4`).
  defp seam(%Delivery{rows: %Table{} = table} = delivery, time, from, upper, step, _i) do
    keep? = keeper(from, upper, step)
    name = Enum.find(Table.names(table), &(spelled(&1) == spelled(time)))
    values = if name, do: Table.column(table, name), else: []
    kept = for {v, i} <- Enum.with_index(values), keep?.(v), do: i
    reached = reached(delivery, values, keep?, {from, upper})

    case kept do
      [] ->
        {:ok, {:table, Table.slice(table, 0, 0)}, reached}

      [first | _] ->
        last = List.last(kept)

        if last - first + 1 == length(kept),
          do: {:ok, {:table, Table.slice(table, first, length(kept))}, reached},
          else: {:ok, {:table, Subset.at(Subset.ready(table), kept)}, reached}
    end
  end

  defp seam(%Delivery{} = delivery, time, from, upper, step, i) do
    keep? = keeper(from, upper, step)

    with {:ok, rows} <- part_rows(delivery, i) do
      kept = Enum.filter(rows, &keep?.(Table.get(&1, time)))
      reached = reached(delivery, Enum.map(rows, &Table.get(&1, time)), keep?, {from, upper})
      {:ok, {:rows, kept}, reached}
    end
  end

  # Where a part stating no served window served from, out of its rows' `times`: its
  # earliest the window kept, spaced or not, since a row dropped for the spacing was still
  # served, so dropping it changes no coverage. Kept rows lie at least `step` before the
  # bound and dropped ones within it, so the earliest kept is the earliest the window kept
  # whenever one was kept. A part stating its window has said where it served from
  # (`served_from/2`), and its times are not read.
  defp reached(%Delivery{served: %{window: [served, _to]}}, _times, _keep?, _bounds)
       when served != nil,
       do: nil

  defp reached(_delivery, times, keep?, {from, upper}) do
    case earliest(Enum.filter(times, keep?)) do
      nil -> earliest(Enum.filter(times, keeper(from, upper, nil)))
      reached -> reached
    end
  end

  defp earliest(times), do: Enum.reduce(times, nil, &Window.earliest(&2, &1))

  # Whether a time is kept: within `[from, upper]` while the bound is inclusive (the
  # freshest part, and a part no fresher one served before), else in `[from, upper)` and,
  # where the first part states a spacing `step`, at least `step` before `upper`, measured
  # as the conformance kit measures it (a number's difference, else seconds between
  # positions) and with its tolerance.
  defp keeper(from, {upper, true}, _step), do: &Window.within?(&1, [from, upper])

  defp keeper(from, {upper, false}, step) when upper == nil or step == nil do
    fn time ->
      Window.within?(time, [from, nil]) and
        (upper == nil or (Window.comparable?(time, upper) and Window.compare(time, upper) == :lt))
    end
  end

  defp keeper(from, {upper, false}, step) when is_number(upper) do
    least = step * (1 - 1.0e-9)
    fn time -> is_number(time) and upper - time >= least and Window.within?(time, [from, nil]) end
  end

  defp keeper(from, {upper, false}, step) do
    least = step * 1_000_000 * (1 - 1.0e-9)
    at = Window.position(upper)

    fn time ->
      Window.instant?(time) and at - Window.position(time) >= least and
        Window.within?(time, [from, nil])
    end
  end

  defp served_from(%Delivery{served: %{window: [served, _to]}}, _reached)
       when served != nil,
       do: served

  defp served_from(_delivery, reached), do: reached

  defp covered?(nil, _from), do: false
  defp covered?(_served, nil), do: false

  defp covered?(served, from),
    do: Window.comparable?(served, from) and Window.compare(served, from) != :gt

  defp combined(kept, from, schema) do
    with :ok <- spaced(kept, schema), do: union(kept, from, schema)
  end

  # The union's resolution is the first part's, its subscription's (spec/01 §4.3), so no
  # later part's rows may lie closer together than it says (§3, the kit's `:deliveries`):
  # where the first's resolution has a spacing, each later part that kept rows states one
  # at least as wide, read in the first's units, else `{:error, {:combined_resolution,
  # position, theirs, first}}`. A part that kept no rows says nothing of the union's
  # spacing, and a first part stating none claims none.
  defp spaced(kept, schema) do
    %{delivery: %{served: %{resolution: first}}} = List.last(kept)
    {:ok, type} = Schema.fetch(schema, Schema.window_field(schema), :type)

    case spacing(first, type) do
      nil ->
        :ok

      step ->
        kept
        |> Enum.reverse()
        |> Enum.drop(1)
        |> Enum.find_value(:ok, fn %{kept: rows, position: position, delivery: delivery} ->
          theirs = delivery.served.resolution
          spacing = spacing(theirs, type)

          if not empty?(rows) and (spacing == nil or spacing < step * (1 - 1.0e-9)),
            do: {:error, {:combined_resolution, position, theirs, first}}
        end)
    end
  end

  @spans %{second: 1, minute: 60, hour: 3600, day: 86_400, week: 604_800}

  # A resolution's spacing in the window field's units, as the conformance kit reads it:
  # a positive number itself (seconds over a `:time` field), a name over a `:time` field
  # its seconds; `nil` for none, a name over a `:number` field, or anything else.
  defp spacing(r, _type) when is_number(r) and r > 0, do: r
  defp spacing(r, :time) when is_atom(r), do: Map.get(@spans, r)
  defp spacing(_r, _type), do: nil

  defp empty?({:rows, rows}), do: rows == []
  defp empty?({:table, table}), do: Table.size(table) == 0

  defp union([oldest | _] = kept, from, schema) do
    freshest = List.last(kept)

    answers = Enum.map(kept, & &1.delivery.served)

    # The oldest part asked is the one no later part stands behind: what it did not reach
    # is short, and so is what it says it cut. A fresher part's cut was handed on.
    capped = oldest.delivery.served.capped or (from != nil and not covered?(oldest.from, from))

    # Each fact said of the union (spec/01 §10.2): the parts' where it is a fact of their
    # answers, the first part's where it is the subscription's, and none of a part's where
    # no part was asked it (a budget, a reducer, an order: finishing's, over the union).
    # Those facts are the parts' own, so one `Delivery.new/2` refuses is the combination's
    # fault.
    delivery =
      Delivery.new(concatenated(Enum.map(kept, & &1.kept)),
        served: [
          window: [Window.latest(oldest.from, from), window_to(freshest.delivery)],
          resolution: freshest.delivery.served.resolution,
          capped: capped,
          stale: stale(answers),
          params: freshest.delivery.served.params,
          note: note(answers),
          position: freshest.delivery.served.position,
          complete_until: claim(freshest.delivery.served, answers)
        ],
        schema: Schema.version(schema)
      )

    case delivery do
      {:ok, delivery} -> {:ok, delivery}
      {:error, faults} -> {:error, {:combined_delivery, faults}}
    end
  end

  # Stale when any part asked answered stale, rows or none: it may lack rows of the window
  # it was asked. A value that is no boolean is passed on, for `Delivery.new/2` to refuse.
  defp stale(answers) do
    case Enum.find(answers, &(not is_boolean(&1.stale))) do
      nil -> Enum.any?(answers, & &1.stale)
      %{stale: wrong} -> wrong
    end
  end

  # The parts' lines for a person, each once, the freshest first; a value that is no
  # string is passed on, for `Delivery.new/2` to refuse.
  defp note(answers) do
    notes = answers |> Enum.reverse() |> Enum.map(& &1.note) |> Enum.reject(&is_nil/1)

    case Enum.find(notes, &(not is_binary(&1))) do
      nil -> if notes == [], do: nil, else: notes |> Enum.uniq() |> Enum.join("; ")
      wrong -> wrong
    end
  end

  # A snapshot for a subscription, its position stated, claims the first part's: a
  # subscription's claim never moves back (spec/01 §4.4), and its increments are the first
  # part's. Any other answer claims what every part asked claims, the least, and none when
  # any part claims none: below it no part expects a change.
  defp claim(%{position: position, complete_until: first}, _answers) when position != nil,
    do: first

  defp claim(_first, answers) do
    claims = Enum.map(answers, & &1.complete_until)
    if Enum.member?(claims, nil), do: nil, else: Enum.reduce(claims, &Window.earliest(&2, &1))
  end

  # The parts at the seam, oldest first: tables of one header are one table of their
  # chunks, concatenated and copied nowhere; any part of rows makes the whole rows.
  defp concatenated(kept) do
    case Enum.uniq(Enum.map(kept, &header/1)) do
      [{:table, header}] ->
        chunks = Enum.flat_map(kept, fn {:table, table} -> Table.chunks(table) end)
        {:ok, table} = Table.from_chunks(header, chunks)
        table

      _mixed ->
        Enum.flat_map(kept, &rows_of/1)
    end
  end

  defp header({:table, table}),
    do: {:table, Enum.map(Table.names(table), &{&1, Table.column_type(table, &1)})}

  defp header({:rows, _rows}), do: :rows

  defp rows_of({:rows, rows}), do: rows

  defp rows_of({:table, table}) do
    {:ok, rows} = Table.rows(table)
    rows
  end

  defp window_to(%Delivery{served: %{window: [_from, to]}}), do: to
  defp window_to(_delivery), do: nil

  # The first part's subscription is the combination's.
  @impl Macaw.Data.Source
  def subscribe(%__MODULE__{parts: [{first, _context} | _]}, pid),
    do: Source.subscribe(first, pid)

  @impl Macaw.Data.Source
  def unsubscribe(%__MODULE__{parts: [{first, _context} | _]}, ref),
    do: Source.unsubscribe(first, ref)

  @doc "A reason's words (spec/00 §5): this module's, else the library's."
  @spec format_error(term()) :: String.t()
  def format_error(reason), do: words(reason) || Fault.sentence(reason, words: &words/1)

  @doc false
  @spec words(term()) :: String.t() | nil
  def words({:type, :parts}), do: "must be a non-empty list of sources, the freshest first"
  def words({:type, :part}), do: "must be a source, or {source, context}"

  def words(:combined_window_field),
    do: "the first part's schema has no :time or :number window field to route by"

  def words({:combined_schema, faults}) do
    "a later part's schema is not the first's: " <>
      Enum.map_join(faults, "; ", fn {position, field, _reason} ->
        "part #{position}, field #{inspect(field)}"
      end)
  end

  def words({:combined_params, faults}) do
    "a later part does not take the first part's parameters: " <>
      Enum.map_join(faults, "; ", fn
        {position, name, :missing} -> "part #{position} lacks #{inspect(name)}"
        {position, name, {:narrower, _, _}} -> "part #{position} takes less of #{inspect(name)}"
      end)
  end

  def words({:combined_resolution, position, theirs, first}) do
    "part #{position} serves rows at #{inspect(theirs)}, finer than the first part's " <>
      "resolution #{inspect(first)} or not comparable with it"
  end

  def words({:combined_part, i, faults}),
    do: "part #{i}'s delivery cannot be read in the first's words: " <> Fault.sentence(faults)

  def words({:combined_delivery, faults}),
    do: "the parts' served facts make no delivery: " <> Fault.sentence(faults)

  def words(_reason), do: nil
end
