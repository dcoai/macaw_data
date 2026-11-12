defmodule Macaw.Data.Source.Push do
  @moduledoc """
  One push subscription, as a value (spec/01 §4): the source's changelog, applied to the
  relation it holds (spec/01 §2.5).

  A source that supports `:push` sends its subscriber three messages, each tagged with the
  reference `subscribe/2` answered:

      {:macaw_source, ref, {:schema, schema}}            # first, and again when the schema changes
      {:macaw_source, ref, {:snapshot, delivery}}        # the relation, as of delivery.served.position
      {:macaw_source, ref, {:increment, seq, delivery}}  # the change numbered seq

  `schema_message/2`, `snapshot_message/2` and `increment_message/3` build them. The
  subscriber holds a `Push` in its state: `receive/2` takes each message (a schema is
  cached, a snapshot or an increment buffered), `snapshot/2` buffers a snapshot the
  holder fetched itself, and `drain/2` applies everything buffered since the last pulse
  at once, so a burst of pushes between two pulses costs one drain. `held/1` is the
  relation as it stands; `refetch/1` says when the holder must fetch a snapshot.
  `take_errors/1` hands the holder the errors recorded since it last took them, and
  `pending?/1` says whether a drain has anything to apply, and `trim/2` drops the chunks
  wholly before a sliding window's start, so a holder needs no field of the struct.

  - **The handshake sends the schema first.** A delivery names its schema's version; one
    naming a version not yet cached falls back to `describe` (`drain/2`'s function, the
    `Macaw.Data.Schema.Cache.resolve/4` describe function), asked once and cached.
  - **Increments are numbered** from 1 per subscription and apply in the order of their
    numbers (spec/01 §4.1). A repeated or older one is dropped whole and counted in
    `ignored`; one past the next is held back, the gap recorded in `errors` and answered
    by `refetch/1`.
  - **A snapshot hands off by position:** it replaces what is held and takes its
    `served.position`; increments at or before it are dropped, later ones apply. A
    snapshot older than the position held is dropped whole.
  - **An increment's changes apply in order** (spec/01 §4.2): its `retracted` rows, each
    matched by identity, held window value and the fields it names, one copy per unit of
    weight; then its `replace` ranges, everything held in each retracted; then its
    insertions. A change that can't be matched, or contradicts a replacement, is a fault
    in `errors`, never a guess; against a capped or reduced holding an unheld retraction
    is counted in `ignored` instead.
  - **Only at the held resolution** (spec/01 §4.3): an increment whose
    `served.resolution` differs from what is held is not merged, and `refetch/1` answers
    `{:resolution, held, given}`.
  - **An increment's rows are insertions, merged by the window field:** they stay
    ordered by it, a late row placed among the held, and the served window grows to
    cover them. Rows are never deduplicated: an identical row is a second row. A schema
    with no window field keeps the newest `limit` rows, marking the delivery `capped`
    when it drops any.
  - **`stale` is the last answer's** (spec/01 §4): a snapshot's `served.stale` becomes
    the holding's, and an applied increment's replaces it, as the source answers as of
    that change.
  - **What is held is a chunked table** (spec/01 §2.6): `held/1`'s rows are a
    `Macaw.Data.Table` of the source's origin, its columns the schema's fields, packed as
    `Delivery.table/2` packs; every change reaches it through `Macaw.Data.Table.apply/2`,
    a settled range's in its delta. Rows that don't pack, or can't be read by name (tuple
    rows without `names:`, macaw_data#166), are `{:table, faults}` in `errors`, and nothing
    of that delivery is applied.

  It is not a process: the process that subscribes receives the messages in its mailbox
  and passes them here. Ported from the logic of visualize's `Visualize.Feed.Monitor`,
  whose message tag was `:visualize_feed`.
  """

  alias Macaw.Data.{Delivery, Schema, Table, Window}
  alias Macaw.Data.Schema.Cache
  alias Macaw.Data.Source.{Description, Order}
  alias Macaw.Data.Source.Push.Changes
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Table.Origin

  @tag :macaw_source

  @enforce_keys [:name, :ref]
  defstruct [
    :name,
    :ref,
    held: nil,
    pending: [],
    cache: %Cache{},
    errors: [],
    ignored: %{},
    limit: 100_000,
    position: 0,
    waiting: %{},
    refetch: nil,
    lateness: nil,
    chunk_span: nil,
    trimmed: nil,
    drained: 0
  ]

  @typedoc "A buffered message: a snapshot, or an increment and its number."
  @type message :: {:snapshot, Delivery.t()} | {:increment, pos_integer(), Delivery.t()}

  @type t :: %__MODULE__{
          name: term(),
          ref: reference(),
          held: Delivery.t() | nil,
          pending: [message()],
          cache: Cache.t(),
          errors: [term()],
          ignored: %{atom() => pos_integer()},
          limit: pos_integer(),
          position: non_neg_integer(),
          waiting: %{pos_integer() => Delivery.t()},
          refetch: term(),
          lateness: Duration.t() | number() | nil,
          chunk_span: Duration.t() | number() | nil,
          trimmed: term(),
          drained: non_neg_integer()
        }

  @doc """
  A subscription to the source named `name` under `ref`, holding nothing yet, at
  position `0`. Options: `cache:` a `Schema.Cache` to start from, `limit:` the most rows
  held for a schema with no window field (`100_000`), `lateness:` the source's
  description's hard bound (spec/01 §4.4), `nil` by default, accepting a change of any
  age; `chunk_span:` the description's `chunk_span` (spec/01 §1.1.3), `nil` by default,
  derived from the resolution held.

  A value it can't use is its fault by path, every one at once, never a failure at a later
  drain (macaw_data#177): `{[:cache], {:type, :cache}}`; `{[:limit], {:type, :integer}}`;
  `{[:lateness], {:type, :lateness}}` for anything but `nil`, a number or a well-formed
  `Duration`; `{[:chunk_span], {:type, :chunk_span}}` for anything but `nil`, a positive
  number or a positive `Duration` of fixed length. There is no schema here to judge a
  value against: a number against a time field, or the reverse, is the delivery's fault, as
  ever. A limit of `0` or below holds nothing.

      iex> alias Macaw.Data.Source.Push
      iex> Push.new(:ticks, make_ref(), limit: "x", chunk_span: 0)
      {:error, [{[:limit], {:type, :integer}}, {[:chunk_span], {:type, :chunk_span}}]}
  """
  @spec new(term(), reference(), keyword()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def new(name, ref, opts \\ []) when is_reference(ref) do
    with {:ok, opts} <-
           Macaw.Data.Options.known(opts,
             cache: %Cache{},
             limit: 100_000,
             lateness: nil,
             chunk_span: nil
           ),
         :ok <- values(opts) do
      {:ok,
       %__MODULE__{
         name: name,
         ref: ref,
         cache: opts[:cache],
         limit: opts[:limit],
         lateness: opts[:lateness],
         chunk_span: opts[:chunk_span]
       }}
    end
  end

  defp values(opts) do
    case for {key, type} <- [
               cache: :cache,
               limit: :integer,
               lateness: :lateness,
               chunk_span: :chunk_span
             ],
             not value?(type, opts[key]),
             do: {[key], {:type, type}} do
      [] -> :ok
      faults -> {:error, faults}
    end
  end

  defp value?(:cache, %Cache{entries: entries}) when is_map(entries),
    do: Enum.all?(entries, fn {_key, schema} -> match?(%Schema{}, schema) end)

  defp value?(:cache, _other), do: false
  defp value?(:integer, limit), do: is_integer(limit)
  defp value?(:lateness, nil), do: true
  defp value?(:lateness, lateness), do: is_number(lateness) or Origin.duration?(lateness)
  defp value?(:chunk_span, nil), do: true
  defp value?(:chunk_span, span) when is_number(span), do: span > 0
  defp value?(:chunk_span, span), do: Origin.span_us(span) != nil

  @doc "As `new/3`, the subscription alone, raising `Macaw.Data.Error` naming the faults."
  @spec new!(term(), reference(), keyword()) :: t()
  def new!(name, ref, opts \\ []) do
    case new(name, ref, opts) do
      {:ok, push} ->
        push

      {:error, faults} ->
        raise Macaw.Data.Error, reason: faults, what: "not a subscription's options"
    end
  end

  @doc "The message a source sends with its schema, first and on every change."
  @spec schema_message(reference(), Schema.t()) :: tuple()
  def schema_message(ref, %Schema{} = schema), do: {@tag, ref, {:schema, schema}}

  @doc """
  The message a source sends with a snapshot for the subscription, its position in
  `served.position` (spec/01 §4.1).
  """
  @spec snapshot_message(reference(), Delivery.t()) :: tuple()
  def snapshot_message(ref, %Delivery{} = delivery), do: {@tag, ref, {:snapshot, delivery}}

  @doc "The message a source sends with the increment numbered `seq` (from 1)."
  @spec increment_message(reference(), pos_integer(), Delivery.t()) :: tuple()
  def increment_message(ref, seq, %Delivery{} = delivery) when is_integer(seq) and seq > 0,
    do: {@tag, ref, {:increment, seq, delivery}}

  @doc """
  A message the subscriber received: `{:ok, push}` with a schema cached, or a snapshot or
  an increment buffered; `:ignore` for a message that is not this subscription's.
  """
  @spec receive(t(), term()) :: {:ok, t()} | :ignore
  def receive(%__MODULE__{ref: ref} = push, {@tag, ref, {:schema, %Schema{} = schema}}),
    do: {:ok, %{push | cache: Cache.put(push.cache, push.name, schema)}}

  def receive(%__MODULE__{ref: ref} = push, {@tag, ref, {:snapshot, %Delivery{} = delivery}}),
    do: {:ok, snapshot(push, delivery)}

  def receive(%__MODULE__{ref: ref} = push, {@tag, ref, {:increment, seq, %Delivery{} = d}})
      when is_integer(seq) and seq > 0,
      do: {:ok, %{push | pending: [{:increment, seq, d} | push.pending]}}

  def receive(%__MODULE__{}, _message), do: :ignore

  @doc """
  A snapshot the holder fetched for this subscription (its request naming the
  subscription, spec/01 §2.3), buffered as a received one is; its position is its
  `served.position`.
  """
  @spec snapshot(t(), Delivery.t()) :: t()
  def snapshot(%__MODULE__{} = push, %Delivery{} = delivery),
    do: %{push | pending: [{:snapshot, delivery} | push.pending]}

  @doc """
  Everything buffered applied, in the order received: one drain per pulse, whatever the
  push rate. Increments apply by their numbers, a snapshot hands off by its position
  (spec/01 §4.1). A delivery naming a version the cache lacks is resolved through
  `describe` (`Schema.Cache.resolve/4`); one that cannot be is dropped and its reason
  kept in `errors`. A delivery naming no version is read under the held schema's. A
  delivery `Delivery.new/2` accepts never raises here: rows that can't be read by name or
  don't pack are `{:table, faults}` in `errors`, nothing of that delivery applied.
  """
  @spec drain(t(), Cache.describe()) :: t()
  def drain(%__MODULE__{pending: pending} = push, describe) do
    pending
    |> Enum.reverse()
    |> Enum.reduce(%{push | pending: [], drained: 0}, &take(&2, &1, describe))
    |> gap()
  end

  @doc """
  The relation as it stands, or `nil` before anything is held: a delivery, what was
  served beside its rows, which are a chunked `Macaw.Data.Table` of the source's origin
  (spec/01 §2.6), its columns the schema's fields.
  """
  @spec held(t()) :: Delivery.t() | nil
  def held(%__MODULE__{held: held}), do: held

  @doc """
  `nil`, or why the holder must fetch a snapshot for this subscription and hand it to
  `snapshot/2` (spec/01 §4.1): `{:gap, from, to}`, the numbers that never arrived, or
  `{:resolution, held, given}`, an increment at another resolution (spec/01 §4.3). A
  snapshot taken clears it.
  """
  @spec refetch(t()) :: term()
  def refetch(%__MODULE__{refetch: refetch}), do: refetch

  @doc """
  The errors recorded since they were last taken, in the order recorded, and the push
  holding none (macaw_data#123): a gap, an unresolvable schema, a fault of a change, or
  rows that can't be read by name or don't pack (`{:table, faults}`). A holder takes them
  after each drain, so a subscription that lives long holds only what it has not yet read.

      iex> alias Macaw.Data.Source.Push
      iex> {[], push} = Push.take_errors(Push.new!(:ticks, make_ref()))
      iex> push.errors
      []
  """
  @spec take_errors(t()) :: {[term()], t()}
  def take_errors(%__MODULE__{errors: errors} = push), do: {errors, %{push | errors: []}}

  @doc """
  The schema cache the subscription resolves versions through (macaw_data#202): a holder
  that describes the source again hands it to `new/3`'s `cache:`, so no version is asked
  for twice.

      iex> alias Macaw.Data.Source.Push
      iex> Push.cache(Push.new!(:ticks, make_ref())) == %Macaw.Data.Schema.Cache{}
      true
  """
  @spec cache(t()) :: Cache.t()
  def cache(%__MODULE__{cache: cache}), do: cache

  @doc """
  The number of the last message taken (macaw_data#202): a snapshot's position, or an
  increment's number, consumed whether or not its changes applied (spec/01 §4.1); `0`
  before any. A holder that fetches a snapshot itself hands it this position.

      iex> alias Macaw.Data.Source.Push
      iex> Push.position(Push.new!(:ticks, make_ref()))
      0
  """
  @spec position(t()) :: non_neg_integer()
  def position(%__MODULE__{position: position}), do: position

  @doc """
  How many snapshots and increments the last `drain/2` applied (macaw_data#202): each taken
  and merged with no fault recorded for it. Not counted are a repeat and a stale snapshot,
  which `ignored` counts; a message whose taking recorded a fault in the errors, an
  increment with any faulted change among them; and increments still waiting behind a gap.
  An increment applied once its gap fills counts in the drain that applies it. `0` before
  any drain, and each drain counts afresh.

      iex> alias Macaw.Data.Source.Push
      iex> Push.drained(Push.new!(:ticks, make_ref()))
      0
  """
  @spec drained(t()) :: non_neg_integer()
  def drained(%__MODULE__{drained: drained}), do: drained

  @doc """
  Whether `drain/2` has anything buffered to apply (macaw_data#123): a message received
  or a snapshot handed in since the last drain, or increments held back waiting on a gap
  (spec/01 §4.1), which apply once the numbers before them, or a snapshot, arrive.

      iex> alias Macaw.Data.Source.Push
      iex> Push.pending?(Push.new!(:ticks, make_ref()))
      false
  """
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{pending: pending, waiting: waiting}),
    do: pending != [] or map_size(waiting) > 0

  @doc """
  The holding without the chunks wholly before `from` in the window field's order, for a
  holder whose window slides (macaw_data#123, spec/01 §4): `{:ok, push}`, or `{:error,
  [{[:from], {:type, type}}]}` for a `from` not of the window field's type (a time of any
  kind for a `:time` field, compared on the instant scale; a number for a `:number` one).

  - **Only whole chunks are dropped:** each held chunk whose every window value is before
    `from`, through `Macaw.Data.Table.trim/2` over their rows, so nothing is copied or
    cut and every chunk kept is the same chunk, by id and version. A chunk straddling
    `from` is kept whole; finishing trims its rows.
  - **The served window is narrowed, never widened:** it starts at `from`, or at the held
    start where that is later; its upper end and `complete_until` are unchanged. A box
    has no start to narrow, so it stays as it is.
  - **The trimmed start is kept** (spec/01 §4.2): after it, a retraction naming a row
    before it that is not held, or a replace range wholly before it, is counted in
    `ignored` as `:trimmed`, not recorded as a fault. A late insertion before it is still
    placed; the next trim drops it. A snapshot taken replaces the holding and clears it.

  It is a no-op `{:ok, push}` when nothing is held, when the schema has no window field,
  for a `:point` window field, which has no order, and for a `nil` `from`, an open start.

      iex> alias Macaw.Data.Source.Push
      iex> push = Push.new!(:ticks, make_ref())
      iex> Push.trim(push, 10) == {:ok, push}
      true
  """
  @spec trim(t(), term()) :: {:ok, t()} | {:error, [{[:from], {:type, :time | :number}}]}
  def trim(%__MODULE__{held: nil} = push, _from), do: {:ok, push}
  def trim(%__MODULE__{} = push, nil), do: {:ok, push}

  def trim(%__MODULE__{held: %Delivery{rows: table} = held} = push, from) do
    case ordered_window(table) do
      nil ->
        {:ok, push}

      {name, type} ->
        if Window.applies?([from, nil], type),
          do: {:ok, cut(push, held, name, from)},
          else: {:error, [{[:from], {:type, type}}]}
    end
  end

  @doc "As `trim/2`, the push alone, raising `Macaw.Data.Error` naming the fault."
  @spec trim!(t(), term()) :: t()
  def trim!(%__MODULE__{} = push, from) do
    case trim(push, from) do
      {:ok, push} ->
        push

      {:error, faults} ->
        raise Macaw.Data.Error, reason: faults, what: "the holding cannot be trimmed"
    end
  end

  # -- the handoff (spec/01 §4.1) ---------------------------------------------------------

  defp take(push, {:snapshot, %Delivery{served: %{position: nil}}}, _describe),
    do: fault(push, {:snapshot, :no_position})

  defp take(%{position: held} = push, {:snapshot, %Delivery{served: %{position: p}}}, _describe)
       when p < held,
       do: ignore(push, :stale_snapshot)

  defp take(push, {:snapshot, %Delivery{served: %{position: p}} = delivery}, describe) do
    case resolve(push, delivery, describe) do
      {:ok, schema, push} ->
        case holding(push, delivery, schema) do
          {:ok, held} ->
            waiting = Map.reject(push.waiting, fn {seq, _d} -> seq <= p end)
            {claim, push} = claim(push, held)
            held = put_claim(held, claim)
            push = %{push | held: held, position: p, waiting: waiting, refetch: nil, trimmed: nil}
            advance(applied(push), describe)

          {:error, faults} ->
            fault(push, {:table, faults})
        end

      {:error, reason, push} ->
        fault(push, reason)
    end
  end

  defp take(%{position: held} = push, {:increment, seq, _delivery}, _describe) when seq <= held,
    do: ignore(push, :repeat)

  defp take(%{position: held} = push, {:increment, seq, delivery}, describe)
       when seq == held + 1,
       do: push |> apply_increment(seq, delivery, describe) |> advance(describe)

  defp take(push, {:increment, seq, delivery}, _describe) do
    if Map.has_key?(push.waiting, seq),
      do: ignore(push, :repeat),
      else: %{push | waiting: Map.put(push.waiting, seq, delivery)}
  end

  # The increments held back that are next in number, applied in order.
  defp advance(%{position: held, waiting: waiting} = push, describe) do
    case Map.pop(waiting, held + 1) do
      {nil, _waiting} ->
        push

      {delivery, waiting} ->
        %{push | waiting: waiting}
        |> apply_increment(held + 1, delivery, describe)
        |> advance(describe)
    end
  end

  # After a drain, increments still held back mean a gap: recorded once, and answered
  # unless a refetch is already asked for another reason.
  defp gap(%{waiting: waiting, position: held} = push) when map_size(waiting) > 0 do
    gap = {:gap, held + 1, Enum.min(Map.keys(waiting)) - 1}

    case push.refetch do
      ^gap ->
        push

      refetch when refetch == nil or elem(refetch, 0) == :gap ->
        %{push | refetch: gap, errors: push.errors ++ [gap]}

      _other ->
        push
    end
  end

  defp gap(%{refetch: {:gap, _from, _to}} = push), do: %{push | refetch: nil}
  defp gap(push), do: push

  # One increment, its number consumed whatever comes of it: merged only into a relation
  # held at its resolution (spec/01 §4.3), a mismatch answered with a refetch.
  defp apply_increment(push, seq, delivery, describe) do
    push = %{push | position: seq}

    with {:ok, schema, push} <- resolve(push, delivery, describe),
         :ok <- resolution(push.held, delivery),
         {:ok, rows} <- Delivery.named_rows(delivery) do
      merged = merge(push, delivery, rows, schema)

      # Applied when its merge recorded no fault: any faulted change leaves it uncounted.
      if length(merged.errors) == length(push.errors), do: applied(merged), else: merged
    else
      {:error, reason, push} -> fault(push, reason)
      {:resolution, _held, _given} = mismatch -> %{fault(push, mismatch) | refetch: mismatch}
      {:error, faults} -> fault(push, {:table, faults})
    end
  end

  defp resolution(nil, _delivery), do: :ok
  defp resolution(%{served: %{resolution: r}}, %{served: %{resolution: r}}), do: :ok

  defp resolution(%{served: %{resolution: held}}, %{served: %{resolution: given}}),
    do: {:resolution, held, given}

  defp fault(push, reason), do: %{push | errors: push.errors ++ [reason]}

  # One more message the drain applied (`drained/1`).
  defp applied(push), do: %{push | drained: push.drained + 1}

  defp ignore(push, reason),
    do: %{push | ignored: Map.update(push.ignored, reason, 1, &(&1 + 1))}

  defp resolve(push, %Delivery{schema: nil}, _describe) do
    case push.held && Cache.fetch(push.cache, push.name, push.held.schema) do
      {:ok, schema} -> {:ok, schema, push}
      _none -> {:error, {:unknown_schema, push.name, nil}, push}
    end
  end

  defp resolve(push, %Delivery{schema: version}, describe) do
    case Cache.resolve(push.cache, push.name, version, describe) do
      {:ok, schema, cache} -> {:ok, schema, %{push | cache: cache}}
      {:error, reason, cache} -> {:error, reason, %{push | cache: cache}}
    end
  end

  # The increment's changes applied to what is held through `Table.apply/2` (spec/01
  # §2.6, §4.2): judged first (lateness, overlaps, conflicts), then matched and placed in
  # the held table's chunks, a settled range's in its delta. The served window grows over
  # the rows inserted.
  defp merge(push, delivery, rows, schema) do
    with {:ok, held} <- holding_now(push, delivery, schema),
         {:ok, held} <- reheld(push, held, schema) do
      merge(push, held, delivery, rows, schema)
    else
      {:error, faults} -> fault(push, {:table, faults})
    end
  end

  defp merge(push, held, delivery, rows, schema) do
    old = held.rows

    # Late changes are judged against the claim held before this increment.
    {bound, push} =
      case bound(claimed(push.held), push.lateness) do
        {:incompatible, claim} -> {nil, fault(push, {:lateness, :incompatible, claim})}
        bound -> {bound, push}
      end

    {claim, push} = claim(push, delivery)
    {delivery, push} = before_trimmed(push, delivery)
    {change, before, after_} = Changes.validate(delivery, rows, schema, bound: bound)

    {table, faults, unheld} =
      Table.apply(
        old,
        Map.merge(change, %{
          schema: schema,
          settled: claimed(push.held),
          thinned: thinned?(push.held)
        })
      )

    inserted = Enum.flat_map(change.replace, & &1.rows) ++ change.insert
    version = delivery.schema || held.schema

    held =
      case Schema.window_field(schema) do
        nil ->
          cut = max(Table.size(table) - push.limit, 0)
          served = %{held.served | capped: held.served.capped or cut > 0}
          %{held | rows: Table.trim(table, cut), schema: version, served: served}

        time ->
          held_to = window_to(held) || extreme(old, time, :latest)

          to =
            Window.latest(
              held_to,
              window_to(delivery) || newest(Enum.map(inserted, &Table.get(&1, time)))
            )

          from =
            window_from(held) || window_from(delivery) || extreme(table, time, :earliest)

          %{held | rows: table, schema: version, served: %{held.served | window: [from, to]}}
      end

    # An increment answers as of its change, so its `stale` is the holding's (spec/01 §4).
    held = %{held | served: %{held.served | stale: delivery.served.stale}}

    {faults, push} = trimmed_retractions(push, faults, Schema.window_field(schema))

    push = %{
      push
      | held: put_claim(held, claim),
        errors: push.errors ++ before ++ faults ++ after_
    }

    if unheld > 0,
      do: Enum.reduce(1..unheld, push, fn _, push -> ignore(push, :unheld) end),
      else: push
  end

  # -- the trimmed start (spec/01 §4, §4.2) -----------------------------------------------

  # The held table's window field and its type, where it has an order.
  defp ordered_window(table) do
    with %{window: name} when name != nil <- Table.origin(table),
         type when type in [:time, :number] <- Table.column_type(table, name) do
      {name, type}
    else
      _none -> nil
    end
  end

  # The leading chunks wholly before `from` dropped, the served window narrowed to start
  # at `from` or the held start, and the trimmed start kept.
  defp cut(push, %Delivery{rows: table, served: served} = held, name, from) do
    dropped =
      table
      |> Table.chunks()
      |> Enum.reduce_while(0, fn {chunk, first, count}, n ->
        if wholly_before?(chunk, name, first, count, from),
          do: {:cont, n + count},
          else: {:halt, n}
      end)

    rows = if dropped == 0, do: table, else: Table.trim(table, dropped)

    window =
      case served.window do
        [held_from, to] -> [Window.latest(from, held_from), to]
        nil -> [from, nil]
        %{} = box -> box
      end

    held = %{held | rows: rows, served: %{served | window: window}}
    %{push | held: held, trimmed: Window.latest(push.trimmed, from)}
  end

  # Every value of the run before `from`. The held rows are in the window field's order,
  # a row of no window value last (spec/01 §4), so the run's last value decides: nil keeps
  # the run, and one before `from` has every other before it. A table holds no empty run.
  defp wholly_before?(chunk, name, first, count, from) do
    case Chunk.values(chunk, name, first + count - 1, 1) do
      [nil] -> false
      [last] -> Window.compare(last, from) == :lt
    end
  end

  # A replace range wholly before the trimmed start (its `to`, exclusive, at or before
  # it) is data the holder dropped: counted, not applied.
  defp before_trimmed(%{trimmed: nil} = push, delivery), do: {delivery, push}

  defp before_trimmed(%{trimmed: start} = push, %Delivery{replace: replace} = delivery) do
    {gone, kept} =
      Enum.split_with(replace, fn %{to: to} ->
        to != nil and Window.comparable?(to, start) and Window.compare(to, start) != :gt
      end)

    {%{delivery | replace: kept},
     Enum.reduce(gone, push, fn _, push -> ignore(push, :trimmed) end)}
  end

  # A retraction of a row not held, or held only at another window value, whose window
  # value is before the trimmed start, names a row the trim dropped: counted, not a fault.
  defp trimmed_retractions(%{trimmed: nil} = push, faults, _time), do: {faults, push}
  defp trimmed_retractions(push, faults, nil), do: {faults, push}

  defp trimmed_retractions(%{trimmed: start} = push, faults, time) do
    Enum.reduce(faults, {[], push}, fn
      {:retract, reason, row} = fault, {kept, push} when reason in [:not_held, :moved] ->
        at = Table.get(row, time)

        if at != nil and Window.comparable?(at, start) and Window.compare(at, start) == :lt,
          do: {kept, ignore(push, :trimmed)},
          else: {kept ++ [fault], push}

      fault, {kept, push} ->
        {kept ++ [fault], push}
    end)
  end

  # -- the held table (spec/01 §2.6) ------------------------------------------------------

  # A delivery's rows as the held table: the schema's fields as columns, packed as the
  # edge packs them, in the window field's order with rows of no window value last, on the
  # source's origin. `{:ok, held}` or the packing's faults.
  defp holding(push, %Delivery{} = delivery, schema) do
    with {:ok, rows} <- Delivery.named_rows(delivery),
         rows = ordered(rows, Schema.window_field(schema), schema),
         columns =
           for(
             {name, type} <- header(schema),
             do: {name, type, Enum.map(rows, &Table.at_edge(type, Table.get(&1, name)))}
           ),
         {:ok, table} <-
           Table.new(columns, origin: origin(push, schema, delivery.served.resolution)) do
      {:ok, %{delivery | rows: table, names: nil, retracted: [], replace: []}}
    end
  end

  # What is held, or with nothing held yet an empty table of the increment's resolution.
  defp holding_now(%{held: %Delivery{} = held}, _delivery, _schema), do: {:ok, held}

  defp holding_now(push, delivery, schema) do
    with {:ok, held} <- holding(push, %{delivery | rows: [], names: nil}, schema) do
      {:ok, %{held | served: %{held.served | window: nil, complete_until: nil}}}
    end
  end

  # A held table under another schema's fields (the schema changed): `{:ok, held}`, its
  # rows held again, or the faults of rows that don't pack under the new fields.
  defp reheld(push, %Delivery{rows: table} = held, schema) do
    if Enum.map(Table.names(table), &{&1, Table.column_type(table, &1)}) == header(schema) do
      {:ok, held}
    else
      # A held table always answers its rows.
      holding(push, %{held | rows: Table.rows!(table)}, schema)
    end
  end

  defp header(%Schema{fields: fields}),
    do: fields |> Enum.map(fn {name, field} -> {name, field.type} end) |> Enum.sort()

  # The source's origin (spec/01 §1.1.3): the subscription's name, the resolution held, a
  # time or number window field and its span.
  defp origin(push, schema, resolution) do
    window = Schema.window_field(schema)

    case window && schema.fields[window].type do
      type when type in [:time, :number] ->
        description = %Description{schema: schema, chunk_span: push.chunk_span}
        span = Description.chunk_span(description, resolution)
        %{source: push.name, resolution: resolution, window: window, span: span}

      _none ->
        %{source: push.name, resolution: resolution, window: nil, span: nil}
    end
  end

  # The source's watermark (spec/01 §4.4): carried forward, advanced by a delivery that
  # states a later one, and never moved back: a smaller one is a fault, the held claim
  # kept.
  defp claim(push, %Delivery{served: %{complete_until: given}}) do
    held = claimed(push.held)

    cond do
      given == nil -> {held, push}
      held == nil or Window.position(given) >= Window.position(held) -> {given, push}
      true -> {held, fault(push, {:complete_until, :backwards, held, given})}
    end
  end

  defp claimed(nil), do: nil
  defp claimed(%Delivery{served: served}), do: served.complete_until

  defp put_claim(%Delivery{served: served} = held, claim),
    do: %{held | served: %{served | complete_until: claim}}

  # `complete_until − lateness`, in the window field's terms; `nil` without both.
  defp bound(nil, _lateness), do: nil
  defp bound(_claim, nil), do: nil

  defp bound(claim, lateness) when is_integer(claim) and is_integer(lateness),
    do: claim - lateness

  # Past what a float's subtraction holds: no row is later than a lateness so large, and
  # a claim so large is its own bound.
  defp bound(_claim, lateness) when is_number(lateness) and abs(lateness) > 1.0e300, do: nil

  defp bound(claim, lateness)
       when is_number(claim) and abs(claim) > 1.0e300 and is_number(lateness), do: claim

  defp bound(claim, lateness) when is_number(claim) and is_number(lateness), do: claim - lateness
  defp bound(%DateTime{} = claim, %Duration{} = d), do: DateTime.shift(claim, Duration.negate(d))

  defp bound(%NaiveDateTime{} = claim, %Duration{} = d),
    do: NaiveDateTime.shift(claim, Duration.negate(d))

  # A date's claim is its midnight: a lateness of hours or less leaves a naive time.
  defp bound(%Date{} = claim, %Duration{hour: 0, minute: 0, second: 0, microsecond: {0, _}} = d),
    do: Date.shift(claim, Duration.negate(d))

  defp bound(%Date{} = claim, %Duration{} = d),
    do: claim |> NaiveDateTime.new!(~T[00:00:00]) |> bound(d)

  # A claim the lateness can't be taken from (a time against a number): recorded, and
  # no bound applied.
  defp bound(claim, _lateness), do: {:incompatible, claim}

  # A holding from a capped or reduced delivery may lack rows (spec/01 §4.2).
  defp thinned?(nil), do: false
  defp thinned?(%Delivery{served: served}), do: served.capped or served.reduced_by != nil

  # Stable by the window field's position, a row with no time last.
  # The rows in the window field's order, each value read as the edge packs it
  # (`Table.at_edge/2`): a time given as an ISO string is placed at its instant, as the
  # table checks the order it is held in (macaw_data#239).
  defp ordered(rows, nil, _schema), do: rows

  defp ordered(rows, time, schema) do
    type = schema.fields[time].type

    Enum.sort_by(rows, fn row ->
      case Window.position(Table.at_edge(type, Table.get(row, time))) do
        nil -> {1, 0}
        p -> {0, p}
      end
    end)
  end

  defp window_from(%Delivery{served: %{window: [from, _to]}}), do: from
  defp window_from(_delivery), do: nil

  defp window_to(%Delivery{served: %{window: [_from, to]}}), do: to
  defp window_to(_delivery), do: nil

  # The fold of `Window.latest/2` (`earliest/2`) over the values, from nil (macaw_data#204):
  # the first value present, replaced by each later one it shares a scale with
  # (`Window.comparable?/2`) and is before (after). Each value's place on its scale is
  # taken once, not at every compare.
  defp newest(values), do: values |> fold(nil, :latest) |> folded()
  defp earliest(values), do: values |> fold(nil, :earliest) |> folded()

  defp fold([], acc, _which), do: acc
  defp fold([nil | rest], acc, which), do: fold(rest, acc, which)
  defp fold([v | rest], nil, which), do: fold(rest, {v, scale(v)}, which)

  defp fold([v | rest], {_held, {kind, at}} = acc, which) do
    case scale(v) do
      {^kind, p} when which == :latest and at < p -> fold(rest, {v, {kind, p}}, which)
      {^kind, p} when which == :earliest and at > p -> fold(rest, {v, {kind, p}}, which)
      _other -> fold(rest, acc, which)
    end
  end

  defp fold([_v | rest], acc, which), do: fold(rest, acc, which)

  defp folded(nil), do: nil
  defp folded({value, _scale}), do: value

  # A value's place: a number on the number scale, an instant on the instant scale, which
  # `Window.compare/2` compares on; anything else shares no scale.
  defp scale(v) when is_number(v), do: {:number, v}

  defp scale(v) do
    if Window.instant?(v), do: {:instant, Order.instant(v)}, else: :none
  end

  # What `newest/1` (`:latest`) or `earliest/1` (`:earliest`) answers over the held
  # table's window column, read from its positions (macaw_data#204): the first value at
  # the latest or earliest position. A time column's instants are read where they lie
  # (`Chunk.instants/4`, on the scale `Window.compare/2` compares on) and a number
  # column's values as they are, so no row is made and no value is compared twice; the
  # one value found is read from its chunk. Every value of either column shares one
  # scale, so the fold compares every pair and keeps the first of equals, as this does.
  # A column of another type is folded as it was.
  defp extreme(table, name, which) do
    case Table.column_type(table, name) do
      type when type in [:time, :number] ->
        found =
          table
          |> Table.chunks()
          |> Enum.reduce(nil, fn {chunk, first, count}, found ->
            chunk |> positions(name, type, first, count) |> best(0, {chunk, first}, found, which)
          end)

        case found do
          nil -> nil
          {_p, {chunk, first}, i} -> Chunk.at(chunk, name, first + i)
        end

      _other ->
        values = Table.column(table, name)
        if which == :latest, do: newest(values), else: earliest(values)
    end
  end

  defp positions(chunk, name, :time, first, count), do: Chunk.instants(chunk, name, first, count)
  defp positions(chunk, name, :number, first, count), do: Chunk.values(chunk, name, first, count)

  # The first position past `found` in a run's positions, with where it lies.
  defp best([], _i, _run, found, _which), do: found
  defp best([nil | rest], i, run, found, which), do: best(rest, i + 1, run, found, which)
  defp best([p | rest], i, run, nil, which), do: best(rest, i + 1, run, {p, run, i}, which)

  defp best([p | rest], i, run, {b, _, _}, :latest) when p > b,
    do: best(rest, i + 1, run, {p, run, i}, :latest)

  defp best([p | rest], i, run, {b, _, _}, :earliest) when p < b,
    do: best(rest, i + 1, run, {p, run, i}, :earliest)

  defp best([_p | rest], i, run, found, which), do: best(rest, i + 1, run, found, which)
end
