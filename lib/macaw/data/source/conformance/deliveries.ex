defmodule Macaw.Data.Source.Conformance.Deliveries do
  @moduledoc false
  # The deliveries check's clauses (spec/01 §9): one probe fetched, read and held to the
  # contract of spec/01 §3, and the schema held to `Schema.new/1`. The supports, push and
  # determinism checks fetch through `fetched/5` too. Ported from visualize's
  # `Visualize.Feed.Conformance`.

  alias Macaw.Data.{Delivery, Schema, Source, Table, Window}
  alias Macaw.Data.Source.{Description, Request}
  alias Macaw.Data.Source.Conformance.Call

  @doc false
  # The schema is one `Schema.new/1` accepts, and the version is its content hash. A
  # field's measure that the vocabulary refuses is its own finding, naming the field; the
  # schema's other faults stay together.
  def schema_faults(%Schema{fields: fields, version: version}) do
    case Schema.new(fields) do
      {:ok, %Schema{version: ^version}} ->
        []

      {:ok, %Schema{version: computed}} ->
        [{:version, version, computed}]

      {:error, errors} ->
        {measures, others} = Enum.split_with(errors, &measure?/1)
        invalid = if others == [], do: [], else: [{:schema_invalid, others}]
        invalid ++ for({[field, _key], reason} <- measures, do: {:measure, field, reason})
    end
  end

  defp measure?({[_field, :unit], {:unit, _code, _reason}}), do: true
  defp measure?({[_field, :quantity], {:unknown_quantity, _quantity}}), do: true
  defp measure?({[_field, :quantity], {:quantity, _quantity, _code}}), do: true
  defp measure?(_error), do: false

  @doc false
  def probe(source, {ask, _budget} = probe, %Description{schema: schema} = description, o) do
    case request(probe, hd(o.viewers), o) do
      {:ok, request} ->
        case Window.check(request, schema) do
          :ok -> probed(source, probe, description, o)
          {:error, faults} -> [{:probe, ask, faults}]
        end

      {:error, faults} ->
        [{:probe, ask, faults}]
    end
  end

  defp probed(source, probe, %Description{schema: schema} = description, o) do
    with {:ok, delivery, rows} <- fetched(source, description, probe, o) do
      time = Schema.window_field(schema)
      type = time && type_of(schema, time)
      served = delivery.served.window

      honest =
        version(delivery, probe, schema) ++
          fields(rows, probe, schema) ++
          times(rows, probe, time, type) ++
          instants(rows, probe, schema, time) ++
          identities(rows, probe, schema) ++
          outside(rows, probe, time, served) ++
          resolution(rows, probe, schema, time, delivery.served.resolution)

      # The clauses that compare against a second fetch need the rows' window field to
      # hold values of its type, and a range window to compare over.
      if Enum.any?(honest, &(elem(&1, 0) == :window_value)) or type not in [:time, :number] do
        honest
      else
        fetch = &fetched(source, description, &1, o)

        honest ++
          complete(fetch, probe, delivery, rows, time) ++
          capped(fetch, probe, delivery, rows, time) ++
          reduced(fetch, probe, delivery, rows, description.supports, time)
      end
    end
  end

  # The request a probe asks, as the given viewer, at the run's `now`.
  defp request({ask, budget}, viewer, o),
    do: Request.new(ask ++ [budget: budget, now: o.now, viewer: viewer])

  @doc false
  # `{:ok, delivery, rows}`, the rows read and well formed, or the findings that end the
  # probe. Shared with every check that fetches.
  def fetched(source, description, probe, o, viewer \\ nil) do
    case request(probe, viewer || hd(o.viewers), o) do
      {:ok, request} -> fetched_request(source, description, request, probe, o)
      {:error, faults} -> [{:probe, elem(probe, 0), faults}]
    end
  end

  defp fetched_request(source, description, request, probe, o) do
    call = {:fetch, probe}

    case call(fn -> Source.fetch(source, description, request) end, call, o) do
      {:ok, {:ok, %Delivery{} = delivery}} ->
        case well_formed(delivery, probe, o) do
          {[], rows} -> {:ok, delivery, rows}
          {faults, _rows} -> faults
        end

      {:ok, {:error, {:bad_fetch, other}}} ->
        [{:not_a_delivery, probe, other}]

      {:ok, {:error, reason}} ->
        [{:fetch_error, probe, reason}]

      {:error, fault} ->
        [fault]
    end
  end

  @doc false
  # A delivery's terms of their kinds (spec/01 §3), and its rows read as maps.
  def well_formed(%Delivery{served: served} = d, probe, o) when is_map(served) do
    {rows, row_faults} = read_rows(d, probe, o)
    window = Map.get(served, :window)
    reduced_by = Map.get(served, :reduced_by)

    faults =
      row_faults ++
        malformed(:window, served_window?(window), window, probe) ++
        malformed(:capped, is_boolean(Map.get(served, :capped)), Map.get(served, :capped), probe) ++
        malformed(:reduced_by, reduced_by in [nil, :source, :runtime], reduced_by, probe) ++
        malformed(:params, is_map(Map.get(served, :params)), Map.get(served, :params), probe) ++
        malformed(:schema, is_nil(d.schema) or is_binary(d.schema), d.schema, probe) ++
        malformed(:resolution, resolution?(Map.get(served, :resolution)), served, probe) ++
        if(reduced_by == :runtime, do: [{:reduced_by, probe, :runtime}], else: [])

    {faults, rows}
  end

  def well_formed(%Delivery{served: served}, probe, _o),
    do: {[{:malformed, probe, :served, served}], []}

  defp malformed(_field, true, _value, _probe), do: []
  defp malformed(field, false, value, probe), do: [{:malformed, probe, field, value}]

  # Rows are read in a process of their own: a table `Table.rows/1` cannot read raises.
  defp read_rows(%Delivery{table: table}, probe, o) do
    case call(fn -> Table.rows(table) end, :rows, o) do
      {:ok, rows} when is_list(rows) ->
        case Enum.find(rows, &(not is_map(&1))) do
          nil -> {rows, []}
          row -> {[], [{:malformed, probe, :rows, row}]}
        end

      _raised ->
        {[], [{:malformed, probe, :rows, table}]}
    end
  end

  defp served_window?(nil), do: true

  defp served_window?([from, to]),
    do: bound?(from) and bound?(to) and (from == nil or to == nil or ordered?(from, to))

  defp served_window?(%{} = box), do: Request.box?(box)
  defp served_window?(_other), do: false

  defp bound?(value), do: value == nil or Window.time?(value)

  defp ordered?(from, to), do: kind(from) == kind(to) and Window.compare(from, to) != :gt

  defp resolution?(nil), do: true
  defp resolution?(r) when is_number(r), do: r > 0
  defp resolution?(r) when is_boolean(r), do: false
  defp resolution?(r), do: is_atom(r)

  defp version(%Delivery{schema: version}, _probe, %Schema{version: version}), do: []

  defp version(%Delivery{schema: named}, probe, %Schema{version: described}),
    do: [{:version, probe, named, described}]

  defp fields(rows, probe, schema) do
    rows
    |> Stream.flat_map(&Map.keys/1)
    |> Stream.uniq()
    |> Enum.reject(&described?(schema, &1))
    |> Enum.map(&{:undescribed_field, probe, &1})
  end

  # A field name is an atom or a string; a row keyed otherwise holds an undescribed field.
  defp described?(schema, field) when is_atom(field) or is_binary(field),
    do: match?({:ok, _}, Schema.fetch(schema, field))

  defp described?(_schema, _field), do: false

  # The window field holds values of its type: instants for `:time`, numbers for
  # `:number`, `{longitude, latitude}` for `:point`, or `nil`.
  defp times(_rows, _probe, nil, _type), do: []

  defp times(rows, probe, time, type) do
    case Enum.find(rows, &(not of_type?(Table.get(&1, time), type))) do
      nil -> []
      row -> [{:window_value, probe, Table.get(row, time)}]
    end
  end

  defp of_type?(nil, _type), do: true
  defp of_type?(value, :time), do: Window.instant?(value)
  defp of_type?(value, :number), do: is_number(value)
  defp of_type?({lon, lat}, :point), do: is_number(lon) and is_number(lat)
  defp of_type?(_value, _type), do: false

  # Every other `:time` field holds instants, or `nil`: a tick written under `:time` is
  # caught here rather than in a drawing.
  defp instants(rows, probe, schema, time) do
    for {field, %{type: :time}} <- Enum.sort(schema.fields),
        field != time,
        row = Enum.find(rows, &(not instant_or_nil?(Table.get(&1, field)))),
        row != nil,
        do: {:not_an_instant, probe, field, Table.get(row, field)}
  end

  defp instant_or_nil?(nil), do: true
  defp instant_or_nil?(value), do: Table.temporal?(value)

  # Every row has a value for each field the schema declares identity: a row that does
  # not say what it is about cannot be grouped with its entity.
  defp identities(rows, probe, schema) do
    for field <- Schema.identity(schema),
        Enum.any?(rows, &(Table.get(&1, field) == nil)),
        do: {:no_identity, probe, field}
  end

  @doc false
  # Every row's window value within the window the delivery says it served.
  def outside(_rows, _probe, nil, _served), do: []
  def outside(_rows, _probe, _time, nil), do: []

  def outside(rows, probe, time, served) do
    case Enum.find(rows, &outside?(Table.get(&1, time), served)) do
      nil -> []
      row -> [{:outside_served, probe, Table.get(row, time), served}]
    end
  end

  @doc false
  # A row with no window value is held to no window; a value of another kind than a bound
  # is outside. Shared with the supports and push checks.
  def outside?(nil, _window), do: false
  def outside?(value, %{} = box), do: not Window.in_box?(value, box)
  def outside?(value, window), do: not inside?(value, window)

  defp inside?(_time, nil), do: true

  defp inside?(time, [from, to]),
    do:
      (from == nil or kind(from) == kind(time)) and (to == nil or kind(to) == kind(time)) and
        Window.within?(time, [from, to])

  defp kind(value) when is_number(value), do: :number
  defp kind(%module{}), do: module
  defp kind(_other), do: :other

  # The served window covers what the source holds in it: every row an open fetch serves
  # within both windows, up to the earlier end, is in the delivery. Asked with a budget,
  # a reduction, `latest` or no range served, there is nothing to compare.
  defp complete(fetch, {ask, budget} = probe, %Delivery{served: served}, rows, time) do
    if budget != nil or served.reduced_by != nil or not match?([_, _], served.window) or
         Keyword.get(ask, :latest, false) do
      []
    else
      [_from, to] = served.window

      case open(fetch, ask, to) do
        {:ok, _open, all} ->
          span = served.window
          held = MapSet.new(rows)

          missing =
            Enum.count(all, fn row ->
              not MapSet.member?(held, row) and Table.get(row, time) != nil and
                not outside?(Table.get(row, time), span)
            end)

          if missing > 0, do: [{:missing, probe, missing, served.window}], else: []

        faults ->
          faults
      end
    end
  end

  # `capped` is true only with a shortfall, and false only when the source held nothing
  # between the asked `from` and where it served from.
  defp capped(fetch, {ask, _budget} = probe, %Delivery{served: served} = delivery, rows, time) do
    case Keyword.get(ask, :window) do
      [from, to] when from != nil ->
        if served.capped,
          do: capped_true(probe, served.window, from),
          else: capped_false(fetch, probe, delivery, rows, time, [from, to])

      _no_from ->
        []
    end
  end

  defp capped_true(probe, served, from) do
    case served do
      [start, _end] when start != nil ->
        if comparable?(start, from) and Window.compare(start, from) == :gt,
          do: [],
          else: [{:capped, probe, served}]

      _no_start ->
        [{:capped, probe, served}]
    end
  end

  defp capped_false(fetch, {ask, _budget} = probe, delivery, rows, time, [from, to]) do
    if Keyword.get(ask, :latest, false) do
      []
    else
      start = start(delivery, rows, time)

      case open(fetch, ask, later(end_of(delivery.served.window), to)) do
        {:ok, _open, all} ->
          before =
            Enum.count(all, fn row ->
              t = Table.get(row, time)
              t != nil and inside?(t, [from, to]) and (start == nil or before?(t, start))
            end)

          if before > 0, do: [{:uncapped, probe, before}], else: []

        faults ->
          faults
      end
    end
  end

  # Where a delivery starts: its served window's `from`, else its earliest row.
  defp start(%Delivery{served: %{window: [from, _to]}}, _rows, _time) when from != nil,
    do: from

  defp start(_delivery, rows, time) do
    rows
    |> Enum.map(&Table.get(&1, time))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(nil, &earlier/2)
  end

  defp end_of([_from, to]), do: to
  defp end_of(_none), do: nil

  @doc false
  def before?(time, start), do: comparable?(time, start) and Window.compare(time, start) == :lt

  @doc false
  # Window arithmetic over the times a source served, which a broken source may not give
  # of one kind: a bound of another kind than the other is kept, never compared.
  def comparable?(a, b), do: Window.time?(a) and Window.time?(b) and kind(a) == kind(b)

  @doc false
  def earlier(nil, b), do: b
  def earlier(a, nil), do: a
  def earlier(a, b), do: if(comparable?(a, b) and Window.compare(b, a) == :lt, do: b, else: a)

  @doc false
  def later(nil, b), do: b
  def later(a, nil), do: a
  def later(a, b), do: if(comparable?(a, b) and Window.compare(b, a) == :gt, do: b, else: a)

  # The open fetch: the same ask, its window `[nil, to]`, with no budget.
  defp open(fetch, ask, to) do
    case fetch.({Keyword.put(ask, :window, [nil, to]), nil}) do
      {:ok, delivery, rows} -> {:ok, delivery, rows}
      faults -> faults
    end
  end

  # `reduced_by` agrees with the rows served with the budget and without it.
  defp reduced(_fetch, {_ask, nil} = probe, %Delivery{served: %{reduced_by: :source}}, _, _, _),
    do: [{:reduced_by, probe, :source}]

  defp reduced(_fetch, {_ask, nil}, _delivery, _rows, _supports, _time), do: []

  defp reduced(fetch, {ask, _budget} = probe, %Delivery{} = delivery, rows, supports, time) do
    case fetch.({ask, nil}) do
      {:ok, whole, all} ->
        upper = earlier(end_of(delivery.served.window), end_of(whole.served.window))
        count = counted(rows, time, upper)
        total = counted(all, time, upper)

        cond do
          delivery.served.reduced_by == :source and (:budget not in supports or count >= total) ->
            [{:reduced_by, probe, :source}]

          delivery.served.reduced_by == nil and count < total ->
            [{:unrecorded_reduction, probe, count, total}]

          true ->
            []
        end

      faults ->
        faults
    end
  end

  # Rows up to a time, so a row that arrived between two fetches is not counted.
  defp counted(rows, nil, _upper), do: length(rows)
  defp counted(rows, _time, nil), do: length(rows)

  defp counted(rows, time, upper),
    do: Enum.count(rows, &(not outside?(Table.get(&1, time), [nil, upper])))

  # No two consecutive distinct times of one series closer than the resolution.
  defp resolution(_rows, _probe, _schema, nil, _resolution), do: []
  defp resolution(_rows, _probe, _schema, _time, nil), do: []

  defp resolution(rows, probe, schema, time, resolution) do
    categories = Enum.sort(for {name, %{type: :category}} <- schema.fields, do: name)

    rows
    |> Enum.group_by(
      fn row -> Enum.map(categories, &Table.get(row, &1)) end,
      &Table.get(&1, time)
    )
    |> Map.values()
    |> Enum.flat_map(&gaps/1)
    |> Enum.find_value([], fn {gap, kind} ->
      case spacing(resolution, kind) do
        nil -> nil
        step -> if gap < step * (1 - 1.0e-9), do: [{:resolution, probe, gap, resolution}]
      end
    end)
  end

  @spans %{second: 1, minute: 60, hour: 3600, day: 86_400, week: 604_800}

  defp gaps(times) do
    times =
      times
      |> Enum.filter(&Window.time?/1)
      |> Enum.uniq_by(&Window.position/1)
      |> Enum.sort_by(&Window.position/1)

    times
    |> Enum.zip(Enum.drop(times, 1))
    |> Enum.map(fn {a, b} -> {seconds(a, b), kind(a)} end)
  end

  # The gap in the window field's own units: seconds for date-times, the values for numbers.
  defp seconds(a, b) when is_number(a), do: b - a
  defp seconds(%DateTime{} = a, b), do: (Window.position(b) - Window.position(a)) / 1_000_000
  defp seconds(%NaiveDateTime{} = a, b), do: Window.position(b) - Window.position(a)
  defp seconds(%Date{} = a, b), do: (Window.position(b) - Window.position(a)) * 86_400

  defp spacing(resolution, _kind) when is_number(resolution), do: resolution
  defp spacing(resolution, :number) when is_atom(resolution), do: nil
  defp spacing(resolution, _kind), do: Map.get(@spans, resolution)

  defp type_of(schema, field) do
    {:ok, type} = Schema.fetch(schema, field, :type)
    type
  end

  defp call(fun, call, o), do: Call.run(fun, call, o)
end
