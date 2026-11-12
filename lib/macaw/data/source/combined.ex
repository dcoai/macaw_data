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
  the fresher part alone; a part serving from after the window's end hands on that end,
  whole. The schema must have a `:time` or `:number` window field to
  route by.

  **The combination's schema is the first part's, whole**: its version, labels and facts.
  Every later part's schema must be compatible with it (`Macaw.Data.Schema.compatibility/2`)
  and window over the same field. Its versions may differ, as a process's live source and a
  store's history always do. A later part's rows are read in the first schema's words
  before routing: keyed by the first part's spellings, numbers converted into its units,
  and fields only the later schema describes dropped. The first part's rows are never
  touched.

  A combination honors `:window`, and pushes when its first part does: its subscription is
  the first's, its pushes pass through unchanged. Its request goes to every part with only
  the window routed, a region and `latest` left to finishing over the union, and its
  `subscription` to the first alone. Its delivery carries the first part's `position`,
  `complete_until` and `resolution`.

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

  # The first part's description, its schema whole, with the combination's supports
  # (`:window`, and `:push` when the first part pushes): `{:error, {:combined_schema,
  # incompatibilities}}` listing every field of every later part whose schema is not
  # compatible with the first's, each `{position, field, reason}`, and `{position,
  # window_field, {:window, first, later}}` for a later part windowing over another field
  # (`nil` for none); `{:error, :combined_window_field}` when the schema has no `:time` or
  # `:number` window field; and the first error of a part that cannot describe. Its own
  # context is not read: each part is described with its own.
  @impl Macaw.Data.Source
  def describe(%__MODULE__{parts: parts}, _context) do
    with {:ok, description, _described, _readings} <- resolve(parts), do: {:ok, description}
  end

  # The combination's description and, per part, its own and how its rows read as the
  # first's.
  defp resolve(parts) do
    with {:ok, [%Description{schema: schema, supports: supports} | _] = described} <-
           describe_all(parts, []),
         :ok <- compatible(described),
         :ok <- has_window(schema) do
      time = Schema.window_field(schema)
      readings = Enum.map(described, &reading(&1, schema.version, schema, time))
      supports = [:window | Enum.filter(supports, &(&1 == :push))]
      {:ok, %Description{schema: schema, supports: supports}, described, readings}
    end
  end

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
      # Only the window is routed; a region and `latest` are finished over the union, so a
      # part is asked neither.
      [from, to] = request.window || [nil, nil]
      asked = %{request | region: nil, latest: false}

      route(
        Enum.zip([parts, described, readings]),
        time,
        from,
        {to, true},
        asked,
        [],
        nil,
        schema
      )
    end
  end

  # Each part is asked for `[from, upper]`, `upper` what the fresher parts served from (the
  # window's `to` for the first), exclusive once a fresher part served from it: `{bound,
  # inclusive?}`. `kept` is built oldest first, since the route goes back
  # in time. `spelling` is the first part's, read off its rows (`nil` until it is fetched).
  defp route([], _time, from, _upper, _request, kept, _spelling, schema),
    do: combined(kept, from, schema)

  defp route([part | rest], time, from, {bound, _} = upper, request, kept, spelling, schema) do
    {{source, _context}, description, reading} = part

    with {:ok, window} <- asked(reading, [from, bound], length(kept)),
         {:ok, delivery} <- Source.fetch(source, description, %{request | window: window}),
         {:ok, delivery} <- read(delivery, reading, spelling, length(kept)),
         {:ok, rows} <- seam(delivery, time, from, upper, length(kept)) do
      served = served_from(delivery, rows, time)
      kept = [%{kept: rows, delivery: delivery, from: served} | kept]
      spelling = spelling || spelling(delivery)
      # The subscription is the first part's alone: a later part's fetch is no snapshot
      # for it.
      request = %{request | subscription: nil}

      if covered?(served, from),
        do: combined(kept, from, schema),
        else: route(rest, time, from, below(served, upper), request, kept, spelling, schema)
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
         {:ok, window} <- served_window(delivery.served.window, reading.window, i) do
      {:ok, %{delivery | rows: rows, names: nil, served: %{delivery.served | window: window}}}
    end
  end

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
  # fresher ones served. A part whose rows are a table keeps them as one: one run sliced,
  # nothing copied; else the kept rows gathered from it.
  defp seam(%Delivery{rows: %Table{} = table}, time, from, upper, _i) do
    keep? = keeper(from, upper)
    name = Enum.find(Table.names(table), &(spelled(&1) == spelled(time)))
    values = if name, do: Table.column(table, name), else: []
    kept = for {v, i} <- Enum.with_index(values), keep?.(v), do: i

    case kept do
      [] ->
        {:ok, {:table, Table.slice(table, 0, 0)}}

      [first | _] ->
        last = List.last(kept)

        if last - first + 1 == length(kept),
          do: {:ok, {:table, Table.slice(table, first, length(kept))}},
          else: {:ok, {:table, Subset.at(Subset.ready(table), kept)}}
    end
  end

  defp seam(%Delivery{} = delivery, time, from, upper, i) do
    keep? = keeper(from, upper)

    with {:ok, rows} <- part_rows(delivery, i),
         do: {:ok, {:rows, Enum.filter(rows, &keep?.(Table.get(&1, time)))}}
  end

  # Whether a time is kept: within `[from, upper]` while the bound is inclusive (the
  # freshest part, and a part no fresher one served before), else in `[from, upper)`.
  defp keeper(from, {upper, true}), do: &Window.within?(&1, [from, upper])

  defp keeper(from, {upper, false}) do
    fn time ->
      Window.within?(time, [from, nil]) and
        (upper == nil or (Window.comparable?(time, upper) and Window.compare(time, upper) == :lt))
    end
  end

  defp served_from(%Delivery{served: %{window: [served, _to]}}, _kept, _time)
       when served != nil,
       do: served

  defp served_from(_delivery, kept, time),
    do: Enum.reduce(times(kept, time), nil, &Window.earliest(&2, &1))

  defp times({:rows, rows}, time), do: Enum.map(rows, &Table.get(&1, time))

  defp times({:table, table}, time) do
    case Enum.find(Table.names(table), &(spelled(&1) == spelled(time))) do
      nil -> []
      name -> Table.column(table, name)
    end
  end

  defp covered?(nil, _from), do: false
  defp covered?(_served, nil), do: false

  defp covered?(served, from),
    do: Window.comparable?(served, from) and Window.compare(served, from) != :gt

  defp combined([oldest | _] = kept, from, schema) do
    freshest = List.last(kept)

    capped =
      if from == nil,
        do: oldest.delivery.served.capped,
        else: not covered?(oldest.from, from)

    # The freshest part's subscription is the combination's, so its position and its
    # claim are the combination's. Those facts are the parts' own, so one `Delivery.new/2`
    # refuses is the combination's fault.
    delivery =
      Delivery.new(concatenated(Enum.map(kept, & &1.kept)),
        served: [
          window: [Window.latest(oldest.from, from), window_to(freshest.delivery)],
          resolution: freshest.delivery.served.resolution,
          capped: capped,
          position: freshest.delivery.served.position,
          complete_until: freshest.delivery.served.complete_until
        ],
        schema: Schema.version(schema)
      )

    case delivery do
      {:ok, delivery} -> {:ok, delivery}
      {:error, faults} -> {:error, {:combined_delivery, faults}}
    end
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

  def words({:combined_part, i, faults}),
    do: "part #{i}'s delivery cannot be read in the first's words: " <> Fault.sentence(faults)

  def words({:combined_delivery, faults}),
    do: "the parts' served facts make no delivery: " <> Fault.sentence(faults)

  def words(_reason), do: nil
end
